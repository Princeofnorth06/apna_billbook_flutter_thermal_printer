# Windows Startup Crash Fix (c0000005 / MSVCP140)

## Why the crash happens

- **Access violation in MSVCP140.dll** (~1 s after launch, even when no Dart API is called) is caused by:
  1. **BLE/WinRT initialization during plugin registration** – In `universal_ble`, the Windows plugin constructor calls `InitializeAsync()`, which starts WinRT work (e.g. `Radio::GetRadiosAsync()`, `bluetooth_radio_.StateChanged(...)`). That runs as soon as the DLL is loaded and the plugin is registered, so COM/WinRT and async completion run during startup.
  2. **Callbacks after object destruction** – WinRT events (e.g. `RadioStateChanged`, `BluetoothLeWatcherReceived`) and coroutine completions hold references to the plugin. When the window/app shuts down or plugins are torn down, those callbacks can still run and touch freed plugin state → use-after-free and MSVCP140 (e.g. std::function/vtable) crashes.
  3. **Static `callback_channel`** – In `universal_ble_plugin.cpp`, `callback_channel` is a static global. It is created in `RegisterWithRegistrar` and used from async completions (e.g. `InitializeAsync` posting to UI thread and calling `callback_channel->OnAvailabilityChanged`). If the plugin or app is disposed before those run, you get use-after-free.
  4. **COM/WinRT apartment lifecycle** – WinRT must run in an apartment (usually STA). If `winrt::init_apartment()` is never called or is called from the wrong thread, or uninit happens while callbacks are still pending, you get undefined behavior and often crashes under Admin or when multiple plugins load (e.g. `flutter_thermal_printer` + `universal_ble`).
  5. **Running as Administrator** – Different process token and COM registration can make the above races deterministic (e.g. different DLL load order or callback timing).

**Conclusion:** The crash is fixed by (1) doing **no** BLE/WinRT work at plugin load/registration, (2) initializing BLE and WinRT only on first Dart call (lazy init), (3) ensuring all callbacks check a single “disposed”/“alive” flag and skip work if the plugin is gone, (4) proper `winrt::init_apartment()` / `uninit_apartment()` and (5) optionally skipping or failing BLE init when running as Admin.

---

## 1. Changes in this repo: `flutter_thermal_printer` (Windows)

This plugin does **not** use BLE or WinRT; it only uses the method channel and Win32 (e.g. version helpers). It was still hardened so it never contributes to startup or shutdown crashes:

- **Files touched:**  
  `windows/flutter_thermal_printer_plugin.h`  
  `windows/flutter_thermal_printer_plugin.cpp`

- **What was done:**
  - Registration only creates the method channel and plugin; no async init, no WinRT/COM.
  - Handler uses **weak_ptr** to the plugin so a late callback never runs after the plugin is destroyed (avoids use-after-free and MSVCP140).
  - Plugin is held by **shared_ptr** and given to the registrar with a custom deleter so that when Flutter “deletes” the plugin, we only release our shared_ptr; the handler’s `weak_ptr::lock()` then returns null and we respond with a DISPOSED error instead of touching freed memory.
  - Added `disposed_` / `is_alive()` for consistency and future use.

No further changes are required in `flutter_thermal_printer` for this crash. The remaining fixes must be in **universal_ble** (see below).

---

## 2. Changes in `universal_ble` (Windows) – exact files and code

Apply these in your **fork** of [Navideck/universal_ble](https://github.com/Navideck/universal_ble) (or your app’s copy of the plugin). Paths are relative to the plugin root (e.g. `universal_ble/windows/`).

---

### 2.1 No BLE init during registration; lazy init only

**File:** `windows/src/universal_ble_plugin.cpp`

**Current (problematic):**

```cpp
void UniversalBlePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<UniversalBlePlugin>(registrar);
  SetUp(registrar->messenger(), plugin.get());
  callback_channel =
      std::make_unique<UniversalBleCallbackChannel>(registrar->messenger());
  registrar->AddPlugin(std::move(plugin));
}

UniversalBlePlugin::UniversalBlePlugin(
    flutter::PluginRegistrarWindows *registrar)
    : ui_thread_handler_(registrar) {
  InitializeAsync();  // <-- REMOVE: starts WinRT at load time
}
```

**Change to:**

- In **RegisterWithRegistrar**: do **not** call any WinRT/BLE APIs. Only create the plugin, set up the platform channel, create the callback channel, and add the plugin. Do **not** start `InitializeAsync` here or in the constructor.
- In **UniversalBlePlugin constructor**: remove the call to `InitializeAsync()`. Only initialize members; do not start async WinRT work.

Example:

```cpp
void UniversalBlePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<UniversalBlePlugin>(registrar);
  SetUp(registrar->messenger(), plugin.get());
  callback_channel =
      std::make_unique<UniversalBleCallbackChannel>(registrar->messenger());
  registrar->AddPlugin(std::move(plugin));
  // No BLE/WinRT work here; no InitializeAsync().
}

UniversalBlePlugin::UniversalBlePlugin(
    flutter::PluginRegistrarWindows *registrar)
    : ui_thread_handler_(registrar) {
  // Do NOT call InitializeAsync() here.
}
```

---

### 2.2 Lazy BLE initialization on first Dart call

- Add a single “BLE initialized” gate (e.g. `std::once_flag` or a bool + mutex) and call WinRT init and your existing `InitializeAsync()` logic only when the first BLE-related method is invoked from Dart (e.g. `GetBluetoothAvailabilityState`, `StartScan`, `EnableBluetooth`).
- Before any WinRT/BLE work, ensure the thread has a WinRT apartment. Call `winrt::init_apartment()` once (e.g. inside the same gate) and document that you call `winrt::uninit_apartment()` only when the plugin is definitely torn down and no more WinRT callbacks will run (see 2.5).

**File:** `windows/src/universal_ble_plugin.cpp`

Add near the top (or in a small helper):

```cpp
#include <winrt/base.h>

static std::once_flag g_winrt_apartment_once;
static bool g_winrt_apartment_ok = false;

static void EnsureWinRtApartment() {
  std::call_once(g_winrt_apartment_once, []() {
    try {
      winrt::init_apartment(winrt::apartment_type::sta);
      g_winrt_apartment_ok = true;
    } catch (...) {
      g_winrt_apartment_ok = false;
    }
  });
}
```

In every entry point that touches BLE/WinRT (e.g. `GetBluetoothAvailabilityState`, `EnableBluetooth`, `StartScan`, `GetSystemDevices`, etc.), at the start:

```cpp
EnsureWinRtApartment();
if (!g_winrt_apartment_ok) {
  result(static_cast<int>(AvailabilityState::unsupported));  // or appropriate error
  return;
}
```

Then ensure your “lazy init” runs once: e.g. a flag `bool ble_initialized_ = false` and a method `void EnsureBleInitialized(std::function<void()> on_done)` that:

1. Checks `ble_initialized_`. If true, calls `on_done()` and returns.
2. Otherwise starts the same logic you had in `InitializeAsync()` (get radios, set `bluetooth_radio_`, subscribe to `StateChanged`), and when that completes sets `ble_initialized_ = true` and calls `on_done()` (on UI thread if required).

Call `EnsureBleInitialized` at the start of each BLE API that needs the radio/watchers, then proceed with the existing logic. That way no WinRT/BLE work runs at plugin load.

---

### 2.3 Disposed / is_alive flag and callback guards

**File:** `windows/src/universal_ble_plugin.h`

- Add a flag that is set to “disposed” only in the destructor, and that outlives any async callback (e.g. `std::atomic<bool> disposed_{false}` or a `std::shared_ptr<std::atomic<bool>>` so the handler can check it without holding a pointer to the plugin).
- Expose something like `bool is_alive() const { return !disposed_; }` (or check the atomic in a static/global so callbacks can check without dereferencing the plugin).

**File:** `windows/src/universal_ble_plugin.cpp`

- In **~UniversalBlePlugin()**:
  - Set `disposed_ = true` (or the shared atomic) **first**.
  - Stop all watchers and revoke all WinRT event tokens (e.g. `bluetooth_le_watcher_.Received(bluetooth_le_watcher_received_token_); bluetooth_le_watcher_.Stop();`, `DisposeDeviceWatcher()`, `radio_state_changed_revoker_.revoke()`), so no new callbacks are delivered.
  - Then clear members (e.g. `bluetooth_radio_ = nullptr`, etc.).

- In **every** callback that touches plugin state or `callback_channel` (e.g. `RadioStateChanged`, `BluetoothLeWatcherReceived`, `OnDeviceInfoReceived`, completions of `InitializeAsync`, and any `ui_thread_handler_.Post([this, ...] { ... })` that use `this` or `callback_channel`):
  - At the top, check the disposed flag. If disposed, return immediately without touching `this` or `callback_channel`.

Example for `RadioStateChanged`:

```cpp
void UniversalBlePlugin::RadioStateChanged(const Radio &sender, const IInspectable &) {
  if (disposed_) return;
  // ... rest of implementation
}
```

For lambdas that capture `this` or `callback_channel`, capture the flag (or a `weak_ptr` to the plugin) and check at the start of the lambda:

```cpp
ui_thread_handler_.Post([this] {
  if (disposed_) return;
  if (!callback_channel) return;
  callback_channel->OnAvailabilityChanged(...);
});
```

Ensure `callback_channel` is either cleared in the destructor (after setting `disposed_`) or also guarded by the same flag so no one uses it after shutdown.

---

### 2.4 Do not use a static `callback_channel` that outlives the plugin

- **Option A (recommended):** Store `callback_channel` as a member of `UniversalBlePlugin` (or a shared_ptr that the plugin owns), create it in `RegisterWithRegistrar` and pass it into the plugin (e.g. constructor or setter). In the destructor, set `disposed_` and then clear or release `callback_channel` so no async callback uses it after the plugin is destroyed. All callbacks must check `disposed_` (and optionally that `callback_channel` is non-null) before use.
- **Option B:** Keep a static `callback_channel` but ensure every use is guarded by the plugin’s disposed flag and that the callback channel is only used from the UI thread and only when the plugin is still alive. Prefer Option A so lifecycle is clear.

---

### 2.5 WinRT apartment uninit

- Call `winrt::uninit_apartment()` only when you are certain no WinRT callbacks will run anymore (e.g. after the plugin is destroyed and the app is shutting down). Do **not** call it from inside the plugin destructor if other threads or queued completions might still run. If your app has a single “shutdown” point (e.g. after the Flutter engine is destroyed), you can call it there once. Otherwise, skipping uninit is safer than calling it too early; many apps leave WinRT apartment initialized for process lifetime.

---

### 2.6 Administrator: skip or fail BLE init

- Before starting BLE (e.g. in `EnsureBleInitialized` or at the start of `InitializeAsync` logic), check whether the process is running with elevation. If so, either skip BLE initialization and return “unsupported”/“unavailable” from APIs, or initialize in a way that is known to work under Admin (e.g. same COM/WinRT setup as non-admin). Simplest production fix: if running as Admin, set a flag and have `GetBluetoothAvailabilityState` (and other BLE APIs) return “unsupported” or an error so no WinRT BLE code runs.

Example (add to the same file or a small util):

```cpp
#include <windows.h>
#include <shellapi.h>

static bool IsProcessElevated() {
  BOOL elevated = FALSE;
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION te = {};
  DWORD size = 0;
  if (GetTokenInformation(token, TokenElevation, &te, sizeof(te), &size))
    elevated = (te.TokenIsElevated != 0);
  if (token) CloseHandle(token);
  return elevated != 0;
}
```

In your lazy BLE init (or first BLE API):

```cpp
if (IsProcessElevated()) {
  // Optional: log that BLE is disabled when running as Admin
  initialized_ = true;
  bluetooth_radio_ = nullptr;
  // Then in GetBluetoothAvailabilityState etc. return unsupported.
  return;
}
```

---

## 3. Checklist (universal_ble)

- [ ] Remove `InitializeAsync()` from `UniversalBlePlugin` constructor.
- [ ] Do not perform any BLE/WinRT work in `RegisterWithRegistrar` (only create plugin and channels).
- [ ] Add lazy init: first BLE API call runs `EnsureWinRtApartment()` and your one-time BLE init (radio, StateChanged, etc.).
- [ ] Add `disposed_` (or shared atomic) and set it at the start of `~UniversalBlePlugin()`; stop watchers and revoke events before clearing members.
- [ ] In every WinRT/coroutine callback and every `ui_thread_handler_.Post` that uses `this` or `callback_channel`, check `disposed_` (and optionally `callback_channel`) at the top and return if set.
- [ ] Prefer storing `callback_channel` in the plugin and clearing it in the destructor; guard all uses with `disposed_`.
- [ ] (Optional) If running as Admin, skip or fail BLE init and return unsupported from BLE APIs.
- [ ] Call `winrt::uninit_apartment()` only when no more WinRT callbacks can run (e.g. app shutdown); otherwise leave initialized.

---

## 4. Result

- Plugin load/registration no longer starts any BLE or WinRT work → no COM/WinRT or async activity during startup.
- All BLE work runs only after the first Dart call and on a properly initialized apartment.
- No callback runs after the plugin is disposed, and no use of `callback_channel` or plugin state after destruction → stable for long-running and POS apps, and no MSVCP140 access violation from use-after-free.

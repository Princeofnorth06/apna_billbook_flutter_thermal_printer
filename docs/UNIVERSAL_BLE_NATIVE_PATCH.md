# universal_ble Windows: Native Crash Fix (Apply in universal_ble repo)

The startup crash (c0000005, MSVCP140) is caused by **universal_ble** running BLE/WinRT during plugin load. Apply these changes in the **universal_ble** Windows plugin source (e.g. after adding it as a path dependency or forking [Navideck/universal_ble](https://github.com/Navideck/universal_ble)).

---

## 1. universal_ble_plugin.h

**Path:** `windows/src/universal_ble_plugin.h`

**Add** `#include <atomic>` with the other includes.

**Add** to the class private section (e.g. after `bool initialized_ = false;`):

```cpp
  std::atomic<bool> alive_{true};

  void EnsureInitialized(std::function<void()> on_ready);
```

**Change** the destructor declaration to ensure it's non-default so we can add cleanup:

```cpp
  ~UniversalBlePlugin();
```

(Keep as-is; ensure the .cpp implements full cleanup.)

**Remove** or keep `fire_and_forget InitializeAsync();` but it must only be called from `EnsureInitialized`, never from the constructor.

---

## 2. universal_ble_plugin.cpp – Registration and constructor

**Path:** `windows/src/universal_ble_plugin.cpp`

**Replace** `RegisterWithRegistrar` so it only registers (no BLE work):

```cpp
void UniversalBlePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<UniversalBlePlugin>(registrar);
  SetUp(registrar->messenger(), plugin.get());
  callback_channel =
      std::make_unique<UniversalBleCallbackChannel>(registrar->messenger());
  registrar->AddPlugin(std::move(plugin));
  // No BLE, WinRT, or threads here.
}
```

**Replace** the constructor so it does nothing except store the registrar:

```cpp
UniversalBlePlugin::UniversalBlePlugin(
    flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar), ui_thread_handler_(registrar) {
  // Do NOT call InitializeAsync() or any WinRT/BLE here.
}
```

---

## 3. universal_ble_plugin.cpp – Lazy init

**Add** at file scope (e.g. after the `static std::unique_ptr<UniversalBleCallbackChannel> callback_channel;`). Ensure `#include <mutex>` and `#include <winrt/base.h>` are present:

```cpp
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

**Add** the member implementation (call this from every BLE method before using WinRT/radio):

```cpp
void UniversalBlePlugin::EnsureInitialized(std::function<void()> on_ready) {
  if (!alive_.load(std::memory_order_acquire))
    return;
  EnsureWinRtApartment();
  if (!g_winrt_apartment_ok) {
    if (callback_channel && alive_.load(std::memory_order_acquire))
      ui_thread_handler_.Post([on_ready] { on_ready(); });
    return;
  }
  if (initialized_) {
    on_ready();
    return;
  }
  // Run existing InitializeAsync() logic once; when it completes, set
  // initialized_ = true and call on_ready() on UI thread.
  InitializeAsync().Completed([this, on_ready](auto const&, AsyncStatus s) {
    if (!alive_.load(std::memory_order_acquire)) return;
    initialized_ = true;
    ui_thread_handler_.Post([on_ready] { on_ready(); });
  });
}
```

**Important:** The existing `InitializeAsync()` is a coroutine (`fire_and_forget`). You have two options:

- **Option A:** Change `InitializeAsync()` to return `IAsyncAction` (or a completable future) so you can call `.Completed(...)` as above and only invoke it from `EnsureInitialized()`.
- **Option B:** Keep `InitializeAsync()` as `fire_and_forget` but do **not** call it from the constructor. From `EnsureInitialized()`, call it once (guarded by a `std::once_flag` or a bool), and have `InitializeAsync()` at the end post to the UI thread to set `initialized_ = true` and call `on_ready()`. All BLE API methods must then call `EnsureInitialized([this, result_callback]{ ... actual API ... });` and only run the actual logic inside the lambda when initialization has finished.

Use Option B if you want minimal changes: from the constructor remove the call to `InitializeAsync()`. Add a `std::once_flag init_once_` and in `EnsureInitialized()`:

```cpp
void UniversalBlePlugin::EnsureInitialized(std::function<void()> on_ready) {
  if (!alive_.load(std::memory_order_acquire)) return;
  EnsureWinRtApartment();
  if (!g_winrt_apartment_ok) { on_ready(); return; }
  std::call_once(init_once_, [this]() { InitializeAsync(); });
  // InitializeAsync() eventually sets initialized_ and notifies. For the first
  // call we need to wait; you can use a condition variable or poll initialized_
  // and then call on_ready(). Simplest: post on_ready after a short delay when
  // !initialized_, or have InitializeAsync() complete callback call on_ready.
  if (initialized_) {
    on_ready();
    return;
  }
  ui_thread_handler_.Post([this, on_ready]() {
    if (!alive_.load(std::memory_order_acquire)) return;
    if (initialized_) on_ready();
    else { /* retry or wait */ on_ready(); }
  });
}
```

Prefer implementing a proper “init completed” callback from `InitializeAsync()` (e.g. it posts to UI thread setting `initialized_ = true` and runs a single “ready” callback) so BLE APIs only run after init.

---

## 4. universal_ble_plugin.cpp – Destructor and cleanup

**Replace** the destructor with full cleanup:

```cpp
UniversalBlePlugin::~UniversalBlePlugin() {
  alive_.store(false, std::memory_order_release);

  try {
    if (bluetooth_le_watcher_) {
      bluetooth_le_watcher_.Received(bluetooth_le_watcher_received_token_);
      bluetooth_le_watcher_.Stop();
      bluetooth_le_watcher_ = nullptr;
    }
    DisposeDeviceWatcher();
    radio_state_changed_revoker_.revoke();
    bluetooth_radio_ = nullptr;
    connected_devices_.clear();
    device_watcher_devices_.clear();
    scan_results_.clear();
    device_watcher_id_to_mac_.clear();
  } catch (...) {}
  callback_channel.reset();
}
```

(Adjust to match actual member names and any extra watchers/threads. Revoke all event tokens and stop all watchers before clearing containers.)

---

## 5. universal_ble_plugin.cpp – Callback guards

In **every** callback that touches plugin state or `callback_channel`, add at the top:

```cpp
if (!alive_.load(std::memory_order_acquire)) return;
```

Examples:

- `RadioStateChanged`: first line `if (!alive_.load(std::memory_order_acquire)) return;`
- `BluetoothLeWatcherReceived`: same.
- `OnDeviceInfoReceived`: same.
- Inside every `ui_thread_handler_.Post([this, ...] { ... })` lambda that uses `this` or `callback_channel`: first line of the lambda `if (!alive_.load(std::memory_order_acquire)) return;`
- In the completion of `InitializeAsync()` (when it posts to UI or calls `callback_channel->OnAvailabilityChanged`): check `alive_` before touching `callback_channel` or `this`.

---

## 6. BLE API entry points – EnsureInitialized and alive_

At the start of every public BLE method (e.g. `GetBluetoothAvailabilityState`, `StartScan`, `Connect`, `GetSystemDevices`, etc.):

1. Check `if (!alive_.load(std::memory_order_acquire)) { result(...error...); return; }`
2. Call `EnsureInitialized()` (or the async variant that calls `result` when ready) so WinRT/radio are only used after lazy init.

Example for `GetBluetoothAvailabilityState`:

```cpp
void UniversalBlePlugin::GetBluetoothAvailabilityState(
    std::function<void(ErrorOr<int64_t> reply)> result) {
  if (!alive_.load(std::memory_order_acquire)) {
    result(static_cast<int64_t>(AvailabilityState::unknown));
    return;
  }
  EnsureInitialized([this, result]() {
    if (!alive_.load(std::memory_order_acquire)) {
      result(static_cast<int64_t>(AvailabilityState::unknown));
      return;
    }
    if (!bluetooth_radio_) {
      result(initialized_ ? static_cast<int64_t>(AvailabilityState::unsupported)
                          : static_cast<int64_t>(AvailabilityState::unknown));
      return;
    }
    result(static_cast<int64_t>(get_availability_state_from_radio(bluetooth_radio_.State())));
  });
}
```

Apply the same pattern to all other BLE methods: guard with `alive_`, then run logic inside `EnsureInitialized(..., [this, result]{ ... })`.

---

## 7. winrt::uninit_apartment()

Call `winrt::uninit_apartment()` only when the process is shutting down and no plugin/DLL will run WinRT again (e.g. in the Flutter Windows runner after the message loop exits and before exit). Do **not** call it inside the plugin destructor if other threads or queued WinRT callbacks might still run.

---

## 8. Checklist

- [ ] Constructor: no `InitializeAsync()`, no WinRT/COM/BLE.
- [ ] `RegisterWithRegistrar`: only create plugin and channels; no BLE.
- [ ] `EnsureWinRtApartment()` + `EnsureInitialized()`; call only from BLE method handlers.
- [ ] `alive_` set to `false` at start of destructor; all callbacks and handlers check `alive_`.
- [ ] Destructor: revoke tokens, stop watchers, clear maps, release WinRT objects.
- [ ] All BLE APIs check `alive_` and call `EnsureInitialized` before using radio/WinRT.

After applying these changes in the universal_ble Windows plugin, rebuild. The EXE should idle without crashing.

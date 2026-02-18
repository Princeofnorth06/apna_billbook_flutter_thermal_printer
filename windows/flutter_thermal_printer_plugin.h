#ifndef FLUTTER_PLUGIN_FLUTTER_THERMAL_PRINTER_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_THERMAL_PRINTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <memory>

namespace flutter_thermal_printer {

/// Windows plugin: USB printer via Win32 only. No BLE, WinRT, or COM.
/// Constructor and RegisterWithRegistrar() do no work; safe at DLL load.
/// All async/callbacks must check is_alive() before touching plugin state.
class FlutterThermalPrinterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterThermalPrinterPlugin();
  virtual ~FlutterThermalPrinterPlugin();

  FlutterThermalPrinterPlugin(const FlutterThermalPrinterPlugin&) = delete;
  FlutterThermalPrinterPlugin& operator=(const FlutterThermalPrinterPlugin&) = delete;

  /// True until destructor runs. All callbacks must check before using this.
  bool is_alive() const { return alive_.load(std::memory_order_acquire); }

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  /// No-op for this plugin (no native BLE/WinRT). Call from method handlers if needed.
  void EnsureInitialized();

  std::atomic<bool> alive_{true};
};

}  // namespace flutter_thermal_printer

#endif  // FLUTTER_PLUGIN_FLUTTER_THERMAL_PRINTER_PLUGIN_H_

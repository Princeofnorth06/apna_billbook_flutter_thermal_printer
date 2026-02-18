#ifndef FLUTTER_PLUGIN_FLUTTER_THERMAL_PRINTER_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_THERMAL_PRINTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <memory>

namespace flutter_thermal_printer {

/// Windows plugin for USB printer (Win32 API only). No BLE, no WinRT, no COM.
/// BLE is handled by Dart via universal_ble; this plugin must stay safe at
/// registration (no async init, no callbacks) to avoid startup crashes when
/// combined with other native plugins (e.g. universal_ble).
class FlutterThermalPrinterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterThermalPrinterPlugin();

  virtual ~FlutterThermalPrinterPlugin();

  // Disallow copy and assign.
  FlutterThermalPrinterPlugin(const FlutterThermalPrinterPlugin&) = delete;
  FlutterThermalPrinterPlugin& operator=(const FlutterThermalPrinterPlugin&) = delete;

  /// Returns false after destructor has run; use in any callback before touching state.
  bool is_alive() const { return !disposed_; }

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  std::atomic<bool> disposed_{false};
};

}  // namespace flutter_thermal_printer

#endif  // FLUTTER_PLUGIN_FLUTTER_THERMAL_PRINTER_PLUGIN_H_

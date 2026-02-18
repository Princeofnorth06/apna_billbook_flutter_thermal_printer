#include "flutter_thermal_printer_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

// For getPlatformVersion; remove unless needed for your plugin implementation.
#include <VersionHelpers.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>

namespace flutter_thermal_printer {

// Registration only: create channel and plugin, set handler. No BLE, WinRT, COM,
// or any async work so plugin load is safe when combined with universal_ble.
// Handler uses weak_ptr so no callback runs after plugin destruction (avoids
// MSVCP140 access violation from use-after-free).
void FlutterThermalPrinterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_thermal_printer",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_shared<FlutterThermalPrinterPlugin>();
  std::weak_ptr<FlutterThermalPrinterPlugin> weak = plugin;

  channel->SetMethodCallHandler(
      [weak](const auto &call, auto result) {
        auto p = weak.lock();
        if (!p) {
          result->Error("DISPOSED", "Plugin has been disposed.");
          return;
        }
        p->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::unique_ptr<flutter::Plugin>(
      plugin.get(),
      [plugin](flutter::Plugin*) mutable { plugin.reset(); }));
}

FlutterThermalPrinterPlugin::FlutterThermalPrinterPlugin() {}

FlutterThermalPrinterPlugin::~FlutterThermalPrinterPlugin() {
  disposed_.store(true);
}

void FlutterThermalPrinterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!is_alive()) {
    result->Error("DISPOSED", "Plugin has been disposed.");
    return;
  }
  if (method_call.method_name().compare("getPlatformVersion") == 0) {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
  } else {
    result->NotImplemented();
  }
}

}  // namespace flutter_thermal_printer

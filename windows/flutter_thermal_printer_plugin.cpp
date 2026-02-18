#include "flutter_thermal_printer_plugin.h"

#include <windows.h>
#include <VersionHelpers.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>

namespace flutter_thermal_printer {

// --- Registration: ONLY register. No BLE, WinRT, COM, threads, or globals. ---
void FlutterThermalPrinterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_thermal_printer",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterThermalPrinterPlugin>();

  channel->SetMethodCallHandler(
      [plugin_ptr = plugin.get()](const auto &call, auto result) {
        if (!plugin_ptr->is_alive()) {
          result->Error("DISPOSED", "Plugin disposed.");
          return;
        }
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

// Constructor must do NOTHING. No WinRT, COM, BLE, or threads.
FlutterThermalPrinterPlugin::FlutterThermalPrinterPlugin() {}

// Full cleanup: mark dead first so no callback touches us; no watchers/threads here.
FlutterThermalPrinterPlugin::~FlutterThermalPrinterPlugin() {
  alive_.store(false, std::memory_order_release);
}

void FlutterThermalPrinterPlugin::EnsureInitialized() {
  // This plugin has no native BLE/WinRT; nothing to lazy-init.
}

void FlutterThermalPrinterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!is_alive()) {
    result->Error("DISPOSED", "Plugin disposed.");
    return;
  }
  EnsureInitialized();
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

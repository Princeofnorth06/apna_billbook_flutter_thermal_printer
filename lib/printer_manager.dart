// ignore_for_file: prefer_foreach

import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';

import 'Windows/windows_platform.dart'
    if (dart.library.html) 'Windows/windows_stub.dart';
import 'flutter_thermal_printer_platform_interface.dart';
import 'utils/ble_config.dart';
import 'utils/printer.dart';

/// Printer manager for USB and network. BLE not supported (universal_ble removed).
class PrinterManager {
  PrinterManager._privateConstructor();

  static PrinterManager? _instance;

  // ignore: prefer_constructors_over_static_methods
  static PrinterManager get instance {
    _instance ??= PrinterManager._privateConstructor();
    return _instance!;
  }

  BleConfig bleConfig = const BleConfig();

  final StreamController<List<Printer>> _devicesStream =
      StreamController<List<Printer>>.broadcast();

  Stream<List<Printer>> get devicesStream => _devicesStream.stream;

  StreamSubscription? _bleSubscription;
  StreamSubscription? _usbSubscription;
  StreamSubscription? _bleAvailabilitySubscription;
  final Map<String, StreamSubscription<bool>> _bleConnectionSubscriptions =
      <String, StreamSubscription<bool>>{};
  Timer? _bleStateSyncTimer;

  static const String _channelName = 'flutter_thermal_printer/events';
  final EventChannel _eventChannel = const EventChannel(_channelName);

  final List<Printer> _devices = [];

  /// Initialize the manager (BLE not supported).
  Future<void> initialize() async {}

  /// Stop scanning (BLE not supported; USB subscriptions cancelled).
  Future<void> stopScan({
    bool stopBle = true,
    bool stopUsb = true,
  }) async {
    try {
      if (stopBle) {
        await _stopBleStateSync();
        await _bleSubscription?.cancel();
        _bleSubscription = null;
      }
      if (stopUsb) {
        await _usbSubscription?.cancel();
        _usbSubscription = null;
      }
    } catch (e) {
      log('Failed to stop scanning for devices: $e');
    }
  }

  /// Dispose all resources
  Future<void> dispose() async {
    await stopScan();
    await _bleAvailabilitySubscription?.cancel();
    await _devicesStream.close();
  }

  /// Connect to a printer device
  ///
  /// [device] The printer device to connect to.
  /// [connectionStabilizationDelay] Optional delay to wait after connection is established
  /// before considering it stable. Defaults to [BleConfig.connectionStabilizationDelay].
  Future<bool> connect(
    Printer device, {
    Duration? connectionStabilizationDelay,
  }) async {
    if (device.connectionType == ConnectionType.USB) {
      if (Platform.isWindows) {
        // Windows USB connection - device is already available, no connection needed
        return true;
      } else {
        return FlutterThermalPrinterPlatform.instance.connect(device);
      }
    } else if (device.connectionType == ConnectionType.BLE) {
      log('BLE not supported (universal_ble removed)');
      return false;
    }
    return false;
  }

  /// Check if a device is connected
  Future<bool> isConnected(Printer device) async {
    if (device.connectionType == ConnectionType.USB) {
      if (Platform.isWindows) {
        // For Windows USB printers, they're always "connected" if they're available
        return true;
      } else {
        return FlutterThermalPrinterPlatform.instance.isConnected(device);
      }
    } else if (device.connectionType == ConnectionType.BLE) {
      return false;
    }
    return false;
  }

  /// Disconnect from a printer device (USB does not require explicit disconnect).
  Future<void> disconnect(Printer device) async {}

  /// Print data to printer device
  Future<void> printData(
    Printer printer,
    List<int> bytes, {
    bool longData = false,
    int? chunkSize,
  }) async {
    if (printer.connectionType == ConnectionType.USB) {
      if (Platform.isWindows) {
        // Windows USB printing using Win32 API
        using((alloc) {
          RawPrinter(printer.name!, alloc).printEscPosWin32(bytes);
        });
        return;
      } else {
        // Non-Windows USB printing
        try {
          await FlutterThermalPrinterPlatform.instance.printText(
            printer,
            Uint8List.fromList(bytes),
            path: printer.address,
          );
        } catch (e) {
          log('FlutterThermalPrinter: Unable to Print Data $e');
        }
      }
    } else if (printer.connectionType == ConnectionType.BLE) {
      log('BLE printing not supported (universal_ble removed)');
    }
  }

  /// Get Printers from BT and USB
  Future<void> getPrinters({
    Duration refreshDuration = const Duration(seconds: 2),
    List<ConnectionType> connectionTypes = const [
      ConnectionType.USB,
    ],
    bool androidUsesFineLocation = false,
  }) async {
    if (connectionTypes.isEmpty) {
      throw Exception('No connection type provided');
    }

    if (connectionTypes.contains(ConnectionType.USB)) {
      await _getUSBPrinters(refreshDuration);
    }

    if (connectionTypes.contains(ConnectionType.BLE)) {
      // BLE not supported (universal_ble removed)
    }
  }

  /// USB printer discovery for all platforms
  Future<void> _getUSBPrinters(Duration refreshDuration) async {
    try {
      if (Platform.isWindows) {
        // Windows USB printer discovery using Win32 API
        await _usbSubscription?.cancel();
        _usbSubscription =
            Stream.periodic(refreshDuration, (x) => x).listen((event) async {
          final devices = PrinterNames(PRINTER_ENUM_LOCAL);
          final tempList = <Printer>[];

          for (final printerName in devices.all()) {
            final device = Printer(
              vendorId: printerName,
              productId: 'N/A',
              name: printerName,
              connectionType: ConnectionType.USB,
              address: printerName,
              isConnected: true,
            );
            tempList.add(device);
          }

          // Update devices list and stream
          for (final printer in tempList) {
            _updateOrAddPrinter(printer);
          }
          sortDevices();
        });
      } else {
        // Non-Windows USB printer discovery
        final devices =
            await FlutterThermalPrinterPlatform.instance.startUsbScan();

        final usbPrinters = <Printer>[];
        for (final map in devices) {
          final printer = Printer(
            vendorId: map['vendorId'].toString(),
            productId: map['productId'].toString(),
            name: map['name'],
            connectionType: ConnectionType.USB,
            address: map['vendorId'].toString(),
            isConnected: false,
          );
          final isConnected =
              await FlutterThermalPrinterPlatform.instance.isConnected(
            printer,
          );
          usbPrinters.add(printer.copyWith(isConnected: isConnected));
        }

        for (final printer in usbPrinters) {
          _updateOrAddPrinter(printer);
        }
        if (Platform.isAndroid) {
          await _usbSubscription?.cancel();
          _usbSubscription =
              _eventChannel.receiveBroadcastStream().listen((event) {
            final map = Map<String, dynamic>.from(event);
            _updateOrAddPrinter(
              Printer(
                vendorId: map['vendorId'].toString(),
                productId: map['productId'].toString(),
                name: map['name'],
                connectionType: ConnectionType.USB,
                address: map['vendorId'].toString(),
                isConnected: map['connected'] ?? false,
              ),
            );
          });
        } else {
          await _usbSubscription?.cancel();
          _usbSubscription =
              Stream.periodic(refreshDuration, (x) => x).listen((event) async {
            final devices =
                await FlutterThermalPrinterPlatform.instance.startUsbScan();

            final usbPrinters = <Printer>[];
            for (final map in devices) {
              final printer = Printer(
                vendorId: map['vendorId'].toString(),
                productId: map['productId'].toString(),
                name: map['name'],
                connectionType: ConnectionType.USB,
                address: map['vendorId'].toString(),
                isConnected: false,
              );
              final isConnected =
                  await FlutterThermalPrinterPlatform.instance.isConnected(
                printer,
              );
              usbPrinters.add(printer.copyWith(isConnected: isConnected));
            }

            for (final printer in usbPrinters) {
              _updateOrAddPrinter(printer);
            }
            sortDevices();
          });
        }

        sortDevices();
      }
    } catch (e) {
      log('$e [USB Connection]');
    }
  }

  /// Update or add printer to the devices list
  void _updateOrAddPrinter(Printer printer) {
    final index = _devices.indexWhere(
      (device) =>
          device.connectionType == printer.connectionType &&
          device.address == printer.address,
    );
    if (index == -1) {
      _devices.add(printer);
    } else {
      _devices[index] = printer;
    }
    sortDevices();
  }

  Future<void> _stopBleStateSync() async {
    _bleStateSyncTimer?.cancel();
    _bleStateSyncTimer = null;

    final subscriptions = _bleConnectionSubscriptions.values.toList();
    _bleConnectionSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  /// Sort and filter devices
  void sortDevices() {
    _devices
        .removeWhere((element) => element.name == null || element.name == '');
    // remove items having same vendorId
    final seen = <String>{};
    _devices.retainWhere((element) {
      final uniqueKey = '${element.vendorId}_${element.address}';
      if (seen.contains(uniqueKey)) {
        return false; // Remove duplicate
      } else {
        seen.add(uniqueKey); // Mark as seen
        return true; // Keep
      }
    });
    _devicesStream.add(_devices);
  }

  /// BLE not supported (universal_ble removed).
  Future<void> turnOnBluetooth() async {}

  /// BLE not supported; always false.
  Stream<bool> get isBleTurnedOnStream => Stream.value(false);

  /// BLE not supported; always false.
  Future<bool> isBleTurnedOn() async => false;
}

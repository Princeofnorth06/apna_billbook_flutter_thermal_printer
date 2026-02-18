// ignore_for_file: constant_identifier_names

/// Connection type for a printer (BLE removed; USB and NETWORK only).
enum ConnectionType {
  BLE,
  USB,
  NETWORK,
}

/// Printer model with data validation and serialization.
/// BLE is not supported (universal_ble removed); use USB or NETWORK.
class Printer {
  Printer({
    this.address,
    this.name,
    this.connectionType,
    this.isConnected,
    this.vendorId,
    this.productId,
  });

  /// Create Printer from JSON with validation
  factory Printer.fromJson(Map<String, dynamic> json) {
    try {
      return Printer(
        address: json['address'] as String?,
        name: json['name'] as String?,
        connectionType:
            _getConnectionTypeFromString(json['connectionType'] as String?),
        isConnected: json['isConnected'] as bool?,
        vendorId: json['vendorId']?.toString(),
        productId: json['productId']?.toString(),
      );
    } catch (e) {
      throw FormatException('Invalid Printer JSON format: $e');
    }
  }

  final String? name;
  final String? address;
  final ConnectionType? connectionType;
  final bool? isConnected;
  final String? vendorId;
  final String? productId;

  /// Alias for [address] (API compatibility).
  String get deviceId => address ?? '';

  /// Convert to JSON with proper formatting
  Map<String, dynamic> toJson() {
    final data = <String, dynamic>{};
    data['address'] = address;
    data['name'] = name;
    data['connectionType'] = connectionType?.name;
    data['isConnected'] = isConnected;
    data['vendorId'] = vendorId;
    data['productId'] = productId;
    return data;
  }

  String get connectionTypeString {
    switch (connectionType) {
      case ConnectionType.BLE:
        return 'BLE';
      case ConnectionType.USB:
        return 'USB';
      case ConnectionType.NETWORK:
        return 'NETWORK';
      default:
        return 'UNKNOWN';
    }
  }

  Printer copyWith({
    String? address,
    String? name,
    ConnectionType? connectionType,
    bool? isConnected,
    String? vendorId,
    String? productId,
  }) =>
      Printer(
        address: address ?? this.address,
        name: name ?? this.name,
        connectionType: connectionType ?? this.connectionType,
        isConnected: isConnected ?? this.isConnected,
        vendorId: vendorId ?? this.vendorId,
        productId: productId ?? this.productId,
      );

  String get uniqueId {
    final buffer = StringBuffer();
    if (vendorId != null) {
      buffer.write(vendorId);
    }
    buffer.write('_');
    if (address != null) {
      buffer.write(address);
    }
    return buffer.toString();
  }

  bool get hasValidConnectionData {
    switch (connectionType) {
      case ConnectionType.USB:
        return vendorId != null && productId != null;
      case ConnectionType.BLE:
        return address != null;
      case ConnectionType.NETWORK:
        return address != null;
      default:
        return false;
    }
  }

  @override
  String toString() =>
      'Printer(name: $name, connectionType: ${connectionType?.name}, '
      'address: $address, isConnected: $isConnected)';

  // --- Stubs (BLE not supported; universal_ble removed) ---
  Future<void> connect() async {}
  Future<void> disconnect() async {}
  Stream<bool> get connectionStream => const Stream<bool>.empty();
  Future<List<dynamic>> discoverServices() async => [];
  Future<int> requestMtu(int mtu) async => 0;

  static ConnectionType? _getConnectionTypeFromString(String? type) {
    if (type == null) {
      return null;
    }
    switch (type.toUpperCase()) {
      case 'BLE':
        return ConnectionType.BLE;
      case 'USB':
        return ConnectionType.USB;
      case 'NETWORK':
        return ConnectionType.NETWORK;
      default:
        return null;
    }
  }
}

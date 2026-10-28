import 'dart:typed_data';

class PrinterDevice {
  final String id;
  final String name;
  final int? rssi;
  const PrinterDevice({required this.id, required this.name, this.rssi});
  bool get likelyT02 => name.toUpperCase().contains('T02');
}

/// A connection must expose validated FF00/FF02/FF03 characteristics and deliver
/// notifications before connect() completes. Writes must respect OS backpressure.
abstract interface class T02Transport {
  Stream<PrinterDevice> get discoveries;
  Stream<Uint8List> get notifications;
  Stream<void> get disconnections;
  Future<void> startScan();
  Future<void> stopScan();

  /// Returns the maximum write payload (ATT MTU minus three), not the MTU.
  Future<int> connect(PrinterDevice device);
  Future<void> write(Uint8List bytes);
  Future<void> disconnect();
  Future<void> dispose();
}

class T02Exception implements Exception {
  final String code;
  final String message;
  const T02Exception(this.code, this.message);
  @override
  String toString() => message;
}

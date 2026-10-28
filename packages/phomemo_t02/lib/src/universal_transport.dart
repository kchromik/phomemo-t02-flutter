import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';
import 'protocol.dart';
import 'transport.dart';

/// One active printer per instance. The underlying universal_ble command queue
/// and CoreBluetooth canSendWriteWithoutResponse handle native backpressure.
class UniversalBleTransport implements T02Transport {
  final _found = StreamController<PrinterDevice>.broadcast(sync: true);
  final _received = StreamController<Uint8List>.broadcast(sync: true);
  final _lost = StreamController<void>.broadcast(sync: true);
  StreamSubscription<BleDevice>? _scan;
  StreamSubscription<Uint8List>? _notify;
  StreamSubscription<bool>? _connection;
  String? _id;
  bool _scanning = false;
  int _scanGeneration = 0, _connectionGeneration = 0;
  @override
  Stream<PrinterDevice> get discoveries => _found.stream;
  @override
  Stream<Uint8List> get notifications => _received.stream;
  @override
  Stream<void> get disconnections => _lost.stream;

  Future<void> _permissions() async {
    await UniversalBle.requestPermissions(); // Location is requested automatically on Android <= 30.
    var state = await UniversalBle.getBluetoothAvailabilityState();
    if (state == AvailabilityState.unknown ||
        state == AvailabilityState.resetting) {
      state = await UniversalBle.availabilityStream
          .firstWhere(
            (s) =>
                s != AvailabilityState.unknown &&
                s != AvailabilityState.resetting,
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => AvailabilityState.unknown,
          );
    }
    if (state != AvailabilityState.poweredOn) {
      throw T02Exception('bluetooth', switch (state) {
        AvailabilityState.unauthorized =>
          'Bluetooth access denied. Please allow it in settings.',
        AvailabilityState.poweredOff => 'Please turn on Bluetooth.',
        AvailabilityState.unsupported =>
          'This device does not support Bluetooth LE.',
        _ => 'Bluetooth is not ready yet. Please try again.',
      });
    }
  }

  @override
  Future<void> startScan() async {
    await stopScan();
    final generation = ++_scanGeneration;
    await _permissions();
    if (generation != _scanGeneration) return;
    _scan = UniversalBle.scanStream.listen((d) {
      if (d.connectable == false) return;
      _found.add(
        PrinterDevice(
          id: d.deviceId,
          name: d.name?.isNotEmpty == true ? d.name! : 'Unnamed device',
          rssi: d.rssi,
        ),
      );
    }, onError: _found.addError);
    // The app advertises AF30/1812 on some models; FF00 filtering misses them.
    try {
      _scanning = true;
      await UniversalBle.startScan();
      if (generation != _scanGeneration) await UniversalBle.stopScan();
    } catch (_) {
      await _scan?.cancel();
      _scan = null;
      rethrow;
    }
  }

  @override
  Future<void> stopScan() async {
    ++_scanGeneration;
    if (_scanning) await UniversalBle.stopScan();
    _scanning = false;
    await _scan?.cancel();
    _scan = null;
  }

  @override
  Future<int> connect(PrinterDevice device) async {
    await disconnect();
    final generation = _connectionGeneration;
    void check() {
      if (generation != _connectionGeneration) {
        throw const T02Exception('cancelled', 'Connection cancelled.');
      }
    }

    await stopScan();
    check();
    await _permissions();
    check();
    _id = device.id;
    _connection = UniversalBle.connectionStream(device.id).listen((connected) {
      if (!connected) _lost.add(null);
    }, onError: _lost.addError);
    try {
      await UniversalBle.connect(
        device.id,
        timeout: const Duration(seconds: 15),
      );
      check();
      final services = await UniversalBle.discoverServices(device.id);
      check();
      final service = services
          .where((s) => s.uuid.toLowerCase() == T02Protocol.service)
          .firstOrNull;
      final tx = service?.characteristics
          .where((c) => c.uuid.toLowerCase() == T02Protocol.write)
          .firstOrNull;
      final rx = service?.characteristics
          .where((c) => c.uuid.toLowerCase() == T02Protocol.notify)
          .firstOrNull;
      if (tx == null ||
          rx == null ||
          !tx.properties.contains(
            CharacteristicProperty.writeWithoutResponse,
          ) ||
          !rx.properties.contains(CharacteristicProperty.notify)) {
        throw const T02Exception(
          'gatt',
          'Not a compatible T02: missing FF00 / FF02 (Write Without Response) / FF03 (Notify).',
        );
      }
      _notify = UniversalBle.characteristicValueStream(
        device.id,
        T02Protocol.notify,
      ).listen(_received.add, onError: _received.addError);
      var payload = 20;
      try {
        payload = math.max(
          20,
          await UniversalBle.requestMtu(device.id, 185) - 3,
        );
      } catch (_) {
        /* Valid default ATT payload. */
      }
      check();
      await UniversalBle.subscribeNotifications(
        device.id,
        T02Protocol.service,
        T02Protocol.notify,
      );
      check();
      return payload;
    } catch (_) {
      // A cancelled native connect can complete late; close that link too.
      _id ??= device.id;
      try {
        await disconnect();
      } catch (_) {
        /* Preserve the original error. */
      }
      rethrow;
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final id = _id;
    if (id == null) {
      throw const T02Exception('disconnected', 'No printer connection.');
    }
    await UniversalBle.write(
      id,
      T02Protocol.service,
      T02Protocol.write,
      bytes,
      withoutResponse: true,
      timeout: const Duration(seconds: 8),
    );
  }

  @override
  Future<void> disconnect() async {
    ++_connectionGeneration;
    final id = _id;
    _id = null;
    await _notify?.cancel();
    await _connection?.cancel();
    _notify = null;
    _connection = null;
    if (id != null) {
      await UniversalBle.disconnect(id, timeout: const Duration(seconds: 5));
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await stopScan();
    } finally {
      try {
        await disconnect();
      } finally {
        await _found.close();
        await _received.close();
        await _lost.close();
      }
    }
  }
}

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'bitmap.dart';
import 'protocol.dart';
import 'transport.dart';

enum PrinterPhase {
  disconnected,
  connecting,
  initializing,
  ready,
  printing,
  waiting,
}

enum FlowControl { credits, experimentalPaced }

enum PrintOutcome { confirmed, sentUnconfirmed }

class PrinterSnapshot {
  final PrinterPhase phase;
  final PrinterDevice? device;
  final int credits, packetSize, bytesSent, totalBytes;
  final bool? paperPresent, coverClosed, temperatureNormal;
  final String? message;
  const PrinterSnapshot({
    required this.phase,
    this.device,
    required this.credits,
    required this.packetSize,
    required this.bytesSent,
    required this.totalBytes,
    this.paperPresent,
    this.coverClosed,
    this.temperatureNormal,
    this.message,
  });
  double get progress => totalBytes == 0 ? 0 : bytesSent / totalBytes;
  bool get isPrinting =>
      phase == PrinterPhase.printing || phase == PrinterPhase.waiting;
}

class DiagnosticEntry {
  final DateTime time;
  final String kind, message;
  final List<int>? bytes;
  DiagnosticEntry(this.kind, this.message, [List<int>? data])
    : time = DateTime.now(),
      bytes = data == null ? null : List.unmodifiable(data);
  Map<String, Object?> toJson() => {
    'time': time.toIso8601String(),
    'kind': kind,
    'message': message,
    if (bytes != null)
      'hex': bytes!.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '),
  };
}

/// Foreground, single-job client. A failed or unconfirmed job disconnects: a
/// partial raster stream must not be followed by a new job on the same link.
class T02Client {
  final T02Transport transport;
  final Duration creditTimeout, completionTimeout;

  /// Optional extra pacing for credit-controlled writes. Normally the printer's
  /// credits and the awaited transport write provide all necessary backpressure.
  final Duration packetInterval;

  /// The diagnostic mode has no printer credits, so it keeps separate pacing.
  final Duration experimentalPacketInterval;
  T02Client({
    required this.transport,
    this.creditTimeout = const Duration(seconds: 8),
    this.completionTimeout = const Duration(seconds: 20),
    this.packetInterval = Duration.zero,
    this.experimentalPacketInterval = const Duration(milliseconds: 200),
  }) {
    _rx = transport.notifications.listen(
      _receive,
      onError: (Object e) => _fail('BLE receive: $e'),
    );
    _lost = transport.disconnections.listen(
      (_) => _fail('Disconnected.'),
      onError: (Object e) => _fail('Bluetooth: $e'),
    );
  }
  final _updates = StreamController<PrinterSnapshot>.broadcast(sync: true);
  final _logUpdates = StreamController<DiagnosticEntry>.broadcast(sync: true);
  final _decoder = T02ReplyDecoder();
  final _log = Queue<DiagnosticEntry>();
  late final StreamSubscription<Uint8List> _rx;
  late final StreamSubscription<void> _lost;
  PrinterPhase _phase = PrinterPhase.disconnected;
  PrinterDevice? _device;
  FlowControl _flow = FlowControl.credits;
  int _credits = 0, _osPayload = 20, _printerPayload = 20;
  int _sent = 0, _total = 0, _epoch = 0;
  int _jobPackets = 0;
  bool _busy = false,
      _disposed = false,
      _completionArmed = false,
      _complete = false;
  bool? _paper, _cover, _temperature;
  String? _message, _failure;
  Completer<void> _signal = Completer<void>();

  Stream<PrinterSnapshot> get states => _updates.stream;
  Stream<DiagnosticEntry> get diagnostics => _logUpdates.stream;
  Stream<PrinterDevice> get discoveries => transport.discoveries;
  List<DiagnosticEntry> get log => List.unmodifiable(_log);
  Duration get _sendInterval => _flow == FlowControl.experimentalPaced
      ? experimentalPacketInterval
      : packetInterval;
  int get _packetSize => math.max(
    1,
    math.min(
      _osPayload,
      _flow == FlowControl.experimentalPaced ? 20 : _printerPayload,
    ),
  );
  PrinterSnapshot get snapshot => PrinterSnapshot(
    phase: _phase,
    device: _device,
    credits: _credits,
    packetSize: _packetSize,
    bytesSent: _sent,
    totalBytes: _total,
    paperPresent: _paper,
    coverClosed: _cover,
    temperatureNormal: _temperature,
    message: _message,
  );

  void _emit() {
    if (!_disposed) _updates.add(snapshot);
  }

  void _record(String kind, String message, [List<int>? bytes]) {
    if (_disposed) return;
    final entry = DiagnosticEntry(kind, message, bytes);
    _log.add(entry);
    while (_log.length > 600) {
      _log.removeFirst();
    }
    _logUpdates.add(entry);
  }

  String exportDiagnostics() => const JsonEncoder.withIndent('  ').convert({
    'sdk': 'phomemo_t02/0.1.1',
    'flowControl': _flow.name,
    'packetSize': _packetSize,
    'osPayload': _osPayload,
    'printerPayload': _printerPayload,
    'packetIntervalMs': _sendInterval.inMicroseconds / 1000,
    'device': _device?.name,
    'state': _phase.name,
    'entries': _log.map((e) => e.toJson()).toList(),
  });
  void _wake() {
    if (!_signal.isCompleted) _signal.complete();
    _signal = Completer<void>();
  }

  void _check(int epoch) {
    if (_disposed || epoch != _epoch) {
      throw const T02Exception('cancelled', 'Operation cancelled.');
    }
    if (_failure != null) throw T02Exception('printer', _failure!);
  }

  void _fail(String message) {
    if (_phase == PrinterPhase.disconnected) return;
    _failure = _message = message;
    _record('error', message);
    _phase = PrinterPhase.disconnected;
    _wake();
    _emit();
  }

  void _receive(Uint8List bytes) {
    if (_phase == PrinterPhase.disconnected || _disposed) return;
    _record('rx', '${bytes.length} Bytes', bytes);
    for (final reply in _decoder.add(bytes)) {
      switch (reply.kind) {
        case ReplyKind.credits:
          _credits = math.min(65535, _credits + reply.value);
        case ReplyKind.packetLimit:
          if (reply.value > 0) _printerPayload = reply.value;
        case ReplyKind.paperPresent:
          _paper = reply.value == 1;
        case ReplyKind.coverClosed:
          _cover = reply.value == 1;
        case ReplyKind.temperatureNormal:
          _temperature = reply.value == 1;
        case ReplyKind.cancelled:
          if (_phase == PrinterPhase.printing ||
              _phase == PrinterPhase.waiting) {
            _failure = 'The printer cancelled the job.';
          }
        case ReplyKind.complete:
          if (_completionArmed) {
            _complete = true;
          } else {
            _record(
              'info',
              'Ignored print completion outside the completion window.',
            );
          }
        case ReplyKind.unknown:
          _record(
            'unknown',
            'Unknown reply, logged without modification.',
            reply.bytes,
          );
      }
    }
    _wake();
    _emit();
  }

  String? get _blockingStatus => _paper == false
      ? 'Printer is out of paper.'
      : _cover == false
      ? 'Please close the printer cover.'
      : _temperature == false
      ? 'Print head is too hot. Please let it cool down.'
      : null;

  Future<void> startScan() async {
    if (_busy || _phase != PrinterPhase.disconnected) {
      throw const T02Exception(
        'busy',
        'Disconnect the current connection first.',
      );
    }
    _record('info', 'BLE scan started.');
    await transport.startScan();
  }

  Future<void> stopScan() => transport.stopScan();

  Future<void> connect(
    PrinterDevice device, {
    FlowControl flowControl = FlowControl.credits,
  }) async {
    if (_disposed || _busy || _phase != PrinterPhase.disconnected) {
      throw const T02Exception('busy', 'An operation is already running.');
    }
    _busy = true;
    final epoch = ++_epoch;
    _device = device;
    _flow = flowControl;
    _credits = 0;
    _osPayload = 20;
    _printerPayload = 20;
    _sent = 0;
    _total = 0;
    _failure = null;
    _message = null;
    _paper = null;
    _cover = null;
    _temperature = null;
    _complete = false;
    _completionArmed = false;
    _decoder.reset();
    _phase = PrinterPhase.connecting;
    _record('info', 'Connecting to ${device.name}; ${flowControl.name}.');
    _emit();
    try {
      _osPayload = await transport.connect(device);
      _check(epoch);
      if (_osPayload < 1) {
        throw const T02Exception('mtu', 'Invalid BLE packet limit.');
      }
      _phase = PrinterPhase.initializing;
      _record(
        'info',
        'GATT ready; OS payload $_osPayload. Handshake: 33 Bytes.',
      );
      _emit();
      await _send(
        Uint8List.fromList(T02Protocol.handshake),
        epoch,
        isJob: false,
      );
      _check(epoch);
      _phase = PrinterPhase.ready;
      _message = 'Ready';
      _record('info', 'Initialization sent.');
      _emit();
    } catch (e) {
      _record('error', e.toString());
      await _drop(e.toString());
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<PrintOutcome> print(MonoBitmap bitmap, {int feed = 4}) async {
    if (_disposed || _busy || _phase != PrinterPhase.ready) {
      throw const T02Exception('busy', 'Printer is not ready yet.');
    }
    final blocked = _blockingStatus;
    if (blocked != null) throw T02Exception('status', blocked);
    final data = T02Protocol.printJob(bitmap, feed: feed);
    _busy = true;
    final epoch = _epoch;
    _sent = 0;
    _total = data.length;
    _complete = false;
    _completionArmed = false;
    _phase = PrinterPhase.printing;
    _message = 'Sending data';
    _record(
      'job',
      '384 × ${bitmap.height}; ${data.length} Bytes; feed $feed; '
          '${_flow.name}; packet limit $_packetSize; '
          'extra delay ${_sendInterval.inMicroseconds / 1000} ms.',
    );
    _emit();
    try {
      _jobPackets = 0;
      final transferWatch = Stopwatch()..start();
      await _send(data, epoch, isJob: true);
      transferWatch.stop();
      final elapsed = transferWatch.elapsedMicroseconds;
      _record(
        'transfer',
        '$_sent bytes passed to BLE in $_jobPackets packets; '
            '${(elapsed / 1000).toStringAsFixed(1)} ms; '
            '${elapsed > 0 ? (_sent * 1000000 / elapsed).round() : 0} Bytes/s; '
            '${_flow.name}; extra delay ${_sendInterval.inMicroseconds / 1000} ms. '
            'Print confirmation is handled separately.',
      );
      _check(epoch);
      if (_blockingStatus != null) {
        throw T02Exception('status', _blockingStatus!);
      }
      _phase = PrinterPhase.waiting;
      _message = 'Waiting for print confirmation';
      _emit();
      final end = DateTime.now().add(completionTimeout);
      while (!_complete) {
        _check(epoch);
        final blocked = _blockingStatus;
        if (blocked != null) throw T02Exception('status', blocked);
        final left = end.difference(DateTime.now());
        if (left <= Duration.zero) {
          _record(
            'result',
            'Data sent, completion not confirmed. Reconnect before the next job.',
          );
          await _drop('Sent · completion not confirmed');
          return PrintOutcome.sentUnconfirmed;
        }
        await _signal.future.timeout(left, onTimeout: () {});
      }
      _check(epoch);
      _phase = PrinterPhase.ready;
      _message = 'Print confirmed by T02';
      _record('result', 'Received print completion 1A 0F 0C.');
      _emit();
      return PrintOutcome.confirmed;
    } catch (e) {
      _record('error', e.toString());
      await _drop(e.toString());
      rethrow;
    } finally {
      _completionArmed = false;
      _busy = false;
    }
  }

  Future<void> _send(Uint8List data, int epoch, {required bool isJob}) async {
    var offset = 0;
    while (offset < data.length) {
      _check(epoch);
      final blocked = _blockingStatus;
      if (isJob && blocked != null) throw T02Exception('status', blocked);
      if (_flow == FlowControl.credits) {
        final end = DateTime.now().add(creditTimeout);
        while (_credits == 0) {
          _check(epoch);
          if (isJob && _blockingStatus != null) {
            throw T02Exception('status', _blockingStatus!);
          }
          final left = end.difference(DateTime.now());
          if (left <= Duration.zero) {
            throw const T02Exception(
              'credits',
              'No credits from the T02. Disconnected. See the log for details.',
            );
          }
          await _signal.future.timeout(left, onTimeout: () {});
        }
        _credits--;
      }
      _check(epoch);
      final end = math.min(offset + _packetSize, data.length);
      final chunk = Uint8List.sublistView(data, offset, end);
      if (isJob && end == data.length) _completionArmed = true;
      await transport.write(chunk);
      _check(epoch);
      offset = end;
      if (isJob) {
        _sent = offset;
        _jobPackets++;
      }
      // Limit payload logging to 24 bytes: sufficient framing diagnostics without
      // retaining every printed document in the diagnostic export.
      _record(
        'tx',
        '${chunk.length} Bytes${chunk.length > 24 ? ' (prefix)' : ''}',
        chunk.take(24).toList(),
      );
      _emit();
      if (offset < data.length && _sendInterval > Duration.zero) {
        // Credit mode normally needs no timer: credits bound the printer queue,
        // and awaiting write() respects the operating system's own readiness.
        await Future<void>.delayed(_sendInterval);
      }
    }
  }

  Future<void> _drop(String message) async {
    ++_epoch;
    _phase = PrinterPhase.disconnected;
    _message = message;
    _completionArmed = false;
    _credits = 0;
    _wake();
    _emit();
    try {
      await transport.disconnect();
    } catch (e) {
      _record('error', 'Disconnect: $e');
    }
  }

  /// Stops further writes and disconnects. Already buffered paper may still print.
  Future<void> disconnect() async {
    _record('info', 'Disconnected by user.');
    await _drop('Disconnected');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    await _rx.cancel();
    await _lost.cancel();
    await transport.dispose();
    await _updates.close();
    await _logUpdates.close();
  }
}

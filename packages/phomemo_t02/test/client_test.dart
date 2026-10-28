import 'dart:async';
import 'dart:typed_data';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phomemo_t02/phomemo_t02.dart';

class FakeTransport implements T02Transport {
  final rx = StreamController<Uint8List>.broadcast(sync: true);
  final lost = StreamController<void>.broadcast(sync: true);
  final found = StreamController<PrinterDevice>.broadcast(sync: true);
  final writes = <List<int>>[];
  List<int> initial = [2, 182, 0, 1, 250];
  int osPayload = 97;
  int disconnects = 0;
  Future<void> Function(Uint8List)? onWrite;
  void emit(List<int> data) => rx.add(Uint8List.fromList(data));
  @override
  Stream<PrinterDevice> get discoveries => found.stream;
  @override
  Stream<Uint8List> get notifications => rx.stream;
  @override
  Stream<void> get disconnections => lost.stream;
  @override
  Future<void> startScan() async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<int> connect(PrinterDevice d) async {
    emit(initial);
    return osPayload;
  }

  @override
  Future<void> write(Uint8List data) async {
    writes.add(data.toList());
    await onWrite?.call(data);
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<void> dispose() async {
    await rx.close();
    await lost.close();
    await found.close();
  }
}

const device = PrinterDevice(id: 'test', name: 'T02');
final tiny = MonoBitmap.fromPixels(3, (x, y) => x == y);

void main() {
  late FakeTransport transport;
  late T02Client client;
  setUp(() {
    transport = FakeTransport();
    client = T02Client(
      transport: transport,
      packetInterval: Duration.zero,
      creditTimeout: const Duration(milliseconds: 40),
      completionTimeout: const Duration(milliseconds: 40),
    );
  });
  tearDown(() async {
    await client.dispose();
  });

  test('default credit mode sends a complete photo without timer pauses', () {
    fakeAsync((clock) {
      final link = FakeTransport()
        ..osPayload = 182
        ..initial = [2, 182, 0, 1, 200];
      final fastClient = T02Client(transport: link);
      final photo = MonoBitmap.fromPixels(416, (x, y) => (x + y).isEven);
      final expected = T02Protocol.printJob(photo);
      PrintOutcome? outcome;
      var jobBytes = 0;
      fastClient.connect(device).then((_) async {
        link.writes.clear();
        link.onWrite = (data) async {
          jobBytes += data.length;
          if (jobBytes == expected.length) link.emit([0x1a, 15, 12]);
        };
        outcome = await fastClient.print(photo);
      });
      // Only resolve Futures, without advancing time. The old 200 ms delay
      // would stall this job after its first write.
      clock.flushMicrotasks();
      expect(outcome, PrintOutcome.confirmed);
      expect(clock.elapsed, Duration.zero);
      expect(link.writes.expand((chunk) => chunk), expected);
      expect(link.writes.length, (expected.length / 182).ceil());
      expect(link.writes.every((chunk) => chunk.length <= 182), isTrue);
      expect(fastClient.log.where((e) => e.kind == 'transfer').length, 1);
      expect(clock.pendingTimers, isEmpty);
      unawaited(fastClient.dispose());
      clock.flushMicrotasks();
    });
  });

  test('experimental mode still paces writes at 200 ms by default', () {
    fakeAsync((clock) {
      final link = FakeTransport()..initial = [];
      final pacedClient = T02Client(transport: link);
      var connected = false;
      pacedClient
          .connect(device, flowControl: FlowControl.experimentalPaced)
          .then((_) => connected = true);
      clock.flushMicrotasks();
      expect(link.writes.map((chunk) => chunk.length), [20]);
      clock.elapse(const Duration(milliseconds: 199));
      expect(link.writes.length, 1);
      expect(connected, isFalse);
      clock.elapse(const Duration(milliseconds: 1));
      expect(link.writes.map((chunk) => chunk.length), [20, 13]);
      expect(connected, isTrue);
      unawaited(pacedClient.dispose());
      clock.flushMicrotasks();
    });
  });

  test(
    'credit mode awaits transport readiness before sending another packet',
    () async {
      await client.connect(device);
      transport.writes.clear();
      final firstWrite = Completer<void>();
      final release = Completer<void>();
      final expected = T02Protocol.printJob(tiny);
      var sent = 0;
      transport.onWrite = (data) async {
        sent += data.length;
        if (!firstWrite.isCompleted) {
          firstWrite.complete();
          await release.future;
        }
        if (sent == expected.length) transport.emit([0x1a, 15, 12]);
      };
      final printing = client.print(tiny);
      await firstWrite.future;
      expect(transport.writes.length, 1);
      release.complete();
      expect(await printing, PrintOutcome.confirmed);
      expect(transport.writes.expand((chunk) => chunk), expected);
    },
  );

  test(
    'subscribe-time credits survive, writes respect OS limit, completion is distinct',
    () async {
      await client.connect(device);
      expect(transport.writes.single, T02Protocol.handshake);
      expect(client.snapshot.packetSize, 97);
      transport.writes.clear();
      final expected = T02Protocol.printJob(tiny);
      var sent = 0;
      transport.onWrite = (data) async {
        sent += data.length;
        if (sent == expected.length) transport.emit([0x1a, 15, 12]);
      };
      expect(await client.print(tiny), PrintOutcome.confirmed);
      expect(transport.writes.expand((e) => e), expected);
      expect(transport.writes.every((c) => c.length <= 97), true);
      expect(client.snapshot.bytesSent, expected.length);
      expect(client.snapshot.phase, PrinterPhase.ready);
      expect(client.snapshot.credits, 247);
    },
  );
  test('no initial credits: timeout and absolutely no write', () async {
    transport.initial = [2, 182, 0];
    await expectLater(
      client.connect(device),
      throwsA(isA<T02Exception>().having((e) => e.code, 'code', 'credits')),
    );
    expect(transport.writes, isEmpty);
    expect(client.snapshot.phase, PrinterPhase.disconnected);
    expect(transport.disconnects, 1);
  });
  test(
    'one credit permits one write, then waits for another notification',
    () async {
      transport.initial = [2, 20, 0, 1, 1];
      final connect = client.connect(device);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(transport.writes.length, 1);
      expect(transport.writes.single.length, 20);
      transport.emit([1, 1]);
      await connect;
      expect(transport.writes.last.length, 13);
      expect(client.snapshot.credits, 0);
    },
  );
  test('experimental pacing is opt-in and retains 20 byte ceiling', () async {
    transport.initial = [];
    await client.connect(device, flowControl: FlowControl.experimentalPaced);
    expect(transport.writes.map((c) => c.length), [20, 13]);
    expect(client.snapshot.credits, 0);
  });
  test(
    'reject concurrent jobs; disconnect interrupts an in-flight write',
    () async {
      await client.connect(device);
      transport.writes.clear();
      final gate = Completer<void>();
      transport.onWrite = (_) => gate.future;
      final first = client.print(tiny);
      final failure = expectLater(first, throwsA(isA<T02Exception>()));
      await expectLater(
        client.print(tiny),
        throwsA(isA<T02Exception>().having((e) => e.code, 'code', 'busy')),
      );
      await client.disconnect();
      gate.complete();
      await failure;
      expect(transport.writes.length, 1);
      expect(client.snapshot.phase, PrinterPhase.disconnected);
    },
  );
  test(
    'disconnect wakes a credit waiter without waiting for its timeout',
    () async {
      transport.initial = [];
      final connecting = client.connect(device);
      final error = expectLater(connecting, throwsA(isA<T02Exception>()));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await client.disconnect();
      await error;
      expect(transport.writes, isEmpty);
    },
  );
  test('unexpected link loss prevents further writes', () async {
    await client.connect(device);
    transport.writes.clear();
    transport.onWrite = (_) async {
      transport.lost.add(null);
    };
    await expectLater(client.print(tiny), throwsA(isA<T02Exception>()));
    expect(transport.writes.length, 1);
    expect(client.snapshot.phase, PrinterPhase.disconnected);
  });
  test(
    'paper-out aborts after current chunk, without automatic retry',
    () async {
      await client.connect(device);
      transport.writes.clear();
      transport.onWrite = (_) async {
        transport.emit([0x1a, 6, 0x88]);
      };
      await expectLater(
        client.print(tiny),
        throwsA(isA<T02Exception>().having((e) => e.code, 'code', 'status')),
      );
      expect(transport.writes.length, 1);
      expect(client.snapshot.paperPresent, false);
      expect(client.snapshot.phase, PrinterPhase.disconnected);
    },
  );
  test(
    'fault arriving with final completion is never reported as success',
    () async {
      await client.connect(device);
      var sent = 0;
      final total = T02Protocol.printJob(tiny).length;
      transport.onWrite = (data) async {
        sent += data.length;
        if (sent == total) transport.emit([0x1a, 6, 0x88, 0x1a, 15, 12]);
      };
      await expectLater(
        client.print(tiny),
        throwsA(isA<T02Exception>().having((e) => e.code, 'code', 'status')),
      );
      expect(client.snapshot.phase, PrinterPhase.disconnected);
    },
  );

  test('early completion cannot falsely confirm a later job', () async {
    transport.initial = [1, 250, 2, 182, 0, 0x1a, 15, 12];
    await client.connect(device);
    expect(await client.print(tiny), PrintOutcome.sentUnconfirmed);
    expect(client.snapshot.bytesSent, T02Protocol.printJob(tiny).length);
    expect(client.snapshot.phase, PrinterPhase.disconnected);
    // Late responses from the uncertain job cannot enter the next job on this link.
    transport.emit([0x1a, 15, 12]);
    await expectLater(client.print(tiny), throwsA(isA<T02Exception>()));
  });
  test('reconnect resets status, packet ceiling and credit budget', () async {
    await client.connect(device);
    transport.emit([0x1a, 5, 0x99]);
    await expectLater(client.print(tiny), throwsA(isA<T02Exception>()));
    await client.disconnect();
    transport.initial = [1, 10];
    await client.connect(device);
    expect(client.snapshot.coverClosed, null);
    expect(client.snapshot.packetSize, 20);
    expect(client.snapshot.credits, 8);
  });
}

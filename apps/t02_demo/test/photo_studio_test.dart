import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:phomemo_t02/phomemo_t02.dart';
import 'package:t02_demo/photo_camera.dart';
import 'package:t02_demo/photo_print.dart';
import 'package:t02_demo/photo_studio.dart';

class TestCamera implements PhotoCamera {
  int captures = 0, closes = 0;
  Completer<Uint8List>? pending;
  @override
  bool get canSwitch => true;
  @override
  Widget buildPreview() => const ColoredBox(
    color: Color(0xFF557261),
    child: Center(
      child: Icon(Icons.local_florist, size: 100, color: Colors.white),
    ),
  );
  @override
  Future<Uint8List> takePhoto() async {
    captures++;
    return pending?.future ?? Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<void> dispose() async {
    closes++;
  }
}

class TestTransport implements T02Transport {
  final rx = StreamController<Uint8List>.broadcast(sync: true);
  final lost = StreamController<void>.broadcast(sync: true);
  final writes = <int>[];
  int? expectedJobBytes;
  @override
  Stream<PrinterDevice> get discoveries => const Stream.empty();
  @override
  Stream<Uint8List> get notifications => rx.stream;
  @override
  Stream<void> get disconnections => lost.stream;
  @override
  Future<void> startScan() async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<int> connect(PrinterDevice device) async {
    rx.add(Uint8List.fromList([2, 182, 0, 1, 250]));
    return 182;
  }

  @override
  Future<void> write(Uint8List data) async {
    writes.addAll(data);
    if (writes.length == expectedJobBytes) {
      rx.add(Uint8List.fromList([0x1a, 15, 12]));
    }
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    await rx.close();
    await lost.close();
  }
}

final sample = PhotoPrint(MonoBitmap.fromPixels(4, (x, y) => x < 80));

void main() {
  late TestTransport transport;
  late T02Client client;
  late List<TestCamera> cameras;
  late PhotoCameraOpener opener;
  late PhotoRenderer renderer;
  var connectRequests = 0;

  setUp(() {
    transport = TestTransport();
    client = T02Client(transport: transport, packetInterval: Duration.zero);
    cameras = [];
    opener = (_) async {
      final camera = TestCamera();
      cameras.add(camera);
      return camera;
    };
    renderer = (_) async => sample;
    connectRequests = 0;
  });
  tearDown(() async {
    await client.dispose();
  });

  Widget screen({bool active = true, double textScale = 1}) => MaterialApp(
    theme: ThemeData(
      fontFamily: const bool.fromEnvironment('PHOTO_SCREENSHOTS')
          ? 'PhotoTestFont'
          : null,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF5F3EC),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F634B)),
    ),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('screen'),
          child: ColoredBox(
            color: const Color(0xFFF5F3EC),
            child: PhotoStudio(
              key: const ValueKey('photo'),
              client: client,
              active: active,
              feed: 4,
              onConnect: () => connectRequests++,
              openCamera: opener,
              render: renderer,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> mount(
    WidgetTester tester, {
    bool active = true,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(screen(active: active, textScale: textScale));
    await tester.pumpAndSettle();
  }

  Future<void> connect(WidgetTester tester) async {
    await tester.runAsync(
      () => client.connect(const PrinterDevice(id: 'test', name: 'T02')),
    );
    transport.writes.clear();
    transport.expectedJobBytes = T02Protocol.printJob(sample.bitmap).length;
    await tester.pump();
  }

  Future<void> instant(WidgetTester tester) async {
    final control = find.byKey(const ValueKey('instant-print'));
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pump();
  }

  testWidgets('camera is opened only in Photo and released when leaving', (
    tester,
  ) async {
    await mount(tester, active: false);
    expect(cameras, isEmpty);
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(cameras, hasLength(1));
    await tester.pumpWidget(screen(active: false));
    await tester.pumpAndSettle();
    expect(cameras.single.closes, 1);
  });

  testWidgets(
    'capture creates a preview; connecting does not discard the photo',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('capture-photo')));
      await tester.pumpAndSettle();
      expect(cameras.single.captures, 1);
      expect(cameras.single.closes, 1);
      expect(find.byKey(const ValueKey('photo-preview')), findsOneWidget);
      expect(transport.writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('print-photo')));
      expect(connectRequests, 1);
      await tester.pumpWidget(screen(active: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('photo-preview')), findsOneWidget);
      expect(cameras, hasLength(1));
    },
  );

  testWidgets('a late camera initialization is closed after leaving the tab', (
    tester,
  ) async {
    await mount(tester, active: false);
    final pending = Completer<PhotoCamera>();
    final camera = TestCamera();
    opener = (_) => pending.future;
    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.pumpWidget(screen(active: false));
    pending.complete(camera);
    await tester.pumpAndSettle();
    expect(camera.closes, 1);
    expect(camera.captures, 0);
    expect(transport.writes, isEmpty);
  });

  testWidgets('instant capture prints the prepared bitmap exactly once', (
    tester,
  ) async {
    await mount(tester);
    await connect(tester);
    await instant(tester);
    final capture = find.byKey(const ValueKey('capture-photo'));
    await tester.tap(capture);
    // A second tap before the next frame still must not start another shot.
    await tester.tap(capture);
    await tester.pumpAndSettle();
    expect(cameras.single.captures, 1);
    expect(transport.writes, T02Protocol.printJob(sample.bitmap));
    expect(find.textContaining('Your instant photo is ready.'), findsOneWidget);
  });

  testWidgets(
    'late capture after leaving Photo never starts an automatic print',
    (tester) async {
      await mount(tester);
      await connect(tester);
      await instant(tester);
      final pending = Completer<Uint8List>();
      cameras.single.pending = pending;
      await tester.tap(find.byKey(const ValueKey('capture-photo')));
      await tester.pumpWidget(screen(active: false));
      pending.complete(Uint8List.fromList([1]));
      await tester.pumpAndSettle();
      expect(transport.writes, isEmpty);
      expect(find.byKey(const ValueKey('photo-preview')), findsNothing);
    },
  );

  testWidgets(
    'background releases camera and prevents a pending instant print',
    (tester) async {
      await mount(tester);
      await connect(tester);
      await instant(tester);
      final pending = Completer<Uint8List>();
      cameras.single.pending = pending;
      await tester.tap(find.byKey(const ValueKey('capture-photo')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      pending.complete(Uint8List.fromList([1]));
      await tester.pump();
      expect(transport.writes, isEmpty);
      expect(cameras.single.closes, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(cameras, hasLength(2));
    },
  );

  testWidgets('permission failure is readable and retry can recover', (
    tester,
  ) async {
    var attempts = 0;
    opener = (_) async {
      if (++attempts == 1) {
        throw CameraException('CameraAccessDenied', 'denied');
      }
      final camera = TestCamera();
      cameras.add(camera);
      return camera;
    };
    await mount(tester);
    expect(find.textContaining('Camera access denied.'), findsOneWidget);
    tester.view.physicalSize = const Size(320, 568);
    await tester.pumpWidget(screen(textScale: 1.3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('capture-photo')))
          .onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(cameras, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'adjusting a photo disables printing until the latest image is ready',
    (tester) async {
      await mount(tester);
      await connect(tester);
      await tester.tap(find.byKey(const ValueKey('capture-photo')));
      await tester.pumpAndSettle();
      final pending = Completer<PhotoPrint>();
      renderer = (_) => pending.future;
      await tester.pumpWidget(screen());
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('photo-exposure')),
      );
      slider.onChanged!(.5);
      await tester.pump(const Duration(milliseconds: 170));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('print-photo')))
            .onPressed,
        isNull,
      );
      expect(transport.writes, isEmpty);
      pending.complete(sample);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('print-photo')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('layout fits a small phone and a real rendered photo', (
    tester,
  ) async {
    if (const bool.fromEnvironment('PHOTO_SCREENSHOTS')) {
      await tester.runAsync(() async {
        final loader = FontLoader('PhotoTestFont')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                File(
                  '/System/Library/Fonts/Supplemental/Arial.ttf',
                ).readAsBytesSync(),
              ),
            ),
          );
        await loader.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
    }
    final source = img.Image(width: 160, height: 120);
    for (final pixel in source) {
      final value = pixel.x * 255 ~/ 160;
      pixel.setRgb(value, pixel.y * 255 ~/ 120, 120);
    }
    final prepared = renderPhoto(PhotoOptions(img.encodePng(source)));
    renderer = (_) async => prepared;
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('capture-photo')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('photo-message')),
      findsNothing,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    expect(find.byKey(const ValueKey('photo-preview')), findsOneWidget);
    if (const bool.fromEnvironment('PHOTO_SCREENSHOTS')) {
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(prepared.preview),
          tester.element(find.byKey(const ValueKey('photo-preview'))),
        ),
      );
      await tester.pump();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('screen')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory('../../evidence/photo-mode')
          ..createSync(recursive: true);
        File(
          '${folder.path}/photo-preview-widget.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    tester.view.physicalSize = const Size(320, 568);
    await tester.pumpWidget(screen(textScale: 1.3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('print-photo')), findsOneWidget);
  });
}

# phomemo_t02

An unofficial Flutter SDK for the **Phomemo T02**: Bluetooth LE transport, monochrome raster encoding, printer status and diagnostics. No Phomemo app is required at runtime.

**Experimental:** basic printing has been reported working, but firmware compatibility, startup credits and completion behavior still need systematic hardware validation. Other printer models are not supported by this profile.

## Install

Requires Dart 3.11+ and Flutter 3.41+. From another Flutter project:

```yaml
dependencies:
  phomemo_t02:
    git:
      url: https://github.com/kchromik/phomemo-t02-flutter.git
      ref: main # Pin a commit for reproducible builds.
      path: packages/phomemo_t02
```

Inside this repository, the demo uses `path: ../../packages/phomemo_t02` instead.

## Discover and print

```dart
import 'package:phomemo_t02/phomemo_t02.dart';

final printer = T02Client(transport: UniversalBleTransport());
final devices = <String, PrinterDevice>{};
final scanSubscription = printer.discoveries.listen((device) {
  devices[device.id] = device; // Present these devices in your UI.
});
final stateSubscription = printer.states.listen((state) {
  // Display phase, progress and paper/cover/temperature status.
  // A null status means unknown, not OK.
});
await printer.startScan();
```

After the user selects a discovered `PrinterDevice` in your UI:

```dart
await printer.stopScan();
await printer.connect(selectedDevice);
final result = await printer.print(MonoBitmap.testPattern());
// PrintOutcome.confirmed: a completion notification was received.
// PrintOutcome.sentUnconfirmed: data sent, physical completion unknown.
```

When leaving the feature, stop scanning, cancel both subscriptions and call `await printer.dispose()`. Disconnect when the app enters the background. The [demo](../../apps/t02_demo) shows the complete lifecycle.

## Images and custom content

```dart
final bitmap = MonoBitmap.fromEncodedImage(pngOrJpegBytes, dither: true);
await printer.print(bitmap, feed: 4);

// Packed rows: 384 pixels, 48 bytes per row, 1 = black, MSB on the left.
final raw = MonoBitmap(height: height, bytes: packedRows);
final pattern = MonoBitmap.fromPixels(128, (x, y) => (x + y).isEven);
```

Render text, widgets, QR codes or PDF pages to an image in your app first. The demo uses `Canvas` and `TextPainter` for text, and an isolate for image conversion. Images are oriented using EXIF metadata, scaled to 384 dots with their aspect ratio preserved, composited on white and optionally dithered with Floyd–Steinberg.

SDK limits: 20 MB encoded input, 32 megapixels source size and 4,096 output rows. These are application limits, not verified firmware limits. The `feed` argument is a protocol parameter, not a millimeter measurement.

## Platform setup

- **iOS:** add `NSBluetoothAlwaysUsageDescription` to `Info.plist`. The included demo targets iOS 15+. Test BLE on a physical device.
- **Android:** use the [demo manifest](../../apps/t02_demo/android/app/src/main/AndroidManifest.xml), including `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` and legacy permissions for Android 11 and earlier. The adapter requests runtime permissions.
- **macOS:** add a Bluetooth usage description and `com.apple.security.device.bluetooth` entitlement. File import also needs user-selected file access.

The adapter uses `universal_ble` 3.0.2. Use one `UniversalBleTransport` per process because the underlying scan and operation queue are global. Implement `T02Transport` to supply a different adapter.

## Behavior and limitations

- GATT service FF00, FF02 Write Without Response and FF03 Notify are checked before sending. Notifications are enabled before initialization.
- Credits start at zero. Each write consumes one printer credit and respects both OS and printer payload limits. Normal mode adds no fixed delay.
- One job runs at a time. Paper, cover, heat, transport errors or disconnects stop further writes; jobs are never automatically retried.
- `disconnect()` stops new writes. Data already buffered by the OS or printer may still print.
- A completion notification is matched to the final-write window. There is no job ID, so this is a heuristic. After 20 seconds without confirmation, the client returns `sentUnconfirmed` and disconnects; reconnect before printing again.
- `FlowControl.experimentalPaced` bypasses credits with 20-byte packets every 200 ms. This opt-in diagnostic fallback is slow and can produce incomplete prints.
- No compression, density control, firmware updates or automatic reconnect. Unknown replies are logged; their framing is not fully understood.

`exportDiagnostics()` returns JSON for the latest 600 events, including RX bytes, TX prefixes (up to 24 bytes), timing and transfer statistics. This measures delivery to the BLE adapter, not physical print time. Logs remain local and may contain printed content.

See [PROTOCOL.md](../../docs/PROTOCOL.md) for the wire format. Run `flutter pub get`, `flutter analyze` and `flutter test` in this directory. Licensed under [MIT](LICENSE).

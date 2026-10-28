# T02 Studio

An English-language Flutter demo for the local [`phomemo_t02` SDK](../../packages/phomemo_t02). Print test strips, text, PNG/JPEG files and camera photos on a Phomemo T02.

## Run

From this directory, using Flutter 3.41.9 / Dart 3.11.5:

```sh
flutter pub get
flutter devices
flutter run --release -d <device-id>
```

For iPhone, install Xcode and CocoaPods, connect a physical device and configure your signing team in `ios/Runner.xcworkspace`. Choose a bundle identifier that belongs to you.

Alternatively, copy `ios/Flutter/Local.xcconfig.example` to `ios/Flutter/Local.xcconfig` and set your `DEVELOPMENT_TEAM` there. This optional file is included by both build configurations and ignored by Git. Bundle identifiers can be changed in Xcode.

iOS 15+ is the primary platform. Android and macOS hosts are included but have not been built or hardware-tested. Camera mode is implemented for iOS and Android only. For Android, use your own release signing configuration before distributing an app; the demo currently uses debug signing.

## Print

1. Turn on the T02, load paper and disconnect any other app using it.
2. Open **Printer → Find printer**, allow Bluetooth access and select the T02.
3. Open **Print**, choose a test strip, text or an image, then tap **Print now**.
4. For photos, open **Photo**, grant camera access and tap **Take photo**. Adjust brightness or the frame, then **Print photo**. Enable **Instant print** to capture and print in one action.

Keep the app in the foreground. Backgrounding disconnects the printer. Photos are not saved to the photo library, audio recording is disabled, and temporary captures are removed after reading.

If a print is unconfirmed, inspect the paper and reconnect before trying again. **Log → Copy log** exports diagnostics; review them before sharing. The experimental send mode is an opt-in fallback for missing credits and may produce incomplete prints.

## Code and checks

- `lib/main.dart`: SDK lifecycle, discovery, status, text rendering and file import.
- `lib/photo_studio.dart`: camera screen and capture/print flow.
- `lib/photo_camera.dart`: native camera adapter and permission errors.
- `lib/photo_print.dart`: photo cropping, brightness, frame and raster conversion.

```sh
flutter analyze
flutter test
flutter build ios --release --no-codesign
```

Widget tests use a fake camera and BLE transport; they do not validate physical camera capture or printed output. See the [project README](../../README.md) for hardware-test status.

The original app icon can be regenerated with `uv run --with pillow python ../../scripts/generate_demo_icons.py`.

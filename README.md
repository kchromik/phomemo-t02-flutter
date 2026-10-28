# Phomemo T02 for Flutter

[![CI](https://github.com/kchromik/phomemo-t02-flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/kchromik/phomemo-t02-flutter/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Flutter SDK and **T02 Studio** demo app for printing on the **Phomemo T02** over Bluetooth Low Energy. Print text, images and instant camera photos without the Phomemo app or a cloud account.

This is an independent, unofficial project for the **T02 specifically**. Compatibility with other Phomemo models is not claimed.

## What is included?

- **SDK:** BLE discovery and connection, 384-dot monochrome raster conversion, dithering, printer flow control, status updates and local diagnostics.
- **Demo app:** test strips, custom text, PNG/JPEG import and a camera mode with brightness adjustment, an optional frame and instant printing.
- **Tests:** protocol vectors, simulated BLE behavior, image processing and camera-screen lifecycle tests.

| Path | Purpose |
| --- | --- |
| [`packages/phomemo_t02`](packages/phomemo_t02) | Reusable Flutter SDK |
| [`apps/t02_demo`](apps/t02_demo) | T02 Studio demo and integration example |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | Short protocol reference and known limitations |

## Run the demo

Use **Flutter 3.41.9 / Dart 3.11.5** (the tested toolchain), a physical T02 and a Bluetooth-capable device. For iOS, use macOS with Xcode, CocoaPods and your own Apple signing team. The demo targets iOS 15 or later.

```sh
git clone https://github.com/kchromik/phomemo-t02-flutter.git
cd phomemo-t02-flutter/apps/t02_demo
flutter pub get
flutter devices
flutter run --release -d <device-id>
```

For iPhone signing, open `ios/Runner.xcworkspace`, select your team under **Signing & Capabilities**, and choose a unique bundle identifier. See the [demo README](apps/t02_demo/README.md) for a local signing configuration that stays outside Git.

Turn on the printer, load paper and disconnect other apps from it. In **Printer → Find printer**, select your T02, then use **Print → Test strip → Print now**. Keep the app in the foreground while printing.

## Use the SDK

The package is available from this repository; it is not published on pub.dev.

```yaml
dependencies:
  phomemo_t02:
    git:
      url: https://github.com/kchromik/phomemo-t02-flutter.git
      ref: main # Pin a commit for reproducible builds.
      path: packages/phomemo_t02
```

See the [SDK README](packages/phomemo_t02/README.md) for discovery, printing and platform permissions.

## Status

**Experimental.** Basic printing, including text, has been reported working on a physical T02. The iOS demo has previously been built and installed on a real iPhone. Printer startup credits, completion notifications, camera-to-paper output and the latest transfer-speed change still need systematic hardware validation.

| Platform | Status |
| --- | --- |
| iOS 15+ | Primary demo platform; physical device required for BLE and camera testing |
| Android | Host and permissions included; not yet built or hardware-tested |
| macOS | Host and entitlements included; not yet built or hardware-tested; no camera mode |
| Web / Windows / Linux | No demo host or verified support |

Sending all bytes does not prove that a print completed. The SDK reports `confirmed` or `sentUnconfirmed` separately and never automatically retries an interrupted job.

## Development

Run the same formatting, analysis and tests as CI:

```sh
./scripts/check.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines. Diagnostics stay in memory until manually copied; there is no automatic upload. Review exported logs before sharing, as they can contain device names and fragments of printed content.

## License

[MIT](LICENSE). Third-party dependencies retain their own licenses; see [THIRD_PARTY.md](THIRD_PARTY.md). Phomemo is a trademark of its respective owner. This project is not affiliated with or endorsed by Phomemo, and includes no vendor binaries or artwork.

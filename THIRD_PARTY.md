# Third-party notices

The SDK, demo and geometric app icons are independently implemented. No Phomemo binaries, extracted implementation code or vendor artwork are distributed with this repository.

## Direct dependencies

| Dependency | License | Use |
| --- | --- | --- |
| [Flutter / Dart](https://github.com/flutter/flutter/blob/master/LICENSE) | BSD-3-Clause | App framework and language |
| [universal_ble 3.0.2](https://pub.dev/packages/universal_ble/versions/3.0.2) | BSD-3-Clause | Native BLE transport and permissions |
| [image](https://pub.dev/packages/image) | MIT | Image decoding, resizing and PNG encoding |
| [file_selector](https://pub.dev/packages/file_selector) | BSD-3-Clause | System file picker |
| [camera](https://pub.dev/packages/camera) | BSD-3-Clause | Camera preview and still capture |
| [Pillow](https://python-pillow.github.io/) | HPND | Optional development tool for generating icons |

The demo `pubspec.lock` records resolved runtime and test dependencies, including transitive platform adapters. Flutter bundles dependency license notices through its license registry. Third-party packages retain their own licenses; the root MIT license applies to this project's original work.

## Protocol references

The implementation was informed by static analysis of Phomemo app 4.1.0 and independent public protocol references:

- [vivier/phomemo-tools](https://github.com/vivier/phomemo-tools/tree/d0522f058df7915674640b71aa6256d96bde4fd6): T02/M02 raster framing and feed sequence.
- [jeffrafter/phomemo](https://github.com/jeffrafter/phomemo/tree/972f887db835b1437b6a60e6cec2eb6251fb8a7d): T02 BLE characteristics and status replies.

These are references, not bundled dependencies. Local disassembly, device logs and research exports are excluded from the repository.

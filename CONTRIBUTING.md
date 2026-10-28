# Contributing

Small, focused pull requests and reproducible T02 bug reports are welcome.

1. Use Flutter 3.41.9 / Dart 3.11.5 and run `./scripts/check.sh` before submitting.
2. For protocol or transport changes, extend the existing tests with the affected byte sequence or failure case.
3. State which platform and physical printer/firmware you tested. Keep simulated results separate from hardware observations.
4. For bug reports, include the app/SDK version, steps, expected result and actual result. Redact device identifiers, serial numbers and printed content from any logs you choose to attach.

Do not commit credentials, signing files, vendor binaries or build output. Keep documentation and user-facing text in English. The project targets the Phomemo T02; discuss support for another model before changing the profile.

Contributions are submitted under the project's [MIT license](LICENSE).

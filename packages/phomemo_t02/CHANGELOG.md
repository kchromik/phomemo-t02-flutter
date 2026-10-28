## Unreleased

- Prepare the public GitHub repository with English documentation, diagnostics and demo UI, an MIT license and CI checks.

## 0.1.1 — 2026-10-15

- Remove the fixed 200 ms delay in normal credit mode while retaining printer credits, payload limits and native write backpressure.
- Keep experimental pacing separately configurable and add transfer timing diagnostics.
- Add regression coverage for throughput, experimental pacing and native write readiness.

## 0.1.0 — 2026-10-15

- Add the 384-dot raster codec, uncompressed blocks, white alpha background and optional Floyd–Steinberg dithering.
- Add an injectable BLE transport with GATT checks, credit flow control and payload limits.
- Add single-job printing, status events, cancellation, confirmed/unconfirmed outcomes and local diagnostics.
- Add protocol and simulated transport tests, plus a standalone iPhone demo.

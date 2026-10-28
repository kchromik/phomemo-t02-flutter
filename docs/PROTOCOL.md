# T02 protocol notes

This is a short reference for the profile implemented by `phomemo_t02`, not a complete Phomemo specification. It combines static app analysis with public T02 references listed in [THIRD_PARTY.md](../THIRD_PARTY.md). Firmware-specific behavior still needs hardware validation.

## BLE connection

| Role | UUID |
| --- | --- |
| Service | `0000ff00-0000-1000-8000-00805f9b34fb` |
| Write Without Response | `0000ff02-0000-1000-8000-00805f9b34fb` |
| Notifications | `0000ff03-0000-1000-8000-00805f9b34fb` |

Enable notifications before sending the 33-byte initialization sequence. Split it into writes according to the negotiated payload limits and available credits:

```text
1F 11 7B  1F 11 20  1F 11 45  1F 11 0E
1F 11 07  1F 11 5E  1F 11 08  1F 11 09
1F 11 38  1F 11 8B  1F 11 63
```

The full meaning and necessity of each query are not established. The SDK starts with zero credits and a 20-byte payload limit, then uses the smaller of the OS limit and the printer-reported limit. It does not invent startup credits.

## Raster format

T02 output is **384 dots wide at 203 DPI**, or 48 bytes per row. Rows run top to bottom; the leftmost pixel is the most significant bit. One means black, zero means white.

```text
1B 40                          reset
1B 61 01                       center alignment
1F 11 35 00                    uncompressed mode
1D 76 30 00 30 00 yL yH        raster block header
<48 × height bytes>            packed image data
...                            further raster headers and data as needed
1B 64 n                        final feed (default n = 4)
```

Height is unsigned little-endian. The SDK splits images into blocks of at most 255 rows and feeds only after the final block. Raster blocks and BLE write chunks are separate boundaries. Image bytes such as `0A` are transmitted unchanged. Feed units are not assumed to be millimeters.

## Flow control and status

| Notification | Interpretation |
| --- | --- |
| `01 n` | Add `n` write credits |
| `02 n 00` | Observed packet-limit reply; the profile uses byte `n` |
| `1A 03 A9` / `1A 03 A8` | Too hot / temperature normal |
| `1A 05 99` / `1A 05 98` | Cover open / closed |
| `1A 06 88` / `1A 06 89` | Paper absent / present |
| `1A 0B B8` | Job cancelled |
| `1A 0F 0C` | Print completion |

Each normal write consumes one credit and awaits the native BLE adapter. No extra delay is added by default. Eight seconds without credits aborts the operation; 20 seconds without completion returns an unconfirmed outcome and disconnects. Both timeouts are configurable.

Completion is accepted only in the window beginning with the final write. Because there is no job ID, this is a heuristic rather than proof of a correct physical print. A disconnect stops further writes but cannot retract buffered data.

Unknown replies are preserved in diagnostics. Their complete framing, the initial credit exchange, capability-dependent raster variants and compression are not fully validated. No density or firmware-update commands are exposed.

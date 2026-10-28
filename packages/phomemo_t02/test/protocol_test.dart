import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:phomemo_t02/phomemo_t02.dart';

void main() {
  test(
    'one raster row: MSB left, 0A unchanged, exact header and single feed',
    () {
      final row = List<int>.filled(48, 0)
        ..[0] = 0x80
        ..[1] = 0x0a
        ..[47] = 1;
      final bitmap = MonoBitmap(height: 1, bytes: row);
      expect(bitmap.blackAt(0, 0), true);
      expect(bitmap.blackAt(383, 0), true);
      expect(bitmap.blackAt(1, 0), false);
      expect(T02Protocol.printJob(bitmap), [
        0x1b,
        0x40,
        0x1b,
        0x61,
        1,
        0x1f,
        0x11,
        0x35,
        0,
        0x1d,
        0x76,
        0x30,
        0,
        0x30,
        0,
        1,
        0,
        ...row,
        0x1b,
        0x64,
        4,
      ]);
      row[0] = 0;
      bitmap.bytes[0] = 0;
      expect(bitmap.bytes.first, 0x80, reason: 'Raster must be immutable');
    },
  );
  test('256 rows split at 255 without deleting or feeding between rows', () {
    final bitmap = MonoBitmap.fromPixels(256, (x, y) => x == y);
    final bytes = T02Protocol.printJob(bitmap);
    expect(bytes.sublist(9, 17), [0x1d, 0x76, 0x30, 0, 48, 0, 255, 0]);
    expect(bytes.sublist(17 + 255 * 48, 25 + 255 * 48), [
      0x1d,
      0x76,
      0x30,
      0,
      48,
      0,
      1,
      0,
    ]);
    expect(bytes.sublist(17, 17 + 255 * 48), bitmap.bytes.sublist(0, 255 * 48));
    expect(
      bytes.sublist(25 + 255 * 48, bytes.length - 3),
      bitmap.bytes.sublist(255 * 48),
    );
    expect(bytes.length, 9 + 16 + 256 * 48 + 3);
  });
  test('transparent black becomes white and opaque black remains black', () {
    final image = img.Image(width: 384, height: 1, numChannels: 4);
    image.setPixelRgba(0, 0, 0, 0, 0, 255);
    final bitmap = MonoBitmap.fromImage(image, dither: false);
    expect(bitmap.bytes.first, 0x80);
    expect(bitmap.bytes.skip(1).every((b) => b == 0), true);
    expect(
      MonoBitmap.fromEncodedImage(bitmap.toPng(), dither: false).bytes,
      bitmap.bytes,
    );
  });
  test('bad input rejected before packet construction', () {
    expect(() => MonoBitmap(height: 0, bytes: []), throwsArgumentError);
    expect(() => MonoBitmap(height: 1, bytes: [0]), throwsArgumentError);
    expect(
      () => MonoBitmap.fromEncodedImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(
      () => T02Protocol.printJob(MonoBitmap.testPattern(), feed: 11),
      throwsArgumentError,
    );
  });
  test(
    'known notifications decode split frames and optional packet padding',
    () {
      final decoder = T02ReplyDecoder();
      expect(decoder.add([1]), isEmpty);
      expect(decoder.add([3, 2, 182]).map((r) => (r.kind, r.value)), [
        (ReplyKind.credits, 3),
        (ReplyKind.packetLimit, 182),
      ]);
      expect(decoder.add([0, 0x1a, 6]), isEmpty);
      expect(
        decoder
            .add([0x88, 0x1a, 5, 0x98, 0x1a, 3, 0xa9])
            .map((r) => (r.kind, r.value)),
        [
          (ReplyKind.paperPresent, 0),
          (ReplyKind.coverClosed, 1),
          (ReplyKind.temperatureNormal, 0),
        ],
      );
    },
  );
  test('unknown capability bytes are opaque, never mined for credits', () {
    final replies = T02ReplyDecoder().add([
      0x1a,
      0x75,
      1,
      200,
      2,
      255,
      0x1a,
      15,
      12,
    ]);
    expect(replies.length, 1);
    expect(replies.single.kind, ReplyKind.unknown);
    expect(replies.single.bytes.length, 9);
  });
  test('incomplete frame expires rather than consuming a later credit', () {
    final decoder = T02ReplyDecoder();
    final now = DateTime(2026);
    decoder.add([0x1a, 6], now: now);
    final replies = decoder.add([
      1,
      2,
    ], now: now.add(const Duration(seconds: 2)));
    expect(replies.map((r) => r.kind), [ReplyKind.unknown, ReplyKind.credits]);
    expect(replies.last.value, 2);
  });
}

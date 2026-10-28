import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:t02_demo/photo_print.dart';

Uint8List png(img.Image image) => img.encodePng(image);
img.Image solid(int width, int height, int value) => img.fill(
  img.Image(width: width, height: height),
  color: img.ColorRgb8(value, value, value),
);

void main() {
  test(
    'background preparation returns a printable frame and its preview',
    () async {
      final result = await preparePhoto(PhotoOptions(png(solid(8, 8, 0))));
      expect(result.bitmap.height, 416);
      expect(result.bitmap.blackAt(192, 192), isTrue);
      expect(result.bitmap.blackAt(192, 400), isFalse);
      expect(img.decodePng(result.preview)!.height, 416);
    },
  );

  test('center square crop excludes the outside of a landscape photo', () {
    final image = solid(8, 4, 255);
    for (var y = 0; y < 4; y++) {
      for (var x = 2; x < 6; x++) {
        image.setPixelRgb(x, y, 0, 0, 0);
      }
    }
    final print = renderPhoto(PhotoOptions(png(image), frame: false));
    expect(print.bitmap.height, 384);
    expect(print.bitmap.bytes.every((byte) => byte == 255), isTrue);
  });

  test('instant frame has white edges and a larger blank lower margin', () {
    final print = renderPhoto(PhotoOptions(png(solid(8, 8, 0))));
    expect(print.bitmap.height, 416);
    expect(print.bitmap.blackAt(16, 16), isTrue);
    expect(print.bitmap.blackAt(367, 367), isTrue);
    for (var y = 0; y < 416; y++) {
      for (var x = 0; x < 384; x++) {
        if (x < 16 || x >= 368 || y < 16 || y >= 368) {
          expect(print.bitmap.blackAt(x, y), isFalse);
        }
      }
    }
  });

  test('EXIF rotation is applied before conversion', () {
    final photo = solid(24, 24, 255);
    for (var y = 0; y < 12; y++) {
      for (var x = 0; x < 12; x++) {
        photo.setPixelRgb(x, y, 0, 0, 0);
      }
    }
    photo.exif.imageIfd.orientation = 6; // 90° clockwise.
    final print = renderPhoto(
      PhotoOptions(img.encodeJpg(photo, quality: 100), frame: false),
    );
    expect(print.bitmap.blackAt(320, 64), isTrue);
    expect(print.bitmap.blackAt(64, 64), isFalse);
    expect(print.bitmap.blackAt(320, 320), isFalse);
  });

  test('exposure changes dot coverage and preview matches the sent raster', () {
    final photo = png(solid(16, 16, 110));
    int blackPixels(PhotoPrint print) {
      var total = 0;
      final preview = img.decodePng(print.preview)!;
      for (var y = 0; y < print.bitmap.height; y++) {
        for (var x = 0; x < 384; x++) {
          final black = print.bitmap.blackAt(x, y);
          expect(preview.getPixel(x, y).r, black ? 0 : 255);
          if (black) total++;
        }
      }
      return total;
    }

    final darker = blackPixels(renderPhoto(PhotoOptions(photo, exposure: -1)));
    final normal = blackPixels(renderPhoto(PhotoOptions(photo)));
    final lighter = blackPixels(renderPhoto(PhotoOptions(photo, exposure: 1)));
    expect(darker, greaterThan(normal));
    expect(normal, greaterThan(lighter));
  });

  test('bad and oversized input never produces a printable image', () {
    expect(
      () => renderPhoto(PhotoOptions(Uint8List(4))),
      throwsFormatException,
    );
    expect(
      () => renderPhoto(PhotoOptions(Uint8List(20 * 1024 * 1024 + 1))),
      throwsFormatException,
    );
  });
}

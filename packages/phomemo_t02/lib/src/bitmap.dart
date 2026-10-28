import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Immutable, row-major 384-pixel bitmap. Black is 1, leftmost pixel is MSB.
class MonoBitmap {
  static const width = 384;
  static const bytesPerRow = 48;
  static const maxHeight =
      4096; // Deliberate SDK memory/paper guard, not firmware limit.
  final int height;
  final Uint8List _bytes;

  MonoBitmap({required this.height, required List<int> bytes})
    : _bytes = Uint8List.fromList(bytes) {
    if (height < 1 ||
        height > maxHeight ||
        bytes.length != height * bytesPerRow) {
      throw ArgumentError(
        'Expected 384 × 1…$maxHeight pixels and exactly 48 bytes per row.',
      );
    }
    if (bytes.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('Raster values must be bytes.');
    }
  }

  Uint8List get bytes => Uint8List.fromList(_bytes);
  bool blackAt(int x, int y) =>
      (_bytes[y * bytesPerRow + x ~/ 8] & (0x80 >> (x & 7))) != 0;
  double get heightMm => height / 203 * 25.4;

  factory MonoBitmap.fromPixels(
    int height,
    bool Function(int x, int y) isBlack,
  ) {
    if (height < 1 || height > maxHeight) {
      throw ArgumentError.value(height, 'height');
    }
    final bytes = Uint8List(height * bytesPerRow);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (isBlack(x, y)) bytes[y * bytesPerRow + x ~/ 8] |= 0x80 >> (x & 7);
      }
    }
    return MonoBitmap(height: height, bytes: bytes);
  }

  /// Decodes PNG/JPEG and other formats supported by package:image.
  /// Alpha is composited onto white; aspect ratio is preserved.
  factory MonoBitmap.fromEncodedImage(Uint8List encoded, {bool dither = true}) {
    if (encoded.length > 20 * 1024 * 1024) {
      throw ArgumentError('Image exceeds 20 MB.');
    }
    final decoder = img.findDecoderForData(encoded);
    final info = decoder?.startDecode(encoded);
    if (info == null) {
      throw const FormatException('Unsupported image. Use PNG or JPEG.');
    }
    if (info.width < 1 ||
        info.height < 1 ||
        info.width * info.height > 32000000) {
      throw ArgumentError(
        'Image exceeds 32 megapixels or has invalid dimensions.',
      );
    }
    final image = decoder!.decodeFrame(0);
    if (image == null) {
      throw const FormatException('Unsupported image. Use PNG or JPEG.');
    }
    return MonoBitmap.fromImage(image, dither: dither);
  }

  factory MonoBitmap.fromImage(img.Image source, {bool dither = true}) {
    source = img.bakeOrientation(source);
    final h = math.max(1, (source.height * width / source.width).round());
    if (h > maxHeight) {
      throw ArgumentError(
        'Image is too tall; crop to at most $maxHeight rows.',
      );
    }
    final scaled = img.copyResize(
      source,
      width: width,
      height: h,
      interpolation: img.Interpolation.average,
    );
    final luminance = Float64List(width * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < width; x++) {
        final p = scaled.getPixel(x, y);
        final a = p.aNormalized;
        luminance[y * width + x] =
            (p.rNormalized * .299 +
                    p.gNormalized * .587 +
                    p.bNormalized * .114) *
                255 *
                a +
            255 * (1 - a);
      }
    }
    final bytes = Uint8List(h * bytesPerRow);
    void diffuse(int x, int y, double error, double weight) {
      if (x >= 0 && x < width && y < h) {
        luminance[y * width + x] += error * weight;
      }
    }

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < width; x++) {
        final value = luminance[y * width + x].clamp(0.0, 255.0);
        final black = value < 128;
        if (black) bytes[y * bytesPerRow + x ~/ 8] |= 0x80 >> (x & 7);
        if (dither) {
          final error = value - (black ? 0 : 255);
          diffuse(x + 1, y, error, 7 / 16);
          diffuse(x - 1, y + 1, error, 3 / 16);
          diffuse(x, y + 1, error, 5 / 16);
          diffuse(x + 1, y + 1, error, 1 / 16);
        }
      }
    }
    return MonoBitmap(height: h, bytes: bytes);
  }

  Uint8List toPng() {
    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final v = blackAt(x, y) ? 0 : 255;
        image.setPixelRgb(x, y, v, v, v);
      }
    }
    return img.encodePng(image);
  }

  /// Small calibration pattern, including 0x0A pixels and asymmetric edge marks.
  factory MonoBitmap.testPattern() => MonoBitmap.fromPixels(128, (x, y) {
    if (y < 4 || y >= 124 || x < 2 || x >= 382) return true;
    if (y >= 12 && y < 28) return x < 22 || (x >= 350 && x < 362);
    if (y >= 38 && y < 62) return (x ~/ 8).isEven;
    if (y >= 72 && y < 96) return (x + y).isEven;
    if (y >= 106 && y < 118) return x % 8 == 4 || x % 8 == 6;
    return false;
  });
}

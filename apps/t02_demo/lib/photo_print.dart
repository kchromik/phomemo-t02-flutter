import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:phomemo_t02/phomemo_t02.dart';

class PhotoOptions {
  final Uint8List bytes;
  final bool frame;
  final double exposure;
  const PhotoOptions(this.bytes, {this.frame = true, this.exposure = 0});
}

class PhotoPrint {
  final MonoBitmap bitmap;
  final Uint8List preview;
  PhotoPrint(this.bitmap) : preview = bitmap.toPng();
}

typedef PhotoRenderer = Future<PhotoPrint> Function(PhotoOptions options);

Future<PhotoPrint> preparePhoto(PhotoOptions options) =>
    compute(renderPhoto, options);

/// Center crop matches the square viewfinder. Bake EXIF before selecting the
/// crop, then adjust at print resolution and dither using the existing SDK.
PhotoPrint renderPhoto(PhotoOptions options) {
  if (options.bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('The photo exceeds 20 MB.');
  }
  final decoder = img.findDecoderForData(options.bytes);
  final info = decoder?.startDecode(options.bytes);
  if (info == null ||
      info.width < 1 ||
      info.height < 1 ||
      info.width * info.height > 32000000) {
    throw const FormatException('The photo cannot be processed.');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const FormatException('The photo is corrupted.');
  final upright = img.bakeOrientation(decoded);
  final side = math.min(upright.width, upright.height);
  final square = img.copyCrop(
    upright,
    x: (upright.width - side) ~/ 2,
    y: (upright.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final margin = options.frame ? 16 : 0;
  final photoSize = MonoBitmap.width - margin * 2;
  final scaled = img.copyResize(
    square,
    width: photoSize,
    height: photoSize,
    interpolation: img.Interpolation.average,
  );
  final multiplier = math.pow(2, options.exposure.clamp(-1.0, 1.0));
  for (final pixel in scaled) {
    pixel
      ..r = (pixel.r * multiplier).clamp(0, 255)
      ..g = (pixel.g * multiplier).clamp(0, 255)
      ..b = (pixel.b * multiplier).clamp(0, 255);
  }
  final sheet = img.Image(
    width: MonoBitmap.width,
    height: options.frame ? 416 : MonoBitmap.width,
  );
  img.fill(sheet, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(sheet, scaled, dstX: margin, dstY: margin);
  return PhotoPrint(MonoBitmap.fromImage(sheet));
}

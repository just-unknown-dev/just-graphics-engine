import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;

import 'model_data.dart' show RgbaImage;

/// Decodes a PNG or JPEG (anything Flutter decodes) into RGBA8. Must run on
/// the root isolate; Flutter decodes off the UI thread itself.
Future<RgbaImage> decodeImage(Uint8List encoded) async {
  final codec = await ui.instantiateImageCodec(encoded);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw StateError('Could not read the decoded image.');
      return RgbaImage(image.width, image.height, Uint8List.sublistView(data));
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// Builds the mip chain of [image] in a background isolate, at most
/// [maxLevels] levels (all the way to 1×1 by default): level 0 is the image
/// itself. [srgb] averages in linear light, so colour textures do not darken
/// as they shrink.
Future<List<RgbaImage>> buildMips(
  RgbaImage image, {
  required bool srgb,
  int? maxLevels,
}) => compute(_mips, (image, srgb, maxLevels ?? 64));

List<RgbaImage> _mips((RgbaImage, bool, int) job) {
  final (image, srgb, maxLevels) = job;
  final levels = [image];
  var current = image;
  while ((current.width > 1 || current.height > 1) &&
      levels.length < maxLevels) {
    current = halve(current, srgb: srgb);
    levels.add(current);
  }
  return levels;
}

final Float64List _toLinear = Float64List.fromList([
  for (var i = 0; i < 256; i++) _srgbToLinear(i / 255),
]);

double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

int _linearToSrgb(double c) {
  final v = c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
  return (v * 255 + 0.5).floor().clamp(0, 255);
}

/// [image] at half size (each side halved, at least 1), every pixel the
/// average of up to four source pixels. Alpha is always averaged linearly.
RgbaImage halve(RgbaImage image, {required bool srgb}) {
  final w = math.max(1, image.width >> 1);
  final h = math.max(1, image.height >> 1);
  final src = image.pixels;
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final y0 = math.min(y * 2, image.height - 1);
    final y1 = math.min(y * 2 + 1, image.height - 1);
    for (var x = 0; x < w; x++) {
      final x0 = math.min(x * 2, image.width - 1);
      final x1 = math.min(x * 2 + 1, image.width - 1);
      final a = (y0 * image.width + x0) * 4;
      final b = (y0 * image.width + x1) * 4;
      final c = (y1 * image.width + x0) * 4;
      final d = (y1 * image.width + x1) * 4;
      final o = (y * w + x) * 4;
      for (var ch = 0; ch < 3; ch++) {
        if (srgb) {
          final sum =
              _toLinear[src[a + ch]] +
              _toLinear[src[b + ch]] +
              _toLinear[src[c + ch]] +
              _toLinear[src[d + ch]];
          out[o + ch] = _linearToSrgb(sum / 4);
        } else {
          out[o + ch] =
              (src[a + ch] + src[b + ch] + src[c + ch] + src[d + ch] + 2) >> 2;
        }
      }
      out[o + 3] = (src[a + 3] + src[b + 3] + src[c + 3] + src[d + 3] + 2) >> 2;
    }
  }
  return RgbaImage(w, h, out);
}

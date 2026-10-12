import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;

/// Why Flutter GPU can't be used here, or null when it can.
///
/// Tests that render call this first and skip when it returns a reason, so a
/// plain `flutter test` stays green. Run them with
/// `flutter test --enable-impeller --enable-flutter-gpu --tags gpu`.
String? gpuUnavailableReason() {
  try {
    gpu.gpuContext;
    return null;
  } on Object catch (e) {
    return '$e';
  }
}

/// Submits [commandBuffer] and completes once the GPU has finished it.
///
/// Reading an image back straight after `submit()` can return stale or empty
/// pixels (seen on the OpenGL ES backend). Waiting for completion first makes
/// readback reliable. Completes with false if the GPU reports a failure, and
/// throws a [TimeoutException] after [timeout].
Future<bool> submitAndWait(
  gpu.CommandBuffer commandBuffer, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final done = Completer<bool>();
  commandBuffer.submit(completionCallback: done.complete);
  return done.future.timeout(timeout);
}

/// RGBA8 pixels read back from an image.
final class RgbaPixels {
  /// Wraps [bytes], which hold [width] × [height] pixels, 4 bytes each.
  RgbaPixels(this.width, this.height, this.bytes)
    : assert(bytes.length == width * height * 4);

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Row-major RGBA bytes, top row first.
  final Uint8List bytes;

  /// The pixel at ([x], [y]) as `[r, g, b, a]`.
  List<int> at(int x, int y) {
    RangeError.checkValueInInterval(x, 0, width - 1, 'x');
    RangeError.checkValueInInterval(y, 0, height - 1, 'y');
    final o = (y * width + x) * 4;
    return [bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]];
  }

  /// The pixel at fractional position ([fx], [fy]) in 0..1 of the image.
  List<int> atFraction(double fx, double fy) => at(
    (fx * (width - 1)).round().clamp(0, width - 1),
    (fy * (height - 1)).round().clamp(0, height - 1),
  );
}

/// Reads [image] back as RGBA8.
Future<RgbaPixels> readPixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError('Could not read the image back.');
  }
  return RgbaPixels(
    image.width,
    image.height,
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

/// Whether every channel of [actual] is within [tolerance] of [expected].
bool colorClose(List<int> actual, List<int> expected, {int tolerance = 2}) {
  if (actual.length != expected.length) return false;
  for (var i = 0; i < actual.length; i++) {
    if ((actual[i] - expected[i]).abs() > tolerance) return false;
  }
  return true;
}

/// How two same-sized images differ.
final class ImageDiff {
  const ImageDiff._(this.maxChannelDelta, this.differingPixels);

  /// The largest difference in any channel of any pixel.
  final int maxChannelDelta;

  /// How many pixels differ by more than the tolerance used.
  final int differingPixels;

  @override
  String toString() =>
      'ImageDiff(maxChannelDelta: $maxChannelDelta, '
      'differingPixels: $differingPixels)';
}

/// Compares [a] and [b] pixel by pixel. A pixel differs when any channel is
/// more than [tolerance] apart.
ImageDiff compareImages(RgbaPixels a, RgbaPixels b, {int tolerance = 2}) {
  if (a.width != b.width || a.height != b.height) {
    throw ArgumentError(
      'Images differ in size: ${a.width}x${a.height} vs ${b.width}x${b.height}',
    );
  }
  var maxDelta = 0;
  var differing = 0;
  for (var p = 0; p < a.bytes.length; p += 4) {
    var pixelDelta = 0;
    for (var c = 0; c < 4; c++) {
      final d = (a.bytes[p + c] - b.bytes[p + c]).abs();
      if (d > pixelDelta) pixelDelta = d;
    }
    if (pixelDelta > maxDelta) maxDelta = pixelDelta;
    if (pixelDelta > tolerance) differing++;
  }
  return ImageDiff._(maxDelta, differing);
}

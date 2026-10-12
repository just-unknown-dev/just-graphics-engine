// Environment maps on the CPU: the cube's faces and directions agree, a
// gradient sky lands the right way up, blurred levels average their
// surroundings, spherical harmonics give back a uniform light, half floats
// round correctly, and a Radiance HDR file decodes.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/assets.dart';

void main() {
  test('a face texel and its direction come back to the same face', () {
    final rng = math.Random(1);
    for (var face = 0; face < 6; face++) {
      for (var i = 0; i < 50; i++) {
        final s = rng.nextDouble(), t = rng.nextDouble();
        final (x, y, z) = EnvironmentMapData.directionOf(face, s, t);
        final (f, s2, t2) = EnvironmentMapData.faceOf(x, y, z);
        expect(f, face);
        expect(s2, closeTo(s, 1e-9));
        expect(t2, closeTo(t, 1e-9));
      }
    }
    // The face centres point along the axes, in the shared order.
    expect(EnvironmentMapData.directionOf(0, 0.5, 0.5), (1.0, -0.0, -0.0));
    expect(EnvironmentMapData.directionOf(3, 0.5, 0.5).$2, -1.0);
    expect(EnvironmentMapData.directionOf(5, 0.5, 0.5).$3, -1.0);
  });

  test('a gradient sky: the zenith up (-Y), the ground below, blurred levels between', () {
    final map = EnvironmentMapData.gradientNow((0.0, 0.0, 1.0), (0.5, 0.5, 0.5), (0.2, 0.1, 0.0), size: 16);
    expect(map.levelCount, 5, reason: '16, 8, 4, 2, 1');
    final c = Float32List(3);
    map.sample(0, 0, -1, 0, c);
    expect(c[2], closeTo(1, 0.05), reason: 'straight up is the zenith');
    map.sample(0, 0, 1, 0, c);
    expect(c[0], closeTo(0.2, 0.05), reason: 'straight down is the ground');
    // The roughest level is near the average of everything.
    map.sample(map.levelCount - 1, 1, 0, 0, c);
    expect(c[2], inInclusiveRange(0.15, 0.85));
  });

  test('spherical harmonics of a uniform light give that light back everywhere', () {
    final map = EnvironmentMapData.build((x, y, z, out) {
      out[0] = 0.5;
      out[1] = 1.0;
      out[2] = 2.0;
    }, size: 8);
    for (final (x, y, z) in [(1.0, 0.0, 0.0), (0.0, -1.0, 0.0), (0.0, 0.6, 0.8)]) {
      final (r, g, b) = map.irradiance(x, y, z);
      expect(r, closeTo(0.5, 0.02));
      expect(g, closeTo(1.0, 0.04));
      expect(b, closeTo(2.0, 0.08));
    }
  });

  test('half floats: exact values, rounding, and the range clamped', () {
    expect(EnvironmentMapData.toHalf(0), 0);
    expect(EnvironmentMapData.toHalf(1), 0x3C00);
    expect(EnvironmentMapData.toHalf(-2), 0xC000);
    expect(EnvironmentMapData.toHalf(0.5), 0x3800);
    expect(EnvironmentMapData.toHalf(65504), 0x7BFF);
    expect(EnvironmentMapData.toHalf(1e9), 0x7BFF, reason: 'clamped, not infinity');
    expect(EnvironmentMapData.toHalf(1e-9), 0, reason: 'too small');
    final map = EnvironmentMapData.gradientNow((1, 1, 1), (1, 1, 1), (1, 1, 1), size: 2);
    expect(map.halfFloatsOf(0, 0).lengthInBytes, 2 * 2 * 4 * 2);
  });

  test('a Radiance HDR file decodes, flat and run-length encoded', () {
    // 8×2: the first row red (1.0), the second green (0.5).
    final header = '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 8\n'.codeUnits;
    final flat = <int>[
      for (var x = 0; x < 8; x++) ...[128, 0, 0, 129],
      for (var x = 0; x < 8; x++) ...[0, 128, 0, 128],
    ];
    var image = decodeRadianceHdr(Uint8List.fromList([...header, ...flat]));
    expect((image.width, image.height), (8, 2));
    expect(image.rgb[0], closeTo(1.0, 1e-6));
    expect(image.rgb[8 * 3 + 1], closeTo(0.5, 1e-6));

    // The same as new-style RLE scanlines: a run of 8 for each component.
    List<int> scan(List<int> rgbe) => [2, 2, 0, 8, for (final v in rgbe) ...[128 + 8, v]];
    final rle = [...scan([128, 0, 0, 129]), ...scan([0, 128, 0, 128])];
    image = decodeRadianceHdr(Uint8List.fromList([...header, ...rle]));
    expect(image.rgb[7 * 3], closeTo(1.0, 1e-6));
    expect(image.rgb[15 * 3 + 1], closeTo(0.5, 1e-6));

    expect(() => decodeRadianceHdr(Uint8List.fromList('nope'.codeUnits)), throwsFormatException);
  });
}

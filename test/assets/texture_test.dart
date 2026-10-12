import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/assets.dart';

RgbaImage _image(int width, int height, List<int> rgba) =>
    RgbaImage(width, height, Uint8List.fromList(rgba));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('halving averages sRGB colour in linear light, alpha linearly', () {
    // Black and white side by side, alpha 0 and 255.
    final image = _image(2, 1, [0, 0, 0, 0, 255, 255, 255, 255]);
    final srgb = halve(image, srgb: true);
    final linear = halve(image, srgb: false);
    expect((srgb.width, srgb.height), (1, 1));
    // Half the light of white is sRGB 188, not 128.
    expect(srgb.pixels[0], inInclusiveRange(186, 190));
    expect(linear.pixels[0], 128);
    expect(srgb.pixels[3], 128, reason: 'alpha is never sRGB');
  });

  test('odd sizes halve down, edges clamp', () {
    final image = _image(3, 1, [10, 0, 0, 255, 20, 0, 0, 255, 30, 0, 0, 255]);
    final half = halve(image, srgb: false);
    expect((half.width, half.height), (1, 1));
  });

  test('a mip chain stops at 1x1 or at the level limit', () async {
    final image = _image(8, 4, List<int>.filled(8 * 4 * 4, 255));
    final full = await buildMips(image, srgb: true);
    expect([for (final l in full) (l.width, l.height)], [(8, 4), (4, 2), (2, 1), (1, 1)]);
    final capped = await buildMips(image, srgb: true, maxLevels: 2);
    expect(capped.length, 2);
  });
}

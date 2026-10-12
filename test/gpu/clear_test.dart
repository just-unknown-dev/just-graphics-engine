@Tags(['gpu'])
library;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/testing.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  final skip = gpuUnavailableReason();

  test('a cleared render target reads back as its clear colour', () async {
    final context = gpu.gpuContext;
    final target = context.createTexture(gpu.StorageMode.devicePrivate, 16, 8);
    final commands = context.createCommandBuffer();
    commands.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: target,
          clearValue: vm.Vector4(1, 0.5, 0, 1),
        ),
      ),
    );
    expect(await submitAndWait(commands), isTrue);

    final pixels = await readPixels(target.asImage());
    expect(pixels.width, 16);
    expect(pixels.height, 8);
    for (final corner in [(0, 0), (15, 0), (0, 7), (15, 7)]) {
      expect(
        colorClose(pixels.at(corner.$1, corner.$2), [255, 128, 0, 255]),
        isTrue,
        reason: 'pixel $corner is ${pixels.at(corner.$1, corner.$2)}',
      );
    }
  }, skip: skip);

  test('an image surface presents its frame as the current image', () async {
    final context = gpu.gpuContext;
    final surface = context.createImageSurface(8, 8);
    final frame = surface.acquireNextFrame();
    final commands = context.createCommandBuffer();
    commands.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: frame.colorTexture,
          clearValue: vm.Vector4(0, 0, 1, 1),
        ),
      ),
    );
    frame.present(commands);
    expect(await submitAndWait(commands), isTrue);

    final image = surface.currentImage;
    expect(image, isNotNull);
    final pixels = await readPixels(image!);
    expect(colorClose(pixels.at(4, 4), [0, 0, 255, 255]), isTrue);
  }, skip: skip);
}

import 'dart:math' as math;
import 'dart:typed_data';

import '../assets/environment_map.dart';
import '../gpu/device.dart';
import '../gpu/formats.dart';

/// An [EnvironmentMapData] on the GPU: its levels in one half-float cube
/// texture, its spherical harmonics beside it. Give it to
/// `Environment.map` and lit surfaces take their ambient light and
/// reflections from it; with `Environment.skybox` the sky shows it.
final class GpuEnvironmentMap {
  GpuEnvironmentMap._(this.texture, this.sh, this.levelCount);

  /// Uploads [data] to [device].
  /// As many levels as the device takes ([GpuDevice.maxMipLevels]: Flutter
  /// GPU leaves out the 1×1 level) are uploaded.
  factory GpuEnvironmentMap.upload(GpuDevice device, EnvironmentMapData data) {
    final levels = math.max(
      1,
      math.min(data.levelCount, device.maxMipLevels(data.size, data.size)),
    );
    final texture = device.createTexture(
      GpuTextureDesc(
        width: data.size,
        height: data.size,
        format: GpuFormat.rgba16f,
        storage: GpuStorage.host,
        mipLevels: levels,
        cube: true,
      ),
    );
    for (var level = 0; level < levels; level++) {
      for (var face = 0; face < 6; face++) {
        texture.upload(
          data.halfFloatsOf(level, face),
          mipLevel: level,
          slice: face,
        );
      }
    }
    return GpuEnvironmentMap._(texture, Float32List.fromList(data.sh), levels);
  }

  /// The cube, its levels from sharp to blurred.
  final GpuTexture texture;

  /// Diffuse light: nine RGB coefficients.
  final Float32List sh;

  /// How many levels the cube has.
  final int levelCount;
}

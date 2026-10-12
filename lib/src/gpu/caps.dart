import 'formats.dart';

/// What a [GpuDevice] can do. Read once when the device is created; the
/// renderer chooses its paths (HDR, MSAA, skinning, compression) from it.
final class GpuCaps {
  /// Capabilities as measured by a backend.
  const GpuCaps({
    required this.backend,
    required this.colorFormat,
    required this.depthFormat,
    required this.msaa,
    required this.renderToMipLevel,
    required this.manualMipLevels,
    required this.maxAnisotropy,
    required this.uniformAlignment,
    required this.compression,
    required this.hdrRenderTarget,
    required this.floatTextures,
  });

  /// Which backend: `flutter_gpu` or `null`.
  final String backend;

  /// The format presentable surfaces use.
  final GpuFormat colorFormat;

  /// The depth-stencil format attachments use.
  final GpuFormat depthFormat;

  /// Whether offscreen 4x MSAA works.
  final bool msaa;

  /// Whether a non-zero mip level can be a render target (false on OpenGL
  /// ES): when false, mip chains must be built on the CPU or at import.
  final bool renderToMipLevel;

  /// Whether textures with hand-uploaded mip levels sample correctly.
  final bool manualMipLevels;

  /// Largest anisotropy a sampler can use (1 = none).
  final int maxAnisotropy;

  /// Byte alignment of uniform data inside a buffer.
  final int uniformAlignment;

  /// Compression families the device can sample.
  final Set<GpuCompression> compression;

  /// Whether `rgba16f` can be rendered into (HDR).
  final bool hdrRenderTarget;

  /// Whether `rgba32f` textures can be created and sampled (joint palettes).
  final bool floatTextures;

  /// Capabilities for the null backend: everything a renderer might ask
  /// for, so its unit tests cover every path.
  static const GpuCaps all = GpuCaps(
    backend: 'null',
    colorFormat: GpuFormat.rgba8,
    depthFormat: GpuFormat.depth24Stencil8,
    msaa: true,
    renderToMipLevel: true,
    manualMipLevels: true,
    maxAnisotropy: 16,
    uniformAlignment: 256,
    compression: {GpuCompression.etc2, GpuCompression.astc, GpuCompression.bc},
    hdrRenderTarget: true,
    floatTextures: true,
  );

  @override
  String toString() =>
      'GpuCaps($backend, colour $colorFormat, depth $depthFormat, '
      'msaa $msaa, renderToMip $renderToMipLevel, manualMips $manualMipLevels, '
      'aniso $maxAnisotropy, uniform align $uniformAlignment, '
      'compression ${compression.map((c) => c.name).join('/')}, '
      'hdr $hdrRenderTarget, float textures $floatTextures)';
}

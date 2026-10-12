/// The GPU layer's own enums. They mirror what Flutter GPU offers today but
/// carry no flutter_gpu type, so code above the layer stays web-safe and a
/// second backend (WebGL2) can map them its own way.
library;

/// A texture's pixel format.
enum GpuFormat {
  /// 8-bit RGBA, linear.
  rgba8,

  /// 8-bit RGBA, sRGB-encoded colour (sampling decodes to linear).
  rgba8Srgb,

  /// 8-bit BGRA, linear.
  bgra8,

  /// 8-bit BGRA, sRGB.
  bgra8Srgb,

  /// 16-bit float RGBA (HDR colour).
  rgba16f,

  /// 32-bit float RGBA (joint palettes, data).
  rgba32f,

  /// One 32-bit float channel (shadow depth written as colour).
  r32f,

  /// 24-bit depth with 8-bit stencil.
  depth24Stencil8,

  /// 32-bit float depth with 8-bit stencil.
  depth32fStencil8,

  /// ETC2 RGB, linear.
  etc2Rgb8,

  /// ETC2 RGB, sRGB.
  etc2Rgb8Srgb,

  /// ETC2 RGBA, linear.
  etc2Rgba8,

  /// ETC2 RGBA, sRGB.
  etc2Rgba8Srgb,

  /// ASTC 4×4, linear.
  astc4x4,

  /// ASTC 4×4, sRGB.
  astc4x4Srgb,

  /// ASTC 8×8, linear.
  astc8x8,

  /// ASTC 8×8, sRGB.
  astc8x8Srgb,

  /// BC7, linear.
  bc7,

  /// BC7, sRGB.
  bc7Srgb;

  /// Whether this is a block-compressed format (sample-only, sizes in
  /// whole blocks).
  bool get isCompressed => index >= GpuFormat.etc2Rgb8.index;

  /// Whether this is a depth (and stencil) format.
  bool get isDepth => this == depth24Stencil8 || this == depth32fStencil8;

  /// Whether sampling decodes sRGB to linear.
  bool get isSrgb => switch (this) {
    rgba8Srgb ||
    bgra8Srgb ||
    etc2Rgb8Srgb ||
    etc2Rgba8Srgb ||
    astc4x4Srgb ||
    astc8x8Srgb ||
    bc7Srgb => true,
    _ => false,
  };

  /// The compression family, or null for an uncompressed format.
  GpuCompression? get compression => switch (this) {
    etc2Rgb8 ||
    etc2Rgb8Srgb ||
    etc2Rgba8 ||
    etc2Rgba8Srgb => GpuCompression.etc2,
    astc4x4 || astc4x4Srgb || astc8x8 || astc8x8Srgb => GpuCompression.astc,
    bc7 || bc7Srgb => GpuCompression.bc,
    _ => null,
  };
}

/// A family of block-compressed texture formats a device may support.
enum GpuCompression {
  /// Desktop (BC1–BC7).
  bc,

  /// OpenGL ES 3 / Android baseline.
  etc2,

  /// Most modern mobile GPUs.
  astc,
}

/// Where a texture lives and who can write it.
enum GpuStorage {
  /// Written from the CPU (uploads).
  host,

  /// GPU memory, written by rendering or copies.
  device,

  /// Never stored: an attachment that exists only during its pass (on
  /// tile-based GPUs it stays in tile memory).
  transient,
}

/// How an attachment starts a pass.
enum GpuLoad {
  /// Cleared to the attachment's clear value.
  clear,

  /// Kept from before the pass.
  load,

  /// Undefined; the pass covers every pixel.
  dontCare,
}

/// What happens to an attachment when its pass ends.
enum GpuStore {
  /// Kept.
  store,

  /// Discarded.
  dontCare,

  /// Resolved into the attachment's resolve texture (MSAA), samples
  /// discarded.
  resolve,

  /// Resolved and the samples kept.
  storeAndResolve,
}

/// Depth comparison.
enum GpuCompare {
  never,
  always,
  less,
  equal,
  lessEqual,
  greater,
  notEqual,
  greaterEqual,
}

/// Which faces to skip.
enum GpuCull { none, front, back }

/// What a draw's vertices form.
enum GpuTopology { triangles, triangleStrip, lines, lineStrip, points }

/// Size of each index.
enum GpuIndexType { uint16, uint32 }

/// Texture filtering.
enum GpuFilter { nearest, linear }

/// What sampling does outside 0..1.
enum GpuAddress { clamp, repeat, mirror }

/// How a texture is sampled.
final class GpuSampler {
  /// A sampler; defaults are linear with linear mips, clamped.
  const GpuSampler({
    this.minFilter = GpuFilter.linear,
    this.magFilter = GpuFilter.linear,
    this.mipFilter = GpuFilter.linear,
    this.addressU = GpuAddress.clamp,
    this.addressV = GpuAddress.clamp,
    this.maxAnisotropy = 1,
  });

  /// Linear, clamped.
  static const GpuSampler linearClamp = GpuSampler();

  /// Linear, repeating.
  static const GpuSampler linearRepeat = GpuSampler(
    addressU: GpuAddress.repeat,
    addressV: GpuAddress.repeat,
  );

  /// Nearest, clamped (data textures, joint palettes).
  static const GpuSampler nearestClamp = GpuSampler(
    minFilter: GpuFilter.nearest,
    magFilter: GpuFilter.nearest,
    mipFilter: GpuFilter.nearest,
  );

  /// Filtering when shrinking.
  final GpuFilter minFilter;

  /// Filtering when enlarging.
  final GpuFilter magFilter;

  /// Filtering between mip levels.
  final GpuFilter mipFilter;

  /// Addressing along u.
  final GpuAddress addressU;

  /// Addressing along v.
  final GpuAddress addressV;

  /// Anisotropy clamp; 1 turns it off.
  final int maxAnisotropy;
}

/// One vertex attribute's type.
enum GpuVertexFormat {
  float1(4),
  float2(8),
  float3(12),
  float4(16),
  uint1(4),
  uint4(16),
  sint1(4),
  sint4(16);

  const GpuVertexFormat(this.bytes);

  /// Size in bytes.
  final int bytes;
}

/// One attribute read from a vertex buffer.
final class GpuVertexAttribute {
  /// An attribute feeding the shader input called [name].
  const GpuVertexAttribute(this.name, this.format, this.offset);

  /// The shader's `in` variable.
  final String name;

  /// Its type.
  final GpuVertexFormat format;

  /// Byte offset inside one element.
  final int offset;
}

/// One vertex buffer slot.
final class GpuVertexBufferLayout {
  /// A slot whose elements are [stride] bytes apart.
  const GpuVertexBufferLayout({
    required this.stride,
    required this.attributes,
    this.perInstance = false,
  });

  /// Bytes from one element to the next.
  final int stride;

  /// What the shader reads from each element.
  final List<GpuVertexAttribute> attributes;

  /// Whether the slot advances once per instance instead of per vertex.
  final bool perInstance;

  /// A key that is equal for equal layouts.
  String get key =>
      '$stride${perInstance ? 'i' : 'v'}'
      '[${attributes.map((a) => '${a.name}:${a.format.name}@${a.offset}').join(',')}]';
}

/// All of a pipeline's vertex buffer slots, slot 0 first.
final class GpuVertexLayout {
  /// A layout reading [buffers].
  const GpuVertexLayout(this.buffers);

  /// The slots, in binding order.
  final List<GpuVertexBufferLayout> buffers;

  /// A key that is equal for equal layouts.
  String get key => buffers.map((b) => b.key).join('|');
}

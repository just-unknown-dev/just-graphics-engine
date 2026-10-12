import 'dart:typed_data';
import 'dart:ui' as ui;

import 'caps.dart';
import 'formats.dart';

/// A GPU the renderer draws with.
///
/// This is the only layer that knows a GPU API. Today the backend is
/// Flutter GPU (`flutter_gpu`); a WebGL2 backend can implement the same
/// interface later. A null backend records commands for unit tests.
///
/// Objects it hands out are released when they become unreachable; there is
/// nothing to destroy explicitly.
abstract interface class GpuDevice {
  /// What this device can do.
  GpuCaps get caps;

  /// A buffer holding [data], for vertices or indices that do not change.
  GpuBuffer createBuffer(ByteData data);

  /// A buffer of [sizeInBytes] the CPU can rewrite ([GpuBuffer.write]).
  GpuBuffer createHostBuffer(int sizeInBytes);

  /// A texture.
  GpuTexture createTexture(GpuTextureDesc desc);

  /// The most mip levels a [width] × [height] texture may have here. Flutter
  /// GPU allows `floor(log2(min(width, height)))`, one fewer than a full
  /// chain (flutter/flutter#186176).
  int maxMipLevels(int width, int height);

  /// Loads the package shader bundle [fileName] (for example
  /// `core.shaderbundle`) once.
  Future<GpuShaderLibrary> loadShaderLibrary(String fileName);

  /// The pipeline for [vertex] and [fragment] reading [layout] (null: the
  /// vertex shader's inputs, interleaved in declaration order). Cached: the
  /// same arguments return the same pipeline.
  GpuPipeline pipeline(
    GpuShader vertex,
    GpuShader fragment, {
    GpuVertexLayout? layout,
  });

  /// Starts a frame: data from [frameData] in earlier frames may be reused.
  /// Call once per frame, before recording.
  void beginFrame();

  /// Copies [data] into this frame's transient memory, aligned for use as
  /// uniforms, vertices or indices.
  GpuBufferView frameData(ByteData data);

  /// A list of commands to record and submit.
  GpuCommands commands();

  /// A presentable target Flutter draws as a [ui.Image].
  GpuSurface createSurface(int width, int height);
}

/// A texture's size, format and uses.
final class GpuTextureDesc {
  /// Describes a texture.
  const GpuTextureDesc({
    required this.width,
    required this.height,
    this.format = GpuFormat.rgba8,
    this.storage = GpuStorage.device,
    this.mipLevels = 1,
    this.samples = 1,
    this.cube = false,
    this.renderTarget = false,
    this.shaderRead = true,
  });

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Pixel format.
  final GpuFormat format;

  /// Where it lives.
  final GpuStorage storage;

  /// Mip levels allocated (1 = none).
  final int mipLevels;

  /// Samples per pixel (1, or 4 for MSAA).
  final int samples;

  /// Whether it is a cube map (6 slices).
  final bool cube;

  /// Whether it can be rendered into.
  final bool renderTarget;

  /// Whether shaders can sample it.
  final bool shaderRead;

  /// Mip levels for a full chain of a [width] × [height] texture.
  static int fullMipCount(int width, int height) {
    var size = width > height ? width : height;
    var levels = 1;
    while (size > 1) {
      size >>= 1;
      levels++;
    }
    return levels;
  }

  /// A copy with some fields changed.
  GpuTextureDesc copyWith({int? width, int? height, GpuFormat? format}) =>
      GpuTextureDesc(
        width: width ?? this.width,
        height: height ?? this.height,
        format: format ?? this.format,
        storage: storage,
        mipLevels: mipLevels,
        samples: samples,
        cube: cube,
        renderTarget: renderTarget,
        shaderRead: shaderRead,
      );

  @override
  bool operator ==(Object other) =>
      other is GpuTextureDesc &&
      other.width == width &&
      other.height == height &&
      other.format == format &&
      other.storage == storage &&
      other.mipLevels == mipLevels &&
      other.samples == samples &&
      other.cube == cube &&
      other.renderTarget == renderTarget &&
      other.shaderRead == shaderRead;

  @override
  int get hashCode => Object.hash(
    width,
    height,
    format,
    storage,
    mipLevels,
    samples,
    cube,
    renderTarget,
    shaderRead,
  );

  @override
  String toString() =>
      'GpuTextureDesc(${width}x$height ${format.name} ${storage.name}'
      '${mipLevels > 1 ? ' mips $mipLevels' : ''}'
      '${samples > 1 ? ' msaa $samples' : ''}${cube ? ' cube' : ''}'
      '${renderTarget ? ' target' : ''})';
}

/// GPU memory holding vertices, indices or uniforms.
abstract interface class GpuBuffer {
  /// Size in bytes.
  int get sizeInBytes;

  /// A view of [length] bytes from [offset] (the whole buffer by default).
  GpuBufferView view([int offset = 0, int? length]);

  /// Rewrites bytes from [offset]; host buffers only.
  void write(ByteData data, {int offset = 0});
}

/// A range of a buffer, as bound to a draw.
abstract interface class GpuBufferView {
  /// Start of the range, in bytes.
  int get offset;

  /// Length of the range, in bytes.
  int get length;
}

/// An image on the GPU.
abstract interface class GpuTexture {
  /// What it was created as.
  GpuTextureDesc get desc;

  /// Uploads [data] (tightly packed rows) into one mip level and slice of a
  /// host texture.
  void upload(ByteData data, {int mipLevel = 0, int slice = 0});

  /// This texture as an image Flutter can draw or read back.
  ui.Image toImage();
}

/// Compiled shader stages, by name.
abstract interface class GpuShaderLibrary {
  /// The shader called [name], or null.
  GpuShader? operator [](String name);
}

/// One compiled shader stage.
abstract interface class GpuShader {
  /// Its name in the bundle.
  String get name;

  /// The uniform block whose GLSL **type** name is [typeName] (for
  /// `uniform FrameInfo { … } frame;`, `FrameInfo`), or null.
  GpuUniformBlock? uniformBlock(String typeName);
}

/// A uniform block's layout, from shader reflection.
abstract interface class GpuUniformBlock {
  /// The block's GLSL type name.
  String get name;

  /// Its size in bytes.
  int get sizeInBytes;

  /// Byte offset of [member], or null when the block has none.
  int? offsetOf(String member);
}

/// A vertex and fragment shader with a vertex layout, ready to draw.
abstract interface class GpuPipeline {
  /// The vertex stage.
  GpuShader get vertex;

  /// The fragment stage.
  GpuShader get fragment;

  /// The block called [typeName] from whichever stage declares it.
  GpuUniformBlock? uniformBlock(String typeName);
}

/// Commands recorded for one submission.
abstract interface class GpuCommands {
  /// Starts a render pass drawing into [targets].
  GpuPass beginPass(GpuRenderTargets targets);

  /// Submits everything recorded. When [present] is given, its texture is
  /// published as the surface's image. Completes once the GPU has finished,
  /// with false when it reported a failure.
  Future<bool> submit({GpuSurfaceFrame? present});
}

/// One colour attachment.
final class GpuColorTarget {
  /// Draws into [texture]; with [resolve], a multisampled [texture] is
  /// resolved into it.
  const GpuColorTarget(
    this.texture, {
    this.load = GpuLoad.clear,
    this.store = GpuStore.store,
    this.clear = const (0.0, 0.0, 0.0, 0.0),
    this.resolve,
    this.mipLevel = 0,
    this.slice = 0,
  });

  /// What is drawn into.
  final GpuTexture texture;

  /// How it starts.
  final GpuLoad load;

  /// What is kept.
  final GpuStore store;

  /// Clear colour, linear RGBA.
  final (double, double, double, double) clear;

  /// Single-sample texture to resolve into.
  final GpuTexture? resolve;

  /// Mip level drawn into.
  final int mipLevel;

  /// Slice (cube face) drawn into.
  final int slice;
}

/// The depth (and stencil) attachment.
final class GpuDepthTarget {
  /// Depth into [texture], cleared to [clearDepth] (1 = far).
  const GpuDepthTarget(
    this.texture, {
    this.load = GpuLoad.clear,
    this.store = GpuStore.dontCare,
    this.clearDepth = 1.0,
  });

  /// The depth texture.
  final GpuTexture texture;

  /// How it starts.
  final GpuLoad load;

  /// What is kept (usually nothing).
  final GpuStore store;

  /// Clear value.
  final double clearDepth;
}

/// What a pass draws into.
final class GpuRenderTargets {
  /// Colour attachments (one on OpenGL ES) and an optional depth attachment.
  const GpuRenderTargets(this.color, {this.depth});

  /// Colour attachments.
  final List<GpuColorTarget> color;

  /// Depth attachment.
  final GpuDepthTarget? depth;
}

/// Colour blending presets.
enum GpuBlend {
  /// Replace.
  off,

  /// Premultiplied alpha over.
  premultiplied,

  /// Straight alpha over.
  alpha,

  /// Add.
  additive,
}

/// Records draws into one set of targets.
abstract interface class GpuPass {
  /// Draws use [pipeline] from now on. Switching to a different pipeline
  /// clears every binding (buffers, uniforms, textures): bind them again.
  void setPipeline(GpuPipeline pipeline);

  /// Binds vertex buffer [slot].
  void setVertexBuffer(int slot, GpuBufferView view);

  /// Binds the index buffer.
  void setIndexBuffer(GpuBufferView view, GpuIndexType type);

  /// Binds [view] to the uniform block [typeName] in every stage of the
  /// current pipeline that declares it.
  void setUniforms(String typeName, GpuBufferView view);

  /// Binds [texture] to the sampler uniform [name] of the fragment stage,
  /// or of the vertex stage when [vertexStage] (a joint palette, say).
  void setTexture(
    String name,
    GpuTexture texture, {
    GpuSampler sampler = GpuSampler.linearClamp,
    bool vertexStage = false,
  });

  /// Depth testing and writing.
  void setDepth({
    bool test = true,
    bool write = true,
    GpuCompare compare = GpuCompare.less,
  });

  /// Face culling; front faces wind clockwise when [frontClockwise].
  void setCull(GpuCull cull, {bool frontClockwise = false});

  /// Colour blending.
  void setBlend(GpuBlend blend);

  /// What vertices form.
  void setTopology(GpuTopology topology);

  /// Draws [vertexCount] vertices, [instances] times.
  void draw(int vertexCount, {int instances = 1});

  /// Draws [indexCount] indices, [instances] times.
  void drawIndexed(int indexCount, {int instances = 1});
}

/// A pool of presentable textures Flutter draws as an image.
abstract interface class GpuSurface {
  /// Width of new frames.
  int get width;

  /// Height of new frames.
  int get height;

  /// Changes the size of frames acquired from now on.
  void resize(int width, int height);

  /// A texture to render the next frame into.
  GpuSurfaceFrame acquire();

  /// The last presented frame, or null before the first.
  ui.Image? get image;
}

/// A texture leased from a [GpuSurface] for one frame.
abstract interface class GpuSurfaceFrame {
  /// What to render into.
  GpuTexture get texture;

  /// Gives the frame back without presenting it.
  void discard();
}

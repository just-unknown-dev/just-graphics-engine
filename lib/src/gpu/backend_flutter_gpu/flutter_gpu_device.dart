// The Flutter GPU backend. Native platforms only: flutter_gpu imports
// dart:ffi, so a web build must never reach this file (see create_device.dart).
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../caps.dart';
import '../device.dart';
import '../formats.dart';
import '../frame_arenas.dart';
import '../shader_bundle_loader.dart';

/// Creates the Flutter GPU device, or returns null and calls [onUnsupported]
/// with the reason when Flutter GPU can't be used here: Impeller or Flutter
/// GPU is off, or the device is on Android's OpenGL ES fallback, where
/// draws can hang (flutter/flutter#177873).
GpuDevice? createGpuDevice({void Function(String reason)? onUnsupported}) {
  final gpu.GpuContext context;
  try {
    context = gpu.gpuContext;
  } on Object catch (e) {
    onUnsupported?.call('$e');
    return null;
  }
  // On Android, Vulkan renders into mip levels and OpenGL ES does not.
  if (Platform.isAndroid && !context.doesSupportFramebufferRenderMipmap) {
    onUnsupported?.call(
      'This device runs Impeller on OpenGL ES (no Vulkan); Flutter GPU draws '
      'can hang there, so 3D is turned off.',
    );
    return null;
  }
  return FlutterGpuDevice._(context);
}

/// [GpuDevice] on Flutter GPU.
final class FlutterGpuDevice implements GpuDevice {
  FlutterGpuDevice._(this._context) : caps = _capsOf(_context) {
    _frames = FrameArenas<gpu.DeviceBuffer>(
      alignment: _context.minimumUniformByteAlignment,
      create: (size) =>
          _context.createDeviceBuffer(gpu.StorageMode.hostVisible, size),
      sizeOf: (block) => block.sizeInBytes,
      write: (block, offset, data) {
        if (!block.overwrite(data, destinationOffsetInBytes: offset)) {
          throw StateError('Frame data write failed.');
        }
        block.flush(offsetInBytes: offset, lengthInBytes: data.lengthInBytes);
      },
    );
  }

  final gpu.GpuContext _context;
  // Not Flutter GPU's HostBuffer: it reuses a frame's memory four frames
  // later, read by the GPU or not (see FrameArenas).
  late final FrameArenas<gpu.DeviceBuffer> _frames;
  final Map<String, Future<GpuShaderLibrary>> _libraries = {};
  final Map<(GpuShader, GpuShader, String), _Pipeline> _pipelines = {};

  @override
  final GpuCaps caps;

  static GpuCaps _capsOf(gpu.GpuContext c) => GpuCaps(
    backend: 'flutter_gpu',
    colorFormat: _fromPixelFormat(c.defaultColorFormat) ?? GpuFormat.rgba8,
    depthFormat:
        _fromPixelFormat(c.defaultDepthStencilFormat) ??
        GpuFormat.depth24Stencil8,
    msaa: c.doesSupportOffscreenMSAA,
    renderToMipLevel: c.doesSupportFramebufferRenderMipmap,
    manualMipLevels: c.doesSupportManuallyMippedTextures,
    maxAnisotropy: c.maxSamplerAnisotropy,
    uniformAlignment: c.minimumUniformByteAlignment,
    compression: {
      if (c.supportsTextureCompression(gpu.TextureCompressionFamily.bc))
        GpuCompression.bc,
      if (c.supportsTextureCompression(gpu.TextureCompressionFamily.etc2))
        GpuCompression.etc2,
      if (c.supportsTextureCompression(gpu.TextureCompressionFamily.astc))
        GpuCompression.astc,
    },
    hdrRenderTarget: c.supportsTextureFormat(
      gpu.PixelFormat.r16g16b16a16Float,
      renderTarget: true,
    ),
    floatTextures: c.supportsTextureFormat(gpu.PixelFormat.r32g32b32a32Float),
  );

  @override
  GpuBuffer createBuffer(ByteData data) =>
      _Buffer(_context.createDeviceBufferWithCopy(data), host: false);

  @override
  GpuBuffer createHostBuffer(int sizeInBytes) => _Buffer(
    _context.createDeviceBuffer(gpu.StorageMode.hostVisible, sizeInBytes),
    host: true,
  );

  @override
  GpuTexture createTexture(GpuTextureDesc desc) {
    final texture = _context.createTexture(
      _storageMode(desc.storage),
      desc.width,
      desc.height,
      format: _pixelFormat(desc.format),
      sampleCount: desc.samples,
      textureType: desc.cube
          ? gpu.TextureType.textureCube
          : desc.samples > 1
          ? gpu.TextureType.texture2DMultisample
          : gpu.TextureType.texture2D,
      enableRenderTargetUsage: desc.renderTarget,
      enableShaderReadUsage: desc.shaderRead,
      mipLevelCount: desc.mipLevels,
    );
    return _Texture(texture, desc);
  }

  @override
  int maxMipLevels(int width, int height) =>
      gpu.Texture.fullMipCount(width, height);

  @override
  Future<GpuShaderLibrary> loadShaderLibrary(String fileName) =>
      _libraries[fileName] ??= loadShaderBundle(
        fileName,
      ).then<GpuShaderLibrary>(_Library.new);

  @override
  GpuPipeline pipeline(
    GpuShader vertex,
    GpuShader fragment, {
    GpuVertexLayout? layout,
  }) {
    final key = (vertex, fragment, layout?.key ?? '');
    return _pipelines[key] ??= _Pipeline(
      _context.createRenderPipeline(
        (vertex as _Shader).native,
        (fragment as _Shader).native,
        vertexLayout: layout == null ? null : _vertexLayout(layout),
      ),
      vertex,
      fragment,
    );
  }

  @override
  void beginFrame() => _frames.beginFrame();

  @override
  GpuBufferView frameData(ByteData data) {
    final (block, offset) = _frames.place(data);
    return _View(
      gpu.BufferView(
        block,
        offsetInBytes: offset,
        lengthInBytes: data.lengthInBytes,
      ),
    );
  }

  @override
  GpuCommands commands() => _Commands(_context, _frames);

  @override
  GpuSurface createSurface(int width, int height) =>
      _Surface(_context.createImageSurface(width, height));
}

// ---- Resources ------------------------------------------------------------

final class _Buffer implements GpuBuffer {
  _Buffer(this.native, {required this.host});

  final gpu.DeviceBuffer native;
  final bool host;

  @override
  int get sizeInBytes => native.sizeInBytes;

  @override
  GpuBufferView view([int offset = 0, int? length]) => _View(
    gpu.BufferView(
      native,
      offsetInBytes: offset,
      lengthInBytes: length ?? native.sizeInBytes - offset,
    ),
  );

  @override
  void write(ByteData data, {int offset = 0}) {
    if (!host) throw StateError('Only host buffers can be written.');
    if (!native.overwrite(data, destinationOffsetInBytes: offset)) {
      throw StateError('Buffer write out of range.');
    }
    native.flush(offsetInBytes: offset, lengthInBytes: data.lengthInBytes);
  }
}

final class _View implements GpuBufferView {
  _View(this.native);

  final gpu.BufferView native;

  @override
  int get offset => native.offsetInBytes;

  @override
  int get length => native.lengthInBytes;
}

final class _Texture implements GpuTexture {
  _Texture(this.native, this.desc);

  final gpu.Texture native;

  @override
  final GpuTextureDesc desc;

  @override
  void upload(ByteData data, {int mipLevel = 0, int slice = 0}) =>
      native.overwrite(data, mipLevel: mipLevel, slice: slice);

  @override
  ui.Image toImage() => native.asImage();
}

final class _Library implements GpuShaderLibrary {
  _Library(this.native);

  final gpu.ShaderLibrary native;
  final Map<String, _Shader?> _shaders = {};

  @override
  GpuShader? operator [](String name) => _shaders.putIfAbsent(name, () {
    final shader = native[name];
    return shader == null ? null : _Shader(shader, name);
  });
}

final class _Shader implements GpuShader {
  _Shader(this.native, this.name);

  final gpu.Shader native;
  final Map<String, _Block?> _blocks = {};
  final Map<String, gpu.UniformSlot> _samplers = {};

  @override
  final String name;

  @override
  _Block? uniformBlock(String typeName) => _blocks.putIfAbsent(typeName, () {
    final slot = native.getUniformSlot(typeName);
    final size = slot.sizeInBytes;
    return size == null ? null : _Block(slot, typeName, size);
  });

  gpu.UniformSlot sampler(String name) =>
      _samplers.putIfAbsent(name, () => native.getUniformSlot(name));
}

final class _Block implements GpuUniformBlock {
  _Block(this.slot, this.name, this.sizeInBytes);

  final gpu.UniformSlot slot;
  final Map<String, int?> _offsets = {};

  @override
  final String name;

  @override
  final int sizeInBytes;

  @override
  int? offsetOf(String member) =>
      _offsets.putIfAbsent(member, () => slot.getMemberOffsetInBytes(member));
}

final class _Pipeline implements GpuPipeline {
  _Pipeline(this.native, this.vertex, this.fragment);

  final gpu.RenderPipeline native;

  @override
  final GpuShader vertex;

  @override
  final GpuShader fragment;

  @override
  GpuUniformBlock? uniformBlock(String typeName) =>
      vertex.uniformBlock(typeName) ?? fragment.uniformBlock(typeName);
}

// ---- Recording ------------------------------------------------------------

/// Commands for one submission. Each pass records into a flutter_gpu
/// command buffer of its own, submitted in order: two render passes in one
/// command buffer, where the second samples what the first drew, crash on
/// Impeller's Vulkan backend (measured on 3.47.6).
///
/// It holds the frame data it may read — the frame's when it was made and
/// when it is submitted — until the GPU has finished it.
final class _Commands implements GpuCommands {
  _Commands(this._context, this._frames) {
    _held.add(_frames.hold(_frames.current));
  }

  final gpu.GpuContext _context;
  final FrameArenas<gpu.DeviceBuffer> _frames;
  final List<FrameArena<gpu.DeviceBuffer>> _held = [];
  final List<gpu.CommandBuffer> _buffers = [];

  @override
  GpuPass beginPass(GpuRenderTargets targets) {
    final buffer = _context.createCommandBuffer();
    _buffers.add(buffer);
    return _Pass(
      buffer.createRenderPass(
        gpu.RenderTarget(
          colorAttachments: [for (final c in targets.color) _color(c)],
          depthStencilAttachment: targets.depth == null
              ? null
              : _depth(targets.depth!),
        ),
      ),
    );
  }

  @override
  Future<bool> submit({GpuSurfaceFrame? present}) {
    if (_buffers.isEmpty) _buffers.add(_context.createCommandBuffer());
    // The last pass holds the surface's final writes.
    if (present != null) {
      (present as _SurfaceFrame).native.present(_buffers.last);
    }
    final current = _frames.current;
    if (!_held.any((arena) => identical(arena, current))) {
      _held.add(_frames.hold(current));
    }
    final held = [..._held];
    _held.clear();
    final done = <Future<bool>>[];
    // A submit that throws keeps what it held: buffers already submitted
    // may still read it.
    for (final buffer in _buffers) {
      final completer = Completer<bool>();
      buffer.submit(completionCallback: completer.complete);
      done.add(completer.future);
    }
    _buffers.clear();
    return Future.wait(done).then((results) {
      for (final arena in held) {
        _frames.release(arena);
      }
      return results.every((ok) => ok);
    });
  }

  static gpu.ColorAttachment _color(GpuColorTarget c) => gpu.ColorAttachment(
    texture: (c.texture as _Texture).native,
    resolveTexture: (c.resolve as _Texture?)?.native,
    loadAction: _load(c.load),
    storeAction: _store(c.store),
    clearValue: vm.Vector4(c.clear.$1, c.clear.$2, c.clear.$3, c.clear.$4),
    mipLevel: c.mipLevel,
    slice: c.slice,
  );

  static gpu.DepthStencilAttachment _depth(GpuDepthTarget d) =>
      gpu.DepthStencilAttachment(
        texture: (d.texture as _Texture).native,
        depthLoadAction: _load(d.load),
        depthStoreAction: _store(d.store),
        depthClearValue: d.clearDepth,
        stencilLoadAction: _load(d.load),
        stencilStoreAction: _store(d.store),
      );
}

/// A buffer view as a value, to tell a repeat binding from a new one.
typedef _ViewKey = (gpu.DeviceBuffer, int, int);

_ViewKey _key(GpuBufferView view) {
  final v = (view as _View).native;
  return (v.buffer, v.offsetInBytes, v.lengthInBytes);
}

final class _Pass implements GpuPass {
  _Pass(this.native);

  final gpu.RenderPass native;
  _Pipeline? _pipeline;

  // What the pass holds now. Bindings and state stay on a flutter_gpu pass
  // until changed, and every call costs (some tens of microseconds each on
  // a phone's Vulkan driver), so a call repeating what is already there is
  // skipped.
  final Map<int, _ViewKey> _vertexBuffers = {};
  (_ViewKey, GpuIndexType)? _indexBuffer;
  final Map<gpu.UniformSlot, _ViewKey> _uniforms = Map.identity();
  final Map<gpu.UniformSlot, (gpu.Texture, GpuSampler)> _textures =
      Map.identity();
  (bool, gpu.CompareFunction)? _depth;
  (GpuCull, bool)? _cull;
  GpuBlend? _blend;
  GpuTopology? _topology;

  void _forget() {
    _vertexBuffers.clear();
    _indexBuffer = null;
    _uniforms.clear();
    _textures.clear();
    _depth = null;
    _cull = null;
    _blend = null;
    _topology = null;
  }

  @override
  void setPipeline(GpuPipeline pipeline) {
    if (identical(_pipeline, pipeline)) return;
    // Bindings stay on a flutter_gpu pass until cleared. Bindings made for
    // another pipeline must not reach this one's draws: Impeller would try
    // to fit them into its descriptor layout (seen as a crash on Vulkan).
    if (_pipeline != null) native.clearBindings();
    _forget();
    _pipeline = pipeline as _Pipeline;
    native.bindPipeline(pipeline.native);
  }

  @override
  void setVertexBuffer(int slot, GpuBufferView view) {
    final key = _key(view);
    if (_vertexBuffers[slot] == key) return;
    _vertexBuffers[slot] = key;
    native.bindVertexBuffer((view as _View).native, slot: slot);
  }

  @override
  void setIndexBuffer(GpuBufferView view, GpuIndexType type) {
    final key = (_key(view), type);
    if (_indexBuffer == key) return;
    _indexBuffer = key;
    native.bindIndexBuffer(
      (view as _View).native,
      type == GpuIndexType.uint16 ? gpu.IndexType.int16 : gpu.IndexType.int32,
    );
  }

  @override
  void setUniforms(String typeName, GpuBufferView view) {
    final pipeline = _requirePipeline();
    final key = _key(view);
    var bound = false;
    for (final shader in [pipeline.vertex, pipeline.fragment]) {
      final block = (shader as _Shader).uniformBlock(typeName);
      if (block == null) continue;
      bound = true;
      if (_uniforms[block.slot] == key) continue;
      _uniforms[block.slot] = key;
      native.bindUniform(block.slot, (view as _View).native);
    }
    if (!bound) {
      throw ArgumentError.value(
        typeName,
        'typeName',
        'No uniform block in ${pipeline.vertex.name}/${pipeline.fragment.name}',
      );
    }
  }

  @override
  void setTexture(
    String name,
    GpuTexture texture, {
    GpuSampler sampler = GpuSampler.linearClamp,
    bool vertexStage = false,
  }) {
    final pipeline = _requirePipeline();
    final shader =
        (vertexStage ? pipeline.vertex : pipeline.fragment) as _Shader;
    final slot = shader.sampler(name);
    final gpuTexture = (texture as _Texture).native;
    final bound = _textures[slot];
    if (bound != null &&
        identical(bound.$1, gpuTexture) &&
        _sameSampler(bound.$2, sampler)) {
      return;
    }
    _textures[slot] = (gpuTexture, sampler);
    _bindTexture(slot, texture, sampler);
  }

  static bool _sameSampler(GpuSampler a, GpuSampler b) =>
      identical(a, b) ||
      (a.minFilter == b.minFilter &&
          a.magFilter == b.magFilter &&
          a.mipFilter == b.mipFilter &&
          a.addressU == b.addressU &&
          a.addressV == b.addressV &&
          a.maxAnisotropy == b.maxAnisotropy);

  void _bindTexture(
    gpu.UniformSlot slot,
    GpuTexture texture,
    GpuSampler sampler,
  ) => native.bindTexture(
    slot,
    (texture as _Texture).native,
    sampler: gpu.SamplerOptions(
      minFilter: _filter(sampler.minFilter),
      magFilter: _filter(sampler.magFilter),
      mipFilter: sampler.mipFilter == GpuFilter.linear
          ? gpu.MipFilter.linear
          : gpu.MipFilter.nearest,
      widthAddressMode: _address(sampler.addressU),
      heightAddressMode: _address(sampler.addressV),
      maxAnisotropy: sampler.maxAnisotropy,
    ),
  );

  @override
  void setDepth({
    bool test = true,
    bool write = true,
    GpuCompare compare = GpuCompare.less,
  }) {
    final key = (write, test ? _compare(compare) : gpu.CompareFunction.always);
    if (_depth == key) return;
    _depth = key;
    native.setDepthWriteEnable(key.$1);
    native.setDepthCompareOperation(key.$2);
  }

  @override
  void setCull(GpuCull cull, {bool frontClockwise = false}) {
    if (_cull == (cull, frontClockwise)) return;
    _cull = (cull, frontClockwise);
    native.setCullMode(switch (cull) {
      GpuCull.none => gpu.CullMode.none,
      GpuCull.front => gpu.CullMode.frontFace,
      GpuCull.back => gpu.CullMode.backFace,
    });
    native.setWindingOrder(
      frontClockwise
          ? gpu.WindingOrder.clockwise
          : gpu.WindingOrder.counterClockwise,
    );
  }

  @override
  void setBlend(GpuBlend blend) {
    if (_blend == blend) return;
    _blend = blend;
    native.setColorBlendEnable(blend != GpuBlend.off);
    if (blend == GpuBlend.off) return;
    final (src, dst) = switch (blend) {
      GpuBlend.premultiplied => (
        gpu.BlendFactor.one,
        gpu.BlendFactor.oneMinusSourceAlpha,
      ),
      GpuBlend.alpha => (
        gpu.BlendFactor.sourceAlpha,
        gpu.BlendFactor.oneMinusSourceAlpha,
      ),
      GpuBlend.additive => (gpu.BlendFactor.one, gpu.BlendFactor.one),
      GpuBlend.off => throw StateError('unreachable'),
    };
    native.setColorBlendEquation(
      gpu.ColorBlendEquation(
        sourceColorBlendFactor: src,
        destinationColorBlendFactor: dst,
        sourceAlphaBlendFactor: gpu.BlendFactor.one,
        destinationAlphaBlendFactor: blend == GpuBlend.additive
            ? gpu.BlendFactor.one
            : gpu.BlendFactor.oneMinusSourceAlpha,
      ),
    );
  }

  @override
  void setTopology(GpuTopology topology) {
    if (_topology == topology) return;
    _topology = topology;
    native.setPrimitiveType(switch (topology) {
      GpuTopology.triangles => gpu.PrimitiveType.triangle,
      GpuTopology.triangleStrip => gpu.PrimitiveType.triangleStrip,
      GpuTopology.lines => gpu.PrimitiveType.line,
      GpuTopology.lineStrip => gpu.PrimitiveType.lineStrip,
      GpuTopology.points => gpu.PrimitiveType.point,
    });
  }

  @override
  void draw(int vertexCount, {int instances = 1}) =>
      native.draw(vertexCount, instanceCount: instances);

  @override
  void drawIndexed(int indexCount, {int instances = 1}) =>
      native.drawIndexed(indexCount, instanceCount: instances);

  _Pipeline _requirePipeline() =>
      _pipeline ?? (throw StateError('Call setPipeline first.'));
}

// ---- Surfaces -------------------------------------------------------------

final class _Surface implements GpuSurface {
  _Surface(this.native);

  final gpu.GpuImageSurface native;

  @override
  int get width => native.width;

  @override
  int get height => native.height;

  @override
  void resize(int width, int height) => native.resize(width, height);

  @override
  GpuSurfaceFrame acquire() {
    final frame = native.acquireNextFrame();
    return _SurfaceFrame(
      frame,
      _Texture(
        frame.colorTexture,
        GpuTextureDesc(
          width: native.width,
          height: native.height,
          format: _fromPixelFormat(native.format) ?? GpuFormat.rgba8,
          renderTarget: true,
        ),
      ),
    );
  }

  @override
  ui.Image? get image => native.currentImage;
}

final class _SurfaceFrame implements GpuSurfaceFrame {
  _SurfaceFrame(this.native, this.texture);

  final gpu.GpuImageSurfaceFrame native;

  @override
  final GpuTexture texture;

  @override
  void discard() => native.discard();
}

// ---- Mapping --------------------------------------------------------------

gpu.StorageMode _storageMode(GpuStorage s) => switch (s) {
  GpuStorage.host => gpu.StorageMode.hostVisible,
  GpuStorage.device => gpu.StorageMode.devicePrivate,
  GpuStorage.transient => gpu.StorageMode.deviceTransient,
};

gpu.LoadAction _load(GpuLoad l) => switch (l) {
  GpuLoad.clear => gpu.LoadAction.clear,
  GpuLoad.load => gpu.LoadAction.load,
  GpuLoad.dontCare => gpu.LoadAction.dontCare,
};

gpu.StoreAction _store(GpuStore s) => switch (s) {
  GpuStore.store => gpu.StoreAction.store,
  GpuStore.dontCare => gpu.StoreAction.dontCare,
  GpuStore.resolve => gpu.StoreAction.multisampleResolve,
  GpuStore.storeAndResolve => gpu.StoreAction.storeAndMultisampleResolve,
};

gpu.CompareFunction _compare(GpuCompare c) => switch (c) {
  GpuCompare.never => gpu.CompareFunction.never,
  GpuCompare.always => gpu.CompareFunction.always,
  GpuCompare.less => gpu.CompareFunction.less,
  GpuCompare.equal => gpu.CompareFunction.equal,
  GpuCompare.lessEqual => gpu.CompareFunction.lessEqual,
  GpuCompare.greater => gpu.CompareFunction.greater,
  GpuCompare.notEqual => gpu.CompareFunction.notEqual,
  GpuCompare.greaterEqual => gpu.CompareFunction.greaterEqual,
};

gpu.MinMagFilter _filter(GpuFilter f) =>
    f == GpuFilter.linear ? gpu.MinMagFilter.linear : gpu.MinMagFilter.nearest;

gpu.SamplerAddressMode _address(GpuAddress a) => switch (a) {
  GpuAddress.clamp => gpu.SamplerAddressMode.clampToEdge,
  GpuAddress.repeat => gpu.SamplerAddressMode.repeat,
  GpuAddress.mirror => gpu.SamplerAddressMode.mirror,
};

gpu.VertexLayout _vertexLayout(GpuVertexLayout layout) => gpu.VertexLayout(
  buffers: [
    for (final b in layout.buffers)
      gpu.VertexBuffer(
        strideInBytes: b.stride,
        stepMode: b.perInstance
            ? gpu.VertexStepMode.instance
            : gpu.VertexStepMode.vertex,
        attributes: [
          for (final a in b.attributes)
            gpu.VertexAttribute(
              name: a.name,
              format: _vertexFormat(a.format),
              offsetInBytes: a.offset,
            ),
        ],
      ),
  ],
);

gpu.VertexFormat _vertexFormat(GpuVertexFormat f) => switch (f) {
  GpuVertexFormat.float1 => gpu.VertexFormat.float32,
  GpuVertexFormat.float2 => gpu.VertexFormat.float32x2,
  GpuVertexFormat.float3 => gpu.VertexFormat.float32x3,
  GpuVertexFormat.float4 => gpu.VertexFormat.float32x4,
  GpuVertexFormat.uint1 => gpu.VertexFormat.uint32,
  GpuVertexFormat.uint4 => gpu.VertexFormat.uint32x4,
  GpuVertexFormat.sint1 => gpu.VertexFormat.sint32,
  GpuVertexFormat.sint4 => gpu.VertexFormat.sint32x4,
};

const _formats = <GpuFormat, gpu.PixelFormat>{
  GpuFormat.rgba8: gpu.PixelFormat.r8g8b8a8UNormInt,
  GpuFormat.rgba8Srgb: gpu.PixelFormat.r8g8b8a8UNormIntSRGB,
  GpuFormat.bgra8: gpu.PixelFormat.b8g8r8a8UNormInt,
  GpuFormat.bgra8Srgb: gpu.PixelFormat.b8g8r8a8UNormIntSRGB,
  GpuFormat.rgba16f: gpu.PixelFormat.r16g16b16a16Float,
  GpuFormat.rgba32f: gpu.PixelFormat.r32g32b32a32Float,
  GpuFormat.r32f: gpu.PixelFormat.r32Float,
  GpuFormat.depth24Stencil8: gpu.PixelFormat.d24UnormS8Uint,
  GpuFormat.depth32fStencil8: gpu.PixelFormat.d32FloatS8UInt,
  GpuFormat.etc2Rgb8: gpu.PixelFormat.etc2RGB8UNormInt,
  GpuFormat.etc2Rgb8Srgb: gpu.PixelFormat.etc2RGB8UNormIntSRGB,
  GpuFormat.etc2Rgba8: gpu.PixelFormat.etc2RGBA8UNormInt,
  GpuFormat.etc2Rgba8Srgb: gpu.PixelFormat.etc2RGBA8UNormIntSRGB,
  GpuFormat.astc4x4: gpu.PixelFormat.astc4x4LDR,
  GpuFormat.astc4x4Srgb: gpu.PixelFormat.astc4x4LDRSRGB,
  GpuFormat.astc8x8: gpu.PixelFormat.astc8x8LDR,
  GpuFormat.astc8x8Srgb: gpu.PixelFormat.astc8x8LDRSRGB,
  GpuFormat.bc7: gpu.PixelFormat.bc7RGBAUNormInt,
  GpuFormat.bc7Srgb: gpu.PixelFormat.bc7RGBAUNormIntSRGB,
};

gpu.PixelFormat _pixelFormat(GpuFormat f) => _formats[f]!;

GpuFormat? _fromPixelFormat(gpu.PixelFormat p) {
  for (final MapEntry(:key, :value) in _formats.entries) {
    if (value == p) return key;
  }
  return null;
}

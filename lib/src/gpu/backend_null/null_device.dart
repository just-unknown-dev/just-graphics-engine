import 'dart:typed_data';
import 'dart:ui' as ui;

import '../caps.dart';
import '../device.dart';
import '../formats.dart';

/// A [GpuDevice] that draws nothing and records what it was asked to do.
///
/// Renderer logic (sorting, batching, uniform packing, culling) is tested on
/// it without a GPU, and it stands in when no GPU is available, so code
/// that renders keeps running headless. [log] holds one line per command.
final class NullGpuDevice implements GpuDevice {
  /// A null device reporting [caps], whose shader libraries hold [shaders]
  /// (name → uniform blocks, each block name → member offsets and size).
  NullGpuDevice({this.caps = GpuCaps.all, this.shaders = const {}});

  /// Shader name → its uniform blocks by GLSL type name.
  final Map<String, Map<String, NullUniformBlock>> shaders;
  final Map<(GpuShader, GpuShader, String), _NullPipeline> _pipelines = {};

  @override
  final GpuCaps caps;

  /// Every command, in order.
  final List<String> log = [];

  /// Draw commands recorded since the last [clearLog].
  int get drawCount => log.where((l) => l.startsWith('draw')).length;

  /// How many pipelines were created (each distinct one counts once).
  int get pipelineCount => _pipelines.length;

  /// Bytes copied through [frameData] since the last [beginFrame].
  int frameBytes = 0;

  /// Empties [log].
  void clearLog() => log.clear();

  @override
  GpuBuffer createBuffer(ByteData data) {
    log.add('buffer ${data.lengthInBytes}');
    return _NullBuffer(data.lengthInBytes);
  }

  @override
  GpuBuffer createHostBuffer(int sizeInBytes) {
    log.add('hostBuffer $sizeInBytes');
    return _NullBuffer(sizeInBytes);
  }

  @override
  GpuTexture createTexture(GpuTextureDesc desc) {
    log.add('texture $desc');
    return _NullTexture(desc);
  }

  @override
  int maxMipLevels(int width, int height) =>
      GpuTextureDesc.fullMipCount(width, height);

  @override
  Future<GpuShaderLibrary> loadShaderLibrary(String fileName) async =>
      _NullLibrary(shaders);

  @override
  GpuPipeline pipeline(
    GpuShader vertex,
    GpuShader fragment, {
    GpuVertexLayout? layout,
  }) => _pipelines.putIfAbsent((vertex, fragment, layout?.key ?? ''), () {
    log.add('pipeline ${vertex.name}+${fragment.name}');
    return _NullPipeline(vertex, fragment);
  });

  @override
  void beginFrame() {
    frameBytes = 0;
    log.add('beginFrame');
  }

  @override
  GpuBufferView frameData(ByteData data) {
    final view = _NullView(frameBytes, data.lengthInBytes);
    frameBytes += data.lengthInBytes;
    return view;
  }

  @override
  GpuCommands commands() => _NullCommands(log);

  @override
  GpuSurface createSurface(int width, int height) =>
      _NullSurface(width, height);
}

/// A uniform block a [NullGpuDevice] shader declares.
final class NullUniformBlock implements GpuUniformBlock {
  /// A block of [sizeInBytes] with member [offsets].
  const NullUniformBlock(this.name, this.sizeInBytes, this.offsets);

  @override
  final String name;

  @override
  final int sizeInBytes;

  /// Member name → byte offset.
  final Map<String, int> offsets;

  @override
  int? offsetOf(String member) => offsets[member];
}

final class _NullBuffer implements GpuBuffer {
  _NullBuffer(this.sizeInBytes);

  @override
  final int sizeInBytes;

  @override
  GpuBufferView view([int offset = 0, int? length]) =>
      _NullView(offset, length ?? sizeInBytes - offset);

  @override
  void write(ByteData data, {int offset = 0}) {
    if (offset + data.lengthInBytes > sizeInBytes) {
      throw StateError('Buffer write out of range.');
    }
  }
}

final class _NullView implements GpuBufferView {
  _NullView(this.offset, this.length);

  @override
  final int offset;

  @override
  final int length;
}

final class _NullTexture implements GpuTexture {
  _NullTexture(this.desc);

  @override
  final GpuTextureDesc desc;

  @override
  void upload(ByteData data, {int mipLevel = 0, int slice = 0}) {}

  @override
  ui.Image toImage() =>
      throw UnsupportedError('The null GPU device draws nothing.');
}

final class _NullLibrary implements GpuShaderLibrary {
  _NullLibrary(this._shaders);

  final Map<String, Map<String, NullUniformBlock>> _shaders;
  final Map<String, _NullShader> _cache = {};

  @override
  GpuShader? operator [](String name) {
    final blocks = _shaders[name];
    if (blocks == null) return null;
    return _cache.putIfAbsent(name, () => _NullShader(name, blocks));
  }
}

final class _NullShader implements GpuShader {
  _NullShader(this.name, this._blocks);

  final Map<String, NullUniformBlock> _blocks;

  @override
  final String name;

  @override
  GpuUniformBlock? uniformBlock(String typeName) => _blocks[typeName];
}

final class _NullPipeline implements GpuPipeline {
  _NullPipeline(this.vertex, this.fragment);

  @override
  final GpuShader vertex;

  @override
  final GpuShader fragment;

  @override
  GpuUniformBlock? uniformBlock(String typeName) =>
      vertex.uniformBlock(typeName) ?? fragment.uniformBlock(typeName);
}

final class _NullCommands implements GpuCommands {
  _NullCommands(this.log);

  final List<String> log;

  @override
  GpuPass beginPass(GpuRenderTargets targets) {
    log.add(
      'pass ${targets.color.length} colour${targets.depth == null ? '' : ' +depth'}',
    );
    return _NullPass(log);
  }

  @override
  Future<bool> submit({GpuSurfaceFrame? present}) async {
    log.add(present == null ? 'submit' : 'submit+present');
    return true;
  }
}

final class _NullPass implements GpuPass {
  _NullPass(this.log);

  final List<String> log;
  GpuPipeline? _pipeline;

  @override
  void setPipeline(GpuPipeline pipeline) {
    _pipeline = pipeline;
    log.add('setPipeline ${pipeline.vertex.name}+${pipeline.fragment.name}');
  }

  @override
  void setVertexBuffer(int slot, GpuBufferView view) =>
      log.add('vertexBuffer $slot ${view.length}');

  @override
  void setIndexBuffer(GpuBufferView view, GpuIndexType type) =>
      log.add('indexBuffer ${type.name} ${view.length}');

  @override
  void setUniforms(String typeName, GpuBufferView view) {
    final pipeline = _pipeline ?? (throw StateError('Call setPipeline first.'));
    if (pipeline.uniformBlock(typeName) == null) {
      throw ArgumentError.value(typeName, 'typeName', 'No such uniform block');
    }
    log.add('uniforms $typeName ${view.length}');
  }

  @override
  void setTexture(
    String name,
    GpuTexture texture, {
    GpuSampler sampler = GpuSampler.linearClamp,
    bool vertexStage = false,
  }) => log.add('texture $name${vertexStage ? ' (vertex)' : ''}');

  @override
  void setDepth({
    bool test = true,
    bool write = true,
    GpuCompare compare = GpuCompare.less,
  }) => log.add('depth test:$test write:$write ${compare.name}');

  @override
  void setCull(GpuCull cull, {bool frontClockwise = false}) =>
      log.add('cull ${cull.name}${frontClockwise ? ' cw' : ' ccw'}');

  @override
  void setBlend(GpuBlend blend) => log.add('blend ${blend.name}');

  @override
  void setTopology(GpuTopology topology) =>
      log.add('topology ${topology.name}');

  @override
  void draw(int vertexCount, {int instances = 1}) =>
      log.add('draw $vertexCount x$instances');

  @override
  void drawIndexed(int indexCount, {int instances = 1}) =>
      log.add('drawIndexed $indexCount x$instances');
}

final class _NullSurface implements GpuSurface {
  _NullSurface(this.width, this.height);

  @override
  int width;

  @override
  int height;

  @override
  void resize(int width, int height) {
    this.width = width;
    this.height = height;
  }

  @override
  GpuSurfaceFrame acquire() => _NullSurfaceFrame(
    _NullTexture(
      GpuTextureDesc(width: width, height: height, renderTarget: true),
    ),
  );

  @override
  ui.Image? get image => null;
}

final class _NullSurfaceFrame implements GpuSurfaceFrame {
  _NullSurfaceFrame(this.texture);

  @override
  final GpuTexture texture;

  @override
  void discard() {}
}

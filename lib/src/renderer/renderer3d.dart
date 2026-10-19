import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import '../assets/model_data.dart';
import '../gpu/clip_fixup.dart';
import '../gpu/create_device.dart';
import '../gpu/device.dart';
import '../gpu/formats.dart';
import '../gpu/pipeline_set.dart';
import '../gpu/render_target_pool.dart';
import '../gpu/sort_key.dart';
import '../gpu/uniform_writer.dart';
import 'gpu_model.dart';
import 'instance_batch.dart';
import 'render_scene.dart';
import 'shadows.dart';
import 'skinning.dart';

const GpuVertexBufferLayout _vertices = GpuVertexBufferLayout(
  stride: VertexOffsets.stride,
  attributes: [
    GpuVertexAttribute(
      'position',
      GpuVertexFormat.float3,
      VertexOffsets.position,
    ),
    GpuVertexAttribute('normal', GpuVertexFormat.float3, VertexOffsets.normal),
    GpuVertexAttribute(
      'tangent',
      GpuVertexFormat.float4,
      VertexOffsets.tangent,
    ),
    GpuVertexAttribute('texcoord', GpuVertexFormat.float2, VertexOffsets.uv),
    GpuVertexAttribute('color', GpuVertexFormat.float4, VertexOffsets.color),
  ],
);

const GpuVertexBufferLayout _positions = GpuVertexBufferLayout(
  stride: VertexOffsets.stride,
  attributes: [
    GpuVertexAttribute(
      'position',
      GpuVertexFormat.float3,
      VertexOffsets.position,
    ),
  ],
);

const GpuVertexBufferLayout _skin = GpuVertexBufferLayout(
  stride: kSkinFloats * 4,
  attributes: [
    GpuVertexAttribute('joints', GpuVertexFormat.float4, 0),
    GpuVertexAttribute('weights', GpuVertexFormat.float4, 16),
  ],
);

const List<GpuVertexAttribute> _model = [
  GpuVertexAttribute('model_0', GpuVertexFormat.float4, 0),
  GpuVertexAttribute('model_1', GpuVertexFormat.float4, 16),
  GpuVertexAttribute('model_2', GpuVertexFormat.float4, 32),
  GpuVertexAttribute('model_3', GpuVertexFormat.float4, 48),
];

const List<GpuVertexAttribute> _normalMatrix = [
  GpuVertexAttribute('normal_0', GpuVertexFormat.float4, 64),
  GpuVertexAttribute('normal_1', GpuVertexFormat.float4, 80),
  GpuVertexAttribute('normal_2', GpuVertexFormat.float4, 96),
];

const GpuVertexAttribute _paletteStart = GpuVertexAttribute(
  'skin',
  GpuVertexFormat.float4,
  112,
);

/// Floats per static instance: a model matrix and a normal matrix.
const int _instanceFloats = 28;

/// Floats per skinned instance: those, then where its palette starts.
const int _skinnedInstanceFloats = 32;

/// The vertex layout of every lit mesh: one vertex buffer
/// ([VertexOffsets]) and one per-instance buffer of a model matrix and a
/// normal matrix.
const GpuVertexLayout litLayout = GpuVertexLayout([
  _vertices,
  GpuVertexBufferLayout(
    stride: _instanceFloats * 4,
    perInstance: true,
    attributes: [..._model, ..._normalMatrix],
  ),
]);

/// Skinned lit meshes: vertices, joints and weights, then per instance the
/// matrices and the palette's first texel.
const GpuVertexLayout litSkinnedLayout = GpuVertexLayout([
  _vertices,
  _skin,
  GpuVertexBufferLayout(
    stride: _skinnedInstanceFloats * 4,
    perInstance: true,
    attributes: [..._model, ..._normalMatrix, _paletteStart],
  ),
]);

const GpuVertexLayout _litSkinnedUniformLayout = GpuVertexLayout([
  _vertices,
  _skin,
  GpuVertexBufferLayout(
    stride: _skinnedInstanceFloats * 4,
    perInstance: true,
    attributes: [..._model, ..._normalMatrix],
  ),
]);

const GpuVertexLayout _shadowLayout = GpuVertexLayout([
  _positions,
  GpuVertexBufferLayout(
    stride: _instanceFloats * 4,
    perInstance: true,
    attributes: _model,
  ),
]);

const GpuVertexLayout _shadowSkinnedLayout = GpuVertexLayout([
  _positions,
  _skin,
  GpuVertexBufferLayout(
    stride: _skinnedInstanceFloats * 4,
    perInstance: true,
    attributes: [..._model, _paletteStart],
  ),
]);

const GpuVertexLayout _shadowSkinnedUniformLayout = GpuVertexLayout([
  _positions,
  _skin,
  GpuVertexBufferLayout(
    stride: _skinnedInstanceFloats * 4,
    perInstance: true,
    attributes: _model,
  ),
]);

const GpuVertexLayout _fullscreenLayout = GpuVertexLayout([
  GpuVertexBufferLayout(
    stride: 8,
    attributes: [GpuVertexAttribute('position', GpuVertexFormat.float2, 0)],
  ),
]);

/// The pipelines the renderer draws with.
abstract final class RendererPipelines {
  /// Lit meshes.
  static const lit = PipelineSpec(
    'LitVertex',
    'LitFragment',
    layout: litLayout,
  );

  /// Skinned lit meshes, palettes in a texture.
  static const litSkinned = PipelineSpec(
    'LitSkinnedVertex',
    'LitFragment',
    layout: litSkinnedLayout,
  );

  /// Skinned lit meshes, palette in a uniform block.
  static const litSkinnedUniform = PipelineSpec(
    'LitSkinnedUniformVertex',
    'LitFragment',
    layout: _litSkinnedUniformLayout,
  );

  /// Shadow casters.
  static const shadow = PipelineSpec(
    'ShadowVertex',
    'ShadowFragment',
    layout: _shadowLayout,
  );

  /// Skinned shadow casters, palettes in a texture.
  static const shadowSkinned = PipelineSpec(
    'ShadowSkinnedVertex',
    'ShadowFragment',
    layout: _shadowSkinnedLayout,
  );

  /// Skinned shadow casters, palette in a uniform block.
  static const shadowSkinnedUniform = PipelineSpec(
    'ShadowSkinnedUniformVertex',
    'ShadowFragment',
    layout: _shadowSkinnedUniformLayout,
  );

  /// The gradient sky.
  static const sky = PipelineSpec(
    'FullscreenVertex',
    'SkyFragment',
    layout: _fullscreenLayout,
  );

  /// HDR to the display.
  static const tonemap = PipelineSpec(
    'FullscreenVertex',
    'TonemapFragment',
    layout: _fullscreenLayout,
  );

  /// Bloom: bright pass and halving.
  static const bloomDown = PipelineSpec(
    'FullscreenVertex',
    'BloomDownFragment',
    layout: _fullscreenLayout,
  );

  /// Bloom: blurring back up.
  static const bloomUp = PipelineSpec(
    'FullscreenVertex',
    'BloomUpFragment',
    layout: _fullscreenLayout,
  );

  /// Edge smoothing after tonemapping.
  static const fxaa = PipelineSpec(
    'FullscreenVertex',
    'FxaaFragment',
    layout: _fullscreenLayout,
  );

  /// Lines over the scene: edges for a wireframe or a highlight. Reads the
  /// same buffers a shadow draw does (positions, model matrices).
  static const wire = PipelineSpec(
    'WireVertex',
    'ColorFragment',
    layout: _shadowLayout,
  );

  /// All of them.
  static const all = [
    lit,
    litSkinned,
    litSkinnedUniform,
    shadow,
    shadowSkinned,
    shadowSkinnedUniform,
    sky,
    tonemap,
    bloomDown,
    bloomUp,
    fxaa,
    wire,
  ];
}

/// The glow around bright things (HDR only).
final class BloomSettings {
  /// Whether it is drawn. Off by default: it costs a chain of small passes.
  bool enabled = false;

  /// How bright (linear, before exposure) light must be to glow.
  double threshold = 1.0;

  /// How gently light past the threshold starts to glow, 0..1.
  double knee = 0.5;

  /// How strong the glow is.
  double intensity = 0.6;

  /// How many halvings the blur goes through (how wide it spreads), 1..8.
  int levels = 5;
}

/// What the last frame did.
final class RenderStats {
  /// Draw calls issued, the shadow pass's included.
  int drawCalls = 0;

  /// Draw calls of the shadow pass.
  int shadowDrawCalls = 0;

  /// Instances drawn.
  int instances = 0;

  /// Of [instances], how many were skinned.
  int skinnedInstances = 0;

  /// Instances drawn into the shadow map.
  int shadowCasters = 0;

  /// Triangles drawn (not counting the shadow pass).
  int triangles = 0;

  /// Instances skipped by frustum culling.
  int culled = 0;

  /// Instance batches drawn (each one call, its instances counted in
  /// [instances]).
  int batches = 0;

  /// Point and spot lights used.
  int lights = 0;

  /// Joints uploaded.
  int joints = 0;

  @override
  String toString() =>
      'RenderStats(draws $drawCalls (shadow $shadowDrawCalls), instances '
      '$instances (skinned $skinnedInstances), casters $shadowCasters, '
      'triangles $triangles, culled $culled, batches $batches, lights $lights, '
      'joints $joints)';
}

/// The uniforms and textures every lit draw of a frame binds.
final class _LitBindings {
  _LitBindings(
    this.frame,
    this.lights,
    this.shadowMap,
    this.shadowMap2,
    this.joints,
    this.environment,
  );

  final GpuBufferView frame;
  final GpuBufferView lights;
  final GpuTexture shadowMap;
  final GpuTexture shadowMap2;

  /// The environment cube (a black one when there is none).
  final GpuTexture environment;
  final GpuTexture? joints;
}

/// Forward renderer for [RenderScene]s: physically based lighting from a
/// sun (with two cascades of shadow maps), up to 8 point/spot lights and a hemisphere
/// ambient; skinned meshes; a gradient sky; HDR with 4x MSAA and ACES
/// tonemapping where the device can.
final class Renderer3D {
  Renderer3D._(this.device, this._pipelines, this.defaults)
    : targets = RenderTargetPool(device),
      uploader = ModelUploader(device, defaults),
      skinning = device.caps.floatTextures
          ? SkinningMode.texture
          : SkinningMode.uniforms,
      _fullscreen = device.createBuffer(
        Float32List.fromList([-1, -1, 3, -1, -1, 3]).buffer.asByteData(),
      );

  /// Creates a renderer on [device], loading and creating every pipeline
  /// up front.
  static Future<Renderer3D> create(GpuDevice device) async {
    final pipelines = await PipelineSet.load(
      device,
      'core.shaderbundle',
      RendererPipelines.all,
    );
    return Renderer3D._(device, pipelines, DefaultTextures(device));
  }

  /// A renderer on [device], or on this platform's GPU when that is null —
  /// or null, after telling [onUnsupported] why, where there is no Flutter
  /// GPU (see [createGpuDevice]) or the renderer fails to start.
  ///
  /// ```dart
  /// String? reason;
  /// final renderer = await Renderer3D.tryCreate(onUnsupported: (r) => reason = r);
  /// ```
  static Future<Renderer3D?> tryCreate({
    GpuDevice? device,
    void Function(String reason)? onUnsupported,
  }) async {
    final gpu = device ?? createGpuDevice(onUnsupported: onUnsupported);
    if (gpu == null) return null;
    try {
      return await create(gpu);
    } on Object catch (error) {
      onUnsupported?.call('The 3D renderer could not start: $error');
      return null;
    }
  }

  /// The device it draws with.
  final GpuDevice device;

  /// Intermediate targets, reused frame to frame.
  final RenderTargetPool targets;

  /// Stand-ins for missing material maps.
  final DefaultTextures defaults;

  /// Uploads models for this renderer.
  final ModelUploader uploader;

  final PipelineSet _pipelines;
  final GpuBuffer _fullscreen;

  /// What the last [render] did.
  final RenderStats stats = RenderStats();

  /// Whether to multisample (when the device can).
  bool msaa = true;

  /// The sun's shadows.
  final ShadowSettings shadows = ShadowSettings();

  /// Glow around bright things.
  final BloomSettings bloom = BloomSettings();

  /// Smooths edges after tonemapping (HDR only): for devices that draw
  /// without MSAA ([msaa] off, or not supported).
  bool fxaa = false;

  /// How the scene is drawn: lit, as the game draws it; unlit, to read
  /// shapes by; or as edges only (an editor's views).
  RenderViewMode viewMode = RenderViewMode.lit;

  /// A slice through the scene: nothing on the far side of the plane —
  /// (normal x, y, z, distance along it) — is drawn. Null for none.
  (double, double, double, double)? clipPlane;

  /// The colour [RenderViewMode.wireframe] draws edges in.
  (double, double, double, double) wireColor = (0.78, 0.82, 0.88, 0.85);

  /// How joint palettes reach the GPU: a texture where the device can read
  /// float textures in the vertex stage, else uniform blocks.
  SkinningMode skinning;

  /// Joints per row of the joint texture (three texels each).
  static const int jointsPerRow = 256;

  // Scratch, reused every frame.
  final Matrix4 _engineViewProjection = Matrix4.identity();
  final Matrix4 _gpuProjection = Matrix4.identity();
  final Matrix4 _gpuViewProjection = Matrix4.identity();
  final Matrix4 _gpuShadowProjection = Matrix4.identity();
  final Matrix4 _gpuShadowViewProjection = Matrix4.identity();
  final Matrix4 _inverse = Matrix4.identity();
  final Frustum _frustum = Frustum();
  final Vector3 _centre = Vector3.zero();
  final List<ShadowFit> _shadowFits = [ShadowFit(), ShadowFit()];
  int _cascades = 0;
  double _cascadeSplit = 0;
  final List<(int, MeshInstance)> _opaque = [];
  final List<(int, MeshInstance)> _transparent = [];
  final List<List<(int, MeshInstance)>> _casters = [[], []];
  final Map<GpuMaterial, int> _materialIds = {};
  final List<InstanceBatch> _batches = [];
  final List<List<InstanceBatch>> _batchCasters = [[], []];
  final Float32List _single = Float32List(kBatchInstanceFloats);
  final Map<GpuPrimitive, int> _primitiveIds = {};
  final List<SkinPalette> _palettes = [];
  Float32List _instanceData = Float32List(_skinnedInstanceFloats * 256);
  Float32List _jointData = Float32List(0);
  // Joint textures the GPU has finished drawing with, free to write again:
  // a frame takes one and gives it back once drawn. Frames drawn faster
  // than the GPU runs them (an editor's views, each a frame) each have
  // their own.
  final List<GpuTexture> _spareJoints = [];
  int _frame = 0;

  bool _skinned(MeshInstance i) => i.skin != null && i.primitive.skin != null;

  /// Draws [scene] seen from [view] into a new frame of [surface] and
  /// presents it. Completes when the GPU has finished.
  Future<bool> render(RenderScene scene, RenderView view, GpuSurface surface) {
    final caps = device.caps;
    final hdr = caps.hdrRenderTarget;
    final samples = msaa && caps.msaa ? 4 : 1;
    final width = math.max(1, view.width), height = math.max(1, view.height);
    if (surface.width != width || surface.height != height) {
      surface.resize(width, height);
    }

    device.beginFrame();
    _resetStats();
    _frame++;
    _engineViewProjection.setProduct(view.projection, view.view);
    _frustum.setFromViewProjection(_engineViewProjection);
    ClipFixup.flipY(view.projection, _gpuProjection);
    _gpuViewProjection.setProduct(_gpuProjection, view.view);

    _collect(scene, view);
    final sun = scene.sun;
    _cascades = 0;
    if (shadows.enabled && shadows.strength > 0 && sun.enabled) {
      final count = shadows.cascades.clamp(1, 2);
      _cascadeSplit = shadows.distance * shadows.cascadeSplit.clamp(0.05, 0.95);
      if (fitSunShadow(
        view,
        sun.direction,
        shadows,
        _shadowFits[0],
        to: count == 2 ? _cascadeSplit : null,
      )) {
        _cascades = 1;
        if (count == 2 &&
            fitSunShadow(
              view,
              sun.direction,
              shadows,
              _shadowFits[1],
              from: _cascadeSplit,
            )) {
          _cascades = 2;
        }
      }
    }
    // Lines only: nothing to shadow.
    if (viewMode == RenderViewMode.wireframe) _cascades = 0;
    final shadowed = _cascades > 0;
    for (final list in _casters) {
      list.clear();
    }
    for (final list in _batchCasters) {
      list.clear();
    }
    for (var c = 0; c < _cascades; c++) {
      _collectCasters(scene, _shadowFits[c], _casters[c]);
      _collectBatchCasters(scene, view, _shadowFits[c], _batchCasters[c]);
    }
    final joints = skinning == SkinningMode.texture ? _packPalettes() : null;

    final frameUniforms = device.frameData(
      _frameBlock(scene, view, toDisplay: !hdr, shadowed: shadowed),
    );
    final lightUniforms = device.frameData(_lightsBlock(scene, view));

    final frame = surface.acquire();
    final commands = device.commands();
    final maps = [
      for (var c = 0; c < _cascades; c++)
        _shadowPass(
          commands,
          joints,
          _shadowFits[c],
          _casters[c],
          _batchCasters[c],
        ),
    ];
    final bindings = _LitBindings(
      frameUniforms,
      lightUniforms,
      maps.isEmpty ? defaults.white : maps[0],
      maps.length > 1 ? maps[1] : defaults.white,
      joints,
      scene.environment.map?.texture ?? defaults.blackCube,
    );

    final env = scene.environment;
    final clear = (
      env.clearColor.$1,
      env.clearColor.$2,
      env.clearColor.$3,
      1.0,
    );
    final colorFormat = hdr ? GpuFormat.rgba16f : frame.texture.desc.format;

    final depth = targets.acquire(
      GpuTextureDesc(
        width: width,
        height: height,
        format: caps.depthFormat,
        storage: GpuStorage.transient,
        samples: samples,
        renderTarget: true,
        shaderRead: false,
      ),
    );
    // Where the scene is resolved to: an HDR texture, or the surface itself.
    final GpuTexture resolved = hdr
        ? targets.acquire(
            GpuTextureDesc(
              width: width,
              height: height,
              format: GpuFormat.rgba16f,
              renderTarget: true,
            ),
          )
        : frame.texture;
    final GpuColorTarget color = samples > 1
        ? GpuColorTarget(
            targets.acquire(
              GpuTextureDesc(
                width: width,
                height: height,
                format: colorFormat,
                storage: GpuStorage.transient,
                samples: samples,
                renderTarget: true,
                shaderRead: false,
              ),
            ),
            clear: clear,
            resolve: resolved,
            store: GpuStore.resolve,
          )
        : GpuColorTarget(resolved, clear: clear);

    final pass = commands.beginPass(
      GpuRenderTargets([color], depth: GpuDepthTarget(depth)),
    );
    final filled = viewMode != RenderViewMode.wireframe;
    if (filled) {
      _drawList(pass, _opaque, bindings, transparent: false);
      _drawBatches(pass, bindings);
    }

    if (env.sky) {
      final sky = _pipelines[RendererPipelines.sky];
      pass
        ..setPipeline(sky)
        ..setUniforms(
          'Sky',
          device.frameData(_skyBlock(sky, scene, view, toDisplay: !hdr)),
        )
        ..setTexture(
          'environment_texture',
          env.map?.texture ?? defaults.blackCube,
          sampler: GpuSampler.linearClamp,
        )
        ..setVertexBuffer(0, _fullscreen.view())
        ..setDepth(write: false, compare: GpuCompare.lessEqual)
        ..setCull(GpuCull.none)
        ..setBlend(GpuBlend.off)
        ..draw(3);
      stats.drawCalls++;
    }

    if (filled && _transparent.isNotEmpty) {
      _drawList(pass, _transparent, bindings, transparent: true);
    }
    // Lines last: a wireframe's every edge, then what is drawn over the
    // scene (a selection's highlight).
    if (!filled) _drawWireframe(pass);
    if (scene.overlays.isNotEmpty) _drawOverlays(pass, scene.overlays);

    if (hdr) {
      final glow = bloom.enabled && bloom.intensity > 0
          ? _bloom(commands, resolved, width, height)
          : null;
      final smooth = fxaa;
      final surfaceEncodes = frame.texture.desc.format.isSrgb;
      // With FXAA, tonemap into a display-encoded image first.
      final toned = smooth
          ? targets.acquire(
              GpuTextureDesc(width: width, height: height, renderTarget: true),
            )
          : frame.texture;
      final tonemap = _pipelines[RendererPipelines.tonemap];
      final block = tonemap.uniformBlock('Tonemap')!;
      final w = UniformWriter(block.sizeInBytes)
        ..vec4(
          block.offsetOf('options')!,
          env.exposure,
          smooth || !surfaceEncodes ? 1 : 0,
          glow == null ? 0 : bloom.intensity,
          0,
        );
      commands.beginPass(
          GpuRenderTargets([GpuColorTarget(toned, load: GpuLoad.dontCare)]),
        )
        ..setPipeline(tonemap)
        ..setUniforms('Tonemap', device.frameData(w.bytes))
        ..setTexture('hdr_texture', resolved, sampler: GpuSampler.nearestClamp)
        ..setTexture(
          'bloom_texture',
          glow ?? defaults.black,
          sampler: GpuSampler.linearClamp,
        )
        ..setVertexBuffer(0, _fullscreen.view())
        ..setDepth(test: false, write: false)
        ..setCull(GpuCull.none)
        ..draw(3);
      stats.drawCalls++;
      if (smooth) {
        final fx = _pipelines[RendererPipelines.fxaa];
        final fb = fx.uniformBlock('Fxaa')!;
        final f = UniformWriter(fb.sizeInBytes)
          ..vec4(
            fb.offsetOf('texel')!,
            1 / width,
            1 / height,
            surfaceEncodes ? 1 : 0,
            0,
          );
        commands.beginPass(
            GpuRenderTargets([
              GpuColorTarget(frame.texture, load: GpuLoad.dontCare),
            ]),
          )
          ..setPipeline(fx)
          ..setUniforms('Fxaa', device.frameData(f.bytes))
          ..setTexture('source', toned, sampler: GpuSampler.linearClamp)
          ..setVertexBuffer(0, _fullscreen.view())
          ..setDepth(test: false, write: false)
          ..setCull(GpuCull.none)
          ..draw(3);
        stats.drawCalls++;
      }
    }

    final done = commands.submit(present: frame);
    targets.endFrame();
    if (joints != null) {
      unawaited(
        done.then((_) {
          if (_spareJoints.length < 4) _spareJoints.add(joints);
        }, onError: (Object _) {}),
      );
    }
    return done;
  }

  /// The bloom of [hdr]: a bright pass halving it, more halvings, then
  /// back up, each level added onto the one above. Returns the
  /// half-resolution result. Separate targets per level: OpenGL ES can't
  /// render into mip levels.
  GpuTexture _bloom(
    GpuCommands commands,
    GpuTexture hdr,
    int width,
    int height,
  ) {
    final down = _pipelines[RendererPipelines.bloomDown];
    final up = _pipelines[RendererPipelines.bloomUp];
    final downBlock = down.uniformBlock('BloomDown')!;
    final upBlock = up.uniformBlock('BloomUp')!;
    final levels = <GpuTexture>[];
    var source = hdr;
    var w = width, h = height;
    final count = bloom.levels.clamp(1, 8);
    for (var i = 0; i < count; i++) {
      final sw = w, sh = h;
      w = math.max(1, w ~/ 2);
      h = math.max(1, h ~/ 2);
      final target = targets.acquire(
        GpuTextureDesc(
          width: w,
          height: h,
          format: GpuFormat.rgba16f,
          renderTarget: true,
        ),
      );
      final u = UniformWriter(downBlock.sizeInBytes)
        ..vec4(downBlock.offsetOf('texel')!, 1 / sw, 1 / sh, 0, 0)
        ..vec4(
          downBlock.offsetOf('options')!,
          bloom.threshold,
          bloom.knee,
          i == 0 ? 1 : 0,
          0,
        );
      commands.beginPass(
          GpuRenderTargets([GpuColorTarget(target, load: GpuLoad.dontCare)]),
        )
        ..setPipeline(down)
        ..setUniforms('BloomDown', device.frameData(u.bytes))
        ..setTexture('source', source, sampler: GpuSampler.linearClamp)
        ..setVertexBuffer(0, _fullscreen.view())
        ..setDepth(test: false, write: false)
        ..setCull(GpuCull.none)
        ..draw(3);
      stats.drawCalls++;
      levels.add(target);
      source = target;
      if (w == 1 && h == 1) break;
    }
    for (var i = levels.length - 1; i > 0; i--) {
      final small = levels[i], large = levels[i - 1];
      final u = UniformWriter(upBlock.sizeInBytes)
        ..vec4(
          upBlock.offsetOf('texel')!,
          1 / small.desc.width,
          1 / small.desc.height,
          0,
          0,
        )
        ..vec4(upBlock.offsetOf('options')!, 1, 1, 0, 0);
      commands.beginPass(
          GpuRenderTargets([GpuColorTarget(large, load: GpuLoad.load)]),
        )
        ..setPipeline(up)
        ..setUniforms('BloomUp', device.frameData(u.bytes))
        ..setTexture('source', small, sampler: GpuSampler.linearClamp)
        ..setVertexBuffer(0, _fullscreen.view())
        ..setDepth(test: false, write: false)
        ..setCull(GpuCull.none)
        ..setBlend(GpuBlend.additive)
        ..draw(3);
      stats.drawCalls++;
    }
    return levels.first;
  }

  void _resetStats() {
    stats
      ..drawCalls = 0
      ..shadowDrawCalls = 0
      ..instances = 0
      ..skinnedInstances = 0
      ..shadowCasters = 0
      ..triangles = 0
      ..culled = 0
      ..batches = 0
      ..lights = 0
      ..joints = 0;
  }

  int _primitiveId(GpuPrimitive p) => _primitiveIds.putIfAbsent(
    p,
    () => _primitiveIds.length % (SortKey.maxMesh + 1),
  );

  /// Culls, keys and sorts the scene's instances.
  void _collect(RenderScene scene, RenderView view) {
    _opaque.clear();
    _transparent.clear();
    _materialIds.clear();
    _primitiveIds.clear();
    // Depth buckets cover the visible range along the camera's distance.
    const near = 0.0;
    const far = 1000.0;
    for (final instance in scene.instances) {
      if (!instance.visible) continue;
      final bounds = instance.bounds;
      if (!_frustum.intersectsAabb(bounds)) {
        stats.culled++;
        continue;
      }
      final material = _materialIds.putIfAbsent(
        instance.material,
        () => _materialIds.length % (SortKey.maxMaterial + 1),
      );
      final mesh = _primitiveId(instance.primitive);
      final pipeline = _skinned(instance) ? 1 : 0;
      bounds.centerInto(_centre);
      final distance = _centre.distanceTo(view.cameraPosition);
      final bucket = SortKey.depthBucket(distance, near, far);
      final data = instance.material.data;
      if (data.alphaMode == AlphaMode.blend) {
        _transparent.add((
          SortKey.transparent(
            phase: 3,
            depth: SortKey.maxDepth - bucket,
            pipeline: pipeline,
            material: material,
            mesh: mesh,
          ),
          instance,
        ));
      } else {
        _opaque.add((
          SortKey.opaque(
            phase: data.alphaMode == AlphaMode.mask ? 2 : 1,
            pipeline: pipeline,
            material: material,
            mesh: mesh,
            depth: bucket,
          ),
          instance,
        ));
      }
    }
    _opaque.sort((a, b) => a.$1.compareTo(b.$1));
    _transparent.sort((a, b) => a.$1.compareTo(b.$1));
    _collectBatches(scene, view);
  }

  /// The batches seen from [view]: visible, in the frustum and within
  /// their reach, by material so each material is bound once.
  void _collectBatches(RenderScene scene, RenderView view) {
    _batches.clear();
    for (final batch in scene.batches) {
      if (!batch.visible || batch.count == 0) continue;
      if (!_frustum.intersectsAabb(batch.bounds) ||
          !_withinReach(batch, view)) {
        stats.culled += batch.count;
        continue;
      }
      _batches.add(batch);
    }
    int materialOf(InstanceBatch b) =>
        _materialIds.putIfAbsent(b.material, () => _materialIds.length);
    _batches.sort((a, b) {
      final m = materialOf(a).compareTo(materialOf(b));
      return m != 0
          ? m
          : _primitiveId(a.primitive).compareTo(_primitiveId(b.primitive));
    });
  }

  /// Whether [batch]'s nearest point is within its reach of the camera.
  static bool _withinReach(InstanceBatch batch, RenderView view) {
    final reach = batch.maxDistance;
    if (!reach.isFinite) return true;
    final b = batch.bounds, c = view.cameraPosition;
    double gap(double v, double lo, double hi) =>
        v < lo ? lo - v : (v > hi ? v - hi : 0);
    final dx = gap(c.x, b.min.x, b.max.x);
    final dy = gap(c.y, b.min.y, b.max.y);
    final dz = gap(c.z, b.min.z, b.max.z);
    return dx * dx + dy * dy + dz * dz <= reach * reach;
  }

  /// The batches casting into [fit]'s shadow map, into [casters].
  void _collectBatchCasters(
    RenderScene scene,
    RenderView view,
    ShadowFit fit,
    List<InstanceBatch> casters,
  ) {
    for (final batch in scene.batches) {
      if (!batch.visible || !batch.castShadows || batch.count == 0) continue;
      if (!_withinReach(batch, view)) continue;
      if (!fit.frustum.intersectsAabb(batch.bounds)) continue;
      casters.add(batch);
      stats.shadowCasters += batch.count;
    }
  }

  /// [batch]'s instances on the GPU, uploaded again when they changed.
  GpuBufferView _batchBuffer(InstanceBatch batch) {
    var buffer = batch.buffer;
    if (buffer == null || batch.uploaded != batch.revision) {
      final data = batch.data;
      buffer = batch.buffer = device.createBuffer(
        data.buffer.asByteData(data.offsetInBytes, data.lengthInBytes),
      );
      batch.uploaded = batch.revision;
    }
    return buffer.view();
  }

  /// Draws the batches collected for this frame, each in one call.
  void _drawBatches(GpuPass pass, _LitBindings bindings) {
    if (_batches.isEmpty) return;
    final lit = _pipelines[RendererPipelines.lit];
    _bindLit(pass, false, bindings, transparent: false);
    GpuMaterial? bound;
    for (final batch in _batches) {
      if (!identical(bound, batch.material)) {
        _bindMaterial(pass, lit, batch.material, transparent: false);
        bound = batch.material;
      }
      final primitive = batch.primitive;
      pass
        ..setVertexBuffer(0, primitive.vertices.view())
        ..setVertexBuffer(1, _batchBuffer(batch))
        ..setIndexBuffer(primitive.indices.view(), primitive.indexType)
        ..drawIndexed(primitive.indexCount, instances: batch.count);
      stats
        ..drawCalls += 1
        ..batches += 1
        ..instances += batch.count
        ..triangles += primitive.indexCount ~/ 3 * batch.count;
    }
  }

  /// One instance at [world], as a frame's data.
  GpuBufferView _oneInstance(Matrix4 world) {
    InstanceBatch.writeInstance(_single, 0, world);
    return device.frameData(_single.buffer.asByteData());
  }

  /// Draws [primitive]'s edges, [count] times as [instances] place them.
  /// Nothing without edges ([ModelUploader.keepEdges]).
  void _drawEdges(
    GpuPass pass,
    GpuPrimitive primitive,
    GpuBufferView instances,
    int count,
    (double, double, double, double) color, {
    required bool xray,
  }) {
    final edges = primitive.edges;
    if (edges == null || primitive.edgeIndexCount == 0) return;
    final wire = _pipelines[RendererPipelines.wire];
    final block = wire.uniformBlock('Overlay')!;
    final w = UniformWriter(block.sizeInBytes)
      ..matrix4(block.offsetOf('view_projection')!, _gpuViewProjection)
      ..vec4(block.offsetOf('color')!, color.$1, color.$2, color.$3, color.$4)
      // Pulled towards the eye so an edge wins over its own faces.
      ..vec4(block.offsetOf('options')!, xray ? 0 : 0.0004, 0, 0, 0);
    pass
      ..setPipeline(wire)
      ..setTopology(GpuTopology.lines)
      ..setUniforms('Overlay', device.frameData(w.bytes))
      ..setDepth(test: !xray, write: false, compare: GpuCompare.lessEqual)
      ..setCull(GpuCull.none)
      ..setBlend(GpuBlend.alpha)
      ..setVertexBuffer(0, primitive.vertices.view())
      ..setVertexBuffer(1, instances)
      ..setIndexBuffer(edges.view(), GpuIndexType.uint32)
      ..drawIndexed(primitive.edgeIndexCount, instances: count);
    stats.drawCalls++;
  }

  /// [RenderViewMode.wireframe]: every visible thing's edges.
  void _drawWireframe(GpuPass pass) {
    for (final list in [_opaque, _transparent]) {
      for (final (_, instance) in list) {
        _drawEdges(
          pass,
          instance.primitive,
          _oneInstance(instance.world),
          1,
          wireColor,
          xray: true,
        );
      }
    }
    for (final batch in _batches) {
      _drawEdges(
        pass,
        batch.primitive,
        _batchBuffer(batch),
        batch.count,
        wireColor,
        xray: true,
      );
    }
    pass.setTopology(GpuTopology.triangles);
  }

  /// The lines drawn over the scene.
  void _drawOverlays(GpuPass pass, List<OverlayDraw> overlays) {
    for (final o in overlays) {
      _drawEdges(
        pass,
        o.primitive,
        _oneInstance(o.world),
        1,
        o.color,
        xray: o.xray,
      );
    }
    pass.setTopology(GpuTopology.triangles);
  }

  /// The instances casting into [fit]'s shadow map, into [casters]:
  /// visible casters inside the sun's box, by pipeline then mesh so each
  /// run is one draw.
  void _collectCasters(
    RenderScene scene,
    ShadowFit fit,
    List<(int, MeshInstance)> casters,
  ) {
    for (final instance in scene.instances) {
      if (!instance.visible || !instance.castShadows) continue;
      if (instance.material.data.alphaMode == AlphaMode.blend) continue;
      if (!fit.frustum.intersectsAabb(instance.bounds)) continue;
      casters.add((
        SortKey.opaque(
          phase: 1,
          pipeline: _skinned(instance) ? 1 : 0,
          material: 0,
          mesh: _primitiveId(instance.primitive),
          depth: 0,
        ),
        instance,
      ));
    }
    casters.sort((a, b) => a.$1.compareTo(b.$1));
    stats.shadowCasters += casters.length;
  }

  /// Gathers the palettes of every skinned instance drawn this frame into
  /// one joint texture (three texels per joint), one the GPU has finished
  /// with, so it never reads one being written.
  GpuTexture? _packPalettes() {
    _palettes.clear();
    var texels = 0;
    void take(List<(int, MeshInstance)> list) {
      for (final (_, instance) in list) {
        final palette = instance.skin;
        if (palette == null ||
            instance.primitive.skin == null ||
            palette.frame == _frame) {
          continue;
        }
        palette
          ..frame = _frame
          ..texel = texels;
        texels += palette.jointCount * 3;
        _palettes.add(palette);
      }
    }

    take(_opaque);
    take(_transparent);
    take(_casters[0]);
    take(_casters[1]);
    if (_palettes.isEmpty) return null;

    const width = jointsPerRow * 3;
    final rows = (texels + width - 1) ~/ width;
    var height = 1;
    while (height < rows) {
      height *= 2;
    }
    final floats = width * height * 4;
    if (_jointData.length < floats) _jointData = Float32List(floats);
    for (final palette in _palettes) {
      _jointData.setAll(palette.texel * 4, palette.rows);
      stats.joints += palette.jointCount;
    }
    GpuTexture? texture;
    while (texture == null && _spareJoints.isNotEmpty) {
      final spare = _spareJoints.removeLast();
      if (spare.desc.height == height) texture = spare;
    }
    texture ??= device.createTexture(
      GpuTextureDesc(
        width: width,
        height: height,
        format: GpuFormat.rgba32f,
        storage: GpuStorage.host,
      ),
    );
    texture.upload(_jointData.buffer.asByteData(0, floats * 4));
    return texture;
  }

  /// Draws [casters] into a fresh shadow map placed by [fit] and returns it.
  GpuTexture _shadowPass(
    GpuCommands commands,
    GpuTexture? joints,
    ShadowFit fit,
    List<(int, MeshInstance)> casters,
    List<InstanceBatch> batchCasters,
  ) {
    final size = shadows.mapSize;
    final map = targets.acquire(
      GpuTextureDesc(
        width: size,
        height: size,
        format: GpuFormat.r32f,
        renderTarget: true,
      ),
    );
    final depth = targets.acquire(
      GpuTextureDesc(
        width: size,
        height: size,
        format: device.caps.depthFormat,
        storage: GpuStorage.transient,
        renderTarget: true,
        shaderRead: false,
      ),
    );
    ClipFixup.flipY(fit.projection, _gpuShadowProjection);
    _gpuShadowViewProjection.setProduct(_gpuShadowProjection, fit.view);
    final block = _pipelines[RendererPipelines.shadow].uniformBlock('Shadow')!;
    final shadowUniforms = device.frameData(
      (UniformWriter(block.sizeInBytes)..matrix4(
            block.offsetOf('light_view_projection')!,
            _gpuShadowViewProjection,
          ))
          .bytes,
    );
    final pass = commands.beginPass(
      GpuRenderTargets([
        GpuColorTarget(map, clear: (1.0, 1.0, 1.0, 1.0)),
      ], depth: GpuDepthTarget(depth)),
    );
    final uniformSkins = skinning == SkinningMode.uniforms;
    int? kind;
    var start = 0;
    while (start < casters.length) {
      final first = casters[start].$2;
      final skinned = _skinned(first);
      final k = skinned ? 1 : 0;
      var end = start + 1;
      if (!(skinned && uniformSkins)) {
        while (end < casters.length &&
            identical(casters[end].$2.primitive, first.primitive) &&
            _skinned(casters[end].$2) == skinned) {
          end++;
        }
      }
      if (k != kind) {
        kind = k;
        final pipeline =
            _pipelines[!skinned
                ? RendererPipelines.shadow
                : uniformSkins
                ? RendererPipelines.shadowSkinnedUniform
                : RendererPipelines.shadowSkinned];
        pass
          ..setPipeline(pipeline)
          ..setUniforms('Shadow', shadowUniforms)
          ..setDepth()
          ..setCull(GpuCull.none)
          ..setBlend(GpuBlend.off);
        if (skinned && !uniformSkins) {
          pass.setTexture(
            'joint_texture',
            joints!,
            sampler: GpuSampler.nearestClamp,
            vertexStage: true,
          );
        }
      }
      final primitive = first.primitive;
      pass.setVertexBuffer(0, primitive.vertices.view());
      if (skinned) {
        pass
          ..setVertexBuffer(1, primitive.skin!.view())
          ..setVertexBuffer(
            2,
            device.frameData(_instances(casters, start, end, skinned: true)),
          );
        if (uniformSkins) {
          pass.setUniforms(
            'Skin',
            device.frameData(_paletteBlock(first.skin!)),
          );
        }
      } else {
        pass.setVertexBuffer(
          1,
          device.frameData(_instances(casters, start, end, skinned: false)),
        );
      }
      pass
        ..setIndexBuffer(primitive.indices.view(), primitive.indexType)
        ..drawIndexed(primitive.indexCount, instances: end - start);
      stats
        ..drawCalls += 1
        ..shadowDrawCalls += 1;
      start = end;
    }
    if (batchCasters.isNotEmpty) {
      pass
        ..setPipeline(_pipelines[RendererPipelines.shadow])
        ..setUniforms('Shadow', shadowUniforms)
        ..setDepth()
        ..setCull(GpuCull.none)
        ..setBlend(GpuBlend.off);
      for (final batch in batchCasters) {
        final primitive = batch.primitive;
        pass
          ..setVertexBuffer(0, primitive.vertices.view())
          ..setVertexBuffer(1, _batchBuffer(batch))
          ..setIndexBuffer(primitive.indices.view(), primitive.indexType)
          ..drawIndexed(primitive.indexCount, instances: batch.count);
        stats
          ..drawCalls += 1
          ..shadowDrawCalls += 1;
      }
    }
    return map;
  }

  /// Switches [pass] to the lit pipeline for [skinned] draws and binds
  /// what every lit draw reads.
  void _bindLit(
    GpuPass pass,
    bool skinned,
    _LitBindings b, {
    required bool transparent,
  }) {
    final uniformSkins = skinning == SkinningMode.uniforms;
    final pipeline =
        _pipelines[!skinned
            ? RendererPipelines.lit
            : uniformSkins
            ? RendererPipelines.litSkinnedUniform
            : RendererPipelines.litSkinned];
    pass
      ..setPipeline(pipeline)
      ..setUniforms('Frame', b.frame)
      ..setUniforms('Lights', b.lights)
      ..setTexture(
        'shadow_texture',
        b.shadowMap,
        sampler: GpuSampler.nearestClamp,
      )
      ..setTexture(
        'shadow_texture_2',
        b.shadowMap2,
        sampler: GpuSampler.nearestClamp,
      )
      ..setTexture(
        'environment_texture',
        b.environment,
        sampler: GpuSampler.linearClamp,
      )
      ..setDepth(write: !transparent);
    if (skinned && !uniformSkins) {
      pass.setTexture(
        'joint_texture',
        b.joints!,
        sampler: GpuSampler.nearestClamp,
        vertexStage: true,
      );
    }
  }

  /// Draws [list] in order. Opaque runs of one primitive, material and
  /// pipeline become one instanced draw; transparent draws stay one per
  /// instance, back to front.
  void _drawList(
    GpuPass pass,
    List<(int, MeshInstance)> list,
    _LitBindings bindings, {
    required bool transparent,
  }) {
    final uniformSkins = skinning == SkinningMode.uniforms;
    final lit = _pipelines[RendererPipelines.lit];
    bool? boundSkinned;
    GpuMaterial? boundMaterial;
    var start = 0;
    while (start < list.length) {
      final first = list[start].$2;
      final skinned = _skinned(first);
      var end = start + 1;
      if (!transparent && !(skinned && uniformSkins)) {
        while (end < list.length &&
            identical(list[end].$2.primitive, first.primitive) &&
            identical(list[end].$2.material, first.material) &&
            _skinned(list[end].$2) == skinned) {
          end++;
        }
      }
      final count = end - start;
      if (boundSkinned != skinned) {
        _bindLit(pass, skinned, bindings, transparent: transparent);
        boundSkinned = skinned;
        // A new pipeline starts with no bindings.
        boundMaterial = null;
      }
      if (!identical(boundMaterial, first.material)) {
        _bindMaterial(pass, lit, first.material, transparent: transparent);
        boundMaterial = first.material;
      }
      final primitive = first.primitive;
      pass.setVertexBuffer(0, primitive.vertices.view());
      if (skinned) {
        pass
          ..setVertexBuffer(1, primitive.skin!.view())
          ..setVertexBuffer(
            2,
            device.frameData(_instances(list, start, end, skinned: true)),
          );
        if (uniformSkins) {
          pass.setUniforms(
            'Skin',
            device.frameData(_paletteBlock(first.skin!)),
          );
        }
        stats.skinnedInstances += count;
      } else {
        pass.setVertexBuffer(
          1,
          device.frameData(_instances(list, start, end, skinned: false)),
        );
      }
      pass
        ..setIndexBuffer(primitive.indices.view(), primitive.indexType)
        ..drawIndexed(primitive.indexCount, instances: count);
      stats
        ..drawCalls += 1
        ..instances += count
        ..triangles += primitive.indexCount ~/ 3 * count;
      start = end;
    }
  }

  void _bindMaterial(
    GpuPass pass,
    GpuPipeline lit,
    GpuMaterial material, {
    required bool transparent,
  }) {
    final data = material.data;
    material.uniforms ??= _materialBuffer(lit, data);
    pass
      ..setUniforms('Material', material.uniforms!.view())
      ..setCull(
        data.doubleSided ? GpuCull.none : GpuCull.back,
        frontClockwise: ClipFixup.frontFaceIsClockwise,
      )
      ..setBlend(transparent ? GpuBlend.alpha : GpuBlend.off);
    for (var i = 0; i < GpuMaterial.textureNames.length; i++) {
      final (texture, sampler) = material.textures[i];
      pass.setTexture(GpuMaterial.textureNames[i], texture, sampler: sampler);
    }
  }

  GpuBuffer _materialBuffer(GpuPipeline lit, MaterialData m) {
    final block = lit.uniformBlock('Material')!;
    final w = UniformWriter(block.sizeInBytes);
    int at(String member) => block.offsetOf(member)!;
    // KHR_texture_transform: one transform for all maps, the base colour's
    // (or the first map that has one).
    final ref =
        [
          m.baseColorTexture,
          m.metallicRoughnessTexture,
          m.normalTexture,
          m.occlusionTexture,
          m.emissiveTexture,
        ].whereType<TextureRef>().firstWhere(
          (r) => r.hasTransform,
          orElse: () => const TextureRef(0),
        );
    w
      ..vec4(
        at('base_color'),
        m.baseColor.$1,
        m.baseColor.$2,
        m.baseColor.$3,
        m.baseColor.$4,
      )
      ..vec4(
        at('emissive'),
        m.emissive.$1 * m.emissiveStrength,
        m.emissive.$2 * m.emissiveStrength,
        m.emissive.$3 * m.emissiveStrength,
        m.alphaCutoff,
      )
      ..vec4(
        at('params'),
        m.metallic,
        m.roughness,
        m.normalScale,
        m.occlusionStrength,
      )
      ..vec4(
        at('flags'),
        m.unlit ? 1 : 0,
        m.alphaMode.index.toDouble(),
        m.doubleSided ? 1 : 0,
        m.layered ? 2 : (m.uvMode == UvMode.world ? 1 : 0),
      )
      ..vec4(
        at('uv_transform'),
        ref.offset.$1,
        ref.offset.$2,
        ref.scale.$1,
        ref.scale.$2,
      )
      ..vec4(at('uv_rotation'), ref.rotation, 0, 0, 0)
      ..vec4(
        at('layers'),
        m.layerTiling.$1,
        m.layerTiling.$2,
        m.layerTiling.$3,
        m.layerTiling.$4,
      );
    final buffer = device.createHostBuffer(w.sizeInBytes);
    buffer.write(w.bytes);
    return buffer;
  }

  /// One palette as the `Skin` uniform block (at most [kMaxUniformJoints]
  /// joints).
  ByteData _paletteBlock(SkinPalette palette) {
    final block = _pipelines[RendererPipelines.litSkinnedUniform].uniformBlock(
      'Skin',
    )!;
    final out = ByteData(block.sizeInBytes);
    final rows = palette.rows;
    final n = math.min(rows.length, kMaxUniformJoints * kPaletteFloats);
    final at = block.offsetOf('rows') ?? 0;
    for (var i = 0; i < n; i++) {
      out.setFloat32(at + i * 4, rows[i], Endian.little);
    }
    stats.joints += math.min(palette.jointCount, kMaxUniformJoints);
    return out;
  }

  ByteData _instances(
    List<(int, MeshInstance)> list,
    int start,
    int end, {
    required bool skinned,
  }) {
    final count = end - start;
    final stride = skinned ? _skinnedInstanceFloats : _instanceFloats;
    if (_instanceData.length < count * stride) {
      _instanceData = Float32List(count * stride * 2);
    }
    final out = _instanceData;
    for (var i = 0; i < count; i++) {
      final instance = list[start + i].$2;
      final m = instance.world.storage;
      final o = i * stride;
      for (var k = 0; k < 16; k++) {
        out[o + k] = m[k];
      }
      // Normal matrix: inverse transpose of the upper 3x3.
      final a = m[0], b = m[1], c = m[2];
      final d = m[4], e = m[5], f = m[6];
      final g = m[8], h = m[9], k = m[10];
      final c00 = e * k - f * h, c01 = -(d * k - f * g), c02 = d * h - e * g;
      final c10 = -(b * k - c * h), c11 = a * k - c * g, c12 = -(a * h - b * g);
      final c20 = b * f - c * e, c21 = -(a * f - c * d), c22 = a * e - b * d;
      final det = a * c00 + b * c01 + c * c02;
      final inv = det.abs() < 1e-20 ? 0.0 : 1.0 / det;
      // Column j of the inverse transpose is row j of the cofactors / det.
      out[o + 16] = c00 * inv;
      out[o + 17] = c01 * inv;
      out[o + 18] = c02 * inv;
      out[o + 19] = 0;
      out[o + 20] = c10 * inv;
      out[o + 21] = c11 * inv;
      out[o + 22] = c12 * inv;
      out[o + 23] = 0;
      out[o + 24] = c20 * inv;
      out[o + 25] = c21 * inv;
      out[o + 26] = c22 * inv;
      out[o + 27] = 0;
      if (skinned) {
        out[o + 28] = skinning == SkinningMode.texture
            ? instance.skin!.texel.toDouble()
            : 0;
        out[o + 29] = 0;
        out[o + 30] = 0;
        out[o + 31] = 0;
      }
    }
    return out.buffer.asByteData(0, count * stride * 4);
  }

  ByteData _frameBlock(
    RenderScene scene,
    RenderView view, {
    required bool toDisplay,
    required bool shadowed,
  }) {
    final block = _pipelines[RendererPipelines.lit].uniformBlock('Frame')!;
    final w = UniformWriter(block.sizeInBytes);
    int at(String member) => block.offsetOf(member)!;
    final sun = scene.sun;
    final env = scene.environment;
    w
      ..matrix4(at('view_projection'), _gpuViewProjection)
      ..vector3(at('camera_position'), view.cameraPosition, 1)
      ..vec4(
        at('sun_direction'),
        sun.direction.x,
        sun.direction.y,
        sun.direction.z,
        sun.enabled ? 1 : 0,
      )
      ..vec4(
        at('sun_color'),
        sun.color.$1 * sun.intensity,
        sun.color.$2 * sun.intensity,
        sun.color.$3 * sun.intensity,
        0,
      )
      ..vec4(
        at('ambient_sky'),
        env.ambientSky.$1,
        env.ambientSky.$2,
        env.ambientSky.$3,
        0,
      )
      ..vec4(
        at('ambient_ground'),
        env.ambientGround.$1,
        env.ambientGround.$2,
        env.ambientGround.$3,
        0,
      )
      ..vec4(
        at('options'),
        env.exposure,
        toDisplay ? 1 : 0,
        viewMode == RenderViewMode.unlit ? 1 : 0,
        0,
      );
    final clip = clipPlane;
    if (clip != null) {
      w.vec4(at('clip_plane'), clip.$1, clip.$2, clip.$3, clip.$4);
    }
    if (env.fogDensity > 0) {
      w
        ..vec4(
          at('fog'),
          env.fogColor.$1,
          env.fogColor.$2,
          env.fogColor.$3,
          env.fogDensity,
        )
        ..vec4(at('fog_params'), env.fogStart, 0, 0, 0);
    }
    final v = view.view.storage;
    w.vec4(at('camera_forward'), v[2], v[6], v[10], 0);
    final map = env.map;
    if (map != null) {
      w.vec4(at('ibl'), env.reflections, (map.levelCount - 1).toDouble(), 1, 0);
      final sh = at('sh');
      for (var i = 0; i < 9; i++) {
        w.vec4(
          sh + i * 16,
          map.sh[i * 3],
          map.sh[i * 3 + 1],
          map.sh[i * 3 + 2],
          0,
        );
      }
    }
    if (shadowed) {
      final fit = _shadowFits[0];
      w
        ..matrix4(at('light_view_projection'), fit.viewProjection)
        ..vec4(
          at('shadow'),
          shadows.strength.clamp(0.0, 1.0),
          shadows.normalOffsetTexels * fit.texelSize,
          1 / shadows.mapSize,
          shadows.depthBias / fit.depthRange,
        );
      if (_cascades > 1) {
        final far = _shadowFits[1];
        w
          ..matrix4(at('light_view_projection_2'), far.viewProjection)
          ..vec4(
            at('cascade'),
            _cascadeSplit,
            2,
            shadows.normalOffsetTexels * far.texelSize,
            shadows.depthBias / far.depthRange,
          );
      } else {
        w.vec4(at('cascade'), 0, 1, 0, 0);
      }
    }
    return w.bytes;
  }

  ByteData _lightsBlock(RenderScene scene, RenderView view) {
    final block = _pipelines[RendererPipelines.lit].uniformBlock('Lights')!;
    final w = UniformWriter(block.sizeInBytes);
    int at(String member) => block.offsetOf(member)!;
    // The 8 that matter most: brightest for their distance to the camera.
    final ranked = [
      for (final l in scene.lights)
        (
          l.intensity / (1 + l.position.distanceToSquared(view.cameraPosition)),
          l,
        ),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    final used = ranked.take(8).map((e) => e.$2).toList();
    stats.lights = used.length;
    final positions = at('position_range');
    final colors = at('color');
    final directions = at('direction');
    final cones = at('cone');
    w.vec4(at('count'), used.length.toDouble(), 0, 0, 0);
    for (var i = 0; i < used.length; i++) {
      final l = used[i];
      w
        ..vec4(
          positions + i * 16,
          l.position.x,
          l.position.y,
          l.position.z,
          l.range ?? 0,
        )
        ..vec4(
          colors + i * 16,
          l.color.$1 * l.intensity,
          l.color.$2 * l.intensity,
          l.color.$3 * l.intensity,
          0,
        );
      final spot = l.type == LightType.spot;
      w.vec4(
        directions + i * 16,
        l.direction.x,
        l.direction.y,
        l.direction.z,
        spot ? 1 : 0,
      );
      if (spot) {
        final cosOuter = math.cos(l.outerConeAngle);
        final cosInner = math.cos(l.innerConeAngle);
        w.vec4(
          cones + i * 16,
          cosOuter,
          1 / math.max(1e-4, cosInner - cosOuter),
          0,
          0,
        );
      }
    }
    return w.bytes;
  }

  ByteData _skyBlock(
    GpuPipeline sky,
    RenderScene scene,
    RenderView view, {
    required bool toDisplay,
  }) {
    final block = sky.uniformBlock('Sky')!;
    final w = UniformWriter(block.sizeInBytes);
    int at(String member) => block.offsetOf(member)!;
    final env = scene.environment;
    _inverse.copyInverse(_gpuViewProjection);
    w
      ..matrix4(at('inverse_view_projection'), _inverse)
      ..vector3(at('camera_position'), view.cameraPosition, 1)
      ..vec4(at('zenith'), env.zenith.$1, env.zenith.$2, env.zenith.$3, 1)
      ..vec4(at('horizon'), env.horizon.$1, env.horizon.$2, env.horizon.$3, 1)
      ..vec4(at('ground'), env.ground.$1, env.ground.$2, env.ground.$3, 1)
      ..vec4(at('options'), env.exposure, toDisplay ? 1 : 0, 0, 0)
      // How far fog reaches into the sky: what it hides at 300 m.
      ..vec4(
        at('fog'),
        env.fogColor.$1,
        env.fogColor.$2,
        env.fogColor.$3,
        env.fogDensity > 0 ? 1 - math.exp(-env.fogDensity * 300) : 0,
      );
    final map = env.map;
    if (env.skybox && map != null) {
      w.vec4(
        at('skybox'),
        1,
        env.skyboxBlur.clamp(0.0, 1.0) * (map.levelCount - 1),
        0,
        0,
      );
    }
    return w.bytes;
  }
}

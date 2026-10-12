import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import '../assets/animation_clip.dart';
import '../assets/model_data.dart';
import '../assets/texture_decode.dart';
import '../gpu/device.dart';
import '../gpu/formats.dart';
import 'skinning.dart';

/// A model uploaded to the GPU: its primitives' buffers, its materials'
/// textures, and the [data] it came from.
final class GpuModel {
  GpuModel._(this.data, this.meshes, this.materials, this.fallbackMaterial);

  /// The CPU model.
  final ModelData data;

  /// Primitives, by mesh index then primitive.
  final List<List<GpuPrimitive>> meshes;

  /// Materials, by material index.
  final List<GpuMaterial> materials;

  /// The material for primitives that name none.
  final GpuMaterial fallbackMaterial;

  /// Its node tree, for posing it.
  late final Skeleton skeleton = Skeleton(data);

  /// This model with its materials' values replaced by [values] (one per
  /// material, in order), sharing its buffers and textures: what a
  /// material preview shows while the values change, uploading nothing.
  GpuModel withMaterialValues(List<MaterialData> values) {
    if (values.length != materials.length) {
      throw ArgumentError.value(
        values.length,
        'values',
        'expected ${materials.length} materials',
      );
    }
    return GpuModel._(data, meshes, [
      for (var i = 0; i < values.length; i++)
        GpuMaterial._(values[i], materials[i].textures),
    ], fallbackMaterial);
  }

  /// Its animations, by name (a later one with the same name wins).
  late final Map<String, AnimationClip> clips = {
    for (final a in data.animations) a.name: AnimationClip(a),
  };

  /// The material of [primitive].
  GpuMaterial materialOf(GpuPrimitive primitive) =>
      primitive.material == null || primitive.material! >= materials.length
      ? fallbackMaterial
      : materials[primitive.material!];
}

/// One primitive's vertex and index buffers.
final class GpuPrimitive {
  GpuPrimitive._(
    this.vertices,
    this.indices,
    this.indexCount,
    this.indexType,
    this.material,
    this.bounds,
    this.skin,
  );

  /// [kVertexFloats] floats per vertex.
  final GpuBuffer vertices;

  /// Indices of [indexType].
  final GpuBuffer indices;

  /// How many indices to draw.
  final int indexCount;

  /// 16-bit when every index fits.
  final GpuIndexType indexType;

  /// Material index in its model, or null.
  final int? material;

  /// Local bounds.
  final Aabb3 bounds;

  /// Joints and weights ([kSkinFloats] floats per vertex) of a skinned
  /// primitive, else null.
  final GpuBuffer? skin;
}

/// A material's textures and settings, ready to bind.
final class GpuMaterial {
  GpuMaterial._(this.data, this.textures);

  /// Its settings.
  final MaterialData data;

  /// Base colour, metal-rough, normal, occlusion, emissive — in that order;
  /// a missing one is a 1×1 default.
  final List<(GpuTexture, GpuSampler)> textures;

  /// The uniform block's bytes, built once by the renderer.
  GpuBuffer? uniforms;

  /// The sampler uniform names, in [textures] order.
  static const List<String> textureNames = [
    'base_color_texture',
    'metallic_roughness_texture',
    'normal_texture',
    'occlusion_texture',
    'emissive_texture',
  ];
}

/// 1×1 textures standing in for a material's missing maps: white (base
/// colour, metal-rough, occlusion, emissive — so factors apply alone) and a
/// flat normal.
final class DefaultTextures {
  /// Creates them on [device].
  DefaultTextures(GpuDevice device)
    : whiteSrgb = _solid(device, [255, 255, 255, 255], GpuFormat.rgba8Srgb),
      white = _solid(device, [255, 255, 255, 255], GpuFormat.rgba8),
      black = _solid(device, [0, 0, 0, 255], GpuFormat.rgba8),
      flatNormal = _solid(device, [128, 128, 255, 255], GpuFormat.rgba8),
      blackCube = _cube(device);

  /// White, sRGB.
  final GpuTexture whiteSrgb;

  /// White, linear.
  final GpuTexture white;

  /// Black, linear: no bloom.
  final GpuTexture black;

  /// (0, 0, 1) in tangent space.
  final GpuTexture flatNormal;

  /// A black cube: bound where there is no environment map.
  final GpuTexture blackCube;

  static GpuTexture _cube(GpuDevice device) {
    final t = device.createTexture(
      const GpuTextureDesc(
        width: 1,
        height: 1,
        format: GpuFormat.rgba8,
        storage: GpuStorage.host,
        cube: true,
      ),
    );
    for (var face = 0; face < 6; face++) {
      t.upload(
        Uint8List.fromList([0, 0, 0, 255]).buffer.asByteData(),
        slice: face,
      );
    }
    return t;
  }

  static GpuTexture _solid(GpuDevice device, List<int> rgba, GpuFormat format) {
    final t = device.createTexture(
      GpuTextureDesc(
        width: 1,
        height: 1,
        format: format,
        storage: GpuStorage.host,
      ),
    );
    t.upload(Uint8List.fromList(rgba).buffer.asByteData());
    return t;
  }
}

/// Uploads [ModelData] to a [GpuDevice].
final class ModelUploader {
  /// An uploader filling missing maps from [defaults].
  ModelUploader(this.device, this.defaults);

  /// Where buffers and textures are created.
  final GpuDevice device;

  /// Stand-ins for missing maps.
  final DefaultTextures defaults;

  /// Uploads [data]: buffers now, then each texture it uses, decoded once
  /// per image and colour space, with a full mip chain when its sampler
  /// mipmaps.
  Future<GpuModel> upload(ModelData data) async {
    final meshes = [
      for (final mesh in data.meshes)
        [for (final p in mesh.primitives) _primitive(p)],
    ];
    final cache = <(int, bool), Future<GpuTexture?>>{};
    Future<(GpuTexture, GpuSampler)> texture(
      TextureRef? ref,
      GpuTexture fallback, {
      required bool srgb,
    }) async {
      if (ref == null || ref.texture >= data.textures.length) {
        return (fallback, GpuSampler.linearRepeat);
      }
      final tex = data.textures[ref.texture];
      final gpu = await (cache[(ref.texture, srgb)] ??= _texture(
        data,
        tex,
        srgb,
      ));
      return (gpu ?? fallback, _sampler(tex.sampler));
    }

    final materials = <GpuMaterial>[];
    for (final m in data.materials) {
      materials.add(
        GpuMaterial._(m, [
          await texture(m.baseColorTexture, defaults.whiteSrgb, srgb: true),
          await texture(
            m.metallicRoughnessTexture,
            defaults.white,
            srgb: false,
          ),
          await texture(m.normalTexture, defaults.flatNormal, srgb: false),
          await texture(m.occlusionTexture, defaults.white, srgb: false),
          await texture(m.emissiveTexture, defaults.whiteSrgb, srgb: true),
        ]),
      );
    }
    final fallback = GpuMaterial._(MaterialData.fallback, [
      (defaults.whiteSrgb, GpuSampler.linearRepeat),
      (defaults.white, GpuSampler.linearRepeat),
      (defaults.flatNormal, GpuSampler.linearRepeat),
      (defaults.white, GpuSampler.linearRepeat),
      (defaults.whiteSrgb, GpuSampler.linearRepeat),
    ]);
    return GpuModel._(data, meshes, materials, fallback);
  }

  /// Uploads one primitive's buffers: a mesh made in code (a shape).
  GpuPrimitive uploadPrimitive(PrimitiveData primitive) =>
      _primitive(primitive);

  /// A material of [data] drawing [baseColor] (its texture and sampler)
  /// where it has one, and the default maps everywhere else: a material
  /// made in code (a shape's), sharing textures it was given.
  GpuMaterial material(
    MaterialData data, {
    (GpuTexture, GpuSampler)? baseColor,
  }) => GpuMaterial._(data, [
    baseColor ?? (defaults.whiteSrgb, GpuSampler.linearRepeat),
    (defaults.white, GpuSampler.linearRepeat),
    (defaults.flatNormal, GpuSampler.linearRepeat),
    (defaults.white, GpuSampler.linearRepeat),
    (defaults.whiteSrgb, GpuSampler.linearRepeat),
  ]);

  /// Decodes the encoded image [bytes] (PNG, JPEG, …) and uploads it with
  /// a full chain of mips, as a colour ([srgb]) or a data map; null when
  /// it cannot be decoded.
  Future<GpuTexture?> uploadImage(Uint8List bytes, {bool srgb = true}) =>
      _texture(
        ModelData(
          name: 'image',
          meshes: const [],
          materials: const [],
          textures: const [TextureData(0, SamplerData())],
          images: [ImageData(bytes, null, 'image')],
          nodes: const [],
          roots: const [],
          lights: const [],
          bounds: Aabb3(),
        ),
        const TextureData(0, SamplerData()),
        srgb,
      );

  GpuPrimitive _primitive(PrimitiveData p) {
    final small = p.vertexCount <= 65535;
    final ByteData indexBytes;
    if (small) {
      indexBytes = Uint16List.fromList(p.indices).buffer.asByteData();
    } else {
      indexBytes = Uint32List.fromList(p.indices).buffer.asByteData();
    }
    return GpuPrimitive._(
      device.createBuffer(
        p.vertices.buffer.asByteData(
          p.vertices.offsetInBytes,
          p.vertices.lengthInBytes,
        ),
      ),
      device.createBuffer(indexBytes),
      p.indices.length,
      small ? GpuIndexType.uint16 : GpuIndexType.uint32,
      p.material,
      p.bounds,
      p.skin == null
          ? null
          : device.createBuffer(
              p.skin!.buffer.asByteData(
                p.skin!.offsetInBytes,
                p.skin!.lengthInBytes,
              ),
            ),
    );
  }

  Future<GpuTexture?> _texture(
    ModelData data,
    TextureData tex,
    bool srgb,
  ) async {
    final imageIndex = tex.image;
    if (imageIndex == null || imageIndex >= data.images.length) return null;
    final image = data.images[imageIndex];
    final mipmapped =
        tex.sampler.minFilter >= 9984 && tex.sampler.minFilter <= 9987;
    final List<RgbaImage> levels;
    final cooked = image.levels;
    if (cooked != null && cooked.isNotEmpty) {
      // Cooked: decoded and mipped already.
      final top = cooked.first;
      final most = device.maxMipLevels(top.width, top.height);
      levels = mipmapped ? cooked.take(most).toList() : [top];
    } else {
      if (image.bytes.isEmpty) return null;
      final RgbaImage decoded;
      try {
        decoded = await decodeImage(image.bytes);
      } on Object {
        return null;
      }
      levels = mipmapped
          ? await buildMips(
              decoded,
              srgb: srgb,
              maxLevels: device.maxMipLevels(decoded.width, decoded.height),
            )
          : [decoded];
    }
    final decoded = levels.first;
    final texture = device.createTexture(
      GpuTextureDesc(
        width: decoded.width,
        height: decoded.height,
        format: srgb ? GpuFormat.rgba8Srgb : GpuFormat.rgba8,
        storage: GpuStorage.host,
        mipLevels: levels.length,
      ),
    );
    for (var level = 0; level < levels.length; level++) {
      texture.upload(
        levels[level].pixels.buffer.asByteData(
          levels[level].pixels.offsetInBytes,
          levels[level].pixels.lengthInBytes,
        ),
        mipLevel: level,
      );
    }
    return texture;
  }

  static GpuSampler _sampler(SamplerData s) {
    GpuAddress address(int wrap) => switch (wrap) {
      33071 => GpuAddress.clamp,
      33648 => GpuAddress.mirror,
      _ => GpuAddress.repeat,
    };
    final min = s.minFilter;
    return GpuSampler(
      magFilter: s.magFilter == 9728 ? GpuFilter.nearest : GpuFilter.linear,
      minFilter: (min == 9728 || min == 9984 || min == 9986)
          ? GpuFilter.nearest
          : GpuFilter.linear,
      mipFilter: (min == 9984 || min == 9985)
          ? GpuFilter.nearest
          : GpuFilter.linear,
      addressU: address(s.wrapS),
      addressV: address(s.wrapT),
    );
  }
}

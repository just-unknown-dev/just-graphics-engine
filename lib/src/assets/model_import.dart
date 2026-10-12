import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import 'model_data.dart';

/// How a model file is imported: what an editor saves beside it as
/// `<model>.import.json` (see [ModelImportSettings.sidecarOf]) and what
/// cooking it (`cookModel`) applies.
final class ModelImportSettings {
  /// Settings; the defaults import the file as it is.
  const ModelImportSettings({
    this.scale = 1.0,
    this.maxTextureSize = 4096,
    this.mipmaps = true,
    this.textureCompression = TextureCompression.none,
    this.materials = const {},
  });

  /// Reads settings saved by [toJson]; anything missing or wrong keeps its
  /// default.
  factory ModelImportSettings.fromJson(Map<String, dynamic> json) {
    final version = json['formatVersion'];
    if (version is int && version > formatVersion) {
      throw FormatException(
        'Model import settings of format $version are newer than this ($formatVersion).',
      );
    }
    final materials = <String, MaterialOverride>{};
    final m = json['materials'];
    if (m is Map) {
      for (final MapEntry(:key, :value) in m.entries) {
        if (key is String && value is Map) {
          materials[key] = MaterialOverride.fromJson(
            value.cast<String, dynamic>(),
          );
        }
      }
    }
    final compression = json['textureCompression'];
    return ModelImportSettings(
      scale: _number(json['scale']) ?? 1.0,
      maxTextureSize: (json['maxTextureSize'] as num?)?.toInt() ?? 4096,
      mipmaps: json['mipmaps'] as bool? ?? true,
      textureCompression: TextureCompression.values.firstWhere(
        (c) => c.name == compression,
        orElse: () => TextureCompression.none,
      ),
      materials: materials,
    );
  }

  /// The format written; a file of a newer one is refused.
  static const int formatVersion = 1;

  /// Where the settings of the model at [modelPath] are kept.
  static String sidecarOf(String modelPath) => '$modelPath.import.json';

  /// Where the cooked form of the model at [modelPath] is kept; a game
  /// loads it in place of the file when it is there.
  static String cookedOf(String modelPath) => '$modelPath$cookedExtension';

  /// How a cooked model's file name ends.
  static const String cookedExtension = '.jmodel';

  /// Every length multiplied by this: a file made in centimetres imports
  /// at 0.01.
  final double scale;

  /// The widest a texture may be, in pixels; larger ones are halved until
  /// they fit. 0 for no limit.
  final int maxTextureSize;

  /// Whether textures keep their smaller levels (mipmaps).
  final bool mipmaps;

  /// How textures are stored once cooked.
  final TextureCompression textureCompression;

  /// Changes to the file's materials, by name (or `#<index>` for one
  /// without a name).
  final Map<String, MaterialOverride> materials;

  /// Whether these are the defaults: the file as it is.
  bool get isDefault =>
      scale == 1.0 &&
      maxTextureSize == 4096 &&
      mipmaps &&
      textureCompression == TextureCompression.none &&
      materials.isEmpty;

  /// These settings with some changed.
  ModelImportSettings copyWith({
    double? scale,
    int? maxTextureSize,
    bool? mipmaps,
    TextureCompression? textureCompression,
    Map<String, MaterialOverride>? materials,
  }) => ModelImportSettings(
    scale: scale ?? this.scale,
    maxTextureSize: maxTextureSize ?? this.maxTextureSize,
    mipmaps: mipmaps ?? this.mipmaps,
    textureCompression: textureCompression ?? this.textureCompression,
    materials: materials ?? this.materials,
  );

  /// The settings as saved.
  Map<String, dynamic> toJson() => {
    'formatVersion': formatVersion,
    'scale': scale,
    'maxTextureSize': maxTextureSize,
    'mipmaps': mipmaps,
    'textureCompression': textureCompression.name,
    if (materials.isNotEmpty)
      'materials': {
        for (final key in materials.keys.toList()..sort())
          if (!materials[key]!.isEmpty) key: materials[key]!.toJson(),
      },
  };

  /// What [materials] calls the material at [index] of [data].
  static String materialKey(ModelData data, int index) {
    final name = data.materials[index].name;
    return name == null || name.isEmpty ? '#$index' : name;
  }

  /// [data] with [scale] and the material changes applied.
  ModelData apply(ModelData data) {
    var out = data;
    if (scale != 1.0) out = scaled(out, scale);
    if (materials.isNotEmpty) {
      out = _withMaterials(out, [
        for (var i = 0; i < out.materials.length; i++)
          materials[materialKey(out, i)]?.applyTo(out.materials[i]) ??
              out.materials[i],
      ]);
    }
    return out;
  }

  /// [data] with every length multiplied by [s]: vertex positions, node and
  /// joint translations, animated translations, bounds and light ranges.
  static ModelData scaled(ModelData data, double s) {
    Aabb3 box(Aabb3 b) =>
        b.isEmpty ? Aabb3() : Aabb3.minMax(b.min * s, b.max * s);
    Matrix4 moved(Matrix4 m) {
      final out = Matrix4.copy(m);
      out.storage[12] *= s;
      out.storage[13] *= s;
      out.storage[14] *= s;
      return out;
    }

    final meshes = [
      for (final mesh in data.meshes)
        MeshData(mesh.name, [
          for (final p in mesh.primitives)
            PrimitiveData(
              vertices: () {
                final v = Float32List.fromList(p.vertices);
                for (var i = 0; i + 2 < v.length; i += kVertexFloats) {
                  v[i] *= s;
                  v[i + 1] *= s;
                  v[i + 2] *= s;
                }
                return v;
              }(),
              indices: p.indices,
              material: p.material,
              bounds: box(p.bounds),
              hasTangents: p.hasTangents,
              skin: p.skin,
            ),
        ]),
    ];
    final nodes = [
      for (final n in data.nodes)
        NodeData(
          name: n.name,
          local: moved(n.local),
          children: n.children,
          mesh: n.mesh,
          skin: n.skin,
          light: n.light,
          translation: n.translation == null ? null : n.translation! * s,
          rotation: n.rotation,
          scale: n.scale,
        ),
    ];
    final skins = [
      for (final skin in data.skins)
        SkinData(
          name: skin.name,
          joints: skin.joints,
          skeleton: skin.skeleton,
          inverseBindMatrices: () {
            final m = Float32List.fromList(skin.inverseBindMatrices);
            for (var j = 0; j + 15 < m.length; j += 16) {
              m[j + 12] *= s;
              m[j + 13] *= s;
              m[j + 14] *= s;
            }
            return m;
          }(),
        ),
    ];
    final animations = [
      for (final a in data.animations)
        AnimationData(
          name: a.name,
          duration: a.duration,
          channels: a.channels,
          samplers: [
            for (var i = 0; i < a.samplers.length; i++)
              a.channels.any(
                    (c) =>
                        c.sampler == i && c.path == AnimationPath.translation,
                  )
                  ? AnimationSamplerData(
                      input: a.samplers[i].input,
                      output: Float32List.fromList([
                        for (final v in a.samplers[i].output) v * s,
                      ]),
                      interpolation: a.samplers[i].interpolation,
                      width: a.samplers[i].width,
                    )
                  : a.samplers[i],
          ],
        ),
    ];
    final lights = [
      for (final l in data.lights)
        LightData(
          type: l.type,
          name: l.name,
          color: l.color,
          intensity: l.intensity,
          range: l.range == null ? null : l.range! * s,
          innerConeAngle: l.innerConeAngle,
          outerConeAngle: l.outerConeAngle,
        ),
    ];
    return ModelData(
      name: data.name,
      meshes: meshes,
      materials: data.materials,
      textures: data.textures,
      images: data.images,
      nodes: nodes,
      roots: data.roots,
      lights: lights,
      bounds: box(data.bounds),
      skins: skins,
      animations: animations,
      warnings: data.warnings,
    );
  }

  static ModelData _withMaterials(
    ModelData data,
    List<MaterialData> materials,
  ) => ModelData(
    name: data.name,
    meshes: data.meshes,
    materials: materials,
    textures: data.textures,
    images: data.images,
    nodes: data.nodes,
    roots: data.roots,
    lights: data.lights,
    bounds: data.bounds,
    skins: data.skins,
    animations: data.animations,
    warnings: data.warnings,
  );

  static double? _number(Object? v) => v is num ? v.toDouble() : null;
}

/// How cooked textures are stored.
enum TextureCompression {
  /// RGBA, 4 bytes a pixel.
  none,

  /// ETC2 (Android, desktop OpenGL ES). Not made yet: cooked as [none].
  etc2,

  /// ASTC 4×4 (iOS, newer Android). Not made yet: cooked as [none].
  astc,
}

/// Changes to one material; a null field keeps the file's value.
final class MaterialOverride {
  /// Changes; none by default.
  const MaterialOverride({
    this.baseColor,
    this.metallic,
    this.roughness,
    this.emissive,
    this.emissiveStrength,
    this.doubleSided,
    this.unlit,
  });

  /// Reads one saved by [toJson].
  factory MaterialOverride.fromJson(Map<String, dynamic> json) {
    List<double>? list(Object? v, int n) =>
        v is List && v.length == n && v.every((e) => e is num)
        ? [for (final e in v) (e as num).toDouble()]
        : null;
    final c = list(json['baseColor'], 4);
    final e = list(json['emissive'], 3);
    return MaterialOverride(
      baseColor: c == null ? null : (c[0], c[1], c[2], c[3]),
      metallic: (json['metallic'] as num?)?.toDouble(),
      roughness: (json['roughness'] as num?)?.toDouble(),
      emissive: e == null ? null : (e[0], e[1], e[2]),
      emissiveStrength: (json['emissiveStrength'] as num?)?.toDouble(),
      doubleSided: json['doubleSided'] as bool?,
      unlit: json['unlit'] as bool?,
    );
  }

  /// Linear RGBA multiplier.
  final (double, double, double, double)? baseColor;

  /// 0 (not metal) to 1.
  final double? metallic;

  /// 0 (mirror) to 1.
  final double? roughness;

  /// Linear RGB glow.
  final (double, double, double)? emissive;

  /// Glow multiplier.
  final double? emissiveStrength;

  /// Drawn from both sides.
  final bool? doubleSided;

  /// Not lit: its colour as it is.
  final bool? unlit;

  /// Whether it changes nothing.
  bool get isEmpty =>
      baseColor == null &&
      metallic == null &&
      roughness == null &&
      emissive == null &&
      emissiveStrength == null &&
      doubleSided == null &&
      unlit == null;

  /// The change as saved.
  Map<String, dynamic> toJson() => {
    if (baseColor case (final r, final g, final b, final a))
      'baseColor': [r, g, b, a],
    'metallic': ?metallic,
    'roughness': ?roughness,
    if (emissive case (final r, final g, final b)) 'emissive': [r, g, b],
    'emissiveStrength': ?emissiveStrength,
    'doubleSided': ?doubleSided,
    'unlit': ?unlit,
  };

  /// [m] with these changes.
  MaterialData applyTo(MaterialData m) => MaterialData(
    name: m.name,
    baseColor: baseColor ?? m.baseColor,
    baseColorTexture: m.baseColorTexture,
    metallic: metallic ?? m.metallic,
    roughness: roughness ?? m.roughness,
    metallicRoughnessTexture: m.metallicRoughnessTexture,
    normalTexture: m.normalTexture,
    normalScale: m.normalScale,
    occlusionTexture: m.occlusionTexture,
    occlusionStrength: m.occlusionStrength,
    emissive: emissive ?? m.emissive,
    emissiveTexture: m.emissiveTexture,
    emissiveStrength: emissiveStrength ?? m.emissiveStrength,
    alphaMode: m.alphaMode,
    alphaCutoff: m.alphaCutoff,
    doubleSided: doubleSided ?? m.doubleSided,
    unlit: unlit ?? m.unlit,
  );
}

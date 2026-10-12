import 'dart:convert';
import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import 'model_data.dart';

/// The cooked model format (`.jmodel`): a [ModelData] ready to upload —
/// vertices and indices as the renderer takes them, textures decoded with
/// their mip levels — so loading it parses no glTF and decodes no image.
///
/// Layout (little-endian): `JMDL`, the format version (u32), a JSON header
/// (u32 length, UTF-8, padded to 4 bytes), then the blobs it refers to by
/// index (u32 count; each a u32 length and its bytes, padded to 4).
abstract final class CookedModel {
  /// The format version written.
  static const int version = 1;

  static const List<int> _magic = [0x4A, 0x4D, 0x44, 0x4C]; // JMDL

  /// Whether [bytes] start like a cooked model.
  static bool isCooked(Uint8List bytes) =>
      bytes.length >= 8 &&
      bytes[0] == _magic[0] &&
      bytes[1] == _magic[1] &&
      bytes[2] == _magic[2] &&
      bytes[3] == _magic[3];

  /// [data] as a cooked file, carrying [stamp] (what it was cooked from;
  /// see [stampOf]). Images with [ImageData.levels] are stored as those
  /// levels; any other keeps its encoded bytes.
  static Uint8List write(ModelData data, {String? stamp}) {
    final blobs = <Uint8List>[];
    int blob(TypedData d) {
      blobs.add(d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes));
      return blobs.length - 1;
    }

    List<double> box(Aabb3 b) => b.isEmpty
        ? const []
        : [b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z];
    Map<String, dynamic>? ref(TextureRef? r) => r == null
        ? null
        : {
            't': r.texture,
            if (r.texCoord != 0) 'uv': r.texCoord,
            if (r.hasTransform)
              'tx': [
                r.offset.$1,
                r.offset.$2,
                r.scale.$1,
                r.scale.$2,
                r.rotation,
              ],
          };

    final header = <String, dynamic>{
      'name': data.name,
      'stamp': ?stamp,
      'bounds': box(data.bounds),
      'roots': data.roots,
      'warnings': data.warnings,
      'meshes': [
        for (final mesh in data.meshes)
          {
            'name': mesh.name,
            'primitives': [
              for (final p in mesh.primitives)
                {
                  'v': blob(p.vertices),
                  'i': blob(p.indices),
                  if (p.skin != null) 's': blob(p.skin!),
                  'm': p.material,
                  'b': box(p.bounds),
                  'tan': p.hasTangents,
                },
            ],
          },
      ],
      'materials': [
        for (final m in data.materials)
          {
            'name': m.name,
            'bc': [
              m.baseColor.$1,
              m.baseColor.$2,
              m.baseColor.$3,
              m.baseColor.$4,
            ],
            'bct': ref(m.baseColorTexture),
            'mt': m.metallic,
            'rg': m.roughness,
            'mrt': ref(m.metallicRoughnessTexture),
            'nt': ref(m.normalTexture),
            'ns': m.normalScale,
            'ot': ref(m.occlusionTexture),
            'os': m.occlusionStrength,
            'em': [m.emissive.$1, m.emissive.$2, m.emissive.$3],
            'et': ref(m.emissiveTexture),
            'es': m.emissiveStrength,
            'am': m.alphaMode.name,
            'ac': m.alphaCutoff,
            'ds': m.doubleSided,
            'ul': m.unlit,
          },
      ],
      'textures': [
        for (final t in data.textures)
          {
            'image': t.image,
            'sampler': [
              t.sampler.magFilter,
              t.sampler.minFilter,
              t.sampler.wrapS,
              t.sampler.wrapT,
            ],
          },
      ],
      'images': [
        for (final image in data.images)
          {
            'name': image.name,
            'mime': image.mimeType,
            if (image.levels case final levels?) ...{
              'levels': [
                for (final l in levels) [l.width, l.height, blob(l.pixels)],
              ],
              'srgb': image.levelsSrgb,
            } else
              'bytes': blob(image.bytes),
          },
      ],
      'nodes': [
        for (final n in data.nodes)
          {
            'name': n.name,
            'local': n.local.storage.toList(),
            'children': n.children,
            'mesh': n.mesh,
            'skin': n.skin,
            'light': n.light,
            if (n.translation case final t?) 't': [t.x, t.y, t.z],
            if (n.rotation case final r?) 'r': [r.x, r.y, r.z, r.w],
            if (n.scale case final s?) 's': [s.x, s.y, s.z],
          },
      ],
      'lights': [
        for (final l in data.lights)
          {
            'type': l.type.name,
            'name': l.name,
            'color': [l.color.$1, l.color.$2, l.color.$3],
            'intensity': l.intensity,
            'range': l.range,
            'inner': l.innerConeAngle,
            'outer': l.outerConeAngle,
          },
      ],
      'skins': [
        for (final s in data.skins)
          {
            'name': s.name,
            'joints': s.joints,
            'ibm': blob(s.inverseBindMatrices),
            'skeleton': s.skeleton,
          },
      ],
      'animations': [
        for (final a in data.animations)
          {
            'name': a.name,
            'duration': a.duration,
            'channels': [
              for (final c in a.channels) [c.sampler, c.node, c.path.name],
            ],
            'samplers': [
              for (final s in a.samplers)
                {
                  'in': blob(s.input),
                  'out': blob(s.output),
                  'interp': s.interpolation.name,
                  'w': s.width,
                },
            ],
          },
      ],
    };

    final json = utf8.encode(jsonEncode(header));
    int padded(int n) => (n + 3) & ~3;
    var length = 4 + 4 + 4 + padded(json.length) + 4;
    for (final b in blobs) {
      length += 4 + padded(b.length);
    }
    final out = Uint8List(length);
    final view = ByteData.sublistView(out);
    out.setAll(0, _magic);
    view.setUint32(4, version, Endian.little);
    view.setUint32(8, json.length, Endian.little);
    out.setAll(12, json);
    var at = 12 + padded(json.length);
    view.setUint32(at, blobs.length, Endian.little);
    at += 4;
    for (final b in blobs) {
      view.setUint32(at, b.length, Endian.little);
      out.setAll(at + 4, b);
      at += 4 + padded(b.length);
    }
    return out;
  }

  /// The stamp [bytes] were cooked with, or null (not a cooked model, or
  /// cooked without one). Reads only the header.
  static String? stampOf(Uint8List bytes) {
    if (!isCooked(bytes) || bytes.length < 12) return null;
    final view = ByteData.sublistView(bytes);
    final n = view.getUint32(8, Endian.little);
    if (12 + n > bytes.length) return null;
    try {
      final header = jsonDecode(
        utf8.decode(Uint8List.sublistView(bytes, 12, 12 + n)),
      );
      return header is Map ? header['stamp'] as String? : null;
    } on FormatException {
      return null;
    }
  }

  /// The model in the cooked file [bytes], named [name] for messages.
  static ModelData read(Uint8List bytes, {String? name}) {
    if (!isCooked(bytes)) {
      throw FormatException('${name ?? 'This file'} is not a cooked model.');
    }
    final view = ByteData.sublistView(bytes);
    final found = view.getUint32(4, Endian.little);
    if (found > version) {
      throw FormatException(
        '${name ?? 'This model'} was cooked by a newer version (format $found; this reads $version). Cook it again.',
      );
    }
    int padded(int n) => (n + 3) & ~3;
    final jsonLength = view.getUint32(8, Endian.little);
    final header =
        jsonDecode(
              utf8.decode(Uint8List.sublistView(bytes, 12, 12 + jsonLength)),
            )
            as Map<String, dynamic>;
    var at = 12 + padded(jsonLength);
    final count = view.getUint32(at, Endian.little);
    at += 4;
    final blobs = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final n = view.getUint32(at, Endian.little);
      blobs.add(Uint8List.sublistView(bytes, at + 4, at + 4 + n));
      at += 4 + padded(n);
    }

    // Typed views need their start aligned; a copy when it isn't.
    Uint8List aligned(int index) {
      final b = blobs[index];
      return b.offsetInBytes % 4 == 0 ? b : Uint8List.fromList(b);
    }

    Float32List floats(int index) {
      final b = aligned(index);
      return b.buffer.asFloat32List(b.offsetInBytes, b.lengthInBytes ~/ 4);
    }

    Uint32List uints(int index) {
      final b = aligned(index);
      return b.buffer.asUint32List(b.offsetInBytes, b.lengthInBytes ~/ 4);
    }

    List<double> nums(Object? v) => [
      for (final e in (v as List? ?? const [])) (e as num).toDouble(),
    ];
    Aabb3 box(Object? v) {
      final n = nums(v);
      return n.length == 6
          ? Aabb3.minMax(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]))
          : Aabb3();
    }

    TextureRef? ref(Object? v) {
      if (v is! Map) return null;
      final tx = nums(v['tx']);
      return TextureRef(
        v['t'] as int,
        texCoord: v['uv'] as int? ?? 0,
        offset: tx.length == 5 ? (tx[0], tx[1]) : (0.0, 0.0),
        scale: tx.length == 5 ? (tx[2], tx[3]) : (1.0, 1.0),
        rotation: tx.length == 5 ? tx[4] : 0.0,
      );
    }

    List<int> ints(Object? v) => [
      for (final e in (v as List? ?? const [])) e as int,
    ];
    List<Map<String, dynamic>> maps(Object? v) =>
        (v as List? ?? const []).cast<Map<String, dynamic>>();

    return ModelData(
      name: name ?? header['name'] as String? ?? 'model',
      bounds: box(header['bounds']),
      roots: ints(header['roots']),
      warnings: [
        for (final w in (header['warnings'] as List? ?? const [])) w as String,
      ],
      meshes: [
        for (final mesh in maps(header['meshes']))
          MeshData(mesh['name'] as String?, [
            for (final p in maps(mesh['primitives']))
              PrimitiveData(
                vertices: floats(p['v'] as int),
                indices: uints(p['i'] as int),
                skin: p['s'] == null ? null : floats(p['s'] as int),
                material: p['m'] as int?,
                bounds: box(p['b']),
                hasTangents: p['tan'] as bool? ?? false,
              ),
          ]),
      ],
      materials: [
        for (final m in maps(header['materials']))
          () {
            final bc = nums(m['bc']), em = nums(m['em']);
            return MaterialData(
              name: m['name'] as String?,
              baseColor: (bc[0], bc[1], bc[2], bc[3]),
              baseColorTexture: ref(m['bct']),
              metallic: (m['mt'] as num).toDouble(),
              roughness: (m['rg'] as num).toDouble(),
              metallicRoughnessTexture: ref(m['mrt']),
              normalTexture: ref(m['nt']),
              normalScale: (m['ns'] as num).toDouble(),
              occlusionTexture: ref(m['ot']),
              occlusionStrength: (m['os'] as num).toDouble(),
              emissive: (em[0], em[1], em[2]),
              emissiveTexture: ref(m['et']),
              emissiveStrength: (m['es'] as num).toDouble(),
              alphaMode: AlphaMode.values.byName(m['am'] as String),
              alphaCutoff: (m['ac'] as num).toDouble(),
              doubleSided: m['ds'] as bool,
              unlit: m['ul'] as bool,
            );
          }(),
      ],
      textures: [
        for (final t in maps(header['textures']))
          () {
            final s = ints(t['sampler']);
            return TextureData(
              t['image'] as int?,
              SamplerData(
                magFilter: s[0],
                minFilter: s[1],
                wrapS: s[2],
                wrapT: s[3],
              ),
            );
          }(),
      ],
      images: [
        for (final image in maps(header['images']))
          image['levels'] is List
              ? ImageData(
                  Uint8List(0),
                  image['mime'] as String?,
                  image['name'] as String?,
                  levels: [
                    for (final l in image['levels'] as List)
                      RgbaImage(l[0] as int, l[1] as int, blobs[l[2] as int]),
                  ],
                  levelsSrgb: image['srgb'] as bool? ?? true,
                )
              : ImageData(
                  blobs[image['bytes'] as int],
                  image['mime'] as String?,
                  image['name'] as String?,
                ),
      ],
      nodes: [
        for (final n in maps(header['nodes']))
          () {
            final t = nums(n['t']), r = nums(n['r']), s = nums(n['s']);
            return NodeData(
              name: n['name'] as String?,
              local: Matrix4.fromList(nums(n['local'])),
              children: ints(n['children']),
              mesh: n['mesh'] as int?,
              skin: n['skin'] as int?,
              light: n['light'] as int?,
              translation: t.length == 3 ? Vector3(t[0], t[1], t[2]) : null,
              rotation: r.length == 4
                  ? Quaternion(r[0], r[1], r[2], r[3])
                  : null,
              scale: s.length == 3 ? Vector3(s[0], s[1], s[2]) : null,
            );
          }(),
      ],
      lights: [
        for (final l in maps(header['lights']))
          () {
            final c = nums(l['color']);
            return LightData(
              type: LightType.values.byName(l['type'] as String),
              name: l['name'] as String?,
              color: (c[0], c[1], c[2]),
              intensity: (l['intensity'] as num).toDouble(),
              range: (l['range'] as num?)?.toDouble(),
              innerConeAngle: (l['inner'] as num).toDouble(),
              outerConeAngle: (l['outer'] as num).toDouble(),
            );
          }(),
      ],
      skins: [
        for (final s in maps(header['skins']))
          SkinData(
            name: s['name'] as String?,
            joints: ints(s['joints']),
            inverseBindMatrices: floats(s['ibm'] as int),
            skeleton: s['skeleton'] as int?,
          ),
      ],
      animations: [
        for (final a in maps(header['animations']))
          AnimationData(
            name: a['name'] as String,
            duration: (a['duration'] as num).toDouble(),
            channels: [
              for (final c in a['channels'] as List)
                AnimationChannelData(
                  sampler: c[0] as int,
                  node: c[1] as int,
                  path: AnimationPath.values.byName(c[2] as String),
                ),
            ],
            samplers: [
              for (final s in maps(a['samplers']))
                AnimationSamplerData(
                  input: floats(s['in'] as int),
                  output: floats(s['out'] as int),
                  interpolation: AnimationInterpolation.values.byName(
                    s['interp'] as String,
                  ),
                  width: s['w'] as int,
                ),
            ],
          ),
      ],
    );
  }
}

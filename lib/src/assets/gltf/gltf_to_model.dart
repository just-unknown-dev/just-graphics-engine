import 'dart:convert';
import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import '../model_data.dart';
import 'accessors.dart';

/// Extensions this loader reads. A file that *requires* any other is
/// refused, since it can't be shown correctly without it.
const Set<String> supportedGltfExtensions = {
  'KHR_texture_transform',
  'KHR_materials_emissive_strength',
  'KHR_materials_unlit',
  'KHR_mesh_quantization',
  'KHR_lights_punctual',
};

const Map<String, String> _unsupportedNames = {
  'KHR_draco_mesh_compression': 'Draco mesh compression',
  'EXT_meshopt_compression': 'meshopt compression',
  'KHR_meshopt_compression': 'meshopt compression',
  'KHR_texture_basisu': 'Basis Universal (KTX2) textures',
};

/// What a glTF file refers to, resolved: [buffers] by buffer index, and the
/// bytes of external or `data:` URIs by URI.
final class GltfSources {
  /// Resolved sources.
  const GltfSources(this.buffers, this.uris);

  /// Buffer bytes by buffer index.
  final List<ByteData> buffers;

  /// External file bytes by the URI the file used.
  final Map<String, Uint8List> uris;
}

/// The URIs a glTF [json] refers to that are not `data:` URIs (buffers and
/// images to fetch next to the file).
List<String> externalUris(Map<String, dynamic> json) => [
  for (final key in ['buffers', 'images'])
    for (final entry in (json[key] as List<dynamic>? ?? const []))
      if ((entry as Map<String, dynamic>)['uri'] case final String uri
          when !uri.startsWith('data:'))
        uri,
];

/// Decodes a `data:` URI's payload.
Uint8List decodeDataUri(String uri) {
  final comma = uri.indexOf(',');
  if (comma < 0) throw FormatException('Malformed data URI.');
  final header = uri.substring(0, comma);
  final payload = uri.substring(comma + 1);
  return header.endsWith(';base64')
      ? base64Decode(payload)
      : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
}

/// Builds a [ModelData] from glTF [json] and its resolved [sources].
/// Throws [UnsupportedError] for files this renderer can't show and
/// [FormatException] for malformed ones.
ModelData gltfToModel(
  Map<String, dynamic> json,
  GltfSources sources, {
  required String name,
}) {
  final version =
      (json['asset'] as Map<String, dynamic>?)?['version'] as String?;
  if (version == null || !version.startsWith('2')) {
    throw UnsupportedError(
      '$name: glTF version $version is not supported (2.x only).',
    );
  }
  final required = (json['extensionsRequired'] as List<dynamic>? ?? const [])
      .cast<String>()
      .where((e) => !supportedGltfExtensions.contains(e))
      .toList();
  if (required.isNotEmpty) {
    throw UnsupportedError(
      '$name needs ${required.map((e) => _unsupportedNames[e] ?? e).join(', ')}, '
      'which this renderer does not support. Re-export the model without it.',
    );
  }

  final warnings = <String>[];
  final reader = AccessorReader(json, sources.buffers);

  List<Map<String, dynamic>> list(String key) =>
      (json[key] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

  // Images.
  final images = <ImageData>[
    for (final image in list('images'))
      _image(image, reader, sources, warnings),
  ];

  // Samplers and textures.
  final samplers = [
    for (final s in list('samplers'))
      SamplerData(
        magFilter: s['magFilter'] as int? ?? 9729,
        minFilter: s['minFilter'] as int? ?? 9987,
        wrapS: s['wrapS'] as int? ?? 10497,
        wrapT: s['wrapT'] as int? ?? 10497,
      ),
  ];
  final textures = [
    for (final t in list('textures'))
      TextureData(
        t['source'] as int?,
        t['sampler'] is int
            ? samplers[t['sampler'] as int]
            : const SamplerData(),
      ),
  ];

  final materials = [for (final m in list('materials')) _material(m)];

  final meshes = <MeshData>[];
  final meshList = list('meshes');
  for (var i = 0; i < meshList.length; i++) {
    final mesh = meshList[i];
    final meshName = mesh['name'] as String?;
    final primitives = <PrimitiveData>[];
    for (final p
        in (mesh['primitives'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final primitive = _primitive(reader, p, warnings, meshName ?? 'mesh $i');
      if (primitive != null) primitives.add(primitive);
    }
    meshes.add(MeshData(meshName, primitives));
  }

  final nodeList = list('nodes');
  final nodes = [for (final n in nodeList) _node(n)];

  final skins = [for (final skin in list('skins')) _skin(skin, reader)];
  final animations = <AnimationData>[];
  final animationList = list('animations');
  for (var i = 0; i < animationList.length; i++) {
    final animation = _animation(
      animationList[i],
      i,
      reader,
      nodes.length,
      warnings,
    );
    if (animation != null) animations.add(animation);
  }

  // The scene shown: `scene`, else the first, else every node without a parent.
  final scenes = list('scenes');
  final List<int> roots;
  if (scenes.isNotEmpty) {
    final index = json['scene'] as int? ?? 0;
    roots = (scenes[index]['nodes'] as List<dynamic>? ?? const []).cast<int>();
  } else {
    final children = {for (final n in nodes) ...n.children};
    roots = [
      for (var i = 0; i < nodes.length; i++)
        if (!children.contains(i)) i,
    ];
  }

  final lightList =
      ((json['extensions'] as Map<String, dynamic>?)?['KHR_lights_punctual']
              as Map<String, dynamic>?)?['lights']
          as List<dynamic>? ??
      const [];
  final lights = [
    for (final l in lightList.cast<Map<String, dynamic>>()) _light(l),
  ];

  final model = ModelData(
    name: name,
    meshes: meshes,
    materials: materials,
    textures: textures,
    images: images,
    nodes: nodes,
    roots: roots,
    lights: lights,
    bounds: Aabb3(),
    skins: skins,
    animations: animations,
    warnings: warnings,
  );
  _computeBounds(model);
  return model;
}

ImageData _image(
  Map<String, dynamic> image,
  AccessorReader reader,
  GltfSources sources,
  List<String> warnings,
) {
  final mime = image['mimeType'] as String?;
  final name = image['name'] as String? ?? image['uri'] as String?;
  final view = image['bufferView'] as int?;
  if (view != null) {
    final data = reader.bufferView(view);
    return ImageData(Uint8List.sublistView(data), mime, name);
  }
  final uri = image['uri'] as String?;
  if (uri != null && uri.startsWith('data:')) {
    return ImageData(decodeDataUri(uri), mime, name);
  }
  final bytes = uri == null ? null : sources.uris[uri];
  if (bytes == null) {
    warnings.add('Image "$name" could not be found; it is left blank.');
    return ImageData(Uint8List(0), mime, name);
  }
  return ImageData(bytes, mime, name);
}

TextureRef? _textureRef(Map<String, dynamic>? info) {
  if (info == null) return null;
  final transform =
      (info['extensions'] as Map<String, dynamic>?)?['KHR_texture_transform']
          as Map<String, dynamic>?;
  List<double>? pair(String key) => (transform?[key] as List<dynamic>?)
      ?.map((v) => (v as num).toDouble())
      .toList();
  final offset = pair('offset');
  final scale = pair('scale');
  return TextureRef(
    info['index'] as int,
    texCoord: transform?['texCoord'] as int? ?? info['texCoord'] as int? ?? 0,
    offset: offset == null ? (0.0, 0.0) : (offset[0], offset[1]),
    scale: scale == null ? (1.0, 1.0) : (scale[0], scale[1]),
    rotation: (transform?['rotation'] as num?)?.toDouble() ?? 0.0,
  );
}

MaterialData _material(Map<String, dynamic> m) {
  final pbr = m['pbrMetallicRoughness'] as Map<String, dynamic>? ?? const {};
  final ext = m['extensions'] as Map<String, dynamic>? ?? const {};
  final base = (pbr['baseColorFactor'] as List<dynamic>?)
      ?.map((v) => (v as num).toDouble())
      .toList();
  final emissive = (m['emissiveFactor'] as List<dynamic>?)
      ?.map((v) => (v as num).toDouble())
      .toList();
  final normal = m['normalTexture'] as Map<String, dynamic>?;
  final occlusion = m['occlusionTexture'] as Map<String, dynamic>?;
  return MaterialData(
    name: m['name'] as String?,
    baseColor: base == null
        ? (1.0, 1.0, 1.0, 1.0)
        : (base[0], base[1], base[2], base[3]),
    baseColorTexture: _textureRef(
      pbr['baseColorTexture'] as Map<String, dynamic>?,
    ),
    metallic: (pbr['metallicFactor'] as num?)?.toDouble() ?? 1.0,
    roughness: (pbr['roughnessFactor'] as num?)?.toDouble() ?? 1.0,
    metallicRoughnessTexture: _textureRef(
      pbr['metallicRoughnessTexture'] as Map<String, dynamic>?,
    ),
    normalTexture: _textureRef(normal),
    normalScale: (normal?['scale'] as num?)?.toDouble() ?? 1.0,
    occlusionTexture: _textureRef(occlusion),
    occlusionStrength: (occlusion?['strength'] as num?)?.toDouble() ?? 1.0,
    emissive: emissive == null
        ? (0.0, 0.0, 0.0)
        : (emissive[0], emissive[1], emissive[2]),
    emissiveTexture: _textureRef(m['emissiveTexture'] as Map<String, dynamic>?),
    emissiveStrength:
        ((ext['KHR_materials_emissive_strength']
                    as Map<String, dynamic>?)?['emissiveStrength']
                as num?)
            ?.toDouble() ??
        1.0,
    alphaMode: switch (m['alphaMode'] as String? ?? 'OPAQUE') {
      'MASK' => AlphaMode.mask,
      'BLEND' => AlphaMode.blend,
      _ => AlphaMode.opaque,
    },
    alphaCutoff: (m['alphaCutoff'] as num?)?.toDouble() ?? 0.5,
    doubleSided: m['doubleSided'] as bool? ?? false,
    unlit: ext.containsKey('KHR_materials_unlit'),
  );
}

NodeData _node(Map<String, dynamic> n) {
  final local = Matrix4.identity();
  final matrix = n['matrix'] as List<dynamic>?;
  Vector3? translation, scale;
  Quaternion? rotation;
  if (matrix != null) {
    final s = local.storage;
    for (var i = 0; i < 16; i++) {
      s[i] = (matrix[i] as num).toDouble();
    }
  } else {
    List<double>? read(String key) =>
        (n[key] as List<dynamic>?)?.map((v) => (v as num).toDouble()).toList();
    final t = read('translation') ?? const [0.0, 0.0, 0.0];
    final r = read('rotation') ?? const [0.0, 0.0, 0.0, 1.0];
    final s = read('scale') ?? const [1.0, 1.0, 1.0];
    translation = Vector3(t[0], t[1], t[2]);
    rotation = Quaternion(r[0], r[1], r[2], r[3]);
    scale = Vector3(s[0], s[1], s[2]);
    local.setFromTrs(translation, rotation, scale);
  }
  final light =
      ((n['extensions'] as Map<String, dynamic>?)?['KHR_lights_punctual']
              as Map<String, dynamic>?)?['light']
          as int?;
  return NodeData(
    name: n['name'] as String?,
    local: local,
    children: (n['children'] as List<dynamic>? ?? const []).cast<int>(),
    mesh: n['mesh'] as int?,
    skin: n['skin'] as int?,
    light: light,
    translation: translation,
    rotation: rotation,
    scale: scale,
  );
}

SkinData _skin(Map<String, dynamic> skin, AccessorReader reader) {
  final joints = (skin['joints'] as List<dynamic>).cast<int>();
  final accessor = skin['inverseBindMatrices'] as int?;
  final Float32List inverseBind;
  if (accessor == null) {
    // No matrices: every joint's is the identity.
    inverseBind = Float32List(joints.length * 16);
    for (var j = 0; j < joints.length; j++) {
      for (var d = 0; d < 4; d++) {
        inverseBind[j * 16 + d * 5] = 1;
      }
    }
  } else {
    inverseBind = reader.floats(accessor);
    if (inverseBind.length < joints.length * 16) {
      throw FormatException(
        'A skin has fewer inverse bind matrices than joints.',
      );
    }
  }
  return SkinData(
    name: skin['name'] as String?,
    joints: joints,
    inverseBindMatrices: inverseBind,
    skeleton: skin['skeleton'] as int?,
  );
}

AnimationData? _animation(
  Map<String, dynamic> a,
  int index,
  AccessorReader reader,
  int nodeCount,
  List<String> warnings,
) {
  final name = a['name'] as String? ?? 'animation $index';
  final samplers = <AnimationSamplerData>[];
  var duration = 0.0;
  final widths = <int, int>{};
  final channels = <AnimationChannelData>[];
  for (final c
      in (a['channels'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()) {
    final target = c['target'] as Map<String, dynamic>;
    final node = target['node'] as int?;
    final path = switch (target['path'] as String?) {
      'translation' => AnimationPath.translation,
      'rotation' => AnimationPath.rotation,
      'scale' => AnimationPath.scale,
      'weights' => AnimationPath.weights,
      _ => null,
    };
    if (node == null || path == null || node >= nodeCount) continue;
    if (path == AnimationPath.weights) {
      warnings.add('$name: morph target weights are not animated yet.');
      continue;
    }
    final sampler = c['sampler'] as int;
    widths[sampler] = path == AnimationPath.rotation ? 4 : 3;
    channels.add(
      AnimationChannelData(sampler: sampler, node: node, path: path),
    );
  }
  final samplerList = (a['samplers'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>();
  for (var i = 0; i < samplerList.length; i++) {
    final sampler = samplerList[i];
    final input = reader.floats(sampler['input'] as int);
    final output = reader.floats(sampler['output'] as int);
    if (input.isNotEmpty && input.last > duration) duration = input.last;
    samplers.add(
      AnimationSamplerData(
        input: input,
        output: output,
        interpolation: switch (sampler['interpolation'] as String? ??
            'LINEAR') {
          'STEP' => AnimationInterpolation.step,
          'CUBICSPLINE' => AnimationInterpolation.cubicSpline,
          _ => AnimationInterpolation.linear,
        },
        width: widths[i] ?? reader.width(sampler['output'] as int),
      ),
    );
  }
  if (channels.isEmpty) return null;
  for (final channel in channels) {
    if (channel.sampler >= samplers.length) {
      throw FormatException(
        '$name: a channel names sampler ${channel.sampler}, which is missing.',
      );
    }
  }
  return AnimationData(
    name: name,
    channels: channels,
    samplers: samplers,
    duration: duration,
  );
}

LightData _light(Map<String, dynamic> l) {
  final color = (l['color'] as List<dynamic>?)
      ?.map((v) => (v as num).toDouble())
      .toList();
  final spot = l['spot'] as Map<String, dynamic>?;
  return LightData(
    type: switch (l['type'] as String?) {
      'directional' => LightType.directional,
      'spot' => LightType.spot,
      _ => LightType.point,
    },
    name: l['name'] as String?,
    color: color == null ? (1.0, 1.0, 1.0) : (color[0], color[1], color[2]),
    intensity: (l['intensity'] as num?)?.toDouble() ?? 1.0,
    range: (l['range'] as num?)?.toDouble(),
    innerConeAngle: (spot?['innerConeAngle'] as num?)?.toDouble() ?? 0.0,
    outerConeAngle:
        (spot?['outerConeAngle'] as num?)?.toDouble() ?? 0.7853981633974483,
  );
}

PrimitiveData? _primitive(
  AccessorReader reader,
  Map<String, dynamic> p,
  List<String> warnings,
  String meshName,
) {
  final mode = p['mode'] as int? ?? 4;
  if (mode < 4 || mode > 6) {
    warnings.add('$meshName: points and lines (mode $mode) are not drawn.');
    return null;
  }
  final attributes = p['attributes'] as Map<String, dynamic>;
  final positionAccessor = attributes['POSITION'] as int?;
  if (positionAccessor == null) {
    warnings.add('$meshName: a primitive has no POSITION and is skipped.');
    return null;
  }
  var positions = reader.floats(positionAccessor);
  var count = positions.length ~/ 3;
  Float32List? read(String key, int width) {
    final index = attributes[key] as int?;
    if (index == null) return null;
    final w = reader.width(index);
    final values = reader.floats(index);
    if (w == width) return values;
    // COLOR_0 may be VEC3: widen to VEC4 with alpha 1.
    if (key == 'COLOR_0' && w == 3 && width == 4) {
      final out = Float32List(values.length ~/ 3 * 4);
      for (var i = 0, j = 0; i < values.length; i += 3, j += 4) {
        out[j] = values[i];
        out[j + 1] = values[i + 1];
        out[j + 2] = values[i + 2];
        out[j + 3] = 1;
      }
      return out;
    }
    warnings.add(
      '$meshName: $key has $w components, expected $width; ignored.',
    );
    return null;
  }

  var normals = read('NORMAL', 3);
  var tangents = read('TANGENT', 4);
  var uvs = read('TEXCOORD_0', 2);
  var colors = read('COLOR_0', 4);
  var skin = _skinAttributes(read('JOINTS_0', 4), read('WEIGHTS_0', 4), count);

  final indexAccessor = p['indices'] as int?;
  var indices = indexAccessor != null
      ? reader.indices(indexAccessor)
      : Uint32List.fromList(List<int>.generate(count, (i) => i));
  indices = _toTriangleList(indices, mode);

  // No normals: the spec asks for flat ones, which means a vertex per corner.
  if (normals == null) {
    Float32List expand(Float32List? data, int width) {
      final out = Float32List(indices.length * width);
      if (data == null) return out;
      for (var i = 0; i < indices.length; i++) {
        final from = indices[i] * width;
        for (var c = 0; c < width; c++) {
          out[i * width + c] = data[from + c];
        }
      }
      return out;
    }

    final hadUvs = uvs != null,
        hadColors = colors != null,
        hadTangents = tangents != null;
    final hadSkin = skin != null;
    positions = expand(positions, 3);
    uvs = hadUvs ? expand(uvs, 2) : null;
    colors = hadColors ? expand(colors, 4) : null;
    tangents = hadTangents ? expand(tangents, 4) : null;
    skin = hadSkin ? expand(skin, kSkinFloats) : null;
    count = indices.length;
    normals = _flatNormals(positions);
    indices = Uint32List.fromList(List<int>.generate(count, (i) => i));
  }

  final vertices = Float32List(count * kVertexFloats);
  for (var v = 0; v < count; v++) {
    final o = v * kVertexFloats;
    vertices[o] = positions[v * 3];
    vertices[o + 1] = positions[v * 3 + 1];
    vertices[o + 2] = positions[v * 3 + 2];
    vertices[o + 3] = normals[v * 3];
    vertices[o + 4] = normals[v * 3 + 1];
    vertices[o + 5] = normals[v * 3 + 2];
    if (tangents != null) {
      for (var c = 0; c < 4; c++) {
        vertices[o + 6 + c] = tangents[v * 4 + c];
      }
    }
    if (uvs != null) {
      vertices[o + 10] = uvs[v * 2];
      vertices[o + 11] = uvs[v * 2 + 1];
    }
    for (var c = 0; c < 4; c++) {
      vertices[o + 12 + c] = colors == null ? 1 : colors[v * 4 + c];
    }
  }

  final bounds = Aabb3();
  final mm = reader.minMax(positionAccessor);
  if (mm != null && mm.$1.length >= 3) {
    bounds.setValues(
      mm.$1[0],
      mm.$1[1],
      mm.$1[2],
      mm.$2[0],
      mm.$2[1],
      mm.$2[2],
    );
  } else {
    for (var v = 0; v < count; v++) {
      bounds.addXYZ(
        positions[v * 3],
        positions[v * 3 + 1],
        positions[v * 3 + 2],
      );
    }
  }

  return PrimitiveData(
    vertices: vertices,
    indices: indices,
    material: p['material'] as int?,
    bounds: bounds,
    hasTangents: tangents != null,
    skin: skin,
  );
}

/// Joints and weights interleaved ([kSkinFloats] per vertex), weights
/// scaled to sum to 1; null unless both are present.
Float32List? _skinAttributes(
  Float32List? joints,
  Float32List? weights,
  int count,
) {
  if (joints == null || weights == null) return null;
  final out = Float32List(count * kSkinFloats);
  for (var v = 0; v < count; v++) {
    final o = v * kSkinFloats;
    var sum = 0.0;
    for (var c = 0; c < 4; c++) {
      sum += weights[v * 4 + c];
    }
    for (var c = 0; c < 4; c++) {
      out[o + c] = joints[v * 4 + c];
      out[o + 4 + c] = sum > 0 ? weights[v * 4 + c] / sum : (c == 0 ? 1 : 0);
    }
  }
  return out;
}

/// Triangle strips and fans as plain triangle lists.
Uint32List _toTriangleList(Uint32List indices, int mode) {
  if (mode == 4) return indices;
  final out = <int>[];
  for (var i = 2; i < indices.length; i++) {
    if (mode == 5) {
      // Strip: alternate winding to keep every triangle facing the same way.
      if (i.isEven) {
        out.addAll([indices[i - 2], indices[i - 1], indices[i]]);
      } else {
        out.addAll([indices[i - 1], indices[i - 2], indices[i]]);
      }
    } else {
      out.addAll([indices[0], indices[i - 1], indices[i]]);
    }
  }
  return Uint32List.fromList(out);
}

/// One normal per triangle, for corner-expanded [positions].
Float32List _flatNormals(Float32List positions) {
  final out = Float32List(positions.length);
  for (var t = 0; t + 8 < positions.length; t += 9) {
    final ax = positions[t], ay = positions[t + 1], az = positions[t + 2];
    final e1x = positions[t + 3] - ax,
        e1y = positions[t + 4] - ay,
        e1z = positions[t + 5] - az;
    final e2x = positions[t + 6] - ax,
        e2y = positions[t + 7] - ay,
        e2z = positions[t + 8] - az;
    var nx = e1y * e2z - e1z * e2y;
    var ny = e1z * e2x - e1x * e2z;
    var nz = e1x * e2y - e1y * e2x;
    final length = Vector3(nx, ny, nz).length;
    if (length > 1e-12) {
      nx /= length;
      ny /= length;
      nz /= length;
    } else {
      nx = 0;
      ny = 1;
      nz = 0;
    }
    for (var c = 0; c < 3; c++) {
      out[t + c * 3] = nx;
      out[t + c * 3 + 1] = ny;
      out[t + c * 3 + 2] = nz;
    }
  }
  return out;
}

void _computeBounds(ModelData model) {
  final corner = Vector3.zero();
  final identity = Matrix4.identity();
  model.forEachNode((index, nodeTransform) {
    final mesh = model.nodes[index].mesh;
    if (mesh == null || mesh >= model.meshes.length) return;
    // A skinned mesh is placed by its joints, not its node: in the bind
    // pose its vertices are already in model space.
    final modelFromNode = model.nodes[index].skin == null
        ? nodeTransform
        : identity;
    for (final primitive in model.meshes[mesh].primitives) {
      final b = primitive.bounds;
      if (b.isEmpty) continue;
      for (var i = 0; i < 8; i++) {
        corner.setValues(
          i & 1 == 0 ? b.min.x : b.max.x,
          i & 2 == 0 ? b.min.y : b.max.y,
          i & 4 == 0 ? b.min.z : b.max.z,
        );
        modelFromNode.transformPointInto(corner, corner);
        model.bounds.addPoint(corner);
      }
    }
  });
}

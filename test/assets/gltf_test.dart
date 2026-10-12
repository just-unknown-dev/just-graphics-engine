import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/src/assets/model_data.dart';
import 'package:just_graphics_engine/src/assets/model_loader.dart';
import 'package:just_graphics_engine/testing.dart';

/// A right triangle in the XY plane with normals facing +Z.
Map<String, dynamic> _triangle(GlbWriter w, {int? material, bool normals = true}) => {
  'attributes': {
    'POSITION': w.addFloats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3', withBounds: true),
    if (normals) 'NORMAL': w.addFloats([0, 0, 1, 0, 0, 1, 0, 0, 1], 'VEC3'),
  },
  'material': ?material,
};

Future<ModelData> _load(Uint8List bytes, {ModelFetch? fetch}) =>
    loadModelData(bytes, name: 'test', fetch: fetch);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a node hierarchy composes transforms, and bounds follow them', () async {
    final w = GlbWriter();
    final mesh = w.addMesh([_triangle(w)]);
    final child = w.addNode({'mesh': mesh, 'translation': [10, 0, 0]});
    final root = w.addNode({'children': [child], 'scale': [2, 2, 2]});
    w.setScene([root]);
    final model = await _load(w.toGlb());

    expect(model.roots, [root]);
    expect(model.meshes.single.primitives.single.vertexCount, 3);
    // Child at x 10 inside a root scaled 2: the triangle spans x 20..22.
    expect(model.bounds.min.x, closeTo(20, 1e-9));
    expect(model.bounds.max.x, closeTo(22, 1e-9));
    expect(model.bounds.max.y, closeTo(2, 1e-9));
    final seen = <int>[];
    model.forEachNode((node, _) => seen.add(node));
    expect(seen, [root, child]);
  });

  test('primitives keep their own materials; defaults follow the spec', () async {
    final w = GlbWriter();
    final red = w.addMaterial({
      'pbrMetallicRoughness': {'baseColorFactor': [1, 0, 0, 1], 'metallicFactor': 0, 'roughnessFactor': 0.5},
      'alphaMode': 'MASK',
      'alphaCutoff': 0.25,
      'doubleSided': true,
      'emissiveFactor': [1, 1, 0],
      'extensions': {
        'KHR_materials_emissive_strength': {'emissiveStrength': 4},
        'KHR_materials_unlit': <String, dynamic>{},
      },
    });
    final plain = w.addMaterial(<String, dynamic>{});
    w.setScene([w.addNode({'mesh': w.addMesh([_triangle(w, material: red), _triangle(w, material: plain)])})]);
    final model = await _load(w.toGlb());

    final primitives = model.meshes.single.primitives;
    expect(primitives.map((p) => p.material), [red, plain]);
    final m = model.materials[red];
    expect(m.baseColor, (1.0, 0.0, 0.0, 1.0));
    expect((m.metallic, m.roughness), (0.0, 0.5));
    expect((m.alphaMode, m.alphaCutoff, m.doubleSided), (AlphaMode.mask, 0.25, true));
    expect((m.emissive, m.emissiveStrength, m.unlit), ((1.0, 1.0, 0.0), 4.0, true));
    final d = model.materials[plain];
    expect((d.metallic, d.roughness, d.alphaMode, d.unlit), (1.0, 1.0, AlphaMode.opaque, false));
  });

  test('quantized positions (KHR_mesh_quantization) and normalized UVs', () async {
    final w = GlbWriter()..json['extensionsUsed'] = ['KHR_mesh_quantization'];
    final mesh = w.addMesh([
      {
        'attributes': {
          'POSITION': w.addInts([0, 0, 0, 100, 0, 0, 0, 100, 0], 'VEC3', 5122),
          'NORMAL': w.addFloats([0, 0, 1, 0, 0, 1, 0, 0, 1], 'VEC3'),
          'TEXCOORD_0': w.addInts([0, 0, 65535, 0, 0, 65535], 'VEC2', 5123, normalized: true),
        },
      },
    ]);
    w.setScene([w.addNode({'mesh': mesh, 'scale': [0.01, 0.01, 0.01]})]);
    final model = await _load(w.toGlb());
    final v = model.meshes.single.primitives.single.vertices;
    expect(v[kVertexFloats], 100, reason: 'raw quantized x of vertex 1');
    expect(v[kVertexFloats + 10], closeTo(1, 1e-6), reason: 'u of vertex 1, normalized');
    expect(model.bounds.max.x, closeTo(1, 1e-9), reason: 'the node scale dequantizes');
  });

  test('a sparse accessor starts as zeros and substitutes its values', () async {
    final w = GlbWriter();
    final mesh = w.addMesh([
      {
        'attributes': {
          'POSITION': w.addSparse(3, 'VEC3', [1, 2], [1, 0, 0, 0, 1, 0]),
          'NORMAL': w.addFloats([0, 0, 1, 0, 0, 1, 0, 0, 1], 'VEC3'),
        },
      },
    ]);
    w.setScene([w.addNode({'mesh': mesh})]);
    final p = (await _load(w.toGlb())).meshes.single.primitives.single;
    expect([p.vertices[0], p.vertices[16], p.vertices[33]], [0, 1, 1]);
    expect(p.bounds.max.x, 1);
  });

  test('missing normals become flat normals, one vertex per corner', () async {
    final w = GlbWriter();
    final mesh = w.addMesh([
      {
        ..._triangle(w, normals: false),
        'indices': w.addInts([0, 1, 2], 'SCALAR', 5123, indices: true),
      },
    ]);
    w.setScene([w.addNode({'mesh': mesh})]);
    final p = (await _load(w.toGlb())).meshes.single.primitives.single;
    expect(p.vertexCount, 3);
    for (var v = 0; v < 3; v++) {
      expect(p.vertices.sublist(v * kVertexFloats + 3, v * kVertexFloats + 6), [0, 0, 1]);
    }
    expect(p.hasTangents, isFalse);
  });

  test('a triangle strip becomes a list with consistent winding', () async {
    final w = GlbWriter();
    final mesh = w.addMesh([
      {
        'mode': 5,
        'attributes': {
          'POSITION': w.addFloats([0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0], 'VEC3', withBounds: true),
          'NORMAL': w.addFloats(List.filled(12, 0)..[2] = 1..[5] = 1..[8] = 1..[11] = 1, 'VEC3'),
        },
      },
    ]);
    w.setScene([w.addNode({'mesh': mesh})]);
    final p = (await _load(w.toGlb())).meshes.single.primitives.single;
    expect(p.indices, [0, 1, 2, 2, 1, 3]);
  });

  test('textures, samplers and KHR_texture_transform', () async {
    final w = GlbWriter();
    final image = w.addImage(Uint8List.fromList([1, 2, 3]));
    final texture = w.addTexture(image, sampler: {'magFilter': 9728, 'wrapS': 33071});
    final material = w.addMaterial({
      'pbrMetallicRoughness': {
        'baseColorTexture': {
          'index': texture,
          'extensions': {
            'KHR_texture_transform': {'offset': [0.5, 0], 'scale': [2, 2], 'rotation': 1.5},
          },
        },
      },
      'normalTexture': {'index': texture, 'scale': 0.5},
    });
    w.setScene([w.addNode({'mesh': w.addMesh([_triangle(w, material: material)])})]);
    final model = await _load(w.toGlb());
    final ref = model.materials.single.baseColorTexture!;
    expect((ref.offset, ref.scale, ref.rotation), ((0.5, 0.0), (2.0, 2.0), 1.5));
    expect(ref.hasTransform, isTrue);
    expect(model.materials.single.normalScale, 0.5);
    expect(model.textures.single.sampler.magFilter, 9728);
    expect(model.textures.single.sampler.wrapS, 33071);
    expect(model.images.single.bytes, [1, 2, 3]);
  });

  test('punctual lights hang off nodes', () async {
    final w = GlbWriter()
      ..json['extensions'] = {
        'KHR_lights_punctual': {
          'lights': [
            {'type': 'spot', 'color': [1, 0.5, 0], 'intensity': 20, 'range': 9, 'spot': {'outerConeAngle': 0.5}},
          ],
        },
      };
    w.setScene([
      w.addNode({
        'extensions': {'KHR_lights_punctual': {'light': 0}},
      }),
    ]);
    final model = await _load(w.toGlb());
    final light = model.lights.single;
    expect((light.type, light.intensity, light.range, light.outerConeAngle), (LightType.spot, 20.0, 9.0, 0.5));
    expect(model.nodes.single.light, 0);
  });

  test('a file that needs Draco is refused with a message saying so', () async {
    final w = GlbWriter()..json['extensionsRequired'] = ['KHR_draco_mesh_compression'];
    w.setScene([w.addNode(<String, dynamic>{})]);
    await expectLater(
      _load(w.toGlb()),
      throwsA(isA<UnsupportedError>().having((e) => e.message, 'message', contains('Draco'))),
    );
  });

  test('.gltf with its buffer inline, and with an external .bin', () async {
    final w = GlbWriter();
    w.setScene([w.addNode({'mesh': w.addMesh([_triangle(w)])})]);
    final (inline, _) = w.toGltf();
    final a = await _load(Uint8List.fromList(utf8.encode(inline)));
    expect(a.meshes.single.primitives.single.vertexCount, 3);

    final (external, bin) = w.toGltf(bufferUri: 'model%20data.bin');
    final fetched = <String>[];
    final b = await _load(
      Uint8List.fromList(utf8.encode(external)),
      fetch: (uri) async {
        fetched.add(uri);
        return bin;
      },
    );
    expect(fetched, ['model data.bin']);
    expect(b.bounds.max, Vector3(1, 1, 0));
  });
}

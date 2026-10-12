@Tags(['gpu'])
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/src/assets/model_loader.dart';
import 'package:just_graphics_engine/src/renderer/gpu_model.dart';
import 'package:just_graphics_engine/src/renderer/render_scene.dart';
import 'package:just_graphics_engine/src/renderer/renderer3d.dart';
import 'package:just_graphics_engine/testing.dart';

/// A unit cube (glTF axes) with one material.
GlbWriter _cube(Map<String, dynamic> material, {Uint8List? texture}) {
  final positions = <double>[];
  final normals = <double>[];
  final indices = <int>[];
  // Six faces: normal, then two axes spanning the face.
  const faces = [
    ([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]),
    ([-1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, 1.0, 0.0]),
    ([0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]),
    ([0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]),
    ([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
    ([0.0, 0.0, -1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]),
  ];
  for (final (n, u, v) in faces) {
    final base = positions.length ~/ 3;
    for (final (su, sv) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]) {
      for (var c = 0; c < 3; c++) {
        positions.add(0.5 * (n[c] + su * u[c] + sv * v[c]));
        normals.add(n[c]);
      }
    }
    indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
  }
  final w = GlbWriter();
  final mesh = w.addMesh([
    {
      'attributes': {
        'POSITION': w.addFloats(positions, 'VEC3', withBounds: true),
        'NORMAL': w.addFloats(normals, 'VEC3'),
        'TEXCOORD_0': w.addFloats([for (var f = 0; f < 6; f++) ...[0, 0, 1, 0, 1, 1, 0, 1]], 'VEC2'),
      },
      'indices': w.addInts(indices, 'SCALAR', 5123, indices: true),
      'material': w.addMaterial(texture == null
          ? material
          : {
              ...material,
              'pbrMetallicRoughness': {
                'baseColorTexture': {'index': w.addTexture(w.addImage(texture))},
              },
              'extensions': {'KHR_materials_unlit': <String, dynamic>{}},
            }),
    },
  ]);
  w.setScene([w.addNode({'mesh': mesh})]);
  return w;
}

const _size = 64;

void main() {
  final skip = gpuUnavailableReason();
  late GpuDevice device;
  late Renderer3D renderer;

  setUpAll(() async {
    if (skip != null) return;
    device = createGpuDevice()!;
    renderer = await Renderer3D.create(device);
  });

  Future<GpuModel> model(Map<String, dynamic> material, {Uint8List? texture}) async =>
      renderer.uploader.upload(
        await loadModelData(_cube(material, texture: texture).toGlb(), name: 'cube'),
      );

  /// A solid-colour PNG, encoded by Flutter.
  Future<Uint8List> png(ui.Color color) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 8, 8), ui.Paint()..color = color);
    final image = await recorder.endRecording().toImage(8, 8);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  RenderView camera({Vector3? eye}) {
    final view = RenderView()
      ..width = _size
      ..height = _size;
    // 1 m above (−Y is up) and 4 m back, looking at the origin.
    view.lookAt(eye ?? Vector3(0, -1, -4), Vector3.zero());
    view.projection.setPerspectiveYDown(math.pi / 3, 1, 0.1, 100);
    return view;
  }

  Future<RgbaPixels> draw(RenderScene scene, RenderView view) async {
    final surface = device.createSurface(_size, _size);
    expect(await renderer.render(scene, view, surface), isTrue);
    return readPixels(surface.image!);
  }

  test('a red cube, lit by the sun, in front of a blue sky', () async {
    final scene = RenderScene();
    scene.addModel(
      await model({
        'pbrMetallicRoughness': {'baseColorFactor': [0.8, 0.05, 0.05, 1], 'metallicFactor': 0, 'roughnessFactor': 0.6},
      }),
      Matrix4.identity(),
    );
    final px = await draw(scene, camera());
    final centre = px.atFraction(0.5, 0.55);
    final corner = px.at(1, 1);
    // ignore: avoid_print
    print('RENDER centre $centre corner $corner ${renderer.stats}');
    expect(centre[0], greaterThan(centre[1] + 40), reason: 'red cube in the middle: $centre');
    expect(corner[2], greaterThan(corner[0]), reason: 'blue sky above: $corner');
    expect(renderer.stats.instances, 1);
  }, skip: skip);

  test('100 instances of one mesh and material are one draw call', () async {
    renderer.shadows.cascades = 1;
    final scene = RenderScene();
    final cube = await model({'pbrMetallicRoughness': {'baseColorFactor': [0.2, 0.7, 0.2, 1]}});
    for (var i = 0; i < 100; i++) {
      scene.addModel(cube, Matrix4.translationValues((i % 10 - 4.5) * 0.3, 0, 3 + (i ~/ 10) * 0.3)..scaleByDouble(0.2, 0.2, 0.2, 1));
    }
    await draw(scene, camera(eye: Vector3(0, -2, -3)));
    expect(renderer.stats.instances, 100);
    // One lit draw, the sky and the tonemap; one more into the shadow map.
    expect(renderer.stats.drawCalls, 4, reason: '${renderer.stats}');
    expect(renderer.stats.shadowDrawCalls, 1);
  }, skip: skip);

  test('instances behind the camera are culled', () async {
    final scene = RenderScene();
    final cube = await model(const {});
    scene.addModel(cube, Matrix4.identity());
    scene.addModel(cube, Matrix4.translationValues(0, 0, -50));
    await draw(scene, camera());
    expect(renderer.stats.culled, 1);
    expect(renderer.stats.instances, 1);
  }, skip: skip);

  test('an unlit material shows its colour without shading', () async {
    final scene = RenderScene()..environment.sky = false;
    scene.addModel(
      await model({
        'pbrMetallicRoughness': {'baseColorFactor': [0, 0, 1, 1]},
        'extensions': {'KHR_materials_unlit': <String, dynamic>{}},
      }),
      Matrix4.identity(),
    );
    final px = await draw(scene, camera());
    final c = px.atFraction(0.5, 0.55);
    expect(c[2], greaterThan(150), reason: '$c');
    expect(c[0], lessThan(30), reason: '$c');
    expect(c[1], lessThan(30), reason: '$c');
  }, skip: skip);

  test('a base colour texture is decoded, mipmapped and sampled as sRGB', () async {
    final scene = RenderScene()..environment.sky = false;
    final texture = await png(const ui.Color(0xFF00C800));
    scene.addModel(await model(const {}, texture: texture), Matrix4.identity());
    final c = (await draw(scene, camera())).atFraction(0.5, 0.55);
    expect(c[1], greaterThan(150), reason: 'green texture: $c');
    expect(c[0], lessThan(40), reason: '$c');
    expect(c[2], lessThan(40), reason: '$c');
  }, skip: skip);
}

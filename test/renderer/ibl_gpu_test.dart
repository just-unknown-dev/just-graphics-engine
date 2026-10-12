@Tags(['gpu'])
library;

// Image-based light on a real GPU: the cube's faces land where the engine's
// directions say (a skybox looking along each axis shows that face), and a
// surface takes its ambient light and reflections from the map.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';
import 'package:just_graphics_engine/testing.dart';

const _size = 32;

/// A colour for each axis direction: what a face shows.
const _faceColours = <(double, double, double)>[
  (1, 0, 0), // +X red
  (0, 1, 0), // -X green
  (0, 0, 1), // +Y blue (down)
  (1, 1, 0), // -Y yellow (up)
  (1, 0, 1), // +Z magenta
  (0, 1, 1), // -Z cyan
];

EnvironmentMapData _axes() => EnvironmentMapData.build((x, y, z, out) {
  final (face, _, _) = EnvironmentMapData.faceOf(x, y, z);
  final c = _faceColours[face];
  out[0] = c.$1;
  out[1] = c.$2;
  out[2] = c.$3;
}, size: 8);

/// A 4 m square facing the camera, 3 m ahead along +Z.
GlbWriter _wall({required bool metal}) {
  final w = GlbWriter();
  final mesh = w.addMesh([
    {
      'attributes': {
        'POSITION': w.addFloats([-2, -2, 0, 2, -2, 0, 2, 2, 0, -2, 2, 0], 'VEC3', withBounds: true),
        'NORMAL': w.addFloats([0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1], 'VEC3'),
      },
      'indices': w.addInts([0, 2, 1, 0, 3, 2], 'SCALAR', 5123, indices: true),
      'material': w.addMaterial({
        'pbrMetallicRoughness': {'baseColorFactor': [1, 1, 1, 1], 'metallicFactor': metal ? 1 : 0, 'roughnessFactor': metal ? 0.05 : 1},
        'doubleSided': true,
      }),
    },
  ]);
  w.setScene([w.addNode({'mesh': mesh})]);
  return w;
}

void main() {
  final skip = gpuUnavailableReason();
  late GpuDevice device;
  late Renderer3D renderer;

  setUpAll(() async {
    if (skip != null) return;
    device = createGpuDevice()!;
    renderer = await Renderer3D.create(device);
    renderer.shadows.enabled = false;
  });

  Future<List<int>> look(RenderScene scene, Vector3 direction) async {
    final view = RenderView()
      ..width = _size
      ..height = _size;
    view.lookAt(Vector3.zero(), direction, up: direction.y.abs() > 0.9 ? Vector3(0, 0, 1) : null);
    view.projection.setPerspectiveYDown(math.pi / 4, 1, 0.1, 100);
    final surface = device.createSurface(_size, _size);
    expect(await renderer.render(scene, view, surface), isTrue);
    return (await readPixels(surface.image!)).atFraction(0.5, 0.5);
  }

  test('a skybox shows each face where its axis points', () async {
    final scene = RenderScene()..sun.enabled = false;
    scene.environment
      ..map = GpuEnvironmentMap.upload(device, _axes())
      ..skybox = true;
    final directions = [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)];
    for (var face = 0; face < 6; face++) {
      final px = await look(scene, directions[face]);
      final want = _faceColours[face];
      for (var c = 0; c < 3; c++) {
        final on = [want.$1, want.$2, want.$3][c] > 0.5;
        expect(on ? px[c] > 150 : px[c] < 60, isTrue, reason: 'face $face channel $c: $px');
      }
    }
  }, skip: skip);

  test('a rough wall takes its light from the map; a mirror reflects it', () async {
    // Everything around is blue but a small patch straight behind the
    // camera, which is red: the rough wall gathers mostly blue, the mirror
    // shows the red.
    final map = EnvironmentMapData.build((x, y, z, out) {
      final behind = z < -0.95;
      out[0] = behind ? 1.0 : 0.05;
      out[1] = 0.05;
      out[2] = behind ? 0.05 : 1.0;
    }, size: 16);
    final env = GpuEnvironmentMap.upload(device, map);
    Future<List<int>> wall({required bool metal, required bool ibl}) async {
      final model = await renderer.uploader.upload(await loadModelData(_wall(metal: metal).toGlb(), name: 'wall'));
      final scene = RenderScene()
        ..sun.enabled = false
        ..addModel(model, Matrix4.translationValues(0, 0, 3), correctAxes: false);
      scene.environment.sky = false;
      if (ibl) scene.environment.map = env;
      return look(scene, Vector3(0, 0, 1));
    }

    final rough = await wall(metal: false, ibl: true);
    expect(rough[2], greaterThan(rough[0]), reason: 'blue light from all round: $rough');
    final mirror = await wall(metal: true, ibl: true);
    expect(mirror[0], greaterThan(mirror[2]), reason: 'the red behind, reflected: $mirror');
    final hemisphere = await wall(metal: false, ibl: false);
    expect(hemisphere, isNot(rough), reason: 'without a map, the hemisphere light');
  }, skip: skip);
}

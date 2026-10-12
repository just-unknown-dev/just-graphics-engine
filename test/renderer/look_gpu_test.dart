@Tags(['gpu'])
library;

// The renderer's look features on a real GPU: fog, and (as they come) the
// rest of the polish pass.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';
import 'package:just_graphics_engine/testing.dart';

const _size = 64;

GlbWriter _cube() {
  final w = GlbWriter();
  final p = <double>[], n = <double>[], idx = <int>[];
  const faces = [
    ([0.0, 0.0, -1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]),
  ];
  for (final (nn, u, v) in faces) {
    final b = p.length ~/ 3;
    for (final (su, sv) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]) {
      for (var c = 0; c < 3; c++) {
        p.add(0.5 * (nn[c] + su * u[c] + sv * v[c]) * 4);
        n.add(nn[c]);
      }
    }
    idx.addAll([b, b + 1, b + 2, b, b + 2, b + 3]);
  }
  final mesh = w.addMesh([
    {
      'attributes': {'POSITION': w.addFloats(p, 'VEC3', withBounds: true), 'NORMAL': w.addFloats(n, 'VEC3')},
      'indices': w.addInts(idx, 'SCALAR', 5123, indices: true),
      'material': w.addMaterial({
        'pbrMetallicRoughness': {'baseColorFactor': [1, 0, 0, 1], 'metallicFactor': 0},
        'extensions': {'KHR_materials_unlit': <String, dynamic>{}},
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
  late GpuModel wall;

  setUpAll(() async {
    if (skip != null) return;
    device = createGpuDevice()!;
    renderer = await Renderer3D.create(device);
    renderer.shadows.enabled = false;
    wall = await renderer.uploader.upload(await loadModelData(_cube().toGlb(), name: 'wall'));
  });

  Future<List<int>> centre(RenderScene scene) async {
    final view = RenderView()
      ..width = _size
      ..height = _size;
    view.lookAt(Vector3.zero(), Vector3(0, 0, 1));
    view.projection.setPerspectiveYDown(math.pi / 3, 1, 0.1, 500);
    final surface = device.createSurface(_size, _size);
    expect(await renderer.render(scene, view, surface), isTrue);
    return (await readPixels(surface.image!)).atFraction(0.5, 0.5);
  }

  test('fog fades a distant wall towards the fog colour', () async {
    RenderScene scene(double density) {
      final s = RenderScene()..addModel(wall, Matrix4.translationValues(0, 0, 40), correctAxes: false);
      s.environment
        ..fogColor = (0.0, 0.0, 1.0)
        ..fogDensity = density
        ..fogStart = 5;
      return s;
    }

    final clear = await centre(scene(0));
    final foggy = await centre(scene(0.05));
    // ignore: avoid_print
    print('FOG clear $clear foggy $foggy');
    expect(clear[0], greaterThan(200));
    expect(clear[2], lessThan(40));
    // exp(-0.05 * 35) leaves about a sixth of the red.
    expect(foggy[2], greaterThan(foggy[0]), reason: 'mostly fog: $foggy');
  }, skip: skip);

  Future<RgbaPixels> draw(RenderScene scene) async {
    final view = RenderView()
      ..width = _size
      ..height = _size;
    view.lookAt(Vector3.zero(), Vector3(0, 0, 1));
    view.projection.setPerspectiveYDown(math.pi / 3, 1, 0.1, 500);
    final surface = device.createSurface(_size, _size);
    expect(await renderer.render(scene, view, surface), isTrue);
    return readPixels(surface.image!);
  }

  test('bloom spills light from something bright onto its surroundings', () async {
    final glowing = await renderer.uploader.upload(
      await loadModelData(
        (GlbWriter()
              ..also((w) {
                final mesh = w.addMesh([
                  {
                    'attributes': {
                      'POSITION': w.addFloats([-0.3, -0.3, 0, 0.3, -0.3, 0, 0.3, 0.3, 0, -0.3, 0.3, 0], 'VEC3', withBounds: true),
                      'NORMAL': w.addFloats([0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1], 'VEC3'),
                    },
                    'indices': w.addInts([0, 2, 1, 0, 3, 2], 'SCALAR', 5123, indices: true),
                    'material': w.addMaterial({
                      'pbrMetallicRoughness': {'baseColorFactor': [0, 0, 0, 1]},
                      'emissiveFactor': [1, 1, 1],
                      'extensions': {'KHR_materials_emissive_strength': {'emissiveStrength': 20}},
                      'doubleSided': true,
                    }),
                  },
                ]);
                w.setScene([w.addNode({'mesh': mesh})]);
              }))
            .toGlb(),
        name: 'glow',
      ),
    );
    RenderScene scene() {
      final s = RenderScene()..addModel(glowing, Matrix4.translationValues(0, 0, 3), correctAxes: false);
      s.environment
        ..sky = false
        ..clearColor = (0.0, 0.0, 0.0);
      s.sun.enabled = false;
      return s;
    }

    renderer.bloom.enabled = false;
    final plain = await draw(scene());
    renderer.bloom
      ..enabled = true
      ..intensity = 1.0;
    final bloomed = await draw(scene());
    renderer.bloom.enabled = false;
    // A little outside the square's edge: dark without bloom, lit with it.
    final beside = (0.5 + 0.25, 0.5);
    final a = plain.atFraction(beside.$1, beside.$2), b = bloomed.atFraction(beside.$1, beside.$2);
    // ignore: avoid_print
    print('BLOOM plain $a bloomed $b ${renderer.stats}');
    expect(a[0], lessThan(10));
    expect(b[0], greaterThan(a[0] + 20));
  }, skip: skip);

  test('FXAA softens an edge drawn without MSAA', () async {
    RenderScene scene() {
      final s = RenderScene()..addModel(wall, Matrix4.rotationZ(0.3)..setTranslationRaw(0, 0, 6), correctAxes: false);
      s.environment
        ..sky = false
        ..clearColor = (0.0, 0.0, 0.0);
      return s;
    }

    int mixedPixels(RgbaPixels px) {
      var n = 0;
      for (var y = 0; y < _size; y++) {
        for (var x = 0; x < _size; x++) {
          final r = px.at(x, y)[0];
          if (r > 30 && r < 200) n++;
        }
      }
      return n;
    }

    renderer.msaa = false;
    final hard = await draw(scene());
    renderer.fxaa = true;
    final soft = await draw(scene());
    renderer
      ..fxaa = false
      ..msaa = true;
    // ignore: avoid_print
    print('FXAA mixed edge pixels: hard ${mixedPixels(hard)}, soft ${mixedPixels(soft)}');
    expect(mixedPixels(soft), greaterThan(mixedPixels(hard) + 10));
  }, skip: skip);
}

extension<T> on T {
  T also(void Function(T it) f) {
    f(this);
    return this;
  }
}

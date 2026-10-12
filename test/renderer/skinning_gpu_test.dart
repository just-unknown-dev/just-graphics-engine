@Tags(['gpu'])
library;

// Skinning and shadows on a real GPU: the bent bar draws where its joints
// put it (both ways of getting palettes to the shader), and casters darken
// the ground where the sun says.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';
import 'package:just_graphics_engine/testing.dart';

const _size = 96;

/// A box (glTF axes) of [x] × [y] × [z] metres, its bottom at [lift].
GlbWriter _box(double x, double y, double z, {double lift = 0, List<double> rgba = const [0.8, 0.8, 0.8, 1]}) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  const faces = [
    ([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]),
    ([-1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, 1.0, 0.0]),
    ([0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]),
    ([0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]),
    ([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
    ([0.0, 0.0, -1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]),
  ];
  final half = [x / 2, y / 2, z / 2];
  for (final (n, u, v) in faces) {
    final base = positions.length ~/ 3;
    for (final (su, sv) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]) {
      for (var c = 0; c < 3; c++) {
        positions.add((n[c] + su * u[c] + sv * v[c]) * half[c] + (c == 1 ? half[1] + lift : 0));
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
      },
      'indices': w.addInts(indices, 'SCALAR', 5123, indices: true),
      'material': w.addMaterial({
        'pbrMetallicRoughness': {'baseColorFactor': rgba, 'metallicFactor': 0, 'roughnessFactor': 0.9},
      }),
    },
  ]);
  w.setScene([w.addNode({'mesh': mesh})]);
  return w;
}

double _luma(List<int> p) => 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];

void main() {
  final skip = gpuUnavailableReason();
  late GpuDevice device;
  late Renderer3D renderer;

  setUpAll(() async {
    if (skip != null) return;
    device = createGpuDevice()!;
    renderer = await Renderer3D.create(device);
  });

  RenderView camera(Vector3 eye, Vector3 target) {
    final view = RenderView()
      ..width = _size
      ..height = _size;
    view.lookAt(eye, target);
    view.projection.setPerspectiveYDown(math.pi / 3, 1, 0.1, 100);
    return view;
  }

  /// The pixel [p] (engine world) lands on.
  (double, double) pixelOf(RenderView view, Vector3 p) {
    final vp = Matrix4.identity()..setProduct(view.projection, view.view);
    final c = Vector3.zero();
    vp.transformPointInto(p, c);
    return ((c.x + 1) / 2 * _size, (c.y + 1) / 2 * _size);
  }

  List<int> at(RgbaPixels px, (double, double) xy) => px.at(xy.$1.floor(), xy.$2.floor());

  Future<RgbaPixels> draw(RenderScene scene, RenderView view) async {
    final surface = device.createSurface(_size, _size);
    expect(await renderer.render(scene, view, surface), isTrue);
    return readPixels(surface.image!);
  }

  test('the null device reports the shaders as reflection does', () async {
    final library = await device.loadShaderLibrary('core.shaderbundle');
    for (final MapEntry(key: name, value: blocks) in rendererNullShaders.entries) {
      final shader = library[name];
      expect(shader, isNotNull, reason: name);
      for (final MapEntry(key: block, value: expected) in blocks.entries) {
        final real = shader!.uniformBlock(block);
        expect(real, isNotNull, reason: '$name $block');
        expect(real!.sizeInBytes, expected.sizeInBytes, reason: '$name $block size');
        for (final MapEntry(key: member, value: offset) in expected.offsets.entries) {
          expect(real.offsetOf(member), offset, reason: '$name $block.$member');
        }
      }
    }
  }, skip: skip);

  group('skinning', () {
    late GpuModel bar;
    setUpAll(() async {
      if (skip != null) return;
      bar = await renderer.uploader.upload(await loadModelData(skinnedBarGlb(halfWidth: 0.15), name: 'bar'));
    });

    Future<RgbaPixels> bent(SkinningMode mode) async {
      renderer
        ..skinning = mode
        ..shadows.enabled = false;
      final scene = RenderScene()..sun.direction.setValues(0.2, 1, 0.6);
      final posed = PosedModel(bar);
      bar.clips['bend']!.sample(1, posed.pose);
      posed.update();
      scene.addModel(bar, Matrix4.identity(), posed: posed);
      return draw(scene, camera(Vector3(0, -1, -4), Vector3(0, -1, 0)));
    }

    test('the bent tip points along -X: red where it went, sky where it was', () async {
      final view = camera(Vector3(0, -1, -4), Vector3(0, -1, 0));
      final px = await bent(SkinningMode.texture);
      final tip = at(px, pixelOf(view, Vector3(-0.75, -1, 0)));
      final wasTip = at(px, pixelOf(view, Vector3(0, -1.8, 0)));
      final foot = at(px, pixelOf(view, Vector3(0, -0.25, 0)));
      // ignore: avoid_print
      print('SKIN tip $tip wasTip $wasTip foot $foot ${renderer.stats}');
      expect(tip[0], greaterThan(tip[2] + 40), reason: 'bent tip is red: $tip');
      expect(foot[0], greaterThan(foot[2] + 40), reason: 'the foot stays: $foot');
      expect(wasTip[2], greaterThan(wasTip[0]), reason: 'sky where the tip stood: $wasTip');
      expect(renderer.stats.skinnedInstances, 1);
    }, skip: skip);

    test('palettes in uniforms draw the same picture', () async {
      final texture = await bent(SkinningMode.texture);
      final uniforms = await bent(SkinningMode.uniforms);
      final diff = compareImages(texture, uniforms, tolerance: 3);
      expect(diff.differingPixels, lessThanOrEqualTo(_size * _size ~/ 200), reason: '$diff');
      renderer.skinning = SkinningMode.texture;
    }, skip: skip);
  });

  group('shadows', () {
    late GpuModel ground, cube, bar;
    setUpAll(() async {
      if (skip != null) return;
      ground = await renderer.uploader.upload(await loadModelData(_box(12, 0.2, 12, lift: -0.2).toGlb(), name: 'ground'));
      cube = await renderer.uploader.upload(await loadModelData(_box(1, 1, 1, rgba: const [0.2, 0.4, 0.9, 1]).toGlb(), name: 'cube'));
      bar = await renderer.uploader.upload(await loadModelData(skinnedBarGlb(halfWidth: 0.3), name: 'bar'));
    });

    RenderScene scene() => RenderScene()
      ..addModel(ground, Matrix4.identity())
      ..sun.direction.setValues(0, 1, 1)
      ..sun.direction.normalize();

    test('a floating cube shades the ground along the sun', () async {
      renderer.shadows
        ..enabled = true
        ..distance = 20;
      final s = scene()..addModel(cube, Matrix4.translationValues(0, -1, 0));
      final view = camera(Vector3(0, -3, -6), Vector3(0, 0, 1));
      final px = await draw(s, view);
      final shaded = at(px, pixelOf(view, Vector3(0, 0, 1.5)));
      final open = at(px, pixelOf(view, Vector3(-2.5, 0, 1.5)));
      // ignore: avoid_print
      print('SHADOW shaded $shaded open $open ${renderer.stats}');
      expect(_luma(shaded), lessThan(_luma(open) * 0.85), reason: 'shaded $shaded, open $open');
      renderer.shadows.enabled = false;
      final unshadowed = await draw(s, view);
      final same = at(unshadowed, pixelOf(view, Vector3(0, 0, 1.5)));
      expect(_luma(same), greaterThan(_luma(open) * 0.85), reason: 'without shadows it is lit: $same');
      renderer.shadows.enabled = true;
    }, skip: skip);

    test('a skinned caster shades the ground where its pose puts it', () async {
      Future<List<int>> groundBeside(bool bend) async {
        final s = scene();
        final posed = PosedModel(bar);
        if (bend) bar.clips['bend']!.sample(1, posed.pose);
        posed.update();
        s.addModel(bar, Matrix4.identity(), posed: posed);
        final view = camera(Vector3(0, -3, -6), Vector3(0, 0, 0.5));
        final px = await draw(s, view);
        return at(px, pixelOf(view, Vector3(-0.8, 0, 1.0)));
      }

      final straight = await groundBeside(false);
      final bent = await groundBeside(true);
      // ignore: avoid_print
      print('SKIN SHADOW straight $straight bent $bent');
      expect(_luma(bent), lessThan(_luma(straight) * 0.85), reason: 'bent $bent, straight $straight');
    }, skip: skip);
  });
}

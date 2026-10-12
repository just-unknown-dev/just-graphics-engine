// The sun's shadow map: where it is placed, that it does not crawl, and
// which instances cast into it.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';
import 'package:just_graphics_engine/testing.dart';

RenderView _view(Vector3 eye, Vector3 target) {
  final view = RenderView()
    ..width = 640
    ..height = 360;
  view.lookAt(eye, target);
  view.projection.setPerspectiveYDown(math.pi / 3, 16 / 9, 0.1, 500);
  return view;
}

Vector3 _clip(Matrix4 m, Vector3 p) {
  final out = Vector3.zero();
  m.transformPointInto(p, out);
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sun = Vector3(0.3, 1, 0.5)..normalize();

  test('the map covers what the camera sees up to the shadow distance', () {
    final settings = ShadowSettings()..distance = 30;
    final fit = ShadowFit();
    final view = _view(Vector3(0, -2, -10), Vector3(0, 0, 0));
    expect(fitSunShadow(view, sun, settings, fit), isTrue);
    // Points in view within 30 m land inside the map, depth inside 0..1.
    for (final p in [Vector3(0, 0, 0), Vector3(5, 0, 10), Vector3(-6, -1, 15), Vector3(0, 0, 19)]) {
      final c = _clip(fit.viewProjection, p);
      expect(c.x.abs(), lessThan(1), reason: '$p x');
      expect(c.y.abs(), lessThan(1), reason: '$p y');
      expect(c.z, inInclusiveRange(0, 1), reason: '$p z');
    }
    // Further along the sun's path towards it: still in depth range (casters
    // up to casterReach behind count).
    final above = Vector3(-sun.x * 40, -sun.y * 40, -sun.z * 40);
    expect(_clip(fit.viewProjection, above).z, inInclusiveRange(0, 1));
    expect(fit.texelSize, closeTo(2 * fit.radius / settings.mapSize, 1e-9));
  });

  test('moving the camera a little keeps texels where they were', () {
    final settings = ShadowSettings();
    final a = ShadowFit(), b = ShadowFit();
    fitSunShadow(_view(Vector3(0, -2, -10), Vector3(0, 0, 0)), sun, settings, a);
    fitSunShadow(_view(Vector3(0.013, -2, -10), Vector3(0.013, 0, 0)), sun, settings, b);
    expect(b.radius, a.radius, reason: 'the size changes only in steps');
    // A world point lands on the same texel grid: its texel coordinate
    // differs by a whole number.
    final p = Vector3(1, 0, 3);
    final ua = (_clip(a.viewProjection, p).x + 1) / 2 * settings.mapSize;
    final ub = (_clip(b.viewProjection, p).x + 1) / 2 * settings.mapSize;
    final shift = ub - ua;
    expect((shift - shift.roundToDouble()).abs(), lessThan(1e-3), reason: 'shift $shift texels');
  });

  test('turning the camera keeps the size', () {
    final settings = ShadowSettings();
    final radii = <double>{};
    for (var a = 0; a < 8; a++) {
      final dir = Vector3(math.sin(a * 0.8), 0, math.cos(a * 0.8));
      final fit = ShadowFit();
      fitSunShadow(_view(Vector3(0, -2, 0), dir), sun, settings, fit);
      radii.add(fit.radius);
    }
    expect(radii, hasLength(1));
  });

  group('casters', () {
    late NullGpuDevice device;
    late Renderer3D renderer;
    late GpuModel cube;

    setUp(() async {
      device = NullGpuDevice(shaders: rendererNullShaders);
      renderer = await Renderer3D.create(device);
      final w = GlbWriter();
      final mesh = w.addMesh([
        {
          'attributes': {
            'POSITION': w.addFloats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3', withBounds: true),
            'NORMAL': w.addFloats([0, 0, 1, 0, 0, 1, 0, 0, 1], 'VEC3'),
          },
        },
      ]);
      w.setScene([w.addNode({'mesh': mesh})]);
      cube = await renderer.uploader.upload(await loadModelData(w.toGlb(), name: 'tri'));
    });

    test('in view and near cast, far behind the camera do not, and they batch', () async {
      renderer.shadows.cascades = 1;
      final scene = RenderScene();
      for (var i = 0; i < 4; i++) {
        scene.addModel(cube, Matrix4.translationValues(i.toDouble(), 0, 2));
      }
      scene.addModel(cube, Matrix4.translationValues(0, 0, -400)); // far behind
      final noCast = scene.addModel(cube, Matrix4.translationValues(1, 0, 3)).single..castShadows = false;
      await renderer.render(scene, _view(Vector3(0, -2, -6), Vector3(0, 0, 2)), device.createSurface(64, 64));
      expect(renderer.stats.shadowCasters, 4);
      expect(renderer.stats.shadowDrawCalls, 1, reason: 'one mesh: one instanced draw');
      expect(noCast.visible, isTrue);
      expect(device.log, contains('setPipeline ShadowVertex+ShadowFragment'));
      expect(device.log.where((l) => l.startsWith('texture GpuTextureDesc(2048x2048 r32f')), isNotEmpty);
    });

    test('two cascades: a map near the camera and one beyond, each with its casters', () async {
      final scene = RenderScene()
        ..addModel(cube, Matrix4.translationValues(0, 0, 3)) // near
        ..addModel(cube, Matrix4.translationValues(0, 0, 30)); // far
      renderer.shadows
        ..distance = 40
        ..cascadeSplit = 0.25;
      device.log.clear();
      await renderer.render(scene, _view(Vector3(0, -2, -6), Vector3(0, 0, 2)), device.createSurface(64, 64));
      expect(device.log.where((l) => l.startsWith('texture GpuTextureDesc(2048x2048 r32f')), hasLength(2));
      expect(device.log, contains('texture shadow_texture_2'));
      expect(renderer.stats.shadowDrawCalls, 2);
      // Each cube counted in the cascades whose box holds it.
      expect(renderer.stats.shadowCasters, inInclusiveRange(2, 4));
    });

    test('no sun, or shadows off: no shadow pass', () async {
      final scene = RenderScene()..addModel(cube, Matrix4.identity());
      scene.sun.enabled = false;
      await renderer.render(scene, _view(Vector3(0, -2, -6), Vector3.zero()), device.createSurface(64, 64));
      expect(renderer.stats.shadowDrawCalls, 0);
      scene.sun.enabled = true;
      renderer.shadows.enabled = false;
      await renderer.render(scene, _view(Vector3(0, -2, -6), Vector3.zero()), device.createSurface(64, 64));
      expect(renderer.stats.shadowDrawCalls, 0);
    });

    test('state already set is not set again', () async {
      final scene = RenderScene();
      final other = await renderer.uploader.upload(await loadModelData(skinnedBarGlb(), name: 'bar'));
      for (var i = 0; i < 3; i++) {
        scene.addModel(cube, Matrix4.translationValues(i.toDouble(), 0, 2));
        scene.addModel(other, Matrix4.translationValues(i.toDouble(), 0, 4));
      }
      renderer.shadows.enabled = false;
      device.log.clear();
      await renderer.render(scene, _view(Vector3(0, -2, -6), Vector3(0, 0, 2)), device.createSurface(64, 64));
      // Two materials bound once each: cull and blend set per material.
      expect(device.log.where((l) => l.startsWith('cull')).length, lessThanOrEqualTo(4));
    });
  });
}

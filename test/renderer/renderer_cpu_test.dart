// The renderer's CPU side on the null device: culling, sorting, batching
// and uniform packing, with no GPU in the way.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';
import 'package:just_graphics_engine/testing.dart';

Future<GpuModel> _triangleModel(Renderer3D renderer, double red) async {
  final w = GlbWriter();
  final mesh = w.addMesh([
    {
      'attributes': {
        'POSITION': w.addFloats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3', withBounds: true),
        'NORMAL': w.addFloats([0, 0, 1, 0, 0, 1, 0, 0, 1], 'VEC3'),
      },
      'material': w.addMaterial({
        'pbrMetallicRoughness': {'baseColorFactor': [red, 0, 0, 1]},
      }),
    },
  ]);
  w.setScene([w.addNode({'mesh': mesh})]);
  return renderer.uploader.upload(await loadModelData(w.toGlb(), name: 'tri'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NullGpuDevice device;
  late Renderer3D renderer;
  late RenderView view;

  setUp(() async {
    device = NullGpuDevice(shaders: rendererNullShaders);
    renderer = await Renderer3D.create(device);
    view = RenderView()
      ..width = 640
      ..height = 360;
    view.lookAt(Vector3(0, -5, -20), Vector3.zero());
    view.projection.setPerspectiveYDown(math.pi / 3, 16 / 9, 0.1, 500);
  });

  test('instances of one mesh and material share a draw; others do not', () async {
    renderer.shadows.enabled = false; // the main pass alone
    final a = await _triangleModel(renderer, 1);
    final b = await _triangleModel(renderer, 0.5);
    final scene = RenderScene();
    for (var i = 0; i < 5; i++) {
      scene.addModel(a, Matrix4.translationValues(i.toDouble(), 0, 0));
      scene.addModel(b, Matrix4.translationValues(i.toDouble(), 2, 0));
    }
    await renderer.render(scene, view, device.createSurface(640, 360));
    expect(renderer.stats.instances, 10);
    // Two lit batches, then the sky and the tonemap.
    expect(device.log.where((l) => l.startsWith('drawIndexed')).toList(), [
      'drawIndexed 3 x5',
      'drawIndexed 3 x5',
    ]);
    expect(renderer.stats.drawCalls, 4);
  });

  test('the brightest lights for the camera win the 8 slots', () async {
    final scene = RenderScene();
    for (var i = 0; i < 12; i++) {
      scene.lights.add(
        PunctualLight(type: LightType.point, position: Vector3(0, 0, i * 10.0)),
      );
    }
    await renderer.render(scene, view, device.createSurface(640, 360));
    expect(renderer.stats.lights, 8);
  });

  test('2,000 instances: CPU time per frame', () async {
    final models = [for (var m = 0; m < 10; m++) await _triangleModel(renderer, m / 10)];
    final scene = RenderScene();
    final random = math.Random(1);
    for (var i = 0; i < 2000; i++) {
      scene.addModel(
        models[i % models.length],
        Matrix4.translationValues(
          random.nextDouble() * 40 - 20,
          random.nextDouble() * 10 - 5,
          random.nextDouble() * 40,
        ),
      );
    }
    final surface = device.createSurface(640, 360);
    for (var i = 0; i < 5; i++) {
      await renderer.render(scene, view, surface); // warm up
    }
    const frames = 20;
    final watch = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      // Everything moves every frame: bounds are recomputed each time.
      for (final instance in scene.instances) {
        instance.markMoved();
      }
      await renderer.render(scene, view, surface);
    }
    watch.stop();
    final ms = watch.elapsedMicroseconds / frames / 1000;
    // ignore: avoid_print
    print('PERF renderer2k: ${ms.toStringAsFixed(3)} ms/frame '
        '(${renderer.stats.instances} drawn, ${renderer.stats.culled} culled, '
        '${renderer.stats.drawCalls} draws)');
    expect(
      renderer.stats.drawCalls - renderer.stats.shadowDrawCalls,
      lessThanOrEqualTo(12),
      reason: 'batched by mesh and material',
    );
    expect(renderer.stats.shadowDrawCalls, lessThanOrEqualTo(20), reason: 'casters batched by mesh, per cascade');
    expect(ms, lessThan(100), reason: 'generous ceiling; the number is printed');
  });
}

// Poses into joint palettes, and skinned drawing on the null device:
// palettes packed into one texture, skinned instances batched, the uniform
// fallback one draw each, and the cost of 20 characters of 65 joints.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';
import 'package:just_graphics_engine/testing.dart';

/// [m] (16 floats at [o], column-major) applied to (x, y, z, 1).
List<double> _apply(Float32List rows, int o, double x, double y, double z) => [
  rows[o] * x + rows[o + 1] * y + rows[o + 2] * z + rows[o + 3],
  rows[o + 4] * x + rows[o + 5] * y + rows[o + 6] * z + rows[o + 7],
  rows[o + 8] * x + rows[o + 9] * y + rows[o + 10] * z + rows[o + 11],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NullGpuDevice device;
  late Renderer3D renderer;
  late GpuModel bar;
  late RenderView view;

  setUp(() async {
    device = NullGpuDevice(shaders: rendererNullShaders);
    renderer = await Renderer3D.create(device);
    bar = await renderer.uploader.upload(await loadModelData(skinnedBarGlb(), name: 'bar'));
    view = RenderView()
      ..width = 320
      ..height = 180;
    view.lookAt(Vector3(0, -1, -6), Vector3(0, -1, 0));
    view.projection.setPerspectiveYDown(math.pi / 3, 16 / 9, 0.1, 100);
  });

  test('at rest every joint matrix is the identity', () {
    final posed = PosedModel(bar);
    final rows = posed.palettes.single.rows;
    expect(rows, hasLength(2 * kPaletteFloats));
    for (var j = 0; j < 2; j++) {
      expect(_apply(rows, j * 12, 0.3, 1.7, -0.2), [closeTo(0.3, 1e-6), closeTo(1.7, 1e-6), closeTo(-0.2, 1e-6)]);
    }
  });

  test('bending the tip moves the top of the bar round the joint', () {
    final posed = PosedModel(bar);
    AnimationClip(bar.data.animations.firstWhere((a) => a.name == 'bend')).sample(1, posed.pose);
    posed.update();
    final rows = posed.palettes.single.rows;
    // The top (0, 2, 0) follows tip, which turned 90° about +Z at (0, 1, 0).
    final top = _apply(rows, 12, 0, 2, 0);
    expect(top, [closeTo(-1, 1e-5), closeTo(1, 1e-5), closeTo(0, 1e-5)]);
    // The foot follows root, which did not move.
    expect(_apply(rows, 0, 0, 0, 0), [closeTo(0, 1e-6), closeTo(0, 1e-6), closeTo(0, 1e-6)]);
    // The skin's bounds reach the bent top.
    final bounds = posed.skinBounds.single;
    expect(bounds.min.x, lessThanOrEqualTo(-1 + 1e-5));
  });

  test('a posed model in a scene: skinned instances carry its palette', () async {
    final scene = RenderScene();
    final posed = PosedModel(bar);
    final instances = scene.addModel(bar, Matrix4.translationValues(2, 0, 0), posed: posed);
    expect(instances, hasLength(1));
    final instance = instances.single;
    expect(instance.skin, same(posed.palettes.single));
    expect(instance.localBounds, same(posed.skinBounds.single));
    // Placed at the root (glTF axes turned to the engine's): the bar rises
    // towards -Y. The bounds are each joint grown by its reach, so they hold
    // the bar with room to spare.
    final b = instance.bounds;
    expect(b.min.y, lessThanOrEqualTo(-2));
    expect(b.max.y, greaterThanOrEqualTo(0));
    expect(b.min.x, lessThanOrEqualTo(1.9));
    expect(b.max.x, greaterThanOrEqualTo(2.1));
    expect(b.max.x - b.min.x, lessThan(3), reason: 'but not unboundedly');

    await renderer.render(scene, view, device.createSurface(320, 180));
    expect(renderer.stats.skinnedInstances, 1);
    expect(renderer.stats.joints, greaterThanOrEqualTo(2));
    expect(device.log, contains('setPipeline LitSkinnedVertex+LitFragment'));
    expect(device.log, contains('texture joint_texture (vertex)'));
    expect(device.log.where((l) => l.startsWith('texture GpuTextureDesc(768x1 rgba32f')), isNotEmpty);
  });

  test('characters sharing a mesh and material are one draw, each with its palette', () async {
    final scene = RenderScene();
    final poses = <PosedModel>[];
    for (var i = 0; i < 6; i++) {
      final posed = PosedModel(bar);
      poses.add(posed);
      scene.addModel(bar, Matrix4.translationValues(i - 2.5, 0, 0), posed: posed);
    }
    renderer.shadows.enabled = false;
    device.log.clear();
    await renderer.render(scene, view, device.createSurface(320, 180));
    expect(renderer.stats.skinnedInstances, 6);
    expect(device.log.where((l) => l.startsWith('drawIndexed')).toList(), ['drawIndexed ${bar.meshes[0][0].indexCount} x6']);
    // Six palettes, back to back in the texture.
    expect([for (final p in poses) p.palettes.single.texel], [0, 6, 12, 18, 24, 30]);
  });

  test('without float textures: palettes go in uniforms, one draw each', () async {
    renderer.skinning = SkinningMode.uniforms;
    renderer.shadows.enabled = false;
    final scene = RenderScene();
    for (var i = 0; i < 3; i++) {
      scene.addModel(bar, Matrix4.translationValues(i.toDouble(), 0, 0), posed: PosedModel(bar));
    }
    device.log.clear();
    await renderer.render(scene, view, device.createSurface(320, 180));
    expect(device.log, contains('setPipeline LitSkinnedUniformVertex+LitFragment'));
    expect(device.log.where((l) => l.startsWith('uniforms Skin')), hasLength(3));
    expect(device.log.where((l) => l.startsWith('drawIndexed')), hasLength(3));
  });

  test('skinned meshes cast shadows through their own pipeline', () async {
    renderer.shadows.cascades = 1;
    final scene = RenderScene()..addModel(bar, Matrix4.identity(), posed: PosedModel(bar));
    device.log.clear();
    await renderer.render(scene, view, device.createSurface(320, 180));
    expect(device.log, contains('setPipeline ShadowSkinnedVertex+ShadowFragment'));
    expect(renderer.stats.shadowCasters, 1);
    expect(renderer.stats.shadowDrawCalls, 1);
  });

  test('a model without a pose shows its skins in the bind pose, unskinned', () async {
    final scene = RenderScene()..addModel(bar, Matrix4.identity());
    await renderer.render(scene, view, device.createSurface(320, 180));
    expect(scene.instances.single.skin, isNull);
    expect(renderer.stats.skinnedInstances, 0);
    expect(renderer.stats.instances, 1);
  });

  test('20 characters of 65 joints: CPU time per frame', () async {
    final chain = await renderer.uploader.upload(await loadModelData(jointChainGlb(65), name: 'chain'));
    final clip = chain.clips['wave']!;
    final scene = RenderScene();
    final characters = [
      for (var i = 0; i < 20; i++)
        PosedModel(chain)..also((p) => scene.addModel(chain, Matrix4.translationValues((i % 5) - 2.0, 0, (i ~/ 5) * 1.0), posed: p)),
    ];
    final surface = device.createSurface(1280, 720);
    final roots = [for (var i = 0; i < 20; i++) Matrix4.translationValues((i % 5) - 2.0, 0, (i ~/ 5) * 1.0)..multiply(gltfToEngine)];
    void frame(double t) {
      for (var i = 0; i < characters.length; i++) {
        final c = characters[i];
        clip.sample((t + i * 0.05) % 1, c.pose);
        c
          ..update()
          ..place(roots[i]);
      }
    }

    for (var i = 0; i < 5; i++) {
      frame(i / 60);
      await renderer.render(scene, view, surface);
    }
    const frames = 30;
    final watch = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      frame(i / 60);
      await renderer.render(scene, view, surface);
    }
    watch.stop();
    final ms = watch.elapsedMicroseconds / frames / 1000;
    // ignore: avoid_print
    print('PERF skinned 20x65: ${ms.toStringAsFixed(3)} ms/frame (${renderer.stats})');
    expect(renderer.stats.joints, 20 * 65, reason: 'each palette uploaded once, for both passes');
    expect(renderer.stats.drawCalls - renderer.stats.shadowDrawCalls, lessThanOrEqualTo(3), reason: 'one skinned draw, the sky, the tonemap');
    expect(ms, lessThan(100), reason: 'generous ceiling; the number is printed');
  });
}

extension<T> on T {
  T also(void Function(T it) f) {
    f(this);
    return this;
  }
}

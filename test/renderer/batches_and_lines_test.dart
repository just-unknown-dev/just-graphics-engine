// What the editor's 3-D views need from the renderer, on the null device:
// many copies drawn in one call and culled as one, lines over the scene
// (a primitive's edges, kept when asked), and a wireframe that draws no
// faces at all.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';

/// A one-metre square on the ground (engine axes: +Y down), two triangles.
PrimitiveData _square() {
  final v = Float32List(4 * kVertexFloats);
  const corners = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)];
  for (var i = 0; i < 4; i++) {
    final o = i * kVertexFloats;
    v[o + VertexOffsets.position ~/ 4] = corners[i].$1;
    v[o + VertexOffsets.position ~/ 4 + 2] = corners[i].$2;
    v[o + VertexOffsets.normal ~/ 4 + 1] = -1;
    v[o + VertexOffsets.color ~/ 4] = 1;
    v[o + VertexOffsets.color ~/ 4 + 1] = 1;
    v[o + VertexOffsets.color ~/ 4 + 2] = 1;
    v[o + VertexOffsets.color ~/ 4 + 3] = 1;
  }
  return PrimitiveData(
    vertices: v,
    indices: Uint32List.fromList([0, 1, 2, 0, 2, 3]),
    material: null,
    bounds: Aabb3()..setValues(-0.5, 0, -0.5, 0.5, 0, 0.5),
    hasTangents: false,
  );
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
    view.lookAt(Vector3(0, -10, -20), Vector3.zero());
    view.projection.setPerspectiveYDown(math.pi / 3, 16 / 9, 0.1, 500);
  });

  List<String> draws() =>
      device.log.where((l) => l.startsWith('drawIndexed')).toList();

  Future<void> render(RenderScene scene) async {
    device.log.clear();
    await renderer.render(scene, view, device.createSurface(640, 360));
  }

  group('edges', () {
    test('each edge of the triangles once', () {
      expect(GpuPrimitive.edgesOf([0, 1, 2, 0, 2, 3]), hasLength(10), reason: 'a square: four sides and a diagonal');
      expect(GpuPrimitive.edgesOf([0, 1, 2]), [0, 1, 1, 2, 0, 2]);
    });

    test('kept only when the uploader is asked', () {
      expect(renderer.uploader.uploadPrimitive(_square()).edges, isNull);
      renderer.uploader.keepEdges = true;
      final kept = renderer.uploader.uploadPrimitive(_square());
      expect(kept.edges, isNotNull);
      expect(kept.edgeIndexCount, 10);
    });
  });

  group('instance batches', () {
    late GpuPrimitive square;
    late GpuMaterial material;

    setUp(() {
      renderer.shadows.enabled = false;
      square = renderer.uploader.uploadPrimitive(_square());
      material = renderer.uploader.material(MaterialData.fallback);
    });

    InstanceBatch grid(int n, {double spacing = 1}) {
      final batch = InstanceBatch(square, material)
        ..setInstances([
          for (var i = 0; i < n; i++)
            Matrix4.translationValues((i % 10) * spacing, 0, (i ~/ 10) * spacing),
        ]);
      return batch;
    }

    test('a hundred copies are one draw', () async {
      final scene = RenderScene()..batches.add(grid(100));
      await render(scene);
      expect(draws(), ['drawIndexed 6 x100']);
      expect(renderer.stats.batches, 1);
      expect(renderer.stats.instances, 100);
      expect(renderer.stats.triangles, 200);
    });

    test('its bounds hold every copy', () {
      final b = grid(100, spacing: 2).bounds;
      expect([b.min.x, b.max.x, b.min.z, b.max.z], [-0.5, 18.5, -0.5, 18.5]);
    });

    test('culled as one: out of view, or beyond its reach', () async {
      final behind = grid(10)..setInstances([Matrix4.translationValues(0, 0, -100)]);
      final far = grid(10)..maxDistance = 5;
      final scene = RenderScene()..batches.addAll([behind, far]);
      await render(scene);
      expect(draws(), isEmpty);
      expect(renderer.stats.culled, 11);
      far.maxDistance = double.infinity;
      await render(scene);
      expect(draws(), ['drawIndexed 6 x10']);
    });

    test('uploaded once, and again only when the copies change', () async {
      final batch = grid(50);
      final scene = RenderScene()..batches.add(batch);
      final instanceBytes = 50 * kBatchInstanceFloats * 4;
      int uploads() => device.log.where((l) => l == 'buffer $instanceBytes').length;
      await render(scene);
      expect(uploads(), 1);
      await render(scene);
      expect(uploads(), 0, reason: 'kept on the GPU');
      batch.setInstances(List.generate(50, (i) => Matrix4.translationValues(i.toDouble(), 0, 0)));
      await render(scene);
      expect(uploads(), 1);
    });

    test('a batch casts shadows in one call too', () async {
      renderer.shadows.enabled = true;
      final scene = RenderScene()..batches.add(grid(20));
      await render(scene);
      expect(renderer.stats.shadowDrawCalls, greaterThanOrEqualTo(1));
      expect(renderer.stats.shadowCasters, greaterThanOrEqualTo(20));
      final scene2 = RenderScene()..batches.add(grid(20)..castShadows = false);
      await render(scene2);
      expect(renderer.stats.shadowDrawCalls, 0);
    });
  });

  group('lines', () {
    late GpuPrimitive square;

    setUp(() {
      renderer
        ..shadows.enabled = false
        ..uploader.keepEdges = true;
      square = renderer.uploader.uploadPrimitive(_square());
    });

    test('an overlay draws the edges as lines, over the scene', () async {
      final scene = RenderScene()
        ..instances.add(MeshInstance(square, renderer.uploader.material(MaterialData.fallback), Matrix4.identity()))
        ..overlays.add(OverlayDraw(square, Matrix4.identity()));
      await render(scene);
      expect(device.log, contains('setPipeline WireVertex+ColorFragment'));
      expect(device.log, contains('topology lines'));
      expect(draws(), ['drawIndexed 6 x1', 'drawIndexed 10 x1'], reason: 'the face, then its edges');
      // Lines last, and the next pass starts from triangles.
      expect(device.log.lastIndexOf('topology triangles'), greaterThan(device.log.lastIndexOf('topology lines')));
    });

    test('a primitive without edges draws no lines', () async {
      renderer.uploader.keepEdges = false;
      final bare = renderer.uploader.uploadPrimitive(_square());
      final scene = RenderScene()..overlays.add(OverlayDraw(bare, Matrix4.identity()));
      await render(scene);
      expect(device.log, isNot(contains('topology lines')));
    });

    test('a wireframe draws every edge and no face', () async {
      renderer.viewMode = RenderViewMode.wireframe;
      final material = renderer.uploader.material(MaterialData.fallback);
      final scene = RenderScene()
        ..instances.add(MeshInstance(square, material, Matrix4.identity()))
        ..batches.add(InstanceBatch(square, material)..setInstances([Matrix4.identity(), Matrix4.translationValues(2, 0, 0)]));
      await render(scene);
      expect(draws(), ['drawIndexed 10 x1', 'drawIndexed 10 x2']);
      expect(device.log, isNot(contains('setPipeline LitVertex+LitFragment')));
    });
  });

  test('layered and world-UV materials draw like any other', () async {
    renderer.shadows.enabled = false;
    final square = renderer.uploader.uploadPrimitive(_square());
    final scene = RenderScene()
      ..instances.addAll([
        MeshInstance(
          square,
          renderer.uploader.material(const MaterialData(layered: true, layerTiling: (1, 2, 3, 4))),
          Matrix4.identity(),
        ),
        MeshInstance(
          square,
          renderer.uploader.material(const MaterialData(uvMode: UvMode.world)),
          Matrix4.translationValues(2, 0, 0),
        ),
      ]);
    renderer
      ..viewMode = RenderViewMode.unlit
      ..clipPlane = (0, -1, 0, 2);
    await render(scene);
    expect(draws(), hasLength(2));
    expect(device.log.where((l) => l.startsWith('uniforms Material')), hasLength(2));
  });
}

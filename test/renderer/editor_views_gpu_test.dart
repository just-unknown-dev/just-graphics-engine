@Tags(['gpu'])
library;

// The editor's 3-D views on a real GPU: a slice takes away what is beyond
// it, lines over the scene show where they are drawn, a wireframe draws
// edges and no faces, and the unlit view still draws the colours.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';
import 'package:just_graphics_engine/testing.dart';

const _size = 96;

/// A box (glTF axes) of [x] × [y] × [z] metres, its bottom at 0.
GlbWriter _box(double x, double y, double z, {List<double> rgba = const [0.2, 0.7, 0.2, 1]}) {
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
        positions.add((n[c] + su * u[c] + sv * v[c]) * half[c] + (c == 1 ? half[1] : 0));
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

void main() {
  final skip = gpuUnavailableReason();
  late GpuDevice device;
  late Renderer3D renderer;
  late GpuModel box;

  setUpAll(() async {
    if (skip != null) return;
    device = createGpuDevice()!;
    renderer = await Renderer3D.create(device);
    renderer.uploader.keepEdges = true;
    box = await renderer.uploader.upload(await loadModelData(_box(1, 2, 1).toGlb(), name: 'box'));
  });

  setUp(() {
    if (skip != null) return;
    renderer
      ..viewMode = RenderViewMode.lit
      ..clipPlane = null
      ..shadows.enabled = false;
  });

  RenderView camera() {
    final view = RenderView()
      ..width = _size
      ..height = _size;
    // Level with the box's middle (1 m up: y = -1), 5 m in front.
    view.lookAt(Vector3(0, -1, -5), Vector3(0, -1, 0));
    view.projection.setPerspectiveYDown(math.pi / 3, 1, 0.1, 100);
    return view;
  }

  (int, int) pixelOf(RenderView view, Vector3 p) {
    final vp = Matrix4.identity()..setProduct(view.projection, view.view);
    final c = Vector3.zero();
    vp.transformPointInto(p, c);
    return (((c.x + 1) / 2 * _size).floor(), ((c.y + 1) / 2 * _size).floor());
  }

  Future<RgbaPixels> draw(RenderScene scene) async {
    final surface = device.createSurface(_size, _size);
    expect(await renderer.render(scene, camera(), surface), isTrue);
    return readPixels(surface.image!);
  }

  bool same(List<int> a, List<int> b) =>
      (a[0] - b[0]).abs() < 6 && (a[1] - b[1]).abs() < 6 && (a[2] - b[2]).abs() < 6;

  RenderScene withBox() => RenderScene()..addModel(box, Matrix4.identity());

  test('a slice takes away what is beyond it, and leaves the rest', () async {
    final view = camera();
    final empty = await draw(RenderScene());
    final upper = pixelOf(view, Vector3(0, -1.6, -0.5));
    final lower = pixelOf(view, Vector3(0, -0.4, -0.5));
    final whole = await draw(withBox());
    expect(same(whole.at(upper.$1, upper.$2), empty.at(upper.$1, upper.$2)), isFalse, reason: 'the box is there');
    // Up is -Y: keep what is below 1 m — nothing where dot(p, (0,-1,0)) > 1.
    renderer.clipPlane = (0, -1, 0, 1);
    final sliced = await draw(withBox());
    expect(same(sliced.at(upper.$1, upper.$2), empty.at(upper.$1, upper.$2)), isTrue, reason: 'cut away above');
    expect(same(sliced.at(lower.$1, lower.$2), whole.at(lower.$1, lower.$2)), isTrue, reason: 'kept below');
  }, skip: skip);

  test('lines over the scene show in their colour', () async {
    final scene = withBox();
    for (final instance in scene.instances) {
      scene.overlays.add(OverlayDraw(instance.primitive, instance.world, color: (1, 0, 0, 1), xray: true));
    }
    final px = await draw(scene);
    var red = 0;
    for (var y = 0; y < _size; y++) {
      for (var x = 0; x < _size; x++) {
        final p = px.at(x, y);
        if (p[0] > 200 && p[1] < 60 && p[2] < 60) red++;
      }
    }
    expect(red, greaterThan(20), reason: 'the box\'s edges, in red');
  }, skip: skip);

  test('a wireframe draws edges and no faces', () async {
    renderer.viewMode = RenderViewMode.wireframe;
    final view = camera();
    final empty = await draw(RenderScene());
    final px = await draw(withBox());
    // The middle of the front face is empty; its outline is not.
    final middle = pixelOf(view, Vector3(0.2, -1, -0.5));
    expect(same(px.at(middle.$1, middle.$2), empty.at(middle.$1, middle.$2)), isTrue, reason: 'no face');
    var changed = 0;
    for (var y = 0; y < _size; y++) {
      for (var x = 0; x < _size; x++) {
        if (!same(px.at(x, y), empty.at(x, y))) changed++;
      }
    }
    expect(changed, greaterThan(20), reason: 'its edges');
  }, skip: skip);

  test('the unlit view still draws the box\'s colours', () async {
    renderer.viewMode = RenderViewMode.unlit;
    final view = camera();
    final px = await draw(withBox());
    final front = pixelOf(view, Vector3(0, -1, -0.5));
    final p = px.at(front.$1, front.$2);
    expect(p[1], greaterThan(p[0]), reason: 'green, unlit');
    expect(p[1], greaterThan(p[2]));
  }, skip: skip);
}

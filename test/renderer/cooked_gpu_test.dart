@Tags(['gpu'])
library;

// A cooked model draws as its source does: same geometry, its textures
// uploaded from the cooked levels instead of decoded.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/renderer.dart';
import 'package:just_graphics_engine/testing.dart';

const _size = 48;

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 32, 32), ui.Paint()..color = const ui.Color(0xFFE04020));
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 16, 32), ui.Paint()..color = const ui.Color(0xFF20A0E0));
  final image = await recorder.endRecording().toImage(32, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Uint8List _quad(Uint8List png) {
  final w = GlbWriter();
  final texture = w.addTexture(w.addImage(png));
  final mesh = w.addMesh([
    {
      'attributes': {
        'POSITION': w.addFloats([-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0], 'VEC3', withBounds: true),
        'TEXCOORD_0': w.addFloats([0, 1, 1, 1, 1, 0, 0, 0], 'VEC2'),
      },
      'indices': w.addInts([0, 1, 2, 0, 2, 3], 'SCALAR', 5123, indices: true),
      'material': w.addMaterial({
        'pbrMetallicRoughness': {'baseColorTexture': {'index': texture}},
        'extensions': {'KHR_materials_unlit': <String, dynamic>{}},
        'doubleSided': true,
      }),
    },
  ]);
  w.setScene([w.addNode({'mesh': mesh})]);
  return w.toGlb();
}

void main() {
  final skip = gpuUnavailableReason();

  test('a cooked model draws as its source does', () async {
    final device = createGpuDevice()!;
    final renderer = await Renderer3D.create(device);
    renderer.shadows.enabled = false;
    final source = _quad(await _png());

    Future<RgbaPixels> draw(ModelData data) async {
      final model = await renderer.uploader.upload(data);
      final scene = RenderScene()..addModel(model, Matrix4.translationValues(0, 0, 3), correctAxes: false);
      final view = RenderView()
        ..width = _size
        ..height = _size;
      view.lookAt(Vector3.zero(), Vector3(0, 0, 1));
      view.projection.setPerspectiveYDown(math.pi / 3, 1, 0.1, 100);
      final surface = device.createSurface(_size, _size);
      expect(await renderer.render(scene, view, surface), isTrue);
      return readPixels(surface.image!);
    }

    final plain = await draw(await loadModelData(source, name: 'quad'));
    final cooked = await draw(CookedModel.read((await cookModel(source, name: 'quad')).bytes));
    for (final (x, y) in [(0.3, 0.5), (0.7, 0.5), (0.5, 0.2)]) {
      final a = plain.atFraction(x, y), b = cooked.atFraction(x, y);
      for (var c = 0; c < 3; c++) {
        expect((a[c] - b[c]).abs(), lessThanOrEqualTo(3), reason: '($x, $y) channel $c: $a vs $b');
      }
    }
    // The two halves differ: the texture is there, not a flat colour.
    expect(plain.atFraction(0.3, 0.5), isNot(plain.atFraction(0.7, 0.5)));
  }, skip: skip);
}

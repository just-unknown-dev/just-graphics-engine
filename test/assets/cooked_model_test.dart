// Import settings and cooked models: settings saved and read back, lengths
// scaled through every part of a model, materials changed by name, the
// cooked format reading back what was written, and cooking a textured
// model into ready mip levels.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/testing.dart';

Future<Uint8List> _png(int w, int h, ui.Color colour) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = colour,
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A textured quad: a base colour map of [png] and a normal map of it too.
Uint8List _texturedQuad(Uint8List png) {
  final w = GlbWriter();
  final image = w.addImage(png);
  final texture = w.addTexture(image);
  final mesh = w.addMesh([
    {
      'attributes': {
        'POSITION': w.addFloats([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0], 'VEC3', withBounds: true),
        'TEXCOORD_0': w.addFloats([0, 0, 1, 0, 1, 1, 0, 1], 'VEC2'),
      },
      'indices': w.addInts([0, 1, 2, 0, 2, 3], 'SCALAR', 5123, indices: true),
      'material': w.addMaterial({
        'name': 'paint',
        'pbrMetallicRoughness': {'baseColorTexture': {'index': texture}},
        'normalTexture': {'index': texture},
      }),
    },
  ]);
  w.setScene([w.addNode({'mesh': mesh, 'translation': [0, 2, 0]})]);
  return w.toGlb();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('import settings', () {
    test('are saved and read back, and a newer format is refused', () {
      const settings = ModelImportSettings(
        scale: 0.01,
        maxTextureSize: 512,
        mipmaps: false,
        textureCompression: TextureCompression.etc2,
        materials: {'paint': MaterialOverride(baseColor: (1, 0, 0, 1), roughness: 0.2)},
      );
      final back = ModelImportSettings.fromJson(settings.toJson());
      expect(back.scale, 0.01);
      expect(back.maxTextureSize, 512);
      expect(back.mipmaps, isFalse);
      expect(back.textureCompression, TextureCompression.etc2);
      expect(back.materials['paint']!.baseColor, (1.0, 0.0, 0.0, 1.0));
      expect(back.materials['paint']!.metallic, isNull);
      expect(const ModelImportSettings().isDefault, isTrue);
      expect(ModelImportSettings.sidecarOf('assets/a.glb'), 'assets/a.glb.import.json');
      expect(ModelImportSettings.cookedOf('assets/a.glb'), 'assets/a.glb.jmodel');
      expect(
        () => ModelImportSettings.fromJson({'formatVersion': ModelImportSettings.formatVersion + 1}),
        throwsFormatException,
      );
    });

    test('scale reaches vertices, nodes, joints, animations and bounds', () async {
      final data = await loadModelData(mannequinGlb(), name: 'm');
      final half = ModelImportSettings.scaled(data, 0.5);
      expect(half.bounds.max.y, closeTo(data.bounds.max.y * 0.5, 1e-5));
      final v0 = data.meshes.first.primitives.first.vertices, v1 = half.meshes.first.primitives.first.vertices;
      expect(v1[1], closeTo(v0[1] * 0.5, 1e-6));
      expect(v1[3], v0[3], reason: 'normals untouched');
      final joint = data.nodes.indexWhere((n) => n.name == 'spine');
      expect(half.nodes[joint].translation!.y, closeTo(data.nodes[joint].translation!.y * 0.5, 1e-6));
      expect(half.nodes[joint].local.storage[13], closeTo(data.nodes[joint].local.storage[13] * 0.5, 1e-6));
      expect(half.skins.first.inverseBindMatrices[13], closeTo(data.skins.first.inverseBindMatrices[13] * 0.5, 1e-6));
      final walk = data.animations.firstWhere((a) => a.name == 'walk');
      final walkHalf = half.animations.firstWhere((a) => a.name == 'walk');
      for (final c in walk.channels.where((c) => c.path == AnimationPath.translation)) {
        expect(walkHalf.samplers[c.sampler].output.first, closeTo(walk.samplers[c.sampler].output.first * 0.5, 1e-6));
      }
      for (final c in walk.channels.where((c) => c.path == AnimationPath.rotation)) {
        expect(identical(walkHalf.samplers[c.sampler], walk.samplers[c.sampler]), isTrue);
      }
    });
  });

  group('the cooked format', () {
    test('reads back what was written', () async {
      final data = await loadModelData(mannequinGlb(), name: 'm');
      final bytes = CookedModel.write(data, stamp: 'abc');
      expect(CookedModel.isCooked(bytes), isTrue);
      expect(CookedModel.stampOf(bytes), 'abc');
      // Not at a 4-byte boundary: views are copied, not misread.
      final shifted = Uint8List(bytes.length + 1)..setAll(1, bytes);
      for (final input in [bytes, Uint8List.sublistView(shifted, 1)]) {
        final back = CookedModel.read(input, name: 'm');
        expect(back.meshes.length, data.meshes.length);
        expect(back.meshes.first.primitives.first.vertices, data.meshes.first.primitives.first.vertices);
        expect(back.meshes.first.primitives.first.indices, data.meshes.first.primitives.first.indices);
        expect(back.meshes.first.primitives.first.skin, data.meshes.first.primitives.first.skin);
        expect(back.nodes.map((n) => n.name), data.nodes.map((n) => n.name));
        expect(back.nodes[3].local.storage, data.nodes[3].local.storage);
        expect(back.skins.first.joints, data.skins.first.joints);
        expect(back.animations.map((a) => a.name), data.animations.map((a) => a.name));
        expect(back.animations.first.samplers.first.output, data.animations.first.samplers.first.output);
        expect(back.materials.first.baseColor, data.materials.first.baseColor);
        expect(back.bounds.max.y, data.bounds.max.y);
      }
    });

    test('a file of a newer format is refused', () {
      final bytes = CookedModel.write(ModelData(
        name: 'x',
        meshes: const [],
        materials: const [],
        textures: const [],
        images: const [],
        nodes: const [],
        roots: const [],
        lights: const [],
        bounds: Aabb3(),
      ));
      ByteData.sublistView(bytes).setUint32(4, CookedModel.version + 1, Endian.little);
      expect(() => CookedModel.read(bytes), throwsFormatException);
      expect(() => CookedModel.read(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])), throwsFormatException);
    });
  });

  test('cooking decodes, shrinks and mips textures, and changes materials', () async {
    final png = await _png(64, 32, const ui.Color(0xFF3366CC));
    final source = _texturedQuad(png);
    const settings = ModelImportSettings(
      maxTextureSize: 16,
      materials: {'paint': MaterialOverride(roughness: 0.25)},
    );
    final result = await cookModel(source, name: 'quad.glb', settings: settings);
    expect(result.warnings.join(), contains('shrunk from 64×32 to 16×8'));
    expect(result.stamp, cookStamp(source, settings));
    expect(cookStamp(source, const ModelImportSettings()), isNot(result.stamp));

    final back = CookedModel.read(result.bytes);
    expect(CookedModel.stampOf(result.bytes), result.stamp);
    final levels = back.images.single.levels!;
    expect([for (final l in levels) (l.width, l.height)], [(16, 8), (8, 4), (4, 2), (2, 1), (1, 1)]);
    expect(back.images.single.levelsSrgb, isTrue, reason: 'used as a colour map first');
    expect(back.images.single.bytes, isEmpty);
    expect(result.textureBytes, levels.fold<int>(0, (n, l) => n + l.pixels.length));
    // Blue-ish all the way down.
    final p = levels.last.pixels;
    expect(p[2], greaterThan(p[0]));
    expect(back.materials.single.roughness, 0.25);
    expect(result.warnings.join(), contains('both a colour and a data map'));

    final plain = await cookModel(source, name: 'quad.glb', settings: const ModelImportSettings(mipmaps: false));
    expect(CookedModel.read(plain.bytes).images.single.levels, hasLength(1));
  });
}

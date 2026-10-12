import 'dart:convert';
import 'dart:typed_data';

import 'cooked_model.dart';
import 'model_data.dart';
import 'model_import.dart';
import 'model_loader.dart';
import 'texture_decode.dart';

/// What [cookModel] made.
final class CookedResult {
  /// [bytes] of the cooked file, with what to tell the author.
  const CookedResult(
    this.bytes,
    this.warnings, {
    required this.textureBytes,
    required this.stamp,
  });

  /// The cooked file (`.jmodel`).
  final Uint8List bytes;

  /// Things the author should know: a feature not cooked, a texture shrunk.
  final List<String> warnings;

  /// Bytes of texture data in it, all levels.
  final int textureBytes;

  /// What it was cooked from; see [cookStamp].
  final String stamp;
}

/// A short fingerprint of [source] and [settings]: a cooked model made
/// from both carries it ([CookedModel.stampOf]), so a tool can tell when
/// it needs cooking again.
String cookStamp(Uint8List source, ModelImportSettings settings) {
  // FNV-1a, 32 bits, over the file and the settings as saved.
  var h = 0x811C9DC5;
  void eat(List<int> bytes) {
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
  }

  eat(source);
  eat(utf8.encode(jsonEncode(settings.toJson())));
  return '${source.length.toRadixString(16)}-${h.toRadixString(16).padLeft(8, '0')}';
}

/// Cooks the model file [source] (`.glb` or `.gltf`, named [name]; [fetch]
/// reads files a `.gltf` refers to) with [settings]: lengths scaled,
/// materials changed, every texture decoded, shrunk to
/// [ModelImportSettings.maxTextureSize] and given its mip levels (sRGB
/// averaged for colour maps, linear for data maps). The result loads with
/// no glTF parsing and no image decoding.
///
/// Decodes images with Flutter: run it on the main isolate.
Future<CookedResult> cookModel(
  Uint8List source, {
  required String name,
  ModelFetch? fetch,
  ModelImportSettings settings = const ModelImportSettings(),
}) async {
  final data = settings.apply(
    await loadModelData(source, name: name, fetch: fetch),
  );
  final warnings = <String>[];
  if (settings.textureCompression != TextureCompression.none) {
    warnings.add(
      '${settings.textureCompression.name.toUpperCase()} texture compression is not made yet: '
      'the textures are cooked uncompressed.',
    );
  }

  // Which images are colour (sRGB) and which hold data.
  final colour = <int>{}, plain = <int>{};
  void use(TextureRef? ref, {required bool srgb}) {
    if (ref == null || ref.texture >= data.textures.length) return;
    final image = data.textures[ref.texture].image;
    if (image == null) return;
    (srgb ? colour : plain).add(image);
  }

  for (final m in data.materials) {
    use(m.baseColorTexture, srgb: true);
    use(m.emissiveTexture, srgb: true);
    use(m.metallicRoughnessTexture, srgb: false);
    use(m.normalTexture, srgb: false);
    use(m.occlusionTexture, srgb: false);
  }

  var textureBytes = 0;
  final images = <ImageData>[];
  for (var i = 0; i < data.images.length; i++) {
    final image = data.images[i];
    if (image.bytes.isEmpty || (!colour.contains(i) && !plain.contains(i))) {
      // Unused, or nothing to decode: kept as it is (unused: dropped).
      images.add(ImageData(Uint8List(0), image.mimeType, image.name));
      continue;
    }
    final srgb = colour.contains(i);
    if (srgb && plain.contains(i)) {
      warnings.add(
        'Image ${image.name ?? i} is both a colour and a data map; its levels are averaged as colour.',
      );
    }
    RgbaImage top;
    try {
      top = await decodeImage(image.bytes);
    } on Object catch (error) {
      warnings.add(
        'Image ${image.name ?? i} could not be decoded ($error); it is left out.',
      );
      images.add(ImageData(Uint8List(0), image.mimeType, image.name));
      continue;
    }
    final limit = settings.maxTextureSize;
    if (limit > 0 && (top.width > limit || top.height > limit)) {
      final was = '${top.width}×${top.height}';
      while (top.width > limit || top.height > limit) {
        top = halve(top, srgb: srgb);
      }
      warnings.add(
        'Image ${image.name ?? i} shrunk from $was to ${top.width}×${top.height}.',
      );
    }
    final levels = settings.mipmaps ? await buildMips(top, srgb: srgb) : [top];
    for (final l in levels) {
      textureBytes += l.pixels.length;
    }
    images.add(
      ImageData(
        Uint8List(0),
        image.mimeType,
        image.name,
        levels: levels,
        levelsSrgb: srgb,
      ),
    );
  }

  final stamp = cookStamp(source, settings);
  final cooked = ModelData(
    name: data.name,
    meshes: data.meshes,
    materials: data.materials,
    textures: data.textures,
    images: images,
    nodes: data.nodes,
    roots: data.roots,
    lights: data.lights,
    bounds: data.bounds,
    skins: data.skins,
    animations: data.animations,
    warnings: [...data.warnings, ...warnings],
  );
  return CookedResult(
    CookedModel.write(cooked, stamp: stamp),
    [...data.warnings, ...warnings],
    textureBytes: textureBytes,
    stamp: stamp,
  );
}

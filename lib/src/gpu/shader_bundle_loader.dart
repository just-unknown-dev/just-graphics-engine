import 'package:flutter_gpu/gpu.dart' as gpu;

/// Where `hook/build.dart` writes compiled shader bundles, relative to the
/// package root.
const String kShaderBundleDir = 'build/shaderbundles';

final Map<String, Future<gpu.ShaderLibrary>> _libraries = {};

/// Loads this package's shader bundle [fileName] (for example
/// `gltf.shaderbundle`) once and caches it.
///
/// An app that depends on this package sees the bundle under
/// `packages/just_graphics_engine/…`; the package's own tests and tools run
/// it as the root app, where the same asset has no `packages/` prefix. Both
/// keys are tried, the dependency key first.
Future<gpu.ShaderLibrary> loadShaderBundle(String fileName) {
  return _libraries[fileName] ??= _load(fileName).catchError((Object e) {
    _libraries.remove(fileName);
    throw e;
  });
}

Future<gpu.ShaderLibrary> _load(String fileName) async {
  final keys = [
    'packages/just_graphics_engine/$kShaderBundleDir/$fileName',
    '$kShaderBundleDir/$fileName',
  ];
  final failures = <String>[];
  for (final key in keys) {
    try {
      final library = await gpu.ShaderLibrary.fromAsset(key);
      if (library != null) return library;
      failures.add('$key: no library');
    } on Exception catch (e) {
      failures.add('$key: $e');
    }
  }
  throw StateError(
    'Could not load the shader bundle "$fileName". Tried:\n'
    '${failures.map((f) => '  $f').join('\n')}',
  );
}

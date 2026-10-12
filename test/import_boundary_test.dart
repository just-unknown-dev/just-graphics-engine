// Where Flutter GPU may be imported, and what this package may depend on.
// The web has no Flutter GPU, so every public library except testing.dart
// must compile without it: only the flutter_gpu backend imports it, reached
// through create_device.dart's `if (dart.library.ffi)` branch. And the
// package stands alone: it never imports a game engine (just_game_engine
// imports it).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `import`/`export` directives: the default URI, then any conditional ones.
final _directive = RegExp(
  r"""^\s*(?:import|export)\s+'([^']+)'((?:\s+if\s*\([^)]*\)\s*'[^']+')*)""",
  multiLine: true,
);

/// Every file of this package [entry] reaches when only default URIs are
/// followed (what a web build compiles), with the URIs each one imports.
Map<String, List<String>> _reach(String entry) {
  final seen = <String, List<String>>{};
  final queue = [File(entry).absolute.uri];
  final lib = Directory('lib').absolute.uri;
  while (queue.isNotEmpty) {
    final uri = queue.removeLast();
    final path = uri.toFilePath();
    if (seen.containsKey(path)) continue;
    final source = File(path).readAsStringSync();
    final uris = [for (final m in _directive.allMatches(source)) m.group(1)!];
    seen[path] = uris;
    for (final u in uris) {
      if (u.startsWith('package:just_graphics_engine/')) {
        queue.add(
          lib.resolve(u.substring('package:just_graphics_engine/'.length)),
        );
      } else if (!u.contains(':')) {
        queue.add(uri.resolve(u));
      }
    }
  }
  return seen;
}

/// Every Dart file under lib/.
Iterable<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  for (final library in ['just_graphics_engine', 'gpu', 'assets', 'renderer']) {
    test('$library.dart compiles without Flutter GPU (the web branch)', () {
      final reached = _reach('lib/$library.dart');
      final offenders = [
        for (final MapEntry(:key, :value) in reached.entries)
          if (value.any((u) => u.startsWith('package:flutter_gpu'))) key,
      ];
      expect(offenders, isEmpty);
      expect(reached.length, greaterThan(1));
    });
  }

  test('the walk takes the web branch of a conditional export', () {
    final reached = _reach(
      'lib/just_graphics_engine.dart',
    ).keys.map((p) => p.replaceAll(r'\', '/'));
    expect(reached, contains(endsWith('lib/src/gpu/create_device_stub.dart')));
    expect(reached, isNot(contains(endsWith('flutter_gpu_device.dart'))));
    expect(reached, contains(endsWith('lib/src/widgets/scene_3d_view.dart')));
  });

  test('only the flutter_gpu backend and the test helpers import it', () {
    final importers = [
      for (final f in _libFiles())
        if (_directive
            .allMatches(f.readAsStringSync())
            .any((m) => m.group(1)!.startsWith('package:flutter_gpu')))
          f.path.replaceAll(r'\', '/'),
    ]..sort();
    expect(importers, [
      'lib/src/gpu/backend_flutter_gpu/flutter_gpu_device.dart',
      'lib/src/gpu/shader_bundle_loader.dart',
      'lib/src/testing/gpu_test_harness.dart',
    ]);
  });

  test('the glTF reader and the other assets need no renderer', () {
    for (final f in Directory(
      'lib/src/assets',
    ).listSync(recursive: true).whereType<File>()) {
      for (final m in _directive.allMatches(f.readAsStringSync())) {
        final u = m.group(1)!;
        expect(
          u.contains('/gpu/') ||
              u.contains('/renderer/') ||
              u.startsWith('package:flutter_gpu'),
          isFalse,
          reason: '${f.path} imports $u',
        );
      }
    }
  });

  test('the package never imports a game engine', () {
    for (final f in _libFiles()) {
      for (final m in _directive.allMatches(f.readAsStringSync())) {
        final u = m.group(1)!;
        expect(
          u.startsWith('package:just_game_engine'),
          isFalse,
          reason: '${f.path} imports $u',
        );
      }
    }
    expect(
      File('pubspec.yaml').readAsStringSync(),
      isNot(contains('just_game_engine:')),
    );
  });
}

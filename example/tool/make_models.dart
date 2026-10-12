// Writes the example's models into assets/models/: simple shapes made in
// code, so the example has no binary files nobody can regenerate.
//
//   dart run tool/make_models.dart
//
// glTF axes: +Y up, metres. Every model rests on y = 0.
import 'dart:io';
import 'dart:math' as math;

// Pure Dart, so this script runs without Flutter.
// ignore: implementation_imports
import 'package:just_graphics_engine/src/testing/glb_writer.dart';
// ignore: implementation_imports
import 'package:just_graphics_engine/src/testing/mannequin.dart';

void main() {
  Directory('assets/models').createSync(recursive: true);
  _write('ground', _box(20, 0.2, 20, lift: -0.2), {
    'baseColorFactor': [0.32, 0.42, 0.28, 1.0],
    'metallicFactor': 0.0,
    'roughnessFactor': 0.95,
  });
  _write('crate', _box(1, 1, 1), {
    'baseColorFactor': [0.72, 0.45, 0.2, 1.0],
    'metallicFactor': 0.0,
    'roughnessFactor': 0.7,
  });
  _write('ball', _sphere(0.5, 32, 16), {
    'baseColorFactor': [1.0, 0.78, 0.34, 1.0],
    'metallicFactor': 1.0,
    'roughnessFactor': 0.3,
  });
  _write('pillar', _cylinder(0.3, 2, 24), {
    'baseColorFactor': [0.85, 0.85, 0.88, 1.0],
    'metallicFactor': 0.0,
    'roughnessFactor': 0.5,
  });
  // A skinned character with `walk` and `idle` clips.
  File('assets/models/mannequin.glb').writeAsBytesSync(mannequinGlb());
  stdout.writeln('assets/models/mannequin.glb: skinned, 16 joints');
}

typedef _Mesh = ({List<double> positions, List<double> normals, List<int> indices});

void _write(String name, _Mesh mesh, Map<String, dynamic> pbr) {
  final w = GlbWriter();
  final m = w.addMesh([
    {
      'attributes': {
        'POSITION': w.addFloats(mesh.positions, 'VEC3', withBounds: true),
        'NORMAL': w.addFloats(mesh.normals, 'VEC3'),
      },
      'indices': w.addInts(mesh.indices, 'SCALAR', 5123, indices: true),
      'material': w.addMaterial({'name': name, 'pbrMetallicRoughness': pbr}),
    },
  ], name: name);
  w.setScene([w.addNode({'name': name, 'mesh': m})]);
  final file = File('assets/models/$name.glb')..writeAsBytesSync(w.toGlb());
  stdout.writeln('${file.path}: ${mesh.indices.length ~/ 3} triangles');
}

/// A box [x] by [y] by [z], its bottom at [lift].
_Mesh _box(double x, double y, double z, {double lift = 0}) {
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
        positions.add((n[c] + su * u[c] + sv * v[c]) * half[c] + (c == 1 ? half[1] + lift : 0));
        normals.add(n[c]);
      }
    }
    indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
  }
  return (positions: positions, normals: normals, indices: indices);
}

/// A sphere of [radius] resting on y = 0.
_Mesh _sphere(double radius, int segments, int rings) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  for (var r = 0; r <= rings; r++) {
    final theta = math.pi * r / rings; // 0 at the top
    for (var s = 0; s <= segments; s++) {
      final phi = 2 * math.pi * s / segments;
      final n = [math.sin(theta) * math.sin(phi), math.cos(theta), math.sin(theta) * math.cos(phi)];
      positions.addAll([n[0] * radius, n[1] * radius + radius, n[2] * radius]);
      normals.addAll(n);
    }
  }
  final row = segments + 1;
  for (var r = 0; r < rings; r++) {
    for (var s = 0; s < segments; s++) {
      final a = r * row + s, b = a + row;
      // Counter-clockwise seen from outside.
      indices.addAll([a, b, a + 1, a + 1, b, b + 1]);
    }
  }
  return (positions: positions, normals: normals, indices: indices);
}

/// A capped cylinder of [radius] and [height] standing on y = 0.
_Mesh _cylinder(double radius, double height, int segments) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  // The side: two rings sharing smooth normals.
  for (var s = 0; s <= segments; s++) {
    final phi = 2 * math.pi * s / segments;
    final nx = math.sin(phi), nz = math.cos(phi);
    positions.addAll([nx * radius, 0, nz * radius, nx * radius, height, nz * radius]);
    normals.addAll([nx, 0, nz, nx, 0, nz]);
  }
  for (var s = 0; s < segments; s++) {
    final a = s * 2;
    indices.addAll([a, a + 2, a + 1, a + 1, a + 2, a + 3]);
  }
  // The caps: a fan each.
  for (final (y, ny) in [(height, 1.0), (0.0, -1.0)]) {
    final centre = positions.length ~/ 3;
    positions.addAll([0, y, 0]);
    normals.addAll([0, ny, 0]);
    for (var s = 0; s <= segments; s++) {
      final phi = 2 * math.pi * s / segments;
      positions.addAll([math.sin(phi) * radius, y, math.cos(phi) * radius]);
      normals.addAll([0, ny, 0]);
    }
    for (var s = 0; s < segments; s++) {
      final a = centre + 1 + s;
      indices.addAll(ny > 0 ? [centre, a, a + 1] : [centre, a + 1, a]);
    }
  }
  return (positions: positions, normals: normals, indices: indices);
}

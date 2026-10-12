import 'dart:math' as math;
import 'dart:typed_data';

import 'glb_writer.dart';

/// A square bar 2 m tall standing on y = 0 (glTF axes), skinned to two
/// joints: `root` at the origin and `tip` 1 m up (child of `root`). Below
/// 0.5 m vertices follow `root`, above 1.5 m `tip`, between they blend.
///
/// Animations:
/// - `bend`: `tip` turns 90° about +Z over 1 s (LINEAR), so the top half
///   ends up pointing along -X.
/// - `hop`: `root` jumps 0.5 m up at 0.5 s and back at 1 s (STEP).
/// - `grow`: `root` scales from 1 to 2 over 1 s (CUBICSPLINE, flat
///   tangents).
Uint8List skinnedBarGlb({
  List<double> rgba = const [0.9, 0.2, 0.2, 1],
  double halfWidth = 0.1,
}) {
  final w = GlbWriter();
  final positions = <double>[],
      normals = <double>[],
      joints = <int>[],
      weights = <double>[];
  final indices = <int>[];
  const levels = [0.0, 0.5, 1.0, 1.5, 2.0];
  const corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)];
  for (final y in levels) {
    final tip = y <= 0.5 ? 0.0 : (y >= 1.5 ? 1.0 : (y - 0.5));
    for (final (cx, cz) in corners) {
      positions.addAll([cx * halfWidth, y, cz * halfWidth]);
      final n = math.sqrt(2) / 2;
      normals.addAll([cx * n, 0, cz * n]);
      joints.addAll([0, 1, 0, 0]);
      weights.addAll([1 - tip, tip, 0, 0]);
    }
  }
  for (var l = 0; l < levels.length - 1; l++) {
    for (var c = 0; c < 4; c++) {
      final a = l * 4 + c, b = l * 4 + (c + 1) % 4;
      // Counter-clockwise seen from outside.
      indices.addAll([a, b + 4, b, a, a + 4, b + 4]);
    }
  }
  // Caps.
  indices.addAll([0, 1, 2, 0, 2, 3]);
  final top = (levels.length - 1) * 4;
  indices.addAll([top, top + 2, top + 1, top, top + 3, top + 2]);

  final mesh = w.addMesh([
    {
      'attributes': {
        'POSITION': w.addFloats(positions, 'VEC3', withBounds: true),
        'NORMAL': w.addFloats(normals, 'VEC3'),
        'JOINTS_0': w.addInts(joints, 'VEC4', 5121),
        'WEIGHTS_0': w.addFloats(weights, 'VEC4'),
      },
      'indices': w.addInts(indices, 'SCALAR', 5123, indices: true),
      'material': w.addMaterial({
        'pbrMetallicRoughness': {
          'baseColorFactor': rgba,
          'metallicFactor': 0,
          'roughnessFactor': 0.6,
        },
      }),
    },
  ], name: 'Bar');
  final ibm = w.addFloats([
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, //
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -1, 0, 1,
  ], 'MAT4');
  final tip = w.addNode({
    'name': 'tip',
    'translation': [0, 1, 0],
  });
  final root = w.addNode({
    'name': 'root',
    'children': [tip],
  });
  w.addSkin({
    'joints': [root, tip],
    'inverseBindMatrices': ibm,
    'skeleton': root,
  });
  final body = w.addNode({'name': 'Bar', 'mesh': mesh, 'skin': 0});
  w.setScene([body, root]);

  final s = math.sin(math.pi / 4), c = math.cos(math.pi / 4);
  final times = w.addFloats([0, 1], 'SCALAR');
  w.addAnimation({
    'name': 'bend',
    'samplers': [
      {
        'input': times,
        'output': w.addFloats([0, 0, 0, 1, 0, 0, s, c], 'VEC4'),
        'interpolation': 'LINEAR',
      },
    ],
    'channels': [
      {
        'sampler': 0,
        'target': {'node': tip, 'path': 'rotation'},
      },
    ],
  });
  w.addAnimation({
    'name': 'hop',
    'samplers': [
      {
        'input': w.addFloats([0, 0.5, 1], 'SCALAR'),
        'output': w.addFloats([0, 0, 0, 0, 0.5, 0, 0, 0, 0], 'VEC3'),
        'interpolation': 'STEP',
      },
    ],
    'channels': [
      {
        'sampler': 0,
        'target': {'node': root, 'path': 'translation'},
      },
    ],
  });
  w.addAnimation({
    'name': 'grow',
    'samplers': [
      {
        'input': times,
        // Per key: in-tangent, value, out-tangent.
        'output': w.addFloats([
          0,
          0,
          0,
          1,
          1,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          2,
          2,
          2,
          0,
          0,
          0,
        ], 'VEC3'),
        'interpolation': 'CUBICSPLINE',
      },
    ],
    'channels': [
      {
        'sampler': 0,
        'target': {'node': root, 'path': 'scale'},
      },
    ],
  });
  return w.toGlb();
}

/// A thin bar skinned to a chain of [joints] joints, each 0.1 m above the
/// last, with a `wave` animation turning every joint a little about +Z and
/// back over 1 s — for timing many joints.
Uint8List jointChainGlb(int joints) {
  final w = GlbWriter();
  final positions = <double>[],
      normals = <double>[],
      js = <int>[],
      ws = <double>[];
  final indices = <int>[];
  for (var j = 0; j <= joints; j++) {
    final y = j * 0.1;
    for (final (cx, cz) in const [
      (-1.0, -1.0),
      (1.0, -1.0),
      (1.0, 1.0),
      (-1.0, 1.0),
    ]) {
      positions.addAll([cx * 0.05, y, cz * 0.05]);
      normals.addAll([cx * 0.7071, 0, cz * 0.7071]);
      js.addAll([math.min(j, joints - 1), 0, 0, 0]);
      ws.addAll([1, 0, 0, 0]);
    }
  }
  for (var l = 0; l < joints; l++) {
    for (var c = 0; c < 4; c++) {
      final a = l * 4 + c, b = l * 4 + (c + 1) % 4;
      indices.addAll([a, b + 4, b, a, a + 4, b + 4]);
    }
  }
  final mesh = w.addMesh([
    {
      'attributes': {
        'POSITION': w.addFloats(positions, 'VEC3', withBounds: true),
        'NORMAL': w.addFloats(normals, 'VEC3'),
        'JOINTS_0': w.addInts(js, 'VEC4', 5123),
        'WEIGHTS_0': w.addFloats(ws, 'VEC4'),
      },
      'indices': w.addInts(indices, 'SCALAR', 5123, indices: true),
    },
  ], name: 'Chain');
  // Joints are added child first so each can name its child.
  final nodes = List<int>.filled(joints, 0);
  for (var j = joints - 1; j >= 0; j--) {
    nodes[j] = w.addNode({
      'name': 'joint $j',
      'translation': [0, j == 0 ? 0 : 0.1, 0],
      if (j < joints - 1) 'children': [nodes[j + 1]],
    });
  }
  final ibm = <double>[];
  for (var j = 0; j < joints; j++) {
    ibm.addAll([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -0.1 * j, 0, 1]);
  }
  w.addSkin({'joints': nodes, 'inverseBindMatrices': w.addFloats(ibm, 'MAT4')});
  final body = w.addNode({'name': 'Chain', 'mesh': mesh, 'skin': 0});
  w.setScene([body, nodes[0]]);
  final s = math.sin(0.05), c = math.cos(0.05);
  final times = w.addFloats([0, 0.5, 1], 'SCALAR');
  final turn = w.addFloats([0, 0, 0, 1, 0, 0, s, c, 0, 0, 0, 1], 'VEC4');
  w.addAnimation({
    'name': 'wave',
    'samplers': [
      {'input': times, 'output': turn, 'interpolation': 'LINEAR'},
    ],
    'channels': [
      for (final node in nodes)
        {
          'sampler': 0,
          'target': {'node': node, 'path': 'rotation'},
        },
    ],
  });
  return w.toGlb();
}

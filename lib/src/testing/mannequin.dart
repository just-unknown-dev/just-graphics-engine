import 'dart:math' as math;
import 'dart:typed_data';

import 'glb_writer.dart';

/// A box mannequin about 1.8 m tall, standing on y = 0 and facing +Z (glTF
/// axes), skinned to 16 joints with an `idle` and a `walk` clip. Made in
/// code, so it is free to use anywhere (CC0).
///
/// Joints: `hips` (the root), `spine`, `chest`, `head`, and per side
/// (`.L`, `.R`): `upper_arm`, `forearm`, `hand`, `thigh`, `shin`, `foot`.
Uint8List mannequinGlb({
  List<double> body = const [0.85, 0.6, 0.35, 1],
  List<double> clothes = const [0.25, 0.35, 0.6, 1],
}) {
  final w = GlbWriter();

  // Joints: name, parent, bind position (model space).
  final joints = <(String, int, List<double>)>[
    ('hips', -1, [0, 0.95, 0]),
    ('spine', 0, [0, 1.1, 0]),
    ('chest', 1, [0, 1.35, 0]),
    ('head', 2, [0, 1.58, 0]),
  ];
  for (final (side, x) in [('L', 1.0), ('R', -1.0)]) {
    final chest = 2, hips = 0;
    final shoulder = joints.length;
    joints.add(('upper_arm.$side', chest, [0.2 * x, 1.45, 0]));
    joints.add(('forearm.$side', shoulder, [0.2 * x, 1.18, 0]));
    joints.add(('hand.$side', shoulder + 1, [0.2 * x, 0.93, 0]));
    final thigh = joints.length;
    joints.add(('thigh.$side', hips, [0.1 * x, 0.92, 0]));
    joints.add(('shin.$side', thigh, [0.1 * x, 0.5, 0]));
    joints.add(('foot.$side', thigh + 1, [0.1 * x, 0.08, 0]));
  }
  int joint(String name) => joints.indexWhere((j) => j.$1 == name);

  // Boxes: joint, centre, size, colour (0 skin, 1 clothes).
  final boxes = <(int, List<double>, List<double>, int)>[
    (joint('hips'), [0, 0.98, 0], [0.32, 0.18, 0.2], 1),
    (joint('spine'), [0, 1.2, 0], [0.3, 0.22, 0.18], 1),
    (joint('chest'), [0, 1.4, 0], [0.38, 0.2, 0.22], 1),
    (joint('head'), [0, 1.7, 0.01], [0.2, 0.24, 0.22], 0),
  ];
  for (final (side, x) in [('L', 1.0), ('R', -1.0)]) {
    boxes
      ..add((
        joint('upper_arm.$side'),
        [0.2 * x, 1.32, 0],
        [0.09, 0.26, 0.09],
        1,
      ))
      ..add((joint('forearm.$side'), [0.2 * x, 1.06, 0], [0.08, 0.24, 0.08], 0))
      ..add((joint('hand.$side'), [0.2 * x, 0.87, 0], [0.07, 0.1, 0.05], 0))
      ..add((joint('thigh.$side'), [0.1 * x, 0.71, 0], [0.13, 0.42, 0.14], 1))
      ..add((joint('shin.$side'), [0.1 * x, 0.3, 0], [0.1, 0.4, 0.11], 1))
      ..add((joint('foot.$side'), [0.1 * x, 0.04, 0.05], [0.1, 0.08, 0.22], 0));
  }

  final primitives = <Map<String, dynamic>>[];
  final materials = [
    w.addMaterial({
      'name': 'skin',
      'pbrMetallicRoughness': {
        'baseColorFactor': body,
        'metallicFactor': 0,
        'roughnessFactor': 0.7,
      },
    }),
    w.addMaterial({
      'name': 'clothes',
      'pbrMetallicRoughness': {
        'baseColorFactor': clothes,
        'metallicFactor': 0,
        'roughnessFactor': 0.85,
      },
    }),
  ];
  for (var m = 0; m < 2; m++) {
    final positions = <double>[],
        normals = <double>[],
        js = <int>[],
        ws = <double>[],
        indices = <int>[];
    for (final (j, centre, size, material) in boxes) {
      if (material != m) continue;
      _box(centre, size, positions, normals, indices);
      for (var v = 0; v < 24; v++) {
        js.addAll([j, 0, 0, 0]);
        ws.addAll([1, 0, 0, 0]);
      }
    }
    primitives.add({
      'attributes': {
        'POSITION': w.addFloats(positions, 'VEC3', withBounds: true),
        'NORMAL': w.addFloats(normals, 'VEC3'),
        'JOINTS_0': w.addInts(js, 'VEC4', 5121),
        'WEIGHTS_0': w.addFloats(ws, 'VEC4'),
      },
      'indices': w.addInts(indices, 'SCALAR', 5123, indices: true),
      'material': materials[m],
    });
  }
  final mesh = w.addMesh(primitives, name: 'Mannequin');

  // Nodes, children first so parents can list them.
  final nodes = List<int>.filled(joints.length, -1);
  final children = List.generate(joints.length, (_) => <int>[]);
  for (var j = 0; j < joints.length; j++) {
    if (joints[j].$2 >= 0) children[joints[j].$2].add(j);
  }
  void make(int j) {
    for (final c in children[j]) {
      make(c);
    }
    final (name, parent, at) = joints[j];
    final from = parent < 0 ? const [0.0, 0.0, 0.0] : joints[parent].$3;
    nodes[j] = w.addNode({
      'name': name,
      'translation': [at[0] - from[0], at[1] - from[1], at[2] - from[2]],
      if (children[j].isNotEmpty)
        'children': [for (final c in children[j]) nodes[c]],
    });
  }

  make(0);
  final ibm = <double>[];
  for (final (_, _, at) in joints) {
    ibm.addAll([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -at[0], -at[1], -at[2], 1]);
  }
  w.addSkin({
    'joints': nodes,
    'inverseBindMatrices': w.addFloats(ibm, 'MAT4'),
    'skeleton': nodes[0],
  });
  final figure = w.addNode({'name': 'Mannequin', 'mesh': mesh, 'skin': 0});
  w.setScene([figure, nodes[0]]);

  _walk(w, nodes, joint, joints);
  _idle(w, nodes, joint, joints);
  return w.toGlb();
}

/// A rotation of [degrees] about +X as a quaternion.
List<double> _aboutX(double degrees) {
  final h = degrees * math.pi / 360;
  return [math.sin(h), 0, 0, math.cos(h)];
}

/// A rotation of [degrees] about +Z.
List<double> _aboutZ(double degrees) {
  final h = degrees * math.pi / 360;
  return [0, 0, math.sin(h), math.cos(h)];
}

void _walk(
  GlbWriter w,
  List<int> nodes,
  int Function(String) joint,
  List<(String, int, List<double>)> joints,
) {
  const times = [0.0, 0.25, 0.5, 0.75, 1.0];
  final input = w.addFloats(times, 'SCALAR');
  final samplers = <Map<String, dynamic>>[];
  final channels = <Map<String, dynamic>>[];
  void rotate(String name, List<double> degrees, {bool z = false}) {
    channels.add({
      'sampler': samplers.length,
      'target': {'node': nodes[joint(name)], 'path': 'rotation'},
    });
    samplers.add({
      'input': input,
      'output': w.addFloats([
        for (final d in degrees) ...(z ? _aboutZ(d) : _aboutX(d)),
      ], 'VEC4'),
      'interpolation': 'LINEAR',
    });
  }

  // Legs swing opposite each other; the back leg's knee bends; arms swing
  // against the legs.
  rotate('thigh.L', [-28, 0, 28, 0, -28]);
  rotate('thigh.R', [28, 0, -28, 0, 28]);
  rotate('shin.L', [5, 35, 5, 5, 5]);
  rotate('shin.R', [5, 5, 5, 35, 5]);
  rotate('upper_arm.L', [22, 0, -22, 0, 22]);
  rotate('upper_arm.R', [-22, 0, 22, 0, -22]);
  rotate('forearm.L', [-20, -10, -5, -10, -20]);
  rotate('forearm.R', [-5, -10, -20, -10, -5]);
  // The hips bob at each step.
  final rest = joints[joint('hips')].$3;
  channels.add({
    'sampler': samplers.length,
    'target': {'node': nodes[joint('hips')], 'path': 'translation'},
  });
  samplers.add({
    'input': input,
    'output': w.addFloats([
      for (final bob in [0.0, 0.03, 0.0, 0.03, 0.0]) ...[
        rest[0],
        rest[1] + bob,
        rest[2],
      ],
    ], 'VEC3'),
    'interpolation': 'LINEAR',
  });
  w.addAnimation({'name': 'walk', 'samplers': samplers, 'channels': channels});
}

void _idle(
  GlbWriter w,
  List<int> nodes,
  int Function(String) joint,
  List<(String, int, List<double>)> joints,
) {
  final input = w.addFloats([0.0, 1.0, 2.0], 'SCALAR');
  final samplers = <Map<String, dynamic>>[];
  final channels = <Map<String, dynamic>>[];
  void rotate(String name, List<double> degrees, {bool z = false}) {
    channels.add({
      'sampler': samplers.length,
      'target': {'node': nodes[joint(name)], 'path': 'rotation'},
    });
    samplers.add({
      'input': input,
      'output': w.addFloats([
        for (final d in degrees) ...(z ? _aboutZ(d) : _aboutX(d)),
      ], 'VEC4'),
      'interpolation': 'LINEAR',
    });
  }

  // Breathing, and arms resting a little away from the body.
  rotate('chest', [0, -3, 0]);
  rotate('head', [0, 2, 0]);
  rotate('upper_arm.L', [6, 9, 6], z: true);
  rotate('upper_arm.R', [-6, -9, -6], z: true);
  w.addAnimation({'name': 'idle', 'samplers': samplers, 'channels': channels});
}

/// A box of [size] around [centre], 24 vertices with face normals.
void _box(
  List<double> centre,
  List<double> size,
  List<double> positions,
  List<double> normals,
  List<int> indices,
) {
  const faces = [
    ([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]),
    ([-1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, 1.0, 0.0]),
    ([0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]),
    ([0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]),
    ([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
    ([0.0, 0.0, -1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]),
  ];
  for (final (n, u, v) in faces) {
    final base = positions.length ~/ 3;
    for (final (su, sv) in [
      (-1.0, -1.0),
      (1.0, -1.0),
      (1.0, 1.0),
      (-1.0, 1.0),
    ]) {
      for (var c = 0; c < 3; c++) {
        positions.add(centre[c] + (n[c] + su * u[c] + sv * v[c]) * size[c] / 2);
        normals.add(n[c]);
      }
    }
    indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
  }
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import '../assets/animation_clip.dart';
import '../assets/model_data.dart';

/// Floats per joint in a palette: the top three rows of its 4x4 matrix.
const int kPaletteFloats = 12;

/// The most joints the uniform-array fallback holds per draw.
const int kMaxUniformJoints = 64;

/// How joint matrices reach the vertex shader.
enum SkinningMode {
  /// Every palette of the frame in one `rgba32f` texture, read with
  /// `texelFetch`: skinned meshes stay instanced. Needs [GpuCaps.floatTextures].
  texture,

  /// One palette per draw in a uniform block (at most [kMaxUniformJoints]
  /// joints): the fallback, one draw per skinned instance.
  uniforms,
}

/// A model's node tree flattened parents first, for turning a [Pose] into
/// node matrices and those into the joint palettes of its skins.
final class Skeleton {
  /// The skeleton of [model].
  Skeleton(this.model)
    : nodeCount = model.nodes.length,
      _parents = Int32List(model.nodes.length)
        ..fillRange(0, model.nodes.length, -1) {
    final seen = List<bool>.filled(nodeCount, false);
    void walk(int node, int parent) {
      if (node >= nodeCount || seen[node]) return;
      seen[node] = true;
      _parents[node] = parent;
      _order.add(node);
      for (final child in model.nodes[node].children) {
        walk(child, node);
      }
    }

    for (final root in model.roots) {
      walk(root, -1);
    }
    // Nodes outside the shown scene still get matrices (a joint may be
    // left out of it by a careless exporter).
    for (var n = 0; n < nodeCount; n++) {
      if (!seen[n]) walk(n, -1);
    }
    for (var s = 0; s < model.skins.length; s++) {
      _reach.add(_reachOf(model.skins[s]));
    }
  }

  /// The model.
  final ModelData model;

  /// How many nodes.
  final int nodeCount;

  final Int32List _parents;
  final List<int> _order = [];
  final List<Float32List> _reach = [];

  /// Model-space matrices of every node in [pose], column-major, 16 floats
  /// each, into [out] (`nodeCount * 16` long). A node the file gave as a
  /// matrix uses that matrix.
  void evaluate(Pose pose, Float32List out) {
    for (final n in _order) {
      final o = n * 16;
      final node = model.nodes[n];
      if (node.translation == null) {
        out.setAll(o, node.local.storage);
      } else {
        _compose(pose, n, out, o);
      }
      final parent = _parents[n];
      if (parent >= 0) _multiplyInPlace(out, parent * 16, o);
    }
  }

  /// The palette of skin [skin] for [nodeMatrices] (from [evaluate]): per
  /// joint, the top three rows of `jointMatrix · inverseBind`
  /// ([kPaletteFloats] floats), into [out] from [offset].
  void palette(
    int skin,
    Float32List nodeMatrices,
    Float32List out, [
    int offset = 0,
  ]) {
    final data = model.skins[skin];
    final ibm = data.inverseBindMatrices;
    for (var j = 0; j < data.joints.length; j++) {
      final n = data.joints[j] * 16;
      final b = j * 16;
      final o = offset + j * kPaletteFloats;
      // Row r of (N · B): sum over k of N[k*4 + r] * B[c*4 + k], for column c.
      for (var r = 0; r < 3; r++) {
        for (var c = 0; c < 4; c++) {
          out[o + r * 4 + c] =
              nodeMatrices[n + r] * ibm[b + c * 4] +
              nodeMatrices[n + 4 + r] * ibm[b + c * 4 + 1] +
              nodeMatrices[n + 8 + r] * ibm[b + c * 4 + 2] +
              nodeMatrices[n + 12 + r] * ibm[b + c * 4 + 3];
        }
      }
    }
  }

  /// Bounds, in model space, of everything skin [skin] can draw in the pose
  /// of [nodeMatrices]: its joints' positions, grown by the furthest any
  /// vertex sits from its joint.
  void boundsInto(int skin, Float32List nodeMatrices, Aabb3 out) {
    final joints = model.skins[skin].joints;
    final reach = _reach[skin];
    out.setEmpty();
    for (var j = 0; j < joints.length; j++) {
      final o = joints[j] * 16;
      final x = nodeMatrices[o + 12],
          y = nodeMatrices[o + 13],
          z = nodeMatrices[o + 14];
      final r = reach[j];
      out
        ..addXYZ(x - r, y - r, z - r)
        ..addXYZ(x + r, y + r, z + r);
    }
  }

  /// Per joint of [skin], the furthest a vertex it moves sits from it in
  /// the bind pose (0 for a joint no vertex follows).
  Float32List _reachOf(SkinData skin) {
    final count = skin.joints.length;
    final reach = Float32List(count);
    // Each joint's bind-pose position: the translation of inverse(IBM).
    final positions = Float32List(count * 3);
    final m = Matrix4.zero(), inverse = Matrix4.zero();
    for (var j = 0; j < count; j++) {
      for (var i = 0; i < 16; i++) {
        m.storage[i] = skin.inverseBindMatrices[j * 16 + i];
      }
      inverse.copyInverse(m);
      positions[j * 3] = inverse.storage[12];
      positions[j * 3 + 1] = inverse.storage[13];
      positions[j * 3 + 2] = inverse.storage[14];
    }
    final skinIndex = model.skins.indexOf(skin);
    for (final node in model.nodes) {
      if (node.skin != skinIndex || node.mesh == null) continue;
      for (final p in model.meshes[node.mesh!].primitives) {
        final data = p.skin;
        if (data == null) continue;
        for (var v = 0; v < p.vertexCount; v++) {
          final px = p.vertices[v * kVertexFloats];
          final py = p.vertices[v * kVertexFloats + 1];
          final pz = p.vertices[v * kVertexFloats + 2];
          for (var i = 0; i < 4; i++) {
            if (data[v * kSkinFloats + 4 + i] <= 0) continue;
            final j = data[v * kSkinFloats + i].toInt();
            if (j < 0 || j >= count) continue;
            final dx = px - positions[j * 3],
                dy = py - positions[j * 3 + 1],
                dz = pz - positions[j * 3 + 2];
            final d = math.sqrt(dx * dx + dy * dy + dz * dz);
            if (d > reach[j]) reach[j] = d;
          }
        }
      }
    }
    return reach;
  }

  /// Writes node [n]'s translation · rotation · scale from [pose] into
  /// [out] at [o].
  static void _compose(Pose pose, int n, Float32List out, int o) {
    final t = pose.translations, r = pose.rotations, s = pose.scales;
    final x = r[n * 4], y = r[n * 4 + 1], z = r[n * 4 + 2], w = r[n * 4 + 3];
    final sx = s[n * 3], sy = s[n * 3 + 1], sz = s[n * 3 + 2];
    final xx = x * x, yy = y * y, zz = z * z;
    final xy = x * y, xz = x * z, yz = y * z;
    final wx = w * x, wy = w * y, wz = w * z;
    out[o] = (1 - 2 * (yy + zz)) * sx;
    out[o + 1] = 2 * (xy + wz) * sx;
    out[o + 2] = 2 * (xz - wy) * sx;
    out[o + 3] = 0;
    out[o + 4] = 2 * (xy - wz) * sy;
    out[o + 5] = (1 - 2 * (xx + zz)) * sy;
    out[o + 6] = 2 * (yz + wx) * sy;
    out[o + 7] = 0;
    out[o + 8] = 2 * (xz + wy) * sz;
    out[o + 9] = 2 * (yz - wx) * sz;
    out[o + 10] = (1 - 2 * (xx + yy)) * sz;
    out[o + 11] = 0;
    out[o + 12] = t[n * 3];
    out[o + 13] = t[n * 3 + 1];
    out[o + 14] = t[n * 3 + 2];
    out[o + 15] = 1;
  }

  static final Float64List _tmp = Float64List(16);

  /// `m[child] = m[parent] · m[child]` (both affine, column-major).
  static void _multiplyInPlace(Float32List m, int a, int b) {
    final t = _tmp;
    for (var c = 0; c < 4; c++) {
      final b0 = m[b + c * 4],
          b1 = m[b + c * 4 + 1],
          b2 = m[b + c * 4 + 2],
          b3 = m[b + c * 4 + 3];
      for (var r = 0; r < 4; r++) {
        t[c * 4 + r] =
            m[a + r] * b0 +
            m[a + 4 + r] * b1 +
            m[a + 8 + r] * b2 +
            m[a + 12 + r] * b3;
      }
    }
    for (var i = 0; i < 16; i++) {
      m[b + i] = t[i];
    }
  }
}

/// One posed skin, ready to draw: [rows] holds its joint palette
/// ([kPaletteFloats] floats per joint), refreshed by its owner each frame.
final class SkinPalette {
  /// A palette of [jointCount] joints, all at the identity.
  SkinPalette(this.jointCount)
    : rows = Float32List(jointCount * kPaletteFloats) {
    for (var j = 0; j < jointCount; j++) {
      rows[j * kPaletteFloats] = 1;
      rows[j * kPaletteFloats + 5] = 1;
      rows[j * kPaletteFloats + 10] = 1;
    }
  }

  /// Joints.
  final int jointCount;

  /// Joint rows.
  final Float32List rows;

  /// Where this palette starts in the frame's joint texture, in texels; set
  /// by the renderer while it draws.
  int texel = 0;

  /// The frame whose joint texture holds it (renderer bookkeeping).
  int frame = -1;
}

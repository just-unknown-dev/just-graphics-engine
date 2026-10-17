import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import '../gpu/device.dart';
import 'gpu_model.dart';

/// Floats per instance in a batch's buffer: a model matrix, then a normal
/// matrix (three columns of four) — what every lit and shadow draw reads.
const int kBatchInstanceFloats = 28;

/// Many copies of one primitive in one material, drawn in one call: grass,
/// rocks, tiles, a fence's posts. Unlike [MeshInstance]s, which the
/// renderer culls and packs one by one each frame, a batch is culled as a
/// whole by its [bounds] and keeps its instances on the GPU between frames,
/// uploaded again only when they change ([setInstances]).
///
/// Opaque materials only: a batch is never sorted back to front.
final class InstanceBatch {
  /// [primitive] in [material], with no instances yet.
  InstanceBatch(this.primitive, this.material);

  /// What each instance draws.
  GpuPrimitive primitive;

  /// How each instance looks.
  GpuMaterial material;

  /// Drawn at all.
  bool visible = true;

  /// Casts shadows.
  bool castShadows = true;

  /// Not drawn when its bounds are further than this from the camera, in
  /// metres: small things far away (the grass of the next field).
  double maxDistance = double.infinity;

  /// Every instance's bounds together, in the world.
  final Aabb3 bounds = Aabb3();

  Float32List _data = Float32List(0);
  int _count = 0;
  int _revision = 0;

  /// Instances held.
  int get count => _count;

  /// Bumped by every [setInstances]: the renderer uploads again when it
  /// differs from what it last uploaded.
  int get revision => _revision;

  /// The instances' data, [kBatchInstanceFloats] floats each.
  Float32List get data => Float32List.sublistView(_data, 0, _count * kBatchInstanceFloats);

  /// Where the renderer keeps the uploaded data, and of which revision.
  GpuBuffer? buffer;
  int uploaded = -1;

  final Aabb3 _one = Aabb3();

  /// Replaces the instances with one at each of [worlds] (world from
  /// local), and their [bounds] with what [primitive]'s bounds become there.
  void setInstances(List<Matrix4> worlds) {
    final need = worlds.length * kBatchInstanceFloats;
    if (_data.length < need) _data = Float32List(need);
    bounds.setEmpty();
    for (var i = 0; i < worlds.length; i++) {
      writeInstance(_data, i * kBatchInstanceFloats, worlds[i]);
      primitive.bounds.transformInto(worlds[i], _one);
      bounds.addBox(_one);
    }
    _count = worlds.length;
    _revision++;
  }

  /// Writes [m] and its normal matrix (the inverse transpose of its upper
  /// 3×3) into [out] at [o]: one instance's [kBatchInstanceFloats] floats.
  static void writeInstance(Float32List out, int o, Matrix4 m) {
    final s = m.storage;
    for (var k = 0; k < 16; k++) {
      out[o + k] = s[k];
    }
    final a = s[0], b = s[1], c = s[2];
    final d = s[4], e = s[5], f = s[6];
    final g = s[8], h = s[9], k = s[10];
    final c00 = e * k - f * h, c01 = -(d * k - f * g), c02 = d * h - e * g;
    final c10 = -(b * k - c * h), c11 = a * k - c * g, c12 = -(a * h - b * g);
    final c20 = b * f - c * e, c21 = -(a * f - c * d), c22 = a * e - b * d;
    final det = a * c00 + b * c01 + c * c02;
    final inv = det.abs() < 1e-20 ? 0.0 : 1.0 / det;
    out[o + 16] = c00 * inv;
    out[o + 17] = c01 * inv;
    out[o + 18] = c02 * inv;
    out[o + 19] = 0;
    out[o + 20] = c10 * inv;
    out[o + 21] = c11 * inv;
    out[o + 22] = c12 * inv;
    out[o + 23] = 0;
    out[o + 24] = c20 * inv;
    out[o + 25] = c21 * inv;
    out[o + 26] = c22 * inv;
    out[o + 27] = 0;
  }
}

/// Lines drawn over the scene: a primitive's edges where [world] puts it,
/// in [color] — a selection's highlight, a wireframe.
///
/// Needs the edges the uploader keeps when asked (`ModelUploader.keepEdges`);
/// a primitive without them is skipped.
final class OverlayDraw {
  /// [primitive]'s edges, placed by [world], in [color] (straight RGBA).
  OverlayDraw(
    this.primitive,
    Matrix4 world, {
    this.color = const (1.0, 0.6, 0.1, 1.0),
    this.xray = false,
  }) {
    this.world.setFrom(world);
  }

  /// Whose edges.
  final GpuPrimitive primitive;

  /// World from local.
  final Matrix4 world = Matrix4.identity();

  /// Straight RGBA.
  final (double, double, double, double) color;

  /// Drawn through whatever is in front of it, as well as where seen.
  final bool xray;
}

/// How the renderer draws the scene: as it looks, flat-lit to read shapes
/// by, or as lines only.
enum RenderViewMode {
  /// Lit, shadowed, as the game draws it.
  lit,

  /// Colours only, shaded a little by facing so shapes read: no lights or
  /// shadows.
  unlit,

  /// Every edge, nothing filled.
  wireframe,
}

/// Draw sort keys: one integer per draw, sorted ascending.
///
/// An opaque key packs, from most to least significant:
///
/// | bits | field |
/// |---|---|
/// | 4 | phase (shadow, opaque, sky, transparent, …) |
/// | 12 | pipeline |
/// | 16 | material |
/// | 12 | mesh |
/// | 8 | depth bucket, near first |
///
/// so draws of one pipeline, material and mesh sit together (and can merge
/// into one instanced draw), front to back inside each group. A transparent
/// key must order back to front first, so it puts the depth bucket straight
/// after the phase: phase, depth, pipeline, material, mesh.
///
/// 52 bits in all, so a key is exact as a JavaScript number. On the web,
/// Dart's `<<` and `|` work on 32 bits, so keys are built with
/// multiplication and addition.
abstract final class SortKey {
  /// Largest phase.
  static const int maxPhase = 15;

  /// Largest pipeline index.
  static const int maxPipeline = 4095;

  /// Largest material index.
  static const int maxMaterial = 65535;

  /// Largest mesh index.
  static const int maxMesh = 4095;

  /// Largest depth bucket.
  static const int maxDepth = 255;

  static const int _p8 = 256; // 2^8
  static const int _p12 = 4096; // 2^12
  static const int _p20 = 1048576; // 2^20
  static const int _p28 = 268435456; // 2^28
  static const int _p36 = 68719476736; // 2^36
  static const int _p40 = 1099511627776; // 2^40
  static const int _p48 = 281474976710656; // 2^48

  /// A key for an opaque (or alpha-tested) draw.
  static int opaque({
    required int phase,
    required int pipeline,
    required int material,
    required int mesh,
    required int depth,
  }) {
    _check(phase, maxPhase, 'phase');
    _check(pipeline, maxPipeline, 'pipeline');
    _check(material, maxMaterial, 'material');
    _check(mesh, maxMesh, 'mesh');
    _check(depth, maxDepth, 'depth');
    return phase * _p48 +
        pipeline * _p36 +
        material * _p20 +
        mesh * _p8 +
        depth;
  }

  /// A key for a transparent draw, back to front: pass [depth] with far
  /// small and near large (`maxDepth - nearFirstBucket`).
  static int transparent({
    required int phase,
    required int depth,
    required int pipeline,
    required int material,
    required int mesh,
  }) {
    _check(phase, maxPhase, 'phase');
    _check(depth, maxDepth, 'depth');
    _check(pipeline, maxPipeline, 'pipeline');
    _check(material, maxMaterial, 'material');
    _check(mesh, maxMesh, 'mesh');
    return phase * _p48 +
        depth * _p40 +
        pipeline * _p28 +
        material * _p12 +
        mesh;
  }

  /// The phase stored in [key].
  static int phaseOf(int key) => key ~/ _p48;

  /// The pipeline, material and mesh of an opaque [key], which decide
  /// whether two draws can share one instanced draw.
  static int batchOf(int opaqueKey) => opaqueKey ~/ _p8;

  /// Quantises [viewDepth] between [near] and [far] into a bucket, 0 nearest.
  static int depthBucket(double viewDepth, double near, double far) {
    if (far <= near) return 0;
    final t = ((viewDepth - near) / (far - near)).clamp(0.0, 1.0);
    return (t * maxDepth).round();
  }

  static void _check(int value, int max, String name) {
    if (value < 0 || value > max) {
      throw RangeError.range(value, 0, max, name);
    }
  }
}

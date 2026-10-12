import 'dart:math' as math;
import 'dart:typed_data';

import 'model_data.dart';

/// Every node's translation, rotation and scale: what an animation moves.
///
/// Flat arrays indexed by node: three floats per translation and scale, four
/// per rotation (x, y, z, w). In the model's own axes (glTF: +Y up).
final class Pose {
  /// A pose of [nodeCount] nodes, all at the origin, unrotated, unscaled.
  Pose(this.nodeCount)
    : translations = Float32List(nodeCount * 3),
      rotations = Float32List(nodeCount * 4),
      scales = Float32List(nodeCount * 3) {
    for (var n = 0; n < nodeCount; n++) {
      rotations[n * 4 + 3] = 1;
      scales[n * 3] = 1;
      scales[n * 3 + 1] = 1;
      scales[n * 3 + 2] = 1;
    }
  }

  /// [model]'s rest pose: each node as the file placed it.
  factory Pose.rest(ModelData model) =>
      Pose(model.nodes.length)..setRest(model);

  /// How many nodes.
  final int nodeCount;

  /// x, y, z per node.
  final Float32List translations;

  /// x, y, z, w per node.
  final Float32List rotations;

  /// x, y, z per node.
  final Float32List scales;

  /// Every node back to [model]'s rest pose. A node the file gave as a
  /// matrix keeps identity values here (it is never animated).
  void setRest(ModelData model) {
    for (var n = 0; n < nodeCount && n < model.nodes.length; n++) {
      final node = model.nodes[n];
      final t = node.translation, r = node.rotation, s = node.scale;
      translations[n * 3] = t?.x ?? 0;
      translations[n * 3 + 1] = t?.y ?? 0;
      translations[n * 3 + 2] = t?.z ?? 0;
      rotations[n * 4] = r?.x ?? 0;
      rotations[n * 4 + 1] = r?.y ?? 0;
      rotations[n * 4 + 2] = r?.z ?? 0;
      rotations[n * 4 + 3] = r?.w ?? 1;
      scales[n * 3] = s?.x ?? 1;
      scales[n * 3 + 1] = s?.y ?? 1;
      scales[n * 3 + 2] = s?.z ?? 1;
    }
  }

  /// Copies [other].
  void setFrom(Pose other) {
    translations.setAll(0, other.translations);
    rotations.setAll(0, other.rotations);
    scales.setAll(0, other.scales);
  }

  /// This pose blended from [a] towards [b] by [t] (0 = [a], 1 = [b]):
  /// translations and scales linearly, rotations along the shorter way.
  void blend(Pose a, Pose b, double t) {
    final u = 1 - t;
    for (var i = 0; i < translations.length; i++) {
      translations[i] = a.translations[i] * u + b.translations[i] * t;
      scales[i] = a.scales[i] * u + b.scales[i] * t;
    }
    for (var n = 0; n < nodeCount; n++) {
      final o = n * 4;
      final ra = a.rotations, rb = b.rotations;
      final dot =
          ra[o] * rb[o] +
          ra[o + 1] * rb[o + 1] +
          ra[o + 2] * rb[o + 2] +
          ra[o + 3] * rb[o + 3];
      final sign = dot < 0 ? -1.0 : 1.0;
      var x = ra[o] * u + rb[o] * t * sign;
      var y = ra[o + 1] * u + rb[o + 1] * t * sign;
      var z = ra[o + 2] * u + rb[o + 2] * t * sign;
      var w = ra[o + 3] * u + rb[o + 3] * t * sign;
      final length = math.sqrt(x * x + y * y + z * z + w * w);
      if (length > 1e-12) {
        x /= length;
        y /= length;
        z /= length;
        w /= length;
      }
      rotations[o] = x;
      rotations[o + 1] = y;
      rotations[o + 2] = z;
      rotations[o + 3] = w;
    }
  }
}

/// A glTF animation, ready to sample: [sample] writes the nodes it moves at
/// any time into a [Pose].
final class AnimationClip {
  /// A clip playing [data].
  AnimationClip(this.data) : _lastKey = List.filled(data.samplers.length, 0);

  /// What it plays.
  final AnimationData data;

  // The key each sampler found last time: playback moves forward a little
  // each frame, so the search usually starts in the right place.
  final List<int> _lastKey;

  /// Its name.
  String get name => data.name;

  /// Its length in seconds.
  double get duration => data.duration;

  /// Writes every channel's value at [time] (seconds, clamped to the keys)
  /// into [pose]. Nodes the clip doesn't move are left as they are.
  void sample(double time, Pose pose) {
    final value = _scratch;
    for (final channel in data.channels) {
      if (channel.node >= pose.nodeCount) continue;
      final sampler = data.samplers[channel.sampler];
      _sampleInto(channel.sampler, sampler, time, value);
      final n = channel.node;
      switch (channel.path) {
        case AnimationPath.translation:
          pose.translations[n * 3] = value[0];
          pose.translations[n * 3 + 1] = value[1];
          pose.translations[n * 3 + 2] = value[2];
        case AnimationPath.rotation:
          pose.rotations[n * 4] = value[0];
          pose.rotations[n * 4 + 1] = value[1];
          pose.rotations[n * 4 + 2] = value[2];
          pose.rotations[n * 4 + 3] = value[3];
        case AnimationPath.scale:
          pose.scales[n * 3] = value[0];
          pose.scales[n * 3 + 1] = value[1];
          pose.scales[n * 3 + 2] = value[2];
        case AnimationPath.weights:
          break;
      }
    }
  }

  static final Float64List _scratch = Float64List(4);

  /// The value of [sampler] (index [index]) at [time] into [out].
  void _sampleInto(
    int index,
    AnimationSamplerData sampler,
    double time,
    Float64List out,
  ) {
    final input = sampler.input;
    final w = sampler.width;
    final cubic = sampler.interpolation == AnimationInterpolation.cubicSpline;
    // Where key k's value starts: cubic keys hold in-tangent, value, out-tangent.
    int valueAt(int k) => cubic ? (k * 3 + 1) * w : k * w;
    final keys = input.length;
    if (keys == 0) return;
    if (keys == 1 || time <= input[0]) {
      _copy(sampler.output, valueAt(0), w, out);
      _normalizeRotation(w, out);
      return;
    }
    if (time >= input[keys - 1]) {
      _copy(sampler.output, valueAt(keys - 1), w, out);
      _normalizeRotation(w, out);
      return;
    }
    final k = _findKey(index, input, time);
    final t0 = input[k], t1 = input[k + 1];
    final span = t1 - t0;
    final u = span > 0 ? (time - t0) / span : 0.0;
    final output = sampler.output;
    switch (sampler.interpolation) {
      case AnimationInterpolation.step:
        _copy(output, valueAt(k), w, out);
      case AnimationInterpolation.linear:
        final a = valueAt(k), b = valueAt(k + 1);
        if (w == 4) {
          _slerp(output, a, b, u, out);
        } else {
          for (var c = 0; c < w; c++) {
            out[c] = output[a + c] + (output[b + c] - output[a + c]) * u;
          }
        }
      case AnimationInterpolation.cubicSpline:
        // glTF: p(u) = (2u³−3u²+1)v₀ + (u³−2u²+u)·Δt·b₀ + (−2u³+3u²)v₁ + (u³−u²)·Δt·a₁.
        final u2 = u * u, u3 = u2 * u;
        final h00 = 2 * u3 - 3 * u2 + 1;
        final h10 = u3 - 2 * u2 + u;
        final h01 = -2 * u3 + 3 * u2;
        final h11 = u3 - u2;
        final v0 = valueAt(k), v1 = valueAt(k + 1);
        final outTangent0 = v0 + w; // b₀ follows v₀
        final inTangent1 = (k + 1) * 3 * w; // a₁ starts key k+1
        for (var c = 0; c < w; c++) {
          out[c] =
              h00 * output[v0 + c] +
              h10 * span * output[outTangent0 + c] +
              h01 * output[v1 + c] +
              h11 * span * output[inTangent1 + c];
        }
    }
    _normalizeRotation(w, out);
  }

  /// The key k with `input[k] <= time < input[k + 1]`.
  int _findKey(int index, Float32List input, double time) {
    var k = _lastKey[index];
    if (k < input.length - 1 && input[k] <= time && time < input[k + 1]) {
      return k;
    }
    if (k + 2 < input.length && input[k + 1] <= time && time < input[k + 2]) {
      return _lastKey[index] = k + 1;
    }
    var lo = 0, hi = input.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (input[mid] <= time) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _lastKey[index] = lo;
  }

  static void _copy(Float32List from, int at, int w, Float64List out) {
    for (var c = 0; c < w; c++) {
      out[c] = from[at + c];
    }
  }

  static void _normalizeRotation(int w, Float64List q) {
    if (w != 4) return;
    final length = math.sqrt(
      q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3],
    );
    if (length < 1e-12) {
      q[0] = q[1] = q[2] = 0;
      q[3] = 1;
      return;
    }
    for (var c = 0; c < 4; c++) {
      q[c] /= length;
    }
  }

  /// Spherical interpolation from the quaternion at [a] to the one at [b].
  static void _slerp(Float32List v, int a, int b, double t, Float64List out) {
    final ax = v[a], ay = v[a + 1], az = v[a + 2], aw = v[a + 3];
    var bx = v[b], by = v[b + 1], bz = v[b + 2], bw = v[b + 3];
    var cos = ax * bx + ay * by + az * bz + aw * bw;
    if (cos < 0) {
      cos = -cos;
      bx = -bx;
      by = -by;
      bz = -bz;
      bw = -bw;
    }
    double s0, s1;
    if (cos > 0.9995) {
      // Nearly the same: a straight line is exact enough (normalised after).
      s0 = 1 - t;
      s1 = t;
    } else {
      final angle = math.acos(cos);
      final sin = math.sin(angle);
      s0 = math.sin((1 - t) * angle) / sin;
      s1 = math.sin(t * angle) / sin;
    }
    out[0] = ax * s0 + bx * s1;
    out[1] = ay * s0 + by * s1;
    out[2] = az * s0 + bz * s1;
    out[3] = aw * s0 + bw * s1;
  }
}

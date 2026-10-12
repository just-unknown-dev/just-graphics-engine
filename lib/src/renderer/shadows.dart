import 'dart:math' as math;

import 'package:just_dart/just_dart.dart';

import 'render_scene.dart';

/// How the sun's shadows are drawn.
final class ShadowSettings {
  /// Whether the sun casts shadows.
  bool enabled = true;

  /// Texels along each side of the shadow map.
  int mapSize = 2048;

  /// How far from the camera shadows reach, in metres.
  double distance = 40;

  /// Shadow maps over that distance: 1, or 2 (a sharp one near the camera
  /// and a wider one beyond [cascadeSplit]). Each costs a shadow pass.
  int cascades = 2;

  /// Where the second cascade takes over, as a share of [distance].
  double cascadeSplit = 0.25;

  /// How dark shadows are: 0 none, 1 full.
  double strength = 1;

  /// How far behind the shadowed region, towards the sun, casters still
  /// count (a tall building out of view still shades the street), metres.
  double casterReach = 60;

  /// Receivers are pushed this many shadow-map texels along their normal
  /// before the test, against self-shadowing acne.
  double normalOffsetTexels = 1.5;

  /// Depth bias, metres.
  double depthBias = 0.02;
}

/// A sun shadow map's placement for one frame.
final class ShadowFit {
  /// World to the sun's view (rotation only; the box is in [projection]).
  final Matrix4 view = Matrix4.identity();

  /// The sun's box to the engine's clip space (x, y in -1..1, y down, depth
  /// 0..1).
  final Matrix4 projection = Matrix4.identity();

  /// `projection · view`.
  final Matrix4 viewProjection = Matrix4.identity();

  /// The box's half-width, metres.
  double radius = 0;

  /// One shadow-map texel, metres.
  double texelSize = 0;

  /// Depth covered from near to far, metres.
  double depthRange = 1;

  /// What the box holds, for culling casters.
  final Frustum frustum = Frustum();
}

final Matrix4 _inverse = Matrix4.identity();
final Matrix4 _viewProjection = Matrix4.identity();
final List<Vector3> _corners = [for (var i = 0; i < 8; i++) Vector3.zero()];
final Vector3 _centre = Vector3.zero();
final Vector3 _point = Vector3.zero();

/// Places a shadow map for a sun shining along [direction] around what
/// [view] sees up to [settings]' distance, into [out]. The box is the
/// bounding sphere of that slice of the view (so it keeps its size as the
/// camera turns) and moves in whole texels (so shadow edges don't crawl as
/// the camera moves). False when there is nothing to fit.
bool fitSunShadow(
  RenderView view,
  Vector3 direction,
  ShadowSettings settings,
  ShadowFit out, {
  double from = 0,
  double? to,
}) {
  if (direction.lengthSquared < 1e-12) return false;
  _viewProjection.setProduct(view.projection, view.view);
  if (_inverse.copyInverse(_viewProjection) == 0) return false;

  // The view frustum's corners: near (z = 0) then far (z = 1).
  var i = 0;
  for (final z in [0.0, 1.0]) {
    for (final y in [-1.0, 1.0]) {
      for (final x in [-1.0, 1.0]) {
        final corner = _corners[i++]..setValues(x, y, z);
        _inverse.transformPointInto(corner, corner);
      }
    }
  }
  // Cut the far corners at the shadow distance along the view direction.
  final v = view.view.storage;
  final fx = v[2], fy = v[6], fz = v[10];
  final eye = view.cameraPosition;
  double depthOf(Vector3 p) =>
      (p.x - eye.x) * fx + (p.y - eye.y) * fy + (p.z - eye.z) * fz;
  // A cascade covers [from]..[to] of that: its near corners move out too.
  final end = to ?? settings.distance;
  for (var c = 0; c < 4; c++) {
    final near = _corners[c], far = _corners[c + 4];
    final nx = near.x, ny = near.y, nz = near.z;
    final ex = far.x, ey = far.y, ez = far.z;
    final dn = depthOf(near), df = depthOf(far);
    final span = df - dn;
    double at(double depth) =>
        span > 1e-9 ? ((depth - dn) / span).clamp(0.0, 1.0) : 1.0;
    final tNear = at(math.max(from, dn)), tFar = at(math.min(end, df));
    near.setValues(
      nx + (ex - nx) * tNear,
      ny + (ey - ny) * tNear,
      nz + (ez - nz) * tNear,
    );
    far.setValues(
      nx + (ex - nx) * tFar,
      ny + (ey - ny) * tFar,
      nz + (ez - nz) * tFar,
    );
  }
  _centre.setZero();
  for (final p in _corners) {
    _centre.add(p);
  }
  _centre.scale(1 / 8);
  var radius = 0.0;
  for (final p in _corners) {
    radius = math.max(radius, p.distanceTo(_centre));
  }
  // A size that only changes in sixteenths of a metre.
  radius = math.max(1 / 16, (radius * 16).ceilToDouble() / 16);

  _lightView(direction, out.view);
  out.view.transformPointInto(_centre, _point);
  final texel = 2 * radius / settings.mapSize;
  final cx = (_point.x / texel).floorToDouble() * texel;
  final cy = (_point.y / texel).floorToDouble() * texel;
  final near = _point.z - radius - settings.casterReach;
  final far = _point.z + radius;
  out.projection.setOrthographicYDown(
    cx - radius,
    cx + radius,
    cy - radius,
    cy + radius,
    near,
    far,
  );
  out.viewProjection.setProduct(out.projection, out.view);
  out.frustum.setFromViewProjection(out.viewProjection);
  out
    ..radius = radius
    ..texelSize = texel
    ..depthRange = far - near;
  return true;
}

/// A view matrix (rotation only) looking along [direction], in the
/// engine's camera convention (+X right, +Y down, +Z ahead).
void _lightView(Vector3 direction, Matrix4 out) {
  final f = Vector3.copy(direction)..normalize();
  // "Down" on the map: the world's down, unless the light falls straight
  // along it.
  final down = f.y.abs() > 0.99 ? Vector3(0, 0, 1) : Vector3(0, 1, 0);
  final r = down.cross(f)..normalize();
  final d = f.cross(r);
  final m = out.storage;
  m[0] = r.x;
  m[4] = r.y;
  m[8] = r.z;
  m[1] = d.x;
  m[5] = d.y;
  m[9] = d.z;
  m[2] = f.x;
  m[6] = f.y;
  m[10] = f.z;
  m[3] = 0;
  m[7] = 0;
  m[11] = 0;
  m[12] = 0;
  m[13] = 0;
  m[14] = 0;
  m[15] = 1;
}

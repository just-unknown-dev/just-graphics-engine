import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import 'model_data.dart';

/// A 3-D shape's triangles on the CPU, in its own space: the renderer's
/// axes (+Y down), metres. Front faces wind counter-clockwise seen from
/// outside, as glTF's do once turned into engine axes.
final class ShapeMesh {
  /// A mesh of [indices] triangles over its vertices.
  ShapeMesh({
    required this.positions,
    required this.normals,
    required this.uvs,
    required this.indices,
  });

  /// x, y, z per vertex.
  final Float32List positions;

  /// x, y, z per vertex, unit length.
  final Float32List normals;

  /// u, v per vertex.
  final Float32List uvs;

  /// Three per triangle.
  final Uint32List indices;

  /// How many vertices there are.
  int get vertexCount => positions.length ~/ 3;

  /// How many triangles there are.
  int get triangleCount => indices.length ~/ 3;

  /// The box around every vertex; empty for no vertices.
  Aabb3 get bounds {
    final out = Aabb3();
    for (var i = 0; i < positions.length; i += 3) {
      out.addXYZ(positions[i], positions[i + 1], positions[i + 2]);
    }
    return out;
  }

  /// The same triangles, each with vertices of its own and its face's
  /// normal: hard edges everywhere, the low-poly look.
  ShapeMesh faceted() {
    final n = indices.length;
    final p = Float32List(n * 3),
        nn = Float32List(n * 3),
        t = Float32List(n * 2);
    final idx = Uint32List(n);
    for (var tri = 0; tri < n; tri += 3) {
      final a = indices[tri] * 3,
          b = indices[tri + 1] * 3,
          c = indices[tri + 2] * 3;
      final ux = positions[b] - positions[a],
          uy = positions[b + 1] - positions[a + 1],
          uz = positions[b + 2] - positions[a + 2];
      final vx = positions[c] - positions[a],
          vy = positions[c + 1] - positions[a + 1],
          vz = positions[c + 2] - positions[a + 2];
      var fx = uy * vz - uz * vy,
          fy = uz * vx - ux * vz,
          fz = ux * vy - uy * vx;
      final len = math.sqrt(fx * fx + fy * fy + fz * fz);
      if (len > 0) {
        fx /= len;
        fy /= len;
        fz /= len;
      }
      for (var k = 0; k < 3; k++) {
        final src = indices[tri + k];
        final dst = tri + k;
        p[dst * 3] = positions[src * 3];
        p[dst * 3 + 1] = positions[src * 3 + 1];
        p[dst * 3 + 2] = positions[src * 3 + 2];
        nn[dst * 3] = fx;
        nn[dst * 3 + 1] = fy;
        nn[dst * 3 + 2] = fz;
        t[dst * 2] = uvs[src * 2];
        t[dst * 2 + 1] = uvs[src * 2 + 1];
        idx[dst] = dst;
      }
    }
    return ShapeMesh(positions: p, normals: nn, uvs: t, indices: idx);
  }

  /// As the renderer takes it: interleaved vertices ([kVertexFloats] each:
  /// no tangents — the shader derives them — and white vertex colour).
  PrimitiveData toPrimitive({int? material = 0}) {
    final count = vertexCount;
    final v = Float32List(count * kVertexFloats);
    for (var i = 0; i < count; i++) {
      final o = i * kVertexFloats;
      v[o] = positions[i * 3];
      v[o + 1] = positions[i * 3 + 1];
      v[o + 2] = positions[i * 3 + 2];
      v[o + 3] = normals[i * 3];
      v[o + 4] = normals[i * 3 + 1];
      v[o + 5] = normals[i * 3 + 2];
      v[o + 10] = uvs[i * 2];
      v[o + 11] = uvs[i * 2 + 1];
      v[o + 12] = 1;
      v[o + 13] = 1;
      v[o + 14] = 1;
      v[o + 15] = 1;
    }
    return PrimitiveData(
      vertices: v,
      indices: indices,
      material: material,
      bounds: bounds,
      hasTangents: false,
    );
  }
}

/// How a shape lays its texture out.
///
/// [natural]: each face of a box or a plane once, round surfaces wrapped
/// once around and once along; the blocking shapes (ramp, stairs, arch,
/// polygon) once per metre of their own size.
///
/// [metres]: once per metre of the world on every surface — the shape's
/// size times the scale it is drawn at — so a grid texture keeps its scale on
/// shapes of any size.
final class ShapeUv {
  const ShapeUv._natural() : metres = false, sx = 1, sy = 1, sz = 1;

  /// Coordinates in metres of the world, for a shape drawn scaled by
  /// ([sx], [sy], [sz]).
  const ShapeUv.metresAt(this.sx, this.sy, this.sz) : metres = true;

  /// Natural texture coordinates.
  static const ShapeUv natural = ShapeUv._natural();

  /// Whether coordinates are in metres of the world.
  final bool metres;

  /// The scale the shape is drawn at (absolute), for [metres].
  final double sx, sy, sz;

  /// Equal for equal layouts (a cache key).
  Object get key => metres ? (sx, sy, sz) : false;

  /// Length along a ring of [radius] about Y, in the world.
  double around(double radius) =>
      2 * math.pi * radius * (metres ? (sx.abs() + sz.abs()) / 2 : 1);

  /// Length [length] along Y, in the world.
  double alongY(double length) => length * (metres ? sy.abs() : 1);

  /// A length that bends every way (round a torus's tube), in the world.
  double anyway(double length) =>
      length * (metres ? (sx.abs() + sy.abs() + sz.abs()) / 3 : 1);
}

/// Builds a [ShapeMesh] a vertex and a triangle at a time. Each triangle is
/// wound to face the way its vertices' normals point, whichever order it
/// was given in.
final class MeshBuilder {
  /// A builder laying textures out by [uv].
  MeshBuilder([this.uv = ShapeUv.natural]);

  /// How textures are laid out.
  final ShapeUv uv;

  final List<double> _p = [], _n = [], _t = [];
  final List<int> _i = [];

  /// How many vertices so far.
  int get vertexCount => _p.length ~/ 3;

  /// Adds a vertex; returns its index.
  int vertex(
    double x,
    double y,
    double z,
    double nx,
    double ny,
    double nz,
    double u,
    double v,
  ) {
    _p.addAll([x, y, z]);
    _n.addAll([nx, ny, nz]);
    _t.addAll([u, v]);
    return vertexCount - 1;
  }

  /// Adds a triangle facing the way its vertices' normals point. One with
  /// no area is left out.
  void triangle(int a, int b, int c) {
    final ux = _p[b * 3] - _p[a * 3],
        uy = _p[b * 3 + 1] - _p[a * 3 + 1],
        uz = _p[b * 3 + 2] - _p[a * 3 + 2];
    final vx = _p[c * 3] - _p[a * 3],
        vy = _p[c * 3 + 1] - _p[a * 3 + 1],
        vz = _p[c * 3 + 2] - _p[a * 3 + 2];
    final fx = uy * vz - uz * vy,
        fy = uz * vx - ux * vz,
        fz = ux * vy - uy * vx;
    final area = fx * fx + fy * fy + fz * fz;
    final scale = (ux * ux + uy * uy + uz * uz) * (vx * vx + vy * vy + vz * vz);
    if (area <= 1e-14 * scale || area == 0) return;
    final nx = _n[a * 3] + _n[b * 3] + _n[c * 3];
    final ny = _n[a * 3 + 1] + _n[b * 3 + 1] + _n[c * 3 + 1];
    final nz = _n[a * 3 + 2] + _n[b * 3 + 2] + _n[c * 3 + 2];
    if (fx * nx + fy * ny + fz * nz >= 0) {
      _i.addAll([a, b, c]);
    } else {
      _i.addAll([a, c, b]);
    }
  }

  /// Adds the quad [a] [b] [c] [d] (corners in order round it).
  void quad(int a, int b, int c, int d) {
    triangle(a, b, c);
    triangle(a, c, d);
  }

  /// Texture coordinates of a point ([x], [y], [z]) on a flat face facing
  /// ([nx], [ny], [nz]): projected onto the face, in metres (of the world
  /// for [ShapeUv.metres]), right and down as seen from outside it.
  (double, double) planar(
    double x,
    double y,
    double z,
    double nx,
    double ny,
    double nz,
  ) {
    final px = x * uv.sx, py = y * uv.sy, pz = z * uv.sz;
    var mx = nx / uv.sx, my = ny / uv.sy, mz = nz / uv.sz;
    final len = math.sqrt(mx * mx + my * my + mz * mz);
    if (len > 0) {
      mx /= len;
      my /= len;
      mz /= len;
    }
    if (my.abs() >= 0.9) {
      // A floor or a ceiling: north is up the texture.
      return my < 0 ? (px, -pz) : (-px, -pz);
    }
    // A wall: right is (−n) × up, down is right × n.
    final rl = math.sqrt(mz * mz + mx * mx);
    final rx = -mz / rl, rz = mx / rl;
    final dx = -rz * my, dy = rz * mx - rx * mz, dz = rx * my;
    return (px * rx + pz * rz, px * dx + py * dy + pz * dz);
  }

  /// A flat face through [corners] (x, y, z each, in order round a convex
  /// outline) facing ([nx], [ny], [nz]); its texture spans it once when
  /// [stretch] and the layout is natural, else by [planar].
  void face(
    List<(double, double, double)> corners,
    double nx,
    double ny,
    double nz, {
    bool stretch = false,
  }) {
    final first = vertexCount;
    for (final (x, y, z) in corners) {
      final (u, v) = planar(x, y, z, nx, ny, nz);
      vertex(x, y, z, nx, ny, nz, u, v);
    }
    if (stretch && !uv.metres) fitTexture(first, vertexCount);
    for (var k = 1; k + 1 < corners.length; k++) {
      triangle(first, first + k, first + k + 1);
    }
  }

  /// The six faces of the box from ([x0], [y0], [z0]) to ([x1], [y1],
  /// [z1]); each face's texture spans it once when [stretch].
  void box(
    double x0,
    double y0,
    double z0,
    double x1,
    double y1,
    double z1, {
    bool stretch = false,
  }) {
    face(
      [(x1, y0, z0), (x1, y0, z1), (x1, y1, z1), (x1, y1, z0)],
      1,
      0,
      0,
      stretch: stretch,
    );
    face(
      [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)],
      -1,
      0,
      0,
      stretch: stretch,
    );
    face(
      [(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)],
      0,
      1,
      0,
      stretch: stretch,
    );
    face(
      [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
      0,
      -1,
      0,
      stretch: stretch,
    );
    face(
      [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
      0,
      0,
      1,
      stretch: stretch,
    );
    face(
      [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)],
      0,
      0,
      -1,
      stretch: stretch,
    );
  }

  /// Rescales the texture coordinates of vertices [from] to [to] to span
  /// 0..1 each way.
  void fitTexture(int from, int to) {
    var u0 = double.infinity,
        v0 = double.infinity,
        u1 = -double.infinity,
        v1 = -double.infinity;
    for (var i = from; i < to; i++) {
      u0 = math.min(u0, _t[i * 2]);
      u1 = math.max(u1, _t[i * 2]);
      v0 = math.min(v0, _t[i * 2 + 1]);
      v1 = math.max(v1, _t[i * 2 + 1]);
    }
    final du = u1 - u0, dv = v1 - v0;
    for (var i = from; i < to; i++) {
      _t[i * 2] = du > 0 ? (_t[i * 2] - u0) / du : 0;
      _t[i * 2 + 1] = dv > 0 ? (_t[i * 2 + 1] - v0) / dv : 0;
    }
  }

  /// Sweeps [profile] round the Y axis in [segments] steps: a surface of
  /// revolution. Each profile point is (distance from the axis, y, the
  /// normal's outward part, the normal's y part, distance along the
  /// profile); the texture wraps once round ([aroundLength] metres for
  /// [ShapeUv.metres]) and runs down the profile (by its distance, over
  /// [profileLength] when natural).
  void lathe(
    List<(double, double, double, double, double)> profile,
    int segments, {
    required double aroundLength,
    required double profileLength,
  }) {
    final first = vertexCount;
    final rows = profile.length;
    for (final (r, y, nr, ny, s) in profile) {
      final v = uv.metres ? s : (profileLength > 0 ? s / profileLength : 0.0);
      for (var i = 0; i <= segments; i++) {
        final a = 2 * math.pi * i / segments;
        final c = math.cos(a), sn = math.sin(a);
        final u = i / segments;
        vertex(
          r * c,
          y,
          r * sn,
          nr * c,
          ny,
          nr * sn,
          uv.metres ? u * aroundLength : u,
          v,
        );
      }
    }
    final stride = segments + 1;
    for (var k = 0; k + 1 < rows; k++) {
      for (var i = 0; i < segments; i++) {
        final a = first + k * stride + i;
        final b = a + 1;
        final c = a + stride + 1;
        final d = a + stride;
        quad(a, b, c, d);
      }
    }
  }

  /// A flat disc of [radius] at height [y] facing up (−Y) or down (+Y),
  /// in [segments] steps; its texture spans it once when natural.
  void disc(double radius, double y, int segments, {required bool up}) {
    final ny = up ? -1.0 : 1.0;
    final first = vertexCount;
    final (cu, cv) = planar(0, y, 0, 0, ny, 0);
    vertex(0, y, 0, 0, ny, 0, cu, cv);
    for (var i = 0; i <= segments; i++) {
      final a = 2 * math.pi * i / segments;
      final x = radius * math.cos(a), z = radius * math.sin(a);
      final (u, v) = planar(x, y, z, 0, ny, 0);
      vertex(x, y, z, 0, ny, 0, u, v);
    }
    if (!uv.metres) fitTexture(first, vertexCount);
    for (var i = 0; i < segments; i++) {
      triangle(first, first + 1 + i, first + 2 + i);
    }
  }

  /// The mesh built so far.
  ShapeMesh build() => ShapeMesh(
    positions: Float32List.fromList(_p),
    normals: Float32List.fromList(_n),
    uvs: Float32List.fromList(_t),
    indices: Uint32List.fromList(_i),
  );
}

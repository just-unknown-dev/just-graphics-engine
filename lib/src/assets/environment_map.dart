import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

/// An image of linear RGB floats: a Radiance `.hdr` decoded.
final class HdrImage {
  /// [width] × [height] pixels in [rgb], three floats each, rows top to
  /// bottom.
  const HdrImage(this.width, this.height, this.rgb);

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Three floats a pixel.
  final Float32List rgb;
}

/// What lights a scene from all round, ready for the GPU: a small cube map
/// of what surrounds it — level 0 the sky itself, each smaller level blurred
/// for a rougher surface (GGX, prefiltered here on the CPU) — and its
/// diffuse light as nine spherical-harmonic coefficients.
///
/// Directions are the engine's (+Y down). The faces follow the cube-map
/// convention every graphics API shares (+X, -X, +Y, -Y, +Z, -Z; see
/// [directionOf]), so a world direction samples the cube as it is.
final class EnvironmentMapData {
  EnvironmentMapData._(this.size, this.levels, this.sh);

  /// Width and height of a face of level 0, in pixels.
  final int size;

  /// The levels, largest first; each six faces of RGBA floats (four a
  /// pixel, rows from the first in memory).
  final List<List<Float32List>> levels;

  /// Diffuse light: nine RGB coefficients (27 floats), already scaled so
  /// that `Σ sh[i]·Yᵢ(n)` is the light a white Lambert surface facing `n`
  /// gives back.
  final Float32List sh;

  /// How many levels it has.
  int get levelCount => levels.length;

  /// The surroundings of a gradient sky, as the sky shader draws it:
  /// [zenith] overhead, [horizon] around, [ground] below (linear RGB).
  static Future<EnvironmentMapData> fromGradient(
    (double, double, double) zenith,
    (double, double, double) horizon,
    (double, double, double) ground, {
    int size = 32,
  }) => compute(_gradientJob, (zenith, horizon, ground, size));

  /// The surroundings in an equirectangular panorama [image] (the top row
  /// straight up, the middle column ahead along +Z).
  static Future<EnvironmentMapData> fromEquirect(
    HdrImage image, {
    int size = 64,
  }) => compute(_equirectJob, (image, size));

  /// [fromGradient] on this isolate.
  static EnvironmentMapData gradientNow(
    (double, double, double) zenith,
    (double, double, double) horizon,
    (double, double, double) ground, {
    int size = 32,
  }) => _gradientJob((zenith, horizon, ground, size));

  /// Builds a map from what [radiance] says each direction holds.
  static EnvironmentMapData build(
    void Function(double x, double y, double z, Float32List out) radiance, {
    int size = 32,
  }) {
    final base = List.generate(6, (_) => Float32List(size * size * 4));
    final c = Float32List(3);
    for (var face = 0; face < 6; face++) {
      final out = base[face];
      for (var row = 0; row < size; row++) {
        for (var col = 0; col < size; col++) {
          final (x, y, z) = directionOf(
            face,
            (col + 0.5) / size,
            (row + 0.5) / size,
          );
          final len = math.sqrt(x * x + y * y + z * z);
          radiance(x / len, y / len, z / len, c);
          final o = (row * size + col) * 4;
          out[o] = c[0];
          out[o + 1] = c[1];
          out[o + 2] = c[2];
          out[o + 3] = 1;
        }
      }
    }
    final levels = <List<Float32List>>[base];
    final count = (math.log(size) / math.ln2).floor() + 1;
    for (var m = 1; m < count; m++) {
      levels.add(_prefilter(base, size, size >> m, m / (count - 1)));
    }
    return EnvironmentMapData._(size, levels, _shOf(base, size));
  }

  /// The direction (not normalized) a face's texel at [s], [t] (0–1, s
  /// along a row, t down the rows) stands for.
  static (double, double, double) directionOf(int face, double s, double t) {
    final a = 2 * s - 1, b = 2 * t - 1;
    return switch (face) {
      0 => (1.0, -b, -a),
      1 => (-1.0, -b, a),
      2 => (a, 1.0, b),
      3 => (a, -1.0, -b),
      4 => (a, -b, 1.0),
      _ => (-a, -b, -1.0),
    };
  }

  /// The face and texel coordinates (0–1) direction ([x], [y], [z]) falls
  /// on: [directionOf] undone.
  static (int, double, double) faceOf(double x, double y, double z) {
    final ax = x.abs(), ay = y.abs(), az = z.abs();
    int face;
    double sc, tc, ma;
    if (ax >= ay && ax >= az) {
      face = x > 0 ? 0 : 1;
      sc = x > 0 ? -z : z;
      tc = -y;
      ma = ax;
    } else if (ay >= az) {
      face = y > 0 ? 2 : 3;
      sc = x;
      tc = y > 0 ? z : -z;
      ma = ay;
    } else {
      face = z > 0 ? 4 : 5;
      sc = z > 0 ? x : -x;
      tc = -y;
      ma = az;
    }
    return (face, 0.5 * (sc / ma + 1), 0.5 * (tc / ma + 1));
  }

  /// Level [level]'s colour in direction ([x], [y], [z]), nearest texel.
  void sample(int level, double x, double y, double z, Float32List out) =>
      _sampleFaces(levels[level], size >> level, x, y, z, out);

  /// Diffuse light (RGB, for a white Lambert surface) facing [n] (unit).
  (double, double, double) irradiance(double nx, double ny, double nz) {
    final y = _basis(nx, ny, nz);
    var r = 0.0, g = 0.0, b = 0.0;
    for (var i = 0; i < 9; i++) {
      r += sh[i * 3] * y[i];
      g += sh[i * 3 + 1] * y[i];
      b += sh[i * 3 + 2] * y[i];
    }
    return (r, g, b);
  }

  /// Level [level]'s face [face] as half floats (RGBA, 8 bytes a pixel):
  /// what an `rgba16f` texture takes.
  ByteData halfFloatsOf(int level, int face) {
    final src = levels[level][face];
    final out = Uint16List(src.length);
    for (var i = 0; i < src.length; i++) {
      out[i] = toHalf(src[i]);
    }
    return out.buffer.asByteData();
  }

  /// [value] as an IEEE half float's bits (rounded; clamped to its range).
  static int toHalf(double value) {
    final f = Float32List(1)..[0] = value;
    final bits = Uint32List.view(f.buffer)[0];
    final sign = (bits >> 16) & 0x8000;
    var exponent = ((bits >> 23) & 0xFF) - 127 + 15;
    var mantissa = bits & 0x7FFFFF;
    if (exponent <= 0) {
      if (exponent < -10) return sign;
      mantissa = (mantissa | 0x800000) >> (1 - exponent);
      return sign | ((mantissa + 0x1000) >> 13);
    }
    if (exponent >= 31) return sign | 0x7BFF; // the largest finite half
    final half = sign | (exponent << 10) | ((mantissa + 0x1000) >> 13);
    // Rounding up a mantissa of all ones carries into the exponent, as it
    // should; past the largest finite, clamp.
    return (half & 0x7C00) == 0x7C00 ? sign | 0x7BFF : half;
  }
}

EnvironmentMapData _gradientJob(
  (
    (double, double, double),
    (double, double, double),
    (double, double, double),
    int,
  )
  job,
) {
  final (zenith, horizon, ground, size) = job;
  double mixf(double a, double b, double t) => a + (b - a) * t;
  return EnvironmentMapData.build((x, y, z, out) {
    final up = -y;
    final (a, b, t) = up >= 0
        ? (horizon, zenith, math.pow(up, 0.6).toDouble())
        : (horizon, ground, math.pow(-up, 0.4).toDouble());
    out[0] = mixf(a.$1, b.$1, t);
    out[1] = mixf(a.$2, b.$2, t);
    out[2] = mixf(a.$3, b.$3, t);
  }, size: size);
}

EnvironmentMapData _equirectJob((HdrImage, int) job) {
  final (image, size) = job;
  return EnvironmentMapData.build((x, y, z, out) {
    // Longitude about the up axis from +Z; latitude from straight up (-Y).
    final u = 0.5 + math.atan2(x, z) / (2 * math.pi);
    final v = math.acos((-y).clamp(-1.0, 1.0)) / math.pi;
    final px = (u * image.width).floor().clamp(0, image.width - 1);
    final py = (v * image.height).floor().clamp(0, image.height - 1);
    final o = (py * image.width + px) * 3;
    out[0] = image.rgb[o];
    out[1] = image.rgb[o + 1];
    out[2] = image.rgb[o + 2];
  }, size: size);
}

void _sampleFaces(
  List<Float32List> faces,
  int size,
  double x,
  double y,
  double z,
  Float32List out,
) {
  final (face, s, t) = EnvironmentMapData.faceOf(x, y, z);
  final col = (s * size).floor().clamp(0, size - 1);
  final row = (t * size).floor().clamp(0, size - 1);
  final o = (row * size + col) * 4;
  final f = faces[face];
  out[0] = f[o];
  out[1] = f[o + 1];
  out[2] = f[o + 2];
}

/// One level blurred for [roughness]: GGX importance samples of [base]
/// about each texel's direction (normal = view = reflection, as the split
/// sum assumes), weighted by n·l.
List<Float32List> _prefilter(
  List<Float32List> base,
  int baseSize,
  int size,
  double roughness,
) {
  final a = roughness * roughness;
  const samples = 48;
  final out = List.generate(6, (_) => Float32List(size * size * 4));
  final c = Float32List(3);
  for (var face = 0; face < 6; face++) {
    for (var row = 0; row < size; row++) {
      for (var col = 0; col < size; col++) {
        var (nx, ny, nz) = EnvironmentMapData.directionOf(
          face,
          (col + 0.5) / size,
          (row + 0.5) / size,
        );
        final len = math.sqrt(nx * nx + ny * ny + nz * nz);
        nx /= len;
        ny /= len;
        nz /= len;
        // A frame about n.
        final (ux, uy, uz) = nz.abs() < 0.999
            ? (0.0, 0.0, 1.0)
            : (1.0, 0.0, 0.0);
        var tx = uy * nz - uz * ny,
            ty = uz * nx - ux * nz,
            tz = ux * ny - uy * nx;
        final tl = math.sqrt(tx * tx + ty * ty + tz * tz);
        tx /= tl;
        ty /= tl;
        tz /= tl;
        final bx = ny * tz - nz * ty,
            by = nz * tx - nx * tz,
            bz = nx * ty - ny * tx;
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0;
        for (var i = 0; i < samples; i++) {
          // Hammersley.
          final e1 = i / samples;
          var bits = i;
          bits = ((bits << 16) | (bits >> 16)) & 0xFFFFFFFF;
          bits =
              (((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1)) &
              0xFFFFFFFF;
          bits =
              (((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2)) &
              0xFFFFFFFF;
          bits =
              (((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4)) &
              0xFFFFFFFF;
          bits =
              (((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8)) &
              0xFFFFFFFF;
          final e2 = bits / 4294967296.0;
          final phi = 2 * math.pi * e1;
          final cosTheta = math.sqrt((1 - e2) / (1 + (a * a - 1) * e2));
          final sinTheta = math.sqrt(1 - cosTheta * cosTheta);
          final hx =
              tx * math.cos(phi) * sinTheta +
              bx * math.sin(phi) * sinTheta +
              nx * cosTheta;
          final hy =
              ty * math.cos(phi) * sinTheta +
              by * math.sin(phi) * sinTheta +
              ny * cosTheta;
          final hz =
              tz * math.cos(phi) * sinTheta +
              bz * math.sin(phi) * sinTheta +
              nz * cosTheta;
          final vh = nx * hx + ny * hy + nz * hz;
          final lx = 2 * vh * hx - nx,
              ly = 2 * vh * hy - ny,
              lz = 2 * vh * hz - nz;
          final nl = nx * lx + ny * ly + nz * lz;
          if (nl <= 0) continue;
          _sampleFaces(base, baseSize, lx, ly, lz, c);
          r += c[0] * nl;
          g += c[1] * nl;
          b += c[2] * nl;
          w += nl;
        }
        final o = (row * size + col) * 4;
        final dst = out[face];
        dst[o] = w > 0 ? r / w : 0;
        dst[o + 1] = w > 0 ? g / w : 0;
        dst[o + 2] = w > 0 ? b / w : 0;
        dst[o + 3] = 1;
      }
    }
  }
  return out;
}

/// The real SH basis up to band 2 at a unit direction.
List<double> _basis(double x, double y, double z) => [
  0.282095,
  0.488603 * y,
  0.488603 * z,
  0.488603 * x,
  1.092548 * x * y,
  1.092548 * y * z,
  0.315392 * (3 * z * z - 1),
  1.092548 * x * z,
  0.546274 * (x * x - y * y),
];

/// The base level's radiance projected onto SH and turned into Lambert
/// light: each band scaled by Aₗ/π (1, 2/3, 1/4).
Float32List _shOf(List<Float32List> base, int size) {
  final sum = Float64List(27);
  var total = 0.0;
  for (var face = 0; face < 6; face++) {
    final f = base[face];
    for (var row = 0; row < size; row++) {
      for (var col = 0; col < size; col++) {
        final s = (col + 0.5) / size, t = (row + 0.5) / size;
        var (x, y, z) = EnvironmentMapData.directionOf(face, s, t);
        final a = 2 * s - 1, b = 2 * t - 1;
        final weight = 1 / math.pow(1 + a * a + b * b, 1.5);
        final len = math.sqrt(x * x + y * y + z * z);
        x /= len;
        y /= len;
        z /= len;
        final basis = _basis(x, y, z);
        final o = (row * size + col) * 4;
        for (var i = 0; i < 9; i++) {
          sum[i * 3] += f[o] * basis[i] * weight;
          sum[i * 3 + 1] += f[o + 1] * basis[i] * weight;
          sum[i * 3 + 2] += f[o + 2] * basis[i] * weight;
        }
        total += weight;
      }
    }
  }
  // The weights sum to 4π over the sphere.
  final norm = 4 * math.pi / total;
  const band = [1.0, 2 / 3, 2 / 3, 2 / 3, 0.25, 0.25, 0.25, 0.25, 0.25];
  return Float32List.fromList([
    for (var i = 0; i < 27; i++) sum[i] * norm * band[i ~/ 3],
  ]);
}

/// Decodes a Radiance `.hdr` (RGBE, flat or run-length encoded, `-Y w +X h`
/// orientation) into linear RGB floats.
HdrImage decodeRadianceHdr(Uint8List bytes) {
  var at = 0;
  String line() {
    final start = at;
    while (at < bytes.length && bytes[at] != 0x0A) {
      at++;
    }
    final text = String.fromCharCodes(bytes, start, at);
    at++;
    return text;
  }

  final magic = line();
  if (!magic.startsWith('#?')) {
    throw const FormatException('Not a Radiance HDR file.');
  }
  var format = '';
  while (true) {
    final l = line();
    if (l.isEmpty) break;
    if (l.startsWith('FORMAT=')) format = l.substring(7);
    if (at >= bytes.length) {
      throw const FormatException('The HDR header never ends.');
    }
  }
  if (format.isNotEmpty && format != '32-bit_rle_rgbe') {
    throw FormatException('Unsupported HDR format "$format".');
  }
  final size = RegExp(r'^-Y (\d+) \+X (\d+)$').firstMatch(line().trim());
  if (size == null) {
    throw const FormatException('Only "-Y h +X w" HDR images are read.');
  }
  final height = int.parse(size.group(1)!), width = int.parse(size.group(2)!);
  final rgbe = Uint8List(width * height * 4);
  final scan = Uint8List(width * 4);
  for (var y = 0; y < height; y++) {
    final rle =
        width >= 8 &&
        width < 32768 &&
        at + 4 <= bytes.length &&
        bytes[at] == 2 &&
        bytes[at + 1] == 2 &&
        (bytes[at + 2] & 0x80) == 0;
    if (rle) {
      at += 4;
      for (var c = 0; c < 4; c++) {
        var x = 0;
        while (x < width) {
          var count = bytes[at++];
          if (count > 128) {
            count -= 128;
            final value = bytes[at++];
            for (var i = 0; i < count; i++) {
              scan[(x++) * 4 + c] = value;
            }
          } else {
            for (var i = 0; i < count; i++) {
              scan[(x++) * 4 + c] = bytes[at++];
            }
          }
        }
      }
    } else {
      for (var i = 0; i < width * 4; i++) {
        scan[i] = bytes[at++];
      }
    }
    rgbe.setRange(y * width * 4, (y + 1) * width * 4, scan);
  }
  final rgb = Float32List(width * height * 3);
  for (var i = 0; i < width * height; i++) {
    final e = rgbe[i * 4 + 3];
    if (e == 0) continue;
    final f = math.pow(2, e - 136).toDouble();
    rgb[i * 3] = rgbe[i * 4] * f;
    rgb[i * 3 + 1] = rgbe[i * 4 + 1] * f;
    rgb[i * 3 + 2] = rgbe[i * 4 + 2] * f;
  }
  return HdrImage(width, height, rgb);
}

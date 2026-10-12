import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

/// Fills one uniform block's bytes: 32-bit floats and ints in host byte
/// order, at member offsets taken from shader reflection.
///
/// The engine's math is 64-bit (`Matrix4` stores doubles); the GPU reads
/// 32-bit floats. Writing converts, so no 32-bit copy of a matrix is kept.
/// Reuse one writer per block and [clear] it each frame: writing allocates
/// nothing.
final class UniformWriter {
  /// A writer for a block of [sizeInBytes].
  UniformWriter(int sizeInBytes) : bytes = ByteData(sizeInBytes);

  /// The block's bytes, ready to upload.
  final ByteData bytes;

  /// The block's size in bytes.
  int get sizeInBytes => bytes.lengthInBytes;

  /// Zeroes every byte.
  void clear() {
    for (var i = 0; i < bytes.lengthInBytes; i += 4) {
      bytes.setUint32(i, 0);
    }
  }

  /// Writes a 4×4 matrix (column-major, as both the engine and GLSL store
  /// it) at [offset].
  void matrix4(int offset, Matrix4 m) {
    final s = m.storage;
    for (var i = 0; i < 16; i++) {
      bytes.setFloat32(offset + i * 4, s[i], Endian.host);
    }
  }

  /// Writes a `vec4` at [offset].
  void vec4(int offset, double x, double y, double z, double w) {
    bytes
      ..setFloat32(offset, x, Endian.host)
      ..setFloat32(offset + 4, y, Endian.host)
      ..setFloat32(offset + 8, z, Endian.host)
      ..setFloat32(offset + 12, w, Endian.host);
  }

  /// Writes [v] as a `vec4` with [w] at [offset]. Uniform blocks pad a
  /// `vec3` to 16 bytes anyway, so blocks declare `vec4`s and this fills one.
  void vector3(int offset, Vector3 v, [double w = 0]) =>
      vec4(offset, v.x, v.y, v.z, w);

  /// Writes a `float` at [offset].
  void float(int offset, double value) =>
      bytes.setFloat32(offset, value, Endian.host);

  /// Writes an `int` at [offset].
  void int32(int offset, int value) =>
      bytes.setInt32(offset, value, Endian.host);

  /// Writes 32-bit floats from [values] starting at [offset].
  void floats(int offset, List<double> values) {
    for (var i = 0; i < values.length; i++) {
      bytes.setFloat32(offset + i * 4, values[i], Endian.host);
    }
  }
}

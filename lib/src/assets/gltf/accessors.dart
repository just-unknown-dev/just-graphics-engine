import 'dart:typed_data';

// glTF accessor component types.
const int _byte = 5120;
const int _ubyte = 5121;
const int _short = 5122;
const int _ushort = 5123;
const int _uint = 5125;
const int _float = 5126;

const Map<String, int> _components = {
  'SCALAR': 1,
  'VEC2': 2,
  'VEC3': 3,
  'VEC4': 4,
  'MAT2': 4,
  'MAT3': 9,
  'MAT4': 16,
};

int _componentSize(int type) => switch (type) {
  _byte || _ubyte => 1,
  _short || _ushort => 2,
  _uint || _float => 4,
  _ => throw FormatException('Unknown accessor componentType $type.'),
};

/// Reads glTF accessors out of a file's buffers, following the spec's rules
/// for component types, normalisation, strides and sparse substitution.
final class AccessorReader {
  /// A reader over [json] whose buffers are [buffers], in buffer order.
  AccessorReader(this.json, this.buffers);

  /// The glTF JSON.
  final Map<String, dynamic> json;

  /// Every buffer's bytes, by buffer index.
  final List<ByteData> buffers;

  List<dynamic> get _accessors =>
      json['accessors'] as List<dynamic>? ?? const [];

  List<dynamic> get _views => json['bufferViews'] as List<dynamic>? ?? const [];

  Map<String, dynamic> _accessor(int i) {
    if (i < 0 || i >= _accessors.length) {
      throw FormatException('No accessor $i.');
    }
    return _accessors[i] as Map<String, dynamic>;
  }

  /// How many elements accessor [index] has.
  int count(int index) => _accessor(index)['count'] as int;

  /// How many components each element of accessor [index] has (VEC3: 3).
  int width(int index) {
    final type = _accessor(index)['type'] as String;
    return _components[type] ?? (throw FormatException('Unknown type $type.'));
  }

  /// The accessor's `min` and `max`, when the file gives them.
  (List<double>, List<double>)? minMax(int index) {
    final a = _accessor(index);
    final min = a['min'] as List<dynamic>?, max = a['max'] as List<dynamic>?;
    if (min == null || max == null) return null;
    return (
      [for (final v in min) (v as num).toDouble()],
      [for (final v in max) (v as num).toDouble()],
    );
  }

  /// The bytes of buffer view [index].
  ByteData bufferView(int index) {
    if (index < 0 || index >= _views.length) {
      throw FormatException('No bufferView $index.');
    }
    final view = _views[index] as Map<String, dynamic>;
    final buffer = view['buffer'] as int;
    if (buffer >= buffers.length) throw FormatException('No buffer $buffer.');
    final data = buffers[buffer];
    final offset = view['byteOffset'] as int? ?? 0;
    final length = view['byteLength'] as int;
    if (offset + length > data.lengthInBytes) {
      throw FormatException('bufferView $index runs past its buffer.');
    }
    return ByteData.sublistView(data, offset, offset + length);
  }

  /// Accessor [index] as floats: integers converted, normalised ones mapped
  /// to 0..1 or -1..1, sparse values substituted. Elements are packed
  /// ([width] floats each).
  Float32List floats(int index) {
    final a = _accessor(index);
    final n = a['count'] as int;
    final w = width(index);
    final out = Float32List(n * w);
    final viewIndex = a['bufferView'] as int?;
    final componentType = a['componentType'] as int;
    final normalized = a['normalized'] as bool? ?? false;
    if (viewIndex != null) {
      _read(
        bufferView(viewIndex),
        stride:
            (_views[viewIndex] as Map<String, dynamic>)['byteStride'] as int?,
        offset: a['byteOffset'] as int? ?? 0,
        count: n,
        width: w,
        componentType: componentType,
        normalized: normalized,
        into: out,
      );
    }
    // Without a bufferView the accessor starts as zeros.
    final sparse = a['sparse'] as Map<String, dynamic>?;
    if (sparse != null) {
      final k = sparse['count'] as int;
      final idx = sparse['indices'] as Map<String, dynamic>;
      final vals = sparse['values'] as Map<String, dynamic>;
      final where = Float32List(k);
      _read(
        bufferView(idx['bufferView'] as int),
        stride: null,
        offset: idx['byteOffset'] as int? ?? 0,
        count: k,
        width: 1,
        componentType: idx['componentType'] as int,
        normalized: false,
        into: where,
      );
      final values = Float32List(k * w);
      _read(
        bufferView(vals['bufferView'] as int),
        stride: null,
        offset: vals['byteOffset'] as int? ?? 0,
        count: k,
        width: w,
        componentType: componentType,
        normalized: normalized,
        into: values,
      );
      for (var i = 0; i < k; i++) {
        final target = where[i].toInt();
        if (target < 0 || target >= n) {
          throw FormatException(
            'Sparse index $target out of range in accessor $index.',
          );
        }
        for (var c = 0; c < w; c++) {
          out[target * w + c] = values[i * w + c];
        }
      }
    }
    return out;
  }

  /// Accessor [index] as vertex indices.
  Uint32List indices(int index) {
    final type = _accessor(index)['componentType'] as int;
    if (type != _ubyte && type != _ushort && type != _uint) {
      throw FormatException('Index accessor $index is not unsigned integers.');
    }
    final values = floats(index);
    final out = Uint32List(values.length);
    for (var i = 0; i < values.length; i++) {
      out[i] = values[i].toInt();
    }
    return out;
  }

  static void _read(
    ByteData view, {
    required int? stride,
    required int offset,
    required int count,
    required int width,
    required int componentType,
    required bool normalized,
    required Float32List into,
  }) {
    final size = _componentSize(componentType);
    final step = stride ?? size * width;
    var o = 0;
    for (var e = 0; e < count; e++) {
      final base = offset + e * step;
      for (var c = 0; c < width; c++) {
        final at = base + c * size;
        into[o++] = switch (componentType) {
          _float => view.getFloat32(at, Endian.little),
          _ubyte =>
            normalized
                ? view.getUint8(at) / 255.0
                : view.getUint8(at).toDouble(),
          _byte =>
            normalized
                ? (view.getInt8(at) / 127.0).clamp(-1.0, 1.0)
                : view.getInt8(at).toDouble(),
          _ushort =>
            normalized
                ? view.getUint16(at, Endian.little) / 65535.0
                : view.getUint16(at, Endian.little).toDouble(),
          _short =>
            normalized
                ? (view.getInt16(at, Endian.little) / 32767.0).clamp(-1.0, 1.0)
                : view.getInt16(at, Endian.little).toDouble(),
          _uint => view.getUint32(at, Endian.little).toDouble(),
          _ => throw FormatException('Unknown componentType $componentType.'),
        };
      }
    }
  }
}

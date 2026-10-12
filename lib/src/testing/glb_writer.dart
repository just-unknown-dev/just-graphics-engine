import 'dart:convert';
import 'dart:typed_data';

/// Writes small glTF files for tests, so fixtures are generated, not
/// checked-in binaries.
///
/// Add accessors, meshes, materials, nodes and images, then call [toGlb]
/// (one file) or [toGltf] (JSON with the buffer as a `data:` URI).
final class GlbWriter {
  final BytesBuilder _bin = BytesBuilder();

  /// The glTF JSON being built; tests may add to it directly.
  final Map<String, dynamic> json = {
    'asset': {'version': '2.0', 'generator': 'just_graphics_engine GlbWriter'},
  };

  List<dynamic> _list(String key) =>
      (json[key] ??= <dynamic>[]) as List<dynamic>;

  int _view(Uint8List bytes, {int? target, int? stride}) {
    while (_bin.length % 4 != 0) {
      _bin.addByte(0);
    }
    final offset = _bin.length;
    _bin.add(bytes);
    final views = _list('bufferViews');
    views.add({
      'buffer': 0,
      'byteOffset': offset,
      'byteLength': bytes.length,
      'target': ?target,
      'byteStride': ?stride,
    });
    return views.length - 1;
  }

  /// Adds float data as an accessor of [type] (`VEC3`, …). Positions get
  /// `min`/`max` when [withBounds].
  int addFloats(List<double> values, String type, {bool withBounds = false}) {
    final data = Float32List.fromList(values);
    final width = const {
      'SCALAR': 1,
      'VEC2': 2,
      'VEC3': 3,
      'VEC4': 4,
      'MAT4': 16,
    }[type]!;
    final accessor = <String, dynamic>{
      'bufferView': _view(data.buffer.asUint8List(), target: 34962),
      'componentType': 5126,
      'count': values.length ~/ width,
      'type': type,
    };
    if (withBounds) {
      final min = List<double>.filled(width, double.infinity);
      final max = List<double>.filled(width, double.negativeInfinity);
      for (var i = 0; i < values.length; i++) {
        final c = i % width;
        if (values[i] < min[c]) min[c] = values[i];
        if (values[i] > max[c]) max[c] = values[i];
      }
      accessor['min'] = min;
      accessor['max'] = max;
    }
    return _add('accessors', accessor);
  }

  /// Adds integer data of [componentType] (5121 ubyte, 5122 short,
  /// 5123 ushort, 5125 uint), optionally [normalized].
  int addInts(
    List<int> values,
    String type,
    int componentType, {
    bool normalized = false,
    bool indices = false,
  }) {
    final width = const {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[type]!;
    final ByteData data;
    switch (componentType) {
      case 5121:
        data = ByteData(values.length);
        for (var i = 0; i < values.length; i++) {
          data.setUint8(i, values[i]);
        }
      case 5122:
        data = ByteData(values.length * 2);
        for (var i = 0; i < values.length; i++) {
          data.setInt16(i * 2, values[i], Endian.little);
        }
      case 5123:
        data = ByteData(values.length * 2);
        for (var i = 0; i < values.length; i++) {
          data.setUint16(i * 2, values[i], Endian.little);
        }
      default:
        data = ByteData(values.length * 4);
        for (var i = 0; i < values.length; i++) {
          data.setUint32(i * 4, values[i], Endian.little);
        }
    }
    return _add('accessors', {
      'bufferView': _view(
        data.buffer.asUint8List(),
        target: indices ? 34963 : 34962,
      ),
      'componentType': componentType,
      'normalized': ?(normalized ? true : null),
      'count': values.length ~/ width,
      'type': type,
    });
  }

  /// Adds an accessor of [count] zeros whose [indices] are replaced by
  /// [values] (a sparse accessor with no bufferView).
  int addSparse(
    int count,
    String type,
    List<int> indices,
    List<double> values,
  ) {
    final idx = Uint32List.fromList(indices);
    final val = Float32List.fromList(values);
    return _add('accessors', {
      'componentType': 5126,
      'count': count,
      'type': type,
      'sparse': {
        'count': indices.length,
        'indices': {
          'bufferView': _view(idx.buffer.asUint8List()),
          'componentType': 5125,
        },
        'values': {'bufferView': _view(val.buffer.asUint8List())},
      },
    });
  }

  /// Adds an embedded image of [mimeType].
  int addImage(Uint8List bytes, {String mimeType = 'image/png'}) =>
      _add('images', {'bufferView': _view(bytes), 'mimeType': mimeType});

  /// Adds a texture of [image].
  int addTexture(int image, {Map<String, dynamic>? sampler}) {
    final texture = <String, dynamic>{'source': image};
    if (sampler != null) texture['sampler'] = _add('samplers', sampler);
    return _add('textures', texture);
  }

  /// Adds a material from raw glTF JSON.
  int addMaterial(Map<String, dynamic> material) => _add('materials', material);

  /// Adds a mesh of [primitives] (raw glTF JSON).
  int addMesh(List<Map<String, dynamic>> primitives, {String? name}) =>
      _add('meshes', {'primitives': primitives, 'name': ?name});

  /// Adds a node (raw glTF JSON).
  int addNode(Map<String, dynamic> node) => _add('nodes', node);

  /// Adds a skin (raw glTF JSON: `joints`, `inverseBindMatrices`, …).
  int addSkin(Map<String, dynamic> skin) => _add('skins', skin);

  /// Adds an animation (raw glTF JSON: `channels`, `samplers`, `name`).
  int addAnimation(Map<String, dynamic> animation) =>
      _add('animations', animation);

  /// Sets the scene to [roots].
  void setScene(List<int> roots) {
    json['scenes'] = [
      {'nodes': roots},
    ];
    json['scene'] = 0;
  }

  int _add(String key, Map<String, dynamic> value) {
    final list = _list(key);
    list.add(value);
    return list.length - 1;
  }

  Uint8List _buffer() {
    while (_bin.length % 4 != 0) {
      _bin.addByte(0);
    }
    return _bin.toBytes();
  }

  /// The model as one `.glb`.
  Uint8List toGlb() {
    final bin = _buffer();
    final out = Map<String, dynamic>.of(json)
      ..['buffers'] = [
        {'byteLength': bin.length},
      ];
    var jsonBytes = utf8.encode(jsonEncode(out));
    final pad = (4 - jsonBytes.length % 4) % 4;
    jsonBytes = Uint8List.fromList([...jsonBytes, ...List.filled(pad, 0x20)]);
    final total = 12 + 8 + jsonBytes.length + 8 + bin.length;
    final b = BytesBuilder()
      ..add(_u32s([0x46546c67, 2, total]))
      ..add(_u32s([jsonBytes.length, 0x4e4f534a]))
      ..add(jsonBytes)
      ..add(_u32s([bin.length, 0x004e4942]))
      ..add(bin);
    return b.toBytes();
  }

  /// The model as `.gltf` JSON with its buffer inline as a `data:` URI, or
  /// as [bufferUri] when given (the caller serves those bytes).
  (String, Uint8List) toGltf({String? bufferUri}) {
    final bin = _buffer();
    final out = Map<String, dynamic>.of(json)
      ..['buffers'] = [
        {
          'byteLength': bin.length,
          'uri':
              bufferUri ??
              'data:application/octet-stream;base64,${base64Encode(bin)}',
        },
      ];
    return (jsonEncode(out), bin);
  }

  static Uint8List _u32s(List<int> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setUint32(i * 4, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

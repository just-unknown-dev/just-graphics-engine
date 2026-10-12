import 'dart:convert';
import 'dart:typed_data';

const int _glbMagic = 0x46546c67; // 'glTF'
const int _jsonChunk = 0x4e4f534a; // 'JSON'
const int _binChunk = 0x004e4942; // 'BIN\0'

/// Whether [bytes] start like a binary glTF (`.glb`) file.
bool isGlb(Uint8List bytes) =>
    bytes.length >= 12 &&
    ByteData.sublistView(bytes).getUint32(0, Endian.little) == _glbMagic;

/// A `.glb` split into its JSON and its binary chunk.
final class GlbParts {
  /// The two chunks.
  const GlbParts(this.json, this.binary);

  /// The glTF JSON.
  final Map<String, dynamic> json;

  /// The `BIN` chunk (buffer 0 when it has no `uri`), or null.
  final ByteData? binary;
}

/// Splits a binary glTF into its chunks. Throws a [FormatException] on a
/// malformed file.
GlbParts parseGlb(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 12 || data.getUint32(0, Endian.little) != _glbMagic) {
    throw const FormatException('Not a GLB file (bad magic).');
  }
  final version = data.getUint32(4, Endian.little);
  if (version != 2) {
    throw FormatException('GLB version $version is not supported (only 2).');
  }
  final total = data.getUint32(8, Endian.little);
  if (total > bytes.length) {
    throw FormatException(
      'Truncated GLB: the header says $total bytes, the file has '
      '${bytes.length}.',
    );
  }
  Map<String, dynamic>? json;
  ByteData? binary;
  var offset = 12;
  while (offset + 8 <= total) {
    final length = data.getUint32(offset, Endian.little);
    final type = data.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    if (start + length > total) {
      throw const FormatException('A GLB chunk runs past the end of the file.');
    }
    if (type == _jsonChunk) {
      json =
          jsonDecode(
                utf8.decode(
                  Uint8List.sublistView(bytes, start, start + length),
                ),
              )
              as Map<String, dynamic>;
    } else if (type == _binChunk && binary == null) {
      binary = ByteData.sublistView(bytes, start, start + length);
    }
    // Chunks are 4-byte aligned.
    offset = start + ((length + 3) & ~3);
  }
  if (json == null) throw const FormatException('The GLB has no JSON chunk.');
  return GlbParts(json, binary);
}

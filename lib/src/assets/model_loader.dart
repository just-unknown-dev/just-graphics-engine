import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import 'gltf/glb.dart';
import 'gltf/gltf_to_model.dart';
import 'model_data.dart';

/// Fetches a file a glTF refers to, by the URI the file used (relative to
/// the model).
typedef ModelFetch = Future<Uint8List> Function(String uri);

/// Reads a glTF model — `.glb` or `.gltf` — into [ModelData].
///
/// External buffers and images are fetched with [fetch] first; the heavy
/// part (reading accessors, building vertices) then runs in a background
/// isolate. Throws [UnsupportedError] for a file this renderer can't show
/// (Draco, meshopt, KTX2) and [FormatException] for a malformed one.
Future<ModelData> loadModelData(
  Uint8List bytes, {
  required String name,
  ModelFetch? fetch,
}) async {
  final Map<String, dynamic> json;
  ByteData? binary;
  if (isGlb(bytes)) {
    final parts = parseGlb(bytes);
    json = parts.json;
    binary = parts.binary;
  } else {
    json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  final uris = <String, Uint8List>{};
  for (final uri in externalUris(json)) {
    if (fetch == null) {
      throw StateError('$name refers to "$uri", and no fetch was given.');
    }
    uris[uri] = await fetch(Uri.decodeFull(uri));
  }

  final buffers = <ByteData>[];
  for (final buffer
      in (json['buffers'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()) {
    final uri = buffer['uri'] as String?;
    if (uri == null) {
      buffers.add(
        binary ?? (throw FormatException('$name: a buffer has no data.')),
      );
    } else if (uri.startsWith('data:')) {
      buffers.add(ByteData.sublistView(decodeDataUri(uri)));
    } else {
      buffers.add(ByteData.sublistView(uris[uri]!));
    }
  }

  return compute(_build, _Job(json, GltfSources(buffers, uris), name));
}

final class _Job {
  const _Job(this.json, this.sources, this.name);

  final Map<String, dynamic> json;
  final GltfSources sources;
  final String name;
}

ModelData _build(_Job job) =>
    gltfToModel(job.json, job.sources, name: job.name);

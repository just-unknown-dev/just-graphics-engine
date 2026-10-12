import 'device.dart';
import 'formats.dart';

/// A pipeline the renderer needs, named by its shaders in a bundle.
final class PipelineSpec {
  /// The pipeline of [vertex] and [fragment] reading [layout].
  const PipelineSpec(this.vertex, this.fragment, {this.layout});

  /// Vertex shader name.
  final String vertex;

  /// Fragment shader name.
  final String fragment;

  /// Vertex layout, or null for the vertex shader's own interleaved inputs.
  final GpuVertexLayout? layout;

  @override
  bool operator ==(Object other) =>
      other is PipelineSpec &&
      other.vertex == vertex &&
      other.fragment == fragment &&
      other.layout?.key == layout?.key;

  @override
  int get hashCode => Object.hash(vertex, fragment, layout?.key);

  @override
  String toString() => 'PipelineSpec($vertex+$fragment)';
}

/// Every pipeline a renderer draws with, created up front.
///
/// Creating a pipeline is synchronous and the first one of a kind can stall
/// a frame for 100 ms or more, so the renderer creates its fixed set here,
/// behind a loading screen, instead of on the first frame that needs one.
final class PipelineSet {
  PipelineSet._(this._pipelines);

  /// Loads [bundle] on [device] and creates a pipeline for each of [specs].
  /// Throws a [StateError] naming any shader the bundle lacks.
  static Future<PipelineSet> load(
    GpuDevice device,
    String bundle,
    Iterable<PipelineSpec> specs,
  ) async {
    final library = await device.loadShaderLibrary(bundle);
    final pipelines = <PipelineSpec, GpuPipeline>{};
    for (final spec in specs) {
      final vertex = library[spec.vertex];
      final fragment = library[spec.fragment];
      if (vertex == null || fragment == null) {
        throw StateError(
          '$bundle has no ${vertex == null ? spec.vertex : spec.fragment}.',
        );
      }
      pipelines[spec] = device.pipeline(vertex, fragment, layout: spec.layout);
    }
    return PipelineSet._(pipelines);
  }

  final Map<PipelineSpec, GpuPipeline> _pipelines;

  /// How many pipelines it holds.
  int get length => _pipelines.length;

  /// The pipeline for [spec]; it must have been in the set.
  GpuPipeline operator [](PipelineSpec spec) =>
      _pipelines[spec] ??
      (throw ArgumentError.value(spec, 'spec', 'Not in the set'));
}

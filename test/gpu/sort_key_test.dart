import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/src/gpu/sort_key.dart';

void main() {
  int opaque({int phase = 1, int pipeline = 0, int material = 0, int mesh = 0, int depth = 0}) =>
      SortKey.opaque(
        phase: phase,
        pipeline: pipeline,
        material: material,
        mesh: mesh,
        depth: depth,
      );

  test('fields order phase, pipeline, material, mesh, then depth', () {
    expect(opaque(phase: 0, pipeline: 4095), lessThan(opaque(phase: 1)));
    expect(opaque(pipeline: 1), greaterThan(opaque(material: 65535, mesh: 4095, depth: 255)));
    expect(opaque(material: 1), greaterThan(opaque(mesh: 4095, depth: 255)));
    expect(opaque(mesh: 1), greaterThan(opaque(depth: 255)));
    expect(opaque(depth: 3), greaterThan(opaque(depth: 2)));
  });

  test('the largest key stays exact as a JavaScript number', () {
    final max = SortKey.opaque(
      phase: SortKey.maxPhase,
      pipeline: SortKey.maxPipeline,
      material: SortKey.maxMaterial,
      mesh: SortKey.maxMesh,
      depth: SortKey.maxDepth,
    );
    expect(max, lessThan(1 << 52));
    expect(max, (1 << 52) - 1);
    expect(SortKey.phaseOf(max), SortKey.maxPhase);
  });

  test('draws that differ only in depth share a batch', () {
    expect(SortKey.batchOf(opaque(mesh: 7, depth: 0)), SortKey.batchOf(opaque(mesh: 7, depth: 200)));
    expect(SortKey.batchOf(opaque(mesh: 7)), isNot(SortKey.batchOf(opaque(mesh: 8))));
  });

  test('transparent keys order by depth before pipeline', () {
    int t({int depth = 0, int pipeline = 0}) => SortKey.transparent(
      phase: 3,
      depth: depth,
      pipeline: pipeline,
      material: 0,
      mesh: 0,
    );
    expect(t(depth: 1), greaterThan(t(depth: 0, pipeline: 4095)));
    expect(SortKey.phaseOf(t(depth: 255, pipeline: 4095)), 3);
  });

  test('out-of-range fields throw', () {
    expect(() => opaque(phase: 16), throwsRangeError);
    expect(() => opaque(material: -1), throwsRangeError);
  });

  test('depth buckets run from 0 at near to 255 at far', () {
    expect(SortKey.depthBucket(0.1, 0.1, 100), 0);
    expect(SortKey.depthBucket(100, 0.1, 100), 255);
    expect(SortKey.depthBucket(500, 0.1, 100), 255);
    expect(SortKey.depthBucket(1, 1, 1), 0);
  });
}

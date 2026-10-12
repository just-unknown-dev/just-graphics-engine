@Tags(['gpu'])
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:just_graphics_engine/testing.dart';

const _size = 32;

/// Positions given straight in the engine's clip space (y down, depth 0..1),
/// flipped once for the GPU.
Matrix4 _engineClip() {
  final m = Matrix4.identity();
  ClipFixup.flipY(m, m);
  return m;
}

ByteData _floats(List<double> values) =>
    Float32List.fromList(values).buffer.asByteData();

ByteData _frame(GpuPipeline pipeline, Matrix4 mvp, [List<double> tint = const [1, 1, 1, 1]]) {
  final block = pipeline.uniformBlock('Frame')!;
  final w = UniformWriter(block.sizeInBytes)
    ..matrix4(block.offsetOf('mvp')!, mvp)
    ..vec4(block.offsetOf('tint')!, tint[0], tint[1], tint[2], tint[3]);
  return w.bytes;
}

/// A colour and depth target of [_size] squared, plus the targets for a pass.
(GpuTexture, GpuRenderTargets) _targets(GpuDevice device, {int samples = 1}) {
  final color = device.createTexture(
    const GpuTextureDesc(width: _size, height: _size, renderTarget: true),
  );
  final depth = device.createTexture(
    GpuTextureDesc(
      width: _size,
      height: _size,
      format: device.caps.depthFormat,
      storage: GpuStorage.transient,
      renderTarget: true,
      shaderRead: false,
      samples: samples,
    ),
  );
  if (samples == 1) {
    return (
      color,
      GpuRenderTargets(
        [GpuColorTarget(color, clear: (0, 0, 0, 1))],
        depth: GpuDepthTarget(depth),
      ),
    );
  }
  final msaa = device.createTexture(
    GpuTextureDesc(
      width: _size,
      height: _size,
      storage: GpuStorage.transient,
      renderTarget: true,
      shaderRead: false,
      samples: samples,
    ),
  );
  return (
    color,
    GpuRenderTargets(
      [
        GpuColorTarget(
          msaa,
          clear: (0, 0, 0, 1),
          resolve: color,
          store: GpuStore.resolve,
        ),
      ],
      depth: GpuDepthTarget(depth),
    ),
  );
}

void main() {
  final skip = gpuUnavailableReason();
  late GpuDevice device;
  late GpuShaderLibrary core;

  setUpAll(() async {
    if (skip != null) return;
    device = createGpuDevice()!;
    core = await device.loadShaderLibrary('core.shaderbundle');
  });

  GpuPipeline unlit() => device.pipeline(
    core['UnlitVertex']!,
    core['UnlitFragment']!,
  );

  GpuTexture solid(List<int> rgba, {int width = 1, int height = 1}) {
    final t = device.createTexture(
      GpuTextureDesc(width: width, height: height, storage: GpuStorage.host),
    );
    t.upload(Uint8List.fromList(rgba).buffer.asByteData());
    return t;
  }

  /// A quad from (x0, y0) to (x1, y1) at depth z, uv 0..1 across it.
  List<double> quad(double x0, double y0, double x1, double y1, double z) => [
    x0, y0, z, 0, 0, x1, y0, z, 1, 0, x1, y1, z, 1, 1, //
    x0, y0, z, 0, 0, x1, y1, z, 1, 1, x0, y1, z, 0, 1,
  ];

  test('the device reports its capabilities', () {
    expect(device.caps.backend, 'flutter_gpu');
    expect(device.caps.uniformAlignment, greaterThan(0));
    // ignore: avoid_print
    print('GPU_CAPS ${device.caps}');
  }, skip: skip);

  test('engine clip space: (-1,-1) is the top-left, texture row 0 is v = 0', () async {
    final pipeline = unlit();
    final texture = solid([
      255, 0, 0, 255, 0, 255, 0, 255, //
      0, 0, 255, 255, 255, 255, 255, 255,
    ], width: 2, height: 2);
    final vertices = device.createBuffer(_floats(quad(-1, -1, 1, 1, 0.5)));
    final (color, targets) = _targets(device);

    device.beginFrame();
    final commands = device.commands();
    final pass = commands.beginPass(targets)
      ..setPipeline(pipeline)
      ..setVertexBuffer(0, vertices.view())
      ..setUniforms('Frame', device.frameData(_frame(pipeline, _engineClip())))
      ..setTexture('base_texture', texture, sampler: GpuSampler.nearestClamp)
      ..setDepth(test: false, write: false)
      ..setCull(GpuCull.none);
    pass.draw(6);
    expect(await commands.submit(), isTrue);

    final px = await readPixels(color.toImage());
    expect(colorClose(px.atFraction(0.25, 0.25), [255, 0, 0, 255]), isTrue,
        reason: 'top-left ${px.atFraction(0.25, 0.25)}');
    expect(colorClose(px.atFraction(0.75, 0.25), [0, 255, 0, 255]), isTrue,
        reason: 'top-right ${px.atFraction(0.75, 0.25)}');
    expect(colorClose(px.atFraction(0.25, 0.75), [0, 0, 255, 255]), isTrue,
        reason: 'bottom-left ${px.atFraction(0.25, 0.75)}');
    expect(colorClose(px.atFraction(0.75, 0.75), [255, 255, 255, 255]), isTrue,
        reason: 'bottom-right ${px.atFraction(0.75, 0.75)}');
  }, skip: skip);

  test('depth: a near quad drawn first hides a far one drawn after', () async {
    final pipeline = unlit();
    final white = solid([255, 255, 255, 255]);
    final near = device.createBuffer(_floats(quad(-0.5, -0.5, 0.5, 0.5, 0.2)));
    final far = device.createBuffer(_floats(quad(-1, -1, 1, 1, 0.8)));
    final (color, targets) = _targets(device);

    device.beginFrame();
    final commands = device.commands();
    final pass = commands.beginPass(targets)
      ..setPipeline(pipeline)
      ..setTexture('base_texture', white)
      ..setDepth()
      ..setCull(GpuCull.none);
    pass
      ..setVertexBuffer(0, near.view())
      ..setUniforms('Frame', device.frameData(_frame(pipeline, _engineClip(), [1, 0, 0, 1])))
      ..draw(6)
      ..setVertexBuffer(0, far.view())
      ..setUniforms('Frame', device.frameData(_frame(pipeline, _engineClip(), [0, 1, 0, 1])))
      ..draw(6);
    expect(await commands.submit(), isTrue);

    final px = await readPixels(color.toImage());
    expect(colorClose(px.atFraction(0.5, 0.5), [255, 0, 0, 255]), isTrue,
        reason: 'centre ${px.atFraction(0.5, 0.5)}');
    expect(colorClose(px.at(1, 1), [0, 255, 0, 255]), isTrue,
        reason: 'corner ${px.at(1, 1)}');
  }, skip: skip);

  test('instancing: one draw, four instances, four quadrants', () async {
    final pipeline = device.pipeline(
      core['InstancedVertex']!,
      core['ColorFragment']!,
      layout: const GpuVertexLayout([
        GpuVertexBufferLayout(
          stride: 12,
          attributes: [GpuVertexAttribute('position', GpuVertexFormat.float3, 0)],
        ),
        GpuVertexBufferLayout(
          stride: 32,
          perInstance: true,
          attributes: [
            GpuVertexAttribute('instance_offset', GpuVertexFormat.float4, 0),
            GpuVertexAttribute('instance_color', GpuVertexFormat.float4, 16),
          ],
        ),
      ]),
    );
    const h = 0.4;
    final positions = device.createBuffer(_floats([
      -h, -h, 0.5, h, -h, 0.5, h, h, 0.5, //
      -h, -h, 0.5, h, h, 0.5, -h, h, 0.5,
    ]));
    final instances = _floats([
      -0.5, -0.5, 0, 0, 1, 0, 0, 1, // top-left red
      0.5, -0.5, 0, 0, 0, 1, 0, 1, // top-right green
      -0.5, 0.5, 0, 0, 0, 0, 1, 1, // bottom-left blue
      0.5, 0.5, 0, 0, 1, 1, 1, 1, // bottom-right white
    ]);
    final (color, targets) = _targets(device);

    device.beginFrame();
    final commands = device.commands();
    final pass = commands.beginPass(targets)
      ..setPipeline(pipeline)
      ..setVertexBuffer(0, positions.view())
      ..setVertexBuffer(1, device.frameData(instances))
      ..setUniforms('Frame', device.frameData(_frame(pipeline, _engineClip())))
      ..setDepth(test: false, write: false)
      ..setCull(GpuCull.none);
    pass.draw(6, instances: 4);
    expect(await commands.submit(), isTrue);

    final px = await readPixels(color.toImage());
    expect(colorClose(px.atFraction(0.25, 0.25), [255, 0, 0, 255]), isTrue,
        reason: 'top-left ${px.atFraction(0.25, 0.25)}');
    expect(colorClose(px.atFraction(0.75, 0.25), [0, 255, 0, 255]), isTrue,
        reason: 'top-right ${px.atFraction(0.75, 0.25)}');
    expect(colorClose(px.atFraction(0.25, 0.75), [0, 0, 255, 255]), isTrue,
        reason: 'bottom-left ${px.atFraction(0.25, 0.75)}');
    expect(colorClose(px.atFraction(0.75, 0.75), [255, 255, 255, 255]), isTrue,
        reason: 'bottom-right ${px.atFraction(0.75, 0.75)}');
    expect(colorClose(px.atFraction(0.5, 0.5), [0, 0, 0, 255]), isTrue,
        reason: 'gap between instances ${px.atFraction(0.5, 0.5)}');
  }, skip: skip);

  test('4x MSAA resolves a slanted edge to partial coverage', () async {
    if (!device.caps.msaa) {
      markTestSkipped('No offscreen MSAA on this device.');
      return;
    }
    final pipeline = unlit();
    final white = solid([255, 255, 255, 255]);
    // A thin sliver with a shallow slanted edge.
    final vertices = device.createBuffer(_floats([
      -1, -1, 0.5, 0, 0, 1, -1, 0.5, 0, 0, -1, 1, 0.5, 0, 0,
    ]));
    final (color, targets) = _targets(device, samples: 4);

    device.beginFrame();
    final commands = device.commands();
    final pass = commands.beginPass(targets)
      ..setPipeline(pipeline)
      ..setVertexBuffer(0, vertices.view())
      ..setUniforms('Frame', device.frameData(_frame(pipeline, _engineClip())))
      ..setTexture('base_texture', white)
      ..setDepth(test: false, write: false)
      ..setCull(GpuCull.none);
    pass.draw(3);
    expect(await commands.submit(), isTrue);

    final px = await readPixels(color.toImage());
    var partial = 0;
    for (var y = 0; y < _size; y++) {
      for (var x = 0; x < _size; x++) {
        final r = px.at(x, y)[0];
        if (r > 20 && r < 235) partial++;
      }
    }
    expect(partial, greaterThan(_size ~/ 2), reason: 'antialiased edge pixels');
  }, skip: skip);

  test('back-face culling keeps a triangle that faces the camera', () async {
    final pipeline = unlit();
    final white = solid([255, 255, 255, 255]);
    final projection = Matrix4.zero()..setPerspectiveYDown(math.pi / 2, 1, 0.1, 100);
    ClipFixup.flipY(projection, projection);
    // View space is the engine's: x right, y down, looking along +z. The
    // order a, c, b winds around a normal pointing back at the camera (-z).
    final a = [-2.0, -2.0, 5.0], b = [2.0, -2.0, 5.0], c = [0.0, 2.0, 5.0];
    List<double> tri(List<double> p, List<double> q, List<double> r) =>
        [...p, 0, 0, ...q, 0, 0, ...r, 0, 0];
    final facing = device.createBuffer(_floats(tri(a, c, b)));
    final away = device.createBuffer(_floats(tri(a, b, c)));

    Future<List<int>> centre(GpuBuffer triangle) async {
      final (color, targets) = _targets(device);
      device.beginFrame();
      final commands = device.commands();
      final pass = commands.beginPass(targets)
        ..setPipeline(pipeline)
        ..setVertexBuffer(0, triangle.view())
        ..setUniforms('Frame', device.frameData(_frame(pipeline, projection)))
        ..setTexture('base_texture', white)
        ..setDepth(test: false, write: false)
        ..setCull(GpuCull.back, frontClockwise: ClipFixup.frontFaceIsClockwise);
      pass.draw(3);
      expect(await commands.submit(), isTrue);
      return (await readPixels(color.toImage())).atFraction(0.5, 0.5);
    }

    expect(await centre(facing), [255, 255, 255, 255], reason: 'front face kept');
    expect(await centre(away), [0, 0, 0, 255], reason: 'back face culled');
  }, skip: skip);
}

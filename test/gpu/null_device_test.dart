import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_dart/just_dart.dart';
import 'package:just_graphics_engine/gpu.dart';
import 'package:vector_math/vector_math_64.dart' show Vector4;

void main() {
  final shaders = {
    'V': {
      'Frame': const NullUniformBlock('Frame', 80, {'mvp': 0, 'tint': 64}),
    },
    'F': const <String, NullUniformBlock>{},
  };

  group('the null device', () {
    test('caches pipelines by shaders and layout', () async {
      final device = NullGpuDevice(shaders: shaders);
      final library = await device.loadShaderLibrary('core.shaderbundle');
      final v = library['V']!, f = library['F']!;
      final a = device.pipeline(v, f);
      expect(device.pipeline(v, f), same(a));
      const layout = GpuVertexLayout([
        GpuVertexBufferLayout(
          stride: 12,
          attributes: [GpuVertexAttribute('position', GpuVertexFormat.float3, 0)],
        ),
      ]);
      final b = device.pipeline(v, f, layout: layout);
      expect(b, isNot(same(a)));
      expect(device.pipeline(v, f, layout: layout), same(b));
      expect(device.pipelineCount, 2);
      expect(library['missing'], isNull);
    });

    test('records a pass, and checks uniform blocks exist', () async {
      final device = NullGpuDevice(shaders: shaders);
      final library = await device.loadShaderLibrary('core.shaderbundle');
      final pipeline = device.pipeline(library['V']!, library['F']!);
      final target = device.createTexture(
        const GpuTextureDesc(width: 4, height: 4, renderTarget: true),
      );
      device
        ..clearLog()
        ..beginFrame();
      final commands = device.commands();
      final pass = commands.beginPass(GpuRenderTargets([GpuColorTarget(target)]))
        ..setPipeline(pipeline)
        ..setUniforms('Frame', device.frameData(ByteData(80)));
      pass.draw(3, instances: 2);
      expect(() => pass.setUniforms('Nope', device.frameData(ByteData(4))), throwsArgumentError);
      expect(await commands.submit(), isTrue);
      expect(device.drawCount, 1);
      expect(device.frameBytes, 84);
      expect(device.log, containsAllInOrder(['beginFrame', 'pass 1 colour', 'draw 3 x2', 'submit']));
    });
  });

  group('the pipeline set', () {
    test('creates every pipeline up front and finds them by spec', () async {
      final device = NullGpuDevice(shaders: shaders);
      const spec = PipelineSpec('V', 'F');
      final set = await PipelineSet.load(device, 'core.shaderbundle', [spec, spec]);
      expect(set.length, 1);
      expect(device.pipelineCount, 1);
      expect(set[const PipelineSpec('V', 'F')], isNotNull);
      expect(() => set[const PipelineSpec('F', 'V')], throwsArgumentError);
    });

    test('names a shader the bundle lacks', () async {
      final device = NullGpuDevice(shaders: shaders);
      expect(
        PipelineSet.load(device, 'core.shaderbundle', [const PipelineSpec('V', 'Missing')]),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Missing'))),
      );
    });
  });

  group('the uniform writer', () {
    test('writes a 64-bit matrix as 32-bit floats, column-major', () {
      final m = Matrix4.identity()..setTranslationRaw(1, 2, 3);
      final w = UniformWriter(80)..matrix4(0, m)..vec4(64, 0.5, 0, 0, 1);
      final f = w.bytes.buffer.asFloat32List();
      expect(f.sublist(12, 15), [1, 2, 3]);
      expect(f[0], 1);
      expect(f[16], 0.5);
      w.clear();
      expect(w.bytes.buffer.asFloat32List().every((v) => v == 0), isTrue);
    });
  });

  group('the clip fix-up', () {
    test('negates clip y and nothing else', () {
      final p = Matrix4.zero()..setPerspectiveYDown(1, 1.5, 0.1, 100);
      final fixed = Matrix4.zero();
      ClipFixup.flipY(p, fixed);
      final point = Vector4(0.3, -0.7, 5, 1);
      final a = p.transformed(point), b = fixed.transformed(point);
      expect(b.x, closeTo(a.x, 1e-12));
      expect(b.y, closeTo(-a.y, 1e-12));
      expect(b.z, closeTo(a.z, 1e-12));
      expect(b.w, closeTo(a.w, 1e-12));
    });
  });

  group('the render-target pool', () {
    const desc = GpuTextureDesc(width: 64, height: 64, renderTarget: true);

    test('reuses a target the next frame instead of creating one', () {
      final device = NullGpuDevice();
      final pool = RenderTargetPool(device);
      final first = pool.acquire(desc);
      pool.endFrame();
      expect(pool.acquire(desc), same(first));
      expect(pool.acquire(desc), isNot(same(first)), reason: 'one is taken');
      expect(pool.size, 2);
    });

    test('drops a target unused for longer than keepFrames', () {
      final pool = RenderTargetPool(NullGpuDevice(), keepFrames: 2);
      pool.acquire(desc);
      pool.endFrame();
      for (var i = 0; i < 3; i++) {
        pool.endFrame();
      }
      expect(pool.size, 0);
    });

    test('keeps targets of different descriptions apart', () {
      final pool = RenderTargetPool(NullGpuDevice());
      final a = pool.acquire(desc);
      pool.endFrame();
      final b = pool.acquire(desc.copyWith(format: GpuFormat.rgba16f));
      expect(b, isNot(same(a)));
    });
  });

  test('a full mip chain halves down to 1x1', () {
    expect(GpuTextureDesc.fullMipCount(1, 1), 1);
    expect(GpuTextureDesc.fullMipCount(256, 64), 9);
    expect(GpuTextureDesc.fullMipCount(300, 200), 9);
  });

  test('formats know whether they are compressed, depth or sRGB', () {
    expect(GpuFormat.etc2Rgba8Srgb.isCompressed, isTrue);
    expect(GpuFormat.etc2Rgba8Srgb.isSrgb, isTrue);
    expect(GpuFormat.etc2Rgba8Srgb.compression, GpuCompression.etc2);
    expect(GpuFormat.rgba16f.isCompressed, isFalse);
    expect(GpuFormat.depth24Stencil8.isDepth, isTrue);
    expect(GpuFormat.rgba8.compression, isNull);
  });
}

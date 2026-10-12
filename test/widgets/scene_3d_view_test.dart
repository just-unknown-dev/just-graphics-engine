// Scene3DView on a device that records instead of drawing: it renders
// every frame at its own size in pixels, or once per build when still, and
// shows the reason when there is no renderer.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/just_graphics_engine.dart';

int _presents(NullGpuDevice device) =>
    device.log.where((e) => e == 'submit+present').length;

Widget _sized(Widget child, {double ratio = 2}) => MediaQuery(
  data: MediaQueryData(devicePixelRatio: ratio),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: SizedBox(width: 200, height: 100, child: child)),
  ),
);

void main() {
  late NullGpuDevice device;
  late Renderer3D renderer;

  setUp(() async {
    device = NullGpuDevice(shaders: rendererNullShaders);
    renderer = (await Renderer3D.tryCreate(device: device))!;
  });

  testWidgets('without a renderer it says why', (tester) async {
    await tester.pumpWidget(
      _sized(
        Scene3DView(
          renderer: null,
          scene: RenderScene(),
          camera: RenderView(),
          unsupportedReason: 'No GPU in this test.',
        ),
      ),
    );
    expect(find.textContaining('3D is not available here.'), findsOneWidget);
    expect(find.textContaining('No GPU in this test.'), findsOneWidget);
  });

  testWidgets('it draws every frame, at its size in pixels', (tester) async {
    final camera = RenderView();
    var frames = 0;
    Size? seen;
    await tester.pumpWidget(
      _sized(
        Scene3DView(
          renderer: renderer,
          scene: RenderScene(),
          camera: camera,
          fieldOfView: math.pi / 3,
          renderScale: 0.5,
          onFrame: (elapsed, size) {
            frames++;
            seen = size;
          },
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(seen, const Size(200, 100));
    // 200 x 100 logical pixels, ratio 2, half the resolution.
    expect((camera.width, camera.height), (200, 100));
    expect(frames, greaterThanOrEqualTo(3));
    expect(_presents(device), frames);
    // A perspective projection: w takes -z.
    expect(camera.projection.storage[11], isNot(0));
  });

  testWidgets('still, it draws only when rebuilt', (tester) async {
    Widget view() => _sized(
      Scene3DView(
        renderer: renderer,
        scene: RenderScene(),
        camera: RenderView(),
        animate: false,
      ),
    );
    await tester.pumpWidget(view());
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final first = _presents(device);
    expect(first, 1);
    await tester.pumpWidget(view());
    expect(_presents(device), 2);
  });

  test('tryCreate gives a renderer or says why there is none', () async {
    String? reason;
    final made = await Renderer3D.tryCreate(onUnsupported: (r) => reason = r);
    // Plain `flutter test` has no Flutter GPU; with --enable-flutter-gpu it
    // does.
    expect(made == null, reason != null);
  });
}

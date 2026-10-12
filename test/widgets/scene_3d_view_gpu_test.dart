// Scene3DView with Flutter GPU: an unlit red box made with MeshBuilder,
// drawn in front of the sky. Skips without a GPU; run with
//   flutter test --enable-impeller --enable-flutter-gpu --tags gpu
@Tags(['gpu'])
library;

import 'dart:math' as math;

// Flutter's rendering library has a RenderView of its own.
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/just_graphics_engine.dart';
import 'package:just_graphics_engine/testing.dart';

void main() {
  // Real time, as in an app: a frame's GPU work completes on its own.
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  final skip = gpuUnavailableReason();

  testWidgets('it draws the scene: a red box in the middle, sky around it', (
    tester,
  ) async {
    final renderer = (await Renderer3D.tryCreate())!;
    final mesh = (MeshBuilder()..box(-0.5, -0.5, -0.5, 0.5, 0.5, 0.5)).build();
    final scene = RenderScene();
    scene.instances.add(
      MeshInstance(
        renderer.uploader.uploadPrimitive(mesh.toPrimitive()),
        renderer.uploader.material(
          const MaterialData(baseColor: (1.0, 0.0, 0.0, 1.0), unlit: true),
        ),
        Matrix4.identity(),
      ),
    );
    final camera = RenderView()..lookAt(Vector3(0, 0, -4), Vector3.zero());
    Future<bool>? drawn;
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Scene3DView(
            renderer: renderer,
            scene: scene,
            camera: camera,
            fieldOfView: math.pi / 3,
            onRendered: (done) => drawn = done,
          ),
        ),
      ),
    );
    // The first frame presents; the next draws the presented image.
    for (var i = 0; i < 2; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await drawn!;
    }

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final px = await readPixels(image);
    final middle = px.atFraction(0.5, 0.5);
    final top = px.atFraction(0.5, 0.03);
    expect(middle[0], greaterThan(200), reason: 'red box: $middle');
    expect(middle[1], lessThan(60), reason: 'red box: $middle');
    expect(top[2], greaterThan(top[0]), reason: 'blue sky: $top');
    expect(renderer.stats.drawCalls, greaterThanOrEqualTo(1));
    image.dispose();
  }, skip: skip != null);
}

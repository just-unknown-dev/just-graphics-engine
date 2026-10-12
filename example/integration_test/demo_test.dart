// The example in a real window, drawing with Flutter GPU:
//   flutter test integration_test -d windows
// Saves what it drew to build/demo.png (desktop). Also runs on a phone:
//   flutter test integration_test -d <device id>
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_graphics_engine/just_graphics_engine.dart';
import 'package:just_graphics_engine/testing.dart';
import 'package:just_graphics_engine_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the demo is drawn: sky above, ground below, models between', (
    tester,
  ) async {
    String? reason;
    final (renderer, demo) = (await tester.runAsync(() async {
      final renderer = await Renderer3D.tryCreate(
        onUnsupported: (r) => reason = r,
      );
      return (
        renderer,
        renderer == null ? null : await Demo.load(renderer, rootBundle),
      );
    }))!;
    expect(renderer, isNotNull, reason: reason);

    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: DemoApp(renderer: renderer, demo: demo),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final png = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    ))!;
    // Desktop only: a phone's working directory is not writable.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      File('build/demo.png').writeAsBytesSync(png.buffer.asUint8List());
    }
    final px = (await tester.runAsync(() => readPixels(image)))!;

    final sky = px.atFraction(0.5, 0.04);
    final ground = px.atFraction(0.5, 0.97);
    // ignore: avoid_print
    print(
      'DEMO ${image.width}x${image.height} sky $sky ground $ground '
      '${renderer!.stats}',
    );
    expect(sky[2], greaterThan(sky[0]), reason: 'blue sky at the top: $sky');
    expect(
      ground[1],
      greaterThan(ground[2]),
      reason: 'green ground at the bottom: $ground',
    );
    expect(renderer.stats.instances, greaterThanOrEqualTo(8));
    expect(renderer.stats.skinnedInstances, 4);
  });
}

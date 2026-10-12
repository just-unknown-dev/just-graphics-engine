// The example's scene loads and its models load, with or without a GPU.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/just_graphics_engine.dart';
import 'package:just_graphics_engine_example/main.dart';

/// Reads assets from the example's folder, as the app's bundle would.
final class _DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(File(key).readAsBytesSync()));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the demo places every model, the mannequins skinned', () async {
    final device = NullGpuDevice(shaders: rendererNullShaders);
    final renderer = (await Renderer3D.tryCreate(device: device))!;
    final demo = await Demo.load(renderer, _DiskBundle());
    final scene = demo.scene;
    // Ten static models, the spinning crate, and two mannequins of two
    // primitives each, skinned.
    expect(scene.instances, hasLength(14));
    expect(scene.instances.where((i) => i.skin != null), hasLength(4));
    expect(scene.lights, hasLength(1));
    expect(scene.sun.enabled, isTrue);

    // The spinning crate comes after the nine models that stand still.
    final spinner = scene.instances[9];
    final before = spinner.world.clone();
    demo.update(0.5);
    expect(spinner.world, isNot(before));
  });

  testWidgets('without Flutter GPU the app says why', (tester) async {
    await tester.pumpWidget(
      const DemoApp(
        renderer: null,
        demo: null,
        unsupportedReason: 'No GPU here.',
      ),
    );
    expect(find.textContaining('No GPU here.'), findsOneWidget);
  });
}

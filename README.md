A 3D renderer for Flutter, built on `package:flutter_gpu`, Flutter's low-level GPU API powered by Impeller: glTF 2.0 models, physically based materials, lights and shadows, skinned animation and image-based light, drawn into any Flutter app. Requires Flutter 3.47.1 or newer.

It stands alone, and it is also the 3D of [just_game_engine](https://pub.dev/packages/just_game_engine) (from its 2.0.0).

## Features

- `gpu.dart`: a GPU layer over Flutter GPU (`GpuDevice`), with a null device for tests and headless runs.
- `assets.dart`: glTF 2.0 loading (`.glb` and `.gltf`) into `ModelData`, and meshes made in code (`MeshBuilder`).
- `renderer.dart`: `Renderer3D`, a forward renderer with physically based materials, lights, two cascades of sun shadows, skinned meshes, a sky or skybox, image-based light, fog, bloom, HDR, MSAA or FXAA, dynamic resolution and instancing.
- Model import: settings beside a model (scale, texture size, material changes) and a cooked copy (`.jmodel`) a game loads with no glTF parsing or image decoding.
- Animation: glTF skins and clips (linear, step and cubic-spline keys), sampled into a `PosedModel`'s pose and blended.
- `Scene3DView`: a widget that draws a `RenderScene` from a camera every frame, or says why it can't.
- `testing.dart`: GPU test helpers and `GlbWriter` for generated fixtures.

See `example/` for models, walking characters, lights, shadows and a sky, drawn by a `Scene3DView` from an orbiting camera.

## Platform support

`flutter_gpu` needs the Impeller renderer and an opt-in switch on every platform.

| Platform | Status |
|---|---|
| Windows | Supported (Impeller on OpenGL ES over ANGLE). Release builds and `flutter test` both render. |
| Linux | Expected to work the same way as Windows (Impeller on OpenGL ES); **untested**. |
| Android | Supported on the **Vulkan** backend only. On devices without Vulkan, Impeller falls back to OpenGL ES, where Flutter GPU draws can hang ([flutter/flutter#177873](https://github.com/flutter/flutter/issues/177873)); treat those devices as unsupported. |
| iOS | Expected to work (Impeller on Metal); **untested** (no Apple hardware). |
| macOS | Expected to work (Impeller on Metal); **untested** (no Apple hardware). |
| Web | No 3D drawing: Flutter GPU is not available on the web. Web builds (JavaScript and WebAssembly) still compile and run, and `Scene3DView` shows a short note where the 3D image would be. |

On unsupported platforms `Renderer3D.tryCreate` (and `createGpuDevice` beneath it) returns null and reports why, so the rest of the app runs as usual.

## Getting started

```sh
flutter pub add just_graphics_engine
```

Its build hook compiles the package's shaders with your Flutter SDK when the app builds. Then enable Flutter GPU on the platforms you target.

### Windows

In `windows/runner/main.cpp`, after the `DartProject` is created:

```cpp
project.set_enable_flutter_gpu(true);
```

`flutter run --enable-flutter-gpu` also works, but only in debug builds; release builds ignore command-line engine switches.

### Linux

In `linux/runner/my_application.cc`, on the `FlDartProject`:

```c
fl_dart_project_set_enable_flutter_gpu(project, TRUE);
```

### Android

Force the Vulkan backend. Add to your app's `android/app/src/main/AndroidManifest.xml`, inside `<application>`:

```xml
<meta-data
    android:name="io.flutter.embedding.android.EnableImpeller"
    android:value="true" />
<meta-data
    android:name="io.flutter.embedding.android.EnableFlutterGPU"
    android:value="true" />
<meta-data
    android:name="io.flutter.embedding.android.ImpellerBackend"
    android:value="vulkan" />
```

Devices (and emulators) without Vulkan still fall back to OpenGL ES. `createGpuDevice` detects that and returns null with the reason, so the app runs without the 3D view instead of hanging.

### iOS / macOS

Set `FLTEnableFlutterGPU` to `true` in `Info.plist` (and `FLTEnableImpeller` on macOS).

## Testing

GPU tests are tagged `gpu` and skip themselves when Flutter GPU is not enabled, so `flutter test` stays green. To run them (Windows works headless):

```sh
flutter test --enable-impeller --enable-flutter-gpu --tags gpu
```

Wait for submitted work before reading pixels back: reading an image straight after a flutter_gpu `CommandBuffer.submit()` can return empty pixels on the OpenGL ES backend. `submitAndWait` in `testing.dart` waits for a raw command buffer; `GpuCommands.submit()` already completes only once the GPU is done.

## Usage

### Draw a scene

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_graphics_engine/just_graphics_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. The renderer on this platform's GPU, or null (with a reason) where
  //    Flutter GPU can't draw. It loads the shaders and makes its pipelines.
  String? reason;
  final renderer = await Renderer3D.tryCreate(onUnsupported: (r) => reason = r);

  // 2. A scene, in the renderer's axes (+Y down, metres), with a model:
  //    glTF 2.0 (.glb, or .gltf with its files fetched by `fetch`).
  final scene = RenderScene();
  if (renderer != null) {
    final asset = await rootBundle.load('assets/models/crate.glb');
    final bytes = asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
    final crate = await renderer.uploader.upload(await loadModelData(bytes, name: 'crate.glb'));
    scene.addModel(crate, Matrix4.identity());
    scene.lights.add(PunctualLight(type: LightType.point, position: Vector3(0, -2, -1)));
  }

  // 3. A camera, and a widget that draws the scene from it every frame.
  final camera = RenderView()..lookAt(Vector3(0, -2, -6), Vector3.zero());
  runApp(MaterialApp(
    home: Scene3DView(
      renderer: renderer,
      scene: scene,
      camera: camera,
      fieldOfView: math.pi / 3,
      unsupportedReason: reason,
      // Before each frame: move the camera, animate the scene.
      onFrame: (elapsed, size) {},
    ),
  ));
}
```

`Scene3DView` fills the space it is given, sizes the camera's image from it (`renderScale: 0.75` renders fewer pixels) and, with `fieldOfView`, sets a perspective projection for its aspect ratio. Without a renderer it shows the reason; if drawing fails it stops and says why. `animate: false` draws only when the widget is rebuilt.

`Renderer3D.render` culls, batches identical meshes into instanced draws, lights with a sun, up to 8 point/spot lights and a hemisphere ambient, draws a gradient sky, and tonemaps HDR into the surface (4x MSAA where the device supports it). `renderer.stats` tells what the last frame did. To draw into a canvas yourself instead, render into a `GpuSurface` (`renderer.device.createSurface`) and paint its `image`: each read hands out a new `ui.Image`, so dispose it once drawn.

Flutter's `package:flutter/rendering.dart` has a `RenderView` of its own. `material.dart` and `widgets.dart` don't export it; if you import the rendering library, hide it there.

### Animated characters

A `PosedModel` is one placed copy of a model in a pose of its own. Sample a clip into its pose, update it, and place it each frame:

```dart
final posed = PosedModel(mannequin);
scene.addModel(mannequin, placement, posed: posed);
final walk = mannequin.clips['walk']!;

// Each frame:
walk.sample(seconds % walk.duration, posed.pose);
posed.update();
posed.place(placement.clone()..multiply(gltfToEngine));
```

Skinned meshes sharing a model draw as one instanced draw, their palettes in a float texture.

### Meshes made in code

`MeshBuilder` builds a `ShapeMesh` a triangle, quad, box or lathe at a time; upload it and draw it with a material made in code:

```dart
final mesh = (MeshBuilder()..box(-0.5, -0.5, -0.5, 0.5, 0.5, 0.5)).build();
scene.instances.add(MeshInstance(
  renderer.uploader.uploadPrimitive(mesh.toPrimitive()),
  renderer.uploader.material(const MaterialData(baseColor: (1.0, 0.2, 0.2, 1.0), roughness: 0.6)),
  Matrix4.identity(),
));
```

### In a just_game_engine game

just_game_engine (2.0.0 and later) draws its 3D scenes with this package: give the engine `EngineConfig(graphics3D: Graphics3D())` (`package:just_game_engine/graphics_3d.dart`) and its Model, Light, Environment and shape components are saved, loaded and drawn from the engine's camera. See just_game_engine's README.

## What works today, and what doesn't yet

- **Models:** static glTF 2.0 — meshes, node hierarchies, metallic-roughness materials with every map, alpha mask and blend, double-sided, vertex colours, `KHR_texture_transform`, `KHR_materials_unlit`, `KHR_materials_emissive_strength`, `KHR_mesh_quantization`, `KHR_lights_punctual`, sparse accessors.
- **Animation:** skins and glTF clips; poses blend for crossfades. Joint palettes go in one float texture (any joint count, and characters sharing a mesh are one draw); on devices without float textures they go in uniform blocks, up to 64 joints and one draw per character. Morph targets are not played yet.
- **Shadows:** the sun casts two cascades of 2048² shadow maps over the first 40 m in front of the camera (`renderer.shadows`), filtered 3×3.
- **Look:** image-based light from the gradient sky or an `.hdr` skybox (prefiltered reflections, spherical-harmonic ambient), fog, bloom, FXAA, dynamic resolution.
- **Not yet:** files that require Draco, meshopt or KTX2 textures (refused with a message saying so), compressed cooked textures (ETC2/ASTC), and morph targets.
- **Phones:** every draw call costs tens of microseconds on Android's Vulkan driver (about 40 us for a bare draw and 60 for a lit one on a Pixel 8), so keep a mobile scene to roughly 100 draws: instancing merges copies of one mesh and material, and `renderer.stats.drawCalls` counts them.
- **Web:** no 3D drawing (see Platform support).

## Credits

The shaders implement published techniques: the BRDF [Filament](https://google.github.io/filament/Filament.html) uses, Brian Karis' analytic fit of the environment BRDF, Krzysztof Narkowicz's [ACES filmic fit](https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/), Christian Schüler's "Followup: Normal Mapping Without Precomputed Tangents", and Timothy Lottes' FXAA (NVIDIA).

## License

BSD 3-Clause; see [LICENSE](LICENSE).

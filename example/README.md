# just_graphics_engine example

just_graphics_engine on its own, with no game engine: glTF models in a `RenderScene` with a sun, a lamp and a sky, drawn by `Scene3DView`. A crate spins and two mannequins walk and idle. Drag to orbit the camera; scroll to zoom.

- `lib/main.dart` makes the renderer with `Renderer3D.tryCreate`, loads `assets/models/*.glb` with `loadModelData`, places them (`RenderScene.addModel`, `PosedModel` for the animated ones) and shows the scene in a `Scene3DView` with an orbiting `RenderView`.
- `assets/models/*.glb` are made by `dart run tool/make_models.dart`.
- Every runner turns Flutter GPU on: `windows/runner/main.cpp`, `linux/runner/my_application.cc`, `android/app/src/main/AndroidManifest.xml` (Impeller on Vulkan), `ios/Runner/Info.plist` and `macos/Runner/Info.plist`.

```sh
flutter run -d windows
flutter test                                # the scene loads (no GPU needed)
flutter test integration_test -d windows    # draws it; saves build/demo.png
```

On the web, or on Android devices without Vulkan, `Renderer3D.tryCreate` gives null and the view says why there is no 3D.

For 3D in a just_game_engine game, see `EngineConfig(graphics3D: Graphics3D())` in just_game_engine.

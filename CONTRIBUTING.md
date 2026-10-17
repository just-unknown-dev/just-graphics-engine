# Contributing to Just Graphics Engine

Thank you for your interest in contributing to **Just Graphics Engine**. Bug fixes, features, tests and documentation are all welcome.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Reporting Bugs and Suggesting Features](#reporting-bugs-and-suggesting-features)
- [Development Setup](#development-setup)
- [Working Against Unpublished Dependencies](#working-against-unpublished-dependencies)
- [How the Package Fits Together](#how-the-package-fits-together)
- [Building the Shaders](#building-the-shaders)
- [Running the Tests](#running-the-tests)
- [Coding Guidelines](#coding-guidelines)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Commit Message Convention](#commit-message-convention)
- [Releasing](#releasing)
- [License](#license)

---

## Code of Conduct

This project follows our [Code of Conduct](CODE_OF_CONDUCT.md). By taking part you agree to its terms. Please report unacceptable behaviour to the maintainers.

---

## Reporting Bugs and Suggesting Features

Before opening an issue, search the [existing issues](https://github.com/just-unknown-dev/just-graphics-engine/issues) and check that the problem happens on the latest version.

What the GPU draws depends on the platform, the backend and the device, so a bug report should have:

- a clear title;
- steps to reproduce, and what you expected instead of what happened;
- the output of `flutter --version`, the platform, and the device (for Android, the phone);
- the Impeller backend your app's log names (`Using the Impeller rendering backend (Vulkan)`, for example), and how you turned Flutter GPU on in the runner;
- when nothing 3D is drawn, the reason the package gives: what `Renderer3D.tryCreate` reported (or, in a just_game_engine game, `engine.graphics3D.unsupportedReason`);
- the model (`.glb`, or `.gltf` with its files), or the smallest one that shows the problem, and its `<model>.import.json` if you cooked it;
- the code that builds the `RenderScene` (its models, lights and environment) and the `RenderView`;
- for a drawing bug, a screenshot and `renderer.stats` for that frame;
- for a crash or a hang, whether `flutter test --enable-impeller --enable-flutter-gpu --tags gpu` passes on your machine.

A bug in the editor's 3D side (model thumbnails, picking, the model import workspace, the Model, Light and Environment inspector sections) belongs to `just_graphics_editor`. The 3D components (Model, Light, Environment, the shapes), scene loading, the camera and 3D physics belong to `just_game_engine`.

For a feature, open an issue labelled **`enhancement`** that describes the problem it solves and how it should behave. The package's scope is drawing 3D in Flutter: the GPU layer over Flutter GPU, glTF loading and model import, meshes made in code, the renderer and `Scene3DView`. It knows no game engine (just_game_engine builds on it). A shader change reaches every backend Flutter GPU runs on, and a renderer change every just_game_engine game, so open the issue first and agree the approach before you write it.

---

## Development Setup

| Tool | Minimum version |
|------|-----------------|
| Dart | 3.12.2 |
| Flutter | 3.47.1, the first stable where Flutter GPU can be turned on in Windows and Linux release builds |

Nothing else needs installing: the shader compiler ships with Flutter (see [Building the Shaders](#building-the-shaders)).

```bash
git clone https://github.com/just-unknown-dev/just-graphics-engine.git just_graphics_engine
cd just_graphics_engine
flutter pub get
flutter test
```

Flutter GPU needs the Impeller renderer and an opt-in switch. The tests take it on the command line (see [Running the Tests](#running-the-tests)). An app turns it on in each runner:

| Platform | Switch | Status |
|----------|--------|--------|
| Windows | `project.set_enable_flutter_gpu(true);` in `windows/runner/main.cpp` | Supported (OpenGL ES over ANGLE); release builds and `flutter test` both render |
| Linux | `fl_dart_project_set_enable_flutter_gpu(project, TRUE);` in `linux/runner/my_application.cc` | Untested |
| Android | The `EnableImpeller`, `EnableFlutterGPU` and `ImpellerBackend` (`vulkan`) meta-data in `android/app/src/main/AndroidManifest.xml` | Vulkan only: `createGpuDevice` refuses the OpenGL ES fallback, where draws can hang |
| iOS, macOS | `FLTEnableFlutterGPU` in `Info.plist` (and `FLTEnableImpeller` on macOS) | Untested |
| Web | None: Flutter web does not run Impeller | No 3D, but builds must still compile |

`flutter run --enable-flutter-gpu` also works, but only in debug builds. `example/` has every switch in place, so use it to try a change in a real window (`cd example`, then `flutter run -d windows`). Its models are made by `dart run tool/make_models.dart`.

---

## Working Against Unpublished Dependencies

The package's one just_* dependency is `just_dart` (the math). When a change needs an unreleased version of it, check it out next to this repository and point this package at it with a `pubspec_overrides.yaml` in the repository root:

```yaml
# pubspec_overrides.yaml: local only, never commit it.
dependency_overrides:
  just_dart:
    path: ../just_dart
```

Then run `flutter pub get`. Delete the file (or the entry) and run `flutter pub get` again to go back to the published version. `.gitignore` already ignores the file.

Do not change `pubspec.yaml` to a path dependency. If your pull request needs a version of `just_dart` that is not published yet, say so in the pull request: this package can only be released after it.

`just_game_engine` (its `graphics_3d.dart`) and `just_graphics_editor` (the editor's 3D side) depend on this package, and `just_game_engine_cli` (the game commands of `just`) writes the Flutter GPU switches into the runners of any new 3D game when `just create` makes it (`GameTemplate.flutterGpuRunners`). If you change the public API, a file format or how Flutter GPU is turned on, say in the pull request what they will need.

---

## How the Package Fits Together

The package is built in layers, each a library of its own. [ARCHITECTURE.md](ARCHITECTURE.md) explains each layer and what was learnt building it; read the part you are changing first.

| Folder | Contents |
|--------|----------|
| `lib/src/gpu/` | `gpu.dart`: `GpuDevice` and its buffers, textures, pipelines, passes and surfaces; `createGpuDevice`; `NullGpuDevice`, which records commands instead of drawing; `PipelineSet`, `RenderTargetPool`, `SortKey`, `UniformWriter`, `ClipFixup`; and, not exported, `loadShaderBundle` |
| `lib/src/gpu/backend_flutter_gpu/` | `FlutterGpuDevice`: the backend over `package:flutter_gpu` |
| `lib/src/assets/` | `assets.dart`: glTF 2.0 into `ModelData` (`loadModelData`), image decoding and mips, `AnimationClip`, `EnvironmentMapData`, `ModelImportSettings`, `cookModel` and `CookedModel`, `ShapeMesh` and `MeshBuilder` |
| `lib/src/renderer/` | `renderer.dart`: `Renderer3D`, `RenderScene`, `RenderView`, `ModelUploader`, `Skeleton`, `PosedModel`, sun shadows, `GpuEnvironmentMap` and `rendererNullShaders` |
| `lib/src/widgets/` | `just_graphics_engine.dart`: `Scene3DView` |
| `lib/src/testing/` | `testing.dart`: `gpuUnavailableReason`, `submitAndWait`, `readPixels`, `compareImages`, `GlbWriter` and the skinned fixtures (`skinnedBarGlb`, `jointChainGlb`, `mannequinGlb`) |
| `shaders/core/`, `core.shaderbundle.json`, `hook/build.dart` | The GLSL shaders, the bundle that names them, and the build hook that compiles it |
| `example/` | A Flutter app drawing models with `Scene3DView` and no game engine, with Flutter GPU on in every runner |
| `test/` | The tests, by layer (`assets/`, `gpu/`, `renderer/`, `widgets/`), and `import_boundary_test.dart` |
| `.pubignore` | What the published package leaves out; it ships the compiled shader bundle (see [Releasing](#releasing)) |

A few rules hold the package together. Keep them:

- **Only the GPU layer touches Flutter GPU.** Everything above it talks to `GpuDevice`. Three files import `package:flutter_gpu`: `lib/src/gpu/backend_flutter_gpu/flutter_gpu_device.dart`, `lib/src/gpu/shader_bundle_loader.dart` and `lib/src/testing/gpu_test_harness.dart`. Importing it anywhere a web build reaches breaks `flutter build web`, with or without `--wasm`, so the backend is reached only through the `dart.library.ffi` branch in `create_device.dart`. Flutter GPU's API changes between Flutter releases, and this keeps the changes in one folder.
- **No GPU is a normal case.** `createGpuDevice` returns null with a reason on the web, with Impeller off, and on Android's OpenGL ES fallback. `Renderer3D.tryCreate` then gives null, `Scene3DView` shows the reason, and the rest of the app runs as usual. Never throw because there is no GPU.
- **Assets are plain data.** Nothing under `lib/src/assets/` imports the GPU layer, the renderer or Flutter GPU, so models load (for their bounds and triangles) on every platform.
- **No game engine.** The package never imports one; `just_game_engine` builds its 3D on it. `test/import_boundary_test.dart` checks.
- **Model files carry a version.** `ModelImportSettings` (`<model>.import.json`) writes `formatVersion` 1, and `CookedModel` (`<model>.jmodel`) writes version 1 after its `JMDL` magic. Each refuses a file newer than itself. Bump the version when the layout changes, and keep reading the older one. A cooked copy carries a `cookStamp` of its file and settings, which is how a tool tells that it is stale.
- **One set of axes.** The renderer's axes (just_game_engine's too) are +Y down and +Z forward, in metres. glTF data stays as the file has it (+Y up) and is turned once, by `gltfToEngine`, when a model is placed; meshes made in code are built in the renderer's axes. Clip space is flipped once, in `ClipFixup`, after which front faces are counter-clockwise.
- **Draws are expensive on phones.** A draw call costs about 40 us (60 for a lit one) on a Pixel 8's Vulkan driver, so a mobile scene gets about 100 draws per frame. Keep instancing working (equal meshes and materials share one draw), don't repeat a binding a pass already holds, and check `RenderStats.drawCalls` when you change how draws are batched.

---

## Building the Shaders

The shaders are GLSL, in `shaders/core/`. `core.shaderbundle.json` names each one and gives its stage (`LitVertex` is `shaders/core/lit.vert`, a vertex shader). Flutter runs `hook/build.dart` when it builds an app that depends on the package, and when it runs this package's tests. The hook calls `buildShaderBundleJson` from `flutter_gpu_shaders`, which compiles the bundle with `impellerc`, the shader compiler that ships with the Flutter SDK, into `build/shaderbundles/core.shaderbundle`. `pubspec.yaml` lists that file under `flutter: assets:`.

There is no step to run by hand: edit a shader, then build or run the tests again. A shader that doesn't compile fails the build with `impellerc`'s message. `build/` is ignored by git; never commit the compiled bundle. At run time `loadShaderBundle` looks for it under `packages/just_graphics_engine/build/shaderbundles/`, as an app sees it, and then under `build/shaderbundles/`, as this package's own tests see it.

To add a shader:

1. Write it in `shaders/core/` and add it to `core.shaderbundle.json`.
2. If the renderer draws with it, add a `PipelineSpec` to `RendererPipelines` in `lib/src/renderer/renderer3d.dart`.
3. Add its uniform blocks, with the sizes and member offsets reflection reports, to `rendererNullShaders` in `lib/src/renderer/null_shaders.dart`. The GPU test "the null device reports the shaders as reflection does" in `test/renderer/skinning_gpu_test.dart` checks them.

Shaders follow these rules:

- **One bundle.** Every shader, the editor's included, goes in `core`: a dev dependency's assets are not bundled into an app, so an editor package can't ship shaders of its own.
- **GLSL ES 3.00.** The hook passes `glesLanguageVersion: 300`. Skinning reads joint palettes with `texelFetch`, which ES 1.00 lacks.
- **WebGL2-expressible:** uniform blocks and samplers only, no storage buffers, no compute, and at most 16 textures.
- **Uniforms come from reflection.** Blocks are bound by their GLSL type name (`uniform Frame { … } frame;` binds as `Frame`), and `UniformWriter` writes at the offsets reflection reports (`GpuUniformBlock.offsetOf`). Never write a std140 layout by hand.

---

## Running the Tests

Run every command from the repository root. `test/import_boundary_test.dart` reads `lib/` from disk and expects that working directory.

```bash
# The whole suite. Tests that render skip themselves without Flutter GPU.
flutter test

# One file.
flutter test test/assets/gltf_test.dart

# The tests that render, on a real GPU (headless on Windows).
flutter test --enable-impeller --enable-flutter-gpu --tags gpu
```

**The `gpu` tag.** Tests that render carry `@Tags(['gpu'])` (declared in `dart_test.yaml`) and skip with the reason from `gpuUnavailableReason()`, so a plain `flutter test` passes on any machine. Run the tagged tests for any change to the GPU layer, the renderer or a shader.

**A real window.** Under `flutter test`, Impeller runs a different backend from a Windows app (Vulkan-like, not the app's OpenGL ES over ANGLE). For a change that reaches the GPU, also draw the example in a window:

```bash
cd example
flutter test                               # the scene loads (no GPU needed)
flutter test integration_test -d windows   # draws it; saves build/demo.png
```

**The import boundary.** `test/import_boundary_test.dart` follows the web branch of `just_graphics_engine.dart`, `gpu.dart`, `assets.dart` and `renderer.dart`, and fails if any of them reaches `package:flutter_gpu`. It also checks that only the three files named above import it, that the glTF reader and the other assets need no renderer, and that the package never imports a game engine.

**Writing tests.** Most tests run on `NullGpuDevice(shaders: rendererNullShaders)`: `Renderer3D` then runs its whole CPU side (culling, sorting, batching, uniform packing), and the device logs what it would draw (`log`, `drawCount`). `Renderer3D.tryCreate(device: …)` takes a null device too, and `Scene3DView` draws through it in widget tests. Make glTF fixtures in code with `GlbWriter` and the fixtures in `lib/testing.dart`, not as binary files. A GPU test reads pixels back with `readPixels` and compares them with `compareImages` or `colorClose`. Wait for submitted work first (`submitAndWait`): a readback straight after `submit()` can come back empty on OpenGL ES. A widget GPU test runs on `LiveTestWidgetsFlutterBinding`: in `testWidgets`' fake-async pump, GPU work never reports back.

---

## Coding Guidelines

- **Formatting.** Format the files you change with `dart format <files>`; `lib/` must stay fully formatted (pub.dev's score checks it).
- **Analysis.** `flutter analyze` must report no issues at all: no errors, warnings or infos. The rules are in `analysis_options.yaml`: `flutter_lints`, with `build/` excluded.
- **Web and WebAssembly.** Every public library except `testing.dart` must compile for the web, to JavaScript and to WebAssembly: no `package:flutter_gpu` outside the three files named above, and no `dart:io` outside the Flutter GPU backend. The import boundary test checks the first; check the second with `grep -rn "import 'dart:io'" lib`.
- **Exact on the web.** On the web, Dart's `<<` and `|` work on 32 bits, so `SortKey` builds its 52-bit keys with multiplication and addition. Pack any new key the same way.
- **Math.** The renderer uses `just_dart`'s math. `vector_math` is there only for Flutter GPU's own API.
- **No allocation per draw.** Call `beginFrame()` once per frame, and send per-frame data (uniforms, instance data) through `frameData()`.
- **Documentation.** Give every public API you add a `///` doc comment. Describe user-visible changes under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md), and update [README.md](README.md) if the public API or platform support changes. Update [ARCHITECTURE.md](ARCHITECTURE.md) when a layer works differently, or when you find a Flutter GPU pitfall.
- **Tests.** Add or update tests for any behaviour you change. A bug fix comes with a test that fails without it, and a change to what is drawn comes with a GPU test.
- **Dependencies.** Do not add a dependency without discussing it in an issue first.
- **Structure.** Match the existing folders under `lib/src/`. Export new public API through the library of its layer (`gpu.dart`, `assets.dart`, `renderer.dart` or `just_graphics_engine.dart`), and test helpers through `testing.dart`. `testing.dart` must not import `flutter_test`, so that depending on the package doesn't pull test packages into an app.

---

## Submitting a Pull Request

1. Create a topic branch from `main`:
   ```bash
   git checkout -b fix/shadow-acne-on-slopes
   ```
2. Make your change, following the [Coding Guidelines](#coding-guidelines).
3. Check that everything passes:
   ```bash
   dart format <the files you changed>
   flutter analyze
   flutter test
   flutter test --enable-impeller --enable-flutter-gpu --tags gpu
   ```
4. For a change to the GPU layer, a shader or the renderer, also draw the example in a window, as in [Running the Tests](#running-the-tests).
5. Commit with a [conventional commit message](#commit-message-convention).
6. Push to your fork and open a pull request against `main`. Say what changed and why, and which platforms you ran it on. List any unpublished `just_dart` version it needs, and any change it means for `just_game_engine` or `just_graphics_editor`.
7. Answer review feedback.

Small pull requests are easier to review.

---

## Commit Message Convention

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary>
```

| Type | When to use |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `chore` | Build process, tooling, dependencies |

Use the area as the scope: `gpu`, `assets`, `renderer`, `shaders`, `widgets`, `testing` or `example`. Mark a change that breaks the public API or a saved format with `!` and a `BREAKING CHANGE:` footer.

**Examples:**
```
fix(renderer): push shadow receivers further along steep normals
feat(assets): read morph targets from glTF files
docs(contributing): explain how the shader bundle is built
```

---

## Releasing

1. Publish the dependencies first: this package can only be released after the `just_dart` version it needs is on pub.dev. just_game_engine is released after this package.
2. Update `version` in `pubspec.yaml` and add its section to `CHANGELOG.md`.
3. Run `flutter test` (and the GPU tests). Besides testing, this runs the build hook, which writes `build/shaderbundles/core.shaderbundle`: `.pubignore` lets that file into the published package, so the asset `pubspec.yaml` lists is there before the hook first runs in an app. Publishing without a fresh build ships an old bundle until the app's first build replaces it.
4. `dart format lib` must leave nothing to change, and `flutter analyze` must report no issues: pub.dev's score counts both.
5. `flutter pub publish --dry-run`, then `flutter pub publish`. Remove `pubspec_overrides.yaml` first, so the dry run resolves what users will get.

---

## License

By contributing to Just Graphics Engine you agree that your contributions will be licensed under the terms in [LICENSE](LICENSE).

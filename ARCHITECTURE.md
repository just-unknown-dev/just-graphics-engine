# Architecture

How `just_graphics_engine` is put together, and what was learnt building it. For contributors; `README.md` is for users.

## Overview

`package:flutter_gpu` is Flutter's low-level GPU API: contexts, buffers, textures, shaders and render passes, with nothing on top, and only under Impeller. This package builds a renderer on it, in layers:

| Library | Layer | Depends on |
|---|---|---|
| `gpu.dart` | `GpuDevice`: the only code that touches flutter_gpu | flutter_gpu (native only), just_dart |
| `assets.dart` | glTF 2.0 into `ModelData`; image decoding and mips | dart:ui, just_dart |
| `renderer.dart` | `Renderer3D`: forward PBR renderer of a `RenderScene` | `gpu.dart`, `assets.dart` |
| `just_graphics_engine.dart` | the layers above, re-exported, and `Scene3DView`, a widget drawing a scene every frame | `renderer.dart`, Flutter widgets |
| `testing.dart` | GPU test helpers, `GlbWriter` | flutter_gpu (native only) |

The package depends on no game engine (a test checks): just_game_engine builds its 3D on it.

Everything above `gpu.dart` loads on the web: flutter_gpu is reached only through a conditional import, so a web build compiles and simply has no device. `test/import_boundary_test.dart` follows the web branch of every public library except the test-only `testing.dart`, and fails if it reaches flutter_gpu.

## The GPU layer (`lib/gpu.dart`)

Everything above this layer talks to `GpuDevice` (`lib/src/gpu/device.dart`) and never to `flutter_gpu`. That keeps the renderer web-safe (importing flutter_gpu breaks a web build), absorbs flutter_gpu's API churn in one folder, and leaves room for a WebGL2 backend later.

| File | What it is |
|---|---|
| `device.dart` | The interfaces: device, buffers, textures, shaders and uniform blocks, pipelines, commands, passes, surfaces. |
| `formats.dart`, `caps.dart` | Our own enums (formats, load/store, compare, cull, blend presets, samplers, vertex layouts) and the device's measured capabilities. |
| `create_device.dart` | `createGpuDevice()`: Flutter GPU where `dart.library.ffi` exists, null (with a reason) on the web. On Android it also returns null on the OpenGL ES fallback, where draws can hang. |
| `backend_flutter_gpu/` | The Flutter GPU device. Only it and `shader_bundle_loader.dart` (which it uses) import flutter_gpu, apart from `testing.dart`'s helpers. |
| `backend_null/` | `NullGpuDevice`: records commands instead of drawing, for renderer unit tests and headless runs. |
| `pipeline_set.dart` | Creates the renderer's fixed pipelines up front; pipeline creation is synchronous and can stall a frame. |
| `render_target_pool.dart` | Reuses depth, MSAA and post-processing targets frame to frame. |
| `sort_key.dart` | 52-bit draw keys, built with multiplication so they stay exact on the web. |
| `uniform_writer.dart` | Packs the engine's 64-bit math into 32-bit uniform bytes at reflected offsets. |
| `clip_fixup.dart` | The engine's clip space has y down, Flutter GPU's has y up: projections are flipped once here. Front faces are then counter-clockwise (`frontFaceIsClockwise` is false, measured). |

Rules the layer follows:

- **Frames.** Call `beginFrame()` once per frame, before recording. Per-frame data (uniforms, instance data) goes through `frameData()`, which emplaces into a rotating host buffer; nothing is allocated per draw.
- **Uniforms** are bound by the block's GLSL *type* name, to every stage that declares it (`setUniforms`). Textures bind to the fragment stage unless `vertexStage: true`.
- **Lifetime.** flutter_gpu objects are freed when unreachable; there is no destroy call to make or defer.
- **Readback.** `submit()` completes when the GPU has finished, so pixels read after it are valid.

### Testing the GPU layer

`test/gpu/` holds two kinds of tests. Unit tests (sort keys, the null device, the pool, the uniform writer, the clip fix-up) run in every `flutter test`. Tests tagged `gpu` render for real and skip themselves without Flutter GPU:

```sh
flutter test --enable-impeller --enable-flutter-gpu --tags gpu
```

Under `flutter test`, Impeller runs a **different backend** from a Windows app (it reports bgra8, d32fS8 depth and render-to-mip support, which points to Vulkan, not the app's OpenGL ES over ANGLE). So check on the real backend too: the example's `integration_test/demo_test.dart` draws in a Windows window (`flutter test integration_test -d windows`, with `set_enable_flutter_gpu(true)` in the runner).

## The shader build pipeline

Shaders are GLSL (`shaders/core/`). `hook/build.dart` runs at app build time and calls `flutter_gpu_shaders`' `buildShaderBundleJson` with `core.shaderbundle.json`, which maps shader names to files; `impellerc` compiles them into `build/shaderbundles/core.shaderbundle`, listed under `flutter: assets:` for every platform but the web. Editing a shader and rebuilding recompiles the bundle.

- **Shipped copy.** The published package carries a compiled bundle (`.pubignore` lets it through), so the asset exists before the hook first runs in an app and pub.dev's analysis finds it. The hook still rebuilds it with the app's own Flutter SDK, because a bundle only suits the `impellerc` that made it. Run `flutter test` before publishing so the copy is current.

- **One bundle.** Every shader the renderer and the editor use lives in the `core` bundle: a dev-dependency package's assets are not bundled into an app, so an editor package can't ship its own.
- **Asset key.** A dependent app sees the bundle under `packages/just_graphics_engine/build/shaderbundles/…`; this package's own tests run it as the root app, where the key has no `packages/` prefix. `lib/src/gpu/shader_bundle_loader.dart` tries both.
- **Stay WebGL2-expressible:** uniform blocks and samplers only (no storage buffers, no compute), at most 16 textures.
- **GLSL ES 3.00.** The hook passes `glesLanguageVersion: 300`. The default (ES 1.00) has no `texelFetch` or `textureSize`, and `impellerc` aborts on the skinning shaders without it. Windows runs OpenGL ES 3 through ANGLE and Linux through EGL, and WebGL2 is ES 3.00 too.

| Shader | Use |
|---|---|
| `lit.vert` / `lit.frag` | Meshes: metallic-roughness PBR, instanced, sun shadow |
| `lit_skinned.vert` | Skinned meshes, joint palettes from a float texture |
| `lit_skinned_uniform.vert` | Skinned meshes, palette in a uniform block (fallback) |
| `shadow.vert`, `shadow_skinned*.vert`, `shadow.frag` | The sun's shadow map |
| `fullscreen.vert` | One screen-covering triangle at the far plane |
| `sky.frag` | Gradient sky behind everything |
| `tonemap.frag` | HDR → display (exposure, ACES, sRGB encode) |
| `bloom_down.frag`, `bloom_up.frag` | Bloom's bright pass and its down/up chain |
| `fxaa.frag` | FXAA after tonemapping |
| `unlit.*`, `instanced.vert`, `color.frag` | Debug drawing and the GPU layer's tests |

## Assets (`lib/assets.dart`)

`loadModelData(bytes, name:, fetch:)` reads `.glb` or `.gltf`:

1. Split a GLB (`gltf/glb.dart`) or decode the JSON; fetch external buffers and images with `fetch` (relative to the model); decode `data:` URIs.
2. In a background isolate (`compute`), `gltfToModel` builds `ModelData`:
   - **Refuses** files whose `extensionsRequired` it can't honour (Draco, meshopt, KTX2/Basis) with a message naming them.
   - **Reads** accessors with every component type, `normalized`, `byteStride` and sparse substitution (`gltf/accessors.dart`), so `KHR_mesh_quantization` works (quantized positions are dequantized by the node scale, as the spec intends).
   - **Builds** one interleaved vertex layout for every primitive (16 floats: position, normal, tangent, uv, colour; see `VertexOffsets`). Strips and fans become lists. No normals → flat normals, one vertex per corner (the spec's rule). No tangents → zeros, and the shader derives a frame from screen-space derivatives.
   - **Materials:** metallic-roughness with every map, `KHR_materials_unlit`, `KHR_materials_emissive_strength`, `KHR_texture_transform` (one transform per material: the first map's that has one); **lights:** `KHR_lights_punctual`.
3. Images stay encoded in `ModelData`. `ModelUploader` decodes each once per colour space on the root isolate (`decodeImage`) and builds mips in a background isolate (`buildMips`): colour maps average in linear light. flutter_gpu has no mip generation, and allows at most `floor(log2(min(w, h)))` levels (`GpuDevice.maxMipLevels`).

Axes are left as the file has them (glTF: +Y up). The renderer applies one correction when a model is placed (`gltfToEngine`, a 180° turn about X into the engine's +Y down, +Z forward); being a rotation, it keeps winding.

### Import settings and cooked models

A model may have settings beside it (`ModelImportSettings`, `<model>.import.json`: scale, the largest texture, mipmaps, material changes). `cookModel` applies them and writes a cooked copy (`<model>.jmodel`, `CookedModel`): a JSON header and 4-byte-aligned blobs — the vertex and index arrays as the uploader takes them, and every texture decoded, shrunk and mipped (`ImageData.levels`). A loader reads the cooked copy in place of the file when there is one (just_game_engine's `GraphicsModels` does when the bundle lists it), so a game parses no glTF and decodes no image. The cooked header carries a stamp of the file and its settings (`cookStamp`); the editor cooks a model again when either changes. ETC2/ASTC are accepted in the settings but not made yet.

## The renderer (`lib/renderer.dart`)

`Renderer3D.render(scene, view, surface)` draws one frame:

1. **Cull** every visible `MeshInstance` against the frustum of the engine-convention view-projection. World bounds are cached per instance until it moves (`setWorld` / `markMoved`).
2. **Key and sort** (`SortKey`): opaque and alpha-tested draws by phase, pipeline, material, mesh, then front to back; blended draws back to front.
3. **Batch:** runs of one primitive and one material become one instanced draw. Per-instance data is a model matrix and a normal matrix (inverse transpose, so non-uniform scale lights correctly), 112 bytes, written into the frame's transient buffer.
4. **Lights:** a sun, the 8 point/spot lights brightest for their distance to the camera, and a hemisphere ambient ("up" is -Y).
5. **Passes:** opaque → sky (far plane, depth `lessEqual`, only where nothing was drawn) → transparent, into an rgba16f target with 4x MSAA resolved into a single-sample texture; then a tonemap pass into the surface frame. Without an HDR target the lit and sky shaders tonemap themselves and draw straight into the surface.

Materials keep their uniform block in a persistent buffer, written once. Intermediate targets come from `RenderTargetPool`.

Measured 2026-10-09: 2,000 moving instances cost 1.3 ms of CPU per frame on the null device (debug test build); 300 unbatched draws at 1280×720 with MSAA and HDR cost 3.3 ms CPU and 6.1 ms per frame including the GPU on Windows (OpenGL ES over ANGLE, debug build).

## Skinning and animation

- **Data.** The loader reads `JOINTS_0`/`WEIGHTS_0` into a second vertex stream (`PrimitiveData.skin`, 8 floats per vertex, weights scaled to sum to 1), skins (joint nodes, inverse bind matrices) and animations (channels and samplers). Nodes keep their translation, rotation and scale, so they can be animated. Morph-target channels are skipped with a warning.
- **Clips** (`AnimationClip`) sample STEP, LINEAR (slerp for rotations) and CUBICSPLINE keys into a `Pose`: flat arrays of every node's TRS. Each sampler remembers its last key, so playback moving forward never searches. `Pose.blend` crossfades two poses (rotations the short way).
- **Skeleton** turns a pose into model-space node matrices, parents first, with no allocation. It then turns those into each skin's palette: per joint, the top three rows of `joint · inverseBind`. A skinned mesh is placed by its joints, not its node, as glTF asks.
- **`PosedModel`** is one placed copy of a model in its own pose. It owns the palettes and each skin's bounds (joint positions grown by the furthest any vertex sits from its joint, so culling stays correct while it moves), and moves its instances on `place`.
- **On the GPU** (`SkinningMode.texture`): every palette drawn in a frame is packed into one `rgba32f` texture (256 joints per row, three texels per joint), uploaded into the next of three textures so the GPU never reads one being written. The per-instance data carries where its palette starts. Characters sharing a mesh and material therefore stay one instanced draw. `SkinningMode.uniforms` is the fallback for devices without float textures: one palette (at most 64 joints) per draw in a uniform block. Both are tested to draw the same picture.
- **In a game**, just_game_engine's animation player and sockets drive `PosedModel`s from components; see its ARCHITECTURE.md.

## Shadows

- Shadow maps from the sun (`renderer.shadows`: on, two cascades of 2048², the first 40 m in front of the camera). Flutter GPU can't sample depth textures, so the shadow pass writes depth into an `r32f` colour target, with a depth buffer for testing. The lit shader compares 3×3 texels (percentage-closer filtering).
- **Fit** (`fitSunShadow`): the bounding sphere of the camera's frustum, cut at the shadow distance. Its size only changes in 1/16 m steps and its centre moves in whole texels, so edges don't crawl as the camera moves or turns. The box reaches `casterReach` (60 m) further towards the sun, so casters out of view still count.
- **Acne:** receivers are pushed 1.5 texels along their normal before the lookup (in the vertex shader), plus a small depth bias.
- **Casters** are culled against the sun's box and batched by mesh (any material), skinned ones through their own pipeline. They cost extra draws: `stats.shadowDrawCalls`.

## Look: fog, bloom, FXAA, cascades, dynamic resolution, image-based light

- **Fog** (`Environment.fog*`): exponential past a start distance, in the lit shader; the sky's horizon fades into the same colour.
- **Bloom** (`Renderer3D.bloom`): a bright pass, then a chain of half-size rgba16f targets down and back up, added in the tonemap pass. A chain of separate targets, as Flutter GPU cannot render into a mip level on GLES.
- **FXAA** (`Renderer3D.fxaa`): tonemapped into rgba8, then FXAA: cheaper than 4× MSAA on a phone.
- **Two shadow cascades** (`ShadowSettings.cascades`, `cascadeSplit`): a sharp map near the camera and a wide one beyond, chosen per fragment by view depth.
- **Dynamic resolution** (`DynamicResolution`): told each frame's time, it lowers a render scale while frames run long, and raises it again (just_game_engine's scene renderer uses it).
- **Image-based light** (`Environment.map`, `GpuEnvironmentMap`): a small half-float cube of the surroundings — the gradient sky, or an equirectangular `.hdr` skybox — built on another isolate (`EnvironmentMapData`). Its levels are GGX-prefiltered on the CPU (one per roughness step); its diffuse light is nine spherical-harmonic coefficients. The lit shader takes diffuse ambient from the harmonics and reflections from the cube (`textureLod` by roughness, with Karis' analytic environment BRDF, so no lookup texture); without a map it keeps the hemisphere light. Faces follow the shared cube convention (`EnvironmentMapData.directionOf`) in the renderer's axes (+Y down); a GPU test checks each face lands where its axis points. `Environment.skybox` draws the map as the sky too.

## Draw cost on phones

Measured on a Pixel 8 (Vulkan, profile build) with a benchmark app run through `flutter drive --profile` (not part of the package):

- a bare `drawIndexed` costs about 40 us with one uniform block and two vertex buffers bound, and about 62 us with the lit pipeline's three blocks and five textures;
- each `bindTexture` costs about 4 us, a uniform bind about 25 us, and `setCull` + `setBlend` together about 25 us;
- the cost is paid when the draw is recorded; submit is about 2 us per draw.

300 unbatched draws take about 51 ms of CPU per frame on the phone, against 3.3 ms on Windows. So the renderer instances everything it can, and the Flutter GPU backend's pass skips any call that repeats what the pass already holds. That is safe because Flutter GPU keeps bindings and state on a pass until the pipeline changes, and the cache is forgotten then. Plan for about 100 draws per frame on a phone.

## The widget (`Scene3DView`)

`Scene3DView` is the whole renderer in one widget, for apps without a game engine. A `Ticker` bumps a notifier its `CustomPainter` repaints on; each paint calls `onFrame` (move the camera, animate), sizes the `RenderView` at layout size x device pixel ratio x `renderScale` (and sets a perspective projection when given `fieldOfView`), renders into a `GpuSurface` of its own and draws `surface.image` over its box. `GpuImageSurface.currentImage` hands out a new `ui.Image` each call, so it disposes the image after drawing (the recorded picture holds its own reference). The frame is submitted without waiting; `onRendered` hands out the future that completes when the GPU is done. With no renderer (`Renderer3D.tryCreate` gave null) or after a failed frame, it shows the reason as plain widgets.

Under `flutter test`, a frame's GPU work submitted inside `testWidgets`' fake-async pump never reports back; the widget's GPU test runs on `LiveTestWidgetsFlutterBinding`, in real time.

just_game_engine's 3D (`package:just_game_engine/graphics_3d.dart`) draws a world with the same renderer from a `SceneRenderer` of its own; its ARCHITECTURE.md covers the components, model loading and interpolation.

- **`example/`** is a Flutter app with the GPU switch on in every runner and no game engine: it loads the models `tool/make_models.dart` generates, places them in a `RenderScene` and draws it with a `Scene3DView`. `integration_test/demo_test.dart` draws it in a real window (`flutter test integration_test -d windows`) and saves `build/demo.png`.

## flutter_gpu pitfalls (found the hard way)

- **Bindings outlive draws.** A render pass keeps buffers, uniforms and textures bound until `clearBindings()`. Binding another pipeline and drawing with the previous pipeline's bindings still attached makes Impeller build an invalid descriptor layout (a crash on Vulkan). `GpuPass.setPipeline` clears bindings whenever the pipeline changes.
- **One render pass per command buffer.** Two passes in one flutter_gpu command buffer, where the second samples what the first drew, crash on Vulkan. `GpuCommands` gives every pass a command buffer of its own and submits them in order (no waiting in between is needed).
- **Mip limit**, see Assets.
- **API churn.** 3.47 made `ShaderLibrary.fromAsset` asynchronous and moved draw counts onto `draw`/`drawIndexed`. flutter_gpu calls stay inside `lib/src/gpu/` (the backend and the shader bundle loader).
- **Crashes look like hangs in tests.** A native crash ends a `flutter test` run with "did not complete" and no message; run the same code under `flutter test` with stderr unfiltered to see SwiftShader's warnings.

## Shader uniform binding

- **Blocks are found by their GLSL type name**, not the instance name: for `uniform Frame { … } frame;` the slot is `Frame`. (The first version used the instance name, from reading Impeller's reflector source, and failed at runtime with "missing the uniform block"; verify reflection names by running them.) Plain samplers are found by their variable name.
- **A block declared in both stages is bound in both.** `bindUniform` targets one stage's slot; `GpuPass.setUniforms` binds the same buffer view to every stage of the current pipeline that declares the block.
- **Offsets come from reflection** (`GpuUniformBlock.offsetOf`), never from a hand-written std140 layout; `UniformWriter` writes at those offsets.

## Platform support and known issues

`flutter_gpu` requires Impeller, and Impeller's platform support is uneven. See `README.md` for the user-facing support table; the rest of this section is the *why*, for anyone debugging a new platform.

### Android: OpenGL ES backend hangs on `draw()`

Impeller on Android prefers Vulkan and falls back to OpenGL ES on devices without it. The GLES backend is known to be substantially less mature for `flutter_gpu` specifically — see [flutter/flutter#177873](https://github.com/flutter/flutter/issues/177873) and [flutter/flutter#179268](https://github.com/flutter/flutter/issues/179268).

We hit this directly: on an Android emulator that fell back to GLES (logged as `Using the Impeller rendering backend (OpenGLES)`), `RenderPass.draw()` hung indefinitely — confirmed by instrumenting every step of the render call with `print()` and observing execution stop dead on the `draw()` call, reproducible even with the simplest possible shader (position-only, no per-vertex color, from this package's since-removed triangle prototype). It was not a timing issue (deferring the render past the first frame didn't help) and not shader-complexity related.

**Fix:** force Vulkan explicitly via the `ImpellerBackend` manifest meta-data (see `README.md` → Getting started → Android). This is mandatory for this package to work reliably on Android — don't rely on Impeller's automatic Vulkan/GLES selection.

The emulator hang reproduced again on 2026-10-09 (Flutter 3.47.6, x86_64 emulator without Vulkan): the manifest asks for Vulkan, Impeller still reports `OpenGLES`, and the first draw never completes. Such devices must be detected and treated as unsupported before anything is drawn. On Android, `gpuContext.doesSupportFramebufferRenderMipmap` is false on OpenGL ES and true on Vulkan, which is the check `createGpuDevice` makes.

### Windows / Linux: Impeller on OpenGL ES (Flutter 3.47 and later; Linux untested)

Flutter 3.47 made Impeller the default renderer on Windows (OpenGL ES over ANGLE, which runs on Direct3D 11) and Linux (OpenGL ES over EGL), and 3.47.1 added a project-level Flutter GPU switch to both embedders ([flutter/flutter#190871](https://github.com/flutter/flutter/issues/190871)): `project.set_enable_flutter_gpu(true)` in `windows/runner/main.cpp`, and `fl_dart_project_set_enable_flutter_gpu` on Linux. Release builds need the switch; `flutter run --enable-flutter-gpu` only works in debug builds.

Verified on Windows 11 (Flutter 3.47.6): a release build renders skinned models, and `flutter test --enable-impeller --enable-flutter-gpu` renders headless, including this package's build-hook shader bundle.

### Web: not supported, and the import itself breaks the build

Flutter web renders through Skia (`canvaskit`/`skwasm`), not Impeller. Importing `package:flutter_gpu` anywhere in a web build's import graph fails both `flutter build web` and `flutter build web --wasm`, because it imports `dart:ffi` and `dart:nativewrappers`. So only the device backend imports it, behind `create_device.dart`'s conditional export: the renderer, the assets and `Scene3DView` load on the web, and `Renderer3D.tryCreate` gives null there. The example builds with both `flutter build web` and `flutter build web --wasm`.

## Capabilities measured on 2026-10-09

| | Windows (OpenGL ES / ANGLE) | Android emulator (OpenGL ES) |
|---|---|---|
| Default colour / depth format | rgba8 / d24S8 | rgba8 / d24S8 |
| Offscreen 4x MSAA | yes | yes |
| Render into a mip level | **no** | **no** |
| Sample hand-uploaded mips | yes | yes |
| Anisotropic filtering | 16 | 1 |
| Uniform buffer alignment | 256 | 256 |
| Texture compression | ETC2 only | ETC2, ASTC |
| rgba16f render target | yes | yes |

Other findings:

- **No multiple render targets on OpenGL ES.** Impeller's OpenGL ES render pass binds only colour attachment 0, so the renderer shades forward.
- **Clip space:** +Y in clip space lands at the top of the rendered image (`test/gpu/device_test.dart` checks this).
- **Readback:** reading an image back straight after `submit()` returned all zeros on Windows. Waiting for `submit(completionCallback:)` first fixes it.
- **Shader bundle keys:** an app that depends on this package sees its bundles under `packages/just_graphics_engine/build/shaderbundles/…`; the package's own tests run it as the root app, where the same asset has no `packages/` prefix. `loadShaderBundle` tries both.

## Debugging a hang or render failure

1. Check that Impeller and Flutter GPU are on: `createGpuDevice` returns null with a reason otherwise. On Android, confirm logcat says `Using the Impeller rendering backend (Vulkan)`; OpenGL ES is refused.
2. Reproduce under `flutter test --enable-impeller --enable-flutter-gpu` and read stderr unfiltered: SwiftShader prints what it rejects before a crash.
3. Bisect by turning renderer features off (sky, HDR, MSAA) one at a time, then reproduce the failing combination in a small test against `GpuDevice` directly. Remember that `bool.fromEnvironment` only sees `--dart-define` values when it is called as `const`.

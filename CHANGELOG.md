## 0.1.0-dev.2

* Instance batches: `InstanceBatch` in `RenderScene.batches`, each in a persistent instance buffer, culled whole and beyond its reach, casting shadows; `Stats.batches`.
* Overlays and wireframes: `OverlayDraw` in `RenderScene.overlays`, drawn last with line topology; `GpuPrimitive.edges` (`ModelUploader(keepEdges:)`).
* View modes (`RenderViewMode`: lit, unlit, wireframe), a clip plane, and the editor's unlit view in the lit shader.
* Layered materials (`MaterialData.layered`: four colour layers weighed by vertex colour) and texture coordinates in metres or from the world (`MaterialData.uvMode`); `ModelUploader.material(maps:)` takes every map.
* Frames drawn before the GPU runs them keep their own data. `GpuDevice.frameData` came from Flutter GPU's `HostBuffer`, which hands a frame's memory out again four frames later whether or not the GPU has read it: an app drawing five or more views a frame (an editor's split view and its game preview) drew views with another's camera, sky and lights, flickering. Each frame now writes into memory of its own, reused once the GPU has finished with it, and so does each frame's joint texture.

## 0.1.0-dev.1

First release, a dev release: a 3D renderer for Flutter on Flutter GPU, standing alone (no game engine) and drawing the 3D of just_game_engine. Requires Flutter 3.47.1 or newer.

* `gpu.dart`: `GpuDevice` over Flutter GPU (`createGpuDevice`, null with a reason where it can't run: the web, Impeller off, Android's OpenGL ES fallback), a `NullGpuDevice` that records commands, `PipelineSet`, `RenderTargetPool`, `SortKey`, `UniformWriter` and `ClipFixup`. The backend skips calls that repeat what a pass already holds, since draw calls cost tens of microseconds on Android.
* `assets.dart`: glTF 2.0 loading (`loadModelData`): `.glb` and `.gltf`, node hierarchies, every material map, sparse accessors, `KHR_texture_transform`, `KHR_materials_unlit`, `KHR_materials_emissive_strength`, `KHR_mesh_quantization` and `KHR_lights_punctual`. Files that require Draco, meshopt or KTX2 are refused by name. Images decode once and get sRGB-correct CPU mips.
* Meshes made in code: `MeshBuilder` (triangles, quads, faces, boxes, lathes, discs) builds a `ShapeMesh`; `ShapeMesh.toPrimitive` and `ModelUploader.uploadPrimitive` put it on the GPU, `ModelUploader.material` gives it a material made in code.
* `renderer.dart`: `Renderer3D` with frustum culling, sorted and instanced draws, metallic-roughness PBR lit by a sun, 8 point/spot lights and a hemisphere ambient, a gradient sky, and HDR with 4x MSAA and ACES tonemapping. `Renderer3D.tryCreate` makes one on this platform's GPU, or gives null and says why. `RenderStats` counts draws, shadow draws, casters, skinned instances and joints.
* `Scene3DView`: a widget that draws a `RenderScene` from a `RenderView` every frame (or when rebuilt), sizes the image from its layout, sets a perspective projection for its aspect ratio, and shows the reason when there is no GPU or drawing fails.
* Sun shadows: two cascades of `r32f` shadow maps fitted to the view with texel snapping, 3×3 PCF and normal-offset bias (`Renderer3D.shadows`, `ShadowSettings.cascades`, `cascadeSplit`, `fitSunShadow`).
* Image-based light: `EnvironmentMapData` (a gradient sky or an equirectangular Radiance `.hdr`, `decodeRadianceHdr`; GGX-prefiltered cube levels and SH9 diffuse light, built on another isolate) and `GpuEnvironmentMap`. Lit surfaces take ambient light and reflections from `Environment.map`; `Environment.skybox` draws it as the sky.
* Fog, over the sky's horizon too; bloom (`Renderer3D.bloom`, `BloomSettings`) through a chain of half-size targets; FXAA (`Renderer3D.fxaa`) for when MSAA is too dear; `DynamicResolution`, which lowers a render scale while frames run long.
* Skinned animation: skins and animations from glTF; `AnimationClip` (step, linear and cubic-spline keys), `Pose` (and blending), `Skeleton`, `PosedModel`; joint palettes in one float texture (instanced skinned draws) or, as a fallback, uniform blocks.
* Model import: `ModelImportSettings` (saved beside a model as `<model>.import.json`: scale, largest texture, mipmaps, material changes) and `cookModel`, which writes a cooked copy (`<model>.jmodel`, `CookedModel`) with every texture decoded, shrunk and mipped: no glTF parsing, no image decoding where it is loaded. ETC2/ASTC compression is accepted in the settings but not made yet (cooked uncompressed, with a warning).
* For editors and tools: `GpuModel.withMaterialValues` (previews change materials without uploading), `ImageData.levels`, `ModelUploader.uploadImage`.
* `testing.dart`: GPU test helpers (`gpuUnavailableReason`, `submitAndWait`, `readPixels`, `compareImages`), `GlbWriter` for generated fixtures, and `skinnedBarGlb`, `jointChainGlb` and `mannequinGlb` (a walking character made in code).
* Shaders compile into one bundle with the app's Flutter SDK (`hook/build.dart`, GLSL ES 3.00 on OpenGL ES). Web builds, JavaScript or WebAssembly, compile and leave the bundle out.
* `example/`: models, walking characters, lights and a sky drawn by a `Scene3DView` from an orbiting camera, with no game engine, and the Flutter GPU switch in every runner.
* GPU tests (tag `gpu`) run headless on Windows with `flutter test --enable-impeller --enable-flutter-gpu --tags gpu`.

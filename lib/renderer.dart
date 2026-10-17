/// just_graphics_engine's forward renderer: upload models
/// ([ModelUploader]), place them in a [RenderScene] with lights and an
/// environment, and draw it from a [RenderView] into a `GpuSurface` with
/// [Renderer3D] ([Renderer3D.tryCreate] picks this platform's GPU).
/// [DynamicResolution] trades pixels for frame time.
///
/// Loads on every platform; drawing needs a `GpuDevice` (see `gpu.dart`).
library;

export 'src/renderer/dynamic_resolution.dart';
export 'src/renderer/environment_map.dart';
export 'src/renderer/gpu_model.dart';
export 'src/renderer/instance_batch.dart';
export 'src/renderer/null_shaders.dart';
export 'src/renderer/posed_model.dart';
export 'src/renderer/render_scene.dart';
export 'src/renderer/renderer3d.dart';
export 'src/renderer/shadows.dart';
export 'src/renderer/skinning.dart';

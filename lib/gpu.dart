/// The GPU layer under just_graphics_engine's renderer.
///
/// Nothing here exposes a `flutter_gpu` type, so this library loads on every
/// platform; [createGpuDevice] returns null where Flutter GPU can't run
/// (the web, Impeller off, Android without Vulkan). [NullGpuDevice] records
/// commands instead of drawing, for tests and headless runs.
library;

export 'src/gpu/backend_null/null_device.dart';
export 'src/gpu/caps.dart';
export 'src/gpu/clip_fixup.dart';
export 'src/gpu/create_device.dart';
export 'src/gpu/device.dart';
export 'src/gpu/formats.dart';
export 'src/gpu/pipeline_set.dart';
export 'src/gpu/render_target_pool.dart';
export 'src/gpu/sort_key.dart';
export 'src/gpu/uniform_writer.dart';

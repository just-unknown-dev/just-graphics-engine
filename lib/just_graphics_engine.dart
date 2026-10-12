/// A 3D renderer for Flutter on Flutter GPU: glTF 2.0 models,
/// physically based materials, lights and shadows, skinned animation and
/// image-based light, drawn into any Flutter app.
///
/// Spread over libraries by layer, all re-exported here:
/// - `gpu.dart`: the GPU layer (`GpuDevice` over flutter_gpu, a null
///   device for tests).
/// - `assets.dart`: glTF 2.0 loading into `ModelData`, cooked models,
///   environment maps and meshes built in code (`MeshBuilder`).
/// - `renderer.dart`: the forward renderer ([Renderer3D], [RenderScene],
///   [RenderView]).
/// - [Scene3DView]: a widget that draws a [RenderScene] every frame.
///
/// `testing.dart` (not re-exported) has GPU test helpers and a glTF writer
/// for fixtures.
///
/// ```dart
/// String? reason;
/// final renderer = await Renderer3D.tryCreate(onUnsupported: (r) => reason = r);
/// ```
///
/// [Renderer3D.tryCreate] gives null where Flutter GPU can't draw (the web,
/// Impeller off, Android on OpenGL ES); [Scene3DView] then shows the reason.
///
/// just_game_engine draws its 3D scenes with this package:
/// `EngineConfig(graphics3D: Graphics3D())` there.
library;

export 'assets.dart';
export 'gpu.dart';
export 'renderer.dart';
export 'src/widgets/scene_3d_view.dart';

// The math types the renderer's signatures use, from just_dart.
export 'package:just_dart/just_dart.dart'
    show
        Aabb3,
        Frustum,
        JustMatrix4,
        Matrix4,
        Plane,
        Quaternion,
        Ray3,
        Vector2,
        Vector3;

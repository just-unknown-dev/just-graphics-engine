/// Model loading for just_graphics_engine: glTF 2.0 (`.gltf` and `.glb`)
/// into [ModelData], ready to upload, with its animation clips; import
/// settings and cooked `.jmodel` copies; environment maps from a gradient
/// sky or a Radiance `.hdr`; meshes built in code ([MeshBuilder]). Pure
/// data, no GPU; heavy work runs in a background isolate.
library;

export 'src/assets/animation_clip.dart';
export 'src/assets/cooked_model.dart';
export 'src/assets/environment_map.dart';
export 'src/assets/model_cooker.dart';
export 'src/assets/model_import.dart';
export 'src/assets/gltf/gltf_to_model.dart' show supportedGltfExtensions;
export 'src/assets/model_data.dart';
export 'src/assets/model_loader.dart';
export 'src/assets/shape_mesh.dart';
export 'src/assets/texture_decode.dart';

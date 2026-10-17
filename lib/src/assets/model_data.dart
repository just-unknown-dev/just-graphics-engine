import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

/// Floats per vertex in [PrimitiveData.vertices]: position (3), normal (3),
/// tangent (4, w = handedness; all zero when the file had none), uv (2),
/// colour (4).
const int kVertexFloats = 16;

/// Floats per vertex in [PrimitiveData.skin]: four joint indices (as
/// floats) and their four weights, which sum to 1.
const int kSkinFloats = 8;

/// Byte offsets of each attribute inside one vertex.
abstract final class VertexOffsets {
  /// Position, 3 floats.
  static const int position = 0;

  /// Normal, 3 floats.
  static const int normal = 12;

  /// Tangent, 4 floats.
  static const int tangent = 24;

  /// Texture coordinate, 2 floats.
  static const int uv = 40;

  /// Vertex colour, 4 floats (linear).
  static const int color = 48;

  /// Bytes per vertex.
  static const int stride = kVertexFloats * 4;
}

/// A model, ready for the GPU: meshes as interleaved vertices and indices,
/// materials, encoded images, the node tree and its lights. In the file's
/// own axes (glTF: +Y up); the renderer corrects axes once, at the root.
///
/// Plain data with no GPU objects, so it can be built in a background
/// isolate and sent back.
final class ModelData {
  /// A model.
  ModelData({
    required this.name,
    required this.meshes,
    required this.materials,
    required this.textures,
    required this.images,
    required this.nodes,
    required this.roots,
    required this.lights,
    required this.bounds,
    this.skins = const [],
    this.animations = const [],
    this.warnings = const [],
  });

  /// Where it came from.
  final String name;

  /// Meshes, by glTF mesh index.
  final List<MeshData> meshes;

  /// Materials, by glTF material index.
  final List<MaterialData> materials;

  /// Textures, by glTF texture index.
  final List<TextureData> textures;

  /// Images (still encoded), by glTF image index.
  final List<ImageData> images;

  /// Nodes, by glTF node index.
  final List<NodeData> nodes;

  /// The nodes of the scene shown, with no parent.
  final List<int> roots;

  /// Lights (`KHR_lights_punctual`), by index.
  final List<LightData> lights;

  /// Bounds of every mesh instance in the scene, in model space (skinned
  /// meshes in their bind pose).
  final Aabb3 bounds;

  /// Skins, by glTF skin index.
  final List<SkinData> skins;

  /// Animations, by glTF animation index.
  final List<AnimationData> animations;

  /// Things the loader skipped or approximated, for the editor to show.
  final List<String> warnings;

  /// Calls [visit] for every node of the shown scene, parents first, with
  /// its transform relative to the model's root.
  void forEachNode(void Function(int node, Matrix4 modelFromNode) visit) {
    void walk(int index, Matrix4 parent) {
      final node = nodes[index];
      final world = parent.multiplied(node.local);
      visit(index, world);
      for (final child in node.children) {
        walk(child, world);
      }
    }

    for (final root in roots) {
      walk(root, Matrix4.identity());
    }
  }
}

/// One glTF mesh.
final class MeshData {
  /// A mesh of [primitives].
  const MeshData(this.name, this.primitives);

  /// Its name in the file.
  final String? name;

  /// Its parts, each with one material.
  final List<PrimitiveData> primitives;
}

/// Triangles with one material.
final class PrimitiveData {
  /// A triangle list.
  PrimitiveData({
    required this.vertices,
    required this.indices,
    required this.material,
    required this.bounds,
    required this.hasTangents,
    this.skin,
  });

  /// [kVertexFloats] floats per vertex.
  final Float32List vertices;

  /// Three per triangle.
  final Uint32List indices;

  /// Material index, or null for the default material.
  final int? material;

  /// Local bounds of the positions.
  final Aabb3 bounds;

  /// Whether tangents came from the file (otherwise the shader derives them).
  final bool hasTangents;

  /// [kSkinFloats] floats per vertex (joints, weights) when the primitive is
  /// skinned, else null.
  final Float32List? skin;

  /// How many vertices there are.
  int get vertexCount => vertices.length ~/ kVertexFloats;
}

/// How a material treats alpha.
enum AlphaMode {
  /// Alpha ignored.
  opaque,

  /// Fragments below the cutoff are discarded.
  mask,

  /// Blended, drawn after opaque geometry, back to front.
  blend,
}

/// A glTF metallic-roughness material, with the extensions this renderer
/// reads (`KHR_materials_unlit`, `KHR_materials_emissive_strength`,
/// `KHR_texture_transform`).
final class MaterialData {
  /// A material; defaults are the glTF spec's.
  const MaterialData({
    this.name,
    this.baseColor = const (1.0, 1.0, 1.0, 1.0),
    this.baseColorTexture,
    this.metallic = 1.0,
    this.roughness = 1.0,
    this.metallicRoughnessTexture,
    this.normalTexture,
    this.normalScale = 1.0,
    this.occlusionTexture,
    this.occlusionStrength = 1.0,
    this.emissive = const (0.0, 0.0, 0.0),
    this.emissiveTexture,
    this.emissiveStrength = 1.0,
    this.alphaMode = AlphaMode.opaque,
    this.alphaCutoff = 0.5,
    this.doubleSided = false,
    this.unlit = false,
    this.uvMode = UvMode.natural,
    this.layered = false,
    this.layerTiling = const (1.0, 1.0, 1.0, 1.0),
  });

  /// The material used where a primitive names none.
  static const MaterialData fallback = MaterialData(name: 'default');

  /// Name in the file.
  final String? name;

  /// Linear RGBA multiplier.
  final (double, double, double, double) baseColor;

  /// sRGB base colour texture.
  final TextureRef? baseColorTexture;

  /// Metalness, 0..1.
  final double metallic;

  /// Roughness, 0..1.
  final double roughness;

  /// Roughness in G, metalness in B.
  final TextureRef? metallicRoughnessTexture;

  /// Tangent-space normal map.
  final TextureRef? normalTexture;

  /// Scale of the normal map's x and y.
  final double normalScale;

  /// Ambient occlusion in R.
  final TextureRef? occlusionTexture;

  /// How much occlusion applies, 0..1.
  final double occlusionStrength;

  /// Linear emissive colour.
  final (double, double, double) emissive;

  /// sRGB emissive texture.
  final TextureRef? emissiveTexture;

  /// `KHR_materials_emissive_strength` multiplier.
  final double emissiveStrength;

  /// How alpha is used.
  final AlphaMode alphaMode;

  /// Cutoff for [AlphaMode.mask].
  final double alphaCutoff;

  /// Whether back faces are drawn too.
  final bool doubleSided;

  /// `KHR_materials_unlit`: base colour only, no lighting.
  final bool unlit;

  /// Where its textures are read: the mesh's own UVs, or the world's
  /// coordinates seen along the face's main axis — tiled per metre by the
  /// base colour texture's scale, the same on every face and size.
  final UvMode uvMode;

  /// Four colour layers instead of the maps: base colour, metal-rough,
  /// normal and occlusion hold the layers, blended by the vertex colour
  /// (R, G, B, A weigh them) and read in world coordinates tiled per metre
  /// by [layerTiling]. What a terrain is painted with. No normal map then.
  final bool layered;

  /// How many times each of the four layers repeats per metre.
  final (double, double, double, double) layerTiling;
}

/// Where a material's textures are read.
enum UvMode {
  /// The mesh's own texture coordinates.
  natural,

  /// The world's, seen along each face's main axis: a texture tiles the
  /// same way on every face, whatever the mesh's size.
  world,
}

/// A material's use of a texture.
final class TextureRef {
  /// Texture [texture] read with UV set [texCoord] and an optional
  /// `KHR_texture_transform`.
  const TextureRef(
    this.texture, {
    this.texCoord = 0,
    this.offset = const (0.0, 0.0),
    this.scale = const (1.0, 1.0),
    this.rotation = 0.0,
  });

  /// Texture index.
  final int texture;

  /// UV set (only 0 is uploaded; 1 falls back to 0).
  final int texCoord;

  /// UV offset.
  final (double, double) offset;

  /// UV scale.
  final (double, double) scale;

  /// UV rotation, radians.
  final double rotation;

  /// Whether it moves UVs at all.
  bool get hasTransform =>
      offset != (0.0, 0.0) || scale != (1.0, 1.0) || rotation != 0.0;
}

/// A texture: an image and how to sample it.
final class TextureData {
  /// Image [image] (null when the file's source is unsupported).
  const TextureData(this.image, this.sampler);

  /// Image index.
  final int? image;

  /// Sampling.
  final SamplerData sampler;
}

/// glTF sampler state (GL enum values).
final class SamplerData {
  /// Defaults: linear, linear-mipmap-linear, repeat.
  const SamplerData({
    this.magFilter = 9729,
    this.minFilter = 9987,
    this.wrapS = 10497,
    this.wrapT = 10497,
  });

  /// GL_NEAREST 9728 or GL_LINEAR 9729.
  final int magFilter;

  /// GL minification filter.
  final int minFilter;

  /// GL wrap mode for u: 33071 clamp, 33648 mirror, 10497 repeat.
  final int wrapS;

  /// GL wrap mode for v.
  final int wrapT;
}

/// An image as RGBA8 pixels.
final class RgbaImage {
  /// [width] × [height] pixels in [pixels], rows top to bottom.
  const RgbaImage(this.width, this.height, this.pixels);

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Four bytes per pixel.
  final Uint8List pixels;
}

/// An image as stored in the file (PNG, JPEG, …).
final class ImageData {
  /// Encoded [bytes] of [mimeType]; or, from a cooked model, ready
  /// [levels] (and [bytes] empty).
  const ImageData(
    this.bytes,
    this.mimeType,
    this.name, {
    this.levels,
    this.levelsSrgb = true,
  });

  /// The encoded image.
  final Uint8List bytes;

  /// Decoded RGBA levels, largest first, made when the model was cooked —
  /// null for an image still to be decoded. The upload uses them as they
  /// are, without decoding or building mips.
  final List<RgbaImage>? levels;

  /// Whether [levels] were averaged in sRGB (a colour map's) rather than
  /// linearly (a data map's).
  final bool levelsSrgb;

  /// `image/png`, `image/jpeg`, … or null when the file did not say.
  final String? mimeType;

  /// Name or URI, for messages.
  final String? name;
}

/// A node of the model's tree.
final class NodeData {
  /// A node with its [local] transform.
  NodeData({
    required this.name,
    required this.local,
    required this.children,
    this.mesh,
    this.skin,
    this.light,
    this.translation,
    this.rotation,
    this.scale,
  });

  /// Name in the file.
  final String? name;

  /// Transform relative to its parent.
  final Matrix4 local;

  /// Child node indices.
  final List<int> children;

  /// Mesh index.
  final int? mesh;

  /// Skin index.
  final int? skin;

  /// Light index (`KHR_lights_punctual`).
  final int? light;

  /// The rest pose's translation, rotation and scale, when the file gave
  /// them (an animated node always does); null for a node given as a
  /// matrix, which can't be animated.
  final Vector3? translation;

  /// See [translation].
  final Quaternion? rotation;

  /// See [translation].
  final Vector3? scale;
}

/// A glTF skin: the nodes that are its joints and how the mesh sat on them.
final class SkinData {
  /// A skin over [joints].
  const SkinData({
    this.name,
    required this.joints,
    required this.inverseBindMatrices,
    this.skeleton,
  });

  /// Name in the file.
  final String? name;

  /// Node index of each joint; a vertex's joint index points into this.
  final List<int> joints;

  /// One column-major 4x4 matrix (16 floats) per joint, taking a vertex
  /// from model space to the joint's space at bind time.
  final Float32List inverseBindMatrices;

  /// The skeleton's root node, when the file names it.
  final int? skeleton;
}

/// What an animation channel moves.
enum AnimationPath {
  /// A node's translation.
  translation,

  /// A node's rotation.
  rotation,

  /// A node's scale.
  scale,

  /// Morph target weights (not played yet).
  weights,
}

/// How values between keys are found.
enum AnimationInterpolation {
  /// Straight lines; rotations by spherical interpolation.
  linear,

  /// Each key's value holds until the next.
  step,

  /// Hermite curves with tangents stored beside each key.
  cubicSpline,
}

/// Keyframes: times and values.
final class AnimationSamplerData {
  /// Keys at [input] times with [output] values ([width] floats each; three
  /// per key for [AnimationInterpolation.cubicSpline]: in-tangent, value,
  /// out-tangent).
  const AnimationSamplerData({
    required this.input,
    required this.output,
    required this.interpolation,
    required this.width,
  });

  /// Key times in seconds, increasing.
  final Float32List input;

  /// Key values.
  final Float32List output;

  /// How to interpolate.
  final AnimationInterpolation interpolation;

  /// Floats per value: 3 (translation, scale) or 4 (rotation).
  final int width;
}

/// One animated property of one node.
final class AnimationChannelData {
  /// [path] of [node] driven by sampler [sampler].
  const AnimationChannelData({
    required this.sampler,
    required this.node,
    required this.path,
  });

  /// Sampler index in its animation.
  final int sampler;

  /// Node index.
  final int node;

  /// What it moves.
  final AnimationPath path;
}

/// A glTF animation (a clip).
final class AnimationData {
  /// An animation of [channels] reading [samplers].
  const AnimationData({
    required this.name,
    required this.channels,
    required this.samplers,
    required this.duration,
  });

  /// Its name: the file's, or `animation <index>`.
  final String name;

  /// What it moves.
  final List<AnimationChannelData> channels;

  /// Keyframes.
  final List<AnimationSamplerData> samplers;

  /// The last key time, in seconds.
  final double duration;
}

/// A punctual light.
enum LightType { directional, point, spot }

/// `KHR_lights_punctual`: a light pointing down its node's -Z.
final class LightData {
  /// A light.
  const LightData({
    required this.type,
    this.name,
    this.color = const (1.0, 1.0, 1.0),
    this.intensity = 1.0,
    this.range,
    this.innerConeAngle = 0.0,
    this.outerConeAngle = 0.7853981633974483,
  });

  /// Kind.
  final LightType type;

  /// Name in the file.
  final String? name;

  /// Linear colour.
  final (double, double, double) color;

  /// Lux (directional) or candela (point, spot).
  final double intensity;

  /// Where it stops, or null for no limit.
  final double? range;

  /// Spot: full intensity inside this angle.
  final double innerConeAngle;

  /// Spot: no light outside this angle.
  final double outerConeAngle;
}

import 'dart:typed_data';

import 'package:just_dart/just_dart.dart';

import '../assets/animation_clip.dart';
import 'gpu_model.dart';
import 'render_scene.dart';
import 'skinning.dart';

/// One placed copy of a model in a pose of its own: what an animated
/// character is to the renderer.
///
/// Set [pose] (sample clips into it), call [update], then [place] with the
/// model root's world matrix: the instances it was added with
/// (`RenderScene.addModel(..., posed: this)`) move with its nodes, and
/// skinned ones with its joints.
final class PosedModel {
  /// [model] in its rest pose.
  PosedModel(this.model)
    : pose = Pose.rest(model.data),
      nodeMatrices = Float32List(model.data.nodes.length * 16),
      palettes = [
        for (final skin in model.data.skins) SkinPalette(skin.joints.length),
      ],
      skinBounds = [for (final _ in model.data.skins) Aabb3()] {
    update();
  }

  /// The model.
  final GpuModel model;

  /// The pose shown after the next [update].
  final Pose pose;

  /// Model-space matrices of every node in the pose, 16 floats each.
  final Float32List nodeMatrices;

  /// Each skin's joint palette.
  final List<SkinPalette> palettes;

  /// Each skin's bounds in model space.
  final List<Aabb3> skinBounds;

  /// The instances that show it.
  final List<MeshInstance> instances = [];

  final Matrix4 _node = Matrix4.identity();

  /// Brings [nodeMatrices], [palettes] and [skinBounds] up to [pose].
  void update() {
    final skeleton = model.skeleton;
    skeleton.evaluate(pose, nodeMatrices);
    for (var s = 0; s < palettes.length; s++) {
      skeleton.palette(s, nodeMatrices, palettes[s].rows);
      skeleton.boundsInto(s, nodeMatrices, skinBounds[s]);
    }
  }

  /// Moves [instances] for the model root at [worldFromModelRoot] (engine
  /// world from the model's own axes, so including `gltfToEngine`): rigid
  /// meshes to their nodes, skinned ones to the root (their joints place
  /// them).
  void place(Matrix4 worldFromModelRoot) {
    for (final instance in instances) {
      if (instance.skin != null ||
          instance.node < 0 ||
          _skinned(instance.node)) {
        instance.world.setFrom(worldFromModelRoot);
      } else {
        nodeMatrixInto(instance.node, _node);
        instance.world.setProduct(worldFromModelRoot, _node);
      }
      instance.markMoved();
    }
  }

  bool _skinned(int node) => model.data.nodes[node].skin != null;

  /// Node [node]'s model-space matrix in the pose, into [out].
  void nodeMatrixInto(int node, Matrix4 out) {
    final s = out.storage;
    for (var i = 0; i < 16; i++) {
      s[i] = nodeMatrices[node * 16 + i];
    }
  }

  /// The index of the node called [name], or -1.
  int nodeNamed(String name) {
    final nodes = model.data.nodes;
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].name == name) return i;
    }
    return -1;
  }
}

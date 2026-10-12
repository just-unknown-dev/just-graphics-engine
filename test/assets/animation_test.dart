// Skins and animations out of glTF, and clips sampled into poses.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/assets.dart';
import 'package:just_graphics_engine/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ModelData bar;
  setUpAll(() async => bar = await loadModelData(skinnedBarGlb(), name: 'bar'));

  int node(String name) => bar.nodes.indexWhere((n) => n.name == name);

  test('a skin: its joints, their inverse bind matrices, weights per vertex', () {
    expect(bar.skins, hasLength(1));
    final skin = bar.skins.single;
    expect(skin.joints, [node('root'), node('tip')]);
    expect(skin.skeleton, node('root'));
    // tip sits 1 m up, so its inverse bind matrix moves 1 m down.
    expect(skin.inverseBindMatrices.sublist(16), [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -1, 0, 1]);
    final primitive = bar.meshes.single.primitives.single;
    final data = primitive.skin!;
    expect(data.length, primitive.vertexCount * kSkinFloats);
    for (var v = 0; v < primitive.vertexCount; v++) {
      final sum = data[v * 8 + 4] + data[v * 8 + 5] + data[v * 8 + 6] + data[v * 8 + 7];
      expect(sum, closeTo(1, 1e-6), reason: 'vertex $v weights sum to 1');
    }
    // The mesh node carries the skin; the bounds are the bind pose's.
    expect(bar.nodes[node('Bar')].skin, 0);
    expect(bar.bounds.max.y, closeTo(2, 1e-6));
  });

  test('animations: channels, samplers, interpolation and length', () {
    expect(bar.animations.map((a) => a.name), ['bend', 'hop', 'grow']);
    final bend = bar.animations[0];
    expect(bend.duration, 1);
    expect(bend.channels.single.node, node('tip'));
    expect(bend.channels.single.path, AnimationPath.rotation);
    expect(bend.samplers.single.width, 4);
    expect(bar.animations[1].samplers.single.interpolation, AnimationInterpolation.step);
    expect(bar.animations[2].samplers.single.interpolation, AnimationInterpolation.cubicSpline);
    // Nodes keep their rest pose as translation, rotation and scale.
    expect(bar.nodes[node('tip')].translation!.y, 1);
  });

  test('the mannequin: 16 joints, a walk and an idle, standing on the ground', () async {
    final m = await loadModelData(mannequinGlb(), name: 'mannequin');
    expect(m.warnings, isEmpty);
    expect(m.skins.single.joints, hasLength(16));
    expect(m.animations.map((a) => a.name), containsAll(['walk', 'idle']));
    expect(m.animations.firstWhere((a) => a.name == 'walk').duration, 1);
    expect(m.bounds.min.y, closeTo(0, 1e-6));
    expect(m.bounds.max.y, closeTo(1.82, 0.01));
  });

  group('sampling', () {
    double angleAboutZ(Pose pose, int n) =>
        2 * math.atan2(pose.rotations[n * 4 + 2], pose.rotations[n * 4 + 3]);

    test('linear rotations turn at an even rate (slerp)', () {
      final clip = AnimationClip(bar.animations[0]);
      final pose = Pose.rest(bar);
      final tip = node('tip');
      for (final (t, degrees) in [(0.0, 0.0), (0.25, 22.5), (0.5, 45.0), (1.0, 90.0)]) {
        clip.sample(t, pose);
        expect(angleAboutZ(pose, tip) * 180 / math.pi, closeTo(degrees, 1e-3), reason: 't = $t');
      }
      // Before the first key and after the last: held.
      clip.sample(-1, pose);
      expect(angleAboutZ(pose, tip), closeTo(0, 1e-6));
      clip.sample(5, pose);
      expect(angleAboutZ(pose, tip) * 180 / math.pi, closeTo(90, 1e-3));
      // Going back in time finds the right key too.
      clip.sample(0.25, pose);
      expect(angleAboutZ(pose, tip) * 180 / math.pi, closeTo(22.5, 1e-3));
    });

    test('step keys hold until the next', () {
      final clip = AnimationClip(bar.animations[1]);
      final pose = Pose.rest(bar);
      final root = node('root');
      for (final (t, y) in [(0.0, 0.0), (0.49, 0.0), (0.5, 0.5), (0.99, 0.5), (1.0, 0.0)]) {
        clip.sample(t, pose);
        expect(pose.translations[root * 3 + 1], closeTo(y, 1e-6), reason: 't = $t');
      }
    });

    test('cubic splines with flat tangents ease in and out', () {
      final clip = AnimationClip(bar.animations[2]);
      final pose = Pose.rest(bar);
      final root = node('root');
      for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        clip.sample(t, pose);
        final smooth = 3 * t * t - 2 * t * t * t;
        expect(pose.scales[root * 3], closeTo(1 + smooth, 1e-6), reason: 't = $t');
      }
    });

    test('a clip leaves the nodes it does not move alone', () {
      final pose = Pose.rest(bar);
      AnimationClip(bar.animations[0]).sample(0.5, pose);
      expect(pose.translations[node('tip') * 3 + 1], 1, reason: 'tip keeps its rest translation');
      expect(pose.scales[node('root') * 3], 1);
    });

    test('poses blend: positions linearly, rotations the short way', () {
      final a = Pose.rest(bar), b = Pose.rest(bar), out = Pose.rest(bar);
      final tip = node('tip');
      AnimationClip(bar.animations[0]).sample(1, b);
      b.translations[tip * 3] = 2;
      out.blend(a, b, 0.5);
      expect(angleAboutZ(out, tip) * 180 / math.pi, closeTo(45, 1e-3));
      expect(out.translations[tip * 3], closeTo(1, 1e-6));
      // A rotation and its negation are the same turn: no long way round.
      for (var c = 0; c < 4; c++) {
        b.rotations[tip * 4 + c] = -b.rotations[tip * 4 + c];
      }
      out.blend(a, b, 0.5);
      expect(angleAboutZ(out, tip).abs() * 180 / math.pi, closeTo(45, 1e-3));
    });
  });
}

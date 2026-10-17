import 'package:just_dart/just_dart.dart';

import '../assets/model_data.dart' show LightType;
import 'environment_map.dart';
import 'gpu_model.dart';
import 'instance_batch.dart';
import 'posed_model.dart';
import 'skinning.dart';

/// glTF is +Y up; the engine is +Y down with +Z into the screen. A 180°
/// turn about X takes one to the other. It is a rotation, not a mirror, so
/// triangle winding is kept.
final Matrix4 gltfToEngine = Matrix4.diagonal3Values(1, -1, -1);

/// One primitive drawn somewhere in the world.
final class MeshInstance {
  /// [primitive] with [material], placed by [world].
  MeshInstance(GpuPrimitive primitive, this.material, Matrix4 world)
    : _primitive = primitive {
    this.world.setFrom(world);
  }

  /// What is drawn. A shape whose sizes change is given another.
  GpuPrimitive get primitive => _primitive;
  set primitive(GpuPrimitive value) {
    if (identical(value, _primitive)) return;
    _primitive = value;
    _boundsStale = true;
  }

  GpuPrimitive _primitive;

  /// How it looks. A shape whose look changes is given another.
  GpuMaterial material;

  /// World from local.
  final Matrix4 world = Matrix4.identity();

  /// Drawn at all.
  bool visible = true;

  /// Casts shadows.
  bool castShadows = true;

  /// The node of its model that placed it, or -1.
  int node = -1;

  /// A skinned instance's posed palette: when set (and the primitive is
  /// skinned) it is drawn skinned.
  SkinPalette? skin;

  /// Its bounds in its own space when they are not its primitive's (a
  /// posed skin's reach); null uses the primitive's.
  Aabb3? localBounds;

  final Aabb3 _bounds = Aabb3();
  bool _boundsStale = true;

  /// Moves the instance.
  void setWorld(Matrix4 m) {
    world.setFrom(m);
    _boundsStale = true;
  }

  /// [world] was changed in place: recompute bounds.
  void markMoved() => _boundsStale = true;

  /// World-space bounds.
  Aabb3 get bounds {
    if (_boundsStale) {
      (localBounds ?? primitive.bounds).transformInto(world, _bounds);
      _boundsStale = false;
    }
    return _bounds;
  }
}

/// The sun: light travelling along [direction].
final class DirectionalLight {
  /// A white sun shining down and forward.
  DirectionalLight({Vector3? direction, this.color = const (1.0, 1.0, 1.0)})
    : direction = direction ?? (Vector3(0.3, 1, 0.5)..normalize());

  /// The way the light travels (+Y is down).
  final Vector3 direction;

  /// Linear colour.
  (double, double, double) color;

  /// Lux-ish multiplier.
  double intensity = 3.0;

  /// Whether it shines.
  bool enabled = true;
}

/// A point or spot light.
final class PunctualLight {
  /// A light of [type] at [position].
  PunctualLight({
    required this.type,
    Vector3? position,
    Vector3? direction,
    this.color = const (1.0, 1.0, 1.0),
    this.intensity = 10.0,
    this.range,
    this.innerConeAngle = 0.0,
    this.outerConeAngle = 0.7853981633974483,
  }) : position = position ?? Vector3.zero(),
       direction = direction ?? Vector3(0, 1, 0);

  /// Point or spot.
  LightType type;

  /// Where it is.
  final Vector3 position;

  /// Spot: the way it points (light travels).
  final Vector3 direction;

  /// Linear colour.
  (double, double, double) color;

  /// Candela-ish multiplier.
  double intensity;

  /// Where it stops, or null.
  double? range;

  /// Spot: full intensity inside.
  double innerConeAngle;

  /// Spot: dark outside.
  double outerConeAngle;
}

/// The sky and the light that doesn't come from lights.
final class Environment {
  /// Zenith, horizon and ground of the gradient sky (linear).
  (double, double, double) zenith = (0.25, 0.45, 0.85);

  /// Horizon colour.
  (double, double, double) horizon = (0.75, 0.85, 0.95);

  /// Below the horizon.
  (double, double, double) ground = (0.35, 0.32, 0.30);

  /// Ambient from above (hemisphere light).
  (double, double, double) ambientSky = (0.35, 0.40, 0.50);

  /// Ambient from below.
  (double, double, double) ambientGround = (0.15, 0.13, 0.12);

  /// Exposure before tonemapping.
  double exposure = 1.0;

  /// Whether the gradient sky is drawn; otherwise [clearColor].
  bool sky = true;

  /// Background when there is no sky (linear).
  (double, double, double) clearColor = (0.05, 0.05, 0.07);

  /// Fog colour (linear).
  (double, double, double) fogColor = (0.7, 0.75, 0.8);

  /// How thick fog is, per metre: 0 for none; 0.02 hides things a hundred
  /// metres off.
  double fogDensity = 0;

  /// Metres from the camera where fog begins.
  double fogStart = 0;

  /// What surrounds the scene, for its ambient light and reflections (and
  /// the [skybox]); null for the hemisphere light ([ambientSky],
  /// [ambientGround]).
  GpuEnvironmentMap? map;

  /// How strong [map]'s reflections are: 0 for none (its diffuse light
  /// still counts).
  double reflections = 1;

  /// Whether the sky shows [map] rather than the gradient.
  bool skybox = false;

  /// How blurred the skybox is: 0 sharp, 1 its blurriest level.
  double skyboxBlur = 0;
}

/// Everything the renderer draws in one view.
final class RenderScene {
  /// Mesh instances.
  final List<MeshInstance> instances = [];

  /// Many copies of a mesh each, drawn in a call each: grass, tiles.
  final List<InstanceBatch> batches = [];

  /// Lines drawn over everything else: a selection's highlight.
  final List<OverlayDraw> overlays = [];

  /// The sun.
  final DirectionalLight sun = DirectionalLight();

  /// Point and spot lights (the 8 that matter most to a frame are used).
  final List<PunctualLight> lights = [];

  /// Sky and ambient.
  final Environment environment = Environment();

  /// Adds an instance for every primitive of every mesh node of [model],
  /// placed at [worldFromModel] (engine world from the model's root). glTF
  /// axes are converted to the engine's unless [correctAxes] is false.
  ///
  /// With [posed], the instances follow its pose (see
  /// [PosedModel.place]) and skinned primitives are drawn skinned;
  /// without, the model shows its rest pose and skins their bind pose.
  List<MeshInstance> addModel(
    GpuModel model,
    Matrix4 worldFromModel, {
    bool correctAxes = true,
    PosedModel? posed,
  }) {
    final added = <MeshInstance>[];
    final root = correctAxes
        ? worldFromModel.multiplied(gltfToEngine)
        : Matrix4.copy(worldFromModel);
    final skins = model.data.skins.length;
    model.data.forEachNode((node, modelFromNode) {
      final data = model.data.nodes[node];
      final mesh = data.mesh;
      if (mesh == null || mesh >= model.meshes.length) return;
      final skin = data.skin != null && data.skin! < skins ? data.skin : null;
      // A skinned mesh is placed by its joints, not by its node.
      final world = skin != null
          ? Matrix4.copy(root)
          : root.multiplied(modelFromNode);
      for (final primitive in model.meshes[mesh]) {
        final instance = MeshInstance(
          primitive,
          model.materialOf(primitive),
          world,
        )..node = node;
        if (posed != null && skin != null && primitive.skin != null) {
          instance
            ..skin = posed.palettes[skin]
            ..localBounds = posed.skinBounds[skin];
        }
        added.add(instance);
      }
    });
    instances.addAll(added);
    if (posed != null) {
      posed.instances.addAll(added);
      posed.place(root);
    }
    return added;
  }
}

/// The camera a frame is drawn from, in the renderer's conventions: +Y
/// down, clip y down, depth 0..1 (`JustMatrix4.setPerspectiveYDown`).
final class RenderView {
  /// World → camera.
  final Matrix4 view = Matrix4.identity();

  /// Camera → clip.
  final Matrix4 projection = Matrix4.identity();

  /// Where the camera is.
  final Vector3 cameraPosition = Vector3.zero();

  /// Pixels to render.
  int width = 1;

  /// Pixels to render.
  int height = 1;

  /// Sets [view] to look from [eye] at [target], with [up] (default -Y,
  /// the engine's up).
  void lookAt(Vector3 eye, Vector3 target, {Vector3? up}) {
    final u = up ?? Vector3(0, -1, 0);
    // The engine's camera looks along +Z with +Y down: forward f, right r =
    // up × f... with +Y down, screen-down is -up.
    final f = (target - eye)..normalize();
    final down = Vector3(-u.x, -u.y, -u.z);
    // right = down × forward (x right, y down, z forward is right-handed).
    final r = down.cross(f)..normalize();
    final d = f.cross(r);
    final m = view.storage;
    m[0] = r.x;
    m[4] = r.y;
    m[8] = r.z;
    m[1] = d.x;
    m[5] = d.y;
    m[9] = d.z;
    m[2] = f.x;
    m[6] = f.y;
    m[10] = f.z;
    m[3] = 0;
    m[7] = 0;
    m[11] = 0;
    m[12] = -(r.x * eye.x + r.y * eye.y + r.z * eye.z);
    m[13] = -(d.x * eye.x + d.y * eye.y + d.z * eye.z);
    m[14] = -(f.x * eye.x + f.y * eye.y + f.z * eye.z);
    m[15] = 1;
    cameraPosition.setFrom(eye);
  }
}

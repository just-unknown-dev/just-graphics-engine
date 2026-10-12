// just_graphics_engine on its own, with no game engine: glTF models in a
// RenderScene with a sun, a lamp and a sky, drawn by Scene3DView. A crate
// spins and two mannequins walk and idle. Drag to orbit, scroll to zoom.
//
// The runners turn Flutter GPU on (windows/runner/main.cpp,
// linux/runner/my_application.cc, the Android manifest, the Info.plists).
// Where it is not available (the web, Android without Vulkan) a note says
// why nothing is drawn.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_graphics_engine/just_graphics_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? reason;
  final renderer = await Renderer3D.tryCreate(onUnsupported: (r) => reason = r);
  final demo = renderer == null ? null : await Demo.load(renderer, rootBundle);
  runApp(DemoApp(renderer: renderer, demo: demo, unsupportedReason: reason));
}

/// The demo's scene: models on a ground, a spinning crate and two animated
/// mannequins, in the renderer's axes (+Y down, metres).
final class Demo {
  Demo._(this.scene);

  /// What is drawn.
  final RenderScene scene;

  final List<_Mover> _movers = [];

  /// Loads the models from [bundle] (`assets/models/`), uploads them with
  /// [renderer] and places them.
  static Future<Demo> load(Renderer3D renderer, AssetBundle bundle) async {
    Future<GpuModel> model(String name) async {
      final data = await bundle.load('assets/models/$name.glb');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return renderer.uploader.upload(await loadModelData(bytes, name: name));
    }

    final ground = await model('ground');
    final crate = await model('crate');
    final ball = await model('ball');
    final pillar = await model('pillar');
    final mannequin = await model('mannequin');

    final demo = Demo._(RenderScene());
    final scene = demo.scene;
    void place(GpuModel m, double x, double y, double z, {double yaw = 0}) =>
        scene.addModel(m, _placement(x, y, z, yaw, 1));

    place(ground, 0, 0, 0);
    place(crate, -2, 0, 1, yaw: 0.3);
    place(crate, -2.1, -1, 1.05, yaw: 0.9);
    place(crate, -0.7, 0, 2.6, yaw: -0.4);
    place(ball, 1.4, 0, 0.4);
    for (final x in [-3.0, -1.0, 1.0, 3.0]) {
      place(pillar, x, 0, 5.5);
    }
    // Moved every frame: a PosedModel moves the instances it was added with.
    demo._add(scene, crate, null, 2.4, 2.6, 0, scale: 0.7, spin: 1);
    demo._add(scene, mannequin, 'walk', -0.4, 1, 0.5);
    demo._add(scene, mannequin, 'idle', 0.6, 2.6, -0.7);

    scene.sun
      ..direction.setValues(-0.35, 0.8, 0.5)
      ..intensity = 3;
    scene.sun.direction.normalize();
    scene.lights.add(
      PunctualLight(
        type: LightType.point,
        position: Vector3(0.4, -1.6, -0.6),
        color: (1.0, 0.45, 0.16),
        intensity: 12,
        range: 8,
      ),
    );
    return demo;
  }

  void _add(
    RenderScene scene,
    GpuModel model,
    String? clip,
    double x,
    double z,
    double yaw, {
    double scale = 1,
    double spin = 0,
  }) {
    final posed = PosedModel(model);
    scene.addModel(model, _placement(x, 0, z, yaw, scale), posed: posed);
    _movers.add(
      _Mover(
        posed,
        clip == null ? null : model.clips[clip],
        x,
        z,
        yaw,
        scale,
        spin,
      ),
    );
  }

  /// Moves the spinning crate and the mannequins on to [seconds].
  void update(double seconds) {
    for (final m in _movers) {
      final clip = m.clip;
      if (clip != null && clip.duration > 0) {
        clip.sample(seconds % clip.duration, m.posed.pose);
        m.posed.update();
      }
      m.posed.place(
        _placement(m.x, 0, m.z, m.yaw + m.spin * seconds, m.scale)
          ..multiply(gltfToEngine),
      );
    }
  }

  static Matrix4 _placement(
    double x,
    double y,
    double z,
    double yaw,
    double scale,
  ) => Matrix4.identity()
    ..setFromTrs(
      Vector3(x, y, z),
      Quaternion.euler(0, yaw, 0),
      Vector3(scale, scale, scale),
    );
}

final class _Mover {
  _Mover(
    this.posed,
    this.clip,
    this.x,
    this.z,
    this.yaw,
    this.scale,
    this.spin,
  );

  final PosedModel posed;
  final AnimationClip? clip;
  final double x, z, yaw, scale, spin;
}

/// The view, with an orbiting camera and a line of stats.
class DemoApp extends StatefulWidget {
  /// Shows [demo] drawn by [renderer], or why there is no 3D.
  const DemoApp({
    super.key,
    required this.renderer,
    required this.demo,
    this.unsupportedReason,
  });

  /// What draws, or null where Flutter GPU can't.
  final Renderer3D? renderer;

  /// What is drawn; null without a renderer.
  final Demo? demo;

  /// Why there is no renderer.
  final String? unsupportedReason;

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  // The camera circles this point (+Y is down).
  final Vector3 _target = Vector3(0, -0.8, 1.5);
  final Vector3 _eye = Vector3.zero();
  final RenderView _camera = RenderView();
  final RenderScene _empty = RenderScene();
  double _yaw = -0.5;
  double _pitch = -0.45;
  double _distance = 10;
  Timer? _stats;
  String _line = '';

  @override
  void initState() {
    super.initState();
    _stats = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final renderer = widget.renderer;
      if (renderer != null) setState(() => _line = '${renderer.stats}');
    });
  }

  @override
  void dispose() {
    _stats?.cancel();
    super.dispose();
  }

  void _frame(Duration elapsed, Size size) {
    widget.demo?.update(elapsed.inMicroseconds / 1e6);
    final cp = math.cos(_pitch);
    _eye.setValues(
      _target.x - math.sin(_yaw) * cp * _distance,
      _target.y + math.sin(_pitch) * _distance,
      _target.z - math.cos(_yaw) * cp * _distance,
    );
    _camera.lookAt(_eye, _target);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF15171C),
        body: Stack(
          children: [
            Listener(
              onPointerMove: (e) {
                if (e.buttons == 0) return;
                _yaw += e.delta.dx * 0.008;
                _pitch = (_pitch - e.delta.dy * 0.008).clamp(-1.5, 0.2);
              },
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) {
                  _distance = (_distance * math.pow(1.0015, e.scrollDelta.dy))
                      .clamp(2.0, 60.0);
                }
              },
              child: Scene3DView(
                renderer: widget.renderer,
                scene: widget.demo?.scene ?? _empty,
                camera: _camera,
                fieldOfView: math.pi / 3,
                onFrame: _frame,
                unsupportedReason: widget.unsupportedReason,
              ),
            ),
            Positioned(
              left: 12,
              bottom: 12,
              child: Text(
                _line,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

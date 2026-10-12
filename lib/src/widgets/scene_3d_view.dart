import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:just_dart/just_dart.dart';

import '../gpu/device.dart';
import '../renderer/render_scene.dart';
import '../renderer/renderer3d.dart';

/// Called before [Scene3DView] draws a frame: move the camera, animate the
/// scene. [elapsed] is the time since the view started ticking; [size] is
/// its size in logical pixels.
typedef Scene3DFrameCallback = void Function(Duration elapsed, Size size);

/// Draws [scene] seen from [camera] with [renderer], every frame.
///
/// ```dart
/// String? reason;
/// final renderer = await Renderer3D.tryCreate(onUnsupported: (r) => reason = r);
/// final scene = RenderScene();
/// // ... upload models with renderer.uploader and add them to scene ...
/// Scene3DView(
///   renderer: renderer,
///   scene: scene,
///   camera: RenderView()..lookAt(Vector3(0, -2, -6), Vector3.zero()),
///   fieldOfView: math.pi / 3,
///   unsupportedReason: reason,
/// );
/// ```
///
/// It fills the space it is given. Each frame it sets [camera]'s size in
/// pixels from its own (times the device pixel ratio and [renderScale])
/// and, when [fieldOfView] is given, a perspective projection with the
/// view's aspect ratio; otherwise the projection is left to [onFrame].
///
/// Where there is no Flutter GPU [renderer] is null and the view shows
/// [unsupportedReason] instead. If drawing fails it stops and shows why.
class Scene3DView extends StatefulWidget {
  /// A view drawing [scene] from [camera] with [renderer].
  const Scene3DView({
    super.key,
    required this.renderer,
    required this.scene,
    required this.camera,
    this.fieldOfView,
    this.near = 0.1,
    this.far = 500,
    this.renderScale = 1.0,
    this.animate = true,
    this.onFrame,
    this.onRendered,
    this.unsupportedReason,
  });

  /// What draws, or null where Flutter GPU can't (see
  /// [Renderer3D.tryCreate]).
  final Renderer3D? renderer;

  /// What is drawn.
  final RenderScene scene;

  /// Where it is seen from. Its [RenderView.width] and [RenderView.height]
  /// are set by the view.
  final RenderView camera;

  /// The vertical field of view in radians, or null to leave
  /// [camera]'s projection alone.
  final double? fieldOfView;

  /// The near clipping distance, with [fieldOfView].
  final double near;

  /// The far clipping distance, with [fieldOfView].
  final double far;

  /// Fraction of the physical resolution rendered: 0.5 draws a quarter of
  /// the pixels, scaled up.
  final double renderScale;

  /// Whether it draws every frame. False draws when rebuilt only, for a
  /// scene that does not move.
  final bool animate;

  /// Called before each frame is drawn.
  final Scene3DFrameCallback? onFrame;

  /// Called with each frame sent to the GPU: the future completes when the
  /// GPU has drawn it (wait for it before reading pixels back).
  final void Function(Future<bool> done)? onRendered;

  /// Why there is no [renderer], shown in its place.
  final String? unsupportedReason;

  @override
  State<Scene3DView> createState() => _Scene3DViewState();
}

class _Scene3DViewState extends State<Scene3DView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<int> _frames = ValueNotifier(0);
  Duration _elapsed = Duration.zero;
  GpuSurface? _surface;
  Renderer3D? _surfaceOf;
  Object? _failure;

  @override
  void initState() {
    super.initState();
    if (widget.animate) _ticker.start();
  }

  @override
  void didUpdateWidget(Scene3DView old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_ticker.isActive) _ticker.start();
    if (!widget.animate && _ticker.isActive) _ticker.stop();
    if (!identical(widget.renderer, old.renderer)) _failure = null;
    _frames.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frames.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    _frames.value++;
  }

  GpuSurface _surfaceFor(Renderer3D renderer) {
    if (!identical(renderer, _surfaceOf)) {
      _surfaceOf = renderer;
      _surface = renderer.device.createSurface(1, 1);
    }
    return _surface!;
  }

  void _fail(Object error) {
    if (_failure != null || !mounted) return;
    // Painting can't rebuild; the next frame shows the error.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _failure = error);
    });
    _failure = error;
  }

  @override
  Widget build(BuildContext context) {
    final renderer = widget.renderer;
    final failure = _failure;
    if (renderer == null || failure != null) {
      return _Unavailable(
        failure != null
            ? 'Drawing stopped: $failure'
            : widget.unsupportedReason ?? 'There is no GPU device.',
      );
    }
    return CustomPaint(
      size: Size.infinite,
      painter: _ScenePainter(
        this,
        renderer,
        MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0,
      ),
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.state, this.renderer, this.pixelRatio)
    : super(repaint: state._frames);

  final _Scene3DViewState state;
  final Renderer3D renderer;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || state._failure != null) return;
    final widget = state.widget;
    widget.onFrame?.call(state._elapsed, size);
    final scale = pixelRatio * widget.renderScale;
    final camera = widget.camera
      ..width = math.max(1, math.min(8192, (size.width * scale).round()))
      ..height = math.max(1, math.min(8192, (size.height * scale).round()));
    final fov = widget.fieldOfView;
    if (fov != null) {
      camera.projection.setPerspectiveYDown(
        fov,
        size.width / size.height,
        widget.near,
        widget.far,
      );
    }
    final surface = state._surfaceFor(renderer);
    try {
      final done = renderer.render(widget.scene, camera, surface);
      unawaited(done.then((_) {}, onError: state._fail));
      widget.onRendered?.call(done);
    } on Object catch (error) {
      state._fail(error);
      return;
    }
    final image = surface.image;
    if (image == null) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    image.dispose();
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      !identical(old.renderer, renderer) || old.pixelRatio != pixelRatio;
}

/// Shown in place of the 3D image: why there is none.
class _Unavailable extends StatelessWidget {
  const _Unavailable(this.reason);

  final String reason;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xCC202024),
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            '3D is not available here.\n$reason',
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}

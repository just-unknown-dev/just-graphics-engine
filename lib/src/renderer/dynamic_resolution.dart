/// Renders fewer pixels while frames run slow, and more again when there is
/// time to spare: a scale between [minScale] and [maxScale] on top of the
/// renderer's own, stepped by what the last second of frames took.
final class DynamicResolution {
  /// Off until [enabled]; aims for [targetFps].
  DynamicResolution({
    this.enabled = false,
    this.targetFps = 60,
    this.minScale = 0.5,
    this.maxScale = 1.0,
    this.step = 0.1,
  });

  /// Whether it adjusts at all.
  bool enabled;

  /// The frame rate to hold.
  double targetFps;

  /// The lowest scale it goes to.
  double minScale;

  /// The highest scale it goes to.
  double maxScale;

  /// How much the scale moves at a time.
  double step;

  /// The scale now (1 when off).
  double get scale => enabled ? _scale : 1.0;

  double _scale = 1.0;
  double _window = 0;
  int _frames = 0;
  int _slow = 0;
  int _fast = 0;

  /// Tells it the last frame took [seconds]. Once a second it lowers the
  /// scale if most frames missed the target, or raises it if nearly all
  /// had a fifth of their time to spare.
  void frame(double seconds) {
    if (!enabled || seconds <= 0 || seconds > 0.5) return;
    final budget = 1 / targetFps;
    _frames++;
    _window += seconds;
    if (seconds > budget * 1.1) _slow++;
    if (seconds < budget * 0.8) _fast++;
    if (_window < 1) return;
    if (_slow > _frames / 2) {
      _scale = (_scale - step).clamp(minScale, maxScale);
    } else if (_fast > _frames * 0.9) {
      _scale = (_scale + step).clamp(minScale, maxScale);
    }
    _window = 0;
    _frames = _slow = _fast = 0;
  }

  /// Back to full scale, forgetting what it measured.
  void reset() {
    _scale = maxScale.clamp(minScale, 1.0);
    _window = 0;
    _frames = _slow = _fast = 0;
  }
}

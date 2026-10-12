import 'device.dart';

/// Reuses intermediate render targets (depth, MSAA colour, shadow maps,
/// post-processing buffers) from frame to frame instead of allocating new
/// ones.
///
/// Take targets with [acquire] while recording a frame and call [endFrame]
/// once it is submitted: everything taken becomes free for the next frame,
/// and a target nobody asks for again for [keepFrames] frames is dropped.
/// The texture Flutter shows is never pooled; it comes from a
/// [GpuSurface], which knows when Flutter is done with it.
final class RenderTargetPool {
  /// A pool creating its textures on [device].
  RenderTargetPool(this.device, {this.keepFrames = 3});

  /// Where textures are created.
  final GpuDevice device;

  /// Frames an unused target is kept for.
  final int keepFrames;

  final Map<GpuTextureDesc, List<(GpuTexture, int)>> _free = {};
  final List<GpuTexture> _taken = [];
  int _frame = 0;

  /// Textures alive in the pool, taken or free.
  int get size =>
      _taken.length + _free.values.fold(0, (n, list) => n + list.length);

  /// A texture matching [desc] for this frame.
  GpuTexture acquire(GpuTextureDesc desc) {
    final free = _free[desc];
    final texture = (free != null && free.isNotEmpty)
        ? free.removeLast().$1
        : device.createTexture(desc);
    _taken.add(texture);
    return texture;
  }

  /// Frees everything taken this frame and drops long-unused targets.
  void endFrame() {
    for (final texture in _taken) {
      (_free[texture.desc] ??= []).add((texture, _frame));
    }
    _taken.clear();
    _frame++;
    _free.removeWhere((_, list) {
      list.removeWhere((entry) => _frame - entry.$2 > keepFrames);
      return list.isEmpty;
    });
  }

  /// Drops every texture.
  void clear() {
    _free.clear();
    _taken.clear();
  }
}

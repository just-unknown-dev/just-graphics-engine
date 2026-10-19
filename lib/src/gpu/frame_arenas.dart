import 'dart:math' as math;
import 'dart:typed_data';

/// Where a device keeps `GpuDevice.frameData`'s data, a frame at a time.
///
/// Each frame writes into an arena of its own, front to back across blocks
/// of memory, and an arena is written again only once every command list
/// that may read it ([hold]) has finished on the GPU ([release]) — however
/// many frames are recorded before the GPU gets to them. Flutter GPU's own
/// `HostBuffer` reuses a frame's memory four frames later whether or not the
/// GPU has read it: an editor drawing a split view and a preview, five
/// frames before the GPU caught up, drew one view with another's camera.
///
/// [B] is a block of memory: [create] makes one, [write] copies into it.
final class FrameArenas<B extends Object> {
  /// Arenas of blocks [create] makes, at least [blockLength] long, each
  /// write starting at a multiple of [alignment].
  FrameArenas({
    required this.alignment,
    required this.create,
    required this.sizeOf,
    required this.write,
    this.blockLength = 1024 * 1024,
    this.keepSpare = 8,
  }) : assert(alignment > 0);

  /// Where a write may start: a multiple of this many bytes.
  final int alignment;

  /// A new block of at least this many bytes.
  final B Function(int sizeInBytes) create;

  /// How many bytes [block] holds.
  final int Function(B block) sizeOf;

  /// Copies [data] into [block] from [offset].
  final void Function(B block, int offset, ByteData data) write;

  /// The size of a block, unless a single write needs more.
  final int blockLength;

  /// How many arenas the GPU has finished with are kept for reuse; more are
  /// let go.
  final int keepSpare;

  final List<FrameArena<B>> _spare = [];
  FrameArena<B>? _current;

  /// The arena the frame writes into, made when first asked for.
  FrameArena<B> get current =>
      _current ??= _spare.isEmpty ? FrameArena<B>._(this) : _spare.removeLast();

  /// Arenas kept for reuse. For tests.
  int get spareCount => _spare.length;

  /// Starts a frame: what earlier frames wrote stays until the command lists
  /// holding it have finished.
  void beginFrame() {
    final last = _current;
    _current = null;
    if (last != null) _retire(last);
  }

  /// Copies [data] into the frame's arena; returns the block it went into
  /// and where it starts.
  (B, int) place(ByteData data) => current._place(data);

  /// Keeps [arena] from being written again until [release]: a command list
  /// that may read it is recorded or submitted.
  FrameArena<B> hold(FrameArena<B> arena) {
    arena._holds++;
    return arena;
  }

  /// The GPU has finished a command list that held [arena].
  void release(FrameArena<B> arena) {
    assert(arena._holds > 0);
    arena._holds--;
    _retire(arena);
  }

  void _retire(FrameArena<B> arena) {
    if (arena._holds > 0 || identical(arena, _current)) return;
    arena
      .._block = 0
      .._offset = 0;
    if (_spare.length < keepSpare) _spare.add(arena);
  }
}

/// One frame's memory in [FrameArenas].
final class FrameArena<B extends Object> {
  FrameArena._(this._owner);

  final FrameArenas<B> _owner;
  final List<B> _blocks = [];
  int _block = 0;
  int _offset = 0;
  int _holds = 0;

  (B, int) _place(ByteData data) {
    final length = data.lengthInBytes;
    final alignment = _owner.alignment;
    while (true) {
      if (_block == _blocks.length) {
        _blocks.add(_owner.create(math.max(_owner.blockLength, length)));
        _offset = 0;
      }
      final block = _blocks[_block];
      final start = (_offset + alignment - 1) ~/ alignment * alignment;
      if (start + length <= _owner.sizeOf(block)) {
        if (length > 0) _owner.write(block, start, data);
        _offset = start + length;
        return (block, start);
      }
      _block++;
      _offset = 0;
    }
  }
}

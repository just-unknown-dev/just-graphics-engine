// Frame data stays put until the GPU has finished every command list that
// may read it, however many frames are recorded before it gets to them: an
// editor drawing five views a frame, none waiting, drew one with another's
// camera when the memory came back after four frames regardless.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_graphics_engine/src/gpu/frame_arenas.dart';

/// A block of memory the test can read back.
final class _Block {
  _Block(int size) : bytes = Uint8List(size);
  final Uint8List bytes;
}

ByteData _bytes(int value, [int length = 4]) =>
    Uint8List.fromList(List.filled(length, value)).buffer.asByteData();

void main() {
  late List<_Block> made;
  late FrameArenas<_Block> arenas;

  setUp(() {
    made = [];
    arenas = FrameArenas<_Block>(
      alignment: 16,
      blockLength: 64,
      create: (size) {
        final block = _Block(size);
        made.add(block);
        return block;
      },
      sizeOf: (block) => block.bytes.length,
      write: (block, offset, data) =>
          block.bytes.setAll(offset, data.buffer.asUint8List()),
    );
  });

  /// Records a frame writing [value]: begins it, places the data and holds
  /// the arena as a command list would. Returns where the data went and
  /// the held arena.
  ((_Block, int), FrameArena<_Block>) frame(int value) {
    arenas.beginFrame();
    final placed = arenas.place(_bytes(value));
    return (placed, arenas.hold(arenas.current));
  }

  test('frames the GPU has not finished keep their data', () {
    final frames = [for (var i = 1; i <= 8; i++) frame(i)];
    for (var i = 0; i < frames.length; i++) {
      final ((block, offset), _) = frames[i];
      expect(block.bytes[offset], i + 1, reason: 'frame $i');
    }
  });

  test('an arena is written again only after its command lists finish', () {
    final (first, held) = frame(1);
    final (second, _) = frame(2);
    expect(identical(first.$1, second.$1), isFalse);

    arenas.release(held);
    expect(arenas.spareCount, 1);
    final (third, _) = frame(3);
    // The first frame's memory, the GPU done with it.
    expect(identical(third.$1, first.$1), isTrue);
    expect(third.$2, first.$2);
  });

  test('the arena still being written is not given out again', () {
    arenas.beginFrame();
    final arena = arenas.hold(arenas.current);
    arenas.place(_bytes(1));
    // Finished before the next frame begins (a render awaited).
    arenas.release(arena);
    expect(arenas.spareCount, 0);
    final second = arenas.place(_bytes(2));
    expect(second.$2, 16, reason: 'after the first write, aligned');
    arenas.beginFrame();
    expect(arenas.spareCount, 1);
  });

  test('writes are aligned and spill into new blocks', () {
    arenas.beginFrame();
    final a = arenas.place(_bytes(1, 5));
    final b = arenas.place(_bytes(2, 5));
    expect(a.$2, 0);
    expect(b.$2, 16);
    // 48 + 20 > 64: the next block.
    arenas.place(_bytes(3, 10));
    final d = arenas.place(_bytes(4, 20));
    expect(identical(d.$1, a.$1), isFalse);
    expect(d.$2, 0);
    // Bigger than a block: a block of its own size.
    final big = arenas.place(_bytes(5, 200));
    expect(big.$1.bytes.length, 200);
    expect(big.$1.bytes.every((v) => v == 5), isTrue);
  });

  test('a reused arena reuses its blocks', () {
    arenas.beginFrame();
    final arena = arenas.hold(arenas.current);
    arenas.place(_bytes(1, 40));
    arenas.place(_bytes(2, 40));
    arenas.beginFrame();
    arenas.release(arena);
    final count = made.length;

    final (_, again) = frame(3);
    arenas.place(_bytes(4, 40));
    expect(made.length, count, reason: 'no new blocks');
    arenas.release(again);
  });

  test('no more than keepSpare arenas are kept', () {
    final held = [for (var i = 0; i < 12; i++) frame(i).$2];
    arenas.beginFrame();
    for (final arena in held) {
      arenas.release(arena);
    }
    expect(arenas.spareCount, arenas.keepSpare);
  });
}

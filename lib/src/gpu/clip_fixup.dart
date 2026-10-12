import 'package:just_dart/just_dart.dart';

/// The one place the engine's clip space meets Flutter GPU's.
///
/// The renderer's projections put y **down** in clip space
/// (`JustMatrix4.setPerspectiveYDown`), the way a 2-D canvas works. Flutter GPU puts clip-space +Y at the **top** of the image
/// (measured; see ARCHITECTURE.md). The renderer multiplies every projection
/// by a y flip once, here, instead of every shader knowing about it.
///
/// Flipping y mirrors the image, so a triangle's winding as seen on screen
/// flips too: front faces are chosen with [frontFaceIsClockwise].
abstract final class ClipFixup {
  /// Writes [projection] with clip-space y negated into [out]. [out] may be
  /// [projection] itself.
  static void flipY(Matrix4 projection, Matrix4 out) {
    if (!identical(out, projection)) out.setFrom(projection);
    final s = out.storage;
    // Column-major: row 1 (clip y) is elements 1, 5, 9 and 13.
    s[1] = -s[1];
    s[5] = -s[5];
    s[9] = -s[9];
    s[13] = -s[13];
  }

  /// Whether, after [flipY], a triangle the engine considers front-facing
  /// (counter-clockwise around a normal pointing at the camera, as glTF
  /// winds them) has to be declared clockwise to Flutter GPU. It does not:
  /// `test/gpu/device_test.dart` ("back-face culling keeps a triangle that
  /// faces the camera") checks this.
  static const bool frontFaceIsClockwise = false;
}

/// Helpers for testing code that renders with Flutter GPU: a GPU probe that
/// lets tests skip, waiting for submitted work, pixel readback and tolerant
/// image comparison.
///
/// Test-only. Nothing here imports `flutter_test`, so depending on this
/// package does not pull test packages into an app.
library;

export 'src/testing/glb_writer.dart';
export 'src/testing/gpu_test_harness.dart';
export 'src/testing/mannequin.dart';
export 'src/testing/skinned_fixtures.dart';

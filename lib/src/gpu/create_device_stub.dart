import 'device.dart';

/// On the web there is no Flutter GPU: always null, with the reason given
/// to [onUnsupported].
GpuDevice? createGpuDevice({void Function(String reason)? onUnsupported}) {
  onUnsupported?.call(
    'Flutter GPU is not available on the web; 3D needs a native platform.',
  );
  return null;
}

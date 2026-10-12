// The device for this platform: Flutter GPU on native platforms, nothing on
// the web (importing flutter_gpu breaks a web build, so the backend is only
// reachable where dart:ffi exists).
export 'create_device_stub.dart'
    if (dart.library.ffi) 'backend_flutter_gpu/flutter_gpu_device.dart'
    show createGpuDevice;

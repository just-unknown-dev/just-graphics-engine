import '../gpu/backend_null/null_device.dart';

/// The renderer's shaders' uniform blocks as reflection reports them, for a
/// [NullGpuDevice] standing in for a GPU: `NullGpuDevice(shaders:
/// rendererNullShaders)` can create a `Renderer3D`, which then runs its
/// whole CPU side (culling, sorting, batching, uniform packing) and draws
/// nothing. A GPU test checks these against the real reflection.
final Map<String, Map<String, NullUniformBlock>> rendererNullShaders = {
  'LitVertex': {'Frame': _frame},
  'LitSkinnedVertex': {'Frame': _frame},
  'LitSkinnedUniformVertex': {'Frame': _frame, 'Skin': _skin},
  'LitFragment': {
    'Frame': _frame,
    'Lights': const NullUniformBlock('Lights', 528, {
      'count': 0,
      'position_range': 16,
      'color': 144,
      'direction': 272,
      'cone': 400,
    }),
    'Material': const NullUniformBlock('Material', 112, {
      'base_color': 0,
      'emissive': 16,
      'params': 32,
      'flags': 48,
      'uv_transform': 64,
      'uv_rotation': 80,
      'layers': 96,
    }),
  },
  'ShadowVertex': {'Shadow': _shadow},
  'ShadowSkinnedVertex': {'Shadow': _shadow},
  'ShadowSkinnedUniformVertex': {'Shadow': _shadow, 'Skin': _skin},
  'ShadowFragment': const {},
  'FullscreenVertex': const {},
  'SkyFragment': {
    'Sky': const NullUniformBlock('Sky', 192, {
      'inverse_view_projection': 0,
      'camera_position': 64,
      'zenith': 80,
      'horizon': 96,
      'ground': 112,
      'options': 128,
      'fog': 144,
      'skybox': 160,
    }),
  },
  'TonemapFragment': {
    'Tonemap': const NullUniformBlock('Tonemap', 16, {'options': 0}),
  },
  'BloomDownFragment': {
    'BloomDown': const NullUniformBlock('BloomDown', 32, {
      'texel': 0,
      'options': 16,
    }),
  },
  'BloomUpFragment': {
    'BloomUp': const NullUniformBlock('BloomUp', 32, {
      'texel': 0,
      'options': 16,
    }),
  },
  'FxaaFragment': {
    'Fxaa': const NullUniformBlock('Fxaa', 16, {'texel': 0}),
  },
  'WireVertex': {
    'Overlay': const NullUniformBlock('Overlay', 128, {
      'view_projection': 0,
      'color': 64,
      'options': 80,
    }),
  },
  'ColorFragment': const {},
};

const _frame = NullUniformBlock('Frame', 576, {
  'view_projection': 0,
  'camera_position': 64,
  'sun_direction': 80,
  'sun_color': 96,
  'ambient_sky': 112,
  'ambient_ground': 128,
  'options': 144,
  'light_view_projection': 160,
  'shadow': 224,
  'fog': 240,
  'fog_params': 256,
  'light_view_projection_2': 272,
  'cascade': 336,
  'camera_forward': 352,
  'ibl': 368,
  'sh': 384,
  'clip_plane': 528,
});

const _shadow = NullUniformBlock('Shadow', 64, {'light_view_projection': 0});

const _skin = NullUniformBlock('Skin', 3072, {'rows': 0});

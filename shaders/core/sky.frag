#version 460 core

// A gradient sky — or a skybox, the environment map — behind everything:
// drawn at the far plane, only where no geometry wrote depth. +Y is down in the engine, so "up" is -Y.

in vec2 v_clip;
in vec2 v_texcoord;

uniform Sky {
  mat4 inverse_view_projection;  // of the flipped view-projection
  vec4 camera_position;
  vec4 zenith;
  vec4 horizon;
  vec4 ground;
  vec4 options;                  // x: exposure, y: 1 = tonemapped sRGB
  vec4 fog;                      // rgb: fog colour; a: how much the horizon fogs
  vec4 skybox;                   // x: 1 = draw the environment map, y: its level (blur)
} sky;

// The surroundings, when there is a skybox.
uniform samplerCube environment_texture;

out vec4 frag_color;

vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec3 to_srgb(vec3 linear) {
  return mix(linear * 12.92, 1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055,
             step(vec3(0.0031308), linear));
}

void main() {
  vec4 far_point = sky.inverse_view_projection * vec4(v_clip, 1.0, 1.0);
  vec3 dir = normalize(far_point.xyz / far_point.w - sky.camera_position.xyz);
  float up = -dir.y;
  vec3 color;
  if (sky.skybox.x > 0.5) {
    color = textureLod(environment_texture, dir, sky.skybox.y).rgb;
  } else {
    color = up >= 0.0
        ? mix(sky.horizon.rgb, sky.zenith.rgb, pow(up, 0.6))
        : mix(sky.horizon.rgb, sky.ground.rgb, pow(-up, 0.4));
  }
  // The horizon disappears into the fog the scene fades to.
  color = mix(color, sky.fog.rgb, sky.fog.a * (1.0 - smoothstep(0.0, 0.3, abs(up))));
  color *= sky.options.x;
  if (sky.options.y > 0.5) color = to_srgb(aces(color));
  frag_color = vec4(color, 1.0);
}

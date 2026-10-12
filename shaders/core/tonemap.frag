#version 460 core

// HDR → display: exposure, ACES (Narkowicz fit), then sRGB encoding for a
// target that does not encode by itself.

in vec2 v_clip;
in vec2 v_texcoord;

uniform Tonemap {
  vec4 options;  // x: exposure, y: 1 = encode sRGB in the shader, z: bloom
} tonemap;

uniform sampler2D hdr_texture;
// Half-resolution bloom, added before exposure (black when bloom is off).
uniform sampler2D bloom_texture;

out vec4 frag_color;

vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec3 to_srgb(vec3 linear) {
  return mix(linear * 12.92, 1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055,
             step(vec3(0.0031308), linear));
}

void main() {
  vec4 hdr = texture(hdr_texture, v_texcoord);
  vec3 light = hdr.rgb + texture(bloom_texture, v_texcoord).rgb * tonemap.options.z;
  vec3 color = aces(light * tonemap.options.x);
  if (tonemap.options.y > 0.5) color = to_srgb(color);
  frag_color = vec4(color, 1.0);
}

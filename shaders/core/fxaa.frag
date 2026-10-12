#version 460 core

// FXAA (the "lite" variant): softens stair-stepped edges after tonemapping,
// for devices that draw without MSAA. Reads display-encoded colour. The
// algorithm is Timothy Lottes' Fast Approximate Anti-Aliasing (NVIDIA).

in vec2 v_clip;
in vec2 v_texcoord;

uniform Fxaa {
  vec4 texel;  // xy: one texel in uv; z: 1 = decode to linear on output
} fxaa;

uniform sampler2D source;

out vec4 frag_color;

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec3 to_linear(vec3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void main() {
  vec2 t = fxaa.texel.xy;
  vec2 uv = v_texcoord;
  vec3 nw = texture(source, uv + vec2(-t.x, -t.y)).rgb;
  vec3 ne = texture(source, uv + vec2(t.x, -t.y)).rgb;
  vec3 sw = texture(source, uv + vec2(-t.x, t.y)).rgb;
  vec3 se = texture(source, uv + vec2(t.x, t.y)).rgb;
  vec3 m = texture(source, uv).rgb;
  float l_nw = luma(nw), l_ne = luma(ne), l_sw = luma(sw), l_se = luma(se), l_m = luma(m);
  float l_min = min(l_m, min(min(l_nw, l_ne), min(l_sw, l_se)));
  float l_max = max(l_m, max(max(l_nw, l_ne), max(l_sw, l_se)));
  vec2 dir = vec2(-((l_nw + l_ne) - (l_sw + l_se)), (l_nw + l_sw) - (l_ne + l_se));
  float reduce = max((l_nw + l_ne + l_sw + l_se) * (0.25 / 8.0), 1.0 / 128.0);
  float scale = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);
  dir = clamp(dir * scale, vec2(-8.0), vec2(8.0)) * t;
  vec3 a = 0.5 * (texture(source, uv + dir * (1.0 / 3.0 - 0.5)).rgb +
                  texture(source, uv + dir * (2.0 / 3.0 - 0.5)).rgb);
  vec3 b = a * 0.5 + 0.25 * (texture(source, uv - dir * 0.5).rgb +
                             texture(source, uv + dir * 0.5).rgb);
  float l_b = luma(b);
  vec3 color = (l_b < l_min || l_b > l_max) ? a : b;
  if (fxaa.texel.z > 0.5) color = to_linear(color);
  frag_color = vec4(color, 1.0);
}

#version 460 core

// Bloom, going up: a 3x3 tent over the smaller level, added (by blending)
// onto the larger one.

in vec2 v_clip;
in vec2 v_texcoord;

uniform BloomUp {
  vec4 texel;    // xy: one source texel in uv
  vec4 options;  // x: radius in texels, y: weight
} up;

uniform sampler2D source;

out vec4 frag_color;

void main() {
  vec2 t = up.texel.xy * up.options.x;
  vec3 c = texture(source, v_texcoord).rgb * 4.0;
  c += (texture(source, v_texcoord + vec2(-t.x, 0.0)).rgb +
        texture(source, v_texcoord + vec2(t.x, 0.0)).rgb +
        texture(source, v_texcoord + vec2(0.0, -t.y)).rgb +
        texture(source, v_texcoord + vec2(0.0, t.y)).rgb) * 2.0;
  c += texture(source, v_texcoord + vec2(-t.x, -t.y)).rgb +
       texture(source, v_texcoord + vec2(t.x, -t.y)).rgb +
       texture(source, v_texcoord + vec2(-t.x, t.y)).rgb +
       texture(source, v_texcoord + vec2(t.x, t.y)).rgb;
  frag_color = vec4(c * (up.options.y / 16.0), 1.0);
}

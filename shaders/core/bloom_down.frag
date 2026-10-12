#version 460 core

// Bloom, going down: halves the image with a 4x4 box (four bilinear taps).
// The first step also keeps only what is brighter than the threshold, with
// a soft knee so bright edges don't pop.

in vec2 v_clip;
in vec2 v_texcoord;

uniform BloomDown {
  vec4 texel;    // xy: one source texel in uv
  vec4 options;  // x: threshold, y: knee (0..1), z: 1 on the first step
} down;

uniform sampler2D source;

out vec4 frag_color;

vec3 bright_part(vec3 c) {
  float brightness = max(c.r, max(c.g, c.b));
  float knee = down.options.x * down.options.y;
  float soft = clamp(brightness - down.options.x + knee, 0.0, 2.0 * knee);
  soft = soft * soft / (4.0 * knee + 1e-5);
  float keep = max(soft, brightness - down.options.x) / max(brightness, 1e-5);
  return c * keep;
}

void main() {
  vec2 t = down.texel.xy;
  vec3 c = texture(source, v_texcoord + vec2(-t.x, -t.y)).rgb +
           texture(source, v_texcoord + vec2(t.x, -t.y)).rgb +
           texture(source, v_texcoord + vec2(-t.x, t.y)).rgb +
           texture(source, v_texcoord + vec2(t.x, t.y)).rgb;
  c *= 0.25;
  if (down.options.z > 0.5) c = bright_part(c);
  frag_color = vec4(c, 1.0);
}

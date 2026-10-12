#version 460 core

// Writes the caster's depth into the shadow map's red channel.

in float v_depth;

out vec4 frag_color;

void main() {
  frag_color = vec4(v_depth, 0.0, 0.0, 1.0);
}

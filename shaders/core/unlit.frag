#version 460 core

in vec2 v_texcoord;

uniform Frame {
  mat4 mvp;
  vec4 tint;
} frame;

uniform sampler2D base_texture;

out vec4 frag_color;

void main() {
  frag_color = texture(base_texture, v_texcoord) * frame.tint;
}

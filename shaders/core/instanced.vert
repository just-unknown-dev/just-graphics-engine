#version 460 core

// Instanced, flat-coloured geometry: one vertex buffer of positions, one
// per-instance buffer of offsets and colours.

in vec3 position;
in vec4 instance_offset;
in vec4 instance_color;

uniform Frame {
  mat4 mvp;
  vec4 tint;
} frame;

out vec4 v_color;

void main() {
  gl_Position = frame.mvp * vec4(position + instance_offset.xyz, 1.0);
  v_color = instance_color * frame.tint;
}

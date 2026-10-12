#version 460 core

// Textured, unlit geometry: debug drawing, sprites, and the GPU layer's own
// tests. The projection inside `mvp` already has the clip-space y flip
// applied (ClipFixup), so nothing here knows about it.

in vec3 position;
in vec2 texcoord;

uniform Frame {
  mat4 mvp;
  vec4 tint;
} frame;

out vec2 v_texcoord;

void main() {
  gl_Position = frame.mvp * vec4(position, 1.0);
  v_texcoord = texcoord;
}

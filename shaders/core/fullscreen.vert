#version 460 core

// One triangle covering the screen (no vertex buffer needed beyond its
// three corners). Passes clip-space xy and a texture coordinate.

in vec2 position;

out vec2 v_clip;
out vec2 v_texcoord;

void main() {
  gl_Position = vec4(position, 1.0, 1.0);  // depth 1: the far plane
  v_clip = position;
  // Clip +Y is the top of the image; texture row 0 is the top too.
  v_texcoord = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
}

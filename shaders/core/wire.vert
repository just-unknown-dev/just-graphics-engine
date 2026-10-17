#version 460 core

// Lines over the scene: a mesh's edges for a wireframe view or a
// selection highlight. The same vertex and instance buffers a lit draw
// uses (only positions and model matrices are read), drawn as lines.

in vec3 position;

in vec4 model_0;
in vec4 model_1;
in vec4 model_2;
in vec4 model_3;

uniform Overlay {
  mat4 view_projection;   // already flipped for the GPU's clip space
  vec4 color;             // rgba, as written
  vec4 options;           // x: how far towards the eye, in clip depth
} overlay;

out vec4 v_color;

void main() {
  mat4 model = mat4(model_0, model_1, model_2, model_3);
  vec4 clip = overlay.view_projection * (model * vec4(position, 1.0));
  // Pulled a hair towards the eye, so an edge wins over the face it bounds.
  clip.z -= overlay.options.x * clip.w;
  gl_Position = clip;
  v_color = overlay.color;
}

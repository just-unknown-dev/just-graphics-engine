#version 460 core

// Shadow casters, seen from the sun: only positions and model matrices.
// The depth is written as a colour (Flutter GPU can't sample depth
// textures), in 0..1 along the sun's direction.

in vec3 position;

in vec4 model_0;
in vec4 model_1;
in vec4 model_2;
in vec4 model_3;

uniform Shadow {
  mat4 light_view_projection;   // already flipped for the GPU's clip space
} shadow;

out float v_depth;

void main() {
  mat4 model = mat4(model_0, model_1, model_2, model_3);
  vec4 clip = shadow.light_view_projection * (model * vec4(position, 1.0));
  gl_Position = clip;
  // Orthographic: w is 1, and z is already 0..1.
  v_depth = clip.z;
}

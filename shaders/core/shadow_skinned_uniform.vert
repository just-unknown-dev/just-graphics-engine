#version 460 core

// Skinned shadow casters with the palette in a uniform block (the
// fallback, as lit_skinned_uniform.vert).

in vec3 position;

in vec4 joints;
in vec4 weights;

in vec4 model_0;
in vec4 model_1;
in vec4 model_2;
in vec4 model_3;

uniform Shadow {
  mat4 light_view_projection;
} shadow;

uniform Skin {
  vec4 rows[192];
} skin_palette;

out float v_depth;

void main() {
  vec4 r0 = vec4(0.0);
  vec4 r1 = vec4(0.0);
  vec4 r2 = vec4(0.0);
  for (int i = 0; i < 4; i++) {
    float w = weights[i];
    if (w > 0.0) {
      int t = int(joints[i] + 0.5) * 3;
      r0 += skin_palette.rows[t] * w;
      r1 += skin_palette.rows[t + 1] * w;
      r2 += skin_palette.rows[t + 2] * w;
    }
  }
  vec4 p = vec4(position, 1.0);
  vec3 skinned = vec3(dot(r0, p), dot(r1, p), dot(r2, p));
  mat4 model = mat4(model_0, model_1, model_2, model_3);
  vec4 clip = shadow.light_view_projection * (model * vec4(skinned, 1.0));
  gl_Position = clip;
  v_depth = clip.z;
}

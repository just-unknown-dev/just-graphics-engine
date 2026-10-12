#version 460 core

// Skinned shadow casters: the skinned position (as lit_skinned.vert), seen
// from the sun.

in vec3 position;

in vec4 joints;
in vec4 weights;

in vec4 model_0;
in vec4 model_1;
in vec4 model_2;
in vec4 model_3;
in vec4 skin;   // x: first texel of this instance's palette

uniform Shadow {
  mat4 light_view_projection;
} shadow;

uniform sampler2D joint_texture;

out float v_depth;

vec4 joint_row(int texel, int width) {
  return texelFetch(joint_texture, ivec2(texel % width, texel / width), 0);
}

void main() {
  int width = textureSize(joint_texture, 0).x;
  int base = int(skin.x + 0.5);
  vec4 r0 = vec4(0.0);
  vec4 r1 = vec4(0.0);
  vec4 r2 = vec4(0.0);
  for (int i = 0; i < 4; i++) {
    float w = weights[i];
    if (w > 0.0) {
      int t = base + int(joints[i] + 0.5) * 3;
      r0 += joint_row(t, width) * w;
      r1 += joint_row(t + 1, width) * w;
      r2 += joint_row(t + 2, width) * w;
    }
  }
  vec4 p = vec4(position, 1.0);
  vec3 skinned = vec3(dot(r0, p), dot(r1, p), dot(r2, p));
  mat4 model = mat4(model_0, model_1, model_2, model_3);
  vec4 clip = shadow.light_view_projection * (model * vec4(skinned, 1.0));
  gl_Position = clip;
  v_depth = clip.z;
}

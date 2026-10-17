#version 460 core

// Skinned lit meshes. Slot 0 holds the mesh's vertices, slot 1 each
// vertex's four joints and weights, slot 2 per instance a model matrix, a
// normal matrix and where its joint palette starts in joint_texture. Each
// joint is three texels: the top three rows of its skinning matrix. One
// texture holds every palette of the frame, so characters sharing a mesh
// and material stay one instanced draw.

in vec3 position;
in vec3 normal;
in vec4 tangent;
in vec2 texcoord;
in vec4 color;

in vec4 joints;
in vec4 weights;

in vec4 model_0;
in vec4 model_1;
in vec4 model_2;
in vec4 model_3;
in vec4 normal_0;
in vec4 normal_1;
in vec4 normal_2;
in vec4 skin;   // x: first texel of this instance's palette

uniform Frame {
  mat4 view_projection;
  vec4 camera_position;
  vec4 sun_direction;
  vec4 sun_color;
  vec4 ambient_sky;
  vec4 ambient_ground;
  vec4 options;
  mat4 light_view_projection;
  vec4 shadow;
  vec4 fog;          // rgb: colour (linear); a: density per metre (0 = none)
  vec4 fog_params;   // x: where fog starts, metres from the camera
  mat4 light_view_projection_2;  // the second shadow cascade's
  vec4 cascade;      // x: where it takes over (view depth), y: cascades,
                     // z: its normal offset, w: its depth bias
  vec4 camera_forward;
  vec4 ibl;             // x: reflection strength (0 = the hemisphere), y: blurriest level, z: 1 = SH diffuse
  vec4 sh[9];           // diffuse light as spherical harmonics, rgb each
  vec4 clip_plane;      // a slice: xyz its normal, w how far; nothing beyond it is drawn (xyz 0: none)
} frame;

uniform sampler2D joint_texture;

out vec3 v_world;
out vec3 v_normal;
out vec4 v_tangent;
out vec2 v_texcoord;
out vec4 v_color;
out vec4 v_shadow;
out vec4 v_shadow2;

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
  // The blended matrix's upper 3x3, by columns.
  mat3 joint3 = mat3(r0.x, r1.x, r2.x, r0.y, r1.y, r2.y, r0.z, r1.z, r2.z);

  mat4 model = mat4(model_0, model_1, model_2, model_3);
  mat3 normal_matrix = mat3(normal_0.xyz, normal_1.xyz, normal_2.xyz);
  vec4 world = model * vec4(skinned, 1.0);
  gl_Position = frame.view_projection * world;
  v_world = world.xyz;
  v_normal = normal_matrix * (joint3 * normal);
  v_tangent = vec4(mat3(model) * (joint3 * tangent.xyz), tangent.w);
  v_texcoord = texcoord;
  v_color = color;
  vec3 n = normalize(v_normal + vec3(1e-6));
  v_shadow = frame.light_view_projection * vec4(world.xyz + n * frame.shadow.y, 1.0);
  v_shadow2 = frame.light_view_projection_2 * vec4(world.xyz + n * frame.cascade.z, 1.0);
}

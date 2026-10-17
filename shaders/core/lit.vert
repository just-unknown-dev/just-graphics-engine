#version 460 core

// Lit meshes. Every draw is instanced: slot 0 holds the mesh's vertices,
// slot 1 one model matrix and one normal matrix per instance.

in vec3 position;
in vec3 normal;
in vec4 tangent;
in vec2 texcoord;
in vec4 color;

in vec4 model_0;
in vec4 model_1;
in vec4 model_2;
in vec4 model_3;
in vec4 normal_0;
in vec4 normal_1;
in vec4 normal_2;

uniform Frame {
  mat4 view_projection;        // already flipped for the GPU's clip space
  vec4 camera_position;        // xyz
  vec4 sun_direction;          // xyz: direction the light travels; w: 1 when on
  vec4 sun_color;              // rgb * intensity
  vec4 ambient_sky;            // rgb
  vec4 ambient_ground;         // rgb
  vec4 options;                // x: exposure, y: 1 = write tonemapped sRGB
  mat4 light_view_projection;  // world -> sun's shadow map (engine clip space)
  vec4 shadow;                 // x: strength (0 = off), y: normal offset (m),
                               // z: one texel in uv, w: depth bias
  vec4 fog;                    // rgb: colour (linear); a: density per metre
  vec4 fog_params;             // x: where fog starts, metres from the camera
  mat4 light_view_projection_2;  // the second shadow cascade's
  vec4 cascade;                // x: where it takes over (view depth),
                               // y: cascades, z: its normal offset, w: its bias
  vec4 camera_forward;         // xyz
  vec4 ibl;             // x: reflection strength (0 = the hemisphere), y: blurriest level, z: 1 = SH diffuse
  vec4 sh[9];           // diffuse light as spherical harmonics, rgb each
  vec4 clip_plane;      // a slice: xyz its normal, w how far; nothing beyond it is drawn (xyz 0: none)
} frame;

out vec3 v_world;
out vec3 v_normal;
out vec4 v_tangent;
out vec2 v_texcoord;
out vec4 v_color;
out vec4 v_shadow;
out vec4 v_shadow2;

void main() {
  mat4 model = mat4(model_0, model_1, model_2, model_3);
  mat3 normal_matrix = mat3(normal_0.xyz, normal_1.xyz, normal_2.xyz);
  vec4 world = model * vec4(position, 1.0);
  gl_Position = frame.view_projection * world;
  v_world = world.xyz;
  v_normal = normal_matrix * normal;
  v_tangent = vec4(mat3(model) * tangent.xyz, tangent.w);
  v_texcoord = texcoord;
  v_color = color;
  // Pushed out along the normal so a surface does not shadow itself.
  vec3 n = normalize(v_normal + vec3(1e-6));
  v_shadow = frame.light_view_projection * vec4(world.xyz + n * frame.shadow.y, 1.0);
  v_shadow2 = frame.light_view_projection_2 * vec4(world.xyz + n * frame.cascade.z, 1.0);
}

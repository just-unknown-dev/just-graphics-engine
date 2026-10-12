#version 460 core

// glTF metallic-roughness PBR (the BRDF Filament uses: GGX distribution,
// height-correlated Smith visibility, Schlick Fresnel, Lambert diffuse),
// lit by one directional sun, up to MAX_LIGHTS point/spot lights and a
// hemispherical ambient — or, given an environment map, its spherical
// harmonics and prefiltered reflections. Writes linear HDR, or tonemapped
// sRGB when
// frame.options.y is set (devices without an HDR target).
//
// World axes are the engine's: +Y is down, so "up" is -Y.

in vec3 v_world;
in vec3 v_normal;
in vec4 v_tangent;
in vec2 v_texcoord;
in vec4 v_color;
in vec4 v_shadow;
in vec4 v_shadow2;

uniform Frame {
  mat4 view_projection;
  vec4 camera_position;
  vec4 sun_direction;   // xyz: the way the light travels; w: 1 when on
  vec4 sun_color;       // rgb * intensity
  vec4 ambient_sky;
  vec4 ambient_ground;
  vec4 options;         // x: exposure, y: 1 = tonemapped sRGB
  mat4 light_view_projection;
  vec4 shadow;          // x: strength (0 = off), y: normal offset, z: texel (uv), w: bias
  vec4 fog;             // rgb: colour (linear); a: density per metre (0 = none)
  vec4 fog_params;      // x: where fog starts, metres from the camera
  mat4 light_view_projection_2;
  vec4 cascade;         // x: second cascade from (view depth), y: cascades, z/w: its offset, bias
  vec4 camera_forward;
  vec4 ibl;             // x: reflection strength (0 = the hemisphere), y: blurriest level, z: 1 = SH diffuse
  vec4 sh[9];           // diffuse light as spherical harmonics, rgb each
} frame;

#define MAX_LIGHTS 8
uniform Lights {
  vec4 count;                        // x: lights in use
  vec4 position_range[MAX_LIGHTS];   // xyz, w: range (0 = unlimited)
  vec4 color[MAX_LIGHTS];            // rgb * intensity
  vec4 direction[MAX_LIGHTS];        // xyz: spot axis (light travels); w: 1 = spot
  vec4 cone[MAX_LIGHTS];             // x: cos(outer), y: 1 / (cos(inner) - cos(outer))
} lights;

uniform Material {
  vec4 base_color;     // linear rgba
  vec4 emissive;       // rgb * strength; a: alpha cutoff
  vec4 params;         // metallic, roughness, normal scale, occlusion strength
  vec4 flags;          // x: unlit, y: alpha mode (0 opaque, 1 mask, 2 blend), z: double sided
  vec4 uv_transform;   // offset.xy, scale.xy (KHR_texture_transform)
  vec4 uv_rotation;    // x: rotation
} material;

uniform sampler2D base_color_texture;
uniform sampler2D metallic_roughness_texture;
uniform sampler2D normal_texture;
uniform sampler2D occlusion_texture;
uniform sampler2D emissive_texture;
// The sun's shadow map: depth (0..1 along the light) in red.
uniform sampler2D shadow_texture;
// The second cascade's (white when there is one cascade).
uniform sampler2D shadow_texture_2;
// The surroundings, each smaller level blurred for a rougher surface.
uniform samplerCube environment_texture;

out vec4 frag_color;

const float PI = 3.14159265359;

vec2 transformed_uv() {
  float c = cos(material.uv_rotation.x);
  float s = sin(material.uv_rotation.x);
  // KHR_texture_transform: offset · rotation · scale.
  mat3 translation = mat3(1.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                          material.uv_transform.x, material.uv_transform.y, 1.0);
  mat3 rotation = mat3(c, s, 0.0, -s, c, 0.0, 0.0, 0.0, 1.0);
  mat3 scale = mat3(material.uv_transform.z, 0.0, 0.0,
                    0.0, material.uv_transform.w, 0.0, 0.0, 0.0, 1.0);
  return (translation * rotation * scale * vec3(v_texcoord, 1.0)).xy;
}

float d_ggx(float n_dot_h, float a) {
  float a2 = a * a;
  float f = (n_dot_h * a2 - n_dot_h) * n_dot_h + 1.0;
  return a2 / (PI * f * f);
}

float v_smith_ggx_correlated(float n_dot_v, float n_dot_l, float a) {
  float a2 = a * a;
  float ggx_l = n_dot_v * sqrt((-n_dot_l * a2 + n_dot_l) * n_dot_l + a2);
  float ggx_v = n_dot_l * sqrt((-n_dot_v * a2 + n_dot_v) * n_dot_v + a2);
  return 0.5 / (ggx_v + ggx_l);
}

vec3 f_schlick(float u, vec3 f0) {
  float f = pow(1.0 - u, 5.0);
  return f + f0 * (1.0 - f);
}

vec3 brdf(vec3 n, vec3 v, vec3 l, vec3 radiance, vec3 diffuse_color,
          vec3 f0, float roughness) {
  vec3 h = normalize(v + l);
  float n_dot_v = abs(dot(n, v)) + 1e-5;
  float n_dot_l = clamp(dot(n, l), 0.0, 1.0);
  float n_dot_h = clamp(dot(n, h), 0.0, 1.0);
  float l_dot_h = clamp(dot(l, h), 0.0, 1.0);
  float a = roughness * roughness;
  vec3 specular = d_ggx(n_dot_h, a) * v_smith_ggx_correlated(n_dot_v, n_dot_l, a) *
                  f_schlick(l_dot_h, f0);
  return (diffuse_color / PI + specular) * radiance * n_dot_l;
}

vec3 hemisphere(vec3 dir) {
  float t = clamp(0.5 - 0.5 * dir.y, 0.0, 1.0);  // up is -Y
  return mix(frame.ambient_ground.rgb, frame.ambient_sky.rgb, t);
}

// The diffuse light facing n, from the environment's spherical harmonics
// (already scaled for a Lambert surface).
vec3 sh_irradiance(vec3 n) {
  vec3 c = frame.sh[0].rgb * 0.282095
         + frame.sh[1].rgb * (0.488603 * n.y)
         + frame.sh[2].rgb * (0.488603 * n.z)
         + frame.sh[3].rgb * (0.488603 * n.x)
         + frame.sh[4].rgb * (1.092548 * n.x * n.y)
         + frame.sh[5].rgb * (1.092548 * n.y * n.z)
         + frame.sh[6].rgb * (0.315392 * (3.0 * n.z * n.z - 1.0))
         + frame.sh[7].rgb * (1.092548 * n.x * n.z)
         + frame.sh[8].rgb * (0.546274 * (n.x * n.x - n.y * n.y));
  return max(c, vec3(0.0));
}

// The split sum's environment BRDF, by Karis' analytic fit (no lookup
// table).
vec3 env_brdf(vec3 f0, float roughness, float n_dot_v) {
  const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
  const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
  vec4 r = roughness * c0 + c1;
  float a004 = min(r.x * r.x, exp2(-9.28 * n_dot_v)) * r.x + r.y;
  vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
  return f0 * ab.x + ab.y;
}

// A tangent frame from screen-space derivatives, for meshes without
// tangents (Schüler, "Followup: Normal Mapping Without Precomputed Tangents").
mat3 cotangent_frame(vec3 n, vec3 p, vec2 uv) {
  vec3 dp1 = dFdx(p);
  vec3 dp2 = dFdy(p);
  vec2 duv1 = dFdx(uv);
  vec2 duv2 = dFdy(uv);
  vec3 dp2_perp = cross(dp2, n);
  vec3 dp1_perp = cross(n, dp1);
  vec3 t = dp2_perp * duv1.x + dp1_perp * duv2.x;
  vec3 b = dp2_perp * duv1.y + dp1_perp * duv2.y;
  float inv_max = inversesqrt(max(max(dot(t, t), dot(b, b)), 1e-12));
  return mat3(t * inv_max, b * inv_max, n);
}

// How much sunlight reaches this fragment: 1 lit, 0 in shadow. 3x3
// percentage-closer filtering over the shadow map's texels.
float shadow_lookup(vec4 position, float bias, bool second) {
  vec3 p = position.xyz / position.w;
  // Engine clip space has y down; texture v = 0 is the top row.
  vec2 uv = p.xy * 0.5 + 0.5;
  if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0 || p.z >= 1.0) {
    return 1.0;
  }
  float depth = p.z - bias;
  float lit = 0.0;
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec2 at = uv + vec2(float(x), float(y)) * frame.shadow.z;
      float stored = second ? texture(shadow_texture_2, at).r : texture(shadow_texture, at).r;
      lit += depth <= stored ? 1.0 : 0.0;
    }
  }
  return lit / 9.0;
}

float sun_visibility() {
  if (frame.shadow.x <= 0.0) return 1.0;
  float view_depth = dot(v_world - frame.camera_position.xyz, frame.camera_forward.xyz);
  bool second = frame.cascade.y > 1.5 && view_depth > frame.cascade.x;
  float lit = second
      ? shadow_lookup(v_shadow2, frame.cascade.w, true)
      : shadow_lookup(v_shadow, frame.shadow.w, false);
  return mix(1.0, lit, frame.shadow.x);
}

vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec3 to_srgb(vec3 linear) {
  return mix(linear * 12.92, 1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055,
             step(vec3(0.0031308), linear));
}

void main() {
  vec2 uv = transformed_uv();
  vec4 base = texture(base_color_texture, uv) * material.base_color * v_color;
  float alpha_mode = material.flags.y;
  if (alpha_mode > 0.5 && alpha_mode < 1.5 && base.a < material.emissive.a) discard;

  vec3 color;
  if (material.flags.x > 0.5) {
    color = base.rgb;
  } else {
    vec3 n = normalize(v_normal);
    if (material.flags.z > 0.5 && !gl_FrontFacing) n = -n;
    vec3 tangent_normal = texture(normal_texture, uv).xyz * 2.0 - 1.0;
    tangent_normal.xy *= material.params.z;
    mat3 tbn;
    if (dot(v_tangent.xyz, v_tangent.xyz) > 1e-8) {
      vec3 t = normalize(v_tangent.xyz - n * dot(n, v_tangent.xyz));
      vec3 b = cross(n, t) * (v_tangent.w < 0.0 ? -1.0 : 1.0);
      tbn = mat3(t, b, n);
    } else {
      tbn = cotangent_frame(n, v_world, uv);
    }
    n = normalize(tbn * tangent_normal);

    vec4 mr = texture(metallic_roughness_texture, uv);
    float metallic = clamp(material.params.x * mr.b, 0.0, 1.0);
    // 0.089 keeps the GGX lobe stable at half precision (Filament).
    float roughness = clamp(material.params.y * mr.g, 0.089, 1.0);
    float occlusion = mix(1.0, texture(occlusion_texture, uv).r, material.params.w);

    vec3 diffuse_color = base.rgb * (1.0 - metallic);
    vec3 f0 = mix(vec3(0.04), base.rgb, metallic);
    vec3 v = normalize(frame.camera_position.xyz - v_world);

    color = vec3(0.0);
    if (frame.sun_direction.w > 0.5) {
      color += brdf(n, v, -normalize(frame.sun_direction.xyz),
                    frame.sun_color.rgb * sun_visibility(), diffuse_color, f0, roughness);
    }
    int count = int(lights.count.x);
    for (int i = 0; i < MAX_LIGHTS; i++) {
      if (i >= count) break;
      vec3 to_light = lights.position_range[i].xyz - v_world;
      float distance_sq = max(dot(to_light, to_light), 1e-4);
      vec3 l = to_light * inversesqrt(distance_sq);
      float attenuation = 1.0 / distance_sq;
      float range = lights.position_range[i].w;
      if (range > 0.0) {
        float r = distance_sq / (range * range);
        float window = clamp(1.0 - r * r, 0.0, 1.0);
        attenuation *= window * window;
      }
      if (lights.direction[i].w > 0.5) {
        float cd = dot(normalize(lights.direction[i].xyz), -l);
        float t = clamp((cd - lights.cone[i].x) * lights.cone[i].y, 0.0, 1.0);
        attenuation *= t * t;
      }
      color += brdf(n, v, l, lights.color[i].rgb * attenuation, diffuse_color, f0, roughness);
    }

    float n_dot_v = clamp(dot(n, v), 0.0, 1.0);
    vec3 irradiance = frame.ibl.z > 0.5 ? sh_irradiance(n) : hemisphere(n);
    vec3 ambient_diffuse = irradiance * diffuse_color;
    vec3 ambient_specular;
    if (frame.ibl.x > 0.0) {
      // Image-based: the surroundings blurred for this roughness.
      vec3 prefiltered = textureLod(environment_texture, reflect(-v, n), roughness * frame.ibl.y).rgb;
      ambient_specular = prefiltered * env_brdf(f0, roughness, n_dot_v) * frame.ibl.x;
    } else {
      ambient_specular = hemisphere(reflect(-v, n)) * f_schlick(n_dot_v, f0) *
                         (1.0 - roughness) * 0.5;
    }
    color += (ambient_diffuse + ambient_specular) * occlusion;
  }

  color += texture(emissive_texture, uv).rgb * material.emissive.rgb;

  // Distance fog: exponential beyond its start.
  if (frame.fog.a > 0.0) {
    float d = max(distance(v_world, frame.camera_position.xyz) - frame.fog_params.x, 0.0);
    color = mix(color, frame.fog.rgb, 1.0 - exp(-frame.fog.a * d));
  }

  float alpha = alpha_mode > 1.5 ? base.a : 1.0;
  if (frame.options.y > 0.5) color = to_srgb(aces(color * frame.options.x));
  frag_color = vec4(color, alpha);
}

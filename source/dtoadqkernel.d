module dtoadqkernel; immutable(string) DTOADQ_kernel = q{
#define MAX_DEPTH 8
#define MARCH_DIST //%MARCH_DIST.0f
#define MARCH_REPS //%MARCH_REPS

__constant float MARCH_ACC = //%MARCH_ACC.0f/1000.0f;
// -----------------------------------------------------------------------------
// --------------- DEBUG -------------------------------------------------------
// Variadic functions not supported, so this is best you get :-(
bool Is_Debug_Print ( ) {
  return get_global_id(0) == get_global_size(0)/2 &&
         get_global_id(1) == get_global_size(1)/2;
}
// -----------------------------------------------------------------------------
// --------------- GPU-CPU STRUCTS ---------------------------------------------
typedef struct T_Camera {
  float3 position, lookat, up;
  int2 dim;
  float fov;
  int flags;
} Camera;

typedef struct T_Material {
  float emission; // > 0.0f is a light source
  float diffuse, specular, retroreflective, transmittive;
} Material;

typedef struct T_SharedInfo {
  unsigned char clear_img;
  unsigned long finished_samples;
  unsigned char spp;
} SharedInfo;

__constant float PI  = 3.141592654f;
__constant float IPI = 0.318309886f;
__constant float TAU = 6.283185307f;
// -----------------------------------------------------------------------------
// --------------- GENERAL STRUCTS ---------------------------------------------
typedef struct T_Ray {
  float3 origin, dir;
} Ray;

typedef struct T_BSDF_Sample_Info {
  float3 omega_i, omega_o, brdf, pdf, dir_cos;
} BSDF_Sample_Info;

typedef struct T_MapInfo {
  float3 colour, origin, dir;
  float dist;
  BSDF_Sample_Info bsdf_info;
  int material_index;
} MapInfo;

typedef struct T_SceneInfo {
  float time;
  __read_only image2d_array_t textures;
  __global Material* materials;
  float3 debug_values;
  __global int* rng;
} SceneInfo;
// -----------------------------------------------------------------------------
// --------------- GENERAL FUNCTIONS      --------------------------------------
// http://www0.cs.ucl.ac.uk/staff/ucacbbl/ftp/papers/langdon_2009_CIGPU.pdf
int Parker_Miller_Rand ( int seed ) {
  const int a = 16807,      // 7^5
            m = 2147483647; // 2^31 - 1
  return ((long)(seed * a))%m;
}

int Rand ( __global int* rng ) {
  int id = get_global_id(1)*get_global_size(0) + get_global_id(0);
  id %= 31;
  int rnum = Parker_Miller_Rand(rng[id]);
  rng[id] = rnum;
  return rnum;
}

float Uniform_Sample ( __global int* rng ) {
  return (float)((uint)(Rand(rng)))/(float)(UINT_MAX);
}

float sqr(float t) { return t*t; }
// -----------------------------------------------------------------------------
// --------------- MAP GEOMETRY FUNCTIONS --------------------------------------

//---MAP GEOMETRY INSERTION POINT---
//%MAPFUNCDECLARATIONS
//----------------------------------
//%MAPFUNCDEFINITIONS
//----------------------------------

void MapUnionG( int avoid, MapInfo* d1, float d, int mi, float3 c ) {
  if ( mi != avoid && d1->dist > d ) {
    d1->colour = c;
    d1->dist = d;
    d1->material_index = mi;
  }
}

// -----------------------------------------------------------------------------
// --------------- SCENE -------------------------------------------------------
//%SCENEINSERT
//------------------------
// -----------------------------------------------------------------------------
// --------------- MAP ---------------------------------------------------------
MapInfo Map ( int a, float3 origin, SceneInfo* scene_info ) {
  MapInfo res;
  res.dist = FLT_MAX;

  //---MAP INSERTION POINT---
  //%MAPINSERT
  //-------------------------

  return res;
}

// -----------------------------------------------------------------------------
// --------------- GRAPHIC FUNCS -----------------------------------------------
float3 Normal ( float3 p, SceneInfo* si ) {
  float2 e = (float2)(1.0f, -1.0f)*0.5773f*0.0005f;
  return normalize(
    e.xyy*Map(-1, p + e.xyy, si).dist + e.yyx*Map(-1, p + e.yyx, si).dist +
    e.yxy*Map(-1, p + e.yxy, si).dist + e.xxx*Map(-1, p + e.xxx, si).dist);
}

float3 reflect ( float3 V, float3 N ) {
  return V - 2.0f*dot(V, N)*N;
}

float3 refract(float3 V, float3 N, float refraction) {
  float cosI = -dot(N, V);
  float cosT = 1.0f - refraction*refraction*(1.0f - cosI*cosI);
  return (refraction*V) + (refraction*cosI - sqrt(cosT))*N;
}

// Cosine weighted
float3 Hemisphere_Direction ( __global int* rng, float3 normal ) {
  const float phi = TAU*Uniform_Sample(rng),
              vv  = 2.0f*(Uniform_Sample(rng) - 0.5f);
  const float cos_theta = sign(vv)*sqrt(fabs(vv)),
              sin_theta = sqrt(fmax(0.0f, 1.0f - (cos_theta*cos_theta)));
  return (float3)(cos(phi)*sin_theta, sin(phi)*sin_theta, cos_theta);
}

BSDF_Sample_Info BSDF ( float3 P, float3 omega_i, float3 omega_o,
     Material material, float3 albedo, Scene_Info* scene_info ) {
  BSDF_Sample_Info info;
  info.omega_i = omega_i;
  info.omega_o = omega_o;
  float3 normal = Normal(P, scene_info);
  info.dir_cos = dot(info.omega_o, normal);
  if ( material.specular > FLT_MIN ) {
    info.brdf = albedo*dot(info.omega_i, normal);
    info.pdf  = 1.0f;
  }
  if ( material.diffuse > FLT_MIN ) {
    info.brdf = info.dir_cos*albedo*IPI*material.diffuse;
    info.pdf  = 1.0f/(2.0f*PI);
  }
  if ( material.transmittive > FLT_MIN ) {
    info.brdf = albedo/dot(ray.dir, normal);
    info.pdf = 1.0f;
  }
  return info;
}

// BSDF + multi importance sampling
BSDF_Sample_Info BSDF_Sample ( Ray ray, float3 pt, float3 normal, float3 albedo,
                               SceneInfo* scene_info ) {
  BSDF_Sample_Info info;
  info.omega_i = ray.dir;
  if ( material.specular > FLT_MIN ) {
    info.omega_o  = reflect(ray.dir, normal);
    info.dir_cos = dot(info.omega_o, normal);
    info.brdf = albedo*dot(ray.dir, normal);
    info.pdf  = 1.0f;
    return info;
  }
  if ( material.diffuse > FLT_MIN ) {
    info.omega_o = normalize(Hemisphere_Direction(rng, normal));
    float3 half_vec = normalize(info.omega_o + ray.dir);
    half_vec *= half_vec;
    info.dir_cos = dot(half_vec, normal);
    info.pdf = 1.0f/(2.0f*PI);
    info.brdf = info.dir_cos*albedo*IPI*material.diffuse;

    return info;
  }
  if ( material.transmittive > FLT_MIN ) {
    info.omega_o = refract(ray.dir, normal, 0.0f+material.retroreflective*5.0f);
    info.dir_cos = max(0.0f, dot(info.omega_o, normal));
    info.brdf = albedo/dot(ray.dir, normal);
    info.pdf  = 1.0f;
    return info;
  }
  if ( material.retroreflective > FLT_MIN ) {
    info.omega_o = -ray.dir;
    info.dir_cos = max(0.0f, dot(info.omega_o, normal));
    info.brdf = albedo/dot(ray.dir, normal);
    info.pdf = 1.0f;
    return info;
  }
  return info;
}
// -----------------------------------------------------------------------------
// --------------- RAYTRACING/MARCH --------------------------------------------
MapInfo March ( int avoid, Ray ray, SceneInfo* scene_info ) {
  float distance = 0.0f;
  MapInfo t_info;
  for ( int i = 0; i < MARCH_REPS; ++ i ) {
    t_info = Map(avoid, ray.origin + ray.dir*distance, scene_info);
    if ( t_info.dist < MARCH_ACC || t_info.dist > MARCH_DIST ) break;
    distance += t_info.dist;
    if ( t_info.material_index != avoid ) avoid = -1;
  }
  if ( t_info.dist > MARCH_DIST ) {
    t_info.dist = -1.0f;
    return t_info;
  }
  t_info.dist = distance;
  return t_info;
}

int Generate_Subpath ( Ray ray, MapInfo* subpath, SceneInfo* scene_info ) {
  int mindex = -1;
  int i;
  for ( i = 0; i != MAX_DEPTH; ++ i ) {
    MapInfo minfo = March(mindex, ray, scene_info);
    if ( minfo.dist < 0.0f ) break;
    mindex = minfo.material_index;
    Material material = material_ptr[minfo.material_index];
    float3 hit = ray.origin + ray.dir*minfo.dist,
           nor = Normal(hit, scene_info);
    BSDF_Sample_Info bsdf_info = BSDF_Sample(ray, hit, nor,
                                       material, albedo, rng);
    ray.origin = hit;
    ray.dir = bsdf_info.omega_o;

    minfo.origin = hit;
    minfo.bsdf_info = bsdf_info;
    subpath[i] = minfo;
  }
  return i;
}

MapInfo Default_Subpath_Info ( float3 origin ) {
  MapInfo minfo;
  minfo.colour = (float3)(1.0f);
  minfo.origin = origin;
  minfo.material_index = 0;
  return minfo;
}

int Generate_Camera_Subpath( Ray ray, MapInfo* subpath, SceneInfo* scene_info ){
  subpath[0] = Default_Subpath_Info(ray.origin);
  int len = Generate_Subpath(ray, subpath+1, scene_info);
  return len;
}
int Generate_Light_Subpath ( Ray ray, MapInfo* subpath, SceneInfo* scene_info ){
  ray.dir = (float3)(Uniform_Sample(rng), Uniform_Sample(rng),
                     Uniform_Sample(rng));
  subpath[0] = Default_Subpath_Info(ray.origin);
  int len = Generate_Subpath(ray, subpath+1, scene_info);
  // Reverse incoming and outcoming ray direction. On the last iteration,
  // the omega_i is bogus;
  // camera_subpath[$-1].omega_o = light_subpath[$-1].omega_i
  for ( int i = 1; i < len; ++ i ) {
    BRDF_Sample_Info* tinfo = &(subpath[i].brdf_info);
    float3 omega_o = tinfo->omega_o;
    tinfo->omega_o = tinfo->omega_i;
    tinfo->omega_i = omega_o;
  }
  return len;
}

MapInfo Check_Subpath_Connection(float3 ox, float3 oy, int mx, int my,
                                 SceneInfo* scene_info) {
  Ray ray;
  ray.origin = ox;
  ray.dir    = normalize(oy - ox);
  MapInfo minfo = March(mx, ray, scene_info);
  float dist_pts = sqrt(sqr(ox.x + oy.x) +
                        sqr(ox.y + oy.y) +
                        sqr(ox.z + oy.z));
  minfo.dir = ray.dir;
  if ( minfo.mindex == my && fabs(minfo.dist - dist_pts) <= MARCH_ACC  )
    return minfo;
  minfo.dist = -1.0f;
  return minfo;
}

//----POSTPROCESS---
//%POSTPROCESS
MapInfo Colour_Pixel ( Ray ray, float time, SceneInfo* scene_info ) {
  // Bidirectional Path Tracing . .
  // Generate camera and light subpaths
  MapInfo camera_vertices[MAX_DEPTH+2],
          light_vertices [MAX_DEPTH+1];
  int camera_length = Generate_Camera_Subpath(ray, camera_vertices, scene_info);
  int light_length  = Generate_Light_Subpath (ray, light_vertices,  scene_info);

  // Execute BDPT connection strategy
  MapInfo result;
  minfo.dist = -1.0f;
  result.colour = (float3)(0.0f);
  float3 origin = ray.origin;
  for ( int t = 1; t <= camera_length; ++ t ) {
    for ( int s = 0; s <= light_length; ++ s ) {
      int depth = t + s - 2;
      if ( (s == 1 && t == 1) || depth < 0 || depth > MAX_DEPTH )
        continue;

      // Check validity of connection
      MapInfo connection_info =
        Check_Subpath_Connection(   camera_vertices[t].origin,
          light_vertices[s].origin, camera_vertices[t].mindex,
          light_vertices[s].mindex, time, texts, material_ptr, dval);

      if ( connection_info.dist < 0.0f ) continue;

      // Connect the two paths
      camera_vertices[t].bsdf_info =
        BSDF(camera_vertices[t].origin, camera_vertices[t].bsdf_info.omega_i,
             connection_info.dir,
             scene_info.material[camera_vertices[t].material_index],
             camera_vertices[t].colour, scene_info);
     light_vertices[s].bsdf_info =
       BSDF(light_vertices[s].origin, connection_info.dir,
            light_vertices[s].bsdf_info.omega_o,
            scene_info.material[light_vertices[s].material_index],
            light_vertices[s].colour, scene_info);


      // Evaluate path
      float mis_weight = 0.0f;
      float3 coeff = (float3)(1.0f);
      for ( int i = 1; i != depth-1; ++ i ) {
        MapInfo minfo = i < t ? camera_vertices[t] :
                                light_vertices[light_length - s];
        Material material = material_ptr[minfo.material_index];
        float3 albedo = minfo.colour;
        float3 normal = Normal(minfo.origin, time, texts, dval);
        coeff *= bsdf_info.brdf * minfo.bsdf_info.dir_cos/bsdf_info.pdf;
      }

      t = camera_length+1;
      minfo.colour = 1.0f * coeff;
      minfo.dist = 1.0f;
      break;
    }
  }
  return minfo;
}

// -----------------------------------------------------------------------------
// --------------- CAMERA ------------------------------------------------------
Ray Camera_Ray(Camera* camera) {
  float2 coord = (float2)((float)get_global_id(0), (float)get_global_id(1));
  float2 resolution = (float2)((float)camera->dim.x, (float)camera->dim.y);
  resolution.y *= 16.0f/9.0f;

  float2 mouse_pos = camera->lookat.xy;

  float2 puv = -1.0f + 2.0f * (coord/resolution);

  float input_angle = PI - 2.0f*PI*mouse_pos.x;
  float3 cam_pos    = camera->position;
  float3 cam_target = cam_pos + (float3)(sin(input_angle),
            (3.0f * mouse_pos.y) - 1.0f, cos(input_angle));
  float3 cam_front = normalize(cam_target - cam_pos);
  float3 cam_right = normalize ( cross(cam_front, (float3)(0.0f, 1.0f, 0.0f)));

  float3 cam_up  = normalize(cross(cam_right, cam_front));
  float3 ray_dir = normalize(puv.x*cam_right + puv.y*cam_up +
                             (180.0f - camera->fov)*PI/180.0f*cam_front);

  Ray ray;
  ray.origin = cam_pos;
  ray.dir = ray_dir;
  return ray;
}

// -----------------------------------------------------------------------------
// --------------- KERNEL ------------------------------------------------------
__kernel void DTOADQ_Kernel (
    __global unsigned char*     img, // R G B ITER
    __write_only image2d_t      output_image,
    __global SharedInfo*        sinfo,
    __global Camera*            camera_ptr,
    __global float*             time_ptr,
    __read_only image2d_array_t textures,
    __global Material*          material_ptr,
    __global float*             debug_val_ptr,
    __global int*               rng
  ) {
  int2 out = (int2)(get_global_id(0), get_global_id(1));
  float spp = (float)(sinfo->spp);
  Camera camera = *camera_ptr;
  int pt = out.y*camera.dim.x*4 + out.x*4;
  float4 old_colour = (float4)(0.0f);
  if ( !(sinfo->clear_img) ) {
    old_colour = (float4)(img[pt+0]/255.0f, img[pt+1]/255.0f,
                          img[pt+2]/255.0f, (float)(img[pt+3]));
  } else {
    img[pt+0] = 0.0f; img[pt+1] = 0.0f; img[pt+2] = 0.0f; img[pt+3] = 0.0f;
    write_imagef(output_image, out, (float4)(old_colour.xyz, 1.0f));
    sinfo->finished_samples = 0;
  }
  if ( old_colour.w < spp ) {
    float3 dval = (float3)(debug_val_ptr[0], debug_val_ptr[1],
                           debug_val_ptr[2]);
    float time = *time_ptr;
    // -- get old pixel, check if there are samples to be done
    //    (counter is stored in alpha channel)
    Update_Camera(&camera, time);

    Ray ray = Camera_Ray(&camera);
    MapInfo result = Colour_Pixel(ray, time, textures, material_ptr, dval, rng);

    float3 colour;
    if ( result.dist >= 0.0f ) {
      colour = result.colour;
      old_colour = (float4)(mix(colour, old_colour.xyz,
                              (old_colour.w/(old_colour.w+1.0f))),
                          old_colour.w+1.0f);
      write_imagef(output_image, out, (float4)(old_colour.xyz, 1.0f));
      //
      img[pt+0] = (unsigned char)(old_colour.x*255.0f);
      img[pt+1] = (unsigned char)(old_colour.y*255.0f);
      img[pt+2] = (unsigned char)(old_colour.z*255.0f);
      img[pt+3] = (unsigned char)(old_colour.w);
      //
    }
  }

  // convert to Y CB R, from matlab
  if ( sinfo->finished_samples >= camera.dim.x*camera.dim.y ) {
    float3 colour;
    colour = (float3)(img[pt+0]/255.0f, img[pt+1]/255.0f, img[pt+2]/255.0f);
    colour = (float3)(
        16.0f + (  65.481f*colour.x + 128.553f*colour.y + 24.966f*colour.z),
        128.0f + (- 37.797f*colour.x - 74.2030f*colour.y + 112.00f*colour.z),
        128.0f + ( 112.000f*colour.x - 93.7860f*colour.y - 18.214f*colour.z)
    );
    int irwx = (camera.dim.y - out.y)*camera.dim.x + out.x;
    int irwy = irwx + camera.dim.x*camera.dim.y;
    int irwz = irwx + camera.dim.x*camera.dim.y*2;
    img[irwx] = (unsigned char)(colour.x);
    img[irwy] = (unsigned char)(colour.y);
    img[irwz] = (unsigned char)(colour.z);
  }
}
};

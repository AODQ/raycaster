module opencl_kernel; immutable(string) Test_pathtrace_string = q{
#define MAX_DEPTH 128
// -----------------------------------------------------------------------------
// --------------- DEBUG -------------------------------------------------------
bool Is_Debug_Print ( ) {
  return get_global_id(get_work_dim()/2) == 1 &&
         get_global_id(get_work_dim()/2) == 1;
}
// -----------------------------------------------------------------------------
// --------------- GPU-CPU STRUCTS ---------------------------------------------
typedef struct T_Material {
  float3 base_colour;
  float metallic, subsurface, specular, roughness, specular_tint,
        anisotropic, sheen, sheen_tint, clearcoat, clearcoat_gloss,
        emission;
} Material;

typedef struct T_Camera {
  float3 position, lookat, up;
  int2 dim;
  float fov;
} Camera;

typedef struct RNG {
  ulong seed[16];
  ulong p;
} RNG;
// -----------------------------------------------------------------------------
// --------------- RANDOM ------------------------------------------------------
// --- random generation via xorshift1024star
ulong RNG_Next(RNG* rng) {
  const ulong s0 = (*rng).seed[(*rng).p];
  ulong       s1 = (*rng).seed[(*rng).p = ((*rng).p + 1)&15];
  s1 ^= s1 << 31; // a
  (*rng).seed[(*rng).p] = s1 ^ s0 ^ (s1 >> 11) ^ (s0 >> 30); // b, c
  return (*rng).seed[(*rng).p] * 1181783497276652981L *
              (get_global_id(0) + 250) * (get_global_id(1) + 250);
}

float Uniform(RNG* rng, const float min, const float max) {
  return min + ((float)RNG_Next(rng) / (float)(ULONG_MAX/(max-min)));
}

float UniformSample ( RNG* rng ) { return Uniform(rng, 0.0f, 1.0f); }

float3 Uniform_Float3(RNG* rng, const float min, const float max) {
  return (float3)(
    Uniform(rng, min, max),
    Uniform(rng, min, max),
    Uniform(rng, min, max)
  );
}
// -----------------------------------------------------------------------------
// --------------- NOISE -------------------------------------------------------
float2 fract2f ( float2 vec ) {float2 itptr; return fract(vec, &itptr);}
float  fract1f ( float  vec ) {float  itptr; return fract(vec, &itptr);}

float rand ( float2 n ) {
  return fract1f(sin(dot(n, (float2)(19.9898f, 4.1414f))) * 43758.5453f);
}
// -----------------------------------------------------------------------------
// --------------- MATRICES ----------------------------------------------------
typedef struct T_mat3 {
  float3 x, y, z;
} mat3;

float3 mat3_mul ( mat3 mat, float3 vec ) {
  return (float3)(
    mat.x.x*vec.x + mat.x.y*vec.y + mat.x.z*vec.z,
    mat.y.x*vec.x + mat.y.y*vec.y + mat.y.z*vec.z,
    mat.z.x*vec.x + mat.z.y*vec.y + mat.z.z*vec.z
  );
}

mat3 nmat3 ( float3 x_, float3 y_, float3 z_ ) {
  mat3 mat;
  mat.x = x_;
  mat.y = y_;
  mat.z = z_;
  return mat;
}

mat3 rotate_y ( float fi ) {
  return nmat3(
    (float3)(cos(fi), 0.0f, sin(fi)),
    (float3)(0.0f, 1.0f, 0.0f),
    (float3)(-sin(fi), 0.0f, cos(fi))
  );
}

mat3 rotate_x ( float fi ) {
  return nmat3(
    (float3)(1.0f, 0.0f, 0.0f),
    (float3)(0.0f, cos(fi), -sin(fi)),
    (float3)(0.0f, sin(fi),  cos(fi))
  );
}
// -----------------------------------------------------------------------------
// --------------- BASIC GRAPHIC FUNCTIONS -------------------------------------
__constant float PI = 3.1415926535f;

float3 reflect ( float3 V, float3 N ) {
  return V - 2.0f*dot(V, N)*N;
}

float sqr ( float t ) { return t*t; }

float3 refract(float3 V, float3 N, float refraction) {
  float cosI = -dot(N, V);
  float cosT = 1.0f - refraction*refraction*(1.0f - cosI*cosI);
  return (refraction*V) + (refraction*cosI - sqrt(cosT))*N;
}

// -----------------------------------------------------------------------------
// --------------- RAY ---------------------------------------------------------
typedef struct T_Ray {
  float3 origin, dir;
} Ray;

Ray New_Ray ( float3 o, float3 d ) {
  Ray ray;
  ray.origin = o;
  ray.dir    = d;
  return ray;
}

typedef struct T_IntersectionInfo {
  float dist;
  Material material;
  float3 origin, dir, normal;
} IntersectionInfo;
// -----------------------------------------------------------------------------
// --------------- BRDF/BSDF FUNCTIONS -----------------------------------------
float Schlick_Fresnel ( float u ) {
  return pown(clamp(1.0f - u, 0.0f, 1.0f), 5);
}

float GTR1 ( float NdotH, float a ) {
  if ( a >= 1.0f ) return 1.0f/PI;
  float a2 = a * a;
  float t = 1.0f + (a2 - 1.0f)*NdotH*NdotH;
  return (a2 - 1.0f)/(PI*log(a2)*t);
}

float GTR2 ( float NdotH, float a ) {
  float a2 = a*a;
  float t = 1.0f + (a2 - 1.0f)*NdotH*NdotH;
  return a2/(PI*t*t);
}

float GTR2_Aniso ( float NdotH, float HdotX, float HdotY, float ax, float ay ) {
  return 1.0f / ( PI * ax * ay * sqr(sqr(HdotX/ax) + sqr(HdotY/ay)
                                     + NdotH*NdotH));
}

float SmithG_GGX ( float NdotV, float alphaG ) {
  float a = alphaG*alphaG;
  float b = NdotV*NdotV;
  return 1.0f / (NdotV + sqrt(a + b - a*b));
}

float SmithG_GGX_Aniso ( float NdotV, float VdotX, float VdotY,
                         float ax, float ay ) {
  return 1.0f / (NdotV + sqrt(sqr(VdotX*ax) + sqr(VdotY*ay) + sqr(NdotV) ));
}


float3 Gamma_Correction ( float3 v ) {
  return pow(v, 2.2f);
}


float3 Disney_BRDF ( float3  L, float3 V, float3 N, float3 X, float3 Y,
                     Material* m ) {
  float NdotL = dot(N, L),
        NdotV = dot(N, V);
  if ( NdotL < 0.0f || NdotV < 0.0f ) return (float3)(0.0f);


  float3 H = normalize(L+V);
  float NdotH = dot(N, H),
        LdotH = dot(L, H);

  float3 Cdlin = Gamma_Correction(m->base_colour);
  float Cdlum = 0.3f*Cdlin.x + 0.6f*Cdlin.y + 0.1f*Cdlin.z; // emission approx
  // normalize lum to isolate hue+sat
  float3 Ctint = Cdlum > 0.0f ? Cdlin/Cdlum : (float3)(1.0f);
  float3 Cspec0 = mix(m->specular*0.08f*mix((float3)(1.0f), Ctint,
                                            m->specular_tint),
                      Cdlin, m->metallic);
  float3 Csheen = mix((float3)(1.0f), Ctint, m->sheen_tint);


  // Diffuse fresnel - 1 at normal incidence to 0.5f at grazing, mix in diffuse
  // retro reflection based on rougness
  float FL = Schlick_Fresnel(NdotL), FV = Schlick_Fresnel(NdotV);
  float Fd90 = 0.5f + 2.0f*LdotH*LdotH*m->roughness;
  float Fd = mix(1.0f, Fd90, FL) * mix(1.0f, Fd90, FV);

  // based on hanrahan krueger brdf approximation of isotropic bssrdf
  // 1.25f scale is to preserve albedo
  // fss90 used to flatten retroreflection based on roughness
  float Fss90 = LdotH*LdotH*m->roughness;
  float Fss = mix(1.0f, Fss90, FL) * mix(1.0f, Fss90, FV);
  float ss = 1.25f * (Fss * (1.0f / (NdotL + NdotV) - 0.5f) + 0.5f);

  // specular
  float aspect = sqrt(1.0f - m->anisotropic*0.9f);
  float ax = fmax(.001f, sqr(m->roughness)/aspect);
  float ay = fmax(.001f, sqr(m->roughness)*aspect);
  float Ds = GTR2_Aniso(NdotH, dot(H, X), dot(H, Y), ax, ay);
  float FH = Schlick_Fresnel(LdotH);
  float3 Fs = mix(Cspec0, (float3)(1.0f), FH);
  float Gs  = SmithG_GGX_Aniso(NdotL, dot(L, X), dot(L, Y), ax, ay);
        Gs *= SmithG_GGX_Aniso(NdotL, dot(V, X), dot(V, Y), ax, ay);

  // sheen
  float3 Fsheen = FH*m->sheen*Csheen;

  // clearcoat (ior = 1.5f -> F0 = 0.05f)
  float Dr = GTR1(NdotH, mix(0.1f, 0.001f, m->clearcoat_gloss));
  float Fr = mix(0.04f, 1.0f, FH);
  float Gr = SmithG_GGX(NdotL, 0.25f) * SmithG_GGX(NdotV, 0.25f);

  return ((1.0f/PI) * mix(Fd, ss, m->subsurface)*Cdlin + Fsheen) *
         (1.0f-m->metallic) + Gs*Fs*Ds + 0.25f*m->clearcoat*Gr*Fr*Dr;
}

// -----------------------------------------------------------------------------
// --------------- MAP GEOMETRY FUNCTIONS --------------------------------------
float noise ( float2 n ) {
  const float2 d = (float2)(0.0f, 1.0f);
  float2 b = floor(n),
         f = smoothstep((float2)(0.0f), (float2)(1.0f), fract2f(n));
  return mix(mix(rand(b), rand(b + d.yx), f.x),
             mix(rand(b + d.xy), rand(b + d.yy), f.x),
             f.y);
}

float sdPlane ( float3 p, float3 wal, float dist ) {
  return dot(p, wal) + dist;
}

float sdSphere( float3 p, float s ) {
    return length(p)-s;
}

float sdBumpSphere( float3 p, float s ) {
  return length(p) - s+noise(p.xy);//0.2f*cos(p.z);
}

float sdBox( float3 p, float3 b ) {
    float3 d = fabs(p) - b;
    return fmin(fmax(d.x,fmax(d.y,d.z)),0.0f) + length(fmax(d,0.0f));
}

float sdEllipsoid( float3 p, float3 r ) {
    return (length( p/r ) - 1.0f) * fmin(fmin(r.x,r.y),r.z);
}

float sdTorus( float3 p, float2 t ) {
    return length( (float2)(length(p.xz)-t.x,p.y) )-t.y;
}

float sdHexPrism( float3 p, float2 h ) {
    float3 q = fabs(p);
    float d1 = q.z-h.y;
    float d2 = fmax((q.x*0.866025f+q.y*0.5f),q.y)-h.x;
    return length(fmax((float2)(d1,d2),0.0f)) + fmin(fmax(d1,d2), 0.0f);
}

float sdCapsule( float3 p, float3 a, float3 b, float r ) {
	float3 pa = p-a, ba = b-a;
	float h = clamp( dot(pa,ba)/dot(ba,ba), 0.0f, 1.0f );
	return length( pa - ba*h ) - r;
}

float sdTriPrism( float3 p, float2 h ) {
    float3 q = fabs(p);
    float d1 = q.z-h.y;
    float d2 = fmax(q.x*0.866025f+p.y*0.5f,-p.y)-h.x*0.5f;
    return length(fmax((float2)(d1,d2),0.0f)) + fmin(fmax(d1,d2), 0.0f);
}

float sdCylinder( float3 p, float2 h ) {
  float2 d = fabs((float2)(length(p.xz),p.y)) - h;
  return fmin(fmax(d.x,d.y),0.0f) + length(fmax(d,0.0f));
}

float sdCone( float3 p, float3 c ) {
    float2 q = (float2)( length(p.xz), p.y );
    float d1 = -q.y-c.z;
    float d2 = fmax( dot(q,c.xy), q.y);
    return length(fmax((float2)(d1,d2),0.0f)) + fmin(fmax(d1,d2), 0.0f);
}

float sdConeSection( float3 p, float h, float r1, float r2 ) {
    float d1 = -p.y - h;
    float q = p.y - h;
    float si = 0.5f*(r1-r2)/h;
    float d2 = fmax( sqrt( dot(p.xz,p.xz)*(1.0f-si*si)) + q*si - r2, q );
    return length(fmax((float2)(d1,d2),0.0f)) + fmin(fmax(d1,d2), 0.0f);
}

float sdPryamid4(float3 p, float3 h ) { // h = { cos a, sin a, height } {
    // Tetrahedron = Octahedron - Cube
    float box = sdBox( p - (float3)(0.0f,-2.0f*h.z,0.0f), (float3)(2.0f*h.z) );

    float d = 0.0f;
    d = fmax( d, fabs( dot(p, (float3)( -h.x, h.y, 0.0f )) ));
    d = fmax( d, fabs( dot(p, (float3)(  h.x, h.y, 0.0f )) ));
    d = fmax( d, fabs( dot(p, (float3)(  0.0f, h.y, h.x )) ));
    d = fmax( d, fabs( dot(p, (float3)(  0.0f, h.y,-h.x )) ));
    float octa = d - h.z;
    return fmax(-box,octa); // Subtraction
 }

float length2( float2 p ) {
	return sqrt( p.x*p.x + p.y*p.y );
}

float length6( float2 p ) {
	p = p*p*p; p = p*p;
	return pow( p.x + p.y, 1.0f/6.0f );
}

float length8( float2 p ) {
	p = p*p; p = p*p; p = p*p;
	return pow( p.x + p.y, 1.0f/8.0f );
}

float sdTorus82( float3 p, float2 t ) {
    float2 q = (float2)(length2(p.xz)-t.x,p.y);
    return length8(q)-t.y;
}

float sdTorus88( float3 p, float2 t ) {
    float2 q = (float2)(length8(p.xz)-t.x,p.y);
    return length8(q)-t.y;
}

float sdCylinder6( float3 p, float2 h ) {
    return fmax( length6(p.xz)-h.x, fabs(p.y)-h.y );
}

//------------------------------------------------------------------

float opS( float d1, float d2 ) {
    return fmax(-d2,d1);
}

float2 opU( float2 d1, float2 d2 ) {
	return (d1.x<d2.x) ? d1 : d2;
}

float3 opRep( float3 p, float3 c ) {
    return fmod(p,c)-0.5f*c;
}

float3 opTwist( float3 p ) {
    float  c = cos(10.0f*p.y+10.0f);
    float  s = sin(10.0f*p.y+10.0f);
    return p;
    // mat2   m = mat2(c,-s,s,c);
    // return (float3)(m*p.xz,p.y);
}

//------------------------------------------------------------------


// -----------------------------------------------------------------------------
// --------------- MAP ---------------------------------------------------------
float2 Map ( float3 p ) {
  // -- spheres --
  float2 res= (float2)(sdSphere(p-(float3)( 0.2f,-0.95f,-1.6f),0.30f),1.0f);
  res=opU(res,(float2)(sdBumpSphere(p-(float3)( 0.0f,-0.85f, 0.0f),0.25f),2.0f));
  res=opU(res,(float2)(sdSphere(p-(float3)(-1.2f,-0.85f, 1.2f),0.55f),3.0f));
  res=opU(res,(float2)(sdCylinder(p-(float3)( 0.0f, 0.0f,  0.0f),
                                    (float2)(0.3f, 0.4f)), 4.0f));
  // // -- walls --
  res=opU(res,(float2)(sdPlane(p, (float3)( 0.0f,  0.0f, -1.0f),12.0f),10.0f));
  res=opU(res,(float2)(sdPlane(p, (float3)( 1.0f,  0.0f,  0.0f),12.0f),11.0f));
  res=opU(res,(float2)(sdPlane(p, (float3)( 0.0f,  1.0f,  0.0f),12.0f),12.0f));
  res=opU(res,(float2)(sdPlane(p, (float3)( 0.0f,  0.0f,  1.0f),12.0f),13.0f));
  res=opU(res,(float2)(sdPlane(p, (float3)(-1.0f,  0.0f,  0.0f),12.0f),14.0f));
  res=opU(res,(float2)(sdPlane(p, (float3)( 0.0f, -1.0f,  0.0f),12.0f),15.0f));
  // // --- lights --
  // res=opU(res,(float2)(sdSphere(p-(float3)(-0.6f, -0.2f,  -3.0f), 1.3f),16.0f));
  // res=opU(res,(float2)(sdSphere(p-(float3)( 1.8f,  1.8f,   1.9f), 0.8f),17.0f));
//res=opU(res,(float2)(sdTorus(p-(float3)(0.0f,0.25f,1.0f),(float2)(0.20f,0.05f)),4.0f));
//res=opU(res,(float2)(sdCapsule(p-(float3)(-1.3f,0.10f,-0.1f),(float3)(-0.8f,0.50f,0.2f),0.1f),4.0f));
//res=opU(res,(float2)(sdTriPrism(p-(float3)(-1.0f,0.25f,-1.0f),(float2)(0.25f,0.05f)),5.0f));
//res=opU(res,(float2)(sdCylinder(p-(float3)(1.0f,0.30f,-1.0f),(float2)(0.1f,0.2f)),6.0f));
//res=opU(res,(float2)(sdCone(p-(float3)(0.0f,0.50f,-1.0f),(float3)(0.8f,0.6f,0.3f)),7.0f));
//res=opU(res,(float2)(sdTorus82(p-(float3)(0.0f,0.25f,2.0f),(float2)(0.20f,0.05f)),8.0f));
//res=opU(res,(float2)(sdTorus88(p-(float3)(-1.0f,0.25f,2.0f),(float2)(0.20f,0.05f)),9.0f));
//res=opU(res,(float2)(sdCylinder6(p-(float3)(1.0f,0.30f,2.0f),(float2)(0.1f,0.2f)),10.0f));
//res=opU(res,(float2)(sdHexPrism(p-(float3)(-1.0f,0.20f,1.0f),(float2)(0.25f,0.05f)),11.0f));
//res=opU(res,(float2)(sdPryamid4(p-(float3)(-1.0f,0.15f,-2.0f),(float3)(0.8f,0.6f,0.25f)),12.0f));
//res=opU(res,(float2)(0.5f*sdTorus(opTwist(p-(float3)(-2.0f,0.25f,2.0f)),(float2)(0.20f,0.05f)),13.0f));
//res=opU(res,(float2)(sdConeSection(p-(float3)(0.0f,0.35f,-2.0f),0.15f,0.2f,0.1f),14.0f));
//res=opU(res,(float2)(sdEllipsoid(p-(float3)(1.0f,0.35f,-2.0f),(float3)(0.15f,0.2f,0.05f)),15.0f));

  return res;
}
// /** MAP INSERTION POINT: */ %s /** <- */
// -----------------------------------------------------------------------------
// --------------- GRAPHIC FUNCS THAT NEED MAP ---------------------------------
float3 Normal ( float3 p ) {
  const float Delta  = 0.001f,
              Delta2 = Delta*2.0f;

  const float3 X = (float3)(Delta, 0.0f, 0.0f),
               Y = (float3)(0.0f, Delta, 0.0f),
               Z = (float3)(0.0f, 0.0f, Delta);

  return (float3)(
    (Map(p + X).x - Map(p - X).x)/Delta2,
    (Map(p + Y).x - Map(p - Y).x)/Delta2,
    (Map(p + Z).x - Map(p - Z).x)/Delta2
  );
}

/**
  FIXME !!
  Doesn't work! need to find hwo to properly get tangent!!
*/
float3 Tangent ( float3 normal ) {
  float3 t1 = cross(normal, (float3)(0.0f, 0.0f, 1.0f)),
         t2 = cross(normal, (float3)(0.0f, 1.0f, 0.0f));
  if ( length(t1) > length(t2) ) return t1;
  return t2;
}

float3 BRDF ( float3 pos, float3 cam, float3 lpos, Material* material ) {
  float3 N         = normalize(Normal(pos)),
         L         = normalize(lpos - pos),
         V         = normalize(cam - pos),
         tangent   = normalize(cross(Tangent(N), N)),
         bitangent = normalize(cross(N, tangent));
  float3 result = Disney_BRDF(L, V, N, tangent, bitangent, material);

  result *= dot(N, L);
  return result;
}

// -----------------------------------------------------------------------------
// --------------- RAYTRACING/MARCH --------------------------------------------
float2 March ( Ray ray ) {
  const float max_dist = 8.0f;
  float distance = 0.0f;
  float2 t_info;
  for ( int i = 0; i < 128; ++ i ) {
    t_info = Map(ray.origin + ray.dir*distance);
    if ( t_info.x < 0.01f || t_info.x > max_dist ) break;
    distance += t_info.x;
  }
  if ( t_info.x > max_dist ) {
    t_info.x = 8.0f;
    t_info.y = 0.0f;
    // t_info.x = -1.0f;
    return t_info;
  }
  t_info.x = distance;
  return t_info;
}

// uses cosine weight random hemisphere directions
// thanks to embree
float3 Hemisphere_Direction ( RNG* rng, float3 normal ) {
  const float phi = 2.0f*PI*UniformSample(rng),
              vv  = 2.0f*(UniformSample(rng) - 0.5f);
  const float cos_theta = sign(vv)*sqrt(fabs(vv)),
              sin_theta = sqrt(fmax(0.0f, 1.0f - (cos_theta*cos_theta)));
  return (float3)(cos(phi)*sin_theta, sin(phi)*sin_theta, cos_theta);
}

float3 Hemisphere_Weighted_Direction ( RNG* rng, float3 normal,
                                       float weight ) {
  float3 dir = Hemisphere_Direction(rng, normal);
  return normalize(dir + normal*weight);
}

float3 Orient_Normal ( float3 normal, float3 direction ) {
  return normal * (dot(normal, direction) < 0.0f ? -1.0f : 1.0f);
}

Ray TODO_BRDF_Reflect ( RNG* rng, const IntersectionInfo* info) {
  Ray rout;
  // if ( Uniform(rng, 0.0f, 1.0) > material.metallic ) {
    // diffuse
  if ( info->material.metallic < 0.2f )
    rout.dir = normalize(Hemisphere_Direction(rng, info->normal));
  else
    rout.dir = reflect(info->dir, info->normal);
  // } else {
  //   // specular/transmission
  //   float3 axis = Hemisphere_Weighted_Direction(rng, info.normal,
  //                         material.specular);
  //   if ( Uniform(rng, 0.0f, 1.0f) > material.anisotropic ) {
  //     //reflect
  //     rout.dir = normalize(info.dir - axis*dot(info.dir, axis)*2.0f);
  //   } else {
  //     //refract
  //     // TODO ! !
  //   }
  // }
  rout.origin = info->origin + rout.dir*0.2f;
  return rout;
}

float3 TODO_BRDF_Radiance ( float3 radiance, IntersectionInfo* info ){
  if ( info->material.metallic < 0.2f )
    return (radiance+info->material.emission)*info->material.base_colour;
            // cos(dot(info->normal, info->dir)/2.0f);
  else
    return radiance*0.8f;
}

typedef struct T_RayInfo {
  bool hit;
  float3 colour;
} RayInfo;

RayInfo Raytrace ( RNG* rng, const __global Material* material, Ray ray,
                  IntersectionInfo* hit_info ) {
  Ray cray = ray;
  // Trace a path from camera origin to some end
  int depth;
  bool hit = false;
  for ( depth = 0; depth != MAX_DEPTH; ++ depth ) {
    float2 marchinfo = March(ray);
    IntersectionInfo info;
    info.dist = marchinfo.x;
    info.dir = ray.dir;
    info.origin = ray.origin + ray.dir*info.dist;
    info.normal = normalize(Normal(info.origin));
    info.material = material[(int)(marchinfo.y)];
    hit_info[depth] = info;
    ray = TODO_BRDF_Reflect(rng, &info);
    if ( info.material.emission > 0.001f ) {
      hit = true;
      break;
    }
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // Now we have a path, so we calculate the radiance from the light source
  float3 radiance = (float3)(0.0f, 0.0f, 0.0f);
  for ( int it = depth; it >= 0; -- it ) {
    radiance = TODO_BRDF_Radiance(radiance, hit_info + it);
  }

  barrier(CLK_LOCAL_MEM_FENCE);
  RayInfo rinfo;
  rinfo.hit = hit;
  rinfo.colour = radiance;
  return rinfo;
}
// -----------------------------------------------------------------------------
// --------------- CAMERA ------------------------------------------------------
Ray Camera_Ray(RNG* rng, __global Camera* camera) {
  float2 coord = (float2)((float)get_global_id(0), (float)get_global_id(1));
  coord += (float2)(Uniform(rng, -0.8f, 0.8f),
                    Uniform(rng, -0.8f, 0.8f));
  float2 resolution = (float2)((float)camera->dim.x, (float)camera->dim.y);

  float2 mouse_pos = camera->lookat.xy;

  float2 puv = -1.0f + 2.0f * (coord/resolution);

  float input_angle = PI - 2.0f*PI*mouse_pos.x;
  float3 cam_pos = camera->position;
  float3 cam_target = cam_pos + (float3)(sin(input_angle),
                                         (3.0f * mouse_pos.y) - 1.0f,
                                         cos(input_angle));
  float3 cam_front = normalize(cam_target - cam_pos);
  float3 cam_right = normalize ( cross(cam_front, (float3)(0.0f, 1.0f, 0.0f)));

  float3 cam_up = normalize(cross(cam_right, cam_front));
  float3 ray_dir = normalize(puv.x*cam_right + puv.y*cam_up + 2.0f*cam_front);

  return New_Ray(cam_pos, ray_dir);
}

// -----------------------------------------------------------------------------
// --------------- KERNEL ------------------------------------------------------
__kernel void Kernel_Pathtrace (
        __write_only image2d_t output_image,
        __read_only  image2d_t input_image,
        __global RNG* rng_ptr,
        __global Camera* camera,
        __global float* time_ptr,
        __global Material* material, __global int* material_size
      ) {
  int2 out = (int2)(get_global_id(0), get_global_id(1));
  RNG rng = *rng_ptr;
  // -- get old pixel, check if there are samples to be done
  //    (counter is stored in alpha channel)
  float4 old_pixel = read_imagef(input_image, out);
  // -- set up camera and stack
  IntersectionInfo hit_info[MAX_DEPTH];

  float time = *time_ptr;
  Ray ray = Camera_Ray(&rng, camera);
  RayInfo result = Raytrace(&rng, material, ray, hit_info);

  if ( Is_Debug_Print() ) {
    printf("W: %f\n", old_pixel.w);
    printf("RESULT: <%f, %f, %f>\n", result.colour.x, result.colour.y,
                                     result.colour.z);
    printf("OLD:    <%f, %f, %f>\n", old_pixel.x, old_pixel.y, old_pixel.z);
    printf("MIX:    %f\n", (old_pixel.w/(old_pixel.w+1.0f)));
    printf("HIT:    %d\n", result.hit);
  }
  if ( result.hit ) {
    old_pixel =
      (float4)(
        mix(
          result.colour,
          old_pixel.xyz,
          (old_pixel.w/(old_pixel.w+5.1f))),
        old_pixel.w+1.0f);
  }

  barrier(CLK_GLOBAL_MEM_FENCE);
  write_imagef(output_image, out, old_pixel);

  if ( get_global_id(0) == 5 && get_global_id(1) == 5 )
    *rng_ptr = rng;

  // -- SUN GLARE :-) --
  // ray.dir += Uniform_Float3(rng, -2.5f, 2.5f);
  // float3 glare = Raytrace(ray, material, rng, time);
  // if ( glare.x > 1.5f ) {
  //   colour = glare/(float)SPP;
  //   write_imagef(output_image, out, (float4)(colour, 1.0f));
  // }
}};

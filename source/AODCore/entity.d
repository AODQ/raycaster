/**
  Entities are what the engine uses to render images to the screen. They also
  support collision detection.
Example:
---
  // To create your own entity class
  class Player {
  public:
    this() {
      super(); // Make sure to call this
      Set_Sprite(Img); // sets sprite
      Set_Size(32, 32, true); // Set the image & collision size to 32x32 pixels
    }
    override void Update() {
      static int time = 0;
      ++ time;
      Set_Position(Vector(cos(time), sin(time)));
    }
  }

  // and then to add to the engine
  auto player = new Player();
  AOD.Add(player);
---
*/

module AODCore.entity;

import derelict.opengl3.gl3;
import derelict.sdl2.sdl;

import AODCore.aod;
/**
  A basic entity class. If you want collision support you should perhaps use
  AABBEntity or PolyEntity
*/
class Entity : Render_Base {
public:
  /**
Params:
    _layer = Layer that the entity should be rendered (0 is top)
    _type  = Type of Entity
  */
  this(ubyte _layer = 5, Type _type = Type.nil) {
    super(_layer);
    type = _type;
    alpha = 1;
    Set_UVs(Vector(0,0), Vector(1,1));
    matrix = Matrix.New();
    rotation = 0;
    rotation_velocity = 0;
    velocity = Vector(0,0);
    is_coloured = 0;
    flipped_x = 0;
    flipped_y = 0;
    rotate_origin = Vector( 0, 0 );
    scale = Vector( 1, 1 );
    Refresh_Transform();
    static_position = false;
  }
  /** Returns true if the entity is clicked
Params:
    offset = If true the check will be adjusted for camera offset (generally set
               this to false for non-static objects)
  */
  bool Clicked(bool offset) {
	  return R_Mouse_Left() &&   R_Mouse_X(offset) > position.x - size.x / 2.0f &&
                               R_Mouse_X(offset) < position.x + size.x / 2.0f &&
                               R_Mouse_Y(offset) > position.y - size.y / 2.0f &&
                               R_Mouse_Y(offset) < position.y + size.y / 2.0f;
  }

  /** Returns true if the entity was clickd on this frame
Params:
  offset = If true the check will be adjusted for camera offset (generally set this
              to false for non-static objects)
  */
  bool Clicked_On(bool offset) {
	  return R_Mouse_Left_Frame() &&
           R_Mouse_X(offset) > position.x - size.x / 2.0f &&
           R_Mouse_X(offset) < position.x + size.x / 2.0f &&
           R_Mouse_Y(offset) > position.y - size.y / 2.0f &&
           R_Mouse_Y(offset) < position.y + size.y / 2.0f;
  }

  /** Sets current image to render for this entity
    Params:
      index = GL Image to render
      reset_size = If the size of this entity (and image) should be resized
                      to index' size
  */
  void Set_Sprite(GLuint index, bool reset_size = 0)
  in {
    assert(index > 0);
  } body {
    if ( reset_size ) {
      GLuint tex = index;
      glGenTextures(1, &tex);
      //glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      //glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      int w, h;
      glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH,  &w);
      glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &h);
      glDeleteTextures(1, &tex);
      size.x = w;
      size.y = h;
      image_size.x = w;
      image_size.y = h;
    }
    image = index;
  }
  /** Sets a sheetcontainer to render this entity
Params:
     sc =
     reset_size = If true, entity size will be set to image_size
                  (sc.width/height)
   */
  void Set_Sprite(SheetContainer sc, bool reset_size = 0) {
    image = sc.texture;
    image_size.x = sc.width;
    image_size.y = sc.height;
    if ( reset_size ) {
      Set_Size(R_Img_Size);
    }
  }
  /** Sets a sheetrect to render this entity
Params:
   sr =
   reset_size = If true, entity size will be set to image_size
                 (sr.width/height) */
  void Set_Sprite(SheetRect sr, bool reset_size = 0) {
    image = sr.texture;
    image_size.x = sr.width;
    image_size.y = sr.height;
    Set_UVs(sr.ul, sr.lr);
    if ( reset_size ) {
      Set_Size(R_Img_Size);
    }
  }
  /** */
  GLuint R_Sprite_Texture() { return image; }

  /** Sets shader to render entity with */
  void Set_Shader(Shader _shader) {
    shader = _shader;
  }

  /** */
  Shader R_Shader() { return shader; }

  /** (radians)*/
  void Add_Rotation(float r) {
    rotation += r;
    Refresh_Transform();
  }
  /** (radians)*/
  void Set_Rotation(float r) {
    rotation = r;
    Refresh_Transform();
  }
  /** (radians)*/
  float R_Rotation() { return rotation; }

  /** */
  void Add_Velocity(Vector force) {
    velocity += force;
  }
  /** */
  void Set_Velocity(Vector vel) {
    velocity = vel;
  }
  /** */
  void Set_Velocity(float x, float y) {
    velocity.x = x;
    velocity.y = y;
  }
  /** The amount added to rotation every update frame */
  void Set_Torque(float t) {
    rotation_velocity = t;
  }
  void Add_Torque(float t) {
    rotation_velocity += t;
  }
  Vector R_Velocity() const {
    return velocity;
  }
  float R_Torque() {
    return rotation_velocity;
  }

  /** Sets the subsection of the image to be rendered */
  void Set_Sprite_Frame(float left_x,  float top_y,
                        float right_x, float bot_y) {
    Set_UVs(Vector(left_x  , top_y),
            Vector(right_x , bot_y));
  }

  /** Sets the UV directly */
  void Set_UVs(Vector ul, Vector lr, bool reset_flip = 1) {
    _UV = [
      ul.x, lr.y,
      lr.x, lr.y,
      lr.x, ul.y,
      ul.x, ul.y
    ];
    if ( reset_flip ) {
      flipped_x = 0;
      flipped_y = 1;
    }
  }
  /** Sets UV to passed in paremeters
    Params:
      left  = [ UV[2], UV[3] ]
      right = [ UV[4], UV[5] ]
  */
  void R_UVs(ref Vector left, ref Vector right) {
    left.x  = _UV[2];
    left.y  = _UV[3];
    right.x = _UV[4];
    right.y = _UV[5];
  }
  /**  */
  auto R_UV_Array() { return _UV; }
  /** sets flip of of X */
  // void Set_Flip_X(bool flip) { if ( flipped_x != flip ) Flip_X(); }
  /** sets flip of of Y */
  // void Set_Flip_X(bool flip) { if ( flipped_y != flip ) Flip_X(); }
  /** Flips the image on the x-axis */
  void Flip_X() {
    Vector bot = Vector(_UV[0], _UV[5]),
           top = Vector(_UV[2], _UV[3]);
    Set_UVs( Vector( top.x, bot.y),
             Vector( bot.x, top.y), false );
    flipped_x ^= 1;
  }
  /** Flips the image on the y-axis */
  void Flip_Y() {
    Vector bot = Vector(_UV[0], _UV[5]),
           top = Vector(_UV[2], _UV[3]);
    Set_UVs( Vector( bot.x, top.y),
             Vector( top.x, bot.y), false );
    flipped_y ^= 1;
  }

  /** Sets the size of the entity
    Params:
      vec         = Size of the entity (in pixels)
      scale_image = If the size should scale the image as well
  */
  void Set_Size(Vector vec, bool scale_image = 0) {
    size = vec;
    if ( scale_image )
      Set_Image_Size(vec);
    Refresh_Transform();
  }
  /** */
  void Set_Size(int x, int y, bool scale_image = 0) {
    Set_Size(Vector(x, y), scale_image);
  }
  /** Sets the size of the image itself, does not affect the entity */
  void Set_Image_Size(Vector vec) {
    image_size = vec;
  }

  /** Returns:
        size of the entity itself
  */
  Vector R_Size()     { return size;       }
  /** Returns:
        the size of the image
  */
  Vector R_Img_Size() { return image_size; }

  /** Sets the colour of the image */
  void Set_Colour(float r = 1, float g = 1,
                  float b = 1, float a = 1) {
    red = r; green = g; blue = b; alpha = a;
    is_coloured = 1;
  }
  /** Cancels manually overriding the colour of the image */
  void Cancel_Colour() { is_coloured = 0; }

  /** Sets the origin of the entity (default is the center of the image size) */
  void Set_Origin(Vector v) {
    rotate_origin = v;
  }
  /** Resets origin to the center of the image size */
  void Clear_Origin() {
    rotate_origin = Vector(0, 0);
  }
  /** Returns:
        the current origin of the image
  */
  Vector R_Origin() { return rotate_origin; }

  /** Sets position based on any two types that are casteable to float */
  void Set_Position(T)(T x, T y) {
    position.x = cast(float)x;
    position.y = cast(float)y;
  }
  /** Adds positionb ased on any two types that are casteable to float */
  void Add_Position(T)(T x, T y) {
    position.x = cast(float)x;
    position.y = cast(float)y;
  }
  /** Sets position based off vector */
  void Set_Position(Vector vec) {
    position = vec;
  }
  /** Sets position X */
  void Set_PositionX(float n) {
    position.x = n;
  }
  /** Sets position Y */
  void Set_PositionY(float n) {
    position.y = n;
  }
  /** Adds position based off vector */
  void Add_Position(Vector vec) {
    position += vec;
  }
  /** Returns current position
  Params:
    apply_static = If this or static_position is false, will modify
            returned position based off the camera
  */
  override Vector R_Position(bool apply_static = false) {
    if ( apply_static && !static_position ) {
      return Vector(position.x - Camera.R_Position.x,
                    position.y - Camera.R_Position.y);
    }
    return position;
  }

  /** */
  float R_Green()        { return green;       }
  /** */
  float R_Red()          { return red;         }
  /** */
  float R_Blue()         { return blue;        }
  /** */
  float R_Alpha()        { return alpha;       }
  /** */
  bool R_Coloured()      { return is_coloured; }
  /** */
  bool R_Flipped_X()     { return flipped_x;   }
  /** */
  bool R_Flipped_Y()     { return flipped_y;   }

  /** */
  Type R_Type()     { return type;   }
  /** */
  Matrix R_Matrix() { return matrix; }
  // ---- utility ----
  /** Called immediately before rendering this entity, used to change GLSL
      uniform values. Meant to be overriden */
  void Prerender() {}
  override void Update() {};
  /** Applies velocity/torque to entity (No need to call this) */
  // override void Post_Update() {
  //   Add_Position(R_Velocity);
  //   Add_Rotation(R_Torque);
  // }
  /** Determines if there is a collision between this entity and another
      Returns:
        Result of the collision in respects to this colliding onto the other
  */
  Collision_Info Collision(Entity o) {
    return Collision_Info();
  }
  override void Render() {
    if ( !R_Visible ) return;
    auto pos = R_Position(true);
    import gl3n.linalg;
    import AODCore.shader;

    int fx = R_Flipped_X ? -1 : 1,
        fy = R_Flipped_Y ?  1 :-1;

    float dx = (1.0f/R_Window_Width ) * R_Img_Size.x,
          dy = (1.0f/R_Window_Height) * R_Img_Size.y;
    mat4 view = mat4.identity().rotatez(rotation).scale(dx, dy, 1.0f);
    view = view.translate( (2.0f/R_Window_Width )*pos.x - 1.0f,
                          -(2.0f/R_Window_Height)*pos.y + 1.0f, 1.0f);
    glUniformMatrix4fv(def_attr_view,   1, GL_TRUE,  &view[0][0]);
    glUseProgram(def_shader);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, R_Sprite_Texture);
    glUniform1i(def_attr_tex, 0);

    glBindBuffer(GL_ARRAY_BUFFER, VBO_UV);
    glBufferData(GL_ARRAY_BUFFER, _UV.length*float.sizeof, _UV.ptr,
                                                    GL_STATIC_DRAW);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, null);
    glBindBuffer(GL_ARRAY_BUFFER, VBO);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, null);
  }
private:
  void Refresh_Transform() {
    matrix.Compose(position, rotation, scale);
    transformed = true;
  }
public:
  /** The collision type of entity */
  enum Type { Circle, AABB, Polygon, Ray, nil };
protected:
  /** Current image to render to the screen */
  GLuint image;
  /** Rotation in radians of object (and image) */
  float rotation;
  /** The amount added to rotation every update frame */
  float rotation_velocity;
  /** Used to keep track of rotation, translation and scaling */
  Matrix matrix;
  /** Collision type of entity */
  Type type;
  /** Amount added to position every update frame */
  Vector velocity;
  Vector scale;
  /** Scale of the object (for collision, does not affect image)*/
  Vector size;
  /** Size of image */
  Vector image_size;
  /** The origin of which to apply rotation. Origin default is in the middle
      of the image */
  Vector rotate_origin;
  /** The alpha of the image */
  float alpha;
  /** Determines if the image is flipped on the x-axis */
  bool flipped_x;
  /** Determines if the imagei s flipped on the y-axis */
  bool flipped_y;
  /** The UV that determines how the image is rendered */
  GLfloat[8] _UV;
  bool is_coloured;
  float red, green, blue;

  /** Used to determine if the vertices entity need to be restructured */
  bool transformed;
  /** Current shader to use to render this (null == no shader) */
  Shader shader;
  /* */
  Vector position;
  /* */
  bool static_position;
};

// -------------- POLY OBJ -----------------------------------------------------

/**
  An entity that uses polygon collision (only supports convex polygons)
*/
class PolyEntity : Entity {
protected:
  Vector[] vertices, vertices_transform;
  void Build_Transform() {}
public:
  /** Constructs an entity that has no vertices */
  this(ubyte _layer = 0) {
    super(_layer, Type.Polygon);
    vertices = [];
  }
  /** Constructs an entity
    Params:
      vertices_ = Vertices to construct polygon with (must be
                   convex and in counter-clockwise order)
      off       = Sets position of entity
      _layer    = layer
  */
  this(Vector[] vertices_, Vector off = Vector( 0, 0 ), ubyte _layer = 0) {
    super(_layer, Type.Polygon);
    vertices = vertices_;
    Set_Position(off);
  }

  // ---- ret/set ----
  // will override previous vectors
  /** Resets vertices of entity
    Params:
      vertices_ =  Vertices to construct polygon with (must be convex)
      reorder   =  If set, the vertices will be ordered as CCW (if set to) 0
                      then vertices_ MUST be in CCW order
  */
  void Set_Vertices(Vector[] vertices_, bool reorder = 1) {
    vertices = vertices_;
    if ( reorder ) {
      Order_Vertices(vertices);
    }
    Build_Transform();
  }
  /** */
  Vector[] R_Vertices() {
    return vertices;
  }
  /**
  Returns:
      Vertices transformed by the entity's matrix
  */
  Vector[] R_Transformed_Vertices(bool force = 0) {
    // check if transform needs to be updated
    if ( transformed || force ) {
      transformed = 0;
      vertices_transform = [];

      foreach ( i; vertices )
        vertices_transform ~= Vector.Transform(R_Matrix(), i);
    }

    return vertices_transform;
  }

  // ---- utility ----

  /** Check collision with another PolyEntity
    Params:
      poly     = Another PolyEntity
      velocity = Velocity for which to check collision
    Returns:
      Result of the collision in respects to this colliding onto the poly
  */
  Collision_Info Collision(PolyEntity poly, Vector velocity) in {
    assert(vertices.length > 0 && poly.R_Vertices().length > 0);
  } body {
    return PolyPolyColl(this, poly, velocity);
  }
  /** Check collision with another AABBEntity
    Params:
      aabb     = Another AABBEntity
      velocity = Velocity for which to check collisio
    Returns:
      Result of the collision in respects to this colliding onto the AABB
  */
  Collision_Info Collision(AABBEntity aabb, Vector velocity) {
    return Collision_Info();
  }

};

/** NOT FUNCTIONAL!!!!!!!!
  An entity that supports Axis-Aligned-Bounding-Box collision (a rectangle with
  no rotation). If rotation is required, use a PolyEntity instead, however this
  does support collision with PolyEntity. (You will effectively save no memory
  at the moment from using this, but you will save computation when doing
  AABB-AABB collisions)
*/
class AABBEntity : PolyEntity {
public:
  /**
    Params:
      _layer =
      size   = Size of the bounding-box
  */
  this(ubyte _layer = 0, Vector size = Vector(0, 0)) {
    super(_layer);
    type = Type.AABB;
    Set_Vertices([Vector(-size.x/2.0, -size.y/2.0),
                  Vector(-size.x/2.0,  size.y/2.0),
                  Vector( size.x/2.0,  size.y/2.0),
                  Vector( size.x/2.0, -size.y/2.0)]);
  }
  /**
    Params:
     _layer =
      size  = Size of the bounding-box
      pos   = Position of the entity
  */
  this(ubyte _layer, Vector size = Vector( 0,0 ), Vector pos = Vector( 0,0 )) {
    this(_layer, size);
    position = pos;
  }

  // ---- utility ----

  /** Check collision with another AABBEntity
    Params:
      aabb     = Another AABBEntity
      velocity = Velocity for which to check collision
    Returns:
      Result of the collision in respects to this colliding onto the AABB
  */
  Collision_Info Collide(AABBEntity aabb, Vector velocity) {
    auto pos  = position + velocity,
         opos = aabb.R_Position(),
         siz  = R_Size(),
         osiz = aabb.R_Size();
    Collision_Info ci;
    ci.will_collide = !( pos.x + siz.x < opos.x          &&
                         pos.x         > opos.x + osiz.x &&
                         pos.y + siz.y < opos.y          &&
                         pos.y         > opos.y + osiz.y );
    return ci;
  }
  /** Check collision with another PolyEntity
    Params:
      poly     = Another PolyEntity
      velocity = Velocity for which to check collision
    Returns:
      Result of the collision in respects to this colliding onto the poly
  */
  Collision_Info Collide(PolyEntity poly, Vector velocity) {
    return Collision_Info();
  }
};

// Valuable information from a collision, "translation"
// could mean different things dependent on the collision type
/**
  Gives information about a collision.
*/
struct Collision_Info {
public:
  /** Determines if there is currently a collision */
  bool collision;
  /** Determines if there will be a collision if the velocity were added
       to the position */
  bool will_collide;
  /** Gives the amount of translation required to no longer be colliding */
  Vector translation;
  /** The axis/projection of the collision */
  Vector projection;
  /** */
  Vector normal;
  /** The object that was collided with */
  PolyEntity obj;
  /**
    basic form of Collision_Info
    Params:
      c = If there was a collision
  */
  this(bool c) {
    collision = c;
    will_collide = 0;
  }
  /**
    Params:
      t  = Translation of the collision
      c  = If there was a collision
      wc = If there will be a collision
  */
  this(ref Vector t, bool c, bool wc) {
    collision = c;
    will_collide = wc;
    translation = t;
  }
};

// -------------------- collision code -----------------------------------------

private Vector Get_Axis(Vector[] vertices, int i) {
  auto vec1 = vertices[i], vec2 = vertices[(i+1)%vertices.length];
  Vector axis  = Vector( -(vec2.y - vec1.y), vec2.x - vec1.x );
  axis.Normalize();
  return axis;
}

private void Project_Poly(ref Vector axis, Vector[] poly,
                          ref float min, ref float max) {
  min = axis.Dot_Product(poly[0]);
  max = min;

  foreach ( i ; 1 .. poly.length ) {
    float t = poly[i].Dot_Product ( axis );
    if ( t < min ) min = t;
    if ( t > max ) max = t;
  }
}

private float Project_Dist(float minA, float maxA, float minB, float maxB) {
  return
      minA < minB ? (minB - maxA)
                  : (minA - maxB);
}

private Collision_Info PolyPolyColl(PolyEntity polyA, PolyEntity polyB,
                                    Vector velocity) {
  // -- variable definitions --
  // the minimum distance needed to translate out of collision
  float min_dist = float.max;
  Vector trans_vec;

  Vector[] vertsA = polyA.R_Transformed_Vertices(),
           vertsB = polyB.R_Transformed_Vertices();

  Collision_Info ci = Collision_Info();
  ci.will_collide = true;
  // -- loop/coll detection --
  // loop through all vertices.
  for ( int i = 0; i != vertsA.length + vertsB.length; ++ i ) {
    bool vA = (i<vertsA.length);
    // get the axis from the edge (we have to build the edge from vertices tho)
    auto axis = Get_Axis((vA?vertsA:vertsB), cast(int)(vA?i: i - vertsA.length));
    // project polygons onto axis
    float minA, minB, maxA, maxB;
    Project_Poly(axis, vertsA, minA, maxA);
    Project_Poly(axis, vertsB, minB, maxB);

    // check for a gap between the two distances
    if ( Project_Dist(minA, maxA, minB, maxB) > 0 ) {
      ci.collision = false;
    }

    // get velocity's projection
    float velP = axis.Dot_Product ( velocity );
    if ( velP < 0 ) minA += velP;
    else            maxA += velP;

    float dist = Project_Dist(minA, maxA, minB, maxB);
    if ( dist > 0 ) ci.will_collide = false;

    if ( !ci.will_collide && !ci.will_collide) break;

    // check if this is minimum translation
    dist = dist > 0 ? dist : -dist;
    if ( dist < min_dist ) {
      min_dist = dist;
      trans_vec = axis;
      ci.projection = axis;
      auto d = polyA.R_Position() - polyB.R_Position();
      if ( d.Dot_Product( trans_vec ) < 0 )
        trans_vec *= -1;
    }
  }

  // -- collision occurred, (hoor|na)ay --
  if ( ci.will_collide )
    ci.translation = trans_vec * min_dist;
  return ci;
}

struct Vert_Pair {
  float dist;
  Vector vert;
  this(float dist_, Vector vert_) {
    dist = dist_;
    vert = vert_;
  }
};

static void Order_Vertices(ref Vector[] verts) {
  // get centroid, same time preparing to calculate angle of verts
  float centx = 0, centy = 0;
  Vert_Pair[] va;
  foreach ( i; verts ) {
    centx += i.x;
    centy += i.y;
    va ~= Vert_Pair(0, i);
  }
  centx /= verts.length;
  centy /= verts.length;
  verts = [];

  foreach ( i; va ) {
    import std.math;
    i.dist = atan2(i.vert.y - centy, i.vert.x - centx);
  }

  import std.algorithm;
  sort!((x, y) => x.dist < y.dist)(va);
  // put back in vector
  foreach ( i; va )
    verts ~= i.vert;
}

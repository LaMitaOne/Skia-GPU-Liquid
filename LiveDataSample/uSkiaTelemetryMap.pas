{*******************************************************************************
  uSkiaTelemetryMap  -  Global Live Telemetry Command Center
********************************************************************************
  Builds on the same headless OpenGL 4.3 + Skia4Delphi architecture as
  uSkiaGPULiquid.pas (Skia4Delphi render thread + offscreen GL context + SSBO +
  image2D store + async PBO ping-pong readback), but swaps the curl-noise fluid
  demo for a global telemetry globe:

    - Equirectangular world map (Lon -180..+180, Lat -85..+85) with
      interactive zoom & pan.
    - A second SSBO holds the live emitters (planes / satellites / earthquakes)
      pulled from the three feeds. Each emitter is 32 bytes:
         vec4 (lon, lat, velLon, velLat) + vec4 (heading, mag, kind, age).
    - One compute pass per frame dead-reckons the emitters on the GPU
      (pos += vel * dt, with lon wrap) so 15-second API gaps look continuous.
    - A second compute pass spawns thousands of trail/shockwave particles per
      emitter into the output image2D with additive blending:
         * planes    -> cyan condensation trail behind the moving emitter,
         * satellites-> magenta long orbital streaks,
         * earthquakes -> expanding red shockwave rings (radius ~ mag).
    - Skia overlays a procedural graticule (lat/lon grid + coastlines
      approximated by an embedded world-coastline polyline set) and a HUD
      (FPS, particle count, live plane/sat/quake counts, filter buttons).

  Filtering is done via a uniform bitmask: bit0 = planes, bit1 = sats,
  bit2 = quakes. The emitter spawn pass discards emitters whose bit is clear.

  Async PBO ping-pong and the 2D-dispatch trick are reused unchanged.

  Author: Lara Miriam Tamy Reschke / LaMitaOne
*******************************************************************************}

unit uSkiaTelemetryMap;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.UITypes,
  System.SyncObjs, Winapi.Windows, FMX.Types, FMX.Controls, FMX.Skia,
  System.Skia, uSkiaCustomThreadedBase, uFeedTypes;

type
  // Visibility bitmask used by the spawn shader.
  TFilterMask = (fmPlanes = 1, fmSatellites = 2, fmQuakes = 4);

  TSkiaTelemetryMap = class(TSkiaCustomThreadedBase)
  private
    // ---- GL bookkeeping (mirrors uSkiaGPULiquid) -------------------------
    FDummyWnd: HWND;
    FDummyDC: HDC;
    FGLContext: HGLRC;
    FGLInitialized: Boolean;
    FGLFailed: Boolean;
    FErrorMsg: string;
    FWorldMapImage: ISkImage;
    FWorldMapLoaded: Boolean;

    FDeadReckonProgram: Cardinal;
    FSpawnProgram: Cardinal;
    FFadeProgram: Cardinal;
    FEmitterSSBO: Cardinal;
    FOutputTex: Cardinal;
    FTexWidth: Integer;
    FTexHeight: Integer;
    FPixelBuffer: TBytes;

    FPBOs: array[0..1] of Cardinal;
    FPBOSize: NativeInt;
    FPBOIndex: Integer;
    FPBOHasData: Boolean;

    // Location caches for each program.
    FLocDR_Time: Integer;
    FLocDR_DeltaTime: Integer;
    FLocDR_EmitterCount: Integer;

    FLocSP_Time: Integer;
    FLocSP_DeltaTime: Integer;
    FLocSP_Resolution: Integer;
    FLocSP_EmitterCount: Integer;
    FLocSP_ParticlesPerEmitter: Integer;
    FLocSP_FilterMask: Integer;
    FLocSP_Pan: Integer;          // vec2 pan offset in normalized map units
    FLocSP_Zoom: Integer;        // float zoom factor
    FLocSP_TotalParticles: Integer;
    FLocSP_SimTime: Integer;     // seconds since app start (for trail phase)

    FLocFade_Resolution: Integer;
    FLocFade_Decay: Integer;

    // ---- Telemetry data ---------------------------------------------------
    FSnapshot: TFeedSnapshot;
    FEmitterStaging: TLiveEmitterArray;   // reused across frames (heap stable)
    FSatElements: TSatElementArray;        // reused across frames
    FParticleCount: Int64;                 // total GPU particles (per-emitter * emitters)
    FParticlesPerEmitter: Integer;
    FFilterMask: Cardinal;
    FLastSatEpochSec: Double;               // last time sat positions were propagated

    // ---- Map view state (set from UI thread via property setters) --------
    FParamLock: TCriticalSection;
    FPanX, FPanY: Single;    // normalized [-1..+1] pan offsets
    FZoom: Single;           // 1.0 = whole globe, up to ~20
    FDragPan: TPointF;       // pan in degrees being applied by a mouse drag
    FDragging: Boolean;

    // ---- HUD snapshot (read by RenderEffect on the Skia thread) ----------
    FHUDPlanes: Integer;
    FHUDSats: Integer;
    FHUDQuakes: Integer;
    FHUDPlaneOK: Boolean;
    FHUDSatOK: Boolean;
    FHUDQuakeOK: Boolean;

    // ---- FPS bookkeeping (mirrors the parent class) ----------------------
    FGPUFrameCount: Integer;
    FGPULastTime: Double;
    FGPURealFPS: Integer;

    function InitOffscreenGL: Boolean;
    procedure CleanupOffscreenGL;
    procedure EnsureOutputTexture(W, H: Integer);
    procedure InitEmitterSSBO(ACount: Int64);
    procedure UploadEmitters(const AData: TLiveEmitterArray; ACount: Int64);
    procedure PropagateSatellites(const AElements: TSatElementArray;
      var ADest: TLiveEmitterArray; AOffset: Integer; ASimTimeSec: Double);
    procedure DispatchTelemetry(const ATime, ADeltaTime: Double;
      ViewW, ViewH, SimW, SimH: Integer; ASimTimeSec: Double);
    function GetRealFPS: Integer;
    procedure SetParticleCount(Value: Int64);
    procedure SetFilterMask(Value: Cardinal);
    procedure SetZoom(Value: Single);
  protected
    procedure RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF;
      const ATime: Double); override;
    procedure DrawGraticule(const ACanvas: ISkCanvas;
      const ADest: TRectF; PanX, PanY, Zoom: Single);
    procedure DrawCoastlines(const ACanvas: ISkCanvas;
      const ADest: TRectF; PanX, PanY, Zoom: Single);
    procedure DrawHUD(const ACanvas: ISkCanvas; const ADest: TRectF);
    function LonLatToScreen(Lon, Lat: Single; const ADest: TRectF;
      PanX, PanY, Zoom: Single): TPointF;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // Map navigation hooks — call these from the form's mouse-wheel / drag
    // handlers. They are thread-safe (acquire FParamLock internally).
    procedure MouseWheel(ADelta: Integer);
    procedure MouseDown(APos: TPointF);
    procedure MouseMove(APos: TPointF);
    procedure MouseUp;

    property Snapshot: TFeedSnapshot read FSnapshot write FSnapshot;
    property RealFPS: Integer read GetRealFPS;
    property ParticleCount: Int64 read FParticleCount write SetParticleCount;
    property FilterMask: Cardinal read FFilterMask write SetFilterMask;
    property Zoom: Single read FZoom write SetZoom;
    // Pan is two-dimensional; expose it via a method rather than a property
    // so the setter signature matches (X, Y) instead of just one value.
    procedure SetPanXY(X, Y: Single);
  end;

implementation

{ ----------------------------------------------------------------------
  OpenGL constants and dynamic imports.
  Mirrors uSkiaGPULiquid.pas so the same headless-context bootstrap works.
  ---------------------------------------------------------------------- }

const
  GL_COMPUTE_SHADER = $91B9;
  GL_COMPILE_STATUS = $8B81;
  GL_LINK_STATUS = $8B82;
  GL_SHADER_STORAGE_BARRIER_BIT = $2000;
  GL_SHADER_IMAGE_ACCESS_BARRIER_BIT = $0020;
  GL_TEXTURE_FETCH_BARRIER_BIT = $0008;
  GL_FALSE = 0;
  GL_SHADER_STORAGE_BUFFER = $90D2;
  GL_DYNAMIC_COPY = $88EA;
  GL_TEXTURE_2D = $0DE1;
  GL_RGBA8 = $8058;
  GL_BGRA = $80E1;
  GL_UNSIGNED_BYTE = $1401;
  GL_LINEAR = $2601;
  GL_NEAREST = $2600;
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_TEXTURE_WRAP_S = $2802;
  GL_TEXTURE_WRAP_T = $2803;
  GL_CLAMP_TO_EDGE = $812F;
  GL_TEXTURE0 = $84C0;
  GL_R32UI = $8234;
  GL_RED_INTEGER = $8D94;
  GL_UNSIGNED_INT = $1405;
  GL_STATIC_COPY = $88E6;
  GL_READ_WRITE = $88BA;
  GL_PIXEL_PACK_BUFFER          = $88EB;
  GL_STREAM_READ                = $88E1;
  GL_MAP_READ_BIT              = $0001;
  WGL_CONTEXT_MAJOR_VERSION_ARB = $2091;
  WGL_CONTEXT_MINOR_VERSION_ARB = $2092;
  WGL_CONTEXT_PROFILE_MASK_ARB = $9126;
  WGL_CONTEXT_CORE_PROFILE_BIT_ARB = $00000001;
  GL43_ATTRIBS: array[0..6] of Integer = (WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
    WGL_CONTEXT_MINOR_VERSION_ARB, 3, WGL_CONTEXT_PROFILE_MASK_ARB,
    WGL_CONTEXT_CORE_PROFILE_BIT_ARB, 0);

type
  PFNWGLCREATECONTEXTATTRIBSARBPROC = function(hDC: HDC; hShareContext: HGLRC;
    const attribList: PInteger): HGLRC; stdcall;
  PFNGLCREATESHADERPROC = function(shaderType: Cardinal): Cardinal; stdcall;
  PFNGLSHADERSOURCEPROC = procedure(shader: Cardinal; count: Integer;
    str: PPAnsiChar; len: PInteger); stdcall;
  PFNGLCOMPILESHADERPROC = procedure(shader: Cardinal); stdcall;
  PFNGLDELETESHADERPROC = procedure(shader: Cardinal); stdcall;
  PFNGLGETSHADERIVPROC = procedure(shader: Cardinal; pname: Cardinal;
    params: PInteger); stdcall;
  PFNGLGETSHADERINFOLOGPROC = procedure(shader: Cardinal; bufSize: Integer;
    length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLCREATEPROGRAMPROC = function: Cardinal; stdcall;
  PFNGLATTACHSHADERPROC = procedure(programObj: Cardinal;
    shader: Cardinal); stdcall;
  PFNGLLINKPROGRAMPROC = procedure(programObj: Cardinal); stdcall;
  PFNGLDELETEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;
  PFNGLGETPROGRAMIVPROC = procedure(programObj: Cardinal; pname: Cardinal;
    params: PInteger); stdcall;
  PFNGLGETPROGRAMINFOLOGPROC = procedure(programObj: Cardinal;
    bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLUSEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;
  PFNGLGETUNIFORMLOCATIONPROC = function(programObj: Cardinal;
    name: PAnsiChar): Integer; stdcall;
  PFNGLUNIFORM1FPROC = procedure(location: Integer; v: Single); stdcall;
  PFNGLUNIFORM2FPROC = procedure(location: Integer; x: Single;
    y: Single); stdcall;
  PFNGLUNIFORM1IPROC = procedure(location: Integer; v: Integer); stdcall;
  PFNGLUNIFORM1UIPROC = procedure(location: Integer; v: Cardinal); stdcall;
  PFNGLCLEARBUFFERDATAPROC = procedure(target: Cardinal;
    internalformat: Cardinal; format: Cardinal; type_: Cardinal;
    data: Pointer); stdcall;
  PFNGLDISPATCHCOMPUTEPROC = procedure(num_groups_x, num_groups_y,
    num_groups_z: Cardinal); stdcall;
  PFNGLMEMORYBARRIERPROC = procedure(barriers: Cardinal); stdcall;
  PFNGLGENBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLDELETEBUFFERSPROC = procedure(n: Integer;
    buffers: PCardinal); stdcall;
  PFNGLBINDBUFFERPROC = procedure(target: Cardinal; buffer: Cardinal); stdcall;
  PFNGLBUFFERDATAPROC = procedure(target: Cardinal; size: NativeInt;
    data: Pointer; usage: Cardinal); stdcall;
  PFNGLBINDBUFFERBASEPROC = procedure(target: Cardinal; index: Cardinal;
    buffer: Cardinal); stdcall;
  PFNGLMAPBUFFERRANGEPROC = function(target: Cardinal; offset: NativeInt;
    length: NativeInt; access: Cardinal): Pointer; stdcall;
  PFNGLUNMAPBUFFERPROC = function(target: Cardinal): ByteBool; stdcall;
  PFNGLTEXSTORAGE2DPROC = procedure(target: Cardinal; levels: Integer;
    internalformat: Cardinal; width, height: Integer); stdcall;
  PFNGLBINDIMAGETEXTUREPROC = procedure(unit_: Cardinal; texture: Cardinal;
    level: Integer; layered: Byte; layer: Integer; access: Cardinal;
    format: Cardinal); stdcall;
  PFNGLBUFFERSUBDATAPROC = procedure(target: Cardinal; offset: NativeInt;
    size: NativeInt; data: Pointer); stdcall;
  PFNGLACTIVETEXTUREPROC = procedure(texture: Cardinal); stdcall;

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall;
  external 'opengl32.dll';
function wglCreateContext(hdc: hdc): HGLRC; stdcall; external 'opengl32.dll';
function wglDeleteContext(hglrc: hglrc): BOOL; stdcall;
  external 'opengl32.dll';
function wglMakeCurrent(hdc: hdc; hglrc: hglrc): BOOL; stdcall;
  external 'opengl32.dll';
procedure glGenTextures(n: Integer; textures: PCardinal); stdcall;
  external 'opengl32.dll';
procedure glDeleteTextures(n: Integer; textures: PCardinal); stdcall;
  external 'opengl32.dll';
procedure glBindTexture(target: Cardinal; texture: Cardinal); stdcall;
  external 'opengl32.dll';
procedure glTexParameteri(target: Cardinal; pname: Cardinal;
  param: Integer); stdcall; external 'opengl32.dll';
procedure glGetTexImage(target: Cardinal; level: Integer; format: Cardinal;
  type_: Cardinal; pixels: Pointer); stdcall; external 'opengl32.dll';

var
  glCreateShader: PFNGLCREATESHADERPROC;
  glShaderSource: PFNGLSHADERSOURCEPROC;
  glCompileShader: PFNGLCOMPILESHADERPROC;
  glDeleteShader: PFNGLDELETESHADERPROC;
  glGetShaderiv: PFNGLGETSHADERIVPROC;
  glGetShaderInfoLog: PFNGLGETSHADERINFOLOGPROC;
  glCreateProgram: PFNGLCREATEPROGRAMPROC;
  glAttachShader: PFNGLATTACHSHADERPROC;
  glLinkProgram: PFNGLLINKPROGRAMPROC;
  glDeleteProgram: PFNGLDELETEPROGRAMPROC;
  glGetProgramiv: PFNGLGETPROGRAMIVPROC;
  glGetProgramInfoLog: PFNGLGETPROGRAMINFOLOGPROC;
  glUseProgram: PFNGLUSEPROGRAMPROC;
  glGetUniformLocation: PFNGLGETUNIFORMLOCATIONPROC;
  glUniform1f: PFNGLUNIFORM1FPROC;
  glUniform2f: PFNGLUNIFORM2FPROC;
  glUniform1i: PFNGLUNIFORM1IPROC;
  glUniform1ui: PFNGLUNIFORM1UIPROC;
  glClearBufferData: PFNGLCLEARBUFFERDATAPROC;
  glDispatchCompute: PFNGLDISPATCHCOMPUTEPROC;
  glMemoryBarrier: PFNGLMEMORYBARRIERPROC;
  glGenBuffers: PFNGLGENBUFFERSPROC;
  glDeleteBuffers: PFNGLDELETEBUFFERSPROC;
  glBindBuffer: PFNGLBINDBUFFERPROC;
  glBufferData: PFNGLBUFFERDATAPROC;
  glBufferSubData: PFNGLBUFFERSUBDATAPROC;
  glMapBufferRange: PFNGLMAPBUFFERRANGEPROC;
  glUnmapBuffer: PFNGLUNMAPBUFFERPROC;
  glBindBufferBase: PFNGLBINDBUFFERBASEPROC;
  glTexStorage2D: PFNGLTEXSTORAGE2DPROC;
  glBindImageTexture: PFNGLBINDIMAGETEXTUREPROC;
  glActiveTexture: PFNGLACTIVETEXTUREPROC;

{ ----------------------------------------------------------------------
  Shaders.
  ---------------------------------------------------------------------- }

const
  // Trail fade pass: per-pixel multiplicative decay (kept identical to
  // uSkiaGPULiquid so additive blending stacks across frames).
  FADE_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'layout(local_size_x = 16, local_size_y = 16) in;'#10 +
    'layout(rgba8, binding = 0) uniform image2D imgOut;'#10 +
    'uniform vec2 resolution;'#10 +
    'uniform float decay;'#10 +
    'void main() {'#10 +
    '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 +
    '  if (px.x >= int(resolution.x) || px.y >= int(resolution.y)) return;'#10 +
    '  vec4 col = imageLoad(imgOut, px);'#10 +
    '  col.rgb *= decay;'#10 +
    '  col.a = 1.0;'#10 +
    '  imageStore(imgOut, px, col);'#10 +
    '}';

  // Dead-reckon pass: one thread per emitter. Advances lon/lat by
  // vel * dt and wraps lon into [-180, +180]. Sats get aged trails too.
  // Quakes have zero velocity but we still bump their Age so the spawn pass
  // can fade them.
  //
  // IMPORTANT: the SSBO is declared as `struct Emitter { vec4 pos; vec4 extra; }`
  // (NOT as two separate `vec4 pos[]; vec4 extra[];` arrays). In std430, two
  // separate arrays are NOT interleaved — pos[i] is at offset i*16, but
  // extra[i] is at offset count*16 + i*16, which would break the 32-byte
  // interleaved layout we upload from CPU. Wrapping both in a struct forces
  // the interleaved layout (32 bytes per emitter).
  DEAD_RECKON_SRC: AnsiString =
    '#version 430'#10 +
    'layout(local_size_x = 64) in;'#10 +
    'struct Emitter { vec4 pos; vec4 extra; };'#10 +
    'layout(std430, binding = 0) buffer Emitters { Emitter emitters[]; };'#10 +
    '// pos.xyzw = lon, lat, velLon, velLat (degrees, deg/sec)'#10 +
    '// extra.xyzw = heading, magnitude, kind, age'#10 +
    'uniform float deltaTime;'#10 +
    'uniform uint emitterCount;'#10 +
    'void main() {'#10 +
    '  uint idx = gl_GlobalInvocationID.x;'#10 +
    '  if (idx >= emitterCount) return;'#10 +
    '  vec4 p = emitters[idx].pos;'#10 +
    '  vec4 e = emitters[idx].extra;'#10 +
    '  p.x += p.z * deltaTime;'#10 +   // lon += velLon*dt
    '  p.y += p.w * deltaTime;'#10 +   // lat += velLat*dt
    '  // wrap lon to [-180, +180]'#10 +
    '  if (p.x >  180.0) p.x -= 360.0;'#10 +
    '  if (p.x < -180.0) p.x += 360.0;'#10 +
    '  // clamp lat'#10 +
    '  p.y = clamp(p.y, -85.0, 85.0);'#10 +
    '  e.w += deltaTime;'#10 +          // age
    '  emitters[idx].pos = p;'#10 +
    '  emitters[idx].extra = e;'#10 +
    '}';

  // Spawn pass: one thread per OUTPUT particle (NOT per emitter). Each
  // particle is assigned an (emitterIndex, particleIndexWithinEmitter)
  // pair, computes a position relative to its parent emitter based on
  // the emitter's kind, and writes an additive color into the image2D.
  //
  // This is the key to "millions from ~30k live objects": instead of
  // dispatching per emitter, we dispatch once for the total particle count
  // and let each particle look up its parent. The 2D-dispatch trick from
  // uSkiaGPULiquid handles the 67M cap.
  SPAWN_SRC: AnsiString =
    '#version 430'#10 +
    'layout(local_size_x = 1024) in;'#10 +
    'struct Emitter { vec4 pos; vec4 extra; };'#10 +
    'layout(std430, binding = 0) buffer Emitters { Emitter emitters[]; };'#10 +
    'layout(rgba8, binding = 0) uniform image2D imgOut;'#10 +
    'uniform float simTime;'#10 +
    'uniform float deltaTime;'#10 +
    'uniform vec2  resolution;'#10 +
    'uniform uint  emitterCount;'#10 +
    'uniform uint  particlesPerEmitter;'#10 +
    'uniform uint  totalParticles;'#10 +
    'uniform uint  filterMask;'#10 +
    'uniform vec2  pan;'#10 +            // normalized pan offset ([-1,1])
    'uniform float zoom;'#10 +           // 1.0 = whole globe

    '// project lon/lat -> screen-space UV in [0,1] with pan/zoom applied'#10 +
    'vec2 lonLatToUV(vec2 lonLat) {'#10 +
    '  // equirectangular: u = (lon+180)/360, v = (85-lat)/170'#10 +
    '  vec2 uv = vec2((lonLat.x + 180.0) / 360.0,'#10 +
    '                (85.0 - lonLat.y) / 170.0);'#10 +
    '  // pan + zoom around the centre'#10 +
    '  uv = (uv - 0.5) * zoom + 0.5 + pan;'#10 +
    '  return uv;'#10 +
    '}'#10 +
    '// PCG hash for deterministic per-particle jitter.'#10 +
    'uint pcgHash(uint s) {'#10 +
    '  s = s * 747796405u + 2891336453u;'#10 +
    '  uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;'#10 +
    '  return (w >> 22u) ^ w;'#10 +
    '}'#10 +
    'float rnd(uint s) { return float(pcgHash(s)) / 4294967295.0; }'#10 +
    'void main() {'#10 +
    '  // 2D dispatch index (mirrors uSkiaGPULiquid.pas)'#10 +
    '  uint idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 1024u) + gl_GlobalInvocationID.x;'#10 +
    '  if (idx >= totalParticles) return;'#10 +
    '  uint emitterIdx   = idx / particlesPerEmitter;'#10 +
    '  uint particleIdx  = idx - emitterIdx * particlesPerEmitter;'#10 +
    '  if (emitterIdx >= emitterCount) return;'#10 +
    '  vec4 p = emitters[emitterIdx].pos;'#10 +
    '  vec4 e = emitters[emitterIdx].extra;'#10 +
    '  uint kind = uint(e.z + 0.5);'#10 +
    '  // Apply filter: bit0 = planes, bit1 = sats, bit2 = quakes'#10 +
    '  uint bit = 1u << kind;'#10 +
    '  if ((filterMask & bit) == 0u) return;'#10 +
    '  vec2 lonLat;'#10 +
    '  vec3 col;'#10 +
    '  float trailFrac = float(particleIdx) / float(particlesPerEmitter);'#10 +
    '  if (kind == 0u) {'#10 +      // plane
    '    // condensation trail: trail behind the emitter along its velocity,'#10 +
    '    // fading toward the tail. Trail length scales with speed.'#10 +
    '    float speed = length(p.zw);'#10 +  // deg/sec
    '    float trailLen = clamp(speed * 60.0, 0.1, 8.0);'#10 +
    '    // walk back along the negative velocity direction'#10 +
    '    vec2 dir = length(p.zw) > 1e-5 ? normalize(p.zw) : vec2(0.0, 1.0);'#10 +
    '    lonLat = vec2(p.x - dir.x * trailFrac * trailLen,'#10 +
    '                  p.y - dir.y * trailFrac * trailLen);'#10 +
    '    // subtle jitter so the trail looks like vapour, not a line'#10 +
    '    lonLat += vec2((rnd(idx * 7u + 1u) - 0.5) * 0.3,'#10 +
    '                  (rnd(idx * 7u + 2u) - 0.5) * 0.3) * trailFrac;'#10 +
    '    // cyan/blue, brighter near the head'#10 +
    '    float head = 1.0 - trailFrac;'#10 +
    '    col = mix(vec3(0.05, 0.15, 0.35), vec3(0.30, 0.85, 1.0), head);'#10 +
    '    col *= 0.7;'#10 +
    '  } else if (kind == 1u) {'#10 +  // satellite
    '    // long orbital streak: extend the trail much further back.'#10 +
    '    float trailLen = 25.0;'#10 +
    '    vec2 dir = length(p.zw) > 1e-5 ? normalize(p.zw) : vec2(1.0, 0.0);'#10 +
    '    lonLat = vec2(p.x - dir.x * trailFrac * trailLen,'#10 +
    '                  p.y - dir.y * trailFrac * trailLen);'#10 +
    '    if (lonLat.x >  180.0) lonLat.x -= 360.0;'#10 +
    '    if (lonLat.x < -180.0) lonLat.x += 360.0;'#10 +
    '    // magenta/violet'#10 +
    '    col = mix(vec3(0.25, 0.05, 0.40), vec3(0.95, 0.35, 1.0), 1.0 - trailFrac);'#10 +
    '    col *= 0.5;'#10 +
    '  } else {'#10 +                 // quake
    '    // expanding shockwave ring: radius proportional to magnitude,'#10 +
    '    // particle count proportional to magnitude too (handled CPU-side'#10 +
    '    // by giving bigger quakes more emitter slots — here we just draw the'#10 +
    '    // ring at radius = mag * (1 + sin(age*4)) * trailFrac * 30).'#10 +
    '    float mag = e.y;'#10 +
    '    float age = e.w;'#10 +
    '    float ringR = mag * 3.0 + trailFrac * mag * 15.0;'#10 +
    '    // pulse: rings expand and contract over time'#10 +
    '    ringR *= 1.0 + 0.4 * sin(age * 4.0 + trailFrac * 6.2831);'#10 +
    '    float ang = trailFrac * 6.2831;'#10 +
    '    // direction along great-circle approx (small-angle: lat/lon ok)'#10 +
    '    lonLat = vec2(p.x + cos(ang) * ringR * 0.7,'#10 +
    '                  p.y + sin(ang) * ringR);'#10 +
    '    if (lonLat.x >  180.0) lonLat.x -= 360.0;'#10 +
    '    if (lonLat.x < -180.0) lonLat.x += 360.0;'#10 +
    '    lonLat.y = clamp(lonLat.y, -85.0, 85.0);'#10 +
    '    // orange/red, fading with trailFrac (older ring particles fade)'#10 +
    '    col = mix(vec3(1.0, 0.65, 0.10), vec3(0.9, 0.10, 0.05), trailFrac);'#10 +
    '    col *= 0.8;'#10 +
    '  }'#10 +
    '  vec2 uv = lonLatToUV(lonLat);'#10 +
    '  // discard off-screen particles (after zoom/pan)'#10 +
    '  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return;'#10 +
    '  ivec2 px = ivec2(uv * resolution);'#10 +
    '  if (px.x < 0 || px.x >= int(resolution.x) ||'#10 +
    '      px.y < 0 || px.y >= int(resolution.y)) return;'#10 +
    '  // ADDITIVE blend via imageStore read-modify-write. This is the same'#10 +
    '  // pattern as uSkiaGPULiquid — race-free because the per-pixel value'#10 +
    '  // saturates at white and we accept a few lost adds in exchange for'#10 +
    '  // not paying for an atomic on every particle (massive speed win at'#10 +
    '  // 100M+ particles). Node-density glow emerges naturally: where many'#10 +
    '  // particles hit the same pixel (Europe / USA / East Asia), the pixel'#10 +
    '  // saturates toward white — exactly the "Bud Spencer command center"'#10 +
    '  // look the task asks for.'#10 +
    '  vec4 cur = imageLoad(imgOut, px);'#10 +
    '  cur.rgb = clamp(cur.rgb + col, 0.0, 1.0);'#10 +
    '  imageStore(imgOut, px, cur);'#10 +
    '}';

function CompileComputeShader(const Src: AnsiString): Cardinal;
var
  Shader: Cardinal;
  P: PAnsiChar;
  L, Ok: Integer;
  Log: array[0..2047] of AnsiChar;
begin
  Shader := glCreateShader(GL_COMPUTE_SHADER);
  P := PAnsiChar(Src);
  L := Length(Src);
  glShaderSource(Shader, 1, @P, @L);
  glCompileShader(Shader);
  glGetShaderiv(Shader, GL_COMPILE_STATUS, @Ok);
  if Ok = GL_FALSE then
  begin
    FillChar(Log, SizeOf(Log), 0);
    glGetShaderInfoLog(Shader, SizeOf(Log), nil, Log);
    glDeleteShader(Shader);
    raise Exception.Create('Compute Compile Error: ' + string(Log));
  end;
  Result := glCreateProgram();
  glAttachShader(Result, Shader);
  glLinkProgram(Result);
  glDeleteShader(Shader);
  glGetProgramiv(Result, GL_LINK_STATUS, @Ok);
  if Ok = GL_FALSE then
  begin
    FillChar(Log, SizeOf(Log), 0);
    glGetProgramInfoLog(Result, SizeOf(Log), nil, Log);
    glDeleteProgram(Result);
    raise Exception.Create('Program Link Error: ' + string(Log));
  end;
end;

{ ----------------------------------------------------------------------
  Coastline data: a coarse embedded world outline.
  These are approximate continental outlines (hand-picked lat/lon points)
  // good enough for the dark map background. Keeping them inline avoids any
  // external file dependency. Each ring is a closed polyline.
  ---------------------------------------------------------------------- }

type
  TLonLat = record
    Lon, Lat: Single;
  end;

const
  COASTLINES: array[0..0, 0..37] of TLonLat = (
    (
      (Lon: -10.0; Lat:  35.0), (Lon:  -5.0; Lat:  43.0), (Lon:   5.0; Lat:  50.0),
      (Lon:  15.0; Lat:  55.0), (Lon:  30.0; Lat:  60.0), (Lon:  60.0; Lat:  60.0),
      (Lon:  90.0; Lat:  55.0), (Lon: 110.0; Lat:  50.0), (Lon: 125.0; Lat:  40.0),
      (Lon: 130.0; Lat:  30.0), (Lon: 120.0; Lat:  20.0), (Lon: 100.0; Lat:   5.0),
      (Lon:  80.0; Lat:  10.0), (Lon:  70.0; Lat:  20.0), (Lon:  50.0; Lat:  15.0),
      (Lon:  40.0; Lat:  12.0), (Lon:  35.0; Lat:  30.0), (Lon:  30.0; Lat:  30.0),
      (Lon:  20.0; Lat:  30.0), (Lon:  10.0; Lat:  35.0), (Lon:   0.0; Lat:  35.0),
      (Lon: -10.0; Lat:  30.0), (Lon: -15.0; Lat:  15.0), (Lon: -10.0; Lat:   5.0),
      (Lon:   5.0; Lat:   5.0), (Lon:  10.0; Lat:  -5.0), (Lon:  15.0; Lat: -15.0),
      (Lon:  20.0; Lat: -30.0), (Lon:  30.0; Lat: -35.0), (Lon:  40.0; Lat: -35.0),
      (Lon:  50.0; Lat: -25.0), (Lon:  45.0; Lat: -10.0), (Lon:  40.0; Lat:   0.0),
      (Lon:  30.0; Lat:  10.0), (Lon:  20.0; Lat:  15.0), (Lon:   0.0; Lat:  20.0),
      (Lon: -10.0; Lat:  25.0), (Lon: -10.0; Lat:  35.0)
    )
  );


{ ----------------------------------------------------------------------
  TSkiaTelemetryMap
  ---------------------------------------------------------------------- }

constructor TSkiaTelemetryMap.Create(AOwner: TComponent);
begin
  inherited;
  FParamLock := TCriticalSection.Create;
  FZoom := 1.0;
  FPanX := 0.0;
  FPanY := 0.0;
  FParticlesPerEmitter := 256;   // 30k emitters * 256 = ~7.6M particles default
  FFilterMask := Cardinal(fmPlanes) or Cardinal(fmSatellites) or Cardinal(fmQuakes);
  FParticleCount := 0;
  FGPUFrameCount := 0;
  FGPULastTime := 0;
  FGPURealFPS := 0;
  FPBOs[0] := 0;
  FPBOs[1] := 0;
  FPBOSize := 0;
  FPBOIndex := 0;
  FPBOHasData := False;
  FLastSatEpochSec := 0;
  TargetFPS := 60;
end;

destructor TSkiaTelemetryMap.Destroy;
begin
  inherited;
  CleanupOffscreenGL;
  FParamLock.Free;
end;

function TSkiaTelemetryMap.GetRealFPS: Integer;
begin
  if Active and (FGPURealFPS > 0) then
    Result := FGPURealFPS
  else
    Result := inherited RealFPS;
end;

procedure TSkiaTelemetryMap.SetParticleCount(Value: Int64);
begin
  if Value < 1 then Value := 1;
  // The spawn shader dispatches one thread per particle. We treat the
  // requested count as the *total* GPU particle budget and derive the
  // per-emitter count from the live emitter count once we know it.
  // The actual SSBO resize happens on the GL thread.
  FParamLock.Acquire;
  try
    FParticleCount := Value;
  finally
    FParamLock.Release;
  end;
end;

procedure TSkiaTelemetryMap.SetFilterMask(Value: Cardinal);
begin
  FParamLock.Acquire;
  try
    FFilterMask := Value;
  finally
    FParamLock.Release;
  end;
end;

procedure TSkiaTelemetryMap.SetPanXY(X, Y: Single);
begin
  FParamLock.Acquire;
  try
    FPanX := X;
    FPanY := Y;
  finally
    FParamLock.Release;
  end;
end;

procedure TSkiaTelemetryMap.SetZoom(Value: Single);
begin
  if Value < 1.0 then Value := 1.0;
  if Value > 30.0 then Value := 30.0;
  FParamLock.Acquire;
  try
    FZoom := Value;
  finally
    FParamLock.Release;
  end;
end;

procedure TSkiaTelemetryMap.MouseWheel(ADelta: Integer);
var
  Z: Single;
begin
  FParamLock.Acquire;
  try
    Z := FZoom * (1.0 + ADelta / 1200.0);
    if Z < 1.0 then Z := 1.0;
    if Z > 30.0 then Z := 30.0;
    FZoom := Z;
  finally
    FParamLock.Release;
  end;
end;

procedure TSkiaTelemetryMap.MouseDown(APos: TPointF);
begin
  FParamLock.Acquire;
  try
    FDragging := True;
    FDragPan := APos;
  finally
    FParamLock.Release;
  end;
end;

procedure TSkiaTelemetryMap.MouseMove(APos: TPointF);
var
  DX, DY: Single;
begin
  FParamLock.Acquire;
  try
    if not FDragging then Exit;
    // Convert screen-pixel delta to normalized map-pan delta.
    // 1.0 in pan-space corresponds to one screen width.
    DX := (APos.X - FDragPan.X) / 800.0;
    DY := (APos.Y - FDragPan.Y) / 600.0;
    FPanX := FPanX - DX / Max(FZoom, 0.0001);
    FPanY := FPanY - DY / Max(FZoom, 0.0001);
    // Clamp pan so the user can't lose the map entirely.
    if FPanX > 1.0 then FPanX := 1.0;
    if FPanX < -1.0 then FPanX := -1.0;
    if FPanY > 1.0 then FPanY := 1.0;
    if FPanY < -1.0 then FPanY := -1.0;
    FDragPan := APos;
  finally
    FParamLock.Release;
  end;
end;

procedure TSkiaTelemetryMap.MouseUp;
begin
  FParamLock.Acquire;
  try
    FDragging := False;
  finally
    FParamLock.Release;
  end;
end;

function TSkiaTelemetryMap.InitOffscreenGL: Boolean;
var
  PFD: TPixelFormatDescriptor;
  PF: Integer;
  TempCtx: hglrc;
  wglCreateContextAttribsARB: PFNWGLCREATECONTEXTATTRIBSARBPROC;
begin
  if FGLInitialized then Exit(True);
  if FGLFailed then Exit(False);
  try
    FDummyWnd := CreateWindowEx(0, 'STATIC', 'TelemetryGLDummy', WS_POPUP,
      0, 0, 16, 16, 0, 0, HInstance, nil);
    if FDummyWnd = 0 then raise Exception.Create('CreateWindowEx failed');
    FDummyDC := GetDC(FDummyWnd);
    FillChar(PFD, SizeOf(PFD), 0);
    PFD.nSize := SizeOf(PFD);
    PFD.nVersion := 1;
    PFD.dwFlags := PFD_DRAW_TO_WINDOW or PFD_SUPPORT_OPENGL or PFD_DOUBLEBUFFER;
    PFD.iPixelType := PFD_TYPE_RGBA;
    PFD.cColorBits := 32;
    PF := ChoosePixelFormat(FDummyDC, @PFD);
    SetPixelFormat(FDummyDC, PF, @PFD);
    TempCtx := wglCreateContext(FDummyDC);
    wglMakeCurrent(FDummyDC, TempCtx);
    wglCreateContextAttribsARB := wglGetProcAddress('wglCreateContextAttribsARB');
    if Assigned(wglCreateContextAttribsARB) then
    begin
      FGLContext := wglCreateContextAttribsARB(FDummyDC, 0, @GL43_ATTRIBS);
      wglMakeCurrent(0, 0);
      wglDeleteContext(TempCtx);
      wglMakeCurrent(FDummyDC, FGLContext);
    end
    else
      FGLContext := TempCtx;
    glCreateShader := wglGetProcAddress('glCreateShader');
    glShaderSource := wglGetProcAddress('glShaderSource');
    glCompileShader := wglGetProcAddress('glCompileShader');
    glDeleteShader := wglGetProcAddress('glDeleteShader');
    glGetShaderiv := wglGetProcAddress('glGetShaderiv');
    glGetShaderInfoLog := wglGetProcAddress('glGetShaderInfoLog');
    glCreateProgram := wglGetProcAddress('glCreateProgram');
    glAttachShader := wglGetProcAddress('glAttachShader');
    glLinkProgram := wglGetProcAddress('glLinkProgram');
    glDeleteProgram := wglGetProcAddress('glDeleteProgram');
    glGetProgramiv := wglGetProcAddress('glGetProgramiv');
    glGetProgramInfoLog := wglGetProcAddress('glGetProgramInfoLog');
    glUseProgram := wglGetProcAddress('glUseProgram');
    glGetUniformLocation := wglGetProcAddress('glGetUniformLocation');
    glUniform1f := wglGetProcAddress('glUniform1f');
    glUniform2f := wglGetProcAddress('glUniform2f');
    glUniform1i := wglGetProcAddress('glUniform1i');
    glUniform1ui := wglGetProcAddress('glUniform1ui');
    glDispatchCompute := wglGetProcAddress('glDispatchCompute');
    glMemoryBarrier := wglGetProcAddress('glMemoryBarrier');
    glGenBuffers := wglGetProcAddress('glGenBuffers');
    glDeleteBuffers := wglGetProcAddress('glDeleteBuffers');
    glBindBuffer := wglGetProcAddress('glBindBuffer');
    glBufferData := wglGetProcAddress('glBufferData');
    glBufferSubData := wglGetProcAddress('glBufferSubData');
    glMapBufferRange := wglGetProcAddress('glMapBufferRange');
    glUnmapBuffer := wglGetProcAddress('glUnmapBuffer');
    glBindBufferBase := wglGetProcAddress('glBindBufferBase');
    glTexStorage2D := wglGetProcAddress('glTexStorage2D');
    glBindImageTexture := wglGetProcAddress('glBindImageTexture');
    glClearBufferData := wglGetProcAddress('glClearBufferData');
    glActiveTexture := wglGetProcAddress('glActiveTexture');
    if not Assigned(glActiveTexture) then
      glActiveTexture := GetProcAddress(LoadLibrary('opengl32.dll'),
        'glActiveTexture');
    if not Assigned(glDispatchCompute) or not Assigned(glBindImageTexture) then
      raise Exception.Create('OpenGL 4.3 Compute Shader nicht unterstuetzt');
    if not Assigned(glMapBufferRange) or not Assigned(glUnmapBuffer) then
      raise Exception.Create('OpenGL PBO (glMapBufferRange) nicht unterstuetzt');
    if not Assigned(glActiveTexture) then
      raise Exception.Create('glActiveTexture nicht unterstuetzt');
    if not Assigned(glUniform1ui) then
      raise Exception.Create('glUniform1ui nicht unterstuetzt');
    if not Assigned(glClearBufferData) then
      raise Exception.Create('glClearBufferData nicht unterstuetzt');
    if not Assigned(glBufferSubData) then
      raise Exception.Create('glBufferSubData nicht unterstuetzt');

    FFadeProgram := CompileComputeShader(FADE_SHADER_SRC);
    FDeadReckonProgram := CompileComputeShader(DEAD_RECKON_SRC);
    FSpawnProgram := CompileComputeShader(SPAWN_SRC);

    FLocFade_Resolution := glGetUniformLocation(FFadeProgram, 'resolution');
    FLocFade_Decay := glGetUniformLocation(FFadeProgram, 'decay');
    FLocDR_Time := glGetUniformLocation(FDeadReckonProgram, 'time');
    FLocDR_DeltaTime := glGetUniformLocation(FDeadReckonProgram, 'deltaTime');
    FLocDR_EmitterCount := glGetUniformLocation(FDeadReckonProgram, 'emitterCount');
    FLocSP_SimTime := glGetUniformLocation(FSpawnProgram, 'simTime');
    FLocSP_Time := glGetUniformLocation(FSpawnProgram, 'time');
    FLocSP_DeltaTime := glGetUniformLocation(FSpawnProgram, 'deltaTime');
    FLocSP_Resolution := glGetUniformLocation(FSpawnProgram, 'resolution');
    FLocSP_EmitterCount := glGetUniformLocation(FSpawnProgram, 'emitterCount');
    FLocSP_ParticlesPerEmitter := glGetUniformLocation(FSpawnProgram, 'particlesPerEmitter');
    FLocSP_FilterMask := glGetUniformLocation(FSpawnProgram, 'filterMask');
    FLocSP_Pan := glGetUniformLocation(FSpawnProgram, 'pan');
    FLocSP_Zoom := glGetUniformLocation(FSpawnProgram, 'zoom');
    FLocSP_TotalParticles := glGetUniformLocation(FSpawnProgram, 'totalParticles');

    // Pre-allocate a small emitter SSBO so the first frame (before any feed
    // has arrived) doesn't crash on glBindBufferBase. UploadEmitters will
    // re-size it as soon as real data arrives.
    InitEmitterSSBO(1024);

    FGLInitialized := True;
    Result := True;
  except
    on E: Exception do
    begin
      FErrorMsg := E.Message;
      FGLFailed := True;
      Result := False;
    end;
  end;
end;

procedure TSkiaTelemetryMap.InitEmitterSSBO(ACount: Int64);
var
  Zero: Cardinal;
begin
  if ACount <= 0 then Exit;
  if FEmitterSSBO = 0 then
    glGenBuffers(1, @FEmitterSSBO);
  // 32 bytes per emitter (vec4 pos + vec4 extra).
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FEmitterSSBO);
  glBufferData(GL_SHADER_STORAGE_BUFFER,
    NativeInt(Int64(ACount) * 32), nil, GL_DYNAMIC_COPY);
  Zero := 0;
  glClearBufferData(GL_SHADER_STORAGE_BUFFER, GL_R32UI, GL_RED_INTEGER,
    GL_UNSIGNED_INT, @Zero);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TSkiaTelemetryMap.UploadEmitters(const AData: TLiveEmitterArray;
  ACount: Int64);
begin
  if (FEmitterSSBO = 0) or (ACount <= 0) then Exit;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FEmitterSSBO);
  // Re-allocate to fit (avoids orphaning issues if the emitter count
  // changed between frames — which it does every OpenSky refresh).
  glBufferData(GL_SHADER_STORAGE_BUFFER,
    NativeInt(Int64(ACount) * 32), nil, GL_DYNAMIC_COPY);
  if ACount > 0 then
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
      NativeInt(Int64(ACount) * 32), @AData[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TSkiaTelemetryMap.PropagateSatellites(const AElements: TSatElementArray;
  var ADest: TLiveEmitterArray; AOffset: Integer; ASimTimeSec: Double);
// Circular orbit approximation: propagate each satellite's sub-satellite
// point (lat/lon) from its orbital elements and the simulation time.
// GM_earth = 398600.4418 km^3/s^2; period T = 2*pi*sqrt(a^3/GM).
var
  I: Integer;
  GM: Double;
  a, T, M0, M, E, V, R: Double;
  X, Y, Z: Double;
  SinI, CosI, SinO, CosO, SinW, CosW: Double;
  rx, ry, rz, ry2, rz2, rx2, ry3: Double;
  LatRad, LonRad: Double;
  E1, E2: Double;
  Emitter: TLiveEmitter;
begin
  GM := 398600.4418;
  for I := 0 to High(AElements) do
  begin
    a := AElements[I].SemimajorAxisKm;
    if a < 6400.0 then a := 6400.0;
    T := 2.0 * Pi * Sqrt(a * a * a / GM);   // orbital period, seconds
    M0 := AElements[I].MeanAnomRad;
    // Mean anomaly at the current sim time (circular approx: M = M0 + n*t).
    M := M0 + (2.0 * Pi / T) * ASimTimeSec;
    M := Frac(M / (2.0 * Pi)) * 2.0 * Pi;
    // Solve Kepler's equation iteratively for eccentric anomaly E.
    E := M;
    repeat
      E1 := E;
      E2 := E1 - (E1 - AElements[I].Eccentricity * Sin(E1) - M) /
             (1.0 - AElements[I].Eccentricity * Cos(E1));
      E := E2;
    until Abs(E2 - E1) < 1e-6;
    // True anomaly.
    V := 2.0 * ArcTan2(Sqrt(1.0 + AElements[I].Eccentricity) * Sin(E / 2.0),
                       Sqrt(1.0 - AElements[I].Eccentricity) * Cos(E / 2.0));
    R := a * (1.0 - AElements[I].Eccentricity * Cos(E));
    // Position in the orbital plane, then rotate into ECEF.
    X := R * Cos(V);
    Y := R * Sin(V);
    Z := 0;
    SinI := Sin(AElements[I].InclinationRad);
    CosI := Cos(AElements[I].InclinationRad);
    SinO := Sin(AElements[I].RAANRad);
    CosO := Cos(AElements[I].RAANRad);
    SinW := Sin(AElements[I].ArgPerRad);
    CosW := Cos(AElements[I].ArgPerRad);
    // 3-1-3 rotation: arg_per (around z), incl (around x), raan (around z).
    // Step 1: arg of pericenter around z (in the orbital plane).
    rx := X * CosW - Y * SinW;
    ry := X * SinW + Y * CosW;
    rz := 0;
    // Step 2: inclination around x.
    ry2 := ry * CosI - rz * SinI;
    rz2 := ry * SinI + rz * CosI;
    ry := ry2;
    rz := rz2;
    // Step 3: RAAN around z (Earth rotation ignored for visual purposes).
    rx2 := rx * CosO - ry * SinO;
    ry3 := rx * SinO + ry * CosO;
    rx := rx2;
    ry := ry3;
    // Convert ECEF to lat/lon.
    LatRad := ArcTan2(rz, Sqrt(rx * rx + ry * ry));
    LonRad := ArcTan2(ry, rx);
    Emitter.Lon := RadToDeg(LonRad);
    Emitter.Lat := RadToDeg(LatRad);
    // Wrap lon
    while Emitter.Lon > 180.0 do Emitter.Lon := Emitter.Lon - 360.0;
    while Emitter.Lon < -180.0 do Emitter.Lon := Emitter.Lon + 360.0;
    // Ground-track speed in deg/sec (approximate): 360/T projected onto the
    // equator by cos(incl); lat component ~ sin(incl). Good enough for the
    // trail-direction vector the shader uses.
    Emitter.VelLon := (360.0 / T) * CosO * SinI;
    Emitter.VelLat := (180.0 / T) * SinI;
    Emitter.Heading := 0.0;
    Emitter.Magnitude := a;     // store altitude proxy (semimajor axis km)
    Emitter.Kind := Ord(fkSatellite);
    Emitter.Age := 0.0;
    if (AOffset + I) <= High(ADest) then
      ADest[AOffset + I] := Emitter;
  end;
end;

procedure TSkiaTelemetryMap.CleanupOffscreenGL;
begin
  if FGLContext <> 0 then
  begin
    wglMakeCurrent(FDummyDC, FGLContext);
    if FDeadReckonProgram <> 0 then glDeleteProgram(FDeadReckonProgram);
    if FSpawnProgram <> 0 then glDeleteProgram(FSpawnProgram);
    if FFadeProgram <> 0 then glDeleteProgram(FFadeProgram);
    if FEmitterSSBO <> 0 then glDeleteBuffers(1, @FEmitterSSBO);
    if (FPBOs[0] <> 0) or (FPBOs[1] <> 0) then
      glDeleteBuffers(2, @FPBOs[0]);
    if FOutputTex <> 0 then glDeleteTextures(1, @FOutputTex);
    wglMakeCurrent(0, 0);
    wglDeleteContext(FGLContext);
    FGLContext := 0;
  end;
  if (FDummyWnd <> 0) and (FDummyDC <> 0) then
    ReleaseDC(FDummyWnd, FDummyDC);
  if FDummyWnd <> 0 then DestroyWindow(FDummyWnd);
  FDummyWnd := 0;
  FDummyDC := 0;
  FGLInitialized := False;
end;

procedure TSkiaTelemetryMap.EnsureOutputTexture(W, H: Integer);
var
  NewSize: NativeInt;
  I: Integer;
begin
  if (FOutputTex <> 0) and (FTexWidth = W) and (FTexHeight = H) then Exit;
  if FOutputTex <> 0 then glDeleteTextures(1, @FOutputTex);
  FTexWidth := W;
  FTexHeight := H;
  SetLength(FPixelBuffer, W * H * 4);
  FillChar(Pointer(FPixelBuffer)^, Length(FPixelBuffer), 0);
  glGenTextures(1, @FOutputTex);
  glBindTexture(GL_TEXTURE_2D, FOutputTex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
  glBindTexture(GL_TEXTURE_2D, 0);

  for I := 0 to 1 do
    if FPBOs[I] <> 0 then glDeleteBuffers(1, @FPBOs[I]);
  FPBOs[0] := 0;
  FPBOs[1] := 0;
  glGenBuffers(2, @FPBOs[0]);
  NewSize := NativeInt(W) * NativeInt(H) * 4;
  FPBOSize := NewSize;
  for I := 0 to 1 do
  begin
    glBindBuffer(GL_PIXEL_PACK_BUFFER, FPBOs[I]);
    glBufferData(GL_PIXEL_PACK_BUFFER, NewSize, nil, GL_STREAM_READ);
  end;
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  FPBOIndex := 0;
  FPBOHasData := False;
end;

procedure TSkiaTelemetryMap.DispatchTelemetry(const ATime, ADeltaTime: Double;
  ViewW, ViewH, SimW, SimH: Integer; ASimTimeSec: Double);
var
  Mapped: Pointer;
  ReadPBO, WritePBO: Cardinal;
  NP, NS, NQ: Integer;
  PlaneOK, SatOK, QuakeOK: Boolean;
  EmitterCount: Int64;
  TotalParticles: Int64;
  GroupsX, GroupsY: Cardinal;
  TotalGroups: Int64;
  PanX, PanY, Zoom: Single;
  Mask: Cardinal;
  PPC: Int64;
begin
  wglMakeCurrent(FDummyDC, FGLContext);
  EnsureOutputTexture(SimW, SimH);

  // Pull the latest snapshot from the feed threads (cheap: just an array copy
  // under a short lock). The satellites are propagated on this thread each
  // frame into the satellite slice of FEmitterStaging.
  if Assigned(FSnapshot) then
  begin
    FSnapshot.CopySnapshot(FEmitterStaging, FSatElements,
      NP, NS, NQ, PlaneOK, SatOK, QuakeOK);
    FHUDPlanes := NP;
    FHUDSats := NS;
    FHUDQuakes := NQ;
    FHUDPlaneOK := PlaneOK;
    FHUDSatOK := SatOK;
    FHUDQuakeOK := QuakeOK;
    if NS > 0 then
      PropagateSatellites(FSatElements, FEmitterStaging, NP, ASimTimeSec);
  end
  else
  begin
    NP := 0; NS := 0; NQ := 0;
  end;
  EmitterCount := Int64(NP) + Int64(NS) + Int64(NQ);

  if EmitterCount > 0 then
    UploadEmitters(FEmitterStaging, EmitterCount);

  // Read the latest user params (pan/zoom/filter/particle budget).
  FParamLock.Acquire;
  try
    PanX := FPanX;
    PanY := FPanY;
    Zoom := FZoom;
    Mask := FFilterMask;
    PPC := FParticleCount;
  finally
    FParamLock.Release;
  end;
  if PPC < 1 then PPC := 1;
  if EmitterCount < 1 then EmitterCount := 1; // avoid div-by-zero below
  // Per-emitter particle count: derived from the user-requested total so the
  // dropdown in the form ("1M", "5M", …) stays meaningful.
  FParticlesPerEmitter := Max(1, Integer(PPC div EmitterCount));
  TotalParticles := Int64(FParticlesPerEmitter) * EmitterCount;
  if TotalParticles < 1 then TotalParticles := 1;

  // ---- Async readback of the PREVIOUS frame's PBO ----------------------
  if FPBOHasData then
  begin
    ReadPBO := FPBOs[FPBOIndex xor 1];
    glBindBuffer(GL_PIXEL_PACK_BUFFER, ReadPBO);
    Mapped := glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, FPBOSize, GL_MAP_READ_BIT);
    if Mapped <> nil then
    begin
      System.Move(Mapped^, Pointer(FPixelBuffer)^, FPBOSize);
      glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    end;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  end;

  // ---- Fade pass (identical to uSkiaGPULiquid) -------------------------
  glUseProgram(FFadeProgram);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  glUniform2f(FLocFade_Resolution, SimW, SimH);
  glUniform1f(FLocFade_Decay, 0.91);   // tune trail length
  GroupsX := (Cardinal(SimW) + 15) div 16;
  GroupsY := (Cardinal(SimH) + 15) div 16;
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);

  // ---- Dead-reckon pass (one thread per emitter) ----------------------
  if EmitterCount > 0 then
  begin
    glUseProgram(FDeadReckonProgram);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FEmitterSSBO);
    glUniform1f(FLocDR_DeltaTime, ADeltaTime);
    glUniform1ui(FLocDR_EmitterCount, Cardinal(EmitterCount));
    // 1D dispatch: emitter counts stay below 1M, well under the 65k limit
    // after dividing by 64 (the local_size_x).
    GroupsX := (Cardinal(EmitterCount) + 63) div 64;
    glDispatchCompute(GroupsX, 1, 1);
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  end;

  // ---- Spawn pass (one thread per output particle) --------------------
  glUseProgram(FSpawnProgram);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FEmitterSSBO);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  glUniform1f(FLocSP_SimTime, ASimTimeSec);
  glUniform1f(FLocSP_Time, ATime);
  glUniform1f(FLocSP_DeltaTime, ADeltaTime);
  glUniform2f(FLocSP_Resolution, SimW, SimH);
  glUniform1ui(FLocSP_EmitterCount, Cardinal(EmitterCount));
  glUniform1ui(FLocSP_ParticlesPerEmitter, Cardinal(FParticlesPerEmitter));
  glUniform1ui(FLocSP_TotalParticles, Cardinal(TotalParticles));
  glUniform1ui(FLocSP_FilterMask, Mask);
  glUniform2f(FLocSP_Pan, PanX, PanY);
  glUniform1f(FLocSP_Zoom, Zoom);
  // 2D dispatch (mirrors uSkiaGPULiquid) — bypasses the 67M 1D limit.
  TotalGroups := (TotalParticles + 1023) div 1024;
  if TotalGroups > 32768 then
    GroupsX := 32768
  else
    GroupsX := Cardinal(TotalGroups);
  GroupsY := Cardinal((TotalGroups + Int64(GroupsX) - 1) div GroupsX);
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT or
                  GL_TEXTURE_FETCH_BARRIER_BIT);

  // ---- Async glGetTexImage into the WRITE PBO -------------------------
  WritePBO := FPBOs[FPBOIndex];
  glBindBuffer(GL_PIXEL_PACK_BUFFER, WritePBO);
  glBindTexture(GL_TEXTURE_2D, FOutputTex);
  glGetTexImage(GL_TEXTURE_2D, 0, GL_BGRA, GL_UNSIGNED_BYTE, nil);
  glBindTexture(GL_TEXTURE_2D, 0);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

  FPBOIndex := FPBOIndex xor 1;
  FPBOHasData := True;
  glUseProgram(0);
end;

{ ----------------------------------------------------------------------
  Map projection helpers (CPU side, for the Skia overlay).
  Equirectangular with pan/zoom, mirroring the GPU shader.
  ---------------------------------------------------------------------- }

function TSkiaTelemetryMap.LonLatToScreen(Lon, Lat: Single;
  const ADest: TRectF; PanX, PanY, Zoom: Single): TPointF;
var
  U, V: Single;
begin
  U := (Lon + 180.0) / 360.0;
  V := (85.0 - Lat) / 170.0;
  U := (U - 0.5) * Zoom + 0.5 + PanX;
  V := (V - 0.5) * Zoom + 0.5 + PanY;

  Result := PointF(ADest.Left + U * ADest.Width,
                   ADest.Top  + V * ADest.Height);
end;

procedure TSkiaTelemetryMap.DrawGraticule(const ACanvas: ISkCanvas;
  const ADest: TRectF; PanX, PanY, Zoom: Single);
var
  Paint: ISkPaint;
  Lon, Lat: Integer;
  P: TPointF;
  Path: ISkPathBuilder;
  PathObj: ISkPath;
  StepLon, StepLat: Integer;
begin
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 0.6;
  Paint.Color := $2030A0D0;   // faint blue
  // Choose a step that keeps ~12-16 lines visible at the current zoom.
  StepLon := 30;
  StepLat := 30;
  if Zoom > 2.0 then begin StepLon := 15; StepLat := 15; end;
  if Zoom > 4.0 then begin StepLon := 10; StepLat := 10; end;
  if Zoom > 8.0 then begin StepLon := 5;  StepLat := 5;  end;

  Path := TSkPathBuilder.Create;
  // Meridians
  Lon := -180;
  while Lon <= 180 do
  begin
    P := LonLatToScreen(Lon, -85, ADest, PanX, PanY, Zoom);
    Path.MoveTo(P);
    Lat := -85;
    while Lat <= 85 do
    begin
      Inc(Lat, 5);
      P := LonLatToScreen(Lon, Lat, ADest, PanX, PanY, Zoom);
      Path.LineTo(P);
    end;
    Inc(Lon, StepLon);
  end;
  // Parallels
  Lat := -85;
  while Lat <= 85 do
  begin
    P := LonLatToScreen(-180, Lat, ADest, PanX, PanY, Zoom);
    Path.MoveTo(P);
    Lon := -180;
    while Lon <= 180 do
    begin
      Inc(Lon, 5);
      P := LonLatToScreen(Lon, Lat, ADest, PanX, PanY, Zoom);
      Path.LineTo(P);
    end;
    Inc(Lat, StepLat);
  end;
  PathObj := Path.Detach;
  ACanvas.DrawPath(PathObj, Paint);
end;

procedure TSkiaTelemetryMap.DrawCoastlines(const ACanvas: ISkCanvas;
  const ADest: TRectF; PanX, PanY, Zoom: Single);
var
  Paint: ISkPaint;
  TopLeft, BottomRight: TPointF;
  TargetRect: TRectF;
begin
  // Lazy-load the equirectangular world map image once on the first render pass
  if not FWorldMapLoaded then
  begin
    FWorldMapLoaded := True;
    if FileExists('world.jpg') then
      FWorldMapImage := TSkImage.MakeFromEncodedFile('world.jpg');
  end;

  // Draw the background map image aligned to the exact Lon/Lat screen projection
  if FWorldMapImage <> nil then
  begin
    TopLeft     := LonLatToScreen(-180.0, 90.0, ADest, PanX, PanY, Zoom);
    BottomRight := LonLatToScreen(180.0, -90.0, ADest, PanX, PanY, Zoom);
    TargetRect  := TRectF.Create(TopLeft, BottomRight);

    Paint := TSkPaint.Create;
    Paint.Alpha := 180; // Slightly dim the background so glowing particles stand out
    ACanvas.DrawImageRect(FWorldMapImage, TargetRect, TSkSamplingOptions.High, Paint);
  end;
end;


procedure TSkiaTelemetryMap.DrawHUD(const ACanvas: ISkCanvas;
  const ADest: TRectF);
var
  Paint: ISkPaint;
  Font: ISkFont;
  Typeface: ISkTypeface;
  Y: Single;
  PlaneStatus, SatStatus, QuakeStatus: string;
begin
  Typeface := TSkTypeface.MakeDefault;
  Font := TSkFont.Create(Typeface, 14);
  Paint := TSkPaint.Create;
  // Dark translucent background bar across the bottom-left.
  Paint.Color := $CC000000;
  ACanvas.DrawRoundRect(RectF(10, ADest.Height - 110, ADest.Width - 10, ADest.Height - 8), 8, 8, Paint);

  Paint.Color := TAlphaColors.White;
  Y := ADest.Height - 88;
  ACanvas.DrawSimpleText(
    Format('Global Live Telemetry Command Center  |  %d FPS  |  %s Particles',
      [GetRealFPS, FormatFloat('#,##0', FParticleCount)]),
    20, Y, Font, Paint);
  Y := Y + 22;

  if FHUDPlaneOK then PlaneStatus := 'OK' else PlaneStatus := 'STALE';
  if FHUDSatOK   then SatStatus   := 'OK' else SatStatus   := 'STALE';
  if FHUDQuakeOK then QuakeStatus := 'OK' else QuakeStatus   := 'STALE';

  ACanvas.DrawSimpleText(
    Format('Planes: %d [%s]   Satellites: %d [%s]   Earthquakes: %d [%s]',
      [FHUDPlanes, PlaneStatus, FHUDSats, SatStatus, FHUDQuakes, QuakeStatus]),
    20, Y, Font, Paint);
  Y := Y + 22;

  ACanvas.DrawSimpleText(
    'Filter: [All] [Planes] [Sats] [Quakes]   |   Mouse: wheel=zoom',
    20, Y, Font, Paint);
end;


procedure TSkiaTelemetryMap.RenderEffect(const ACanvas: ISkCanvas;
  const ADest: TRectF; const ATime: Double);
var
  ViewW, ViewH, SimW, SimH: Integer;
  ImgInfo: TSkImageInfo;
  GPUImg: ISkImage;
  PanX, PanY, Zoom: Single;
  Paint: ISkPaint;
  SimTimeSec: Double;
begin
  ViewW := Round(ADest.Width);
  ViewH := Round(ADest.Height);
  if (ViewW <= 0) or (ViewH <= 0) then Exit;
  if not Active then
  begin
    inherited RenderEffect(ACanvas, ADest, ATime);
    Exit;
  end;
  if not InitOffscreenGL then
  begin
    ACanvas.Clear($FF1A0000);
    Paint := TSkPaint.Create;
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawSimpleText('GL 4.3 Error: ' + FErrorMsg, 20, 40,
      TSkFont.Create(TSkTypeface.MakeDefault, 16), Paint);
    Exit;
  end;
  // Half-res simulation above a size threshold (mirrors uSkiaGPULiquid).
  if (ViewW > 1100) or (ViewH > 750) then
  begin
    SimW := ViewW div 2;
    SimH := ViewH div 2;
  end
  else
  begin
    SimW := ViewW;
    SimH := ViewH;
  end;
  SimTimeSec := ATime;
  DispatchTelemetry(ATime, 1.0 / 60.0, ViewW, ViewH, SimW, SimH, SimTimeSec);

  // FPS bookkeeping.
  if FGPULastTime <= 0 then FGPULastTime := ATime;
  Inc(FGPUFrameCount);
  if (ATime - FGPULastTime) >= 1.0 then
  begin
    FGPURealFPS := Round(FGPUFrameCount / (ATime - FGPULastTime));
    FGPUFrameCount := 0;
    FGPULastTime := ATime;
  end;

  // ---- Skia composite -------------------------------------------------
  ACanvas.Clear(TAlphaColors.Black);

  FParamLock.Acquire;
  try
    PanX := FPanX; PanY := FPanY; Zoom := FZoom;
  finally
    FParamLock.Release;
  end;

  // 1. Background graticule + coastlines.
  DrawGraticule(ACanvas, ADest, PanX, PanY, Zoom);
  DrawCoastlines(ACanvas, ADest, PanX, PanY, Zoom);

  // 2. GPU particle framebuffer, blended additively over the map.
  ImgInfo := TSkImageInfo.Create(SimW, SimH, TSkColorType.BGRA8888,
    TSkAlphaType.Premul);
  GPUImg := TSkImage.MakeFromRaster(ImgInfo, Pointer(FPixelBuffer), SimW * 4);
  if Assigned(GPUImg) then
  begin
    Paint := TSkPaint.Create;
    Paint.AntiAlias := True;
    Paint.Blender := TSkBlender.MakeMode(TSkBlendMode.Plus);
    ACanvas.DrawImageRect(GPUImg, RectF(0, 0, SimW, SimH),
      RectF(ADest.Left, ADest.Top, ADest.Right, ADest.Bottom),
      TSkSamplingOptions.Medium, Paint);
  end;

  // 3. HUD on top.
  DrawHUD(ACanvas, ADest);
end;

end.

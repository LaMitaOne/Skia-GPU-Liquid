{*******************************************************************************
  SkiaGPULiquid v0.2 (Skia4Delphi + OpenGL 4.3+ Compute Shader Hybrid)
********************************************************************************
  Real-time 2D compute shader GPU liquid & particle simulation rendered directly
  inside an FMX Skia4Delphi control (TSkiaCustomThreadedBase derivative).

  Instead of drawing particles via CPU canvas calls or traditional vertex
  pipelines, this component spins up a dedicated offscreen OpenGL 4.3 Core
  context inside the background render thread. Three compute shaders run per
  frame:
    1. Trail-Fade Pass: Decays the previous RGBA8 image buffer via imageLoad /
       imageStore to produce smooth, glowing ink-like fluid trails.
    2. Curl-Field Precompute Pass: Writes the per-frame 2D flow vector field
       into a 256x256 RG16F texture so the particle shader can sample it via
       texture() instead of evaluating sin()/cos() per particle.
    3. Particle Simulation Pass: Evolves up to 1,000,000,000 particles stored
       in an SSBO using 2D Curl-Noise turbulence and interactive mouse forces,
       writing velocity-mapped colors directly into the output image2D.

  The resulting frame is wrapped zero-overhead via TSkImage.MakeFromRaster
  and composited onto the Skia canvas with crisp vector HUD overlays.

  Key Features:
    - Up to 1,000,000,000 particles (7M @ 60 FPS on Ryzen 4500U iGPU,
      125M @ 60 FPS on RTX 2060 Super, 1B @ 8 FPS on RTX 2060 Super)
    - Dedicated offscreen OpenGL 4.3 context running asynchronously in a TThread
    - Zero external dependencies (pure Windows OpenGL32 + Skia4Delphi)
    - 2D Curl-Noise fluid field + PCG uint hashing (no float precision artifacts)
    - Half-float packed SSBO (uvec2 = 8 bytes/particle) - 1B fits in 8 GB VRAM
    - 2D workgroup dispatch (works around the 67M GL_MAX_COMPUTE_WORK_GROUP_COUNT limit)
    - Zero-CPU GPU-side seeding via glClearBufferData + lazy pcgHash init
    - Async PBO readback (no pipeline stall on glGetTexImage)
    - Interactive mouse vortex & repulsion (Left-Drag = push/swirl, Right-Drag = black hole)
    - Automatic half-resolution simulation scaling for smooth fullscreen playback
    - Accurate GPU compute-thread RealFPS measurement

  Author:  Lara Miriam Tamy Reschke / LaMitaOne

  # Changelog

  -v0.2:

  Rewritten to scale from 1M to 1B particles on the same architecture.

  **Measured (2026-11-16):**

  | Particles | Ryzen 4500U iGPU | RTX 2060 Super 8GB |
  |-----------|------------------|--------------------|
  | 7M        | 60 FPS           | 60 FPS             |
  | 150M      | 1 FPS            | 60 FPS             |
  | 1B        | 1 FPS            | 8 FPS              |

  ### Technical changes

  - **3 compute passes per frame** instead of 2: added a curl-field precompute pass that writes the per-frame flow vector field into a 256×256 RG16F texture, sampled via `texture()` in the particle shader — eliminates 8 `sin()`/`cos()` calls per particle per frame.
  - **Half-float packed SSBO** (`uvec2`, 8 bytes/particle instead of `vec4` at 16 bytes) — halves VRAM and bandwidth; 1B particles fit in 8 GB instead of 16 GB.
  - **2D workgroup dispatch** (`GroupsX=32768`, `GroupsY=ceil(total/GroupsX)`) — works around the 67M limit imposed by `GL_MAX_COMPUTE_WORK_GROUP_COUNT` (=65535) on 1D dispatch; max addressable now ~2.2 trillion.
  - **Zero-CPU GPU-side seeding**: SSBO allocated with `nil` data + zeroed via `glClearBufferData`, lazy-initialized in the shader via `pcgHash` on the first frame — no multi-second CPU loop, no 8–16 GB host RAM spike.
  - **Int64 particle counts end-to-end** (`FParticleCount`, `FRequestedParticleCount`, property, setter, `InitParticles` param) + `uint` uniform set via `glUniform1ui` — avoids Int32 overflow at 268M+ and sign handling near 2.1B.
  - **Async PBO ping-pong readback**: two `GL_PIXEL_PACK_BUFFER`s alternate; `glGetTexImage` writes into the previous-frame PBO and returns immediately, DMA overlaps with the next frame's compute — removes the pipeline stall of synchronous `glGetTexImage`.
  - **Removed `imageLoad` from the particle pass**: pure `imageStore` writes — kills 1M extra texture reads/frame and the read-modify-write race when multiple particles hit the same pixel.
  - **`glActiveTexture` loaded dynamically** via `wglGetProcAddress` with `LoadLibrary`+`GetProcAddress` fallback — static import failed on some Windows installs ("entry point not found").
  - **NVIDIA GLSL fix**: local variable `packed` renamed to `pkd` — `packed` is a reserved GLSL layout-qualifier keyword that AMD tolerates as an identifier but NVIDIA rejects with `error C0000`.
  - **Shader simplifications**: `pos = fract(pos + vel * deltaTime)` replaces four `if`-branch wrap checks (branch-free on GPU).
  - **UI**: ComboBox extended with 125M / 150M / 200M / 250M / 500M / 750M / 1B entries; `FMillionCounts` array changed to `Int64`.

  ### Build

  - **Win64 target required** — `NativeInt` is 32-bit on Win32 and the `glBufferData` size parameter overflows above 2 GB SSBO.


*******************************************************************************}


unit uSkiaGPULiquid;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.UITypes,
  System.SyncObjs, Winapi.Windows, FMX.Types, FMX.Controls, FMX.Skia,
  System.Skia, uSkiaCustomThreadedBase;

const
  LIQUID_PARTICLE_COUNT = 1000000;

type
  TSkiaGPULiquid = class(TSkiaCustomThreadedBase)
  private
    FDummyWnd: HWND;
    FDummyDC: HDC;
    FGLContext: HGLRC;
    FGLInitialized: Boolean;
    FGLFailed: Boolean;
    FErrorMsg: string;

    FComputeProgram: Cardinal;
    FFadeProgram: Cardinal;
    // Curl-field precompute pass (writes the per-frame RG16F flow texture).
    FCurlProgram: Cardinal;
    FCurlFieldTex: Cardinal;     // 256x256 RG16F, sampled by the particle shader
    FSSBO_Particles: Cardinal;
    FOutputTex: Cardinal;
    FTexWidth: Integer;
    FTexHeight: Integer;
    FPixelBuffer: TBytes;

    // Runtime-adjustable particle count. The SSBO is reallocated (and the
    // particles re-seeded with random positions) whenever the requested count
    // changes between frames - see DispatchLiquid.
    // Int64 because we go up to 1 billion particles; Int32 overflows at ~2.1B
    // but intermediate arithmetic (ACount * SizeOf) overflows far earlier.
    FParticleCount: Int64;
    FRequestedParticleCount: Int64;

    // PBO ping-pong for async glGetTexImage (GPU->RAM transfer overlaps
    // with next frame's compute work; removes the pipeline stall).
    FPBOs: array[0..1] of Cardinal;
    FPBOSize: NativeInt;
    FPBOIndex: Integer;       // PBO we issue glGetTexImage into THIS frame
    FPBOHasData: Boolean;     // False until at least one frame has been queued

    FLoc_Time: Integer;
    FLoc_DeltaTime: Integer;
    FLoc_Resolution: Integer;
    FLoc_MousePos: Integer;
    FLoc_MouseDown: Integer;
    FLoc_CurlStrength: Integer;
    FLoc_ParticleCount: Integer;

    FLocFade_Resolution: Integer;
    FLocFade_Decay: Integer;

    // Curl-field pass uniforms
    FLocCurl_Time: Integer;
    FLocCurl_Resolution: Integer;

    FParamLock: TCriticalSection;
    FMousePos: TPointF;
    FMouseMode: Integer;
    FCurlStrength: Single;
    FTrailDecay: Single;

    // Echte Compute-Thread-FPS Messung
    FGPUFrameCount: Integer;
    FGPULastTime: Double;
    FGPURealFPS: Integer;

    function InitOffscreenGL: Boolean;
    procedure CleanupOffscreenGL;
    procedure EnsureOutputTexture(W, H: Integer);
    procedure InitParticles(ACount: Int64);
    procedure PollWindowsMouse(ViewW, ViewH, SimW, SimH: Integer);
    procedure DispatchLiquid(const ATime, ADeltaTime: Double; ViewW, ViewH, SimW, SimH: Integer);
    function GetRealFPS: Integer;
    procedure SetParticleCount(Value: Int64);
  protected
    procedure RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetMouseState(const APos: TPointF; AMode: Integer);
    property RealFPS: Integer read GetRealFPS;
    property ParticleCount: Int64 read FParticleCount write SetParticleCount;
    property CurlStrength: Single read FCurlStrength write FCurlStrength;
    property TrailDecay: Single read FTrailDecay write FTrailDecay;
  end;

implementation

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
  GL_RG16F = $822F;       // internal format for the curl-field texture
  GL_RG = $8227;          // texture format (2-channel)
  GL_HALF_FLOAT = $140B;  // texture type
  GL_TEXTURE0 = $84C0;
  // For zero-CPU seeding via glClearBufferData:
  GL_R32UI = $8234;              // 32-bit uint internal format
  GL_RED_INTEGER = $8D94;        // texture format (single uint channel)
  GL_UNSIGNED_INT = $1405;       // texture type
  GL_STATIC_COPY = $88E6;        // buffer usage: GPU writes, GPU reads
  GL_READ_WRITE = $88BA;
  // Pixel Buffer Object (PBO) targets / usage / map flags - for async glGetTexImage
  GL_PIXEL_PACK_BUFFER          = $88EB;
  GL_STREAM_READ                = $88E1;
  GL_MAP_READ_BIT              = $0001;
  WGL_CONTEXT_MAJOR_VERSION_ARB = $2091;
  WGL_CONTEXT_MINOR_VERSION_ARB = $2092;
  WGL_CONTEXT_PROFILE_MASK_ARB = $9126;
  WGL_CONTEXT_CORE_PROFILE_BIT_ARB = $00000001;
  GL43_ATTRIBS: array[0..6] of Integer = (WGL_CONTEXT_MAJOR_VERSION_ARB, 4, WGL_CONTEXT_MINOR_VERSION_ARB, 3, WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB, 0);

type
  PFNWGLCREATECONTEXTATTRIBSARBPROC = function(hDC: HDC; hShareContext: HGLRC; const attribList: PInteger): HGLRC; stdcall;

  PFNGLCREATESHADERPROC = function(shaderType: Cardinal): Cardinal; stdcall;

  PFNGLSHADERSOURCEPROC = procedure(shader: Cardinal; count: Integer; str: PPAnsiChar; len: PInteger); stdcall;

  PFNGLCOMPILESHADERPROC = procedure(shader: Cardinal); stdcall;

  PFNGLDELETESHADERPROC = procedure(shader: Cardinal); stdcall;

  PFNGLGETSHADERIVPROC = procedure(shader: Cardinal; pname: Cardinal; params: PInteger); stdcall;

  PFNGLGETSHADERINFOLOGPROC = procedure(shader: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;

  PFNGLCREATEPROGRAMPROC = function: Cardinal; stdcall;

  PFNGLATTACHSHADERPROC = procedure(programObj: Cardinal; shader: Cardinal); stdcall;

  PFNGLLINKPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLDELETEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLGETPROGRAMIVPROC = procedure(programObj: Cardinal; pname: Cardinal; params: PInteger); stdcall;

  PFNGLGETPROGRAMINFOLOGPROC = procedure(programObj: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;

  PFNGLUSEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLGETUNIFORMLOCATIONPROC = function(programObj: Cardinal; name: PAnsiChar): Integer; stdcall;

  PFNGLUNIFORM1FPROC = procedure(location: Integer; v: Single); stdcall;

  PFNGLUNIFORM2FPROC = procedure(location: Integer; x: Single; y: Single); stdcall;

  PFNGLUNIFORM1IPROC = procedure(location: Integer; v: Integer); stdcall;

  PFNGLUNIFORM1UIPROC = procedure(location: Integer; v: Cardinal); stdcall;

  PFNGLCLEARBUFFERDATAPROC = procedure(target: Cardinal; internalformat: Cardinal; format: Cardinal; type_: Cardinal; data: Pointer); stdcall;

  PFNGLDISPATCHCOMPUTEPROC = procedure(num_groups_x, num_groups_y, num_groups_z: Cardinal); stdcall;

  PFNGLMEMORYBARRIERPROC = procedure(barriers: Cardinal); stdcall;

  PFNGLGENBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLDELETEBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLBINDBUFFERPROC = procedure(target: Cardinal; buffer: Cardinal); stdcall;

  PFNGLBUFFERDATAPROC = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;

  PFNGLBINDBUFFERBASEPROC = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;

  PFNGLMAPBUFFERRANGEPROC = function(target: Cardinal; offset: NativeInt; length: NativeInt; access: Cardinal): Pointer; stdcall;

  PFNGLUNMAPBUFFERPROC = function(target: Cardinal): ByteBool; stdcall;

  PFNGLTEXSTORAGE2DPROC = procedure(target: Cardinal; levels: Integer; internalformat: Cardinal; width, height: Integer); stdcall;

  PFNGLBINDIMAGETEXTUREPROC = procedure(unit_: Cardinal; texture: Cardinal; level: Integer; layered: Byte; layer: Integer; access: Cardinal; format: Cardinal); stdcall;

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';

function wglCreateContext(hdc: hdc): HGLRC; stdcall; external 'opengl32.dll';

function wglDeleteContext(hglrc: hglrc): BOOL; stdcall; external 'opengl32.dll';

function wglMakeCurrent(hdc: hdc; hglrc: hglrc): BOOL; stdcall; external 'opengl32.dll';

procedure glGenTextures(n: Integer; textures: PCardinal); stdcall; external 'opengl32.dll';

procedure glDeleteTextures(n: Integer; textures: PCardinal); stdcall; external 'opengl32.dll';

procedure glBindTexture(target: Cardinal; texture: Cardinal); stdcall; external 'opengl32.dll';

procedure glTexParameteri(target: Cardinal; pname: Cardinal; param: Integer); stdcall; external 'opengl32.dll';

procedure glGetTexImage(target: Cardinal; level: Integer; format: Cardinal; type_: Cardinal; pixels: Pointer); stdcall; external 'opengl32.dll';

// glActiveTexture (OpenGL 1.3) - on some Windows systems the static
// opengl32.dll import does NOT expose this entry point at load time
// (the DLL forwards it via the ICD, which isn't present until a context
// is current). Resolve it dynamically: first try wglGetProcAddress (works
// for GL >= 1.2 entry points once a context is current), then fall back
// to LoadLibrary+GetProcAddress on opengl32.dll itself (some drivers
// only expose it through the DLL, not through wglGetProcAddress).
type
  PFNGLACTIVETEXTUREPROC = procedure(texture: Cardinal); stdcall;

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
  glMapBufferRange: PFNGLMAPBUFFERRANGEPROC;
  glUnmapBuffer: PFNGLUNMAPBUFFERPROC;
  glBindBufferBase: PFNGLBINDBUFFERBASEPROC;
  glTexStorage2D: PFNGLTEXSTORAGE2DPROC;
  glBindImageTexture: PFNGLBINDIMAGETEXTUREPROC;
  glActiveTexture: PFNGLACTIVETEXTUREPROC;

const
  FADE_SHADER_SRC: AnsiString = '#version 430'#10 + 'layout(local_size_x = 16, local_size_y = 16) in;'#10 + 'layout(rgba8, binding = 0) uniform image2D imgOut;'#10 + 'uniform vec2 resolution;'#10 + 'uniform float decay;'#10 + 'void main() {'#10 + '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 + '  if (px.x >= int(resolution.x) || px.y >= int(resolution.y)) return;'#10 + '  vec4 col = imageLoad(imgOut, px);'#10 + '  col.rgb *= decay;'#10 + '  col.a = 1.0;'#10 + '  imageStore(imgOut, px, col);'#10 + '}';

  // Curl-field precomputation pass. Writes the per-frame 2D flow vector field
  // (UV space) into a small RG16F texture. The particle shader then samples
  // it with hardware-bilinear filtering instead of evaluating sin()/cos() per
  // particle. At 100M particles this is ~1500x fewer trig ops per frame.
  // 256x256 = 65k texels, 8 trig ops each = 524k ops/frame (vs. 800M before).
  CURL_FIELD_SHADER_SRC: AnsiString = '#version 430'#10
    + 'layout(local_size_x = 16, local_size_y = 16) in;'#10
    + 'layout(rg16f, binding = 0) uniform image2D curlFieldOut;'#10
    + 'uniform float time;'#10
    + 'uniform vec2 resolution;'#10
    + 'void main() {'#10
    + '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10
    + '  if (px.x >= int(resolution.x) || px.y >= int(resolution.y)) return;'#10
    + '  vec2 uv = vec2(px) / resolution;'#10
    + '  float eps = 0.005;'#10
    + '  float n1 = sin((uv.x + eps) * 6.0 + time * 0.8) * cos(uv.y * 6.0 - time * 0.6)'#10
    + '           + sin((uv.x + eps) * 13.0 - time * 1.1) * 0.5;'#10
    + '  float n2 = sin((uv.x - eps) * 6.0 + time * 0.8) * cos(uv.y * 6.0 - time * 0.6)'#10
    + '           + sin((uv.x - eps) * 13.0 - time * 1.1) * 0.5;'#10
    + '  float n3 = sin(uv.x * 6.0 + time * 0.8) * cos((uv.y + eps) * 6.0 - time * 0.6)'#10
    + '           + cos((uv.y + eps) * 13.0 + time * 0.9) * 0.5;'#10
    + '  float n4 = sin(uv.x * 6.0 + time * 0.8) * cos((uv.y - eps) * 6.0 - time * 0.6)'#10
    + '           + cos((uv.y - eps) * 13.0 + time * 0.9) * 0.5;'#10
    + '  float dx = (n1 - n2) / (2.0 * eps);'#10
    + '  float dy = (n3 - n4) / (2.0 * eps);'#10
    + '  vec2 curl = vec2(dy, -dx) * 0.035;'#10
    + '  imageStore(curlFieldOut, px, vec4(curl, 0.0, 1.0));'#10
    + '}';
  LIQUID_COMPUTE_SRC: AnsiString = '#version 430'#10 + 'layout(local_size_x = 1024) in;'#10 + 'layout(std430, binding = 0) buffer Particles { uvec2 p[]; };'#10 + 'layout(rgba8, binding = 0) uniform image2D imgOut;'#10 + 'layout(binding = 1) uniform sampler2D curlField;'#10 + 'uniform float time;'#10 + 'uniform float deltaTime;'#10 + 'uniform vec2 resolution;'#10 + 'uniform vec2 mousePos;'#10 + 'uniform float mouseDown;'#10 + 'uniform float curlStrength;'#10 + 'uniform uint particleCount;'#10 + 'uint pcgHash(uint s) {'#10 + '  s = s * 747796405u + 2891336453u;'#10
    + '  uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;'#10 + '  return (w >> 22u) ^ w;'#10 + '}'#10 + 'float rand01(uint s) { return float(pcgHash(s)) / 4294967295.0; }'#10
    // Curl field is precomputed by CURL_FIELD_SHADER_SRC into a 256x256 RG16F
    // texture; here we sample with hardware bilinear filtering - removes the
    // 8 sin()/cos() calls per particle per frame.
    + 'vec2 sampleCurl(vec2 uv) {'#10 + '  return texture(curlField, uv).xy;'#10 + '}'#10
    + 'void main() {'#10
    // 2D dispatch index: 1D dispatch hits GL_MAX_COMPUTE_WORK_GROUP_COUNT (65.535)
    // at 67M particles. Y axis multiplies the addressable space by 65k.
    + '  uint idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 1024u) + gl_GlobalInvocationID.x;'#10
    + '  if (idx >= particleCount) return;'#10
    // Half-float packing: 8 bytes per particle (uvec2 = 2x uint32). Halves
    // VRAM and bandwidth vs vec4 layout. RTX 2060 Super (8GB) holds 1B
    // particles in 8GB; with this packing 1B fits in 8GB instead of 16GB.
    // NOTE: the local var is named `pkd`, NOT `packed` - "packed" is a
    // reserved GLSL layout-qualifier keyword (used in `layout(packed)` for
    // UBOs/SSBOs). AMD's compiler tolerates it as an identifier, but NVIDIA's
    // strict parser throws "error C0000: syntax error, unexpected '(',
    // expecting '::' or '(' exactly at packed.x - which is the crash that
    // prevented the RTX 2060 Super build from starting.
    + '  uvec2 pkd = p[idx];'#10 + '  vec2 pos = unpackHalf2x16(pkd.x);'#10 + '  vec2 vel = unpackHalf2x16(pkd.y);'#10
    // Lazy GPU seeding: zero-initialized buffer is detected here and seeded
    // via pcgHash on the FIRST frame only - no CPU seeding loop needed.
    + '  if (pos.x == 0.0 && pos.y == 0.0 && vel.x == 0.0) {'#10 + '    pos = vec2(rand01(idx * 3u + 1u), rand01(idx * 3u + 2u));'#10 + '  }'#10 + '  vec2 flow = sampleCurl(pos) * curlStrength;'#10 + '  vel = vel * 0.94 + flow * 0.06;'#10 + '  if (mouseDown > 0.5) {'#10
    + '    vec2 mUV = mousePos / max(resolution, vec2(1.0));'#10 + '    vec2 diff = pos - mUV;'#10 + '    float aspect = resolution.x / max(resolution.y, 1.0);'#10 + '    diff.x *= aspect;'#10 + '    float dist = length(diff);'#10 + '    if (dist < 0.35 && dist > 0.0005) {'#10 + '      vec2 dir = diff / dist;'#10 + '      dir.x /= aspect;'#10 + '      vec2 tangent = vec2(-dir.y, dir.x);'#10 + '      float falloff = pow(1.0 - dist / 0.35, 1.2);'#10 + '      if (mouseDown < 1.5) {'#10
    + '        vel += (dir * 3.5 + tangent * 2.5) * falloff * deltaTime * 35.0;'#10 + '      } else {'#10 + '        vel += (-dir * 3.0 + tangent * 4.5) * falloff * deltaTime * 35.0;'#10 + '      }'#10 + '    }'#10 + '  }'#10 + '  float vLen = length(vel);'#10 + '  if (vLen > 2.2) vel = (vel / vLen) * 2.2;'#10
    // fract() wrap: replaces 4 if-branches and is branch-free on the GPU.
    + '  pos = fract(pos + vel * deltaTime);'#10
    + '  p[idx] = uvec2(packHalf2x16(pos), packHalf2x16(vel));'#10 + '  ivec2 px = ivec2(pos * resolution);'#10 + '  if (px.x >= 0 && px.x < int(resolution.x) && px.y >= 0 && px.y < int(resolution.y)) {'#10 + '    float speed = clamp(vLen * 2.0, 0.0, 1.0);'#10 + '    vec3 cSlow = vec3(0.02, 0.20, 0.55);'#10 + '    vec3 cFast = vec3(0.40, 0.98, 1.00);'#10 + '    vec3 col = mix(cSlow, cFast, speed);'#10
    + '    imageStore(imgOut, px, vec4(col, 1.0));'#10 + '  }'#10 + '}';

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
{ TSkiaGPULiquid }

constructor TSkiaGPULiquid.Create(AOwner: TComponent);
begin
  inherited;
  FParamLock := TCriticalSection.Create;
  FCurlStrength := 1.4;
  FTrailDecay := 0.91;
  FMouseMode := 0;
  FGPUFrameCount := 0;
  FGPULastTime := 0;
  FGPURealFPS := 0;
  FPBOs[0] := 0;
  FPBOs[1] := 0;
  FPBOSize := 0;
  FPBOIndex := 0;
  FPBOHasData := False;
  FParticleCount := 0;
  FRequestedParticleCount := LIQUID_PARTICLE_COUNT;
  FCurlProgram := 0;
  FCurlFieldTex := 0;
end;

destructor TSkiaGPULiquid.Destroy;
begin
  inherited;
  CleanupOffscreenGL;
  FParamLock.Free;
end;

function TSkiaGPULiquid.GetRealFPS: Integer;
begin
  if Active and (FGPURealFPS > 0) then
    Result := FGPURealFPS
  else
    Result := inherited RealFPS;
end;

procedure TSkiaGPULiquid.SetMouseState(const APos: TPointF; AMode: Integer);
begin
  FParamLock.Acquire;
  try
    FMousePos := APos;
    FMouseMode := AMode;
  finally
    FParamLock.Release;
  end;
end;

procedure TSkiaGPULiquid.PollWindowsMouse(ViewW, ViewH, SimW, SimH: Integer);
var
  CurPt: TPoint;
  WndHandle: HWND;
  LeftDown, RightDown: Boolean;
  LocalX, LocalY, ScaleX, ScaleY: Single;
begin
  LeftDown := (GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0;
  RightDown := (GetAsyncKeyState(VK_RBUTTON) and $8000) <> 0;
  if not LeftDown and not RightDown then
  begin
    SetMouseState(PointF(0, 0), 0);
    Exit;
  end;
  WndHandle := GetForegroundWindow;
  if WndHandle = 0 then
    Exit;
  if GetCursorPos(CurPt) and ScreenToClient(WndHandle, CurPt) then
  begin
    LocalX := CurPt.X - 10.0;
    LocalY := CurPt.Y - 80.0;
    if (LocalX >= 0) and (LocalX <= ViewW) and (LocalY >= 0) and (LocalY <= ViewH) then
    begin
      ScaleX := SimW / Max(ViewW, 1);
      ScaleY := SimH / Max(ViewH, 1);
      if RightDown then
        SetMouseState(PointF(LocalX * ScaleX, LocalY * ScaleY), 2)
      else
        SetMouseState(PointF(LocalX * ScaleX, LocalY * ScaleY), 1);
      Exit;
    end;
  end;
  SetMouseState(PointF(0, 0), 0);
end;

function TSkiaGPULiquid.InitOffscreenGL: Boolean;
var
  PFD: TPixelFormatDescriptor;
  PF: Integer;
  TempCtx: hglrc;
  wglCreateContextAttribsARB: PFNWGLCREATECONTEXTATTRIBSARBPROC;
begin
  if FGLInitialized then
    Exit(True);
  if FGLFailed then
    Exit(False);
  try
    FDummyWnd := CreateWindowEx(0, 'STATIC', 'SkiaGLComputeDummy', WS_POPUP, 0, 0, 16, 16, 0, 0, HInstance, nil);
    if FDummyWnd = 0 then
      raise Exception.Create('CreateWindowEx failed');
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
    glDispatchCompute := wglGetProcAddress('glDispatchCompute');
    glMemoryBarrier := wglGetProcAddress('glMemoryBarrier');
    glGenBuffers := wglGetProcAddress('glGenBuffers');
    glDeleteBuffers := wglGetProcAddress('glDeleteBuffers');
    glBindBuffer := wglGetProcAddress('glBindBuffer');
    glBufferData := wglGetProcAddress('glBufferData');
    glMapBufferRange := wglGetProcAddress('glMapBufferRange');
    glUnmapBuffer := wglGetProcAddress('glUnmapBuffer');
    glBindBufferBase := wglGetProcAddress('glBindBufferBase');
    glTexStorage2D := wglGetProcAddress('glTexStorage2D');
    glBindImageTexture := wglGetProcAddress('glBindImageTexture');
    glUniform1ui := wglGetProcAddress('glUniform1ui');
    glClearBufferData := wglGetProcAddress('glClearBufferData');
    // glActiveTexture (GL 1.3): try wglGetProcAddress first; some drivers
    // only expose it via the opengl32.dll export table, so fall back to
    // LoadLibrary+GetProcAddress if wglGetProcAddress returns nil.
    glActiveTexture := wglGetProcAddress('glActiveTexture');
    if not Assigned(glActiveTexture) then
      glActiveTexture := GetProcAddress(LoadLibrary('opengl32.dll'), 'glActiveTexture');
    if not Assigned(glDispatchCompute) or not Assigned(glBindImageTexture) then
      raise Exception.Create('OpenGL 4.3 Compute Shader nicht unterstuetzt');
    if not Assigned(glMapBufferRange) or not Assigned(glUnmapBuffer) then
      raise Exception.Create('OpenGL PBO (glMapBufferRange) nicht unterstuetzt');
    if not Assigned(glActiveTexture) then
      raise Exception.Create('glActiveTexture nicht unterstuetzt (OpenGL 1.3 erforderlich)');
    if not Assigned(glUniform1ui) then
      raise Exception.Create('glUniform1ui nicht unterstuetzt (OpenGL 3.0 erforderlich)');
    if not Assigned(glClearBufferData) then
      raise Exception.Create('glClearBufferData nicht unterstuetzt (OpenGL 4.3 erforderlich)');
    FFadeProgram := CompileComputeShader(FADE_SHADER_SRC);
    FComputeProgram := CompileComputeShader(LIQUID_COMPUTE_SRC);
    FCurlProgram := CompileComputeShader(CURL_FIELD_SHADER_SRC);
    FLocFade_Resolution := glGetUniformLocation(FFadeProgram, 'resolution');
    FLocFade_Decay := glGetUniformLocation(FFadeProgram, 'decay');
    FLoc_Time := glGetUniformLocation(FComputeProgram, 'time');
    FLoc_DeltaTime := glGetUniformLocation(FComputeProgram, 'deltaTime');
    FLoc_Resolution := glGetUniformLocation(FComputeProgram, 'resolution');
    FLoc_MousePos := glGetUniformLocation(FComputeProgram, 'mousePos');
    FLoc_MouseDown := glGetUniformLocation(FComputeProgram, 'mouseDown');
    FLoc_CurlStrength := glGetUniformLocation(FComputeProgram, 'curlStrength');
    FLoc_ParticleCount := glGetUniformLocation(FComputeProgram, 'particleCount');
    FLocCurl_Time := glGetUniformLocation(FCurlProgram, 'time');
    FLocCurl_Resolution := glGetUniformLocation(FCurlProgram, 'resolution');
    // Create the 256x256 RG16F curl-field texture. Written by the curl
    // compute pass via imageStore, sampled by the particle shader via
    // texture() with hardware bilinear filtering. LINEAR + CLAMP_TO_EDGE
    // gives smooth interpolation across the UV [0,1] domain.
    glGenTextures(1, @FCurlFieldTex);
    glBindTexture(GL_TEXTURE_2D, FCurlFieldTex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RG16F, 256, 256);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);
    // Seed + upload the initial particle set (default count set in the ctor).
    InitParticles(FRequestedParticleCount);
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

procedure TSkiaGPULiquid.InitParticles(ACount: Int64);
var
  Zero: Cardinal;
begin
  if ACount <= 0 then
    Exit;
  // Zero-CPU seeding: allocate the SSBO with nil data (no host upload),
  // then use glClearBufferData to zero it on the GPU in milliseconds.
  // The particle shader's first-frame lazy init (the `if (pos.x == 0.0 ...)`
  // branch) then seeds the positions via pcgHash on the GPU itself, which
  // is what removes the multi-second CPU loop and 8-16 GB RAM spike that
  // SetLength(InitData, ACount) would cause at 1B particles.
  if FSSBO_Particles = 0 then
    glGenBuffers(1, @FSSBO_Particles);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Particles);
  // 8 bytes per particle (uvec2 = 2x uint32). Int64 cast avoids Int32 overflow
  // at >= 268M particles with the old 16-byte vec4 layout; this packing is
  // half that and supports up to ~2.1B before the cast itself matters.
  glBufferData(GL_SHADER_STORAGE_BUFFER, NativeInt(Int64(ACount) * 8), nil, GL_DYNAMIC_COPY);
  Zero := 0;
  glClearBufferData(GL_SHADER_STORAGE_BUFFER, GL_R32UI, GL_RED_INTEGER, GL_UNSIGNED_INT, @Zero);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  FParticleCount := ACount;
end;

procedure TSkiaGPULiquid.SetParticleCount(Value: Int64);
begin
  if Value < 1 then
    Value := 1;
  // Just record the wish - the actual SSBO reallocation happens on the GL
  // thread in DispatchLiquid, where a GL context is current.
  FRequestedParticleCount := Value;
end;

procedure TSkiaGPULiquid.CleanupOffscreenGL;
begin
  if FGLContext <> 0 then
  begin
    wglMakeCurrent(FDummyDC, FGLContext);
    if FComputeProgram <> 0 then
      glDeleteProgram(FComputeProgram);
    if FFadeProgram <> 0 then
      glDeleteProgram(FFadeProgram);
    if FCurlProgram <> 0 then
      glDeleteProgram(FCurlProgram);
    if FSSBO_Particles <> 0 then
      glDeleteBuffers(1, @FSSBO_Particles);
    if (FPBOs[0] <> 0) or (FPBOs[1] <> 0) then
      glDeleteBuffers(2, @FPBOs[0]);
    if FOutputTex <> 0 then
      glDeleteTextures(1, @FOutputTex);
    if FCurlFieldTex <> 0 then
      glDeleteTextures(1, @FCurlFieldTex);
    wglMakeCurrent(0, 0);
    wglDeleteContext(FGLContext);
    FGLContext := 0;
  end;
  if (FDummyWnd <> 0) and (FDummyDC <> 0) then
    ReleaseDC(FDummyWnd, FDummyDC);
  if FDummyWnd <> 0 then
    DestroyWindow(FDummyWnd);
  FDummyWnd := 0;
  FDummyDC := 0;
  FGLInitialized := False;
end;

procedure TSkiaGPULiquid.EnsureOutputTexture(W, H: Integer);
var
  NewSize: NativeInt;
  I: Integer;
begin
  if (FOutputTex <> 0) and (FTexWidth = W) and (FTexHeight = H) then
    Exit;
  if FOutputTex <> 0 then
    glDeleteTextures(1, @FOutputTex);
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

  // (Re)create the two PBOs used for async glGetTexImage.
  // The first frame will not have valid pixel data yet, so we mark the
  // pipeline as "no data" - DispatchLiquid skips the readback for that
  // single frame and the FPixelBuffer (already zeroed above) is shown instead.
  for I := 0 to 1 do
    if FPBOs[I] <> 0 then
      glDeleteBuffers(1, @FPBOs[I]);
  FPBOs[0] := 0;
  FPBOs[1] := 0;
  glGenBuffers(2, @FPBOs[0]);
  NewSize := NativeInt(W) * NativeInt(H) * 4;
  FPBOSize := NewSize;
  // Persistent-style STREAM_READ: GPU writes, CPU reads. Allocate both.
  for I := 0 to 1 do
  begin
    glBindBuffer(GL_PIXEL_PACK_BUFFER, FPBOs[I]);
    // NULL data ptr = allocate only, GPU will fill via glGetTexImage.
    glBufferData(GL_PIXEL_PACK_BUFFER, NewSize, nil, GL_STREAM_READ);
  end;
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  FPBOIndex := 0;
  FPBOHasData := False;
end;

procedure TSkiaGPULiquid.DispatchLiquid(const ATime, ADeltaTime: Double; ViewW, ViewH, SimW, SimH: Integer);
var
  MPos: TPointF;
  MMode: Integer;
  GroupsX, GroupsY: Cardinal;
  TotalGroups: Int64;
  ReadPBO, WritePBO: Cardinal;
  Mapped: Pointer;
begin
  wglMakeCurrent(FDummyDC, FGLContext);
  EnsureOutputTexture(SimW, SimH);
  // Apply a pending particle-count change on the GL thread (where the
  // context is current). Reallocates the SSBO + re-seeds positions.
  if FRequestedParticleCount <> FParticleCount then
    InitParticles(FRequestedParticleCount);
  PollWindowsMouse(ViewW, ViewH, SimW, SimH);
  FParamLock.Acquire;
  try
    MPos := FMousePos;
    MMode := FMouseMode;
  finally
    FParamLock.Release;
  end;

  // ---- Async readback of the PREVIOUS frame's PBO -----------------------
  // The glGetTexImage for this PBO was issued one frame ago and the GPU DMA
  // has been running in the background during the Skia composite + frame
  // pacing wait. glMapBufferRange blocks only until that DMA finishes - it
  // does NOT wait for the current frame's compute (which runs afterwards).
  // This is what removes the pipeline stall vs. the old synchronous glGetTexImage.
  if FPBOHasData then
  begin
    ReadPBO := FPBOs[FPBOIndex xor 1];
    glBindBuffer(GL_PIXEL_PACK_BUFFER, ReadPBO);
    Mapped := glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, FPBOSize, GL_MAP_READ_BIT);
    if Mapped <> nil then
    begin
      // Fully qualified: avoids shadowing by any other Move() in scope
      // (e.g. an FMX/TControl method with a different signature).
      System.Move(Mapped^, Pointer(FPixelBuffer)^, FPBOSize);
      glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    end;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  end;

  // ---- Fade pass --------------------------------------------------------
  glUseProgram(FFadeProgram);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  glUniform2f(FLocFade_Resolution, SimW, SimH);
  glUniform1f(FLocFade_Decay, FTrailDecay);
  GroupsX := (Cardinal(SimW) + 15) div 16;
  GroupsY := (Cardinal(SimH) + 15) div 16;
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);

  // ---- Curl-field precompute pass --------------------------------------
  // Writes the per-frame 2D flow vector field into the 256x256 RG16F texture.
  // The particle shader then samples it via texture() instead of evaluating
  // 8 sin()/cos() calls per particle - the major ALU win at high counts.
  glUseProgram(FCurlProgram);
  glBindImageTexture(0, FCurlFieldTex, 0, 0, 0, GL_READ_WRITE, GL_RG16F);
  glUniform1f(FLocCurl_Time, ATime);
  glUniform2f(FLocCurl_Resolution, 256, 256);
  glDispatchCompute(16, 16, 1);   // (256+15)/16 = 16 work groups each axis
  // Shader image write -> texture fetch: must synchronize the image store
  // before the sampler can read it back as a texture.
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT or GL_TEXTURE_FETCH_BARRIER_BIT);

  // ---- Particle simulation pass ---------------------------------------
  glUseProgram(FComputeProgram);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FSSBO_Particles);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  // Bind the curl-field texture to sampler unit 1 (matches
  // "layout(binding = 1) uniform sampler2D curlField" in the shader).
  // Unit 0 stays reserved for the image2D output - keeps image and sampler
  // paths fully separated, which some drivers require.
  glActiveTexture(Cardinal(GL_TEXTURE0 + 1));
  glBindTexture(GL_TEXTURE_2D, FCurlFieldTex);
  glUniform1f(FLoc_Time, ATime);
  glUniform1f(FLoc_DeltaTime, ADeltaTime);
  glUniform2f(FLoc_Resolution, SimW, SimH);
  glUniform2f(FLoc_MousePos, MPos.X, MPos.Y);
  glUniform1f(FLoc_MouseDown, MMode * 1.0);
  glUniform1f(FLoc_CurlStrength, FCurlStrength);
  // particleCount is a uint uniform now (used to index into the SSBO and
  // compared against the 2D-derived idx). glUniform1ui because glUniform1i
  // caps at Int32 max (~2.1B) which is uncomfortably close to 1B and would
  // require shader-side sign handling.
  glUniform1ui(FLoc_ParticleCount, Cardinal(FParticleCount));
  // 2D dispatch: 1D dispatch is capped at GL_MAX_COMPUTE_WORK_GROUP_COUNT
  // (65.535 on essentially all desktop GPUs), which clamps 1D dispatch to
  // 67M particles. Spread across X+Y so we cover up to 65k * 65k * 1024 ~=
  // 4.4 trillion particles - effectively unbounded.
  // Use GroupsX = 32768 (power-of-two-ish, well under the 65k limit, leaves
  // headroom for the Y axis to grow). The shader reverses this via
  //   idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 1024u) + gl_GlobalInvocationID.x
  TotalGroups := (Int64(FParticleCount) + 1023) div 1024;
  if TotalGroups > 32768 then
    GroupsX := 32768
  else
    GroupsX := Cardinal(TotalGroups);
  GroupsY := Cardinal((TotalGroups + Int64(GroupsX) - 1) div GroupsX);
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT or GL_TEXTURE_FETCH_BARRIER_BIT);

  // ---- Issue async glGetTexImage into the WRITE PBO ---------------------
  // pixels = nil with a bound GL_PIXEL_PACK_BUFFER routes the transfer into
  // the PBO and returns immediately; the GPU DMA continues in the background
  // while we go on to the next frame's compute. The result is consumed one
  // frame later by the MapBufferRange block at the top of this procedure.
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

procedure TSkiaGPULiquid.RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double);
var
  ViewW, ViewH, SimW, SimH: Integer;
  ImgInfo: TSkImageInfo;
  GPUImg: ISkImage;
  Paint: ISkPaint;
  Font: ISkFont;
  Typeface: ISkTypeface;
  ScaleBack: Single;
begin
  ViewW := Round(ADest.Width);
  ViewH := Round(ADest.Height);
  if (ViewW <= 0) or (ViewH <= 0) then
    Exit;
  if not Active then
  begin
    inherited RenderEffect(ACanvas, ADest, ATime);
    Exit;
  end;
  if not InitOffscreenGL then
  begin
    ACanvas.Clear($FF1A0000);
    Typeface := TSkTypeface.MakeDefault;
    Font := TSkFont.Create(Typeface, 16);
    Paint := TSkPaint.Create;
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawSimpleText('GL 4.3 Error: ' + FErrorMsg, 20, 40, Font, Paint);
    Exit;
  end;
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
  DispatchLiquid(ATime, 1.0 / 60.0, ViewW, ViewH, SimW, SimH);
  if FGPULastTime <= 0 then
    FGPULastTime := ATime;
  Inc(FGPUFrameCount);
  if (ATime - FGPULastTime) >= 1.0 then
  begin
    FGPURealFPS := Round(FGPUFrameCount / (ATime - FGPULastTime));
    FGPUFrameCount := 0;
    FGPULastTime := ATime;
  end;
  ACanvas.Clear(TAlphaColors.Black);
  ImgInfo := TSkImageInfo.Create(SimW, SimH, TSkColorType.BGRA8888, TSkAlphaType.Premul);
  GPUImg := TSkImage.MakeFromRaster(ImgInfo, Pointer(FPixelBuffer), SimW * 4);
  if Assigned(GPUImg) then
    ACanvas.DrawImageRect(GPUImg, RectF(0, 0, SimW, SimH), RectF(0, 0, ViewW, ViewH), TSkSamplingOptions.Medium);
  Paint := TSkPaint.Create;
  Paint.Color := $CC000000;
  ACanvas.DrawRoundRect(RectF(10, 8, 630, 38), 6, 6, Paint);
  Typeface := TSkTypeface.MakeDefault;
  Font := TSkFont.Create(Typeface, 15);
  Paint.Color := TAlphaColors.White;
  ACanvas.DrawSimpleText(Format('Skia + OpenGL 4.3 Compute | %s Liquid Particles (Left/Right Drag)', [FormatFloat('#,##0', FParticleCount)]), 18, 28, Font, Paint);
  FParamLock.Acquire;
  try
    if FMouseMode <> 0 then
    begin
      ScaleBack := ViewW / Max(SimW, 1);
      Paint := TSkPaint.Create(TSkPaintStyle.Stroke);
      Paint.AntiAlias := True;
      Paint.StrokeWidth := 2;
      if FMouseMode = 1 then
        Paint.Color := $AA00FFFF
      else
        Paint.Color := $AAFF44AA;
      ACanvas.DrawCircle(PointF(FMousePos.X * ScaleBack, FMousePos.Y * ScaleBack), 45, Paint);
    end;
  finally
    FParamLock.Release;
  end;
end;

end.


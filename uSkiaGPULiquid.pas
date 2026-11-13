{*******************************************************************************
  SkiaGPULiquid v0.1 (Skia4Delphi + OpenGL 4.3+ Compute Shader Hybrid)
********************************************************************************
  Real-time 2D compute shader GPU liquid & particle simulation rendered directly
  inside an FMX Skia4Delphi control (TSkiaCustomThreadedBase derivative).

  Instead of drawing particles via CPU canvas calls or traditional vertex
  pipelines, this component spins up a dedicated offscreen OpenGL 4.3 Core
  context inside the background render thread. Two compute shaders run per
  frame:
    1. Trail-Fade Pass: Decays the previous RGBA8 image buffer via imageLoad /
       imageStore to produce smooth, glowing ink-like fluid trails.
    2. Particle Simulation Pass: Evolves 1,000,000+ particles stored in an
       SSBO using 2D Curl-Noise turbulence and interactive mouse forces,
       writing velocity-mapped colors directly into the output image2D.

  The resulting frame is wrapped zero-overhead via TSkImage.MakeFromRaster
  and composited onto the Skia canvas with crisp vector HUD overlays.

  Key Features:
    - 1M+ particles simulated at 60 FPS on ryzen4500u
    - Dedicated offscreen OpenGL 4.3 context running asynchronously in a TThread
    - Zero external dependencies (pure Windows OpenGL32 + Skia4Delphi)
    - 2D Curl-Noise fluid field + PCG uint hashing (no float precision artifacts)
    - Interactive mouse vortex & repulsion (Left-Drag = push/swirl, Right-Drag = black hole)
    - Automatic half-resolution simulation scaling for smooth fullscreen playback
    - Accurate GPU compute-thread RealFPS measurement

  Author:  Lara Miriam Tamy Reschke / LaMitaOne

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
  TGLVec4 = record
    X, Y, Z, W: Single;
  end;

  PGLVec4 = ^TGLVec4;

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
    FSSBO_Particles: Cardinal;
    FOutputTex: Cardinal;
    FTexWidth: Integer;
    FTexHeight: Integer;
    FPixelBuffer: TBytes;

    FLoc_Time: Integer;
    FLoc_DeltaTime: Integer;
    FLoc_Resolution: Integer;
    FLoc_MousePos: Integer;
    FLoc_MouseDown: Integer;
    FLoc_CurlStrength: Integer;
    FLoc_ParticleCount: Integer;

    FLocFade_Resolution: Integer;
    FLocFade_Decay: Integer;

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
    procedure PollWindowsMouse(ViewW, ViewH, SimW, SimH: Integer);
    procedure DispatchLiquid(const ATime, ADeltaTime: Double; ViewW, ViewH, SimW, SimH: Integer);
    function GetRealFPS: Integer;
  protected
    procedure RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetMouseState(const APos: TPointF; AMode: Integer);
    property RealFPS: Integer read GetRealFPS;
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
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_READ_WRITE = $88BA;
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

  PFNGLDISPATCHCOMPUTEPROC = procedure(num_groups_x, num_groups_y, num_groups_z: Cardinal); stdcall;

  PFNGLMEMORYBARRIERPROC = procedure(barriers: Cardinal); stdcall;

  PFNGLGENBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLDELETEBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLBINDBUFFERPROC = procedure(target: Cardinal; buffer: Cardinal); stdcall;

  PFNGLBUFFERDATAPROC = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;

  PFNGLBINDBUFFERBASEPROC = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;

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
  glDispatchCompute: PFNGLDISPATCHCOMPUTEPROC;
  glMemoryBarrier: PFNGLMEMORYBARRIERPROC;
  glGenBuffers: PFNGLGENBUFFERSPROC;
  glDeleteBuffers: PFNGLDELETEBUFFERSPROC;
  glBindBuffer: PFNGLBINDBUFFERPROC;
  glBufferData: PFNGLBUFFERDATAPROC;
  glBindBufferBase: PFNGLBINDBUFFERBASEPROC;
  glTexStorage2D: PFNGLTEXSTORAGE2DPROC;
  glBindImageTexture: PFNGLBINDIMAGETEXTUREPROC;

const
  FADE_SHADER_SRC: AnsiString = '#version 430'#10 + 'layout(local_size_x = 16, local_size_y = 16) in;'#10 + 'layout(rgba8, binding = 0) uniform image2D imgOut;'#10 + 'uniform vec2 resolution;'#10 + 'uniform float decay;'#10 + 'void main() {'#10 + '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 + '  if (px.x >= int(resolution.x) || px.y >= int(resolution.y)) return;'#10 + '  vec4 col = imageLoad(imgOut, px);'#10 + '  col.rgb *= decay;'#10 + '  col.a = 1.0;'#10 + '  imageStore(imgOut, px, col);'#10 + '}';
  LIQUID_COMPUTE_SRC: AnsiString = '#version 430'#10 + 'layout(local_size_x = 1024) in;'#10 + 'layout(std430, binding = 0) buffer Particles { vec4 p[]; };'#10 + 'layout(rgba8, binding = 0) uniform image2D imgOut;'#10 + 'uniform float time;'#10 + 'uniform float deltaTime;'#10 + 'uniform vec2 resolution;'#10 + 'uniform vec2 mousePos;'#10 + 'uniform float mouseDown;'#10 + 'uniform float curlStrength;'#10 + 'uniform int particleCount;'#10 + 'uint pcgHash(uint s) {'#10 + '  s = s * 747796405u + 2891336453u;'#10
    + '  uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;'#10 + '  return (w >> 22u) ^ w;'#10 + '}'#10 + 'float rand01(uint s) { return float(pcgHash(s)) / 4294967295.0; }'#10 + 'vec2 curlField(vec2 uv, float t) {'#10 + '  float eps = 0.005;'#10 + '  float n1 = sin((uv.x + eps) * 6.0 + t * 0.8) * cos(uv.y * 6.0 - t * 0.6)'#10 + '           + sin((uv.x + eps) * 13.0 - t * 1.1) * 0.5;'#10 + '  float n2 = sin((uv.x - eps) * 6.0 + t * 0.8) * cos(uv.y * 6.0 - t * 0.6)'#10 +
    '           + sin((uv.x - eps) * 13.0 - t * 1.1) * 0.5;'#10 + '  float n3 = sin(uv.x * 6.0 + t * 0.8) * cos((uv.y + eps) * 6.0 - t * 0.6)'#10 + '           + cos((uv.y + eps) * 13.0 + t * 0.9) * 0.5;'#10 + '  float n4 = sin(uv.x * 6.0 + t * 0.8) * cos((uv.y - eps) * 6.0 - t * 0.6)'#10 + '           + cos((uv.y - eps) * 13.0 + t * 0.9) * 0.5;'#10 + '  float dx = (n1 - n2) / (2.0 * eps);'#10 + '  float dy = (n3 - n4) / (2.0 * eps);'#10 + '  return vec2(dy, -dx) * 0.035;'#10 + '}'#10 + 'void main() {'#10 +
    '  uint idx = gl_GlobalInvocationID.x;'#10 + '  if (idx >= uint(particleCount)) return;'#10 + '  vec4 data = p[idx];'#10 + '  vec2 pos = data.xy;'#10 + '  vec2 vel = data.zw;'#10 + '  if (pos.x == 0.0 && pos.y == 0.0 && vel.x == 0.0) {'#10 + '    pos = vec2(rand01(idx * 3u + 1u), rand01(idx * 3u + 2u));'#10 + '  }'#10 + '  vec2 flow = curlField(pos, time) * curlStrength;'#10 + '  vel = vel * 0.94 + flow * 0.06;'#10 + '  if (mouseDown > 0.5) {'#10 +
    '    vec2 mUV = mousePos / max(resolution, vec2(1.0));'#10 + '    vec2 diff = pos - mUV;'#10 + '    float aspect = resolution.x / max(resolution.y, 1.0);'#10 + '    diff.x *= aspect;'#10 + '    float dist = length(diff);'#10 + '    if (dist < 0.35 && dist > 0.0005) {'#10 + '      vec2 dir = diff / dist;'#10 + '      dir.x /= aspect;'#10 + '      vec2 tangent = vec2(-dir.y, dir.x);'#10 + '      float falloff = pow(1.0 - dist / 0.35, 1.2);'#10 + '      if (mouseDown < 1.5) {'#10 +
    '        vel += (dir * 3.5 + tangent * 2.5) * falloff * deltaTime * 35.0;'#10 + '      } else {'#10 + '        vel += (-dir * 3.0 + tangent * 4.5) * falloff * deltaTime * 35.0;'#10 + '      }'#10 + '    }'#10 + '  }'#10 + '  float vLen = length(vel);'#10 + '  if (vLen > 2.2) vel = (vel / vLen) * 2.2;'#10 + '  pos += vel * deltaTime;'#10 + '  if (pos.x < 0.0) pos.x += 1.0;'#10 + '  if (pos.x >= 1.0) pos.x -= 1.0;'#10 + '  if (pos.y < 0.0) pos.y += 1.0;'#10 + '  if (pos.y >= 1.0) pos.y -= 1.0;'#10 +
    '  p[idx] = vec4(pos, vel);'#10 + '  ivec2 px = ivec2(pos * resolution);'#10 + '  if (px.x >= 0 && px.x < int(resolution.x) && px.y >= 0 && px.y < int(resolution.y)) {'#10 + '    float speed = clamp(vLen * 2.0, 0.0, 1.0);'#10 + '    vec3 cSlow = vec3(0.02, 0.20, 0.55);'#10 + '    vec3 cFast = vec3(0.40, 0.98, 1.00);'#10 + '    vec3 col = mix(cSlow, cFast, speed);'#10 + '    vec4 prev = imageLoad(imgOut, px);'#10 + '    vec3 blended = clamp(prev.rgb + col * 0.28, 0.0, 1.0);'#10 + '    imageStore(imgOut, px, vec4(blended, 1.0));'#10 + '  }'#10 + '}';

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
  InitData: array of TGLVec4;
  Ptr: PGLVec4;
  I: Integer;
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
    glBindBufferBase := wglGetProcAddress('glBindBufferBase');
    glTexStorage2D := wglGetProcAddress('glTexStorage2D');
    glBindImageTexture := wglGetProcAddress('glBindImageTexture');
    if not Assigned(glDispatchCompute) or not Assigned(glBindImageTexture) then
      raise Exception.Create('OpenGL 4.3 Compute Shader nicht unterstuetzt');
    FFadeProgram := CompileComputeShader(FADE_SHADER_SRC);
    FComputeProgram := CompileComputeShader(LIQUID_COMPUTE_SRC);
    FLocFade_Resolution := glGetUniformLocation(FFadeProgram, 'resolution');
    FLocFade_Decay := glGetUniformLocation(FFadeProgram, 'decay');
    FLoc_Time := glGetUniformLocation(FComputeProgram, 'time');
    FLoc_DeltaTime := glGetUniformLocation(FComputeProgram, 'deltaTime');
    FLoc_Resolution := glGetUniformLocation(FComputeProgram, 'resolution');
    FLoc_MousePos := glGetUniformLocation(FComputeProgram, 'mousePos');
    FLoc_MouseDown := glGetUniformLocation(FComputeProgram, 'mouseDown');
    FLoc_CurlStrength := glGetUniformLocation(FComputeProgram, 'curlStrength');
    FLoc_ParticleCount := glGetUniformLocation(FComputeProgram, 'particleCount');
    SetLength(InitData, LIQUID_PARTICLE_COUNT);
    Ptr := Pointer(InitData);
    for I := 0 to LIQUID_PARTICLE_COUNT - 1 do
    begin
      Ptr^.X := Random;
      Ptr^.Y := Random;
      Ptr^.Z := 0;
      Ptr^.W := 0;
      Inc(Ptr);
    end;
    glGenBuffers(1, @FSSBO_Particles);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Particles);
    glBufferData(GL_SHADER_STORAGE_BUFFER, LIQUID_PARTICLE_COUNT * SizeOf(TGLVec4), Pointer(InitData), GL_DYNAMIC_COPY);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
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

procedure TSkiaGPULiquid.CleanupOffscreenGL;
begin
  if FGLContext <> 0 then
  begin
    wglMakeCurrent(FDummyDC, FGLContext);
    if FComputeProgram <> 0 then
      glDeleteProgram(FComputeProgram);
    if FFadeProgram <> 0 then
      glDeleteProgram(FFadeProgram);
    if FSSBO_Particles <> 0 then
      glDeleteBuffers(1, @FSSBO_Particles);
    if FOutputTex <> 0 then
      glDeleteTextures(1, @FOutputTex);
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
end;

procedure TSkiaGPULiquid.DispatchLiquid(const ATime, ADeltaTime: Double; ViewW, ViewH, SimW, SimH: Integer);
var
  MPos: TPointF;
  MMode: Integer;
  GroupsX, GroupsY: Cardinal;
begin
  wglMakeCurrent(FDummyDC, FGLContext);
  EnsureOutputTexture(SimW, SimH);
  PollWindowsMouse(ViewW, ViewH, SimW, SimH);
  FParamLock.Acquire;
  try
    MPos := FMousePos;
    MMode := FMouseMode;
  finally
    FParamLock.Release;
  end;
  glUseProgram(FFadeProgram);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  glUniform2f(FLocFade_Resolution, SimW, SimH);
  glUniform1f(FLocFade_Decay, FTrailDecay);
  GroupsX := (Cardinal(SimW) + 15) div 16;
  GroupsY := (Cardinal(SimH) + 15) div 16;
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
  glUseProgram(FComputeProgram);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FSSBO_Particles);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  glUniform1f(FLoc_Time, ATime);
  glUniform1f(FLoc_DeltaTime, ADeltaTime);
  glUniform2f(FLoc_Resolution, SimW, SimH);
  glUniform2f(FLoc_MousePos, MPos.X, MPos.Y);
  glUniform1f(FLoc_MouseDown, MMode * 1.0);
  glUniform1f(FLoc_CurlStrength, FCurlStrength);
  glUniform1i(FLoc_ParticleCount, LIQUID_PARTICLE_COUNT);
  glDispatchCompute((LIQUID_PARTICLE_COUNT + 1023) div 1024, 1, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT or GL_TEXTURE_FETCH_BARRIER_BIT);
  glBindTexture(GL_TEXTURE_2D, FOutputTex);
  glGetTexImage(GL_TEXTURE_2D, 0, GL_BGRA, GL_UNSIGNED_BYTE, Pointer(FPixelBuffer));
  glBindTexture(GL_TEXTURE_2D, 0);
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
  ACanvas.DrawSimpleText('Skia + OpenGL 4.3 Compute | 1,000,000 Liquid Particles (Left/Right Drag)', 18, 28, Font, Paint);
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


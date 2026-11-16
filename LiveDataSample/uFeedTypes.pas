{*******************************************************************************
  uFeedTypes  -  Global Live Telemetry Command Center
********************************************************************************
  Thread-safe data structures shared between the HTTP feed threads and the
  OpenGL compute-render thread.

  The merged snapshot is what the render thread uploads into the Emitter SSBO
  each frame. The struct layout below is byte-for-byte compatible with the
  GLSL `struct Emitter { vec4 pos; vec4 extra; ;` (std430) used by the
  compute shader in uSkiaTelemetryMap:

    offset 0..3   : Lon, Lat            (degrees, current position)
    offset 4..7   : VelLon, VelLat      (degrees/sec, for GPU trail direction)
    offset 8..11  : Heading             (degrees, true track / orbital heading)
                    Magnitude           (m/s for planes, alt-km for sats,
                                         Richter for quakes)
    offset 12..15 : Kind (0/1/2 as float) and Age (seconds since last refresh)

  Velocities are pre-converted to DEGREES PER SECOND on the API thread so the
  GPU dead-reckoning math is a single `pos += vel * dt`. Per-emitter orbital
  elements for satellites are kept in a parallel TSatElement array (they
  don't fit in the 32-byte emitter slot) and propagated on the CPU each frame.

  Author: Lara Miriam Tamy Reschke / LaMitaOne
*******************************************************************************}

unit uFeedTypes;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Types;

type
  TFeedKind = (fkPlane = 0, fkSatellite = 1, fkQuake = 2);

  // 32 bytes, vec4-aligned. Matches the GLSL `struct Emitter { vec4 pos;
  // vec4 extra; };` declaration. Kind is stored as a Single so the shader can
  // branch on it without an int cast.
  PLiveEmitter = ^TLiveEmitter;
  TLiveEmitter = packed record
    Lon: Single;        // degrees, -180..+180
    Lat: Single;        // degrees, -85..+85
    VelLon: Single;     // degrees/sec
    VelLat: Single;     // degrees/sec
    Heading: Single;    // degrees
    Magnitude: Single;  // units depend on Kind
    Kind: Single;       // 0=plane, 1=satellite, 2=quake
    Age: Single;        // seconds since the API last refreshed this emitter
  end;
  TLiveEmitterArray = array of TLiveEmitter;

  // Orbital elements for one satellite. Held alongside the emitter snapshot
  // so the render thread can propagate the sub-satellite point on the CPU
  // each frame without re-hitting the API.
  PSatElement = ^TSatElement;
  TSatElement = packed record
    SemimajorAxisKm: Double;
    Eccentricity: Double;
    InclinationRad: Double;
    RAANRad: Double;
    ArgPerRad: Double;
    MeanAnomRad: Double;
    EpochJ2000Days: Double;   // TLE epoch in days since 2000-01-01 12:00 UTC
  end;
  TSatElementArray = array of TSatElement;

  // Locked container holding the latest snapshot of every feed. Each HTTP
  // thread calls ReplaceKind() / ReplaceSatElements() when its data arrives;
  // the render thread calls CopySnapshot() once per frame. The lock is held
  // only for the duration of the array copy, never during HTTP I/O.
  TFeedSnapshot = class
  private
    FLock: TCriticalSection;
    FPlanes: TLiveEmitterArray;
    FQuakes: TLiveEmitterArray;
    FSatElements: TSatElementArray;
    FPlaneStamp: TDateTime;
    FQuakeStamp: TDateTime;
    FSatStamp: TDateTime;
    FPlaneOK: Boolean;
    FQuakeOK: Boolean;
    FSatOK: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    // Push a fresh slice. AKind = fkSatellite is rejected — satellites are
    // pushed via ReplaceSatElements() because their per-frame propagation
    // needs the orbital elements, not a frozen lat/lon.
    procedure ReplaceKind(AKind: TFeedKind;
      const AData: TLiveEmitterArray; AOK: Boolean);
    procedure ReplaceSatElements(const AElements: TSatElementArray; AOK: Boolean);

    // Pull a merged snapshot. ADest is grown as needed and never shrunk, so
    // repeated calls don't thrash the heap. The out flags report whether the
    // last fetch of each feed succeeded (so the HUD can show "stale" status).
    function CopySnapshot(out ADest: TLiveEmitterArray;
                          out ASatElements: TSatElementArray;
                          out APlanes, ASats, AQuakes: Integer;
                          out APlaneOK, ASatOK, AQuakeOK: Boolean): Boolean;
  end;

implementation

{ TFeedSnapshot }

constructor TFeedSnapshot.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
end;

destructor TFeedSnapshot.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TFeedSnapshot.ReplaceKind(AKind: TFeedKind;
  const AData: TLiveEmitterArray; AOK: Boolean);
begin
  FLock.Acquire;
  try
    case AKind of
      fkPlane:
        begin
          FPlanes := AData;
          FPlaneStamp := Now;
          FPlaneOK := AOK;
        end;
      fkQuake:
        begin
          FQuakes := AData;
          FQuakeStamp := Now;
          FQuakeOK := AOK;
        end;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TFeedSnapshot.ReplaceSatElements(const AElements: TSatElementArray;
  AOK: Boolean);
begin
  FLock.Acquire;
  try
    FSatElements := AElements;
    FSatStamp := Now;
    FSatOK := AOK;
  finally
    FLock.Release;
  end;
end;

function TFeedSnapshot.CopySnapshot(out ADest: TLiveEmitterArray;
  out ASatElements: TSatElementArray;
  out APlanes, ASats, AQuakes: Integer;
  out APlaneOK, ASatOK, AQuakeOK: Boolean): Boolean;
var
  NP, NQ, NS, Total: Integer;
begin
  FLock.Acquire;
  try
    NP := Length(FPlanes);
    NQ := Length(FQuakes);
    NS := Length(FSatElements);
    APlanes := NP;
    AQuakes := NQ;
    ASats := NS;
    APlaneOK := FPlaneOK;
    AQuakeOK := FQuakeOK;
    ASatOK := FSatOK;

    // Satellites are propagated on the render thread each frame, so the merged
    // emitter array must reserve slots for them too.
    Total := NP + NS + NQ;
    if Total = 0 then
    begin
      SetLength(ADest, 0);
      SetLength(ASatElements, 0);
      Exit(False);
    end;

    if Length(ADest) < Total then
      SetLength(ADest, Total)
    else if Length(ADest) > Total then
      SetLength(ADest, Total);

    if NP > 0 then
      Move(FPlanes[0], ADest[0], NP * SizeOf(TLiveEmitter));
    // The satellite slice of ADest is filled by the render thread after it
    // propagates positions from FSatElements — leave it uninitialized here.
    if NQ > 0 then
      Move(FQuakes[0], ADest[NP + NS], NQ * SizeOf(TLiveEmitter));

    // Hand back the orbital elements so the render thread can propagate.
    if Length(ASatElements) <> NS then
      SetLength(ASatElements, NS);
    if NS > 0 then
      Move(FSatElements[0], ASatElements[0], NS * SizeOf(TSatElement));

    Result := True;
  finally
    FLock.Release;
  end;
end;

end.

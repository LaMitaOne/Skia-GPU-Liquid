{*******************************************************************************
  uLiveFeeds  -  Global Live Telemetry Command Center
********************************************************************************
  Three background HTTP polling threads. Each one pulls its live feed through
  System.Net.HttpClient on a fixed interval, decodes the JSON/GeoJSON into a
  TLiveEmitterArray, and pushes it into the shared TFeedSnapshot under a lock.
  No API key required for any of them.

  Feeds
  -----
  1. OpenSky Network /api/states/all   (every 15s)
        states[i, 5] = lon, [i, 6] = lat, [i, 9] = velocity m/s,
        [i, 10] = true_track (heading deg), [i, 7] = baro_altitude m
  2. USGS earthquake.usgs.gov GeoJSON  (every 60s)
        features[].geometry.coordinates = [lon, lat, depth km]
        features[].properties.mag       = Richter magnitude
  3. CelesTRAK GP JSON (sup-gp.php?GROUP=active&FORMAT=json)  (once at start)
        inclination, ra_of_asc_node, arg_of_pericenter, mean_anomaly,
        eccentricity, semimajor_axis, epoch

  Velocity conversion
  -------------------
  Planes report m/s over the ground; we convert to degrees-per-second of lon/lat
  using the local parallel length (cos(lat) for lon). Altitude is stored in the
  `Magnitude` slot for planes (in metres) so the trail shader can fade it.

  Satellite propagation
  ---------------------
  We keep the orbital elements and let the RENDER thread propagate the
  sub-satellite point each frame on the CPU (cheap, ~10000 elements). The feed
  thread therefore only emits a TSatElementArray.

  Error handling
  --------------
  Every fetch is wrapped in try/except. On failure the previous snapshot is
  kept (TFeedSnapshot.ReplaceKind is simply not called) and the feed's OK
  flag stays False until the next successful poll — the HUD shows a "stale"
  indicator and the GPU keeps dead-reckoning the last-known positions.

  Author: Lara Miriam Tamy Reschke / LaMitaOne
*******************************************************************************}

unit uLiveFeeds;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Types, System.Math,
  System.NetEncoding, System.Net.HttpClient, System.Net.URLClient,
  System.JSON,
  uFeedTypes;

type
  TFeedThreadBase = class(TThread)
  private
    FSnapshot: TFeedSnapshot;
    FIntervalSec: Integer;
    procedure DoFetch;
  protected
    function FetchOnce(out AOK: Boolean): Boolean; virtual; abstract;
    procedure Execute; override;
  public
    constructor Create(ASnapshot: TFeedSnapshot; AIntervalSec: Integer);
  end;

  TOpenSkyFeedThread = class(TFeedThreadBase)
  protected
    function FetchOnce(out AOK: Boolean): Boolean; override;
  end;

  TUSGSFeedThread = class(TFeedThreadBase)
  protected
    function FetchOnce(out AOK: Boolean): Boolean; override;
  end;

  TCelesTrakFeedThread = class(TFeedThreadBase)
  protected
    function FetchOnce(out AOK: Boolean): Boolean; override;
  end;

  // Helper: synchronous single-shot HTTP GET with timeout + User-Agent.
  // Returns the body as a string (UTF-8 decoded). On any failure returns ''
  // and sets AOK := False. The User-Agent matters for OpenSky, which rejects
  // requests with the default empty UA.
  function HttpGetText(const AURL: string; ATimeoutMs: Integer;
    out ABody: string; out AOK: Boolean): Boolean;

implementation

const
  DEFAULT_UA = 'GlobalTelemetryDemo/1.0 (Lara Miriam Tamy Reschke; Skia+OpenGL4.3)';

{ -- HTTP helper ------------------------------------------------------------- }

function HttpGetText(const AURL: string; ATimeoutMs: Integer;
  out ABody: string; out AOK: Boolean): Boolean;
var
  Client: THTTPClient;
  Resp: IHTTPResponse;
begin
  AOK := False;
  ABody := '';
  Result := False;
  Client := THTTPClient.Create;
  try
    Client.ConnectionTimeout := 8000;
    Client.ResponseTimeout := ATimeoutMs;
    Client.UserAgent := DEFAULT_UA;
    try
      Resp := Client.Get(AURL);
    except
      on E: Exception do Exit;
    end;
    if Resp = nil then Exit;
    if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
    begin
      ABody := Resp.ContentAsString(TEncoding.UTF8);
      AOK := True;
      Result := True;
    end;
  finally
    Client.Free;
  end;
end;

{ -- Earth radius for velocity conversion ------------------------------------ }
const
  EARTH_RADIUS_KM = 6371.0;

{ -- JSON null-safety helpers ------------------------------------------------ }
// OpenSky returns JSON null for any field not currently reported. Delphi
// parses JSON null as a TJSONNull instance, NOT as nil — so a bare "= nil"
// check on a TJSONValue does not catch it. These two helpers centralise the
// check and also bound-check array access, so the parser cannot AV on
// truncated state vectors.
function JsonIsNull(const V: TJSONValue): Boolean; inline;
begin
  Result := (V = nil) or (V is TJSONNull);
end;

function JsonArrNum(const A: TJSONArray; const Idx: Integer;
  const Default: Double = 0.0): Double; inline;
var
  V: TJSONValue;
begin
  Result := Default;
  if (A = nil) or (Idx < 0) or (Idx >= A.Count) then Exit;
  V := A.Items[Idx];
  if JsonIsNull(V) then Exit;
  if V is TJSONNumber then
    Result := (V as TJSONNumber).AsDouble
  else if V is TJSONString then
    Result := StrToFloatDef((V as TJSONString).Value, Default,
                            TFormatSettings.Invariant)
  else
    Result := V.AsType<Double>;
end;

{ -- TFeedThreadBase --------------------------------------------------------- }

constructor TFeedThreadBase.Create(ASnapshot: TFeedSnapshot; AIntervalSec: Integer);
begin
  inherited Create(False);
  FSnapshot := ASnapshot;
  FIntervalSec := AIntervalSec;
  FreeOnTerminate := False;
end;

procedure TFeedThreadBase.DoFetch;
var
  Dummy: Boolean;
begin
  try
    FetchOnce(Dummy);
  except
    // Swallow — the next interval will retry.
  end;
end;

procedure TFeedThreadBase.Execute;
var
  NextTick: Cardinal;
begin
  NameThreadForDebugging(ClassName);
  // First fetch immediately so the map fills up as soon as the app starts.
  DoFetch;
  while not Terminated do
  begin
    NextTick := Cardinal(FIntervalSec) * 1000;
    // Sleep in 250ms chunks so Terminate is responsive.
    while (NextTick > 0) and not Terminated do
    begin
      if NextTick > 250 then
      begin
        Sleep(250);
        Dec(NextTick, 250);
      end
      else
      begin
        Sleep(NextTick);
        NextTick := 0;
      end;
    end;
    if Terminated then Break;
    DoFetch;
  end;
end;

{ -- OpenSky planes ---------------------------------------------------------- }

function TOpenSkyFeedThread.FetchOnce(out AOK: Boolean): Boolean;
const
  URL = 'https://opensky-network.org/api/states/all';
var
  Body: string;
  Arr: TLiveEmitterArray;
  Root, States: TJSONValue;
  StateArr: TJSONArray;
  Item: TJSONArray;
  I, N: Integer;
  Lat, Lon, Vms, Track, Alt: Double;
  CosLat, MpsToDeg: Double;
  E: TLiveEmitter;
begin
  Result := False;
  AOK := False;
  if not HttpGetText(URL, 15000, Body, AOK) or (Body = '') then Exit;
  Arr := nil;
  try
    Root := TJSONObject.ParseJSONValue(Body);
    if Root = nil then Exit;
    try
      if not (Root is TJSONObject) then Exit;
      States := (Root as TJSONObject).GetValue('states');
      if (States = nil) or not (States is TJSONArray) then Exit;
      StateArr := States as TJSONArray;
      N := StateArr.Count;
      SetLength(Arr, N);
      for I := 0 to N - 1 do
      begin
        Item := StateArr.Items[I] as TJSONArray;
        // Indices per OpenSky REST spec (ICAO24, callsign, origin_country,
        // time_position, last_contact, longitude, latitude, baro_altitude,
        // on_ground, velocity, true_track, vertical_rate, ...).
        // Any field can be JSON null when not currently reported. We must
        // skip the whole aircraft if lon/lat is null — we have no position
        // to plot. Note: JSON null parses to TJSONNull, not nil, so we use
        // JsonIsNull (handles both).
        if (Item.Count < 11) or JsonIsNull(Item.Items[5]) or JsonIsNull(Item.Items[6]) then
        begin
          // Place a sentinel off-screen so the array stays aligned; the spawn
          // shader will discard it (UV outside [0,1]).
          E.Lon := 9999.0;
          E.Lat := 9999.0;
          E.VelLon := 0.0;
          E.VelLat := 0.0;
          E.Heading := 0.0;
          E.Magnitude := 0.0;
          E.Kind := Ord(fkPlane);
          E.Age := 0.0;
          Arr[I] := E;
          Continue;
        end;
        Lon := JsonArrNum(Item, 5);
        Lat := JsonArrNum(Item, 6);
        Alt   := JsonArrNum(Item, 7);
        Vms   := JsonArrNum(Item, 9);
        Track := JsonArrNum(Item, 10);

        // m/s -> degrees of lon/lat per second, split by heading.
        // 1 deg of latitude  ~ 111.32 km.
        // 1 deg of longitude ~ 111.32 * cos(lat) km.
        // Heading is the direction of motion (0 = north, 90 = east), so:
        //   dLat/dt = (V / 111320) * cos(heading)
        //   dLon/dt = (V / 111320) * sin(heading) / cos(lat)
        CosLat := Cos(DegToRad(Lat));
        if CosLat < 0.0001 then CosLat := 0.0001;
        MpsToDeg := Vms / 111320.0;
        E.Lon := Lon;
        E.Lat := Lat;
        E.VelLon := MpsToDeg * Sin(DegToRad(Track)) / CosLat;
        E.VelLat := MpsToDeg * Cos(DegToRad(Track));
        E.Heading := Track;
        E.Magnitude := Alt;          // store altitude, the shader fades with it
        E.Kind := Ord(fkPlane);
        E.Age := 0.0;
        Arr[I] := E;
      end;
    finally
      Root.Free;
    end;
    FSnapshot.ReplaceKind(fkPlane, Arr, True);
    Result := True;
  except
    // Bad JSON / network — keep the previous snapshot.
  end;
end;

{ -- USGS earthquakes -------------------------------------------------------- }

function TUSGSFeedThread.FetchOnce(out AOK: Boolean): Boolean;
const
  URL = 'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson';
var
  Body: string;
  Arr: TLiveEmitterArray;
  Root: TJSONObject;
  Features: TJSONArray;
Item, Geo: TJSONObject;
  PropV: TJSONValue;
  Coords: TJSONArray;
  MagV: TJSONValue;
  I, N: Integer;
  E: TLiveEmitter;
begin
  Result := False;
  AOK := False;
  if not HttpGetText(URL, 15000, Body, AOK) or (Body = '') then Exit;
  Arr := nil;
  try
    Root := TJSONObject.ParseJSONValue(Body) as TJSONObject;
    if Root = nil then Exit;
    try
      if not Root.TryGetValue('features', Features) or not (Features is TJSONArray) then Exit;
      N := Features.Count;
      SetLength(Arr, N);
      for I := 0 to N - 1 do
      begin
        // Pre-fill with a sentinel so any skipped feature (bad geometry / no
        // magnitude) doesn't leave uninitialized data in the array — those
        // sentinels land off-screen and the spawn shader discards them.
        E.Lon := 9999.0;
        E.Lat := 9999.0;
        E.VelLon := 0.0;
        E.VelLat := 0.0;
        E.Heading := 0.0;
        E.Magnitude := 0.0;
        E.Kind := Ord(fkQuake);
        E.Age := 0.0;
        Arr[I] := E;

        Item := Features.Items[I] as TJSONObject;
        if Item = nil then Continue;
        if JsonIsNull(Item.FindValue('geometry')) or
           not (Item.FindValue('geometry') is TJSONObject) then Continue;
        Geo := Item.FindValue('geometry') as TJSONObject;
        if JsonIsNull(Geo.FindValue('coordinates')) or
           not (Geo.FindValue('coordinates') is TJSONArray) then Continue;
        Coords := Geo.FindValue('coordinates') as TJSONArray;
        if Coords.Count < 2 then Continue;
        // GeoJSON coordinates are [lon, lat, depth], but each can still be
        // null in a malformed feature — go through JsonArrNum which treats
        // both nil and TJSONNull as "use default".
        E.Lon := JsonArrNum(Coords, 0, 9999.0);
        E.Lat := JsonArrNum(Coords, 1, 9999.0);
        // Skip features that ended up off-screen.
        if (E.Lon = 9999.0) or (E.Lat = 9999.0) then Continue;
        PropV := Item.FindValue('properties');
        if not JsonIsNull(PropV) and (PropV is TJSONObject) then
        begin
          MagV := (PropV as TJSONObject).FindValue('mag');
          if not JsonIsNull(MagV) and (MagV is TJSONNumber) then
            E.Magnitude := (MagV as TJSONNumber).AsDouble
          else
            E.Magnitude := 0.0;
        end
        else
          E.Magnitude := 0.0;
        Arr[I] := E;
      end;
    finally
      Root.Free;
    end;
    FSnapshot.ReplaceKind(fkQuake, Arr, True);
    Result := True;
  except
    // Bad JSON — keep previous snapshot.
  end;
end;

{ -- CelesTrak satellites ---------------------------------------------------- }

function TCelesTrakFeedThread.FetchOnce(out AOK: Boolean): Boolean;
const
  URL = 'https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=json';
var
  Body: string;
  Arr: TSatElementArray;
  Root, Item: TJSONObject;
  RootArr: TJSONArray;
  List: TJSONArray;
  I, N: Integer;
  El: TSatElement;
  OwnsRoot: Boolean;
  function GetD(const AObj: TJSONObject; const AName: string): Double;
  var
    V: TJSONValue;
  begin
    Result := 0.0;
    if AObj.TryGetValue(AName, V) and (V <> nil) then
      Result := V.AsType<Double>;
  end;
begin
  Result := False;
  AOK := False;
  if not HttpGetText(URL, 20000, Body, AOK) or (Body = '') then Exit;
  Arr := nil;
  // The GP JSON response can be either a top-level array of GP objects,
  // or a single GP object (if the query returned one satellite). Detect
  // both: parse once, look at the result kind.
  Root := nil;
  RootArr := TJSONObject.ParseJSONValue(Body) as TJSONArray;
  List := nil;
  OwnsRoot := False;
  try
    if RootArr <> nil then
    begin
      // Top-level array — the common case.
      List := RootArr;
      OwnsRoot := True;
    end
    else
    begin
      // Could be a single GP object. If it has OBJECT_NAME, treat it as
      // a one-element list.
      Root := TJSONObject.ParseJSONValue(Body) as TJSONObject;
      if Root = nil then Exit;
      if Assigned(Root.FindValue('OBJECT_NAME')) or
         Assigned(Root.FindValue('OBJECT_ID'))   or
         Assigned(Root.FindValue('SEMIMAJOR_AXIS')) then
      begin
        List := TJSONArray.Create;
        List.AddElement(Root);
        // List now owns Root; don't free Root separately below.
        Root := nil;
        OwnsRoot := True;   // OwnsRoot controls List.Free, not Root.Free.
      end
      else
      begin
        // Not a GP object — bail out cleanly.
        Root.Free;
        Root := nil;
        Exit;
      end;
    end;

    N := List.Count;
    if N = 0 then Exit;
    SetLength(Arr, N);
    for I := 0 to N - 1 do
    begin
      // Pre-fill with a sane default so any skipped satellite doesn't leave
      // uninitialized data in the array.
      El.SemimajorAxisKm := 7000.0;   // ~LEO default
      El.Eccentricity    := 0.0;
      El.InclinationRad  := 0.0;
      El.RAANRad         := 0.0;
      El.ArgPerRad       := 0.0;
      El.MeanAnomRad     := 0.0;
      El.EpochJ2000Days  := 0.0;
      Arr[I] := El;

      if not (List.Items[I] is TJSONObject) then Continue;
      Item := List.Items[I] as TJSONObject;
      El.SemimajorAxisKm := GetD(Item, 'SEMIMAJOR_AXIS');
      El.Eccentricity     := GetD(Item, 'ECCENTRICITY');
      El.InclinationRad   := DegToRad(GetD(Item, 'INCLINATION'));
      El.RAANRad          := DegToRad(GetD(Item, 'RA_OF_ASC_NODE'));
      El.ArgPerRad        := DegToRad(GetD(Item, 'ARG_OF_PERICENTER'));
      El.MeanAnomRad      := DegToRad(GetD(Item, 'MEAN_ANOMALY'));
      // Epoch is a string like "2026-001T12:34:56.789" in GP JSON; the
      // propagation here is a simple circular approximation, so we only
      // need the *current* mean anomaly — we recompute it from the
      // satellite's orbital period each frame on the render thread.
      // (Epoch-parsing omitted: the circular approx just propagates from
      // the current mean-anomaly at GM/r^1.5, accurate enough for a visual
      // globe. See uSkiaTelemetryMap.PropagateSatellites.)
      El.EpochJ2000Days := 0.0;
      if El.SemimajorAxisKm < 6400.0 then
        El.SemimajorAxisKm := 6400.0; // sanity: never inside Earth
      Arr[I] := El;
    end;
  finally
    if OwnsRoot then
    begin
      if Root <> nil then Root.Free;
      if List <> nil then List.Free;
    end;
  end;

  FSnapshot.ReplaceSatElements(Arr, True);
  Result := True;
end;

end.

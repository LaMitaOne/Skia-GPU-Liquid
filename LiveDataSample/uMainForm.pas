{*******************************************************************************
  uMainForm  -  Global Live Telemetry Command Center
********************************************************************************
  Top-level VCL-style FMX form. Creates the TSkiaTelemetryMap component, wires
  up the three HTTP feed threads, and provides:
    - Start / Stop buttons
    - Filter buttons (All / Planes / Sats / Quakes)
    - Particle-count ComboBox (reuses the 1M..1B ladder from uSkiaGPULiquid's
      Unit9 so the existing benchmark range transfers directly)
    - Mouse-wheel zoom routed to the GPU component
    - FPS / status HUD read from the component itself

  Author: Lara Miriam Tamy Reschke / LaMitaOne
*******************************************************************************}

unit uMainForm;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.Variants, System.Math,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.Layouts, FMX.StdCtrls, FMX.Controls.Presentation, FMX.ListBox,
  uFeedTypes, uLiveFeeds, uSkiaTelemetryMap;

type
  TMainForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; var Handled: Boolean);
    procedure FormResize(Sender: TObject);
  private
    FMap: TSkiaTelemetryMap;
    FSnapshot: TFeedSnapshot;
    FOpenSkyThread: TOpenSkyFeedThread;
    FUSGSThread: TUSGSFeedThread;
    FCelesTrakThread: TCelesTrakFeedThread;

    UILayout: TLayout;
    btnStart: TButton;
    btnStop: TButton;
    btnAll: TButton;
    btnPlanes: TButton;
    btnSats: TButton;
    btnQuakes: TButton;
    lblParticles: TLabel;
    cbParticles: TComboBox;
    FPSTimer: TTimer;
    // Parallel to cbParticles.Items: FMillionCounts[i] is the actual count
    // (in millions) for the i-th dropdown entry. Int64 because the live
    // particle count can reach 1 billion.
    FMillionCounts: array of Int64;
    FLastDragPos: TPointF;
    FDrawing: Boolean;

    procedure OnStartClick(Sender: TObject);
    procedure OnStopClick(Sender: TObject);
    procedure OnAllClick(Sender: TObject);
    procedure OnPlanesClick(Sender: TObject);
    procedure OnSatsClick(Sender: TObject);
    procedure OnQuakesClick(Sender: TObject);
    procedure OnParticlesChange(Sender: TObject);
    procedure OnFPSTimer(Sender: TObject);
    procedure OnMapMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure OnMapMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Single);
    procedure OnMapMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
  public
    { Public declarations }
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}

procedure TMainForm.FormCreate(Sender: TObject);
var
  I: Integer;
begin
  Caption := 'Global Live Telemetry Command Center';
  ClientWidth := 1280;
  ClientHeight := 800;

  // ---- Top toolbar -----------------------------------------------------
  UILayout := TLayout.Create(Self);
  UILayout.Parent := Self;
  UILayout.Align := TAlignLayout.Top;
  UILayout.Height := 48;
  UILayout.HitTest := True;

  btnStart := TButton.Create(Self);
  btnStart.Parent := UILayout;
  btnStart.Text := 'Start';
  btnStart.Width := 80;
  btnStart.Height := 32;
  btnStart.Position.X := 8;
  btnStart.Position.Y := 8;
  btnStart.OnClick := OnStartClick;

  btnStop := TButton.Create(Self);
  btnStop.Parent := UILayout;
  btnStop.Text := 'Stop';
  btnStop.Width := 80;
  btnStop.Height := 32;
  btnStop.Position.X := 96;
  btnStop.Position.Y := 8;
  btnStop.OnClick := OnStopClick;

  btnAll := TButton.Create(Self);
  btnAll.Parent := UILayout;
  btnAll.Text := 'All';
  btnAll.Width := 70;
  btnAll.Height := 32;
  btnAll.Position.X := 200;
  btnAll.Position.Y := 8;
  btnAll.OnClick := OnAllClick;

  btnPlanes := TButton.Create(Self);
  btnPlanes.Parent := UILayout;
  btnPlanes.Text := 'Planes';
  btnPlanes.Width := 70;
  btnPlanes.Height := 32;
  btnPlanes.Position.X := 274;
  btnPlanes.Position.Y := 8;
  btnPlanes.OnClick := OnPlanesClick;

  btnSats := TButton.Create(Self);
  btnSats.Parent := UILayout;
  btnSats.Text := 'Sats';
  btnSats.Width := 70;
  btnSats.Height := 32;
  btnSats.Position.X := 348;
  btnSats.Position.Y := 8;
  btnSats.OnClick := OnSatsClick;

  btnQuakes := TButton.Create(Self);
  btnQuakes.Parent := UILayout;
  btnQuakes.Text := 'Quakes';
  btnQuakes.Width := 70;
  btnQuakes.Height := 32;
  btnQuakes.Position.X := 422;
  btnQuakes.Position.Y := 8;
  btnQuakes.OnClick := OnQuakesClick;

  lblParticles := TLabel.Create(Self);
  lblParticles.Parent := UILayout;
  lblParticles.Text := 'Particles:';
  lblParticles.Position.X := 520;
  lblParticles.Position.Y := 14;
  lblParticles.Width := 70;
  lblParticles.StyledSettings := [];
  lblParticles.TextSettings.Font.Size := 12;

  cbParticles := TComboBox.Create(Self);
  cbParticles.Parent := UILayout;
  cbParticles.Width := 110;
  cbParticles.Position.X := 590;
  cbParticles.Position.Y := 10;
  // 1M..20M in 1M steps, 25M..50M in 5M steps, 60M..100M in 10M steps, then
  // the big-step stress entries. Mirrors the original uSkiaGPULiquid ladder.
  for I := 1 to 20 do
  begin
    cbParticles.Items.Add(IntToStr(I) + 'M');
    SetLength(FMillionCounts, Length(FMillionCounts) + 1);
    FMillionCounts[High(FMillionCounts)] := I;
  end;
  I := 25;
  while I <= 50 do
  begin
    cbParticles.Items.Add(IntToStr(I) + 'M');
    SetLength(FMillionCounts, Length(FMillionCounts) + 1);
    FMillionCounts[High(FMillionCounts)] := I;
    Inc(I, 5);
  end;
  I := 60;
  while I <= 100 do
  begin
    cbParticles.Items.Add(IntToStr(I) + 'M');
    SetLength(FMillionCounts, Length(FMillionCounts) + 1);
    FMillionCounts[High(FMillionCounts)] := I;
    Inc(I, 10);
  end;
  for I in [125, 150, 200, 250, 500, 750, 1000] do
  begin
    if I < 1000 then
      cbParticles.Items.Add(IntToStr(I) + 'M')
    else
      cbParticles.Items.Add('1B');
    SetLength(FMillionCounts, Length(FMillionCounts) + 1);
    FMillionCounts[High(FMillionCounts)] := I;
  end;
  cbParticles.ItemIndex := 4;  // 5M default — comfortable on integrated GPUs
  cbParticles.OnChange := OnParticlesChange;

  // ---- Map (Skia + GL) -------------------------------------------------
  FSnapshot := TFeedSnapshot.Create;
  FMap := TSkiaTelemetryMap.Create(Self);
  FMap.Parent := Self;
  FMap.Align := TAlignLayout.Client;
  FMap.Margins.Rect := TRectF.Create(0, 48, 0, 0);
  FMap.HitTest := True;
  FMap.Snapshot := FSnapshot;
  FMap.TargetFPS := 60;
  FMap.ParticleCount := 5000000;  // 5M default
  FMap.FilterMask := Cardinal(fmPlanes) or Cardinal(fmSatellites) or
                     Cardinal(fmQuakes);
  FMap.OnMouseDown := OnMapMouseDown;
  FMap.OnMouseMove := OnMapMouseMove;
  FMap.OnMouseUp := OnMapMouseUp;

  // ---- Background feed threads ----------------------------------------
  // Created suspended — started by OnStartClick so the GL context is ready
  // first. CelesTrak is the slowest (10k satellites, ~1 MB JSON), so it
  // starts immediately and re-fetches once per session.
  FOpenSkyThread := TOpenSkyFeedThread.Create(FSnapshot, 15);
  FUSGSThread := TUSGSFeedThread.Create(FSnapshot, 60);
  FCelesTrakThread := TCelesTrakFeedThread.Create(FSnapshot, 3600);

  // ---- Status timer ----------------------------------------------------
  FPSTimer := TTimer.Create(Self);
  FPSTimer.Interval := 500;
  FPSTimer.OnTimer := OnFPSTimer;
  FPSTimer.Enabled := True;

  // Auto-start so the user sees the globe fill up immediately.
  OnStartClick(Self);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  if Assigned(FOpenSkyThread) then
  begin
    FOpenSkyThread.Terminate;
    FOpenSkyThread.WaitFor;
    FOpenSkyThread.Free;
  end;
  if Assigned(FUSGSThread) then
  begin
    FUSGSThread.Terminate;
    FUSGSThread.WaitFor;
    FUSGSThread.Free;
  end;
  if Assigned(FCelesTrakThread) then
  begin
    FCelesTrakThread.Terminate;
    FCelesTrakThread.WaitFor;
    FCelesTrakThread.Free;
  end;
  FSnapshot.Free;
end;

procedure TMainForm.OnStartClick(Sender: TObject);
begin
  if Assigned(FMap) then
    FMap.Active := True;
  // Threads auto-start on construction; if we ever want to pause them
  // we'd add a TEvent gate. For now they run continuously while the app is up.
end;

procedure TMainForm.OnStopClick(Sender: TObject);
begin
  if Assigned(FMap) then
    FMap.Active := False;
end;

procedure TMainForm.OnAllClick(Sender: TObject);
begin
  if Assigned(FMap) then
    FMap.FilterMask := Cardinal(fmPlanes) or Cardinal(fmSatellites) or
                       Cardinal(fmQuakes);
end;

procedure TMainForm.OnPlanesClick(Sender: TObject);
begin
  if Assigned(FMap) then
    FMap.FilterMask := Cardinal(fmPlanes);
end;

procedure TMainForm.OnSatsClick(Sender: TObject);
begin
  if Assigned(FMap) then
    FMap.FilterMask := Cardinal(fmSatellites);
end;

procedure TMainForm.OnQuakesClick(Sender: TObject);
begin
  if Assigned(FMap) then
    FMap.FilterMask := Cardinal(fmQuakes);
end;

procedure TMainForm.OnParticlesChange(Sender: TObject);
var
  Idx: Integer;
begin
  if Assigned(FMap) and Assigned(cbParticles) then
  begin
    Idx := cbParticles.ItemIndex;
    if (Idx >= 0) and (Idx < Length(FMillionCounts)) then
      FMap.ParticleCount := FMillionCounts[Idx] * 1000000;
  end;
end;

procedure TMainForm.OnFPSTimer(Sender: TObject);
begin
  if Assigned(FMap) then
    Caption := Format('Telemetry  |  %d FPS  |  %s particles',
      [FMap.RealFPS, FormatFloat('#,##0', FMap.ParticleCount)]);
end;

procedure TMainForm.OnMapMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FDrawing := True;
  FLastDragPos := PointF(X, Y);
end;

procedure TMainForm.OnMapMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
begin
  if FDrawing and Assigned(FMap) then
  begin
    FMap.MouseMove(PointF(X, Y));
    FLastDragPos := PointF(X, Y);
  end;
end;

procedure TMainForm.OnMapMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FDrawing := False;
  if Assigned(FMap) then
    FMap.MouseUp;
end;

procedure TMainForm.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; var Handled: Boolean);
begin
  if Assigned(FMap) then
  begin
    FMap.MouseWheel(WheelDelta);
    Handled := True;
  end;
end;

procedure TMainForm.FormResize(Sender: TObject);
begin
  // The Skia component is client-aligned, so it handles its own resize.
  // Nothing to do here, but kept so future layout tweaks have a hook.
end;

end.

unit Unit9;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.Layouts,
  FMX.StdCtrls, FMX.Controls.Presentation, FMX.ListBox, uSkiaGPULiquid;

type
  TForm9 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FSkiaView: TSkiaGPULiquid;
    UILayout: TLayout;
    btnStart: TButton;
    btnStop: TButton;
    lblFPS: TLabel;
    cbParticles: TComboBox;
    lblParticles: TLabel;
    FPSTimer: TTimer;
    // Parallel to cbParticles.Items: FMillionCounts[i] is the actual count
    // (in millions) for the i-th dropdown entry. Lets us mix 1M / 5M / 10M /
    // 25M step sizes in the same list. Int64 because the live particle count
    // can reach 1 billion which overflows Int32 once multiplied by 1e6.
    FMillionCounts: array of Int64;
    procedure OnStartClick(Sender: TObject);
    procedure OnStopClick(Sender: TObject);
    procedure OnParticlesChange(Sender: TObject);
    procedure OnFPSTimer(Sender: TObject);
  public
    { Public-Deklarationen }
  end;

var
  Form9: TForm9;

implementation
{$R *.fmx}

procedure TForm9.FormCreate(Sender: TObject);
var
  I: Integer;
begin
  Caption := 'Skia GPU Liquid Sample';
  ClientWidth := 800;
  ClientHeight := 600;
  UILayout := TLayout.Create(Self);
  UILayout.Parent := Self;
  UILayout.Align := TAlignLayout.Top;
  UILayout.Height := 70;
  UILayout.HitTest := True;
  // 2. Create the Custom Skia Component
  FSkiaView := TSkiaGPULiquid.Create(Self);
  FSkiaView.Parent := Self;
  FSkiaView.Align := TAlignLayout.Client;
  FSkiaView.Margins.Rect := TRectF.Create(10, 10, 10, 10);
  FSkiaView.HitTest := False;
  FSkiaView.Active := False;
  // Fixed 60 FPS target - the trackbar is gone, particle count is the test knob now.
  FSkiaView.TargetFPS := 60;
  // 3. Create Start Button
  btnStart := TButton.Create(Self);
  btnStart.Parent := UILayout;
  btnStart.Text := 'Start Animation';
  btnStart.Width := 120;
  btnStart.Height := 40;
  btnStart.Position.X := 20;
  btnStart.Position.Y := 15;
  btnStart.OnClick := OnStartClick;
  // 4. Create Stop Button
  btnStop := TButton.Create(Self);
  btnStop.Parent := UILayout;
  btnStop.Text := 'Stop Animation';
  btnStop.Width := 120;
  btnStop.Height := 40;
  btnStop.Position.X := 150;
  btnStop.Position.Y := 15;
  btnStop.OnClick := OnStopClick;
  // 5. Create FPS Label
  lblFPS := TLabel.Create(Self);
  lblFPS.Parent := UILayout;
  lblFPS.Text := 'Real: 0 FPS';
  lblFPS.Position.X := 290;
  lblFPS.Position.Y := 10;
  lblFPS.Width := 200;
  lblFPS.StyledSettings := [];
  lblFPS.TextSettings.Font.Size := 12;
  // 6. Create Particle Count ComboBox
  //    1M steps 1..20, 5M steps 25..50, 10M steps 60..100. The FMillionCounts
  //    array mirrors the dropdown so OnParticlesChange can look up the actual
  //    count without any step-size branching.
  lblParticles := TLabel.Create(Self);
  lblParticles.Parent := UILayout;
  lblParticles.Text := 'Particles:';
  lblParticles.Position.X := 500;
  lblParticles.Position.Y := 10;
  lblParticles.Width := 80;
  lblParticles.StyledSettings := [];
  lblParticles.TextSettings.Font.Size := 12;
  cbParticles := TComboBox.Create(Self);
  cbParticles.Parent := UILayout;
  cbParticles.Width := 120;
  cbParticles.Position.X := 500;
  cbParticles.Position.Y := 28;
  // 1M steps from 1M to 20M
  for I := 1 to 20 do
  begin
    cbParticles.Items.Add(IntToStr(I) + 'M');
    SetLength(FMillionCounts, Length(FMillionCounts) + 1);
    FMillionCounts[High(FMillionCounts)] := I;
  end;
  // 5M steps from 25M to 50M
  I := 25;
  while I <= 50 do
  begin
    cbParticles.Items.Add(IntToStr(I) + 'M');
    SetLength(FMillionCounts, Length(FMillionCounts) + 1);
    FMillionCounts[High(FMillionCounts)] := I;
    Inc(I, 5);
  end;
  // 10M steps from 60M to 100M
  I := 60;
  while I <= 100 do
  begin
    cbParticles.Items.Add(IntToStr(I) + 'M');
    SetLength(FMillionCounts, Length(FMillionCounts) + 1);
    FMillionCounts[High(FMillionCounts)] := I;
    Inc(I, 10);
  end;
  // Large-step entries for the 1B-particle stress test.
  // 125M = past the GL_MAX_COMPUTE_WORK_GROUP_COUNT 1D limit (67M), so the
  // 2D dispatch path is exercised from here on up.
  for I in [125, 150, 200, 250, 500, 750, 1000] do
  begin
    if I < 1000 then
      cbParticles.Items.Add(IntToStr(I) + 'M')
    else
      cbParticles.Items.Add('1B');
    SetLength(FMillionCounts, Length(FMillionCounts) + 1);
    FMillionCounts[High(FMillionCounts)] := I;
  end;
  cbParticles.ItemIndex := 0; // 1M default
  cbParticles.OnChange := OnParticlesChange;
  FSkiaView.ParticleCount := 1000000;
  // 7. Create FPS Update Timer
  FPSTimer := TTimer.Create(Self);
  FPSTimer.Interval := 500;
  FPSTimer.OnTimer := OnFPSTimer;
  FPSTimer.Enabled := True;
end;

procedure TForm9.FormDestroy(Sender: TObject);
begin
  // Owned components are freed automatically
end;

procedure TForm9.OnStartClick(Sender: TObject);
begin
  if Assigned(FSkiaView) then
    FSkiaView.Active := True;
end;

procedure TForm9.OnStopClick(Sender: TObject);
begin
  if Assigned(FSkiaView) then
    FSkiaView.Active := False;
end;

procedure TForm9.OnParticlesChange(Sender: TObject);
var
  Idx: Integer;
begin
  if Assigned(FSkiaView) and Assigned(cbParticles) then
  begin
    Idx := cbParticles.ItemIndex;
    // Lookup against the parallel array: index alone is no longer enough
    // because the step size changes (1M / 5M / 10M) across the list.
    if (Idx >= 0) and (Idx < Length(FMillionCounts)) then
      FSkiaView.ParticleCount := FMillionCounts[Idx] * 1000000;
  end;
end;

procedure TForm9.OnFPSTimer(Sender: TObject);
begin
  if Assigned(FSkiaView) and Assigned(lblFPS) then
  begin
    lblFPS.Text := Format('Real: %d FPS  |  Particles: %s',
      [FSkiaView.RealFPS, FormatFloat('#,##0', FSkiaView.ParticleCount)]);
  end;
end;

end.


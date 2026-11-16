{*******************************************************************************
  GlobalTelemetry.dpr
  Global Live Telemetry Command Center — Delphi / Skia4Delphi + OpenGL 4.3

  Build target: Win64 (Release).
  Required units in the project:
    uFeedTypes.pas           thread-safe snapshot records
    uLiveFeeds.pas           OpenSky / USGS / CelesTrak HTTP polling threads
    uSkiaTelemetryMap.pas    GPU compute + Skia overlay component
    uMainForm.pas + .fmx     the form

  Author: Lara Miriam Tamy Reschke / LaMitaOne
*******************************************************************************}

program GlobalTelemetry;

uses
  System.StartUpCopy,
  FMX.Forms,
  System.SysUtils,
  uFeedTypes in 'uFeedTypes.pas',
  uLiveFeeds in 'uLiveFeeds.pas',
  uSkiaTelemetryMap in 'uSkiaTelemetryMap.pas',
  uMainForm in 'uMainForm.pas' {MainForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.

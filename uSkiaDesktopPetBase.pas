{*******************************************************************************
  Skia-DesktopPetBase;
********************************************************************************
  A lightweight, procedural desktop pet overlay rendered via Skia4Delphi.
*******************************************************************************}
{ Skia-DesktopPetBase; v0.2                                                    }
{ by Lara Miriam Tamy Reschke                                                  }
{                                                                              }
{------------------------------------------------------------------------------}
{
  Latest Changes:
   v 0.2:
   - Replaced PNG stream encoding with direct SkImageToBitmap (BGRA8888 + Premul)
     for zero-overhead DirtyRect UpdateLayeredWindow rendering.
   v 0.1:
   - Initial release featuring procedural Skia rendering, state machine AI,
     DirtyRect optimization, and automatic idle sleep mode.
}


unit uSkiaDesktopPetBase;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Math, Vcl.Forms, Vcl.Graphics, Vcl.Dialogs,
  System.Generics.Collections, Skia, VCL.Skia;

type
  { Particle record for vomit effects }
  TParticle = record
    Pos, Vel: TPointF;
    Life: Single;
    Color: TAlphaColor;
    Size: Single;
  end;
  { Available states for the desktop cat's state machine }
  TCatState = (csIdle, csWalking, csFreakOut, csVomiting, csSitting);
  { TSkiaDesktopPetBase }
  { A thread-safe, low-CPU desktop pet that uses Skia for high-quality rendering.
    It only redraws the specific screen area (DirtyRect) where the cat is currently active. }
  TSkiaDesktopPetBase = class
  private
    FForm: TForm;
    FBuffer: TBitmap;
    FActive: Boolean;
    FThread: TThread;
    FDirtyRect: TRect;

    FCatPos: TPointF;
    FCatVel: TPointF;
    FCatState: TCatState;
    FCatAnimPhase: Single;
    FCatLookDir: Integer;
    FCatCrouching: Boolean;
    FCatStateTimer: Double;
    FFreakTimer: Double;
    FWalkTargetX: Single; // Target X position for the current walk cycle

    FParticles: TList<TParticle>;
    FVomitTimer: Double;
    FNeedsRedraw: Boolean;

    procedure MakeClickThroughFullScreen;
    procedure UpdateLogic(DeltaTime: Double);
    procedure DrawToCanvas(const Canvas: ISkCanvas);
    procedure RenderFrame;
    procedure UpdateLayeredWindowFromBitmap(const ARect: TRect);
    procedure SafeInvalidate;
    procedure StartThread;
    procedure StopThread;

    procedure UpdateCat(DeltaTime: Double);
    procedure DrawCat(const ACanvas: ISkCanvas; const Center: TPointF; const Scale: Single; const VelX: Single);
    procedure DrawParticles(const ACanvas: ISkCanvas);
    procedure SpawnVomitParticle;
    procedure SetState(NewState: TCatState);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

implementation
{ TSkiaDesktopPetBase }

constructor TSkiaDesktopPetBase.Create;
begin
  // Setup the transparent, click-through overlay form
  FForm := TForm.Create(nil);
  FForm.FormStyle := fsStayOnTop;
  FForm.BorderStyle := bsNone;
  FForm.Color := clBlack;
  FForm.ClientWidth := Screen.Width;
  FForm.ClientHeight := Screen.Height;
  FForm.Left := 0;
  FForm.Top := 0;
  MakeClickThroughFullScreen;

  // Setup the internal 32-bit bitmap buffer used for LayeredWindow updates
  FBuffer := TBitmap.Create;
  FBuffer.PixelFormat := pf32bit;
  FBuffer.AlphaFormat := afDefined;
  FBuffer.SetSize(Screen.Width, Screen.Height);

  FActive := False;
  FDirtyRect := Rect(0, 0, 0, 0);

  // Initial cat state and position (Bottom left of the work area / Taskbar)
  FCatPos := TPointF.Create(Screen.WorkAreaRect.Left + 100, Screen.WorkAreaRect.Bottom);
  FCatVel := TPointF.Create(0, 0);
  FCatState := csIdle;
  FCatLookDir := 1;
  FCatAnimPhase := 0;
  FCatStateTimer := 0;
  FFreakTimer := 0;
  FVomitTimer := 0;
  FCatCrouching := False;
  FWalkTargetX := FCatPos.X;

  FParticles := TList<TParticle>.Create;
end;

destructor TSkiaDesktopPetBase.Destroy;
begin
  StopThread;
  FBuffer.Free;
  FParticles.Free;
  FForm.Free;
  inherited;
end;

procedure TSkiaDesktopPetBase.MakeClickThroughFullScreen;
begin
  // Make the form transparent to mouse clicks so the user can interact with the desktop normally
  SetWindowLong(FForm.Handle, GWL_EXSTYLE, GetWindowLong(FForm.Handle, GWL_EXSTYLE) or WS_EX_LAYERED or WS_EX_TRANSPARENT);
end;

procedure TSkiaDesktopPetBase.Start;
begin
  if FActive then
    Exit;
  FActive := True;
  FForm.Show;

  // Clear the buffer initially to make the whole screen transparent
  FBuffer.Canvas.Lock;
  try
    FBuffer.Canvas.Brush.Color := clBlack;
    FBuffer.Canvas.FillRect(Rect(0, 0, FBuffer.Width, FBuffer.Height));
  finally
    FBuffer.Canvas.Unlock;
  end;
  UpdateLayeredWindowFromBitmap(Rect(0, 0, Screen.Width, Screen.Height));

  StartThread;
end;

procedure TSkiaDesktopPetBase.Stop;
begin
  StopThread;
  if Assigned(FForm) then
    FForm.Hide;
end;

procedure TSkiaDesktopPetBase.SetState(NewState: TCatState);
begin
  FCatState := NewState;
  FCatStateTimer := 0;
  FFreakTimer := 0;
  FNeedsRedraw := True;
end;

procedure TSkiaDesktopPetBase.SpawnVomitParticle;
var
  P: TParticle;
  MouthY: Single;
begin
  // Calculate the Y coordinate of the cat's mouth based on whether it's crouching or standing
  if FCatCrouching then
    MouthY := FCatPos.Y - 10
  else
    MouthY := FCatPos.Y - 30;

  // Initialize particle properties
  P.Pos := TPointF.Create(FCatPos.X + (FCatLookDir * 30), MouthY);
  P.Vel := TPointF.Create(FCatLookDir * (100 + Random(150)), -20 - Random(80));
  P.Life := 1.0 + (Random(5) / 10.0);
  P.Color := TAlphaColors.MediumSpringGreen;
  if Random(2) = 0 then
    P.Color := TAlphaColors.YellowGreen;
  P.Size := 3.0 + Random(3);
  FParticles.Add(P);
end;

procedure TSkiaDesktopPetBase.UpdateCat(DeltaTime: Double);
var
  WorkArea: TRect;
  Margin: Integer;
  i: Integer;
  P: TParticle;
  RandVal: Integer;
  WalkDist: Single;
  MaxDistRight, MaxDistLeft: Single;
begin
  WorkArea := Screen.WorkAreaRect;
  Margin := 40; // Boundary margin to prevent clipping off-screen

  // Safety reset if the cat somehow escapes the screen bounds
  if (FCatPos.Y > Screen.Height + 100) or (FCatPos.X < -100) or (FCatPos.X > Screen.Width + 100) then
  begin
    FCatPos := TPointF.Create(WorkArea.Left + 100, WorkArea.Bottom);
    FCatLookDir := 1;
    SetState(csIdle);
  end;

  FCatAnimPhase := FCatAnimPhase + DeltaTime;
  FCatStateTimer := FCatStateTimer + DeltaTime;
  FFreakTimer := FFreakTimer + DeltaTime;

  // Handle vomit particle spawning loop
  if FCatState = csVomiting then
  begin
    FVomitTimer := FVomitTimer + DeltaTime;
    if FVomitTimer > 0.1 then
    begin
      SpawnVomitParticle;
      FVomitTimer := 0;
    end;
  end;

  // Main State Machine
  case FCatState of
    csIdle:
      begin
        FCatVel.X := 0;
        FCatCrouching := False;
        // Wait for 2-4 seconds before deciding what to do next
        if FCatStateTimer > 2.0 + Random(2) then
        begin
          RandVal := Random(10);
          if RandVal < 2 then
            SetState(csFreakOut) // 20% chance to freak out
          else if RandVal < 5 then
            SetState(csSitting)  // 30% chance to sit like a loaf
          else
          begin
            // 50% chance to walk. Calculate a random distance to walk (200 to 600 pixels)
            WalkDist := 200 + Random(400);

            // Check available space towards the current direction
            if FCatLookDir = 1 then
            begin
              MaxDistRight := (WorkArea.Right - Margin) - FCatPos.X;
              if MaxDistRight >= WalkDist then
                FWalkTargetX := FCatPos.X + WalkDist // Enough space, keep going right
              else
              begin
                // Not enough space, turn around and walk left
                FCatLookDir := -1;
                FWalkTargetX := FCatPos.X - WalkDist;
              end;
            end
            else
            begin
              MaxDistLeft := FCatPos.X - (WorkArea.Left + Margin);
              if MaxDistLeft >= WalkDist then
                FWalkTargetX := FCatPos.X - WalkDist // Enough space, keep going left
              else
              begin
                // Not enough space, turn around and walk right
                FCatLookDir := 1;
                FWalkTargetX := FCatPos.X + WalkDist;
              end;
            end;

            SetState(csWalking);
          end;
        end;
      end;
    csSitting:
      begin
        FCatVel.X := 0;
        FCatCrouching := False;
        // Sit for 5-10 seconds
        if FCatStateTimer > 5.0 + Random(5) then
          SetState(csIdle);
      end;
    csWalking:
      begin
        FCatVel.X := FCatLookDir * 50.0;
        FCatCrouching := False;

        // Stop walking if we reached the target X, or randomly decide to stop/vomit early
        if ((FCatLookDir = 1) and (FCatPos.X >= FWalkTargetX)) or ((FCatLookDir = -1) and (FCatPos.X <= FWalkTargetX)) then
        begin
          if Random(10) < 3 then
            SetState(csVomiting)
          else
            SetState(csIdle);
        end;
      end;
    csFreakOut:
      begin
        // Hyper speed running back and forth
        FCatVel.X := FCatLookDir * 250.0;
        FCatCrouching := False;
        FNeedsRedraw := True;

        // Change direction rapidly every 0.2 - 0.5 seconds
        if FFreakTimer > 0.2 + (Random(3) / 10.0) then
        begin
          FCatLookDir := -FCatLookDir;
          FFreakTimer := 0;
        end;

        // Freak out lasts for 2-3 seconds, then vomit
        if FCatStateTimer > 2.0 + Random(1) then
          SetState(csVomiting);
      end;
    csVomiting:
      begin
        FCatVel.X := 0;
        FCatCrouching := True; // Hunch the back
        FNeedsRedraw := True;

        // Vomit for 1.5 - 2.5 seconds
        if FCatStateTimer > 1.5 + (Random(10) / 10.0) then
          SetState(csIdle);
      end;
  end;

  // Apply horizontal movement
  FCatPos.X := FCatPos.X + (FCatVel.X * DeltaTime);
  FCatPos.Y := WorkArea.Bottom;

  // Hard wall collision checks to prevent escaping the work area
  if FCatPos.X <= WorkArea.Left + Margin then
  begin
    FCatPos.X := WorkArea.Left + Margin;
    FCatLookDir := 1;
    if FCatState = csWalking then
      SetState(csIdle); // Hit wall, stop walking
  end
  else if FCatPos.X >= WorkArea.Right - Margin then
  begin
    FCatPos.X := WorkArea.Right - Margin;
    FCatLookDir := -1;
    if FCatState = csWalking then
      SetState(csIdle); // Hit wall, stop walking
  end;

  // Update particles (applying gravity and bounce)
  for i := FParticles.Count - 1 downto 0 do
  begin
    P := FParticles[i];
    P.Vel.Y := P.Vel.Y + 1200.0 * DeltaTime; // Gravity
    P.Pos := P.Pos + P.Vel * DeltaTime;
    P.Life := P.Life - DeltaTime * 0.7;

    // Bounce off the taskbar
    if P.Pos.Y > WorkArea.Bottom - 5 then
    begin
      P.Pos.Y := WorkArea.Bottom - 5;
      P.Vel.X := P.Vel.X * 0.5; // Friction
      P.Vel.Y := -P.Vel.Y * 0.3; // Reduced bounce
    end;

    // Remove dead particles
    if P.Life <= 0 then
      FParticles.Delete(i)
    else
      FParticles[i] := P;
  end;
end;

procedure TSkiaDesktopPetBase.DrawCat(const ACanvas: ISkCanvas; const Center: TPointF; const Scale: Single; const VelX: Single);
var
  Paint, GlowPaint: ISkPaint;
  BodyRect, HeadRect: TRectF;
  TailWag, RunPhase: Single;
  TailStart, TailMid, TailEnd: TPointF;
  PB: ISkPathBuilder;
  IsSitting: Boolean;
  MousePos: TPoint;
  MouseDiffX: Single;
  EyeShift: Single;
begin
  // Setup base paint and glow effect
  Paint := TSkPaint.Create;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.AntiAlias := True;
  Paint.Color := $FF333333; // Dark gray cat
  GlowPaint := TSkPaint.Create(Paint);
  GlowPaint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 6.0);
  GlowPaint.Color := $FF00FFFF; // Cyan glow

  // Update look direction based on velocity
  if VelX < -0.5 then
    FCatLookDir := -1
  else if VelX > 0.5 then
    FCatLookDir := 1;

  if FCatLookDir = 0 then
    FCatLookDir := 1;

  IsSitting := (FCatState = csSitting);

  // --- Eye Tracking Logic ---
  // Cat's eyes follow the mouse cursor when idle, sitting, or vomiting
  GetCursorPos(MousePos);
  MouseDiffX := (MousePos.X - 20) - FCatPos.X;
  if FCatLookDir = -1 then
    MouseDiffX := -MouseDiffX; // Adjust for flipped coordinate space

  if MouseDiffX > 100 then
    MouseDiffX := 100;
  if MouseDiffX < -100 then
    MouseDiffX := -100;
  MouseDiffX := MouseDiffX / 100.0;

  if (FCatState = csWalking) or (FCatState = csFreakOut) then
    EyeShift := 2 // Look straight ahead while running
  else
    EyeShift := 2 + (MouseDiffX * 3.0); // Shift eyes based on mouse position

  // Apply canvas transformations for drawing the cat
  ACanvas.Save;
  ACanvas.Translate(Center.X, Center.Y);

  if FCatLookDir = -1 then
    ACanvas.Scale(-1, 1); // Mirror the cat if looking left

  var BodyDrop := 16.0;
  var HeadLift := -10.0;
  RunPhase := FCatAnimPhase * 15;

  // Define Body and Head rectangles based on current state
  if IsSitting then
  begin
    // "Bread Loaf" shape: Wide and flat body, head tucked in
    BodyRect := TRectF.Create(-28, BodyDrop + 12, 28, BodyDrop + 35);
    HeadRect := TRectF.Create(12, BodyDrop + 2, 32, BodyDrop + 22);
  end
  else if FCatCrouching then
  begin
    // Vomiting pose: Hunched back
    BodyRect := TRectF.Create(-20, BodyDrop + 15, 20, BodyDrop + 28);
    HeadRect := TRectF.Create(15, BodyDrop + 5, 35, BodyDrop + 25);
  end
  else
  begin
    // Standing/Running pose
    BodyRect := TRectF.Create(-18, BodyDrop, 18, BodyDrop + 18);
    if Abs(VelX) < 0.5 then
      BodyRect := TRectF.Create(-14, BodyDrop, 14, BodyDrop + 20); // Idle is slightly thinner

    var HeadXOffset := 20;
    if Abs(VelX) > 0.5 then
      HeadXOffset := 25; // Head pushed forward when running
    HeadRect := TRectF.Create(-10 + HeadXOffset, BodyDrop + HeadLift - 5, 10 + HeadXOffset, BodyDrop + HeadLift + 15);
  end;

  // Draw Body with Glow
  ACanvas.DrawOval(BodyRect, GlowPaint);
  ACanvas.DrawOval(BodyRect, Paint);

  // Draw Legs
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 3.0;
  Paint.StrokeCap := TSkStrokeCap.Round;
  var LegOffset := 0.0;
  if Abs(VelX) > 0.5 then
    LegOffset := Sin(RunPhase) * 5.0; // Running animation offset

  if IsSitting then
  begin
    // Front paws straight down
    ACanvas.DrawLine(PointF(18, BodyRect.Bottom), PointF(18, BodyRect.Bottom + 6), Paint);
    ACanvas.DrawLine(PointF(12, BodyRect.Bottom), PointF(12, BodyRect.Bottom + 6), Paint);
  end
  else if not FCatCrouching then
  begin
    // Standard 4 legs walking animation
    ACanvas.DrawLine(PointF(-14, BodyRect.Bottom), PointF(-14 + LegOffset, BodyRect.Bottom + 8), Paint);
    ACanvas.DrawLine(PointF(-10, BodyRect.Bottom), PointF(-10 - LegOffset, BodyRect.Bottom + 8), Paint);
    ACanvas.DrawLine(PointF(14, BodyRect.Bottom), PointF(14 + LegOffset, BodyRect.Bottom + 8), Paint);
    ACanvas.DrawLine(PointF(10, BodyRect.Bottom), PointF(10 - LegOffset, BodyRect.Bottom + 8), Paint);
  end
  else
  begin
    // Tucked legs while vomiting
    ACanvas.DrawLine(PointF(-10, BodyRect.Bottom - 2), PointF(-12, BodyRect.Bottom + 3), Paint);
    ACanvas.DrawLine(PointF(10, BodyRect.Bottom - 2), PointF(12, BodyRect.Bottom + 3), Paint);
  end;

  // Draw Head
  Paint.Style := TSkPaintStyle.Fill;
  ACanvas.DrawOval(HeadRect, GlowPaint);
  ACanvas.DrawOval(HeadRect, Paint);

  // Draw Ears
  PB := TSkPathBuilder.Create;
  if IsSitting then
  begin
    // Small ears poking out of the "loaf"
    PB.MoveTo(HeadRect.Left + 2, HeadRect.Top + 5);
    PB.LineTo(HeadRect.Left + 5, HeadRect.Top - 4);
    PB.LineTo(HeadRect.Left + 12, HeadRect.Top + 2);
  end
  else if FCatCrouching then
  begin
    // Ears pinned back slightly
    PB.MoveTo(HeadRect.Left + 2, HeadRect.Top + 8);
    PB.LineTo(HeadRect.Left + 4, HeadRect.Top - 2);
    PB.LineTo(HeadRect.Left + 12, HeadRect.Top + 4);
  end
  else
  begin
    // Standard alert ears
    PB.MoveTo(HeadRect.Left + 2, HeadRect.Top + 5);
    PB.LineTo(HeadRect.Left + 6, HeadRect.Top - 8);
    PB.LineTo(HeadRect.Left + 10, HeadRect.Top + 5);
    PB.MoveTo(HeadRect.Right - 10, HeadRect.Top + 5);
    PB.LineTo(HeadRect.Right - 6, HeadRect.Top - 8);
    PB.LineTo(HeadRect.Right - 2, HeadRect.Top + 5);
  end;
  ACanvas.DrawPath(PB.Snapshot, Paint);

  // Draw Tail
  TailWag := Sin(FCatAnimPhase * 6) * 5.0;
  if (FCatCrouching or IsSitting) then
    TailWag := 0; // Tail rests when sitting/vomiting

  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 3.0;
  Paint.Color := $FF333333;

  if IsSitting then
  begin
    // Tail wrapped around the body
    TailStart := PointF(BodyRect.Right - 5, BodyRect.Bottom);
    TailMid := PointF(BodyRect.Right + 10, BodyRect.Bottom - 5);
    TailEnd := PointF(BodyRect.Right + 5, BodyRect.Top + 5);
  end
  else
  begin
    // Standard wagging tail
    TailStart := PointF(BodyRect.Left + 15, BodyRect.CenterPoint.Y);
    TailMid := PointF(TailStart.X - 15, BodyDrop + TailWag);
    TailEnd := PointF(TailMid.X - 5, BodyDrop - 15 + TailWag);
  end;

  PB := TSkPathBuilder.Create;
  PB.MoveTo(TailStart.X, TailStart.Y);
  PB.QuadTo(TailMid.X, TailMid.Y, TailEnd.X, TailEnd.Y);
  ACanvas.DrawPath(PB.Snapshot, Paint);

  // Draw Eyes (Always Yellow)
  Paint.Style := TSkPaintStyle.Fill;
  Paint.Color := TAlphaColors.Yellow;

  ACanvas.DrawCircle(PointF(HeadRect.CenterPoint.X - 3 + EyeShift, HeadRect.CenterPoint.Y), 3, Paint);
  ACanvas.DrawCircle(PointF(HeadRect.CenterPoint.X + 3 + EyeShift, HeadRect.CenterPoint.Y), 3, Paint);

  // Draw Pupils
  Paint.Color := TAlphaColors.Black;
  ACanvas.DrawOval(TRectF.Create(HeadRect.CenterPoint.X - 4 + EyeShift, HeadRect.CenterPoint.Y - 1.5, HeadRect.CenterPoint.X - 2 + EyeShift, HeadRect.CenterPoint.Y + 1.5), Paint);
  ACanvas.DrawOval(TRectF.Create(HeadRect.CenterPoint.X + 2 + EyeShift, HeadRect.CenterPoint.Y - 1.5, HeadRect.CenterPoint.X + 4 + EyeShift, HeadRect.CenterPoint.Y + 1.5), Paint);

  ACanvas.Restore;
end;

procedure TSkiaDesktopPetBase.DrawParticles(const ACanvas: ISkCanvas);
var
  P: TParticle;
  Paint: ISkPaint;
  AlphaVal: Integer;
begin
  if FParticles.Count = 0 then
    Exit;

  // Setup paint for particles
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.MaskFilter := nil;

  // Iterate and draw all active particles, fading them out based on Life
  for P in FParticles do
  begin
    Paint.Color := P.Color;
    AlphaVal := Round(P.Life * 180);
    if AlphaVal > 255 then
      AlphaVal := 255;
    if AlphaVal < 0 then
      AlphaVal := 0;
    Paint.Alpha := AlphaVal;
    ACanvas.DrawCircle(P.Pos, P.Size * P.Life, Paint);
  end;
end;

procedure TSkiaDesktopPetBase.UpdateLogic(DeltaTime: Double);
var
  OldCatX: Double;
  MinX, MaxX, MinY, MaxY: Double;
  P: TParticle;
begin
  OldCatX := FCatPos.X;

  UpdateCat(DeltaTime);

  // Calculate the DirtyRect (the only area of the screen that needs to be redrawn)
  MinX := Min(OldCatX, FCatPos.X) - 60;
  MaxX := Max(OldCatX, FCatPos.X) + 60;
  MinY := Screen.WorkAreaRect.Bottom - 80;
  MaxY := Screen.WorkAreaRect.Bottom + 10;

  // Expand DirtyRect to include particles
  for P in FParticles do
  begin
    MinX := Min(MinX, P.Pos.X - 20);
    MaxX := Max(MaxX, P.Pos.X + 20);
    MinY := Min(MinY, P.Pos.Y - 20);
    MaxY := Max(MaxY, P.Pos.Y + 20);
  end;

  FDirtyRect := Rect(Max(0, Trunc(MinX)), Max(0, Trunc(MinY)), Min(FBuffer.Width, Trunc(MaxX)), Min(FBuffer.Height, Trunc(MaxY)));

  // Force continuous redraw if particles are active or cat is in an active state
  if (FParticles.Count > 0) or (FCatState = csFreakOut) or (FCatState = csVomiting) then
    FNeedsRedraw := True;

  // CPU Optimization: Stop drawing entirely if the cat is resting for more than 3 seconds
  if (FCatState = csIdle) and (FParticles.Count = 0) and not FNeedsRedraw and (FCatStateTimer > 3.0) then
    FDirtyRect := Rect(0, 0, 0, 0);
end;

procedure TSkiaDesktopPetBase.DrawToCanvas(const Canvas: ISkCanvas);
var
  CatCenter: TPointF;
begin
  Canvas.Clear(TAlphaColorRec.Null);

  // Calculate the center point for drawing based on feet position
  CatCenter := TPointF.Create(FCatPos.X, FCatPos.Y - 44);

  // Draw cat first, then particles ON TOP so it looks like it's coming out of the mouth
  DrawCat(Canvas, CatCenter, 1.0, FCatVel.X);
  DrawParticles(Canvas);

  FNeedsRedraw := False;
end;

procedure TSkiaDesktopPetBase.RenderFrame;
var
  ImgInfo: TSkImageInfo;
  Surface: ISkSurface;
  Canvas: ISkCanvas;
  SkImage: ISkImage;
  MemStream: TMemoryStream;
  W, H: Integer;
  ClearRect: TRect;
  DirtyBmp: TBitmap;
begin
  if FDirtyRect.IsEmpty then
    Exit;

  // Define the area to render based on DirtyRect
  W := FDirtyRect.Width;
  H := FDirtyRect.Height;
  ClearRect := Rect(Max(0, FDirtyRect.Left - 40), Max(0, FDirtyRect.Top - 40), Min(FBuffer.Width, FDirtyRect.Right + 40), Min(FBuffer.Height, FDirtyRect.Bottom + 40));

// Create a small Skia surface for the dirty area (explizit BGRA8888 + Premul!)
  ImgInfo := TSkImageInfo.Create(W, H, TSkColorType.BGRA8888, TSkAlphaType.Premul);
  Surface := TSkSurface.MakeRaster(ImgInfo);
  if not Assigned(Surface) then
    Exit;

  // Render the cat onto the Skia surface
  Canvas := Surface.Canvas;
  Canvas.Save;
  Canvas.Translate(-FDirtyRect.Left, -FDirtyRect.Top);
  DrawToCanvas(Canvas);
  Canvas.Restore;

  // Export the Skia surface to a temporary VCL Bitmap without PNG roundtrip
  SkImage := Surface.MakeImageSnapshot;
  if Assigned(SkImage) then
  begin
    DirtyBmp := SkImageToBitmap(SkImage);
    try
      FBuffer.Canvas.Lock;
      try
        FBuffer.Canvas.Brush.Color := clBlack;
        FBuffer.Canvas.FillRect(ClearRect); // Clear previous frame
        FBuffer.Canvas.Draw(FDirtyRect.Left, FDirtyRect.Top, DirtyBmp);
      finally
        FBuffer.Canvas.Unlock;
      end;
    finally
      DirtyBmp.Free;
    end;

    // Push the updated buffer area to the Windows Layered Window
    UpdateLayeredWindowFromBitmap(ClearRect);
  end;

  FDirtyRect := Rect(0, 0, 0, 0);
end;

procedure TSkiaDesktopPetBase.UpdateLayeredWindowFromBitmap(const ARect: TRect);
var
  ScreenDC, MemDC: HDC;
  BlendFunc: TBlendFunction;
  PtSrc, PtDest: TPoint;
  Size: TSize;
  OldBitmap: HBITMAP;
begin
  // WinAPI call to update a specific region of the transparent click-through form
  ScreenDC := GetDC(0);
  try
    MemDC := CreateCompatibleDC(ScreenDC);
    try
      OldBitmap := SelectObject(MemDC, FBuffer.Handle);
      PtDest := Point(ARect.Left, ARect.Top);
      Size.cx := ARect.Width;
      Size.cy := ARect.Height;
      PtSrc := Point(ARect.Left, ARect.Top);
      BlendFunc.BlendOp := AC_SRC_OVER;
      BlendFunc.BlendFlags := 0;
      BlendFunc.SourceConstantAlpha := 255;
      BlendFunc.AlphaFormat := AC_SRC_ALPHA;
      UpdateLayeredWindow(FForm.Handle, ScreenDC, @PtDest, @Size, MemDC, @PtSrc, 0, @BlendFunc, ULW_ALPHA);
      SelectObject(MemDC, OldBitmap);
    finally
      DeleteDC(MemDC);
    end;
  finally
    ReleaseDC(0, ScreenDC);
  end;
end;

procedure TSkiaDesktopPetBase.SafeInvalidate;
begin
  // Thread-safe UI invalidation
  TThread.Queue(nil,
    procedure
    begin
      if FActive and Assigned(FForm) and not (csDestroying in FForm.ComponentState) then
        if not FDirtyRect.IsEmpty then
          RenderFrame;
    end);
end;

procedure TSkiaDesktopPetBase.StartThread;
begin
  if Assigned(FThread) then
    Exit;
  // Start the background logic loop
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, NowTime, DeltaMS: Cardinal;
    begin
      LastTime := TThread.GetTickCount;
      while not TThread.CheckTerminated do
      begin
        if not FActive then
          Break;
        NowTime := TThread.GetTickCount;
        DeltaMS := NowTime - LastTime;
        if DeltaMS = 0 then
          DeltaMS := 1;
        LastTime := NowTime;

        UpdateLogic(DeltaMS / 1000);
        SafeInvalidate;

        Sleep(16); // Target ~60 FPS
      end;
    end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TSkiaDesktopPetBase.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50); // Give the thread time to exit gracefully
  end;
end;

end.


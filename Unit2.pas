unit Unit2;

interface
uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, uSkiaDesktopPetBase;
type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    { Private-Deklarationen }
    GlobalMCP: TSkiaDesktopPetBase;
  public
    { Public-Deklarationen }
  end;
var
  Form1: TForm1;
implementation
{$R *.dfm}
procedure TForm1.FormCreate(Sender: TObject);
begin
  GlobalMCP := TSkiaDesktopPetBase.Create;
  GlobalMCP.Start;
  Hide;
end;


procedure TForm1.FormDestroy(Sender: TObject);
begin
  if Assigned(GlobalMCP) then
    GlobalMCP.Free;
end;


end.

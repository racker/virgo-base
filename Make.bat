@ECHO off

IF NOT "x%1" == "x" GOTO :%1

:virgo
ECHO "Building virgo"
IF NOT EXIST lit.exe CALL Make.bat lit
lit.exe make
GOTO :end

:lit
ECHO "Building lit"
@powershell -NoProfile -ExecutionPolicy unrestricted -Command "iex ((new-object net.webclient).DownloadString('https://raw.githubusercontent.com/luvit/lit/a1bef9c234cf2569ded3b5c7516277c0f5746f70/web-install.ps1'))"

:test
CALL Make.bat virgo
virgo.exe
GOTO :end

:clean
IF EXIST virgo.exe DEL /F /Q virgo-base.exe
IF EXIST lit.exe DEL /F /Q lit.exe
IF EXIST lit RMDIR /S /Q lit
IF EXIST luvi-binaries RMDIR /S /Q luvi-binaries

:end


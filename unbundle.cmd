@echo off
setlocal
rem Drag Copilot's reply .txt onto this file, or double-click and type a path.
rem Rebuilds into a .\unbundled folder next to these scripts.
set "SCRIPT=%~dp0unbundle.ps1"
if "%~1"=="" (
    set /p "TARGET=Drag the reply .txt here (or type its path), then press Enter: "
) else (
    set "TARGET=%~1"
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" "%TARGET%"
echo.
pause
endlocal

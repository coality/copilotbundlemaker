@echo off
setlocal
rem Drag a project FOLDER onto this file, or double-click and type a path.
set "SCRIPT=%~dp0bundle.ps1"
if "%~1"=="" (
    set /p "TARGET=Drag a project folder here (or type its path), then press Enter: "
) else (
    set "TARGET=%~1"
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" "%TARGET%"
echo.
pause
endlocal

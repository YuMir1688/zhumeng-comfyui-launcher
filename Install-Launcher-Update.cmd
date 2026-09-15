@echo off
setlocal
cd /d "%~dp0"
if not exist ".ext\python.exe" (
  echo Extract this patch into your ComfyUI package folder first.
  pause
  exit /b 1
)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Update-Launcher.ps1" -Root "%~dp0." -LocalArchive "%~dp0zhumeng-launcher-1.3.2.zip" -LocalManifest "%~dp0launcher-update.json"
if errorlevel 1 pause

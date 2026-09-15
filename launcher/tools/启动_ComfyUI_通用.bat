@echo off
setlocal

cd /d "%~dp0.."

rem Universal launcher for NVIDIA RTX 30 / 40 / 50 series.
rem Keep backend selection automatic so ComfyUI can choose a compatible path.
set TORCHDYNAMO_DISABLE=1
set CUDA_MODULE_LOADING=LAZY
set PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
set "PATH=%~dp0sox;%~dp0..\.ext\Library\bin;%PATH%"

if not exist ".ext\python.exe" (
  echo [ERROR] Missing .ext\python.exe
  pause
  exit /b 1
)

echo.
echo [ComfyUI] Universal NVIDIA launcher
echo [ComfyUI] RTX 30 / 40 / 50 series - http://127.0.0.1:1080
echo.

".ext\python.exe" -s main.py ^
  --listen 127.0.0.1 ^
  --port 1080

echo.
echo [ComfyUI] Process exited with code %ERRORLEVEL%
pause

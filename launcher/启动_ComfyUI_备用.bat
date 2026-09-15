@echo off
setlocal
cd /d "%~dp0"

if not exist "tools\ComfyUI-Launcher.ps1" (
  echo [ERROR] 缺少 tools\ComfyUI-Launcher.ps1，整合包可能没有完整解压。
  pause
  exit /b 1
)

powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "tools\ComfyUI-Launcher.ps1"
set "launcher_exit=%errorlevel%"
if not "%launcher_exit%"=="0" (
  echo.
  echo [ERROR] 启动器异常退出，代码：%launcher_exit%
  echo 请截图本窗口，并把 user\launcher\logs\bootstrap.log 发给老师。
  pause
)
exit /b %launcher_exit%

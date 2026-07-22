@echo off
setlocal
cd /d "%~dp0"

set "SIM_ROOT=%~1"
set "BRIDGE_PROFILE=%~2"
if "%SIM_ROOT%"=="" (
  echo Usage: install_bot.bat "X-Plane 12 root path"
  echo Optional second argument: bridge profile ^(realtime or xpilot_safe^)
  echo Example: install_bot.bat "D:\X-Plane 12"
  echo Example: install_bot.bat "D:\X-Plane 12" realtime
  exit /b 1
)

if "%BRIDGE_PROFILE%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_bot.ps1" -SimulatorRoot "%SIM_ROOT%"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_bot.ps1" -SimulatorRoot "%SIM_ROOT%" -BridgeProfile "%BRIDGE_PROFILE%"
)
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo Install failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo Install finished successfully.
exit /b 0

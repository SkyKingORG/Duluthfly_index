@echo off
setlocal
cd /d "%~dp0"

set "SIM_ROOT=%~1"
if "%SIM_ROOT%"=="" (
  echo Usage: install_bot.bat "X-Plane 12 root path"
  echo Example: install_bot.bat "D:\X-Plane 12"
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_bot.ps1" -SimulatorRoot "%SIM_ROOT%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo Install failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo Install finished successfully.
exit /b 0

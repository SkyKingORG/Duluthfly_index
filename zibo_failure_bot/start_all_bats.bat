@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"

echo [start-all-bats] Launching all .bat files in "%~dp0"

for %%F in ("%~dp0*.bat") do (
  set "BAT_NAME=%%~nxF"
  if /I not "!BAT_NAME!"=="start_all_bats.bat" (
    echo [start-all-bats] Starting !BAT_NAME!
    start "%%~nF" cmd /c ""%~dp0%%~nxF""
  )
)

echo [start-all-bats] Launch requests sent.
endlocal

@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"

echo [start-all-bats] Launching release startup batch files in "%~dp0"

for %%F in (start_bot.bat start_twitch_bridge.bat start_auto_events.bat) do (
  if exist "%~dp0%%F" (
    echo [start-all-bats] Starting %%F
    start "%%~nF" cmd /c ""%~dp0%%F""
  )
)

echo [start-all-bats] Launch requests sent.
endlocal

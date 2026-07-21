@echo off
cd /d "%~dp0"
set "TWITCH_OAUTH=oauth:ambcwmt03vrl239ls7hxifcywfh90w"
set "TWITCH_BOT_NICK=OnlyPilots"
set "TWITCH_CHANNEL=#desktoppilotsociety"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_events.ps1"
pause

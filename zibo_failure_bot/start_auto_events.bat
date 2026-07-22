@echo off
cd /d "%~dp0"
if not defined TWITCH_BOT_NICK set "TWITCH_BOT_NICK=OnlyPilots"
if not defined TWITCH_CHANNEL set "TWITCH_CHANNEL=#desktoppilotsociety"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_events.ps1"
pause

@echo off
cd /d "%~dp0"
if not defined TWITCH_OAUTH set "TWITCH_OAUTH=oauth:8gy2b00ynzq8wgfjmn3vvsy0c7usbj"
if not defined TWITCH_BOT_NICK set "TWITCH_BOT_NICK=OnlyPilots"
if not defined TWITCH_CHANNEL set "TWITCH_CHANNEL=#desktoppilotsociety"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_events.ps1"
pause

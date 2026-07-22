@echo off
cd /d "%~dp0"
if not defined TWITCH_OAUTH set "TWITCH_OAUTH=oauth:aad3ycu1s5rezfshbwxb3f1v5grlxm"
if not defined TWITCH_BOT_NICK set "TWITCH_BOT_NICK=desktoppilotsociety"
if not defined TWITCH_CHANNEL set "TWITCH_CHANNEL=#desktoppilotsociety"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_events.ps1"
pause

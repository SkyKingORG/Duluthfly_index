@echo off
cd /d "%~dp0"

echo [live-mode] Enabling automatic StreamElements relay events...
set "EVENT_RELAY_ENABLED=1"

echo [live-mode] Starting main bot...
start "zibo_bot" cmd /c ""%~dp0start_bot.bat""

echo [live-mode] Waiting briefly for bot startup...
timeout /t 2 /nobreak >nul

echo [live-mode] Starting Twitch bridge for real-time chat action handling...
start "twitch_bridge" cmd /c ""%~dp0start_twitch_bridge.bat""

echo [live-mode] Started.
echo [live-mode] Bot is running with automatic StreamElements events and live Twitch chat action recognition.

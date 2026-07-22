@echo off
cd /d "%~dp0"

echo [live-mode] Starting full bot suite...
start "zibo_bot" cmd /c ""%~dp0start_bot.bat""

echo [live-mode] Started.
echo [live-mode] Bot is running with automatic StreamElements events and live Twitch chat action recognition.

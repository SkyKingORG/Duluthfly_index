@echo off
cd /d "%~dp0"
set "PROJECT_DIR=%~dp0"
if not defined TWITCH_OAUTH (
  echo TWITCH_OAUTH is not set.
  echo Set TWITCH_OAUTH in your terminal before running this script.
  echo Example ^(PowerShell^): $env:TWITCH_OAUTH = "oauth:your_token_here"
  echo Example ^(cmd^): set TWITCH_OAUTH=oauth:your_token_here
  pause
  exit /b 1
)
if defined TWITCH_OAUTH (
  set "TWITCH_OAUTH_PREFIX=%TWITCH_OAUTH:~0,6%"
  if /i not "%TWITCH_OAUTH_PREFIX%"=="oauth:" set "TWITCH_OAUTH=oauth:%TWITCH_OAUTH%"
  set "TWITCH_OAUTH_PREFIX="
)
set "LUA_CMD="
if defined LUA (
  set "LUA_CMD=%LUA%"
  if exist "%LUA%\lua.exe" set "LUA_CMD=%LUA%\lua.exe"
  if exist "%LUA%\lua5.1.exe" set "LUA_CMD=%LUA%\lua5.1.exe"
  if exist "%LUA%\lua5.2.exe" set "LUA_CMD=%LUA%\lua5.2.exe"
  if exist "%LUA%\lua5.3.exe" set "LUA_CMD=%LUA%\lua5.3.exe"
  if exist "%LUA%\lua5.4.exe" set "LUA_CMD=%LUA%\lua5.4.exe"
  if exist "%LUA%\lua5.5.exe" set "LUA_CMD=%LUA%\lua5.5.exe"
) else if defined LUA_HOME (
  set "LUA_CMD=%LUA_HOME%\lua.exe"
  if not exist "%LUA_CMD%" set "LUA_CMD=%LUA_HOME%\lua5.1.exe"
  if not exist "%LUA_CMD%" set "LUA_CMD=%LUA_HOME%\lua5.2.exe"
  if not exist "%LUA_CMD%" set "LUA_CMD=%LUA_HOME%\lua5.3.exe"
  if not exist "%LUA_CMD%" set "LUA_CMD=%LUA_HOME%\lua5.4.exe"
  if not exist "%LUA_CMD%" set "LUA_CMD=%LUA_HOME%\lua5.5.exe"
) else (
  if exist "C:\Users\scott\Documents\luaforwindows-master\luaforwindows-master\files\lua5.1.exe" (
    set "LUA_CMD=C:\Users\scott\Documents\luaforwindows-master\luaforwindows-master\files\lua5.1.exe"
  ) else if exist "C:\Users\scott\Desktop\lua-5.1.5_Win64_bin\lua5.1.exe" (
    set "LUA_CMD=C:\Users\scott\Desktop\lua-5.1.5_Win64_bin\lua5.1.exe"
  ) else (
    set "LUA_CMD=lua"
  )
)

set "LOCAL_LUA_SHARE=%PROJECT_DIR%luarocks-tree\share\lua\5.1"
set "LOCAL_LUA_LIB=%PROJECT_DIR%luarocks-tree\lib\lua\5.1"

if exist "%LOCAL_LUA_SHARE%" (
  if defined LUA_PATH (
    set "LUA_PATH=%LOCAL_LUA_SHARE%\?.lua;%LOCAL_LUA_SHARE%\?\init.lua;%LUA_PATH%"
  ) else (
    set "LUA_PATH=%LOCAL_LUA_SHARE%\?.lua;%LOCAL_LUA_SHARE%\?\init.lua;;"
  )
)

if exist "%LOCAL_LUA_LIB%" (
  if defined LUA_CPATH (
    set "LUA_CPATH=%LOCAL_LUA_LIB%\?.dll;%LUA_CPATH%"
  ) else (
    set "LUA_CPATH=%LOCAL_LUA_LIB%\?.dll;;"
  )
)

if /i "%LUA_CMD%"=="lua" (
  where lua >nul 2>&1
  if errorlevel 1 (
    echo Lua is not installed or not on PATH.
    echo Install Lua and LuaSocket first.
    echo Or set LUA to the full path of a Lua executable, or set LUA_HOME to your Lua install folder.
    pause
    exit /b 1
  )
) else (
  if not exist "%LUA_CMD%" (
    echo Lua executable not found at "%LUA_CMD%"
    echo Set LUA to the full path of a Lua executable, or set LUA_HOME to your Lua install folder.
    echo Valid executable names include lua.exe and lua5.1.exe.
    pause
    exit /b 1
  )
)

"%LUA_CMD%" twitch_event_bridge.lua
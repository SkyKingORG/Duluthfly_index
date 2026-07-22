# Zibo Twitch Failure Bot

This package creates a lightweight Lua-based bot that can:

- listen for Twitch chat commands when IRC is enabled,
- relay Twitch IRC events into the failure bot with a standalone bridge,
- accept webhook-style events from StreamElements and Streamlabs,
- apply themed Zibo failure severity events,
- send a structured payload to X-Plane 12,
- write a JSON state file consumed by a browser gauge dashboard.

## What it does

- Every event increases overall failure severity.
- Events are mapped to a Zibo failure profile such as engine, hydraulics, avionics, electrical, and airframe.
- The dashboard displays each failure as a gauge so the stream audience can see the current situation live.

## Setup

1. Install Lua and add it to your system `PATH`, or define one of these environment variables:
   - `LUA` -> full path to `lua.exe`
   - `LUA_HOME` -> Lua installation folder containing `lua.exe`
2. Install LuaSocket for your Lua runtime.
3. Place the files in a folder that is easy to run from a local machine.
4. Edit the configuration block at the top of [zibo_failure_bot.lua](zibo_failure_bot.lua) for:
   - your Twitch bot credentials,
   - the X-Plane 12 host/port,
   - the StreamElements and Streamlabs webhook paths.
  - Recommended: set Twitch values via environment variables so secrets are not stored in source files:
    - `TWITCH_OAUTH` (required when Twitch is enabled)
    - `TWITCH_CLIENT_ID` (optional, needed for Twitch API calls)
    - `TWITCH_BOT_NICK` (optional)
    - `TWITCH_CHANNEL` (optional)
    - `TWITCH_IRC_SERVER` (optional)
    - `TWITCH_IRC_PORT` (optional)
5. Start the script with `start_bot.bat`.
6. Open [dashboard.html](dashboard.html) in a browser.

If `TWITCH_OAUTH` is not set, `start_bot.bat` starts the bot with Twitch IRC disabled while keeping StreamElements and Streamlabs webhook endpoints enabled.

`start_bot.bat` now does a clean startup sequence automatically:

- stops previous bot operations,
- resets bot state to zero faults/events,
- starts the Twitch bridge,
- starts the automatic event generator,
- starts the main Lua bot.

You can skip helper process startup when needed:

- set `SKIP_TWITCH_BRIDGE=1` to skip starting `start_twitch_bridge.bat`
- set `SKIP_AUTO_EVENTS=1` to skip starting `start_auto_events.bat`

For release use, do not ship a real Twitch OAuth token inside these scripts. Set `TWITCH_OAUTH` in the runtime environment instead.

You can generate a Twitch OAuth token at https://antiscuff.com/oauth/ and then set it as `TWITCH_OAUTH`.

## Automatic install into X-Plane folders

Use the installer to automatically place files into the simulator tree:

- Host-side bot files are copied to `X-Plane 12\\Tools\\ZiboFailureBot`.
- The real-time FlyWithLua bridge from [xplane_bridge_realtime.lua](xplane_bridge_realtime.lua) is installed into the FlyWithLua `Scripts` folder as the active bridge script.

PowerShell:

- `./install_bot.ps1 -SimulatorRoot "D:\\X-Plane 12"`
- `./install_bot.ps1 -SimulatorRoot "D:\\X-Plane 12" -BridgeProfile realtime`
- `./install_bot.ps1 -SimulatorRoot "D:\\X-Plane 12" -BridgeProfile xpilot_safe`

Command Prompt:

- `install_bot.bat "D:\\X-Plane 12"`
- `install_bot.bat "D:\\X-Plane 12" realtime`
- `install_bot.bat "D:\\X-Plane 12" xpilot_safe`

Optional preview (no file changes):

- `./install_bot.ps1 -SimulatorRoot "D:\\X-Plane 12" -DryRun`

Bridge profile options:

- `realtime` (default) -> installs [xplane_bridge_realtime.lua](xplane_bridge_realtime.lua) as the active FlyWithLua bridge
- `xpilot_safe` -> installs [xplane_bridge_xpilot_safe.lua](xplane_bridge_xpilot_safe.lua) as the active FlyWithLua bridge

After install, the recommended all-in-one launcher is `Tools\\ZiboFailureBot\\start_live_mode.bat`.
You can still launch `Tools\\ZiboFailureBot\\start_bot.bat` and `Tools\\ZiboFailureBot\\start_twitch_bridge.bat` separately if you want manual control.

## Twitch event bridge

Use [twitch_event_bridge.lua](twitch_event_bridge.lua) when you want Twitch-native IRC events to trigger failures in the standalone bot.

What it forwards into the bot:

- raids,
- bits / cheers,
- new subs,
- re-subs,
- Prime subs,
- gifted subs / community gift bombs,
- synthetic tip events using a chat command.

It can also control local bot lifecycle from Twitch chat for moderators/broadcaster:

- `!startbot` -> starts the local bot process
- `!resetbot` -> resets the bot back to 0 faults and 0 events
- `!stopbot` -> stops all local bot operations

By default, these commands are only accepted in `TWITCH_STARTBOT_CHANNEL`.
When a viewer-triggered Twitch event is forwarded successfully, the bridge also posts a confirmation message back into Twitch chat.

Environment variables used by the bridge:

- `TWITCH_OAUTH` -> required Twitch IRC OAuth token
- `TWITCH_CLIENT_ID` -> optional Twitch app client ID for API calls
- `TWITCH_BOT_NICK` -> bot/login nick
- `TWITCH_CHANNEL` -> channel to join, for example `#yourchannel`
- `TWITCH_IRC_SERVER` -> optional, defaults to `irc.chat.twitch.tv`
- `TWITCH_IRC_PORT` -> optional, defaults to `6667`
- `FAILURE_BOT_HOST` -> local failure bot host, defaults to `127.0.0.1`
- `FAILURE_BOT_PORT` -> local failure bot port, defaults to `6100`
- `FAILURE_BOT_ENDPOINT` -> local bot endpoint, defaults to `/streamelements`
- `TWITCH_TIP_COMMAND` -> synthetic tip chat command, defaults to `!tip`
- `TWITCH_STARTBOT_COMMAND` -> remote start command, defaults to `!startbot`
- `TWITCH_RESETBOT_COMMAND` -> remote reset command, defaults to `!resetbot`
- `TWITCH_STOPBOT_COMMAND` -> remote stop command, defaults to `!stopbot`
- `TWITCH_STARTBOT_CHANNEL` -> only this channel may use the start command, defaults to `#desktoppilotsociety`
- `TWITCH_STARTBOT_SCRIPT` -> local script name to launch, defaults to `start_bot.bat`
- `TWITCH_STOPBOT_SCRIPT` -> local stop script name, defaults to `stop_bot_operations.ps1`
- `TWITCH_CHAT_RESPONSES` -> set to `0` to disable Twitch chat confirmations, defaults to enabled

Example run:

- PowerShell:
  - `& $env:LUA .\twitch_event_bridge.lua`
  - `./start_twitch_bridge.bat`

Recommended startup order:

- start the main local bot with `start_bot.bat`
- then start the Twitch relay with `start_twitch_bridge.bat`
- or use `start_live_mode.bat` to launch the bot, auto-event generator, and Twitch bridge together

Notes:

- Twitch IRC does not provide native donation / tip events. The bridge supports a synthetic tip command like `!tip 5` so chat automation can still trigger the bot's tip failure path.
- The bridge reuses the existing local bot HTTP endpoint so you do not need to change [zibo_failure_bot.lua](zibo_failure_bot.lua) to receive these Twitch event types.
- `!startbot`, `!resetbot`, and `!stopbot` are restricted to moderators/broadcaster and only work in `#desktoppilotsociety` by default.
- Successful viewer-triggered Twitch actions send a chat acknowledgement so the channel can see that the event reached the bot.
- `start_twitch_bridge.bat` does not contain a fallback OAuth token. Set `TWITCH_OAUTH` in your environment before launch.

## Reset and stop scripts

Local helper scripts now included:

- `reset_bot_state.ps1` -> writes a zeroed `dashboard_state.json` and attempts a live `/admin/reset` call.
- `stop_bot_operations.ps1` -> stops all bot-related local processes (bot, Twitch bridge, auto events).

The bot also exposes local-only admin endpoints used by the bridge/scripts:

- `POST /admin/reset` -> reset live bot state to zero
- `POST /admin/stop` -> stop the running bot loop

These admin endpoints only accept localhost callers.

## Quick ops (PowerShell)

Run from the project folder:

```powershell
Set-Location "C:\Users\scott\Documents\Duluthfly_index\zibo_failure_bot"
```

Start full suite (bot + Twitch bridge + auto-events):

```powershell
.\start_bot.bat
```

Start bot only (skip bridge and auto-events):

```powershell
$env:SKIP_TWITCH_BRIDGE = "1"
$env:SKIP_AUTO_EVENTS = "1"
.\start_bot.bat
```

Reset live bot to 0 faults / 0 events:

```powershell
Invoke-RestMethod -Uri "http://127.0.0.1:6100/admin/reset" -Method Post -ContentType "application/json" -Body "{}"
```

Stop all bot operations:

```powershell
.\stop_bot_operations.ps1
```

Health check:

```powershell
Invoke-RestMethod -Uri "http://127.0.0.1:6100/health" -Method Get
```

## Quick ops (Command Prompt)

Run from the project folder:

```bat
cd /d C:\Users\scott\Documents\Duluthfly_index\zibo_failure_bot
```

Start full suite (bot + Twitch bridge + auto-events):

```bat
start_bot.bat
```

Start bot only (skip bridge and auto-events):

```bat
set SKIP_TWITCH_BRIDGE=1
set SKIP_AUTO_EVENTS=1
start_bot.bat
```

Reset live bot to 0 faults / 0 events:

```bat
powershell -NoProfile -Command "Invoke-RestMethod -Uri 'http://127.0.0.1:6100/admin/reset' -Method Post -ContentType 'application/json' -Body '{}'"
```

Stop all bot operations:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File .\stop_bot_operations.ps1
```

Health check:

```bat
powershell -NoProfile -Command "Invoke-RestMethod -Uri 'http://127.0.0.1:6100/health' -Method Get"
```

### Windows environment example

- PowerShell:
  - `$env:TWITCH_OAUTH = 'oauth:your_token_here'`
  - `$env:TWITCH_CLIENT_ID = 'your_client_id_here'`
  - `$env:LUA = 'C:\path\to\lua5.1.exe'`
  - `$env:PATH = 'C:\path\to\lua;$env:PATH'`
  - `./start_bot.bat`
- Command Prompt:
  - `set TWITCH_OAUTH=oauth:your_token_here`
  - `set TWITCH_CLIENT_ID=your_client_id_here`
  - `set LUA=C:\path\to\lua5.1.exe`
  - `set PATH=C:\path\to\lua;%PATH%`
  - `start_bot.bat`

The batch file also checks a few common local Lua install locations automatically if `LUA` or `LUA_HOME` is not defined. If none are found it falls back to whatever `lua` resolves to on `PATH`.

If `luarocks-tree\share\lua\5.1` and `luarocks-tree\lib\lua\5.1` exist, `start_bot.bat` prepends them to `LUA_PATH` and `LUA_CPATH` for project-local dependency loading.

## StreamElements / Streamlabs integration

Set your webhook endpoint to:

- StreamElements: http://your-host:6100/streamelements
- Streamlabs: http://your-host:6100/streamlabs

The bot expects a JSON body. The parser handles common event shapes for:

- raids,
- subscriptions,
- gifted subscriptions,
- tips/donations,
- bits/cheers.

## X-Plane 12 integration

This script sends a JSON payload over UDP to the host/port configured in the script. If you want a tighter in-sim bridge, replace the placeholder datarefs in the Zibo mapping table with the exact X-Plane datarefs or FlyWithLua commands you want to drive.

## Notes

- The script is intentionally opinionated and easy to customize.
- The default example uses placeholder X-Plane failure datarefs so you can adapt it to your own setup.
- If you want a more aggressive or cinematic effect, increase the weights in the config block.

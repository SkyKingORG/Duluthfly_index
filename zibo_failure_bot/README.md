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
2. Install LuaSocket and dkjson for your Lua runtime.
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

## Automatic install into X-Plane folders

Use the installer to automatically place files into the simulator tree:

- Host-side bot files are copied to `X-Plane 12\\Tools\\ZiboFailureBot`.
- The FlyWithLua bridge is copied to `X-Plane 12\\Resources\\plugins\\FlyWithLua\\Scripts\\zibo_failure_xplane_bridge.lua`.

PowerShell:

- `./install_bot.ps1 -SimulatorRoot "D:\\X-Plane 12"`

Command Prompt:

- `install_bot.bat "D:\\X-Plane 12"`

Optional preview (no file changes):

- `./install_bot.ps1 -SimulatorRoot "D:\\X-Plane 12" -DryRun`

After install, launch the bot from `Tools\\ZiboFailureBot\\start_bot.bat` and launch Twitch relay from `Tools\\ZiboFailureBot\\start_twitch_bridge.bat`.

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

It can also launch the local bot process from Twitch chat with `!startbot`.
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
- `TWITCH_STARTBOT_CHANNEL` -> only this channel may use the start command, defaults to `#desktoppilotsociety`
- `TWITCH_STARTBOT_SCRIPT` -> local script name to launch, defaults to `start_bot.bat`
- `TWITCH_CHAT_RESPONSES` -> set to `0` to disable Twitch chat confirmations, defaults to enabled

Example run:

- PowerShell:
  - `& $env:LUA .\twitch_event_bridge.lua`
  - `./start_twitch_bridge.bat`

Recommended startup order:

- start the main local bot with `start_bot.bat`
- then start the Twitch relay with `start_twitch_bridge.bat`

Notes:

- Twitch IRC does not provide native donation / tip events. The bridge supports a synthetic tip command like `!tip 5` so chat automation can still trigger the bot's tip failure path.
- The bridge reuses the existing local bot HTTP endpoint so you do not need to change [zibo_failure_bot.lua](zibo_failure_bot.lua) to receive these Twitch event types.
- `!startbot` is restricted to moderators/broadcaster and only works in `#desktoppilotsociety` by default.
- Successful viewer-triggered Twitch actions send a chat acknowledgement so the channel can see that the event reached the bot.
- `start_twitch_bridge.bat` does not contain a fallback OAuth token. Set `TWITCH_OAUTH` in your environment before launch.

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

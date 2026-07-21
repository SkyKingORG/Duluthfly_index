-- start_twitch_then_bot.lua
-- Launch order:
--   1) start_twitch_bridge.bat
--   2) start_bot.bat (in a separate window)

local function get_script_dir()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local path = src:sub(2)
    return path:match("^(.*[\\/])") or ".\\"
  end
  return ".\\"
end

local function file_exists(path)
  local fh = io.open(path, "r")
  if fh then
    fh:close()
    return true
  end
  return false
end

local function run_in_new_window(window_title, working_dir, batch_path)
  local command = string.format(
    'cmd /c start "%s" /D "%s" cmd /c ""%s""',
    window_title,
    working_dir,
    batch_path
  )
  return os.execute(command)
end

local function sleep_seconds(seconds)
  local wait = math.max(1, math.floor((tonumber(seconds) or 1) + 0.5))
  os.execute(string.format('ping -n %d 127.0.0.1 >nul', wait + 1))
end

local script_dir = get_script_dir()
local twitch_bridge_bat = script_dir .. "start_twitch_bridge.bat"
local bot_bat = script_dir .. "start_bot.bat"

if not file_exists(twitch_bridge_bat) then
  error("Missing file: " .. twitch_bridge_bat)
end

if not file_exists(bot_bat) then
  error("Missing file: " .. bot_bat)
end

print("[launcher] Starting Twitch bridge first...")
local ok_bridge = run_in_new_window("twitch_bridge", script_dir, twitch_bridge_bat)
if ok_bridge ~= true and ok_bridge ~= 0 then
  error("Failed to start Twitch bridge: " .. tostring(ok_bridge))
end

-- Give the bridge a brief head start before launching the bot.
sleep_seconds(2)

print("[launcher] Starting bot in a separate window...")
local ok_bot = run_in_new_window("zibo_failure_bot", script_dir, bot_bat)
if ok_bot ~= true and ok_bot ~= 0 then
  error("Failed to start bot: " .. tostring(ok_bot))
end

print("[launcher] Done. Twitch bridge launched first, bot launched second.")
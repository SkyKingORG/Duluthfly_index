-- xplane_bridge_realtime.lua
-- Real-time UDP bridge for X-Plane 12 / FlyWithLua.
--
-- Purpose:
-- 1) Receive bot payloads immediately (no intentional delay).
-- 2) Apply mapped aircraft failures right away.
-- 3) Use incoming severity (0.0-1.0) to scale failure intensity.
--
-- Expected payload shape from the bot:
-- {
--   "event": "subscribe",
--   "failure": "engine",
--   "severity": 0.73,
--   "details": { ... },
--   "ts": 1784700000
-- }

local function get_script_dir()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local path = src:sub(2)
    return path:match("^(.*[\\/])") or ""
  end
  return ""
end

local function load_local_lua_module(module_name)
  local base = get_script_dir()
  local file_path = base .. module_name .. ".lua"
  local chunk, load_err = loadfile(file_path)
  if not chunk then
    return nil, load_err
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, result
  end

  if result == nil then
    return package.loaded[module_name], nil
  end

  package.loaded[module_name] = result
  return result, nil
end

local function safe_require(module_name)
  local ok, mod = pcall(require, module_name)
  if ok then
    return mod
  end

  local local_mod, local_err = load_local_lua_module(module_name)
  if local_mod ~= nil then
    return local_mod
  end

  return nil, tostring(mod) .. " | local load failed: " .. tostring(local_err)
end

local socket, socket_err = safe_require("socket")

local config = {
  listen_port = 49000,
  enabled = true,
  debug = false,
  standalone_mode = false,

  -- Each mapping may include one or more targets.
  -- Severity is scaled to integer values in [min_value, max_value].
  -- Replace targets with exact Zibo-specific refs/commands if desired.
  mappings = {
    engine = {
      targets = {
        { target = "sim/operation/failures/rel_engfir0", write_mode = "int_severity", min_value = 0, max_value = 6 },
        { target = "sim/operation/failures/rel_engfir1", write_mode = "int_severity", min_value = 0, max_value = 6 },
      },
    },
    hydraulics = {
      targets = {
        { target = "sim/operation/failures/rel_hydpmp", write_mode = "int_severity", min_value = 0, max_value = 6 },
      },
    },
    avionics = {
      targets = {
        { target = "sim/operation/failures/rel_adc_comp", write_mode = "int_severity", min_value = 0, max_value = 6 },
      },
    },
    electrical = {
      targets = {
        { target = "sim/operation/failures/rel_g_generators", write_mode = "int_severity", min_value = 0, max_value = 6 },
      },
    },
    airframe = {
      targets = {
        { target = "sim/operation/failures/rel_depress", write_mode = "int_severity", min_value = 0, max_value = 6 },
      },
    },
  }
}

local udp = nil
local dataref_handle_cache = {}
local command_handle_cache = {}

local function log(msg)
  if config.debug then
    print("[xplane-bridge-rt] " .. tostring(msg))
  end
end

local function clamp(v, min_v, max_v)
  if v < min_v then return min_v end
  if v > max_v then return max_v end
  return v
end

local function round(v)
  return math.floor(v + 0.5)
end

local function parse_payload(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end

  local failure = text:match('"failure"%s*:%s*"([^"]+)"')
  if not failure then
    return nil
  end

  local severity = tonumber(text:match('"severity"%s*:%s*([%-%%d%.]+)')) or 0
  local event = text:match('"event"%s*:%s*"([^"]+)"') or "unknown"

  return {
    failure = failure,
    severity = clamp(severity, 0, 1),
    event = event,
  }
end

local function get_dataref_handle(path)
  if dataref_handle_cache[path] ~= nil then
    return dataref_handle_cache[path]
  end

  local handle = nil
  if type(XPLMFindDataRef) == "function" then
    local ok, result = pcall(XPLMFindDataRef, path)
    if ok then
      handle = result
    end
  end

  dataref_handle_cache[path] = handle
  return handle
end

local function get_command_handle(path)
  if command_handle_cache[path] ~= nil then
    return command_handle_cache[path]
  end

  local handle = nil
  if type(XPLMFindCommand) == "function" then
    local ok, result = pcall(XPLMFindCommand, path)
    if ok then
      handle = result
    end
  end

  command_handle_cache[path] = handle
  return handle
end

local function write_float(path, value)
  if type(set) == "function" then
    local ok = pcall(set, path, value)
    if ok then return true end
  end

  if type(XPLMSetDataf) == "function" then
    local handle = get_dataref_handle(path)
    if handle then
      local ok = pcall(XPLMSetDataf, handle, value)
      if ok then return true end
    end
  end

  if type(setData) == "function" then
    local ok = pcall(setData, path, value)
    if ok then return true end
  end

  return false
end

local function write_int(path, value)
  if type(set) == "function" then
    local ok = pcall(set, path, value)
    if ok then return true end
  end

  if type(XPLMSetDatai) == "function" then
    local handle = get_dataref_handle(path)
    if handle then
      local ok = pcall(XPLMSetDatai, handle, value)
      if ok then return true end
    end
  end

  if type(setData) == "function" then
    local ok = pcall(setData, path, value)
    if ok then return true end
  end

  return false
end

local function invoke_command_once(path)
  if type(command_once) == "function" then
    local ok = pcall(command_once, path)
    if ok then return true end
  end

  if type(XPLMCommandOnce) == "function" then
    local handle = get_command_handle(path)
    if handle then
      local ok = pcall(XPLMCommandOnce, handle)
      if ok then return true end
    end
  end

  return false
end

local function apply_target(target_cfg, severity)
  local path = target_cfg.target
  if not path or path == "" then
    return false
  end

  local mode = target_cfg.write_mode or "int_severity"
  if mode == "float_severity" then
    local min_v = target_cfg.min_value or 0.0
    local max_v = target_cfg.max_value or 1.0
    local value = min_v + (max_v - min_v) * severity
    return write_float(path, value)
  end

  if mode == "int_severity" then
    local min_v = target_cfg.min_value or 0
    local max_v = target_cfg.max_value or 6
    local value = round(min_v + (max_v - min_v) * severity)
    value = clamp(value, min_v, max_v)
    return write_int(path, value)
  end

  if mode == "int" then
    local value = target_cfg.value
    if value == nil then
      local active_value = target_cfg.active_value or 1
      local inactive_value = target_cfg.inactive_value or 0
      local threshold = target_cfg.threshold or 0
      value = severity > threshold and active_value or inactive_value
    end
    return write_int(path, round(tonumber(value) or 0))
  end

  if mode == "float" then
    local value = target_cfg.value
    if value == nil then
      local active_value = target_cfg.active_value or 1.0
      local inactive_value = target_cfg.inactive_value or 0.0
      local threshold = target_cfg.threshold or 0
      value = severity > threshold and active_value or inactive_value
    end
    return write_float(path, tonumber(value) or 0)
  end

  if mode == "command_once" then
    local threshold = target_cfg.threshold or 0
    if severity > threshold then
      return invoke_command_once(path)
    end
    return true
  end

  return false
end

local function apply_payload(payload)
  local mapping = config.mappings[payload.failure]
  if not mapping then
    log("no mapping for failure: " .. tostring(payload.failure))
    return
  end

  local targets = mapping.targets or {}
  local success_count = 0
  for i = 1, #targets do
    if apply_target(targets[i], payload.severity) then
      success_count = success_count + 1
    end
  end

  if success_count == 0 then
    log("no target write succeeded for failure: " .. tostring(payload.failure))
    return
  end

  log(string.format("applied event=%s failure=%s severity=%.2f targets=%d", tostring(payload.event), tostring(payload.failure), payload.severity, success_count))
end

local function poll_udp_realtime()
  if not udp or not config.enabled then
    return
  end

  while true do
    local packet, err = udp:receive()
    if not packet then
      if err and err ~= "timeout" then
        log("udp receive error: " .. tostring(err))
      end
      break
    end

    local payload = parse_payload(packet)
    if payload then
      apply_payload(payload)
    end
  end
end

local function init_udp()
  if not socket then
    print("[xplane-bridge-rt] LuaSocket not available: " .. tostring(socket_err))
    return false
  end

  local sock, err = socket.udp()
  if not sock then
    print("[xplane-bridge-rt] udp create failed: " .. tostring(err))
    return false
  end

  local ok, bind_err = sock:setsockname("*", config.listen_port)
  if not ok then
    print("[xplane-bridge-rt] udp bind failed: " .. tostring(bind_err))
    return false
  end

  sock:settimeout(0)
  udp = sock
  print("[xplane-bridge-rt] listening on UDP port " .. tostring(config.listen_port))
  return true
end

local function main()
  if not init_udp() then
    return
  end

  if type(do_every_frame) == "function" then
    _G.xplane_bridge_realtime_poll = poll_udp_realtime
    do_every_frame("xplane_bridge_realtime_poll()")
    print("[xplane-bridge-rt] registered FlyWithLua frame callback")
    return
  end

  if config.standalone_mode then
    while true do
      poll_udp_realtime()
      socket.sleep(0.005)
    end
  else
    print("[xplane-bridge-rt] do_every_frame unavailable. Set standalone_mode=true for standalone mode.")
  end
end

main()

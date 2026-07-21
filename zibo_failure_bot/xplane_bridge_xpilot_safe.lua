-- xplane_bridge_xpilot_safe.lua
-- FlyWithLua bridge designed to coexist with xPilot with minimal frame impact.
--
-- Safety/performance strategy:
-- 1) Non-blocking UDP socket.
-- 2) Hard cap on packets processed per frame.
-- 3) Hard CPU time budget per frame.
-- 4) Rate-limited writes to datarefs/commands.
-- 5) Duplicate-value suppression to avoid redundant writes.

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

local perf_profiles = {
  standard = {
    max_packets_per_frame = 2,
    max_frame_cpu_seconds = 0.0015,
    min_write_interval_seconds = 0.05,
  },
  ultra_safe = {
    max_packets_per_frame = 1,
    max_frame_cpu_seconds = 0.0010,
    min_write_interval_seconds = 0.10,
  },
}

local profile_name = tostring(os.getenv("XPLANE_BRIDGE_PROFILE") or "standard"):lower()
local selected_profile = perf_profiles[profile_name]
if not selected_profile then
  profile_name = "standard"
  selected_profile = perf_profiles.standard
end

local config = {
  listen_port = 49000,
  enabled = true,
  debug = false,

  -- Choose performance profile with XPLANE_BRIDGE_PROFILE:
  -- "standard" (default) or "ultra_safe".
  max_packets_per_frame = selected_profile.max_packets_per_frame,
  max_frame_cpu_seconds = selected_profile.max_frame_cpu_seconds,
  min_write_interval_seconds = selected_profile.min_write_interval_seconds,

  -- If you run this outside FlyWithLua, set true.
  standalone_mode = false,

  mappings = {
    engine = {
      target = "sim/operation/failures/rel_engfir1",
      write_mode = "int",
      threshold = 0.0,
      active_value = 6,
      inactive_value = 0,
    },
    hydraulics = {
      target = "sim/operation/failures/rel_hyd1",
      write_mode = "int",
      threshold = 0.0,
      active_value = 6,
      inactive_value = 0,
    },
    avionics = {
      target = "sim/operation/failures/rel_avionics",
      write_mode = "int",
      threshold = 0.0,
      active_value = 6,
      inactive_value = 0,
    },
    electrical = {
      target = "sim/operation/failures/rel_elec",
      write_mode = "int",
      threshold = 0.0,
      active_value = 6,
      inactive_value = 0,
    },
    airframe = {
      target = "sim/operation/failures/rel_structure",
      write_mode = "int",
      threshold = 0.0,
      active_value = 6,
      inactive_value = 0,
    },
  }
}

local udp = nil
local startup_blocker = nil
local dataref_handle_cache = {}
local command_handle_cache = {}
local last_write_time_by_target = {}
local last_value_by_target = {}
local last_command_active_by_target = {}

local function log(msg)
  if config.debug then
    print("[xplane-bridge-safe] " .. tostring(msg))
  end
end

local function now_seconds()
  if socket and type(socket.gettime) == "function" then
    return socket.gettime()
  end
  return os.clock()
end

local function clamp(v, min_v, max_v)
  if v < min_v then return min_v end
  if v > max_v then return max_v end
  return v
end

local function round(v)
  return math.floor(v + 0.5)
end

local function parse_payload_fast(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end

  -- Fast-path extraction; avoids full JSON decode overhead per frame.
  local failure = text:match('"failure"%s*:%s*"([^"]+)"')
  if not failure then
    return nil
  end

  local severity = tonumber(text:match('"severity"%s*:%s*([%-%%d%.]+)')) or 0
  return {
    failure = failure,
    severity = severity,
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

local function should_rate_limit(target, now_ts)
  local last_ts = last_write_time_by_target[target]
  if not last_ts then
    return false
  end
  return (now_ts - last_ts) < (config.min_write_interval_seconds or 0)
end

local function mark_write(target, value, now_ts)
  last_write_time_by_target[target] = now_ts
  last_value_by_target[target] = value
end

local function apply_mapping(mapping, severity)
  local mode = mapping.write_mode or "float"
  local target = mapping.target
  if not target or target == "" then
    return false
  end

  local now_ts = now_seconds()
  if should_rate_limit(target, now_ts) then
    return true
  end

  if mode == "float" then
    local scale = mapping.scale or 1.0
    local min_value = mapping.min_value or 0.0
    local max_value = mapping.max_value or 1.0
    local resolved = clamp((tonumber(severity) or 0) * scale, min_value, max_value)
    if last_value_by_target[target] == resolved then
      return true
    end
    local ok = write_float(target, resolved)
    if ok then
      mark_write(target, resolved, now_ts)
    end
    return ok
  end

  if mode == "int" then
    local threshold = mapping.threshold or 0.0
    local active_value = mapping.active_value or 1
    local inactive_value = mapping.inactive_value or 0
    local resolved = (tonumber(severity) or 0) > threshold and active_value or inactive_value
    if last_value_by_target[target] == resolved then
      return true
    end
    local ok = write_int(target, resolved)
    if ok then
      mark_write(target, resolved, now_ts)
    end
    return ok
  end

  if mode == "int_scale" then
    local scale = mapping.scale or 1.0
    local min_value = mapping.min_value or 0
    local max_value = mapping.max_value or 1
    local resolved = clamp(round((tonumber(severity) or 0) * scale), min_value, max_value)
    if last_value_by_target[target] == resolved then
      return true
    end
    local ok = write_int(target, resolved)
    if ok then
      mark_write(target, resolved, now_ts)
    end
    return ok
  end

  if mode == "command_once" then
    local threshold = mapping.threshold or 0.0
    local active = (tonumber(severity) or 0) > threshold
    local was_active = last_command_active_by_target[target] == true
    last_command_active_by_target[target] = active

    if active and not was_active then
      local ok = invoke_command_once(target)
      if ok then
        last_write_time_by_target[target] = now_ts
      end
      return ok
    end

    return true
  end

  return false
end

local function handle_payload(payload)
  local mapping = config.mappings[payload.failure]
  if not mapping then
    return
  end

  local ok = apply_mapping(mapping, payload.severity)
  if not ok then
    log("apply failed for " .. tostring(payload.failure))
  end
end

local function poll_udp_budgeted()
  if not udp or not config.enabled then
    return
  end

  local frame_start = now_seconds()
  local max_packets = math.max(1, tonumber(config.max_packets_per_frame) or 1)
  local frame_budget = tonumber(config.max_frame_cpu_seconds) or 0.0015

  local processed = 0
  while processed < max_packets do
    if (now_seconds() - frame_start) >= frame_budget then
      break
    end

    local data = udp:receive()
    if not data then
      break
    end

    local payload = parse_payload_fast(data)
    if payload then
      handle_payload(payload)
    end

    processed = processed + 1
  end
end

local function init_udp()
  if not socket then
    startup_blocker = "LuaSocket not available: " .. tostring(socket_err)
    return false
  end

  local sock, err = socket.udp()
  if not sock then
    startup_blocker = "udp create failed: " .. tostring(err)
    return false
  end

  local bind_ok, bind_err = sock:setsockname("*", config.listen_port)
  if not bind_ok then
    startup_blocker = "udp bind failed: " .. tostring(bind_err)
    return false
  end

  sock:settimeout(0)
  udp = sock
  return true
end

local function main()
  if not init_udp() then
    print("[xplane-bridge-safe] disabled: " .. tostring(startup_blocker))
    return
  end

  if type(do_every_frame) == "function" then
    _G.xplane_bridge_xpilot_safe_poll = poll_udp_budgeted
    do_every_frame("xplane_bridge_xpilot_safe_poll()")
    print("[xplane-bridge-safe] active on UDP " .. tostring(config.listen_port) .. " (profile=" .. profile_name .. ")")
    return
  end

  if config.standalone_mode then
    while true do
      poll_udp_budgeted()
      socket.sleep(0.02)
    end
  else
    print("[xplane-bridge-safe] do_every_frame unavailable; set standalone_mode=true to run standalone")
  end
end

main()
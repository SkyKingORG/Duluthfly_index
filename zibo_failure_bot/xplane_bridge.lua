-- xplane_bridge.lua
-- Bridge between the standalone failure bot UDP payload and X-Plane 12.
--
-- Works in two modes:
-- 1) FlyWithLua mode: non-blocking poll via do_every_frame.
-- 2) Standalone Lua mode: blocking loop.
--
-- Important:
-- The mapping table below uses generic X-Plane placeholder failure refs. The
-- write modes are now explicit (`int`, `float`, `command_once`) so the bridge
-- behaves correctly for X-Plane 12, but you should still replace the targets
-- with the exact Zibo-specific refs or commands you want to drive.

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

local function make_json()
  local json = {}
  local json_null = setmetatable({}, {
    __tojson = function() return "null" end,
  })
  json.null = json_null

  local escapes = {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  }

  local function codepoint_to_utf8(cp)
    if cp <= 0x7F then
      return string.char(cp)
    elseif cp <= 0x7FF then
      return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp <= 0xFFFF then
      return string.char(
        0xE0 + math.floor(cp / 0x1000),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40)
      )
    elseif cp <= 0x10FFFF then
      return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40)
      )
    end
    return ""
  end

  local function escape_string(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(ch)
      return escapes[ch] or string.format("\\u%04x", ch:byte())
    end) .. '"'
  end

  local function encode_value(value, stack)
    local value_type = type(value)
    if value == nil or value == json_null then
      return "null"
    elseif value_type == "string" then
      return escape_string(value)
    elseif value_type == "number" then
      return tostring(value)
    elseif value_type == "boolean" then
      return value and "true" or "false"
    elseif value_type ~= "table" then
      return nil, "unsupported JSON type: " .. value_type
    end

    stack = stack or {}
    if stack[value] then
      return nil, "reference cycle"
    end
    stack[value] = true

    local is_array = true
    local max_index = 0
    for k, _ in pairs(value) do
      if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
        is_array = false
        break
      end
      if k > max_index then
        max_index = k
      end
    end

    local parts = {}
    if is_array then
      for i = 1, max_index do
        local encoded, err = encode_value(value[i], stack)
        if err then
          stack[value] = nil
          return nil, err
        end
        parts[#parts + 1] = encoded or "null"
      end
      stack[value] = nil
      return "[" .. table.concat(parts, ",") .. "]"
    end

    for k, v in pairs(value) do
      if type(k) ~= "string" and type(k) ~= "number" then
        stack[value] = nil
        return nil, "unsupported key type"
      end
      local encoded, err = encode_value(v, stack)
      if err then
        stack[value] = nil
        return nil, err
      end
      parts[#parts + 1] = escape_string(tostring(k)) .. ":" .. (encoded or "null")
    end
    stack[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local function skip_ws(text, pos)
    while true do
      local byte = text:byte(pos)
      if byte == 32 or byte == 9 or byte == 10 or byte == 13 then
        pos = pos + 1
      else
        return pos
      end
    end
  end

  local function parse_value(text, pos)
    pos = skip_ws(text, pos)
    local ch = text:sub(pos, pos)
    if ch == '"' then
      local out = {}
      pos = pos + 1
      while true do
        local c = text:sub(pos, pos)
        if c == "" then
          return nil, "unterminated string"
        elseif c == '"' then
          return table.concat(out), pos + 1
        elseif c == "\\" then
          local esc = text:sub(pos + 1, pos + 1)
          if esc == '"' or esc == "\\" or esc == "/" then
            out[#out + 1] = esc
            pos = pos + 2
          elseif esc == "b" then
            out[#out + 1] = "\b"
            pos = pos + 2
          elseif esc == "f" then
            out[#out + 1] = "\f"
            pos = pos + 2
          elseif esc == "n" then
            out[#out + 1] = "\n"
            pos = pos + 2
          elseif esc == "r" then
            out[#out + 1] = "\r"
            pos = pos + 2
          elseif esc == "t" then
            out[#out + 1] = "\t"
            pos = pos + 2
          elseif esc == "u" then
            local hex = text:sub(pos + 2, pos + 5)
            if not hex:match("^%x%x%x%x$") then
              return nil, "invalid unicode escape"
            end
            out[#out + 1] = codepoint_to_utf8(tonumber(hex, 16))
            pos = pos + 6
          else
            return nil, "invalid escape sequence"
          end
        else
          out[#out + 1] = c
          pos = pos + 1
        end
      end
    elseif ch == "{" then
      local obj = {}
      pos = skip_ws(text, pos + 1)
      if text:sub(pos, pos) == "}" then
        return obj, pos + 1
      end
      while true do
        local key
        key, pos = parse_value(text, pos)
        if type(key) ~= "string" then
          return nil, "object key must be a string"
        end
        pos = skip_ws(text, pos)
        if text:sub(pos, pos) ~= ":" then
          return nil, "expected ':' after object key"
        end
        local value
        value, pos = parse_value(text, pos + 1)
        obj[key] = value
        pos = skip_ws(text, pos)
        local sep = text:sub(pos, pos)
        if sep == "," then
          pos = skip_ws(text, pos + 1)
        elseif sep == "}" then
          return obj, pos + 1
        else
          return nil, "expected ',' or '}'"
        end
      end
    elseif ch == "[" then
      local arr = {}
      pos = skip_ws(text, pos + 1)
      if text:sub(pos, pos) == "]" then
        return arr, pos + 1
      end
      local index = 1
      while true do
        local value
        value, pos = parse_value(text, pos)
        arr[index] = value
        index = index + 1
        pos = skip_ws(text, pos)
        local sep = text:sub(pos, pos)
        if sep == "," then
          pos = skip_ws(text, pos + 1)
        elseif sep == "]" then
          return arr, pos + 1
        else
          return nil, "expected ',' or ']'"
        end
      end
    elseif ch == "t" and text:sub(pos, pos + 3) == "true" then
      return true, pos + 4
    elseif ch == "f" and text:sub(pos, pos + 4) == "false" then
      return false, pos + 5
    elseif ch == "n" and text:sub(pos, pos + 3) == "null" then
      return json_null, pos + 4
    else
      local start_pos = pos
      if ch == "-" then
        pos = pos + 1
      end
      local int_start = pos
      while text:sub(pos, pos):match("%d") do
        pos = pos + 1
      end
      if pos == int_start then
        return nil, "invalid JSON value"
      end
      if text:sub(pos, pos) == "." then
        pos = pos + 1
        local frac_start = pos
        while text:sub(pos, pos):match("%d") do
          pos = pos + 1
        end
        if pos == frac_start then
          return nil, "invalid number"
        end
      end
      local exp = text:sub(pos, pos)
      if exp == "e" or exp == "E" then
        pos = pos + 1
        local sign = text:sub(pos, pos)
        if sign == "+" or sign == "-" then
          pos = pos + 1
        end
        local exp_start = pos
        while text:sub(pos, pos):match("%d") do
          pos = pos + 1
        end
        if pos == exp_start then
          return nil, "invalid exponent"
        end
      end
      local number = tonumber(text:sub(start_pos, pos - 1))
      if number == nil then
        return nil, "invalid number"
      end
      return number, pos
    end
  end

  function json.encode(value)
    return encode_value(value, {})
  end

  function json.decode(text)
    if type(text) ~= "string" then
      return nil, "expected string"
    end
    local value, pos = parse_value(text, 1)
    if value == nil then
      return nil, pos
    end
    pos = skip_ws(text, pos)
    if pos <= #text then
      return nil, "unexpected trailing data"
    end
    return value
  end

  return json
end

local json = make_json()

local config = {
  listen_port = 49000,
  enabled = true,
  debug = false,
  standalone_mode = false,
  mappings = {
    -- Placeholder X-Plane failure refs. Replace these with verified Zibo refs
    -- or commands when you have them.
    engine = {
      target = "sim/operation/failures/rel_engfir1",
      write_mode = "int",
      active_value = 6,
      inactive_value = 0,
    },
    hydraulics = {
      target = "sim/operation/failures/rel_hyd1",
      write_mode = "int",
      active_value = 6,
      inactive_value = 0,
    },
    avionics = {
      target = "sim/operation/failures/rel_avionics",
      write_mode = "int",
      active_value = 6,
      inactive_value = 0,
    },
    electrical = {
      target = "sim/operation/failures/rel_elec",
      write_mode = "int",
      active_value = 6,
      inactive_value = 0,
    },
    airframe = {
      target = "sim/operation/failures/rel_structure",
      write_mode = "int",
      active_value = 6,
      inactive_value = 0,
    },
  }
}

local udp = nil
local dataref_handle_cache = {}
local command_handle_cache = {}
local startup_blocker = nil

local function log(msg)
  if config.debug then
    print("[xplane-bridge] " .. tostring(msg))
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
    if ok then
      return true
    end
  end

  if type(XPLMSetDataf) == "function" then
    local handle = get_dataref_handle(path)
    if handle then
      local ok = pcall(XPLMSetDataf, handle, value)
      if ok then
        return true
      end
    end
  end

  if type(setData) == "function" then
    local ok = pcall(setData, path, value)
    if ok then
      return true
    end
  end

  return false
end

local function write_int(path, value)
  if type(set) == "function" then
    local ok = pcall(set, path, value)
    if ok then
      return true
    end
  end

  if type(XPLMSetDatai) == "function" then
    local handle = get_dataref_handle(path)
    if handle then
      local ok = pcall(XPLMSetDatai, handle, value)
      if ok then
        return true
      end
    end
  end

  if type(setData) == "function" then
    local ok = pcall(setData, path, value)
    if ok then
      return true
    end
  end

  return false
end

local function invoke_command_once(path)
  if type(command_once) == "function" then
    local ok = pcall(command_once, path)
    if ok then
      return true
    end
  end

  if type(XPLMCommandOnce) == "function" then
    local handle = get_command_handle(path)
    if handle then
      local ok = pcall(XPLMCommandOnce, handle)
      if ok then
        return true
      end
    end
  end

  return false
end

local function apply_mapping(mapping, severity)
  local mode = mapping.write_mode or "float"
  local target = mapping.target
  if not target or target == "" then
    return false
  end

  if mode == "float" then
    local scale = mapping.scale or 1.0
    local min_value = mapping.min_value or 0.0
    local max_value = mapping.max_value or 1.0
    return write_float(target, clamp((tonumber(severity) or 0) * scale, min_value, max_value))
  end

  if mode == "int" then
    local threshold = mapping.threshold or 0.0
    local active_value = mapping.active_value or 1
    local inactive_value = mapping.inactive_value or 0
    local resolved = (tonumber(severity) or 0) > threshold and active_value or inactive_value
    return write_int(target, resolved)
  end

  if mode == "int_scale" then
    local scale = mapping.scale or 1.0
    local min_value = mapping.min_value or 0
    local max_value = mapping.max_value or 1
    local resolved = clamp(round((tonumber(severity) or 0) * scale), min_value, max_value)
    return write_int(target, resolved)
  end

  if mode == "command_once" then
    local threshold = mapping.threshold or 0.0
    if (tonumber(severity) or 0) > threshold then
      return invoke_command_once(target)
    end
    return true
  end

  return false
end

local function set_failure(failure_name, severity)
  if not config.enabled then return end

  local mapping = config.mappings[failure_name]
  if not mapping then
    log("unknown failure mapping: " .. tostring(failure_name))
    return
  end

  if not apply_mapping(mapping, severity) then
    log("unable to apply mapping for " .. tostring(failure_name) .. " using target " .. tostring(mapping.target))
  end
end

local function handle_payload(payload)
  if type(payload) ~= "table" then
    return
  end

  local failure_name = payload.failure or "engine"
  local severity = tonumber(payload.severity) or 0.2
  set_failure(failure_name, severity)
  log(string.format("%s -> %.2f", tostring(failure_name), severity))
end

local function poll_udp()
  if not udp then
    return
  end

  while true do
    local data = udp:receivefrom()
    if not data then
      break
    end

    local ok, decoded = pcall(json.decode, data)
    if ok and type(decoded) == "table" then
      handle_payload(decoded)
    else
      log("invalid JSON payload received")
    end
  end
end

local function init_udp()
  if not socket then
    startup_blocker = "LuaSocket not available: " .. tostring(socket_err)
    return false
  end

  if udp then
    return true
  end

  local sock, err = socket.udp()
  if not sock then
    log("udp create failed: " .. tostring(err))
    return false
  end

  local bind_ok, bind_err = sock:setsockname("*", config.listen_port)
  if not bind_ok then
    log("udp bind failed: " .. tostring(bind_err))
    return false
  end

  sock:settimeout(0)
  udp = sock
  log(string.format("listening on port %d", config.listen_port))
  return true
end

local function main()
  if not init_udp() then
    log("bridge disabled: " .. tostring(startup_blocker or "failed to initialize UDP bridge"))
    return
  end

  if type(do_every_frame) == "function" then
    _G.xplane_bridge_poll = poll_udp
    do_every_frame("xplane_bridge_poll()")
    log("registered do_every_frame poll callback")
    return
  end

  if config.standalone_mode then
    while true do
      poll_udp()
      socket.sleep(0.02)
    end
  else
    log("do_every_frame not available; set standalone_mode=true to run outside FlyWithLua")
  end
end

main()

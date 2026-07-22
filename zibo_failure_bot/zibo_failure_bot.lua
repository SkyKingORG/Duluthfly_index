-- zibo_failure_bot.lua
-- A Lua bot that can listen for Twitch, StreamElements, and Streamlabs events,
-- apply simulated Zibo failure events, send a payload to X-Plane 12, and write
-- a dashboard state file for a browser gauge display.
--
-- Requirements:
--   - LuaSocket (https://github.com/lunarmodules/luasocket)
--   - JSON helper embedded in this script
--
-- Suggested runtime:
--   - Run as a standalone Lua process or inside FlyWithLua if you want a tighter
--     in-sim bridge. This script sends UDP payloads to X-Plane 12 and exposes
--     HTTP endpoints for StreamElements/Streamlabs webhooks.

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
    -- Module may set package.loaded itself and return nil.
    return package.loaded[module_name], nil
  end

  package.loaded[module_name] = result
  return result, nil
end

local function require_or_die(module_name, hint)
  local ok, mod = pcall(require, module_name)
  if ok then
    return mod
  end

  local local_mod, local_err = load_local_lua_module(module_name)
  if local_mod ~= nil then
    return local_mod
  end

  local message = string.format("missing Lua module '%s': %s", module_name, tostring(mod))
  if local_err then
    message = message .. "\nlocal load failed: " .. tostring(local_err)
  end
  if hint and hint ~= "" then
    message = message .. "\n" .. hint
  end
  error(message)
end

local socket = require_or_die("socket", "Install LuaSocket for your active Lua runtime.")

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

    local meta = getmetatable(value)
    if meta and type(meta.__tojson) == "function" then
      local custom = meta.__tojson(value)
      if type(custom) == "string" then
        return custom
      end
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
            local code = tonumber(hex, 16)
            local next_pos = pos + 6
            if code >= 0xD800 and code <= 0xDBFF and text:sub(next_pos, next_pos + 1) == "\\u" then
              local low_hex = text:sub(next_pos + 2, next_pos + 5)
              if low_hex:match("^%x%x%x%x$") then
                local low = tonumber(low_hex, 16)
                if low >= 0xDC00 and low <= 0xDFFF then
                  code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                  pos = next_pos + 6
                  out[#out + 1] = codepoint_to_utf8(code)
                else
                  out[#out + 1] = codepoint_to_utf8(code)
                  pos = pos + 6
                end
              else
                out[#out + 1] = codepoint_to_utf8(code)
                pos = pos + 6
              end
            else
              out[#out + 1] = codepoint_to_utf8(code)
              pos = pos + 6
            end
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
      local number_text = text:sub(start_pos, pos - 1)
      local number = tonumber(number_text)
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

local function getenv_nonempty(name, fallback)
  local value = os.getenv(name)
  if value and value ~= "" then
    return value
  end
  return fallback
end

local function show_status_message(title, message, is_error)
  local safe_title = tostring(title or "Bot Status"):gsub("'", "''")
  local safe_message = tostring(message or ""):gsub("'", "''")
  local icon = is_error and "Error" or "Information"
  local command = table.concat({
    "powershell -NoProfile -ExecutionPolicy Bypass -Command",
    '"Add-Type -AssemblyName PresentationFramework;',
    string.format("[System.Windows.MessageBox]::Show('%s','%s','OK','%s') | Out-Null", safe_message, safe_title, icon),
    '"',
  }, " ")
  pcall(os.execute, command)
end

local config = {
  listen_port = 6100,
  xplane_host = "127.0.0.1",
  xplane_port = 49000,
  dashboard_path = "dashboard_state.json",
  twitch = {
    enabled = getenv_nonempty("TWITCH_ENABLED", "true") ~= "false",
    nick = getenv_nonempty("TWITCH_BOT_NICK", "OnlyPilots"),
    oauth = getenv_nonempty("TWITCH_OAUTH", "oauth:replace_with_token"),
    channel = getenv_nonempty("TWITCH_CHANNEL", "#desktoppilotsociety"),
    server = getenv_nonempty("TWITCH_IRC_SERVER", "irc.chat.twitch.tv"),
    port = tonumber(getenv_nonempty("TWITCH_IRC_PORT", "6667")) or 6667,
  },
  streamelements = {
    enabled = getenv_nonempty("STREAMELEMENTS_ENABLED", "true") ~= "false",
    endpoint = "/streamelements",
    randomize_all_actions = getenv_nonempty("STREAMELEMENTS_RANDOMIZE_ALL_ACTIONS", "true") ~= "false",
    prime_sub_failure_burst = tonumber(getenv_nonempty("STREAMELEMENTS_PRIME_SUB_FAILURE_BURST", "3")) or 3,
  },
  streamlabs = {
    enabled = getenv_nonempty("STREAMLABS_ENABLED", "true") ~= "false",
    endpoint = "/streamlabs",
  },
  weights = {
    raid = 0.18,
    subscribe = 0.11,
    tip = 0.16,
    gift = 0.14,
    bits = 0.10,
    command = 0.08,
  },
  failure_profile = {
    engine = { label = "Engine", severity = 0.35 },
    hydraulics = { label = "Hydraulics", severity = 0.25 },
    avionics = { label = "Avionics", severity = 0.20 },
    electrical = { label = "Electrical", severity = 0.25 },
    airframe = { label = "Airframe", severity = 0.30 },
  },
  zibo = {
    enabled = true,
  }
}

local function make_initial_state()
  return {
    current_severity = 0.0,
    last_event = "idle",
    event_counter = 0,
    active_failures = {},
    last_failure_ts = 0,
    last_raid = {
      user = "None",
      viewers = 0,
      ts = 0,
    },
    last_follower = {
      user = "None",
      ts = 0,
    },
    last_bits = {
      user = "None",
      amount = 0,
      ts = 0,
    },
    total_bits = 0,
    bits_totals = {},
    top_bits_giver = {
      user = "None",
      amount = 0,
      ts = 0,
    },
    highest_single_bits = {
      user = "None",
      amount = 0,
      ts = 0,
    },
  }
end

local state = make_initial_state()
local shutdown_requested = false

local function clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

local function round(value, digits)
  local factor = 10 ^ (digits or 2)
  return math.floor(value * factor + 0.5) / factor
end

local function coerce_number(value, fallback)
  local n = tonumber(value)
  if n ~= nil then return n end
  return fallback or 1
end

local function random_failure_name()
  local names = {}
  for name, _ in pairs(config.failure_profile) do
    names[#names + 1] = name
  end

  if #names == 0 then
    return "engine"
  end

  return names[math.random(#names)]
end

local function is_prime_subscription(payload)
  if type(payload) ~= "table" then
    return false
  end

  local data = type(payload.data) == "table" and payload.data or nil
  local candidates = {
    payload.tier,
    payload.plan,
    payload.sub_plan,
    payload.subscription_kind,
    payload["msg-param-sub-plan"],
    data and data.tier,
    data and data.plan,
    data and data.sub_plan,
    data and data.subscription_kind,
  }

  for _, candidate in ipairs(candidates) do
    local text = tostring(candidate or ""):lower()
    if text == "prime" or text:find("prime", 1, true) then
      return true
    end
  end

  return false
end

local function pick_failure(event_name, amount, details)
  local profile = config.failure_profile
  if details and details.randomize_failure then
    local failure_name = random_failure_name()
    local profile_data = profile[failure_name] or profile.engine
    return failure_name, (profile_data and profile_data.severity or 0.30) + amount * 0.01
  end

  if event_name == "raid" then
    return "engine", profile.engine.severity + amount * 0.01
  elseif event_name == "subscribe" then
    return "electrical", profile.electrical.severity + amount * 0.01
  elseif event_name == "tip" then
    return "avionics", profile.avionics.severity + amount * 0.01
  elseif event_name == "gift" then
    return "hydraulics", profile.hydraulics.severity + amount * 0.01
  elseif event_name == "bits" then
    return "airframe", profile.airframe.severity + amount * 0.01
  elseif event_name == "command" then
    return "electrical", profile.electrical.severity + 0.05
  end
  return "engine", profile.engine.severity
end

local function write_dashboard_state()
  local payload = {
    severity = round(state.current_severity, 2),
    last_event = state.last_event,
    event_counter = state.event_counter,
    failures = state.active_failures,
    last_failure_ts = state.last_failure_ts,
    last_raid = state.last_raid,
    last_follower = state.last_follower,
    last_bits = state.last_bits,
    total_bits = state.total_bits,
    top_bits_giver = state.top_bits_giver,
    highest_single_bits = state.highest_single_bits,
  }

  local encoded, encode_err = json.encode(payload)
  if not encoded then
    print("[state] json encode failed: " .. tostring(encode_err))
    return
  end

  local fh = io.open(config.dashboard_path, "w")
  if fh then
    fh:write(encoded)
    fh:close()
  else
    print("[state] failed to open dashboard state file: " .. tostring(config.dashboard_path))
  end
end

local function reset_state(reason)
  state = make_initial_state()
  write_dashboard_state()
  print(string.format("[state] reset to zero (%s)", tostring(reason or "manual")))
end

local function send_to_xplane(event_name, failure_name, severity, details)
  if not config.zibo.enabled then return end

  local payload = {
    event = event_name,
    failure = failure_name,
    severity = round(severity, 2),
    details = details or {},
    ts = os.time(),
  }

  local ok, err = pcall(function()
    local udp = assert(socket.udp())
    udp:settimeout(0.2)
    udp:sendto(json.encode(payload), config.xplane_host, config.xplane_port)
    udp:close()
  end)

  if not ok then
    print("[xplane] failed: " .. tostring(err))
  end
end

local function apply_event(event_name, amount, details)
  amount = coerce_number(amount, 1)
  local severity_boost = config.weights[event_name] or 0.10
  local failure_name, base_severity = pick_failure(event_name, amount, details)
  local severity = clamp(state.current_severity + (severity_boost * amount) + base_severity, 0, 1.0)
  local now_ts = os.time()

  state.current_severity = severity
  state.event_counter = state.event_counter + 1
  state.last_event = event_name
  state.last_failure_ts = now_ts

  if event_name == "raid" then
    local raid_user = "unknown"
    if details and details.user and details.user ~= "" then
      raid_user = details.user
    end
    state.last_raid = {
      user = raid_user,
      viewers = math.max(0, math.floor(amount + 0.5)),
      ts = now_ts,
    }
  elseif event_name == "bits" then
    local bits_user = "unknown"
    if details and details.user and details.user ~= "" then
      bits_user = details.user
    end
    local bits_amount = math.max(0, math.floor(amount + 0.5))
    state.last_bits = {
      user = bits_user,
      amount = bits_amount,
      ts = now_ts,
    }
    state.total_bits = math.max(0, math.floor((state.total_bits or 0) + bits_amount + 0.5))
    state.bits_totals = state.bits_totals or {}
    state.bits_totals[bits_user] = math.max(0, math.floor((state.bits_totals[bits_user] or 0) + bits_amount + 0.5))
    local user_total = state.bits_totals[bits_user]
    local current_top = state.top_bits_giver or { amount = 0 }
    if user_total > (current_top.amount or 0) then
      state.top_bits_giver = {
        user = bits_user,
        amount = user_total,
        ts = now_ts,
      }
    end

    local current_single = state.highest_single_bits or { amount = 0 }
    if bits_amount > (current_single.amount or 0) then
      state.highest_single_bits = {
        user = bits_user,
        amount = bits_amount,
        ts = now_ts,
      }
    end
  end

  state.active_failures[failure_name] = {
    severity = round(severity, 2),
    amount = amount,
    details = details or {},
  }

  write_dashboard_state()
  send_to_xplane(event_name, failure_name, severity, details)

  print(string.format("[event] %s -> failure=%s severity=%.2f amount=%.2f", event_name, failure_name, severity, amount))
end

local function parse_payload(body)
  if not body or body == "" then return nil end
  local ok, decoded = pcall(json.decode, body)
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

local function payload_user(payload)
  if type(payload) ~= "table" then
    return "unknown"
  end

  local data = payload.data
  local user = payload.user or payload.name or payload.username or (type(data) == "table" and data.name)
  if user and user ~= "" then
    return user
  end

  return "unknown"
end

local function record_follower(user_name)
  local follower_user = "unknown"
  if user_name and user_name ~= "" then
    follower_user = user_name
  end

  state.last_follower = {
    user = follower_user,
    ts = os.time(),
  }

  write_dashboard_state()
  print(string.format("[event] follower -> user=%s", follower_user))
end

local function handle_streamlabs_payload(payload)
  if not payload then return end
  local event_name = nil
  local amount = 1
  local details = {}

  if payload.type == "follow" or payload.type == "follower" or payload.event == "follow" or payload.event == "follower" then
    record_follower(payload_user(payload))
    return
  end

  if payload.type == "donation" or payload.type == "tip" or payload.event == "donation" then
    event_name = "tip"
    amount = coerce_number(payload.amount or payload.amount_value or payload.data and payload.data.amount or 1, 1)
    details = { source = "streamlabs", user = payload_user(payload) }
  elseif payload.type == "subscription" or payload.event == "subscription" then
    event_name = "subscribe"
    amount = coerce_number(payload.amount or payload.months or 1, 1)
    details = { source = "streamlabs", user = payload_user(payload) }
  elseif payload.type == "raid" or payload.event == "raid" then
    event_name = "raid"
    amount = coerce_number(payload.viewers or payload.viewer_count or 1, 1)
    details = { source = "streamlabs", user = payload_user(payload) }
  elseif payload.type == "bits" or payload.event == "bits" then
    event_name = "bits"
    amount = coerce_number(payload.bits or payload.amount or 1, 1)
    details = { source = "streamlabs", user = payload_user(payload) }
  end

  if event_name then apply_event(event_name, amount, details) end
end

local function handle_streamelements_payload(payload)
  if not payload then return end
  local event_name = nil
  local amount = 1
  local details = { source = "streamelements", user = payload_user(payload), randomize_failure = true }

  if payload.type == "follow" or payload.type == "follower" or payload.event == "follow" or payload.event == "follower" or payload.action == "follow" then
    record_follower(payload_user(payload))
    return
  end

  if payload.type == "tip" or payload.event == "tip" or payload.action == "tip" then
    event_name = "tip"
    amount = coerce_number(payload.amount or payload.data and payload.data.amount or 1, 1)
  elseif payload.type == "subscriber" or payload.type == "subscription" or payload.event == "subscription" then
    event_name = "subscribe"
    amount = coerce_number(payload.amount or payload.months or 1, 1)
    details.subscription_kind = is_prime_subscription(payload) and "prime" or "regular"
  elseif payload.type == "raid" or payload.event == "raid" then
    event_name = "raid"
    amount = coerce_number(payload.viewers or payload.viewer_count or 1, 1)
  elseif payload.type == "gifted" or payload.event == "gifted" or payload.type == "gift_sub" then
    event_name = "gift"
    amount = coerce_number(payload.amount or payload.count or payload.gifts or 1, 1)
  elseif payload.type == "bits" or payload.event == "bits" then
    event_name = "bits"
    amount = coerce_number(payload.bits or payload.amount or 1, 1)
  elseif config.streamelements.randomize_all_actions then
    event_name = "command"
    amount = 1
    details.action_name = tostring(payload.action or payload.type or payload.event or "unknown")
  end

  if event_name then
    apply_event(event_name, amount, details)

    if event_name == "subscribe" and details.subscription_kind == "prime" then
      local burst = math.max(2, math.floor(config.streamelements.prime_sub_failure_burst + 0.5))
      for _ = 2, burst do
        apply_event("subscribe", 1, {
          source = "streamelements",
          user = details.user,
          randomize_failure = true,
          subscription_kind = "prime",
          prime_chain = true,
        })
      end

      print(string.format("[event] prime sub burst applied: %d immediate failures", burst))
    end
  end
end

local function handle_http_request(client)
  local request_line = client:receive("*l")
  if not request_line then return end

  local headers = {}
  while true do
    local line = client:receive("*l")
    if not line or line == "" then break end
    local key, value = line:match("^([%w%-]+):%s*(.+)$")
    if key then headers[key:lower()] = value end
  end

  local method, path = request_line:match("^(%u+)%s+([^%s]+)")
  method = method or "GET"
  path = path or "/"
  path = path:match("^[^?]+") or path

  local peer_ip = select(1, client:getpeername()) or ""
  local is_local_client = (peer_ip == "127.0.0.1" or peer_ip == "::1" or peer_ip == "::ffff:127.0.0.1")
  local body = ""
  local length = tonumber(headers["content-length"]) or 0
  if length > 0 then
    local chunk, receive_err, partial = client:receive(length)
    body = chunk or partial or ""
    if not chunk and receive_err and receive_err ~= "timeout" then
      print("[http] body receive issue: " .. tostring(receive_err))
    end
  end

  local payload = parse_payload(body)

  if path == config.streamlabs.endpoint then
    handle_streamlabs_payload(payload)
  elseif path == config.streamelements.endpoint then
    handle_streamelements_payload(payload)
  elseif path == "/admin/reset" then
    if not is_local_client then
      local forbidden = json.encode({ status = "forbidden" })
      client:send("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: " .. #forbidden .. "\r\n\r\n" .. forbidden)
      return
    end

    reset_state("http_admin")
    local response = json.encode({ status = "ok", action = "reset", method = method })
    client:send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #response .. "\r\n\r\n" .. response)
    return
  elseif path == "/admin/stop" then
    if not is_local_client then
      local forbidden = json.encode({ status = "forbidden" })
      client:send("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: " .. #forbidden .. "\r\n\r\n" .. forbidden)
      return
    end

    shutdown_requested = true
    local response = json.encode({ status = "ok", action = "stop", method = method })
    client:send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #response .. "\r\n\r\n" .. response)
    return
  elseif path == "/health" then
    local health = { status = "ok", current_severity = round(state.current_severity, 2), last_event = state.last_event }
    local body_out = json.encode(health)
    client:send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #body_out .. "\r\n\r\n" .. body_out)
    return
  end

  local response = { status = "ok" }
  local response_body = json.encode(response)
  client:send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #response_body .. "\r\n\r\n" .. response_body)
end

local function serve_http_once(server)
  local client = server:accept()
  if client then
    client:settimeout(1)
    local ok, err = pcall(handle_http_request, client)
    if not ok then
      print("[http] request error: " .. tostring(err))
    end
    client:close()
  end
end

local function create_http_server(host, port)
  local server, tcp_err = socket.tcp()
  if not server then
    return nil, tcp_err
  end

  pcall(function()
    server:setoption("reuseaddr", true)
  end)

  local ok, bind_err = server:bind(host or "*", port)
  if not ok then
    return nil, bind_err
  end

  local listen_ok, listen_err = server:listen(16)
  if not listen_ok then
    return nil, listen_err
  end

  return server
end

local function connect_twitch_irc()
  if not config.twitch.enabled then
    return nil
  end

  if config.twitch.oauth == "oauth:replace_with_token" then
    error("twitch enabled but TWITCH_OAUTH is not set")
  end

  local client, err = socket.tcp()
  if not client then error(err) end
  client:settimeout(0.5)
  local ok, connect_err = client:connect(config.twitch.server, config.twitch.port)
  if not ok then error(connect_err) end

  client:send("PASS " .. config.twitch.oauth .. "\r\n")
  client:send("NICK " .. config.twitch.nick .. "\r\n")
  client:send("JOIN " .. config.twitch.channel .. "\r\n")

  print("[twitch] connected")
  return client
end

local function handle_twitch_messages(client)
  if not client then return end

  local line = client:receive("*l")
  if not line then return end

  if line:match("^PING") then
    client:send("PONG" .. line:sub(6) .. "\r\n")
    return
  end

  local user, _, message = line:match(":(%S+)!%S+%s+PRIVMSG%s+(%S+)%s+:(.+)$")
  if user and message then
    if message:match("!fail") then
      apply_event("command", 1, { source = "twitch", user = user })
    elseif message:match("!zibo") then
      apply_event("command", 1.2, { source = "twitch", user = user })
    end
  end
end

local function main()
  math.randomseed(os.time())

  -- This bot script is intended to run as a standalone Lua process.
  -- In FlyWithLua, use xplane_bridge.lua and keep this script external.
  if type(do_every_frame) == "function" then
    print("[bot] zibo_failure_bot.lua is standalone. Run it outside FlyWithLua; use xplane_bridge.lua in-sim.")
    show_status_message("Bot Not Started", "zibo_failure_bot.lua is standalone. Run it outside FlyWithLua; use xplane_bridge.lua in-sim.", true)
    return
  end

  reset_state("startup")

  local twitch_client = nil
  if config.twitch.enabled then
    twitch_client = connect_twitch_irc()
  end

  local server, server_err = create_http_server("*", config.listen_port)
  if not server then
    local message = "Could not start HTTP listener on port " .. tostring(config.listen_port) .. ": " .. tostring(server_err)
    show_status_message("Bot Not Started", message, true)
    error(server_err)
  end
  server:settimeout(0.1)
  print(string.format("[http] listening on port %d", config.listen_port))
  print("[bot] ready. Send events to /streamlabs or /streamelements, or use Twitch chat commands if enabled.")
  show_status_message("Bot Started", "Zibo Failure Bot started and is listening on port " .. tostring(config.listen_port) .. ".", false)

  while true do
    if shutdown_requested then
      print("[bot] shutdown requested")
      break
    end

    local ready_list = {}
    if server then table.insert(ready_list, server) end
    if twitch_client then table.insert(ready_list, twitch_client) end

    if #ready_list > 0 then
      local ready, _, _ = socket.select(ready_list, nil, 0.1)
      if ready then
        for _, sock in ipairs(ready) do
          if sock == server then
            local ok, err = pcall(serve_http_once, server)
            if not ok then
              print("[http] server loop stopped: " .. tostring(err))
            end
          elseif twitch_client and sock == twitch_client then
            local ok, err = pcall(handle_twitch_messages, twitch_client)
            if not ok then
              print("[twitch] error: " .. tostring(err))
            end
          end
        end
      end
    end
  end

  if twitch_client then
    pcall(function() twitch_client:close() end)
  end
  if server then
    pcall(function() server:close() end)
  end

  print("[bot] stopped")
end

main()

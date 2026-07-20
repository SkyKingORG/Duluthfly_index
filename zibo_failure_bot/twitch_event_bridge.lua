-- twitch_event_bridge.lua
-- Standalone Twitch IRC relay for the Zibo failure bot.
--
-- This script connects to Twitch IRC, listens for Twitch-native events that
-- appear in IRC tags / USERNOTICE messages, and forwards them to the existing
-- local failure bot over HTTP JSON.
--
-- Supported forwarded events:
--   - raids
--   - bits / cheers
--   - new subs
--   - re-subs
--   - Prime subs
--   - gifted subs / community gifts
--   - synthetic tips via chat command (Twitch has no native tip event)

local function require_or_die(module_name, hint)
  local ok, mod = pcall(require, module_name)
  if ok then
    return mod
  end

  local message = string.format("missing Lua module '%s': %s", module_name, tostring(mod))
  if hint and hint ~= "" then
    message = message .. "\n" .. hint
  end
  error(message)
end

local socket = require_or_die("socket", "Install LuaSocket for your active Lua runtime.")

local function getenv_nonempty(name, fallback)
  local value = os.getenv(name)
  if value and value ~= "" then
    return value
  end
  return fallback
end

local config = {
  twitch = {
    nick = getenv_nonempty("TWITCH_BOT_NICK", "OnlyPilots"),
    oauth = getenv_nonempty("TWITCH_OAUTH", "oauth:replace_with_token"),
    channel = getenv_nonempty("TWITCH_CHANNEL", "#desktoppilotsociety"),
    server = getenv_nonempty("TWITCH_IRC_SERVER", "irc.chat.twitch.tv"),
    port = tonumber(getenv_nonempty("TWITCH_IRC_PORT", "6667")) or 6667,
  },
  bot = {
    host = getenv_nonempty("FAILURE_BOT_HOST", "127.0.0.1"),
    port = tonumber(getenv_nonempty("FAILURE_BOT_PORT", "6100")) or 6100,
    endpoint = getenv_nonempty("FAILURE_BOT_ENDPOINT", "/streamelements"),
  },
  synthetic_tip_command = getenv_nonempty("TWITCH_TIP_COMMAND", "!tip"),
  reconnect_delay_seconds = tonumber(getenv_nonempty("TWITCH_RECONNECT_DELAY", "5")) or 5,
}

local function log(message)
  print("[twitch-bridge] " .. tostring(message))
end

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function json_escape(value)
  local escapes = {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  }

  return '"' .. tostring(value):gsub('[%z\1-\31\\"]', function(ch)
    return escapes[ch] or string.format("\\u%04x", ch:byte())
  end) .. '"'
end

local function json_encode(value, stack)
  local value_type = type(value)
  if value == nil then
    return "null"
  elseif value_type == "string" then
    return json_escape(value)
  elseif value_type == "number" then
    return tostring(value)
  elseif value_type == "boolean" then
    return value and "true" or "false"
  elseif value_type ~= "table" then
    error("unsupported JSON type: " .. value_type)
  end

  stack = stack or {}
  if stack[value] then
    error("reference cycle while encoding JSON")
  end
  stack[value] = true

  local is_array = true
  local max_index = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      is_array = false
      break
    end
    if key > max_index then
      max_index = key
    end
  end

  local parts = {}
  if is_array then
    for index = 1, max_index do
      parts[#parts + 1] = json_encode(value[index], stack)
    end
    stack[value] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end

  for key, item in pairs(value) do
    parts[#parts + 1] = json_escape(tostring(key)) .. ":" .. json_encode(item, stack)
  end
  stack[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

local function unescape_tag_value(value)
  value = tostring(value or "")
  value = value:gsub("\\:", ";")
  value = value:gsub("\\s", " ")
  value = value:gsub("\\r", "\r")
  value = value:gsub("\\n", "\n")
  value = value:gsub("\\\\", "\\")
  return value
end

local function parse_tags(tags_text)
  local tags = {}
  for pair in tostring(tags_text or ""):gmatch("[^;]+") do
    local key, value = pair:match("([^=]+)=?(.*)")
    if key then
      tags[key] = unescape_tag_value(value)
    end
  end
  return tags
end

local function parse_irc_line(line)
  local cursor = 1
  local tags = {}
  local prefix = nil

  if line:sub(cursor, cursor) == "@" then
    local space_pos = line:find(" ", cursor, true)
    if not space_pos then
      return nil
    end
    tags = parse_tags(line:sub(cursor + 1, space_pos - 1))
    cursor = space_pos + 1
  end

  if line:sub(cursor, cursor) == ":" then
    local space_pos = line:find(" ", cursor, true)
    if not space_pos then
      return nil
    end
    prefix = line:sub(cursor + 1, space_pos - 1)
    cursor = space_pos + 1
  end

  local trailing_start = line:find(" :", cursor, true)
  local head = trailing_start and line:sub(cursor, trailing_start - 1) or line:sub(cursor)
  local trailing = trailing_start and line:sub(trailing_start + 2) or nil

  local parts = {}
  for token in head:gmatch("%S+") do
    parts[#parts + 1] = token
  end

  if #parts == 0 then
    return nil
  end

  return {
    tags = tags,
    prefix = prefix,
    command = parts[1],
    params = parts,
    trailing = trailing,
  }
end

local function connect_irc()
  if config.twitch.oauth == "oauth:replace_with_token" then
    error("TWITCH_OAUTH is not set")
  end

  local client, err = socket.tcp()
  if not client then
    error(err)
  end

  client:settimeout(10)
  local ok, connect_err = client:connect(config.twitch.server, config.twitch.port)
  if not ok then
    error(connect_err)
  end

  client:send("CAP REQ :twitch.tv/tags twitch.tv/commands\r\n")
  client:send("PASS " .. config.twitch.oauth .. "\r\n")
  client:send("NICK " .. config.twitch.nick .. "\r\n")
  client:send("JOIN " .. config.twitch.channel .. "\r\n")
  client:settimeout(1)

  log("connected to Twitch IRC as " .. config.twitch.nick .. " in " .. config.twitch.channel)
  return client
end

local function post_to_bot(payload)
  local encoded = json_encode(payload)
  local request = table.concat({
    "POST " .. config.bot.endpoint .. " HTTP/1.1",
    "Host: " .. config.bot.host .. ":" .. tostring(config.bot.port),
    "Content-Type: application/json",
    "Connection: close",
    "Content-Length: " .. tostring(#encoded),
    "",
    encoded,
  }, "\r\n")

  local client, err = socket.tcp()
  if not client then
    log("failed to create HTTP client: " .. tostring(err))
    return false
  end

  client:settimeout(3)
  local ok, connect_err = client:connect(config.bot.host, config.bot.port)
  if not ok then
    client:close()
    log("failed to reach local bot: " .. tostring(connect_err))
    return false
  end

  local send_ok, send_err = client:send(request)
  if not send_ok then
    client:close()
    log("failed to send event to bot: " .. tostring(send_err))
    return false
  end

  client:close()
  return true
end

local function user_from_tags(tags)
  return trim(tags["display-name"] ~= "" and tags["display-name"] or tags.login or tags["user-login"] or tags.username or "unknown")
end

local function forward_event(payload)
  local ok = post_to_bot(payload)
  if ok then
    log("forwarded " .. tostring(payload.type or payload.event or "event") .. " for " .. tostring(payload.name or payload.user or "unknown"))
  end
end

local function handle_usernotice(tags)
  local msg_id = tostring(tags["msg-id"] or "")
  local user = user_from_tags(tags)

  if msg_id == "raid" then
    forward_event({
      type = "raid",
      event = "raid",
      viewers = tonumber(tags["msg-param-viewerCount"]) or 1,
      name = user,
      source = "twitch_irc",
    })
    return
  end

  if msg_id == "sub" or msg_id == "resub" then
    local plan = tags["msg-param-sub-plan"] or "1000"
    forward_event({
      type = "subscription",
      event = "subscription",
      amount = tonumber(tags["msg-param-cumulative-months"]) or 1,
      name = user,
      source = "twitch_irc",
      subscription_kind = (plan == "Prime" and "prime") or msg_id,
      sub_plan = plan,
    })
    return
  end

  if msg_id == "subgift" or msg_id == "anonsubgift" then
    forward_event({
      type = "gifted",
      event = "gifted",
      amount = 1,
      name = user,
      recipient = tags["msg-param-recipient-user-name"] or tags["msg-param-recipient-display-name"] or "unknown",
      source = "twitch_irc",
      gift_kind = msg_id,
    })
    return
  end

  if msg_id == "submysterygift" or msg_id == "anonsubmysterygift" then
    forward_event({
      type = "gifted",
      event = "gifted",
      amount = tonumber(tags["msg-param-mass-gift-count"]) or 1,
      name = user,
      source = "twitch_irc",
      gift_kind = msg_id,
    })
    return
  end
end

local function handle_privmsg(parsed)
  local tags = parsed.tags or {}
  local message = tostring(parsed.trailing or "")
  local user = user_from_tags(tags)

  local bits = tonumber(tags.bits)
  if bits and bits > 0 then
    forward_event({
      type = "bits",
      event = "bits",
      bits = bits,
      amount = bits,
      name = user,
      source = "twitch_irc",
    })
    return
  end

  -- Twitch has no native tip event. This provides a manual command path so a
  -- broadcaster/mod tool or chat automation can still trigger tip-style events.
  local command_pattern = "^" .. config.synthetic_tip_command:gsub("([^%w])", "%%%1") .. "%s+(%d+%.?%d*)"
  local amount_text = message:match(command_pattern)
  if amount_text then
    forward_event({
      type = "tip",
      event = "tip",
      amount = tonumber(amount_text) or 1,
      name = user,
      source = "twitch_chat_command",
    })
  end
end

local function handle_line(client, line)
  if line:match("^PING") then
    client:send("PONG :tmi.twitch.tv\r\n")
    return
  end

  local parsed = parse_irc_line(line)
  if not parsed then
    return
  end

  if parsed.command == "USERNOTICE" then
    handle_usernotice(parsed.tags or {})
  elseif parsed.command == "PRIVMSG" then
    handle_privmsg(parsed)
  end
end

local function main()
  while true do
    local ok, err = pcall(function()
      local client = connect_irc()
      while true do
        local line, receive_err = client:receive("*l")
        if line then
          handle_line(client, line)
        elseif receive_err ~= "timeout" then
          client:close()
          error(receive_err or "connection closed")
        end
      end
    end)

    if not ok then
      log("disconnected: " .. tostring(err))
      log("reconnecting in " .. tostring(config.reconnect_delay_seconds) .. " seconds")
      socket.sleep(config.reconnect_delay_seconds)
    end
  end
end

main()
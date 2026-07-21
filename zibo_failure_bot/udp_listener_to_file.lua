-- udp_listener_to_file.lua
-- Listens for UDP packets on port 5000 and appends payloads to udp_data.txt.

local ok, socket = pcall(require, "socket")
if not ok or not socket then
  error("LuaSocket is required. Install 'luasocket' for your Lua runtime.")
end

local listen_port = 5000
local output_file = "udp_data.txt"

local udp, udp_err = socket.udp()
if not udp then
  error("failed to create UDP socket: " .. tostring(udp_err))
end

local bind_ok, bind_err = udp:setsockname("*", listen_port)
if not bind_ok then
  error("failed to bind UDP socket on port " .. tostring(listen_port) .. ": " .. tostring(bind_err))
end

udp:settimeout(0)
print("[udp-listener] listening on UDP port " .. tostring(listen_port))
print("[udp-listener] writing packets to " .. output_file)

while true do
  local data, ip, port = udp:receivefrom()
  if data then
    local fh, open_err = io.open(output_file, "a")
    if fh then
      local timestamp = os.date("%Y-%m-%d %H:%M:%S")
      fh:write(string.format("[%s] %s:%s %s\n", timestamp, tostring(ip), tostring(port), tostring(data)))
      fh:close()
      print(string.format("[udp-listener] wrote packet from %s:%s", tostring(ip), tostring(port)))
    else
      print("[udp-listener] failed to open output file: " .. tostring(open_err))
    end
  else
    socket.sleep(0.05)
  end
end

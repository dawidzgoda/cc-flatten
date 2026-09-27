-- listener.lua - nasluch polecen na zolwiu (zapisz jako "startup")
-- Czeka na polecenia z pilota (remote.lua) i uruchamia flatten.

local PROTOCOL = "flatten"

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Brak wireless/ender modemu na zolwiu!") end
rednet.open(peripheral.getName(modem))
rednet.host(PROTOCOL, "zolw_" .. os.getComputerID())

print(("Zolw #%d czeka na polecenia..."):format(os.getComputerID()))

while true do
  local sender, msg = rednet.receive(PROTOCOL)
  if type(msg) == "table" and msg.cmd == "ping" then
    rednet.send(sender, { cmd = "pong", fuel = turtle.getFuelLevel() }, PROTOCOL)

  elseif type(msg) == "table" and msg.cmd == "start" then
    local l, w = tonumber(msg.length), tonumber(msg.width)
    if l and w then
      print(("Start od #%d: flatten %d %d%s"):format(sender, l, w, msg.center and " -c" or ""))
      rednet.send(sender, { cmd = "started" }, PROTOCOL)
      local ok
      if msg.center then
        ok = shell.run("flatten", tostring(l), tostring(w), "-c")
      else
        ok = shell.run("flatten", tostring(l), tostring(w))
      end
      rednet.send(sender, { cmd = "done", ok = ok }, PROTOCOL)
    else
      rednet.send(sender, { cmd = "error", text = "Zle wymiary" }, PROTOCOL)
    end
  end
end

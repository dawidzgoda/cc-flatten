-- listener.lua - nasluch polecen na zolwiu (zapisz jako "startup")
-- Czeka na polecenia z pilota (remote.lua) i uruchamia flatten lub torches.

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
    local program = msg.program or "flatten"
    local l, w = tonumber(msg.length), tonumber(msg.width)
    if program ~= "flatten" and program ~= "torches" then
      rednet.send(sender, { cmd = "error", text = "Nieznany program: " .. tostring(program) }, PROTOCOL)
    elseif not l or not w then
      rednet.send(sender, { cmd = "error", text = "Zle wymiary" }, PROTOCOL)
    else
      local runArgs = { program, tostring(l), tostring(w) }
      if program == "torches" and tonumber(msg.spacing) then
        runArgs[#runArgs + 1] = tostring(msg.spacing)
      end
      if msg.center then runArgs[#runArgs + 1] = "-c" end

      print(("Start od #%d: %s"):format(sender, table.concat(runArgs, " ")))
      rednet.send(sender, { cmd = "started" }, PROTOCOL)
      local ok = shell.run(table.unpack(runArgs))
      rednet.send(sender, { cmd = "done", ok = ok }, PROTOCOL)
    end
  end
end

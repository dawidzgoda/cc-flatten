-- listener.lua - nasluch polecen na zolwiu (zapisz jako "startup")
-- Czeka na polecenia z pilota (remote.lua) i uruchamia flatten lub torches.
-- Na "ping" (pilot, SCADA) odpowiada stanem - rowniez w trakcie pracy.

local PROTOCOL = "flatten"

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Brak wireless/ender modemu na zolwiu!") end
rednet.open(peripheral.getName(modem))
rednet.host(PROTOCOL, "zolw_" .. os.getComputerID())

-- Aktualny stan; postep (0..1) programy zapisuja w _G.ccProgress
local status = { state = "idle" }

local function sendPong(to)
  rednet.send(to, {
    cmd = "pong",
    label = os.getComputerLabel(),
    fuel = turtle.getFuelLevel(),
    fuelLimit = turtle.getFuelLimit(),
    state = status.state,
    program = status.program,
    progress = status.state == "work" and _G.ccProgress or nil,
  }, PROTOCOL)
end

-- Sprawdza polecenie start; zwraca argumenty dla shell.run albo nil + blad
local function parseStart(msg)
  local program = msg.program or "flatten"
  local l, w = tonumber(msg.length), tonumber(msg.width)
  if program ~= "flatten" and program ~= "torches" then
    return nil, "Nieznany program: " .. tostring(program)
  elseif not l or not w then
    return nil, "Zle wymiary"
  end
  local runArgs = { program, tostring(l), tostring(w) }
  if program == "torches" and tonumber(msg.spacing) then
    runArgs[#runArgs + 1] = tostring(msg.spacing)
  end
  if msg.center then runArgs[#runArgs + 1] = "-c" end
  return runArgs
end

-- W trakcie pracy: odpowiada na ping, odrzuca kolejne starty
local function busyResponder()
  while true do
    local sender, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" and msg.cmd == "ping" then
      sendPong(sender)
    elseif type(msg) == "table" and msg.cmd == "start" then
      rednet.send(sender, { cmd = "error", text = "Zolw jest zajety" }, PROTOCOL)
    end
  end
end

print(("Zolw #%d czeka na polecenia..."):format(os.getComputerID()))

while true do
  local sender, msg = rednet.receive(PROTOCOL)
  if type(msg) == "table" and msg.cmd == "ping" then
    sendPong(sender)

  elseif type(msg) == "table" and msg.cmd == "start" then
    local runArgs, err = parseStart(msg)
    if not runArgs then
      rednet.send(sender, { cmd = "error", text = err }, PROTOCOL)
    else
      print(("Start od #%d: %s"):format(sender, table.concat(runArgs, " ")))
      rednet.send(sender, { cmd = "started" }, PROTOCOL)

      status.state, status.program = "work", runArgs[1]
      _G.ccProgress = 0
      local ok = false
      parallel.waitForAny(
        function() ok = shell.run(table.unpack(runArgs)) end,
        busyResponder
      )
      status.state, status.program = "idle", nil
      _G.ccProgress = nil

      rednet.send(sender, { cmd = "done", ok = ok }, PROTOCOL)
    end
  end
end

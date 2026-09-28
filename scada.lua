-- scada.lua - panel stanu zolwi na advanced monitorze
--
-- Uzycie:  scada        - prawdziwe zolwie przez rednet
--          scada demo   - dane testowe (bez zolwi, do sprawdzenia monitora)
--
-- Wymaga: komputer + advanced monitor (min. 2 bloki szerokosci, np. 3x2)
--         + wireless/ender modem.
-- Odswieza co REFRESH sekund; dotkniecie monitora odswieza od razu.

local PROTOCOL = "flatten"
local REFRESH  = 5      -- sekundy miedzy odpytaniami
local OFFLINE  = 15     -- po tylu sekundach bez odpowiedzi zolw jest OFFLINE
local LOW_FUEL = 500

local DEMO = ({ ... })[1] == "demo"

local mon = peripheral.find("monitor")
if not mon then error("Brak monitora!") end
if not mon.isColor() then error("Potrzebny ADVANCED monitor (kolorowy)") end
mon.setTextScale(0.5)

if not DEMO then
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then error("Brak wireless/ender modemu!") end
  rednet.open(peripheral.getName(modem))
end

-- id -> { data = <pong>, last = <czas ms> }
local known = {}

---------------------------------------------------------------------------
-- Zbieranie danych

local function now() return os.epoch("utc") end

local function pollTurtles()
  rednet.broadcast({ cmd = "ping" }, PROTOCOL)
  local deadline = os.clock() + 1.5
  while true do
    local left = deadline - os.clock()
    if left <= 0 then break end
    local id, msg = rednet.receive(PROTOCOL, left)
    if not id then break end
    if type(msg) == "table" and msg.cmd == "pong" then
      known[id] = { data = msg, last = now() }
    end
  end
end

local demoTick = 0
local function pollDemo()
  demoTick = demoTick + 1
  local p = (demoTick % 10) / 10
  known[3]  = { last = now(), data = { label = "Kopacz", state = "work", program = "flatten",
                                       progress = p, fuel = 4200, fuelLimit = 20000 } }
  known[7]  = { last = now(), data = { label = "Swiatlo", state = "work", program = "torches",
                                       progress = (p + 0.5) % 1, fuel = 320, fuelLimit = 20000 } }
  known[12] = { last = now(), data = { state = "idle", fuel = 15000, fuelLimit = 20000 } }
  known[21] = { last = now() - 60000, data = { label = "Zgubiony", state = "idle", fuel = 0 } }
end

---------------------------------------------------------------------------
-- Rysowanie

local w, h

local function put(x, y, s, fg, bg)
  mon.setCursorPos(x, y)
  if bg then mon.setBackgroundColor(bg) end
  if fg then mon.setTextColor(fg) end
  mon.write(s)
end

local function fillRow(y, bg)
  put(1, y, (" "):rep(w), nil, bg)
end

local function fit(s, n)
  s = tostring(s or "")
  if #s > n then return s:sub(1, n) end
  return s .. (" "):rep(n - #s)
end

-- Kolumny: ID(5) STAN(8) PROGRAM(9) POSTEP(reszta) PALIWO(7)
local COL_ID, COL_STATE, COL_PROG, COL_BAR = 1, 6, 14, 23

local function drawBar(x, y, width, p)
  if width < 6 then return end
  local barW = width - 5
  local filled = math.floor(barW * math.max(0, math.min(1, p)) + 0.5)
  put(x, y, (" "):rep(filled), nil, colors.lime)
  put(x + filled, y, (" "):rep(barW - filled), nil, colors.gray)
  put(x + barW, y, ("%4d%%"):format(math.floor(p * 100 + 0.5)), colors.white, colors.black)
end

local function fuelText(d)
  if d.fuel == "unlimited" then return "inf" end
  return tostring(d.fuel or "?")
end

local function draw()
  w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  if w < 36 then
    put(1, 1, "Monitor za maly", colors.red, colors.black)
    put(1, 2, "min. 2 bloki szer.", colors.red, colors.black)
    return
  end

  -- Naglowek
  fillRow(1, colors.blue)
  put(2, 1, DEMO and "SCADA - zolwie [DEMO]" or "SCADA - zolwie", colors.white, colors.blue)
  local clock = textutils.formatTime(os.time(), true)
  put(w - #clock, 1, clock, colors.white, colors.blue)

  fillRow(2, colors.gray)
  put(COL_ID, 2, "ID", colors.lightGray, colors.gray)
  put(COL_STATE, 2, "STAN", colors.lightGray, colors.gray)
  put(COL_PROG, 2, "PROGRAM", colors.lightGray, colors.gray)
  put(COL_BAR, 2, "POSTEP", colors.lightGray, colors.gray)
  put(w - 6, 2, "PALIWO", colors.lightGray, colors.gray)

  -- Wiersze zolwi
  local ids = {}
  for id in pairs(known) do ids[#ids + 1] = id end
  table.sort(ids)

  local online, y = 0, 3
  for _, id in ipairs(ids) do
    if y > h - 1 then break end
    local e, d = known[id], known[id].data
    local isOnline = (now() - e.last) < OFFLINE * 1000

    local stateTxt, stateCol
    if not isOnline then stateTxt, stateCol = "OFFLINE", colors.red
    elseif d.state == "work" then stateTxt, stateCol = "PRACA", colors.yellow
    else stateTxt, stateCol = "CZEKA", colors.lime end
    if isOnline then online = online + 1 end

    local bg = colors.black
    put(COL_ID, y, fit("#" .. id, 5), colors.white, bg)
    put(COL_STATE, y, fit(stateTxt, 8), stateCol, bg)
    put(COL_PROG, y, fit(isOnline and d.program or "-", 9), colors.lightBlue, bg)

    local barWidth = (w - 7) - COL_BAR
    if isOnline and d.state == "work" and d.progress then
      drawBar(COL_BAR, y, barWidth, d.progress)
    else
      put(COL_BAR, y, fit(d.label or "", barWidth), colors.lightGray, bg)
    end

    local fuel = fuelText(d)
    local fuelCol = (tonumber(d.fuel) and d.fuel < LOW_FUEL) and colors.red or colors.white
    put(w - 6, y, ("%6s"):format(fuel:sub(1, 6)), fuelCol, bg)
    y = y + 1
  end

  if #ids == 0 then
    put(2, 4, "Brak zolwi w zasiegu...", colors.lightGray, colors.black)
  end

  -- Stopka
  fillRow(h, colors.gray)
  put(2, h, ("Online: %d/%d  |  dotknij = odswiez"):format(online, #ids),
      colors.white, colors.gray)
end

---------------------------------------------------------------------------
-- Petla glowna

term.clear(); term.setCursorPos(1, 1)
print("SCADA dziala na monitorze. Ctrl+T - wyjscie.")

while true do
  if DEMO then pollDemo() else pollTurtles() end
  draw()

  local timer = os.startTimer(REFRESH)
  while true do
    local ev, p1 = os.pullEvent()
    if (ev == "timer" and p1 == timer) or ev == "monitor_touch" or ev == "monitor_resize" then
      break
    end
  end
end

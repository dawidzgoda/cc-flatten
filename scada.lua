-- scada.lua - panel stanu i sterowania zolwiami na advanced monitorze
--
-- Uzycie:  scada        - prawdziwe zolwie przez rednet
--          scada demo   - dane testowe (bez zolwi, do sprawdzenia monitora)
--
-- Wymaga: komputer + advanced monitor (min. 2x2 bloki, najlepiej 3x2)
--         + wireless/ender modem.
--
-- Obsluga (dotyk):
--   * lista zolwi -> dotknij zolwia, zeby go skonfigurowac,
--   * ekran konfiguracji -> wybierz program i parametry, dotknij START.

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

local function now() return os.epoch("utc") end

-- id -> { data = <pong>, last = <czas ms> }
local known = {}

-- Stan interfejsu
local view, selected = "list", nil     -- "list" albo "config"
local params = {}                      -- id -> parametry programu
local message                          -- { text, color, time }

local function setMsg(text, color)
  message = { text = text, color = color or colors.white, time = now() }
end

local function getParams(id)
  if not params[id] then
    params[id] = { program = "flatten", length = 16, width = 16, spacing = 5, center = true }
  end
  return params[id]
end

local function isOnline(e)
  return e ~= nil and (now() - e.last) < OFFLINE * 1000
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

---------------------------------------------------------------------------
-- Tryb demo: wymyslone zolwie, ktorych postep sam rosnie

local function initDemo()
  known[3]  = { last = now(), data = { label = "Kopacz", state = "work", program = "flatten",
                                       progress = 0.3, fuel = 4200, fuelLimit = 20000 } }
  known[7]  = { last = now(), data = { label = "Swiatlo", state = "work", program = "torches",
                                       progress = 0.7, fuel = 320, fuelLimit = 20000 } }
  known[12] = { last = now(), data = { state = "idle", fuel = 15000, fuelLimit = 20000 } }
  known[21] = { last = now() - 60000, data = { label = "Zgubiony", state = "idle", fuel = 0 } }
end

local function tickDemo()
  for id, e in pairs(known) do
    if id ~= 21 then
      e.last = now()
      if e.data.state == "work" then
        e.data.progress = (e.data.progress or 0) + 0.1
        if e.data.progress >= 1 then
          e.data.state, e.data.program, e.data.progress = "idle", nil, nil
          setMsg(("Zolw #%d skonczyl"):format(id), colors.lime)
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Rysowanie

local w, h
local buttons = {}

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

-- Rysuje przycisk i zapamietuje jego obszar do obslugi dotyku
local function button(x, y, label, bg, action, fg)
  put(x, y, label, fg or colors.white, bg)
  buttons[#buttons + 1] = { x1 = x, x2 = x + #label - 1, y = y, action = action }
end

local function drawBar(x, y, width, p)
  if width < 6 then return end
  local barW = width - 5
  local filled = math.floor(barW * clamp(p, 0, 1) + 0.5)
  put(x, y, (" "):rep(filled), nil, colors.lime)
  put(x + filled, y, (" "):rep(barW - filled), nil, colors.gray)
  put(x + barW, y, ("%4d%%"):format(math.floor(p * 100 + 0.5)), colors.white, colors.black)
end

local function fuelText(d)
  if d.fuel == "unlimited" then return "inf" end
  return tostring(d.fuel or "?")
end

local function stateOf(e)
  if not isOnline(e) then return "OFFLINE", colors.red end
  if e.data.state == "work" then return "PRACA", colors.yellow end
  return "CZEKA", colors.lime
end

local function drawHeader(title)
  fillRow(1, colors.blue)
  put(2, 1, title, colors.white, colors.blue)
  local clock = textutils.formatTime(os.time(), true)
  put(w - #clock, 1, clock, colors.white, colors.blue)
end

local function drawFooter(default)
  fillRow(h, colors.gray)
  if message and now() - message.time < 10000 then
    put(2, h, fit(message.text, w - 2), message.color, colors.gray)
  else
    put(2, h, fit(default, w - 2), colors.white, colors.gray)
  end
end

-- Kolumny listy: ID(5) STAN(8) PROGRAM(9) POSTEP(reszta) PALIWO(7)
local COL_ID, COL_STATE, COL_PROG, COL_BAR = 1, 6, 14, 23

local function drawList()
  drawHeader(DEMO and "SCADA - zolwie [DEMO]" or "SCADA - zolwie")

  fillRow(2, colors.gray)
  put(COL_ID, 2, "ID", colors.lightGray, colors.gray)
  put(COL_STATE, 2, "STAN", colors.lightGray, colors.gray)
  put(COL_PROG, 2, "PROGRAM", colors.lightGray, colors.gray)
  put(COL_BAR, 2, "POSTEP", colors.lightGray, colors.gray)
  put(w - 6, 2, "PALIWO", colors.lightGray, colors.gray)

  local ids = {}
  for id in pairs(known) do ids[#ids + 1] = id end
  table.sort(ids)

  local online, y = 0, 3
  for _, id in ipairs(ids) do
    if y > h - 1 then break end
    local e, d = known[id], known[id].data
    local stateTxt, stateCol = stateOf(e)
    if isOnline(e) then online = online + 1 end

    -- caly wiersz jest przyciskiem -> konfiguracja zolwia
    button(1, y, (" "):rep(w), colors.black, function()
      selected, view = id, "config"
    end)
    put(COL_ID, y, fit("#" .. id, 5), colors.white, colors.black)
    put(COL_STATE, y, fit(stateTxt, 8), stateCol, colors.black)
    put(COL_PROG, y, fit(isOnline(e) and d.program or "-", 9), colors.lightBlue, colors.black)

    local barWidth = (w - 7) - COL_BAR
    if isOnline(e) and d.state == "work" and d.progress then
      drawBar(COL_BAR, y, barWidth, d.progress)
    else
      put(COL_BAR, y, fit(d.label or "", barWidth), colors.lightGray, colors.black)
    end

    local fuelCol = (tonumber(d.fuel) and d.fuel < LOW_FUEL) and colors.red or colors.white
    put(w - 6, y, ("%6s"):format(fuelText(d):sub(1, 6)), fuelCol, colors.black)
    y = y + 1
  end

  if #ids == 0 then
    put(2, 4, "Brak zolwi w zasiegu...", colors.lightGray, colors.black)
  end

  drawFooter(("Online: %d/%d | dotknij zolwia = ustawienia"):format(online, #ids))
end

-- Wiersz z wartoscia liczbowa i przyciskami -10 -1 +1 +10
local function numberRow(y, label, value, set, bigStep)
  put(2, y, label, colors.lightGray, colors.black)
  button(10, y, " -" .. bigStep .. " ", colors.red, function() set(value - bigStep) end)
  button(16, y, " -1 ", colors.red, function() set(value - 1) end)
  put(21, y, ("%4d"):format(value), colors.white, colors.black)
  button(26, y, " +1 ", colors.green, function() set(value + 1) end)
  button(31, y, " +" .. bigStep .. " ", colors.green, function() set(value + bigStep) end)
end

local function toggle(x, y, label, active, action)
  button(x, y, label, active and colors.blue or colors.gray, action,
         active and colors.white or colors.lightGray)
end

local function startSelected()
  local e = known[selected]
  if not isOnline(e) then setMsg("Zolw #" .. selected .. " jest offline", colors.red); return end
  if e.data.state == "work" then setMsg("Zolw #" .. selected .. " jest zajety", colors.red); return end

  local p = getParams(selected)
  if DEMO then
    e.data.state, e.data.program, e.data.progress = "work", p.program, 0
    setMsg(("Zolw #%d: start %s (demo)"):format(selected, p.program), colors.yellow)
  else
    rednet.send(selected, {
      cmd = "start", program = p.program,
      length = p.length, width = p.width,
      spacing = p.program == "torches" and p.spacing or nil,
      center = p.center,
    }, PROTOCOL)
    setMsg(("Wyslano start do #%d..."):format(selected), colors.yellow)
  end
  view = "list"
end

local function drawConfig()
  local e = known[selected]
  local d = e and e.data or {}
  local p = getParams(selected)

  drawHeader(("Zolw #%d %s"):format(selected, d.label or ""))

  local stateTxt, stateCol = stateOf(e)
  put(2, 2, "Stan: ", colors.lightGray, colors.black)
  put(8, 2, stateTxt, stateCol, colors.black)
  put(17, 2, "Paliwo: " .. fuelText(d), colors.lightGray, colors.black)

  put(2, 4, "Program", colors.lightGray, colors.black)
  toggle(10, 4, " WYROWNAJ ", p.program == "flatten", function() p.program = "flatten" end)
  toggle(21, 4, " POCHODNIE ", p.program == "torches", function() p.program = "torches" end)

  numberRow(6, "Dlugosc", p.length, function(v) p.length = clamp(v, 1, 256) end, 10)
  numberRow(8, "Szerok.", p.width,  function(v) p.width  = clamp(v, 1, 256) end, 10)

  if p.program == "torches" then
    numberRow(10, "Odstep", p.spacing, function(v) p.spacing = clamp(v, 1, 32) end, 5)
  end

  put(2, 12, "Srodek", colors.lightGray, colors.black)
  toggle(10, 12, " TAK ", p.center, function() p.center = true end)
  toggle(16, 12, " NIE ", not p.center, function() p.center = false end)

  button(2, 14, " START ", colors.green, startSelected)
  button(10, 14, " WSTECZ ", colors.gray, function() view = "list" end)

  drawFooter(p.center and "Zolw stoi na srodku obszaru" or "Zolw stoi w rogu, obszar w prawo")
end

local function draw()
  w, h = mon.getSize()
  buttons = {}
  mon.setBackgroundColor(colors.black)
  mon.clear()

  if w < 36 or h < 15 then
    put(1, 1, "Monitor za maly", colors.red, colors.black)
    put(1, 2, "min. 2x2 bloki", colors.red, colors.black)
    return
  end

  if view == "config" and selected then drawConfig() else drawList() end
end

---------------------------------------------------------------------------
-- Watki: odbior wiadomosci, odpytywanie, dotyk

-- Odbiera odpowiedzi zolwi (pong, started, done, error)
local function receiver()
  if DEMO then while true do os.pullEvent("__never") end end
  while true do
    local id, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" then
      if msg.cmd == "pong" then
        known[id] = { data = msg, last = now() }
      elseif msg.cmd == "started" then
        if known[id] then known[id].data.state = "work"; known[id].data.progress = 0 end
        setMsg(("Zolw #%d wystartowal"):format(id), colors.lime)
        draw()
      elseif msg.cmd == "done" then
        setMsg(("Zolw #%d: %s"):format(id, msg.ok and "gotowe!" or "przerwal (blad)"),
               msg.ok and colors.lime or colors.red)
        draw()
      elseif msg.cmd == "error" then
        setMsg(("Zolw #%d: %s"):format(id, tostring(msg.text)), colors.red)
        draw()
      end
    end
  end
end

-- Co REFRESH sekund odpytuje zolwie i odswieza ekran
local function pinger()
  while true do
    if DEMO then
      tickDemo()
      draw()
      sleep(REFRESH)
    else
      rednet.broadcast({ cmd = "ping" }, PROTOCOL)
      sleep(1.5) -- czas na odpowiedzi
      draw()
      sleep(REFRESH - 1.5)
    end
  end
end

-- Obsluga dotyku monitora
local function ui()
  while true do
    local ev, _, x, y = os.pullEvent()
    if ev == "monitor_touch" then
      for _, b in ipairs(buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then b.action(); break end
      end
      draw()
    elseif ev == "monitor_resize" then
      draw()
    end
  end
end

---------------------------------------------------------------------------

term.clear(); term.setCursorPos(1, 1)
print("SCADA dziala na monitorze. Ctrl+T - wyjscie.")

if DEMO then initDemo() end
draw()
parallel.waitForAny(receiver, pinger, ui)

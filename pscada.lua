-- pscada.lua - mini SCADA na (advanced) pocket computer
--
-- Uzycie:  pscada        - dane z zolwi i czujnikow (lavasensor/energysensor)
--          pscada demo   - dane testowe
--
-- Obsluga: dotknij zakladki u gory albo klawisze 1/2/3, Q - wyjscie.
-- Pojemnosc lawy do paska (mB):  set scada.lava_max 720000
-- Prog alarmu lawy (mB):         set scada.lava_low 50000

local PROTOCOL        = "flatten"
local LAVA_PROTOCOL   = "scada_lava"
local ENERGY_PROTOCOL = "scada_energy"
local REFRESH         = 5
local OFFLINE         = 15
local ENERGY_LOW_PCT  = 20
local LOW_FUEL        = 500

local DEMO = ({ ... })[1] == "demo"

local lavaMax = settings.get("scada.lava_max", 64000)
local lavaLow = settings.get("scada.lava_low", 8000)

if not DEMO then
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then error("Pocket nie ma modemu!") end
  rednet.open(peripheral.getName(modem))
end

local color = term.isColor()
local function c(col, fallback) return color and col or (fallback or colors.white) end

local function now() return os.epoch("utc") end
local function isOnline(e) return e ~= nil and (now() - e.last) < OFFLINE * 1000 end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local turtles, lavaSensors, energySensors = {}, {}, {}
local lavaHist, energyHist = {}, {}
local view = "turtles"

---------------------------------------------------------------------------
-- Dane

local function totals()
  local lava, en, cap = 0, 0, 0
  for _, s in pairs(lavaSensors) do if isOnline(s) then lava = lava + s.total end end
  for _, s in pairs(energySensors) do
    if isOnline(s) then en, cap = en + s.energy, cap + s.capacity end
  end
  return lava, en, cap
end

local function pushHist(hist, v)
  hist[#hist + 1] = { t = now(), v = v }
  if #hist > 24 then table.remove(hist, 1) end   -- 2 min historii
end

-- zmiana na minute z historii
local function ratePerMin(hist)
  if #hist < 2 then return 0 end
  local a, b = hist[1], hist[#hist]
  local dt = (b.t - a.t) / 60000
  return dt > 0 and (b.v - a.v) / dt or 0
end

local function demoTick()
  local t = os.clock()
  turtles[3] = { last = now(), data = { label = "Kopacz", state = "work", program = "flatten",
                                        progress = (t / 60) % 1, fuel = 4200 } }
  turtles[7] = { last = now(), data = { state = "idle", fuel = 320 } }
  turtles[21] = turtles[21] or { last = now() - 60000, data = { state = "idle", fuel = 0 } }
  lavaSensors[5] = { last = now(), label = "Zbiorniki", total = math.floor(400000 + 200000 * math.sin(t / 20)) }
  energySensors[6] = { last = now(), label = "Prad", capacity = 70e6,
                       energy = math.floor(35e6 + 30e6 * math.sin(t / 30)) }
end

---------------------------------------------------------------------------
-- Rysowanie

local w, h = term.getSize()

local function put(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.write(s)
end

local function fillRow(y, bg) put(1, y, (" "):rep(w), nil, bg) end

local function fit(s, n)
  s = tostring(s or "")
  if #s > n then return s:sub(1, n) end
  return s .. (" "):rep(n - #s)
end

local function bar(y, p, col)
  local bw = w - 6
  local f = math.floor(bw * clamp(p, 0, 1) + 0.5)
  put(2, y, (" "):rep(f), nil, c(col, colors.white))
  put(2 + f, y, (" "):rep(bw - f), nil, c(colors.gray, colors.black))
  put(w - 4, y, ("%3d%%"):format(math.floor(p * 100 + 0.5)), colors.white, colors.black)
end

local function fmtFE(n)
  local units = { "", "k", "M", "G", "T" }
  local i = 1
  while math.abs(n) >= 1000 and i < #units do n = n / 1000; i = i + 1 end
  return ("%.1f%sFE"):format(n, units[i])
end

local function sortedIds(t)
  local ids = {}
  for id in pairs(t) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local TABS = {
  { x = 1,  label = " ZOLW ", view = "turtles" },
  { x = 7,  label = " LAWA ", view = "lava" },
  { x = 13, label = " PRAD ", view = "energy" },
}

local function drawTabs(lava, en, cap)
  fillRow(1, c(colors.blue, colors.black))
  local alarm = {
    lava = #lavaHist > 0 and next(lavaSensors) ~= nil and lava < lavaLow,
    energy = cap > 0 and en / cap * 100 < ENERGY_LOW_PCT,
  }
  for _, t in ipairs(TABS) do
    local active = view == t.view
    local bg = active and c(colors.lightBlue, colors.white)
            or (alarm[t.view] and c(colors.red) or c(colors.gray, colors.black))
    put(t.x, 1, t.label, active and colors.black or colors.white, bg)
  end
  local clock = textutils.formatTime(os.time(), true)
  put(w - #clock + 1, 1, clock, colors.white, c(colors.blue, colors.black))
end

local function drawTurtles()
  fillRow(2, c(colors.gray, colors.black))
  put(1, 2, "ID  STAN     %  PALIWO", colors.white, c(colors.gray, colors.black))
  local y = 3
  for _, id in ipairs(sortedIds(turtles)) do
    if y > h - 1 then break end
    local e, d = turtles[id], turtles[id].data
    local st, col
    if not isOnline(e) then st, col = "OFFLN", colors.red
    elseif d.state == "work" then st, col = "PRACA", colors.yellow
    else st, col = "CZEKA", colors.lime end
    put(1, y, fit("#" .. id, 4), colors.white, colors.black)
    put(5, y, fit(st, 6), c(col), colors.black)
    local pr = (isOnline(e) and d.state == "work" and d.progress)
               and ("%3d%%"):format(math.floor(d.progress * 100)) or "   -"
    put(11, y, pr, colors.white, colors.black)
    local fuel = d.fuel == "unlimited" and "inf" or tostring(d.fuel or "?")
    local fc = (tonumber(d.fuel) and d.fuel < LOW_FUEL) and c(colors.red) or colors.white
    put(17, y, ("%7s"):format(fuel:sub(1, 7)), fc, colors.black)
    y = y + 1
    if d.label and y <= h - 1 then
      put(2, y, fit(d.label, w - 2), c(colors.lightGray), colors.black)
      y = y + 1
    end
  end
  if y == 3 then put(1, 4, "Brak zolwi w zasiegu", c(colors.lightGray), colors.black) end
end

local function drawLava(lava)
  local low = lava < lavaLow
  put(1, 3, ("Zapas: %.1f B"):format(lava / 1000), low and c(colors.red) or c(colors.orange), colors.black)
  local r = ratePerMin(lavaHist) / 1000
  put(1, 4, ("Trend: %+.1f B/min"):format(r),
      r < 0 and c(colors.red) or (r > 0 and c(colors.lime) or colors.white), colors.black)
  bar(5, lava / lavaMax, low and colors.red or colors.orange)
  put(1, 6, ("max %.0f B, alarm < %.0f B"):format(lavaMax / 1000, lavaLow / 1000),
      c(colors.gray, colors.white), colors.black)

  local y = 8
  for _, id in ipairs(sortedIds(lavaSensors)) do
    if y > h - 1 then break end
    local s = lavaSensors[id]
    put(1, y, fit(s.label or ("#" .. id), 14), colors.white, colors.black)
    if isOnline(s) then
      put(15, y, ("%10s"):format(("%.1f B"):format(s.total / 1000)), c(colors.orange), colors.black)
    else
      put(15, y, ("%10s"):format("OFFLINE"), c(colors.red), colors.black)
    end
    y = y + 1
  end
  if y == 8 then put(1, 8, "Brak czujnikow lawy", c(colors.lightGray), colors.black) end
end

local function drawEnergy(en, cap)
  local p = cap > 0 and en / cap or 0
  local col = p * 100 < ENERGY_LOW_PCT and colors.red or (p < 0.5 and colors.yellow or colors.lime)
  put(1, 3, fmtFE(en) .. " / " .. fmtFE(cap), c(col), colors.black)
  bar(4, p, col)
  local r = ratePerMin(energyHist) / 1200     -- FE/min -> FE/t
  put(1, 5, (r > 0 and "+" or "") .. fmtFE(r) .. "/t",
      r < 0 and c(colors.red) or (r > 0 and c(colors.lime) or colors.white), colors.black)
  if r ~= 0 and cap > 0 then
    local mins = (r > 0 and (cap - en) / r or en / -r) / 1200
    local txt = mins >= 600 and ">10 h" or
                (mins >= 60 and ("%.1f h"):format(mins / 60) or ("%d min"):format(math.floor(mins)))
    put(1, 6, (r > 0 and "Pelne za: " or "Puste za: ") .. txt,
        r > 0 and c(colors.lightGray) or c(colors.orange), colors.black)
  end

  local y = 8
  for _, id in ipairs(sortedIds(energySensors)) do
    if y > h - 1 then break end
    local s = energySensors[id]
    put(1, y, fit(s.label or ("#" .. id), 14), colors.white, colors.black)
    if isOnline(s) then
      local sp = s.capacity > 0 and math.floor(s.energy / s.capacity * 100 + 0.5) or 0
      put(15, y, ("%10s"):format(sp .. "%"), c(colors.yellow), colors.black)
    else
      put(15, y, ("%10s"):format("OFFLINE"), c(colors.red), colors.black)
    end
    y = y + 1
  end
  if y == 8 then put(1, 8, "Brak czujnikow pradu", c(colors.lightGray), colors.black) end
end

local function draw()
  w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  local lava, en, cap = totals()
  drawTabs(lava, en, cap)

  if view == "lava" then drawLava(lava)
  elseif view == "energy" then drawEnergy(en, cap)
  else drawTurtles() end

  fillRow(h, c(colors.gray, colors.black))
  put(1, h, DEMO and "DEMO | 1/2/3, Q-wyjscie" or "1/2/3 zakladki, Q-wyjscie",
      colors.white, c(colors.gray, colors.black))
end

---------------------------------------------------------------------------
-- Watki

local function receiver()
  if DEMO then while true do os.pullEvent("__never") end end
  while true do
    local id, msg, proto = rednet.receive()
    if type(msg) == "table" then
      if proto == PROTOCOL and msg.cmd == "pong" then
        turtles[id] = { data = msg, last = now() }
      elseif proto == LAVA_PROTOCOL and msg.cmd == "lava" then
        lavaSensors[id] = { label = msg.label, total = tonumber(msg.total) or 0, last = now() }
      elseif proto == ENERGY_PROTOCOL and msg.cmd == "energy" then
        energySensors[id] = { label = msg.label, energy = tonumber(msg.energy) or 0,
                              capacity = tonumber(msg.capacity) or 0, last = now() }
      end
    end
  end
end

local function pinger()
  while true do
    if DEMO then demoTick() else rednet.broadcast({ cmd = "ping" }, PROTOCOL) end
    sleep(1.5)
    local lava, en = totals()
    pushHist(lavaHist, lava)
    pushHist(energyHist, en)
    draw()
    sleep(REFRESH - 1.5)
  end
end

local function ui()
  while true do
    local ev, a, x, y = os.pullEvent()
    if ev == "mouse_click" and y == 1 then
      for _, t in ipairs(TABS) do
        if x >= t.x and x < t.x + #t.label then view = t.view end
      end
      draw()
    elseif ev == "key" then
      if a == keys.one then view = "turtles"
      elseif a == keys.two then view = "lava"
      elseif a == keys.three then view = "energy"
      elseif a == keys.q then return end
      draw()
    end
  end
end

draw()
parallel.waitForAny(receiver, pinger, ui)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

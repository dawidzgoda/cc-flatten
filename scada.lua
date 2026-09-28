-- scada.lua - panel stanu i sterowania zolwiami na advanced monitorze
--
-- Uzycie:  scada        - prawdziwe zolwie przez rednet
--          scada demo   - dane testowe (bez zolwi, do sprawdzenia monitora)
--
-- Wymaga: komputer + advanced monitor (min. 2x2 bloki, najlepiej 3x2)
--         + wireless/ender modem.
--
-- Obsluga (dotyk):
--   * zakladki w naglowku: ZOLWIE / LAWA,
--   * lista zolwi -> dotknij zolwia, zeby go skonfigurowac,
--   * ekran konfiguracji -> wybierz program i parametry, dotknij START,
--   * LAWA -> zapas lawy ze zbiornikow i skrzyn z wiadrami podlaczonych
--     do komputera (bezposrednio albo wired modemem + kablem).

local PROTOCOL      = "flatten"
local LAVA_PROTOCOL = "scada_lava"   -- dane z czujnikow lavasensor
local REFRESH  = 5      -- sekundy miedzy odpytaniami
local OFFLINE  = 15     -- po tylu sekundach bez odpowiedzi zolw jest OFFLINE
local LOW_FUEL = 500

local LAVA        = "minecraft:lava"
local LAVA_BUCKET = "minecraft:lava_bucket"
-- Pojemnosc i prog alarmu (mB) ustawia sie dotykiem w zakladce LAWA -> USTAW;
-- zapisywane w ustawieniach komputera (settings), wiec przetrwaja restart.
-- Create: 1 blok zbiornika = 8 wiader (8000 mB).
local lavaMax = settings.get("scada.lava_max", 64000)
local lavaLow = settings.get("scada.lava_low", 8000)

local function saveLavaSettings()
  settings.set("scada.lava_max", lavaMax)
  settings.set("scada.lava_low", lavaLow)
  settings.save()
end
local HISTORY_MAX = 120     -- probek historii (120 x 5 s = 10 min)

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
-- Lawa: zbiorniki (tanks) i skrzynie z wiadrami (list)

local lava = { total = 0, sources = {}, history = {} }  -- history: { t, mB }

local function scanLava()
  local total, sources = 0, {}
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    local amount, show = 0, false

    if p.tanks then
      local ok, tanks = pcall(p.tanks)
      if ok and type(tanks) == "table" then
        local other = false
        for _, t in pairs(tanks) do
          if t.name == LAVA then amount = amount + t.amount
          elseif t.amount and t.amount > 0 then other = true end
        end
        -- pokaz zbiornik z lawa albo pusty (zbiornik z woda pomijamy)
        show = amount > 0 or not other
      end
    end

    if p.list then
      local ok, items = pcall(p.list)
      if ok and type(items) == "table" then
        for _, it in pairs(items) do
          if it.name == LAVA_BUCKET then
            amount = amount + it.count * 1000
            show = true
          end
        end
      end
    end

    if show then
      sources[#sources + 1] = { name = name, amount = amount }
      total = total + amount
    end
  end
  table.sort(sources, function(a, b) return a.amount > b.amount end)
  return total, sources
end

local function scanLavaDemo()
  local t = os.clock()
  local a = math.floor(24000 + 14000 * math.sin(t / 20))
  local b = math.floor(9000 + 6000 * math.cos(t / 13))
  return a + b + 5000, {
    { name = "create:fluid_tank_0", amount = a },
    { name = "create:fluid_tank_1", amount = b },
    { name = "minecraft:chest_2",   amount = 5000 },
  }
end

-- Dane z czujnikow lawy (lavasensor) na innych komputerach:
-- id -> { label, total, sources, last }
local remoteLava = {}

local function shortName(n) return n:match(":(.+)$") or n end

local function sampleLava()
  local total, sources = (DEMO and scanLavaDemo or scanLava)()

  -- doliczamy czujniki zdalne; nieaktywny czujnik pokazujemy jako OFFLINE
  for id, r in pairs(remoteLava) do
    local prefix = (r.label or ("#" .. id)) .. "/"
    if isOnline(r) then
      for _, s in ipairs(r.sources) do
        sources[#sources + 1] = { name = prefix .. shortName(s.name), amount = s.amount }
      end
      total = total + r.total
    else
      sources[#sources + 1] = { name = prefix .. "OFFLINE", amount = 0, offline = true }
    end
  end
  table.sort(sources, function(a, b) return a.amount > b.amount end)

  lava.total, lava.sources = total, sources
  local hist = lava.history
  hist[#hist + 1] = { t = now(), v = lava.total }
  if #hist > HISTORY_MAX then table.remove(hist, 1) end
end

-- Zmiana zapasu w mB/min liczona z ostatniej minuty historii
local function lavaRate()
  local hist = lava.history
  if #hist < 2 then return 0 end
  local last = hist[#hist]
  local first = hist[1]
  for i = #hist - 1, 1, -1 do
    first = hist[i]
    if last.t - hist[i].t >= 60000 then break end
  end
  local dt = (last.t - first.t) / 60000
  if dt <= 0 then return 0 end
  return (last.v - first.v) / dt
end

local function buckets(mB) return ("%.1f B"):format(mB / 1000) end

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

-- Naglowek z zakladkami ZOLWIE / LAWA
local function drawTabs()
  fillRow(1, colors.blue)
  put(1, 1, " SCADA ", colors.white, colors.blue)

  local function tab(x, label, name, alarm)
    local active = (view == name)
    local bg = active and colors.lightBlue or (alarm and colors.red or colors.gray)
    button(x, 1, label, bg, function() view = name end, active and colors.black or colors.white)
  end
  tab(9, " ZOLWIE ", "list")
  tab(18, " LAWA ", "lava", #lava.history > 0 and lava.total < lavaLow)

  if DEMO then put(25, 1, "[DEMO]", colors.yellow, colors.blue) end
  local clock = textutils.formatTime(os.time(), true)
  put(w - #clock, 1, clock, colors.white, colors.blue)
end

local function drawFooter(default, color)
  fillRow(h, colors.gray)
  if message and now() - message.time < 10000 then
    put(2, h, fit(message.text, w - 2), message.color, colors.gray)
  else
    put(2, h, fit(default, w - 2), color or colors.white, colors.gray)
  end
end

-- Kolumny listy: ID(5) STAN(8) PROGRAM(9) POSTEP(reszta) PALIWO(7)
local COL_ID, COL_STATE, COL_PROG, COL_BAR = 1, 6, 14, 23

local function drawList()
  drawTabs()

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

-- Wiersz z wartoscia liczbowa i przyciskami -duzy -maly wartosc +maly +duzy
local function numberRow(y, label, value, set, bigStep, smallStep)
  smallStep = smallStep or 1
  put(2, y, label, colors.lightGray, colors.black)
  local x = 10
  local function btn(txt, col, v)
    button(x, y, " " .. txt .. " ", col, function() set(v) end)
    x = x + #txt + 3
  end
  btn("-" .. bigStep, colors.red, value - bigStep)
  btn("-" .. smallStep, colors.red, value - smallStep)
  put(x, y, ("%5d"):format(value), colors.white, colors.black)
  x = x + 6
  btn("+" .. smallStep, colors.green, value + smallStep)
  btn("+" .. bigStep, colors.green, value + bigStep)
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

local function drawLava()
  drawTabs()
  local total = lava.total
  local low = #lava.history > 0 and total < lavaLow

  -- Podsumowanie i trend
  put(2, 3, "Zapas:", colors.lightGray, colors.black)
  put(9, 3, ("%s / %s"):format(buckets(total), buckets(lavaMax)),
      low and colors.red or colors.orange, colors.black)
  local rate = lavaRate()
  local rateTxt = ("%+.1f B/min"):format(rate / 1000)
  local rateCol = rate < 0 and colors.red or (rate > 0 and colors.lime or colors.lightGray)
  put(w - #rateTxt, 3, rateTxt, rateCol, colors.black)

  -- Pasek wypelnienia
  local barW = w - 2
  local filled = math.floor(barW * clamp(total / lavaMax, 0, 1) + 0.5)
  put(2, 4, (" "):rep(filled), nil, low and colors.red or colors.orange)
  put(2 + filled, 4, (" "):rep(barW - filled), nil, colors.gray)

  button(w - 7, 5, " USTAW ", colors.blue, function() view = "lavacfg" end)

  -- Zrodla (max 4 wiersze)
  fillRow(6, colors.gray)
  put(2, 6, "ZRODLO", colors.lightGray, colors.gray)
  put(w - 6, 6, "ZAPAS", colors.lightGray, colors.gray)
  local y = 7
  for i, s in ipairs(lava.sources) do
    if i > 4 then
      put(2, y, ("... i %d wiecej"):format(#lava.sources - 4), colors.lightGray, colors.black)
      y = y + 1
      break
    end
    put(2, y, fit(s.name, w - 14), s.offline and colors.red or colors.white, colors.black)
    put(w - 10, y, ("%10s"):format(s.offline and "-" or buckets(s.amount)),
        colors.orange, colors.black)
    y = y + 1
  end
  if #lava.sources == 0 then
    put(2, y, "Brak zbiornikow/skrzyn z lawa", colors.red, colors.black)
    y = y + 1
  end

  -- Wykres historii (ostatnie probki, prawa strona = teraz)
  local gTop, gBot = y + 2, h - 1
  if gBot - gTop >= 1 then
    put(2, gTop - 1, ("Historia (%d min)"):format(math.floor(HISTORY_MAX * REFRESH / 60)),
        colors.lightGray, colors.black)
    local gh, gw = gBot - gTop + 1, w - 2
    local hist = lava.history
    local maxV = lavaMax
    for _, s in ipairs(hist) do maxV = math.max(maxV, s.v) end
    local start = math.max(1, #hist - gw + 1)
    for i = start, #hist do
      local x = 2 + gw - 1 - (#hist - i)
      local bh = math.floor(gh * hist[i].v / maxV + 0.5)
      local col = hist[i].v < lavaLow and colors.red or colors.orange
      for r = 0, bh - 1 do put(x, gBot - r, " ", nil, col) end
    end
  end

  if low then
    drawFooter(("ALARM: malo lawy (< %s)"):format(buckets(lavaLow)), colors.red)
  elseif total > lavaMax then
    drawFooter("Zapas > pojemnosc - popraw w USTAW", colors.yellow)
  else
    drawFooter(("Zrodel: %d | probka co %d s"):format(#lava.sources, REFRESH))
  end
end

-- Ustawienia lawy: pojemnosc i prog alarmu (w wiadrach), zapis od razu
local function drawLavaCfg()
  drawHeader("Ustawienia lawy")

  local maxB, lowB = math.floor(lavaMax / 1000), math.floor(lavaLow / 1000)

  put(2, 3, "Pojemnosc calkowita (wiadra):", colors.lightGray, colors.black)
  numberRow(4, "Max", maxB, function(v)
    lavaMax = clamp(v, 1, 99999) * 1000
    saveLavaSettings()
  end, 64, 8)
  put(2, 5, "Create: 8 B = 1 blok zbiornika", colors.gray, colors.black)

  put(2, 7, "Alarm ponizej (wiadra):", colors.lightGray, colors.black)
  numberRow(8, "Alarm", lowB, function(v)
    lavaLow = clamp(v, 0, 99999) * 1000
    saveLavaSettings()
  end, 10, 1)

  button(2, 10, " = TERAZ ", colors.orange, function()
    -- pojemnosc = obecny zapas zaokraglony w gore do pelnego bloku Create
    lavaMax = math.max(8000, math.ceil(lava.total / 8000) * 8000)
    saveLavaSettings()
  end, colors.black)
  put(12, 10, "max = obecny zapas", colors.gray, colors.black)

  put(2, 12, ("Teraz: %s"):format(buckets(lava.total)), colors.orange, colors.black)

  button(2, 14, " WSTECZ ", colors.gray, function() view = "lava" end)

  drawFooter("Zmiany zapisuja sie od razu")
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

  if view == "config" and selected then drawConfig()
  elseif view == "lava" then drawLava()
  elseif view == "lavacfg" then drawLavaCfg()
  else drawList() end
end

---------------------------------------------------------------------------
-- Watki: odbior wiadomosci, odpytywanie, dotyk

-- Odbiera odpowiedzi zolwi (pong, started, done, error)
local function receiver()
  if DEMO then while true do os.pullEvent("__never") end end
  while true do
    local id, msg, proto = rednet.receive()
    if proto == LAVA_PROTOCOL and type(msg) == "table" and msg.cmd == "lava" then
      remoteLava[id] = {
        label = msg.label, total = tonumber(msg.total) or 0,
        sources = type(msg.sources) == "table" and msg.sources or {}, last = now(),
      }
    elseif proto == PROTOCOL and type(msg) == "table" then
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
    sampleLava()
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

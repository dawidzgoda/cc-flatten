-- scada.lua - panel stanu i sterowania zolwiami na advanced monitorze
--
-- Uzycie:  scada        - prawdziwe zolwie przez rednet
--          scada demo   - dane testowe (bez zolwi, do sprawdzenia monitora)
--
-- Wymaga: komputer + advanced monitor (min. 2x2 bloki, najlepiej 3x2)
--         + wireless/ender modem.
--
-- Obsluga (dotyk):
--   * zakladki w naglowku: ZOLWIE / LAWA / PRAD,
--   * PRAD -> magazyny FE (np. Powah) lokalnie i z czujnikow energysensor,
--   * lista zolwi -> dotknij zolwia, zeby go skonfigurowac,
--   * ekran konfiguracji -> wybierz program i parametry, dotknij START,
--   * LAWA -> zapas lawy ze zbiornikow i skrzyn z wiadrami podlaczonych
--     do komputera (bezposrednio albo wired modemem + kablem).

local PROTOCOL      = "flatten"
local LAVA_PROTOCOL = "scada_lava"   -- dane z czujnikow lavasensor
local ENERGY_PROTOCOL = "scada_energy" -- dane z czujnikow energysensor
local ENERGY_LOW_PCT  = 20           -- % naladowania: ponizej alarm
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
        -- demo alarmu: zolw #3 "czeka na paliwo" w polowie pracy
        e.data.waiting = (id == 3 and e.data.progress > 0.5 and e.data.progress < 0.8)
                         and "brak paliwa" or nil
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
  local online = 0
  for _, s in ipairs(sources) do if not s.offline then online = online + 1 end end
  local hist = lava.history
  -- sig = zestaw zrodel; bilans liczymy tylko z probek o tym samym zestawie
  hist[#hist + 1] = { t = now(), v = lava.total, sig = online }
  if #hist > HISTORY_MAX then table.remove(hist, 1) end
end

-- Zmiana na jednostke czasu z ostatniej minuty historii. Bierze tylko probki
-- z tym samym zestawem zrodel co ostatnia (sig) - inaczej start programu albo
-- chwilowy zanik czujnika dawalby ogromny, falszywy bilans.
local function histRate(hist, msPerUnit)
  if #hist < 2 then return 0 end
  local last, first = hist[#hist], nil
  for i = #hist - 1, 1, -1 do
    if hist[i].sig ~= last.sig then break end
    first = hist[i]
    if last.t - hist[i].t >= 60000 then break end
  end
  if not first then return 0 end
  local dt = (last.t - first.t) / msPerUnit
  if dt <= 0 then return 0 end
  return (last.v - first.v) / dt
end

-- mB na minute
local function lavaRate() return histRate(lava.history, 60000) end

local function buckets(mB) return ("%.1f B"):format(mB / 1000) end

---------------------------------------------------------------------------
-- Prad (FE): magazyny energy_storage (np. Powah) lokalnie + czujniki zdalne

local energy = { total = 0, capacity = 0, sources = {}, history = {} }
local remoteEnergy = {}   -- id -> { label, energy, capacity, sources, last }

local function scanEnergy()
  local total, capacity, sources = 0, 0, {}
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p.getEnergy and p.getEnergyCapacity then
      local ok1, e = pcall(p.getEnergy)
      local ok2, c = pcall(p.getEnergyCapacity)
      if ok1 and ok2 and tonumber(e) and tonumber(c) and c > 0 then
        sources[#sources + 1] = { name = name, energy = e, capacity = c }
        total, capacity = total + e, capacity + c
      end
    end
  end
  return total, capacity, sources
end

local function scanEnergyDemo()
  local t = os.clock()
  local a = math.floor(30e6 + 25e6 * math.sin(t / 25))
  local b = math.floor(4e6 + 3e6 * math.cos(t / 11))
  return a + b, 60e6 + 10e6, {
    { name = "powah:energy_cell_0", energy = a, capacity = 60e6 },
    { name = "powah:energy_cell_1", energy = b, capacity = 10e6 },
  }
end

local function sampleEnergy()
  local total, capacity, sources = (DEMO and scanEnergyDemo or scanEnergy)()

  for id, r in pairs(remoteEnergy) do
    local prefix = (r.label or ("#" .. id)) .. "/"
    if isOnline(r) then
      for _, s in ipairs(r.sources) do
        sources[#sources + 1] = {
          name = prefix .. shortName(s.name), energy = s.energy, capacity = s.capacity,
        }
      end
      total, capacity = total + r.energy, capacity + r.capacity
    else
      sources[#sources + 1] = { name = prefix .. "OFFLINE", energy = 0, capacity = 0, offline = true }
    end
  end
  table.sort(sources, function(a, b) return a.energy > b.energy end)

  energy.total, energy.capacity, energy.sources = total, capacity, sources
  local hist = energy.history
  -- sig = laczna pojemnosc: zmienia sie, gdy czujnik zniknie/dojdzie
  hist[#hist + 1] = { t = now(), v = total, sig = capacity }
  if #hist > HISTORY_MAX then table.remove(hist, 1) end
end

-- Bilans w FE/t (1 tick = 50 ms)
local function energyRate() return histRate(energy.history, 50) end

local function energyPct()
  if energy.capacity <= 0 then return 0 end
  return energy.total / energy.capacity * 100
end

local function energyLow()
  return #energy.history > 0 and energy.capacity > 0 and energyPct() < ENERGY_LOW_PCT
end

local function fmtFE(n)
  local units = { "", "k", "M", "G", "T" }
  local i = 1
  while math.abs(n) >= 1000 and i < #units do n = n / 1000; i = i + 1 end
  return ("%.1f %sFE"):format(n, units[i])
end

---------------------------------------------------------------------------
-- Alarmy
--
-- Stany alarmu: AKTYWNY niepotwierdzony (czerwony, miga), AKTYWNY potwierdzony
-- (pomaranczowy), USTAPIL niepotwierdzony (zolty). Potwierdzony i ustapiony
-- znika z listy. Kazda zmiana trafia do dziennika zdarzen.

local ALARM_PROTOCOL = "scada_alarm"
-- Push na prawdziwy telefon przez ntfy.sh (aplikacja ntfy):
--   set scada.ntfy <twoj_tajny_temat>     (pusty = wylaczone)
local NTFY_TOPIC = settings.get("scada.ntfy")
if NTFY_TOPIC == "" then NTFY_TOPIC = nil end

local alarms   = {}   -- key -> { key, text, crit, since, active, acked }
local latched  = {}   -- key -> { text, crit } alarmy zdarzeniowe, trwaja do potwierdzenia
local alarmLog = {}   -- { t, text, color }, najnowsze na poczatku
local speaker  = peripheral.find("speaker")
local blink    = false

local function logEvent(text, color)
  table.insert(alarmLog, 1, { t = now(), text = text, color = color })
  if #alarmLog > 30 then table.remove(alarmLog) end
end

local function notifyPhone(a)
  if not NTFY_TOPIC or not http or DEMO then return end
  pcall(http.post, "https://ntfy.sh/" .. NTFY_TOPIC, a.text, {
    Title = a.crit and "SCADA ALARM" or "SCADA ostrzezenie",
    Priority = a.crit and "high" or "default",
    Tags = a.crit and "rotating_light" or "warning",
  })
end

-- Wszystkie warunki alarmowe w tej chwili: key -> { text, crit }
local function alarmConditions()
  local c = {}
  local function add(key, text, crit) c[key] = { text = text, crit = crit } end

  if #lava.history > 0 and #lava.sources > 0 and lava.total < lavaLow then
    add("lava_low", "Malo lawy: " .. buckets(lava.total), true)
  end
  if energyLow() then
    add("energy_low", ("Malo pradu: %d%%"):format(math.floor(energyPct())), true)
  end

  for id, e in pairs(known) do
    local name = "Zolw #" .. id .. (e.data.label and (" " .. e.data.label) or "")
    if not isOnline(e) then
      add("t_off_" .. id, name .. " offline", false)
    else
      local fuel = tonumber(e.data.fuel)
      if fuel and fuel < LOW_FUEL then
        add("t_fuel_" .. id, ("%s: malo paliwa (%d)"):format(name, fuel), false)
      end
      if e.data.waiting then
        add("t_wait_" .. id, name .. ": " .. e.data.waiting, true)
      end
    end
  end

  for id, r in pairs(remoteLava) do
    if not isOnline(r) then add("s_lava_" .. id, "Czujnik lawy " .. (r.label or id) .. " offline", false) end
  end
  for id, r in pairs(remoteEnergy) do
    if not isOnline(r) then add("s_en_" .. id, "Czujnik pradu " .. (r.label or id) .. " offline", false) end
  end

  for key, l in pairs(latched) do c[key] = l end
  return c
end

local function alarmList()
  local list = {}
  for _, a in pairs(alarms) do list[#list + 1] = a end
  local function rank(a) return (a.active and 0 or 2) + (a.acked and 1 or 0) end
  table.sort(list, function(x, y)
    if rank(x) ~= rank(y) then return rank(x) < rank(y) end
    if x.crit ~= y.crit then return x.crit end
    return x.since > y.since
  end)
  return list
end

local function alarmCounts()
  local active, unacked, critUnacked = 0, 0, false
  for _, a in pairs(alarms) do
    if a.active then active = active + 1 end
    if not a.acked then
      unacked = unacked + 1
      if a.active and a.crit then critUnacked = true end
    end
  end
  return active, unacked, critUnacked
end

-- Wysyla pelna liste alarmow do pocketow (pscada)
local function syncAlarms()
  if DEMO then return end
  local list = {}
  for _, a in ipairs(alarmList()) do
    list[#list + 1] = { key = a.key, text = a.text, crit = a.crit,
                        since = a.since, active = a.active, acked = a.acked }
  end
  rednet.broadcast({ cmd = "alarms", list = list }, ALARM_PROTOCOL)
end

local function evalAlarms()
  local cond = alarmConditions()

  for key, cnd in pairs(cond) do
    local a = alarms[key]
    if not a or not a.active then
      a = { key = key, text = cnd.text, crit = cnd.crit, since = now(), active = true, acked = false }
      alarms[key] = a
      logEvent((cnd.crit and "ALARM: " or "UWAGA: ") .. cnd.text,
               cnd.crit and colors.red or colors.orange)
      if speaker then pcall(speaker.playNote, cnd.crit and "bell" or "pling", 3, 12) end
      notifyPhone(a)
    else
      a.text = cnd.text
    end
  end

  for key, a in pairs(alarms) do
    if a.active and not cond[key] then
      a.active = false
      logEvent("OK: " .. a.text, colors.lime)
      if a.acked then alarms[key] = nil end
    end
  end

  -- syrena co cykl, dopoki jest niepotwierdzony alarm krytyczny
  local _, _, critUnacked = alarmCounts()
  if critUnacked and speaker then pcall(speaker.playNote, "bell", 3, 18) end

  syncAlarms()
end

local function ackAlarm(key)
  local a = alarms[key]
  if not a or a.acked then return end
  a.acked = true
  latched[key] = nil
  logEvent("Potwierdzono: " .. a.text, colors.lightGray)
  if not a.active then alarms[key] = nil end
end

local function ackAll()
  for key in pairs(alarms) do ackAlarm(key) end
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
  if e.data.waiting then return "BRAK", colors.orange end
  if e.data.state == "work" then return "PRACA", colors.yellow end
  return "CZEKA", colors.lime
end

local function drawHeader(title)
  fillRow(1, colors.blue)
  put(2, 1, title, colors.white, colors.blue)
  local clock = textutils.formatTime(os.time(), true)
  put(w - #clock, 1, clock, colors.white, colors.blue)
end

-- Naglowek z zakladkami ALARM / ZOLWIE / LAWA / PRAD
local function drawTabs()
  fillRow(1, colors.blue)

  local function tab(x, label, name, alarm)
    local active = (view == name)
    local bg = active and colors.lightBlue or (alarm and colors.red or colors.gray)
    button(x, 1, label, bg, function() view = name end, active and colors.black or colors.white)
  end

  -- ALARM: zielony = spokoj, czerwony migajacy = niepotwierdzone,
  -- pomaranczowy = aktywne potwierdzone
  local activeN, unacked = alarmCounts()
  local abg, afg = colors.green, colors.white
  if unacked > 0 then abg = blink and colors.red or colors.gray
  elseif activeN > 0 then abg = colors.orange end
  if view == "alarms" then abg, afg = colors.lightBlue, colors.black end
  local alabel = (activeN + unacked) > 0 and fit((" ALM %d"):format(math.max(activeN, unacked)), 7)
                 or (DEMO and " DEMO  " or " OK    ")
  button(1, 1, alabel, abg, function() view = "alarms" end, afg)
  tab(9, " ZOLWIE ", "list")
  tab(18, " LAWA ", "lava", #lava.history > 0 and lava.total < lavaLow)
  tab(25, " PRAD ", "energy", energyLow())

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

local function drawEnergy()
  drawTabs()
  local pct = energyPct()
  local low = energyLow()
  local barCol = pct < ENERGY_LOW_PCT and colors.red
              or (pct < 50 and colors.yellow or colors.lime)

  -- Podsumowanie i bilans
  put(2, 3, ("%s / %s"):format(fmtFE(energy.total), fmtFE(energy.capacity)),
      barCol, colors.black)
  local rate = energyRate()
  local rateTxt = (rate > 0 and "+" or "") .. fmtFE(rate) .. "/t"
  local rateCol = rate < 0 and colors.red or (rate > 0 and colors.lime or colors.lightGray)
  put(w - #rateTxt, 3, rateTxt, rateCol, colors.black)

  -- Pasek naladowania z procentem
  local pctTxt = ("%3d%%"):format(math.floor(pct + 0.5))
  local barW = w - 2 - #pctTxt - 1
  local filled = math.floor(barW * clamp(pct / 100, 0, 1) + 0.5)
  put(2, 4, (" "):rep(filled), nil, barCol)
  put(2 + filled, 4, (" "):rep(barW - filled), nil, colors.gray)
  put(w - #pctTxt, 4, pctTxt, colors.white, colors.black)

  -- Czas do pelna / do zera przy obecnym bilansie
  if rate ~= 0 then
    local ticks = rate > 0 and (energy.capacity - energy.total) / rate or energy.total / -rate
    local mins = ticks / 20 / 60
    local txt = mins >= 600 and ">10 h" or
                (mins >= 60 and ("%.1f h"):format(mins / 60) or ("%d min"):format(math.floor(mins)))
    put(2, 5, (rate > 0 and "Pelne za: " or "Puste za: ") .. txt,
        rate > 0 and colors.lightGray or colors.orange, colors.black)
  end

  -- Magazyny (max 4 wiersze)
  fillRow(6, colors.gray)
  put(2, 6, "MAGAZYN", colors.lightGray, colors.gray)
  put(w - 13, 6, "STAN", colors.lightGray, colors.gray)
  local y = 7
  for i, s in ipairs(energy.sources) do
    if i > 4 then
      put(2, y, ("... i %d wiecej"):format(#energy.sources - 4), colors.lightGray, colors.black)
      y = y + 1
      break
    end
    put(2, y, fit(s.name, w - 16), s.offline and colors.red or colors.white, colors.black)
    if s.offline then
      put(w - 13, y, ("%13s"):format("-"), colors.lightGray, colors.black)
    else
      local sp = s.capacity > 0 and math.floor(s.energy / s.capacity * 100 + 0.5) or 0
      local amount = (fmtFE(s.energy):gsub("FE", ""))
      put(w - 13, y, ("%4d%%%8s"):format(sp, amount),
          colors.yellow, colors.black)
    end
    y = y + 1
  end
  if #energy.sources == 0 then
    put(2, y, "Brak magazynow energii (FE)", colors.red, colors.black)
    y = y + 1
  end

  -- Wykres historii naladowania
  local gTop, gBot = y + 2, h - 1
  if gBot - gTop >= 1 and energy.capacity > 0 then
    put(2, gTop - 1, ("Historia (%d min)"):format(math.floor(HISTORY_MAX * REFRESH / 60)),
        colors.lightGray, colors.black)
    local gh, gw = gBot - gTop + 1, w - 2
    local hist = energy.history
    local start = math.max(1, #hist - gw + 1)
    for i = start, #hist do
      local x = 2 + gw - 1 - (#hist - i)
      local p = clamp(hist[i].v / energy.capacity, 0, 1)
      local bh = math.floor(gh * p + 0.5)
      local col = p * 100 < ENERGY_LOW_PCT and colors.red or colors.yellow
      for r = 0, bh - 1 do put(x, gBot - r, " ", nil, col) end
    end
  end

  if low then
    drawFooter(("ALARM: prad ponizej %d%%"):format(ENERGY_LOW_PCT), colors.red)
  else
    drawFooter(("Magazynow: %d | probka co %d s"):format(#energy.sources, REFRESH))
  end
end

local function hhmm(ms) return os.date("%H:%M", math.floor(ms / 1000)) end

local function drawAlarms()
  drawTabs()

  fillRow(2, colors.gray)
  put(2, 2, "CZAS  ALARM (dotknij = potwierdz)", colors.lightGray, colors.gray)

  local list = alarmList()
  local maxRows = math.max(3, math.floor((h - 6) / 2))
  local y = 3
  for i, a in ipairs(list) do
    if i > maxRows then
      put(2, y, ("... i %d wiecej"):format(#list - maxRows), colors.lightGray, colors.black)
      y = y + 1
      break
    end
    local fg, bg = colors.yellow, colors.black          -- ustapil, niepotwierdzony
    if a.active and not a.acked then
      fg, bg = colors.red, colors.black
      if blink and a.crit then fg, bg = colors.white, colors.red end
    elseif a.active then
      fg = colors.orange
    end
    local txt = ("%s %s%s%s"):format(hhmm(a.since), a.crit and "!" or " ",
                                      a.active and "" or "(ok) ", a.text)
    button(1, y, " " .. fit(txt, w - 1), bg, function() ackAlarm(a.key) end, fg)
    y = y + 1
  end
  if #list == 0 then
    put(2, y, "Brak alarmow - wszystko OK", colors.lime, colors.black)
    y = y + 1
  end

  local _, unacked = alarmCounts()
  y = y + 1
  if unacked > 0 then
    button(2, y, " POTWIERDZ WSZYSTKIE ", colors.green, ackAll)
  end
  y = y + 2

  -- Dziennik zdarzen
  if y < h - 1 then
    fillRow(y, colors.gray)
    put(2, y, "ZDARZENIA", colors.lightGray, colors.gray)
    y = y + 1
    for _, ev in ipairs(alarmLog) do
      if y > h - 1 then break end
      put(2, y, fit(hhmm(ev.t) .. " " .. ev.text, w - 2), ev.color, colors.black)
      y = y + 1
    end
  end

  drawFooter(("ntfy: %s | syrena: %s"):format(NTFY_TOPIC and "ON" or "off",
                                              speaker and "ON" or "brak"))
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
  elseif view == "energy" then drawEnergy()
  elseif view == "alarms" then drawAlarms()
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
    elseif proto == ENERGY_PROTOCOL and type(msg) == "table" and msg.cmd == "energy" then
      remoteEnergy[id] = {
        label = msg.label,
        energy = tonumber(msg.energy) or 0, capacity = tonumber(msg.capacity) or 0,
        sources = type(msg.sources) == "table" and msg.sources or {}, last = now(),
      }
    elseif proto == ALARM_PROTOCOL and type(msg) == "table" and msg.cmd == "ack" then
      -- potwierdzenie z pocketa (pscada)
      if msg.all then ackAll() elseif msg.key then ackAlarm(msg.key) end
      syncAlarms()
      draw()
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
        if msg.ok then
          logEvent(("Zolw #%d skonczyl prace"):format(id), colors.lime)
        else
          latched["t_err_" .. id] = { text = ("Zolw #%d przerwal prace (blad)"):format(id), crit = true }
          evalAlarms()
        end
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
    sampleEnergy()
    if DEMO then
      tickDemo()
      evalAlarms()
      draw()
      sleep(REFRESH)
    else
      rednet.broadcast({ cmd = "ping" }, PROTOCOL)
      sleep(1.5) -- czas na odpowiedzi
      evalAlarms()
      draw()
      sleep(REFRESH - 1.5)
    end
  end
end

-- Miganie niepotwierdzonych alarmow (odswieza ekran tylko gdy sa takie alarmy)
local function blinker()
  while true do
    sleep(1)
    blink = not blink
    local _, unacked = alarmCounts()
    if unacked > 0 then draw() end
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
      if view == "alarms" then syncAlarms() end -- potwierdzenia -> pockety
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
parallel.waitForAny(receiver, pinger, ui, blinker)

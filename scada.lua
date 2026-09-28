-- scada.lua - panel stanu i sterowania na advanced monitorze
--
-- Uzycie:  scada           - normalna praca
--          scada demo      - dane testowe (bez zolwi i czujnikow)
--          scada install   - autostart
--
-- Wymaga: komputer + advanced monitor (min. 2x2 bloki, najlepiej 3x2)
--         + wireless/ender modem.
--
-- Zakladki (dotyk):
--   * ALM    - alarmy, dziennik zdarzen, przycisk UPDATE
--   * ZOLWIE - stan zolwi; dotknij zolwia -> program i parametry -> START
--   * ZAKLAD - grupy z czujnikow (sensor); jedna grupa = jeden komputer
--              z czujnikiem (nazwa = jego etykieta). Dotknij grupy ->
--              sekcje PRAD / KINETYKA / PLYNY / MAGAZYN / POCIAGI.
--              Dotknij pozycji -> prog alarmu dla tej pozycji.

local PROTOCOL        = "flatten"       -- zolwie
local SENSOR_PROTOCOL = "scada_sensor"  -- czujniki (sensor)
local ALARM_PROTOCOL  = "scada_alarm"   -- alarmy -> pockety (pscada)
local ADMIN_PROTOCOL  = "scada_admin"   -- zdalny UPDATE
local REFRESH  = 5      -- sekundy miedzy odswiezeniami
local OFFLINE  = 15     -- po tylu sekundach bez danych: OFFLINE
local LOW_FUEL = 500
local TERM_ROW = 11     -- wiersz statusu na ekranie komputera (1-8 zajmuje sensor)

local DEMO = ({ ... })[1] == "demo"

if ({ ... })[1] == "install" then
  -- stary update nie pobieral 'autostart' - dociagnij go w razie potrzeby
  if not fs.exists("autostart") and not fs.exists("autostart.lua") then shell.run("update") end
  shell.run("autostart", "add", "scada")
  return
end

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
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function isOnline(e) return e ~= nil and (now() - e.last) < OFFLINE * 1000 end

-- Stan interfejsu
local view, selected = "plant", nil
local selGroup, cfgTarget = nil, nil
local scroll = {}                 -- klucz widoku -> przesuniecie listy
local message                     -- { text, color, time }

local function setMsg(text, color)
  message = { text = text, color = color or colors.white, time = now() }
end

---------------------------------------------------------------------------
-- Formatowanie

local function shortName(n) return (tostring(n):match(":(.+)$") or tostring(n)) end

local function fmtNum(n)
  if math.abs(n) >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if math.abs(n) >= 1e4 then return ("%.1fk"):format(n / 1e3) end
  return tostring(math.floor(n))
end

local function fmtFE(n)
  local units = { "", "k", "M", "G", "T" }
  local i = 1
  while math.abs(n) >= 1000 and i < #units do n = n / 1000; i = i + 1 end
  return ("%.1f %sFE"):format(n, units[i])
end

local function buckets(mB) return ("%.1f B"):format(mB / 1000) end
local function hhmm(ms) return os.date("%H:%M", math.floor(ms / 1000)) end

---------------------------------------------------------------------------
-- ZOLWIE

local known = {}     -- id -> { data = <pong>, last }
local params = {}    -- id -> parametry programu

local function getParams(id)
  if not params[id] then
    params[id] = { program = "flatten", length = 16, width = 16, spacing = 5, center = true }
  end
  return params[id]
end

---------------------------------------------------------------------------
-- ZAKLAD: grupy z czujnikow
--
-- groups[nazwa] = { label, id, last, points, sum, hist }
--   sum  - podsumowanie punktow (patrz summarize)
--   hist - historia energii { t, v, sig } do bilansu FE/t

local groups = {}

local function summarize(points)
  local s = {
    energy = 0, energyCap = 0, energySrc = {},
    stress = {}, speed = {},
    fluids = {}, fluidList = {}, tanks = 0,
    items = {}, itemList = {}, itemSources = 0,
    stations = {}, signals = {},
  }
  for _, pt in ipairs(points or {}) do
    if pt.kind == "energy" then
      s.energy, s.energyCap = s.energy + pt.energy, s.energyCap + pt.capacity
      s.energySrc[#s.energySrc + 1] = pt
    elseif pt.kind == "stress" then s.stress[#s.stress + 1] = pt
    elseif pt.kind == "speed" then s.speed[#s.speed + 1] = pt
    elseif pt.kind == "fluid" then
      s.tanks = s.tanks + 1
      for _, f in ipairs(pt.fluids or {}) do
        local e = s.fluids[f.name] or { name = f.name, amount = 0, tanks = 0 }
        e.amount, e.tanks = e.amount + f.amount, e.tanks + 1
        s.fluids[f.name] = e
      end
    elseif pt.kind == "items" then
      s.items, s.itemSources = pt.items or {}, pt.sources or 0
    elseif pt.kind == "station" then s.stations[#s.stations + 1] = pt
    elseif pt.kind == "signal" then s.signals[#s.signals + 1] = pt
    end
  end
  for _, f in pairs(s.fluids) do s.fluidList[#s.fluidList + 1] = f end
  table.sort(s.fluidList, function(a, b) return a.amount > b.amount end)
  for name, count in pairs(s.items) do s.itemList[#s.itemList + 1] = { name = name, count = count } end
  table.sort(s.itemList, function(a, b) return a.count > b.count end)
  return s
end

-- Bilans z ostatniej minuty; tylko probki z tym samym zestawem zrodel (sig)
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
  return dt > 0 and (last.v - first.v) / dt or 0
end

local function receiveSensor(id, msg)
  local key = tostring(msg.label or ("#" .. id))
  local g = groups[key]
  -- dwa rozne czujniki z ta sama etykieta - rozrozniamy po ID
  if g and g.id ~= id and isOnline(g) then key = key .. " #" .. id; g = groups[key] end
  if not g then
    g = { label = key, hist = {} }
    groups[key] = g
  end
  g.id, g.last = id, now()
  g.points = type(msg.points) == "table" and msg.points or {}
  g.sum = summarize(g.points)
  g.hist[#g.hist + 1] = { t = now(), v = g.sum.energy, sig = g.sum.energyCap }
  if #g.hist > 24 then table.remove(g.hist, 1) end
end

local function groupNames()
  local names = {}
  for k in pairs(groups) do names[#names + 1] = k end
  table.sort(names)
  return names
end

---------------------------------------------------------------------------
-- Progi alarmow (zapisywane w settings, przetrwaja restart)
--   cfg[grupa][klucz] = wartosc; 0 = alarm wylaczony
--   energy       - % naladowania, alarm PONIZEJ          (domyslnie 20)
--   su:<id>      - % obciazenia stressometru, alarm OD   (domyslnie 90)
--   rpm:<id>     - RPM speedometru, alarm PONIZEJ        (domyslnie 0)
--   fluid:<nazwa>- wiadra plynu, alarm PONIZEJ           (domyslnie 0)
--   item:<nazwa> - sztuki przedmiotu, alarm PONIZEJ      (domyslnie 0)

local cfg = settings.get("scada.cfg")
if type(cfg) ~= "table" then cfg = {} end

local function getCfg(group, key, default)
  local g = cfg[group]
  local v = g and g[key]
  if v == nil then return default end
  return v
end

local function setCfg(group, key, value)
  cfg[group] = cfg[group] or {}
  cfg[group][key] = value
  settings.set("scada.cfg", cfg)
  settings.save()
end

-- Obserwowane (prog > 0) pozycje danego rodzaju w grupie: nazwa -> prog
local function watched(group, prefix)
  local out = {}
  for k, v in pairs(cfg[group] or {}) do
    if k:sub(1, #prefix) == prefix and tonumber(v) and v > 0 then out[k:sub(#prefix + 1)] = v end
  end
  return out
end

---------------------------------------------------------------------------
-- Tryb demo

local function initDemo()
  known[3]  = { last = now(), data = { label = "Kopacz", state = "work", program = "flatten",
                                       progress = 0.3, fuel = 4200 } }
  known[7]  = { last = now(), data = { label = "Swiatlo", state = "work", program = "torches",
                                       progress = 0.7, fuel = 320 } }
  known[21] = { last = now() - 60000, data = { label = "Zgubiony", state = "idle", fuel = 0 } }
  if not cfg["Wyspa Glowna"] then
    cfg["Wyspa Glowna"] = { ["fluid:minecraft:lava"] = 200, ["item:minecraft:coal"] = 128 }
  end
end

local function tickDemo()
  for id, e in pairs(known) do
    if id ~= 21 then
      e.last = now()
      if e.data.state == "work" then
        e.data.progress = (e.data.progress or 0) + 0.1
        e.data.waiting = (id == 3 and e.data.progress > 0.5 and e.data.progress < 0.8)
                         and "brak paliwa" or nil
        if e.data.progress >= 1 then
          e.data.state, e.data.program, e.data.progress = "idle", nil, nil
          setMsg(("Zolw #%d skonczyl"):format(id), colors.lime)
        end
      end
    end
  end

  local t = os.clock()
  receiveSensor(9001, { label = "Wyspa Glowna", points = {
    { kind = "energy", id = "powah:energy_cell_0", energy = math.floor(30e6 + 25e6 * math.sin(t / 25)), capacity = 60e6 },
    { kind = "stress", id = "Create_Stressometer_0", stress = math.floor(1400 + 500 * math.sin(t / 15)), capacity = 2048 },
    { kind = "speed",  id = "Create_Speedometer_0", speed = 128 },
    { kind = "fluid",  id = "create:fluid_tank_0", fluids = { { name = "minecraft:lava", amount = math.floor(300000 + 200000 * math.sin(t / 20)) } } },
    { kind = "fluid",  id = "create:fluid_tank_1", fluids = { { name = "minecraft:water", amount = 512000 } } },
    { kind = "fluid",  id = "create:fluid_tank_2", fluids = {} },
    { kind = "items",  id = "items", sources = 3, items = {
        ["minecraft:cobblestone"] = 18240, ["minecraft:iron_ingot"] = 1532,
        ["create:andesite_alloy"] = 830, ["minecraft:coal"] = math.floor(150 + 60 * math.sin(t / 10)),
        ["create:brass_ingot"] = 96 } },
    { kind = "station", id = "train_station_0", station = "Wyspa", present = (t % 60) < 20,
      train = "Ekspres 1", imminent = (t % 60) > 50, enroute = true },
    { kind = "signal", id = "train_signal_0", state = (t % 60) < 20 and "RED" or "GREEN", trains = 0 },
  } })
  receiveSensor(9002, { label = "Kopalnia", points = {
    { kind = "energy", id = "powah:energy_cell_1", energy = 1.5e6, capacity = 10e6 },
    { kind = "stress", id = "Create_Stressometer_1", stress = math.floor(3900 + 300 * math.sin(t / 8)), capacity = 4096 },
  } })
  if not groups["Magazyn Stary"] then
    receiveSensor(9003, { label = "Magazyn Stary", points = {} })
    groups["Magazyn Stary"].last = now() - 60000
  end
end

---------------------------------------------------------------------------
-- Alarmy
--
-- Stany: AKTYWNY niepotwierdzony (czerwony, miga), AKTYWNY potwierdzony
-- (pomaranczowy), USTAPIL niepotwierdzony (zolty). Potwierdzony i ustapiony
-- znika z listy. Kazda zmiana trafia do dziennika zdarzen.

-- Push na prawdziwy telefon przez ntfy.sh:  set scada.ntfy <tajny_temat>
local NTFY_TOPIC = settings.get("scada.ntfy")
if NTFY_TOPIC == "" then NTFY_TOPIC = nil end

local alarms   = {}   -- key -> { key, text, crit, group, since, active, acked }
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

-- Wszystkie warunki alarmowe w tej chwili: key -> { text, crit, group }
local function alarmConditions()
  local c = {}
  local function add(key, text, crit, group) c[key] = { text = text, crit = crit, group = group } end

  for id, e in pairs(known) do
    local name = "Zolw #" .. id .. (e.data.label and (" " .. e.data.label) or "")
    if not isOnline(e) then
      add("t_off_" .. id, name .. " offline", false)
    else
      local fuel = tonumber(e.data.fuel)
      if fuel and fuel < LOW_FUEL then
        add("t_fuel_" .. id, ("%s: malo paliwa (%d)"):format(name, fuel), false)
      end
      if e.data.waiting then add("t_wait_" .. id, name .. ": " .. e.data.waiting, true) end
    end
  end

  for label, g in pairs(groups) do
    local tag, s = "[" .. label .. "] ", g.sum
    if not isOnline(g) then
      add("g_off_" .. label, tag .. "czujnik offline", false, label)
    else
      if s.energyCap > 0 then
        local pct, min = s.energy / s.energyCap * 100, getCfg(label, "energy", 20)
        if min > 0 and pct < min then
          add("g_en_" .. label, tag .. ("malo pradu: %d%%"):format(math.floor(pct)), true, label)
        end
      end
      for _, st in ipairs(s.stress) do
        if st.capacity > 0 then
          local pct, max = st.stress / st.capacity * 100, getCfg(label, "su:" .. st.id, 90)
          if st.stress > st.capacity then
            add("g_su_" .. label .. st.id, tag .. "PRZECIAZENIE sieci " .. shortName(st.id), true, label)
          elseif max > 0 and pct >= max then
            add("g_su_" .. label .. st.id, tag .. ("obciazenie %d%% (%s)"):format(math.floor(pct), shortName(st.id)), false, label)
          end
        end
      end
      for _, sp in ipairs(s.speed) do
        local min = getCfg(label, "rpm:" .. sp.id, 0)
        if min > 0 and math.abs(sp.speed) < min then
          add("g_rpm_" .. label .. sp.id, tag .. ("wolno: %d RPM (%s)"):format(sp.speed, shortName(sp.id)), false, label)
        end
      end
      for name, min in pairs(watched(label, "fluid:")) do
        local amount = s.fluids[name] and s.fluids[name].amount or 0
        if amount < min * 1000 then
          add("g_fl_" .. label .. name, tag .. ("malo: %s %s"):format(shortName(name), buckets(amount)), true, label)
        end
      end
      if s.itemSources > 0 then
        for name, min in pairs(watched(label, "item:")) do
          local count = s.items[name] or 0
          if count < min then
            add("g_it_" .. label .. name, tag .. ("malo: %s %d/%d"):format(shortName(name), count, min), false, label)
          end
        end
      end
    end
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

local function alarmCounts(group)
  local active, unacked, critUnacked = 0, 0, false
  for _, a in pairs(alarms) do
    if group == nil or a.group == group then
      if a.active then active = active + 1 end
      if not a.acked then
        unacked = unacked + 1
        if a.active and a.crit then critUnacked = true end
      end
    end
  end
  return active, unacked, critUnacked
end

-- Wysyla pelna liste alarmow do pocketow (pscada)
local function syncAlarms()
  if DEMO then return end
  local list = {}
  for _, a in ipairs(alarmList()) do
    list[#list + 1] = { key = a.key, text = a.text, crit = a.crit, group = a.group,
                        since = a.since, active = a.active, acked = a.acked }
  end
  rednet.broadcast({ cmd = "alarms", list = list }, ALARM_PROTOCOL)
end

local function evalAlarms()
  local cond = alarmConditions()

  for key, cnd in pairs(cond) do
    local a = alarms[key]
    if not a or not a.active then
      a = { key = key, text = cnd.text, crit = cnd.crit, group = cnd.group,
            since = now(), active = true, acked = false }
      alarms[key] = a
      logEvent((cnd.crit and "ALARM: " or "UWAGA: ") .. cnd.text,
               cnd.crit and colors.red or colors.orange)
      if speaker then pcall(speaker.playNote, cnd.crit and "bell" or "pling", 3, 12) end
      notifyPhone(a)
    else
      a.text, a.crit = cnd.text, cnd.crit
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
-- Rysowanie: podstawy

local w, h
local buttons = {}

local function put(x, y, s, fg, bg)
  mon.setCursorPos(x, y)
  if bg then mon.setBackgroundColor(bg) end
  if fg then mon.setTextColor(fg) end
  mon.write(s)
end

local function fillRow(y, bg) put(1, y, (" "):rep(w), nil, bg) end

local function fit(s, n)
  s = tostring(s or "")
  if n <= 0 then return "" end
  if #s > n then return s:sub(1, n) end
  return s .. (" "):rep(n - #s)
end

-- Rysuje przycisk i zapamietuje jego obszar do obslugi dotyku
local function button(x, y, label, bg, action, fg)
  put(x, y, label, fg or colors.white, bg)
  buttons[#buttons + 1] = { x1 = x, x2 = x + #label - 1, y = y, action = action }
end

local function drawBar(x, y, width, p, col)
  if width < 6 then return end
  local barW = width - 5
  local filled = math.floor(barW * clamp(p, 0, 1) + 0.5)
  put(x, y, (" "):rep(filled), nil, col or colors.lime)
  put(x + filled, y, (" "):rep(barW - filled), nil, colors.gray)
  put(x + barW, y, ("%4d%%"):format(math.floor(p * 100 + 0.5)), colors.white, colors.black)
end

local function drawHeader(title, back)
  fillRow(1, colors.blue)
  put(2, 1, fit(title, w - 12), colors.white, colors.blue)
  if back then
    button(w - 8, 1, " WSTECZ ", colors.gray, back)
  else
    local clock = textutils.formatTime(os.time(), true)
    put(w - #clock, 1, clock, colors.white, colors.blue)
  end
end

-- Naglowek z zakladkami ALM / ZOLWIE / ZAKLAD
local function drawTabs()
  fillRow(1, colors.blue)

  -- ALM: zielony = spokoj, czerwony migajacy = niepotwierdzone,
  -- pomaranczowy = aktywne potwierdzone
  local activeN, unacked = alarmCounts()
  local abg, afg = colors.green, colors.white
  if unacked > 0 then abg = blink and colors.red or colors.gray
  elseif activeN > 0 then abg = colors.orange end
  if view == "alarms" then abg, afg = colors.lightBlue, colors.black end
  local alabel = (activeN + unacked) > 0 and fit((" ALM %d"):format(math.max(activeN, unacked)), 7)
                 or (DEMO and " DEMO  " or " OK    ")
  button(1, 1, alabel, abg, function() view = "alarms" end, afg)

  local function tab(x, label, name, alarm)
    local active = (view == name)
    local bg = active and colors.lightBlue or (alarm and colors.red or colors.gray)
    button(x, 1, label, bg, function() view = name end, active and colors.black or colors.white)
  end
  local turtleAlarm, plantAlarm = false, false
  for _, a in pairs(alarms) do
    if a.active and not a.acked then
      if a.group then plantAlarm = true else turtleAlarm = true end
    end
  end
  tab(9, " ZOLWIE ", "list", turtleAlarm)
  tab(18, " ZAKLAD ", "plant", plantAlarm)

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

-- Przewijana lista wierszy. Wiersz: { text, fg, bg, right, rfg, action,
-- bar = 0..1, barCol }. Zwraca true, jesli lista sie nie miesci.
local function drawRows(rows, top, bottom, key)
  local n = bottom - top + 1
  local off = clamp(scroll[key] or 0, 0, math.max(0, #rows - n))
  scroll[key] = off
  for i = 1, n do
    local r = rows[off + i]
    if not r then break end
    local y = top + i - 1
    local bg = r.bg or colors.black
    if r.bar then
      put(1, y, " ", nil, colors.black)
      drawBar(2, y, w - 2, r.bar, r.barCol)
    else
      local rightW = r.right and (#r.right + 1) or 0
      local text = " " .. fit(r.text, w - 1 - rightW)
      if r.action then button(1, y, text, bg, r.action, r.fg)
      else put(1, y, text, r.fg or colors.white, bg) end
      if r.right then
        put(w - #r.right, y, r.right, r.rfg or r.fg or colors.white, bg)
        if r.action then buttons[#buttons].x2 = w end
      end
    end
  end
  return #rows > n
end

local function scrollButtons(key, pageSize)
  button(w - 7, h, " ^ ", colors.lightGray, function()
    scroll[key] = math.max(0, (scroll[key] or 0) - (pageSize - 1))
  end, colors.black)
  button(w - 3, h, " v ", colors.lightGray, function()
    scroll[key] = (scroll[key] or 0) + (pageSize - 1)
  end, colors.black)
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

---------------------------------------------------------------------------
-- Widok: ZOLWIE

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

    button(1, y, (" "):rep(w), colors.black, function() selected, view = id, "config" end)
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

  if #ids == 0 then put(2, 4, "Brak zolwi w zasiegu...", colors.lightGray, colors.black) end

  drawFooter(("Online: %d/%d | dotknij zolwia = ustawienia"):format(online, #ids))
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

---------------------------------------------------------------------------
-- Widok: ZAKLAD (karty grup)

local function openGroup(label)
  selGroup, view = label, "group"
end

-- Otwiera ekran progu alarmu dla jednej pozycji
local function openCfg(t)
  cfgTarget, view = t, "pcfg"
end

-- Krotkie podsumowanie grupy do karty
local function groupSummary(g)
  local s, parts = g.sum, {}
  if s.energyCap > 0 then parts[#parts + 1] = ("FE %d%%"):format(math.floor(s.energy / s.energyCap * 100)) end
  local maxSu
  for _, st in ipairs(s.stress) do
    if st.capacity > 0 then maxSu = math.max(maxSu or 0, st.stress / st.capacity * 100) end
  end
  if maxSu then parts[#parts + 1] = ("SU %d%%"):format(math.floor(maxSu)) end
  if s.fluidList[1] then
    parts[#parts + 1] = shortName(s.fluidList[1].name) .. " " .. fmtNum(s.fluidList[1].amount / 1000) .. "B"
  end
  if s.itemSources > 0 then parts[#parts + 1] = #s.itemList .. " poz." end
  if #s.stations > 0 then parts[#parts + 1] = #s.stations .. " stacji" end
  if #parts == 0 then return "brak danych" end
  return table.concat(parts, " | ")
end

local function drawPlant()
  drawTabs()

  local names = groupNames()
  local rows = {}
  local online, totalE, totalC, totalRate = 0, 0, 0, 0
  for _, label in ipairs(names) do
    local g = groups[label]
    if isOnline(g) then
      online = online + 1
      totalE, totalC = totalE + g.sum.energy, totalC + g.sum.energyCap
      totalRate = totalRate + histRate(g.hist, 50)
    end
  end

  -- Pasek laczny: caly prad zakladu
  fillRow(2, colors.gray)
  put(2, 2, ("GRUPY: %d (online %d)"):format(#names, online), colors.lightGray, colors.gray)
  if totalC > 0 then
    local r = (totalRate > 0 and "+" or "") .. fmtFE(totalRate) .. "/t"
    put(w - #r, 2, r, totalRate < 0 and colors.red or colors.lime, colors.gray)
  end

  for _, label in ipairs(names) do
    local g = groups[label]
    local act, unacked = alarmCounts(label)
    local status, scol
    if not isOnline(g) then status, scol = "OFFLINE", colors.red
    elseif unacked > 0 then status, scol = ("ALM %d"):format(math.max(act, unacked)), colors.red
    elseif act > 0 then status, scol = ("ALM %d"):format(act), colors.orange
    else status, scol = "OK", colors.lime end

    local open = function() openGroup(label) end
    rows[#rows + 1] = { text = label, fg = colors.white, right = status, rfg = scol, action = open }
    rows[#rows + 1] = { text = " " .. (isOnline(g) and groupSummary(g) or "brak polaczenia"),
                        fg = colors.lightGray, action = open }
  end

  local top = 3
  if totalC > 0 then
    rows = { { bar = totalE / totalC, barCol = colors.yellow }, table.unpack(rows) }
  end
  if #names == 0 then
    rows = { { text = "Brak czujnikow. Na komputerze przy maszynach:", fg = colors.lightGray },
             { text = "sensor install  (nazwa grupy = label)", fg = colors.lightGray } }
  end

  local overflow = drawRows(rows, top, h - 1, "plant")
  drawFooter("Dotknij grupy = szczegoly")
  if overflow then scrollButtons("plant", h - top) end
end

---------------------------------------------------------------------------
-- Widok: szczegoly grupy (sekcje)

local function groupRows(label)
  local g = groups[label]
  local s, rows = g.sum, {}
  local function sec(t) rows[#rows + 1] = { text = t, fg = colors.black, bg = colors.lightGray } end
  local function row(r) rows[#rows + 1] = r end

  if not isOnline(g) then
    row({ text = ("Czujnik OFFLINE od %s"):format(hhmm(g.last)), fg = colors.red })
    row({ text = " USUN GRUPE Z LISTY ", fg = colors.white, bg = colors.red,
          action = function() groups[label] = nil; view = "plant" end })
  end

  -- PRAD
  if s.energyCap > 0 then
    local pct = s.energy / s.energyCap * 100
    local min = getCfg(label, "energy", 20)
    local col = (min > 0 and pct < min) and colors.red or (pct < 50 and colors.yellow or colors.lime)
    local rate = histRate(g.hist, 50)
    sec("PRAD")
    row({ bar = pct / 100, barCol = col })
    row({ text = fmtFE(s.energy) .. " / " .. fmtFE(s.energyCap),
          right = (rate > 0 and "+" or "") .. fmtFE(rate) .. "/t",
          rfg = rate < 0 and colors.red or (rate > 0 and colors.lime or colors.lightGray) })
    if #s.energySrc > 1 then
      for _, src in ipairs(s.energySrc) do
        row({ text = " " .. shortName(src.id), fg = colors.lightGray,
              right = ("%d%%"):format(math.floor(src.energy / src.capacity * 100)) })
      end
    end
    row({ text = "Alarm ponizej", fg = colors.lightGray,
          right = min > 0 and (min .. "%") or "wyl.", rfg = colors.lightBlue,
          action = function() openCfg({ group = label, key = "energy", title = "Prad",
            desc = "Alarm, gdy naladowanie ponizej", unit = "%", default = 20,
            big = 10, small = 1, max = 100 }) end })
  end

  -- KINETYKA (Create)
  if #s.stress + #s.speed > 0 then
    sec("KINETYKA")
    for _, st in ipairs(s.stress) do
      local pct = st.capacity > 0 and st.stress / st.capacity * 100 or 0
      local max = getCfg(label, "su:" .. st.id, 90)
      local col = st.stress > st.capacity and colors.red
               or ((max > 0 and pct >= max) and colors.orange or colors.lime)
      row({ text = "SU " .. shortName(st.id), fg = col,
            right = ("%s/%s %d%%"):format(fmtNum(st.stress), fmtNum(st.capacity), math.floor(pct)),
            action = function() openCfg({ group = label, key = "su:" .. st.id,
              title = "SU " .. shortName(st.id), desc = "Ostrzezenie od obciazenia",
              unit = "%", default = 90, big = 10, small = 1, max = 100 }) end })
    end
    for _, sp in ipairs(s.speed) do
      local min = getCfg(label, "rpm:" .. sp.id, 0)
      local col = (min > 0 and math.abs(sp.speed) < min) and colors.orange or colors.white
      row({ text = "RPM " .. shortName(sp.id), fg = col,
            right = ("%d RPM"):format(sp.speed) .. (min > 0 and (" /min " .. min) or ""),
            action = function() openCfg({ group = label, key = "rpm:" .. sp.id,
              title = "RPM " .. shortName(sp.id), desc = "Ostrzezenie, gdy predkosc ponizej",
              unit = "RPM", default = 0, big = 32, small = 1, max = 256 }) end })
    end
  end

  -- PLYNY
  if s.tanks > 0 then
    sec(("PLYNY (%d zbiornikow)"):format(s.tanks))
    local watch = watched(label, "fluid:")
    local shown = {}
    local function fluidRow(name, amount, tanks)
      local min = getCfg(label, "fluid:" .. name, 0)
      local low = min > 0 and amount < min * 1000
      row({ text = shortName(name) .. (tanks and (" (" .. tanks .. ")") or ""),
            fg = low and colors.red or colors.cyan,
            right = buckets(amount) .. (min > 0 and (" /min " .. min) or ""),
            rfg = low and colors.red or colors.white,
            action = function() openCfg({ group = label, key = "fluid:" .. name,
              title = shortName(name), desc = "Alarm, gdy mniej niz (wiadra)",
              unit = "B", default = 0, big = 64, small = 8, max = 99999 }) end })
      shown[name] = true
    end
    for _, f in ipairs(s.fluidList) do fluidRow(f.name, f.amount, f.tanks) end
    for name in pairs(watch) do if not shown[name] then fluidRow(name, 0) end end
    if #s.fluidList == 0 and next(watch) == nil then
      row({ text = "wszystkie zbiorniki puste", fg = colors.lightGray })
    end
  end

  -- MAGAZYN
  if s.itemSources > 0 then
    sec(("MAGAZYN (%d rodzajow, %d zrodel)"):format(#s.itemList, s.itemSources))
    local watch = watched(label, "item:")
    local function itemRow(name, count)
      local min = getCfg(label, "item:" .. name, 0)
      local low = min > 0 and count < min
      row({ text = shortName(name), fg = low and colors.red or (min > 0 and colors.yellow or colors.white),
            right = fmtNum(count) .. (min > 0 and (" /min " .. fmtNum(min)) or ""),
            rfg = low and colors.red or colors.white,
            action = function() openCfg({ group = label, key = "item:" .. name,
              title = shortName(name), desc = "Ostrzezenie, gdy mniej niz (szt.)",
              unit = "szt", default = 0, big = 64, small = 1, max = 99999 }) end })
    end
    -- najpierw obserwowane (z progiem), potem najliczniejsze
    local wl = {}
    for name in pairs(watch) do wl[#wl + 1] = name end
    table.sort(wl)
    for _, name in ipairs(wl) do itemRow(name, s.items[name] or 0) end
    local n = 0
    for _, it in ipairs(s.itemList) do
      if not watch[it.name] then
        itemRow(it.name, it.count)
        n = n + 1
        if n >= 15 then break end
      end
    end
  end

  -- POCIAGI (Create)
  if #s.stations + #s.signals > 0 then
    sec("POCIAGI")
    for _, st in ipairs(s.stations) do
      local state, col
      if st.present then state, col = "stoi: " .. tostring(st.train or "?"), colors.lime
      elseif st.imminent then state, col = "nadjezdza", colors.yellow
      elseif st.enroute then state, col = "w drodze", colors.lightGray
      else state, col = "pusto", colors.gray end
      row({ text = "Stacja " .. tostring(st.station or shortName(st.id)), right = state, rfg = col })
    end
    for _, sg in ipairs(s.signals) do
      local col = sg.state == "GREEN" and colors.lime or (sg.state == "RED" and colors.red or colors.yellow)
      row({ text = "Sygnal " .. shortName(sg.id), right = tostring(sg.state), rfg = col })
    end
  end

  if #rows == 0 then
    row({ text = "Czujnik nic nie wykrywa.", fg = colors.lightGray })
    row({ text = "Na jego komputerze: sensor test", fg = colors.lightGray })
  end
  return rows
end

local function drawGroup()
  local g = groups[selGroup]
  if not g then view = "plant"; return false end
  drawHeader(selGroup, function() view = "plant" end)
  local rows = groupRows(selGroup)
  local overflow = drawRows(rows, 2, h - 1, "group:" .. selGroup)
  drawFooter("Dotknij pozycji = prog alarmu")
  if overflow then scrollButtons("group:" .. selGroup, h - 2) end
  return true
end

-- Ekran progu alarmu jednej pozycji
local function drawPointCfg()
  local t = cfgTarget
  drawHeader("Alarm: " .. t.title, function() view = "group" end)

  local value = getCfg(t.group, t.key, t.default)
  put(2, 3, "Grupa: " .. t.group, colors.lightGray, colors.black)
  put(2, 5, t.desc, colors.white, colors.black)
  numberRow(7, t.unit, value, function(v) setCfg(t.group, t.key, clamp(v, 0, t.max)) end, t.big, t.small)
  put(2, 9, value > 0 and "Alarm wlaczony" or "Alarm wylaczony (0)",
      value > 0 and colors.lime or colors.gray, colors.black)

  button(2, 11, " WYLACZ ", colors.gray, function() setCfg(t.group, t.key, 0) end)
  button(11, 11, " DOMYSLNE ", colors.gray, function() setCfg(t.group, t.key, nil) end)

  drawFooter("Zmiany zapisuja sie od razu")
end

---------------------------------------------------------------------------
-- Widok: ALM + UPDATE

-- Przycisk UPDATE: pierwsze dotkniecie uzbraja (5 s), drugie uruchamia
local updateArmed = 0
local updateRequested = false
local updating = nil        -- { replies = { {id, label, busy} } } w trakcie aktualizacji

local function hasAutostart()
  if not fs.exists("startup.lua") then return false end
  local f = fs.open("startup.lua", "r"); local c = f.readAll(); f.close()
  local header = c:match("^%-%- autostart: ([^\n]*)")
  return header ~= nil and ("," .. header .. ","):find(",scada,", 1, true) ~= nil
end

local function pressUpdate()
  if now() < updateArmed then
    updateArmed, updateRequested = 0, true
  else
    updateArmed = now() + 5000
    if hasAutostart() then
      setMsg("UPDATE: dotknij jeszcze raz, aby potwierdzic", colors.yellow)
    else
      setMsg("Brak autostartu (scada install)! Dotknij ponownie", colors.orange)
    end
  end
end

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
  if now() < updateArmed then
    button(w - 8, y, " PEWNE? ", colors.orange, pressUpdate, colors.black)
  else
    button(w - 8, y, " UPDATE ", colors.blue, pressUpdate)
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

local function drawUpdating()
  fillRow(1, colors.orange)
  put(2, 1, "AKTUALIZACJA", colors.black, colors.orange)
  put(2, 3, "Wyslano UPDATE do zolwi i czujnikow", colors.white, colors.black)
  local y = 5
  for _, r in ipairs(updating.replies) do
    if y > h - 2 then break end
    put(2, y, fit(("#%d %s"):format(r.id, r.label or ""), w - 15), colors.white, colors.black)
    put(w - 12, y, r.busy and "zajety-pomin" or "aktualizuje",
        r.busy and colors.orange or colors.lime, colors.black)
    y = y + 1
  end
  put(2, h - 1, "Zaraz aktualizacja i restart SCADA", colors.yellow, colors.black)
end

---------------------------------------------------------------------------

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

  if updating then drawUpdating()
  elseif view == "config" and selected then drawConfig()
  elseif view == "alarms" then drawAlarms()
  elseif view == "list" then drawList()
  elseif view == "pcfg" and cfgTarget then drawPointCfg()
  elseif view == "group" and drawGroup() then -- narysowane
  else view = "plant"; drawPlant() end
end

---------------------------------------------------------------------------
-- Watki: odbior wiadomosci, odpytywanie, miganie, dotyk

local function receiver()
  while true do
    local id, msg, proto = rednet.receive()
    if type(msg) ~= "table" then
      -- nic
    elseif proto == SENSOR_PROTOCOL and msg.cmd == "data" then
      if not DEMO then receiveSensor(id, msg) end
    elseif proto == ADMIN_PROTOCOL and (msg.cmd == "updating" or msg.cmd == "busy") then
      if updating then
        updating.replies[#updating.replies + 1] = { id = id, label = msg.label, busy = msg.cmd == "busy" }
        draw()
      end
    elseif proto == ALARM_PROTOCOL and msg.cmd == "ack" then
      -- potwierdzenie z pocketa (pscada)
      if msg.all then ackAll() elseif msg.key then ackAlarm(msg.key) end
      syncAlarms()
      draw()
    elseif proto == PROTOCOL then
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

-- Co REFRESH sekund odpytuje zolwie, liczy alarmy i odswieza ekran
local function pinger()
  while true do
    if DEMO then
      tickDemo()
    else
      rednet.broadcast({ cmd = "ping" }, PROTOCOL)
      sleep(1.5) -- czas na odpowiedzi
    end
    evalAlarms()
    draw()
    sleep(DEMO and REFRESH or (REFRESH - 1.5))
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

-- UPDATE: zdalnie zolwie i czujniki, potem sama SCADA + restart komputera
local function runUpdate()
  updating = { replies = {} }
  if not DEMO then rednet.broadcast({ cmd = "update" }, ADMIN_PROTOCOL) end
  draw()
  sleep(3) -- odpowiedzi zbiera receiver i dopisuje na ekranie
  if DEMO then
    updating = nil
    setMsg("Demo: aktualizacja pominieta", colors.yellow)
    draw()
    return
  end
  term.setCursorPos(1, TERM_ROW + 1)
  shell.run("update")
  os.reboot()
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
      if updateRequested then
        updateRequested = false
        runUpdate()
      end
    elseif ev == "monitor_resize" then
      draw()
    end
  end
end

---------------------------------------------------------------------------

-- Bez term.clear(): na tym samym komputerze moze dzialac sensor (wiersze 1-8)
term.setCursorPos(1, TERM_ROW); term.clearLine()
term.write("SCADA dziala na monitorze. Ctrl+T - wyjscie.")
term.setCursorPos(1, TERM_ROW + 1)

if DEMO then initDemo(); tickDemo() end
draw()
parallel.waitForAny(receiver, pinger, ui, blinker)

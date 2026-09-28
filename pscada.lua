-- pscada.lua - mini SCADA na (advanced) pocket computer
--
-- Uzycie:  pscada        - dane z zolwi, czujnikow (sensor) i alarmy ze SCADA
--          pscada demo   - dane testowe
--
-- Obsluga: dotknij zakladki u gory albo klawisze 1/2/3, Q - wyjscie.
--   1 ZOLW - stan zolwi
--   2 ZAKL - grupy z czujnikow (prad, SU, plyny, magazyn);
--            przewijanie: strzalki gora/dol albo kolko myszy
--   3 ALM  - alarmy ze SCADA; dotknij alarmu = potwierdz, A = wszystkie.
--            Alarmy i progi liczy duza SCADA - musi dzialac.

local PROTOCOL        = "flatten"
local SENSOR_PROTOCOL = "scada_sensor"
local ALARM_PROTOCOL  = "scada_alarm"
local REFRESH         = 5
local OFFLINE         = 15
local LOW_FUEL        = 500

local DEMO = ({ ... })[1] == "demo"

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
local function shortName(n) return (tostring(n):match(":(.+)$") or tostring(n)) end

local function fmtNum(n)
  if math.abs(n) >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if math.abs(n) >= 1e4 then return ("%.1fk"):format(n / 1e3) end
  return tostring(math.floor(n))
end

local turtles = {}
local groups  = {}            -- nazwa -> { last, sum }
local view    = "turtles"
local plantScroll = 0

-- Alarmy ze SCADA
local alarmList, scadaId, lastSync = {}, nil, 0
local seenAlarms = {}        -- klucze juz widzianych alarmow
local newAlarmUntil = 0      -- do kiedy pokazywac "NOWY ALARM"
local alarmRows = {}         -- wiersz ekranu -> klucz alarmu

local function unackedCount(onlyGroups)
  local n = 0
  for _, a in ipairs(alarmList) do
    if not a.acked and (not onlyGroups or a.group) then n = n + 1 end
  end
  return n
end

local function setAlarms(list)
  alarmList = list
  for _, a in ipairs(list) do
    if a.active and not a.acked and not seenAlarms[a.key .. a.since] then
      newAlarmUntil = now() + 10000
    end
    seenAlarms[a.key .. a.since] = true
  end
end

local function sendAck(key)
  if DEMO then
    for i = #alarmList, 1, -1 do
      local a = alarmList[i]
      if key == nil or a.key == key then
        a.acked = true
        if not a.active then table.remove(alarmList, i) end
      end
    end
    return
  end
  if not scadaId then return end
  rednet.send(scadaId, { cmd = "ack", key = key, all = key == nil }, ALARM_PROTOCOL)
end

---------------------------------------------------------------------------
-- Dane z czujnikow: krotkie podsumowanie grupy

local function summarize(points)
  local s = { energy = 0, energyCap = 0, suMax = nil, fluids = {}, fluidList = {},
              itemTypes = 0, itemSources = 0, stations = 0 }
  for _, pt in ipairs(points or {}) do
    if pt.kind == "energy" then
      s.energy, s.energyCap = s.energy + pt.energy, s.energyCap + pt.capacity
    elseif pt.kind == "stress" and pt.capacity > 0 then
      s.suMax = math.max(s.suMax or 0, pt.stress / pt.capacity * 100)
    elseif pt.kind == "fluid" then
      for _, f in ipairs(pt.fluids or {}) do s.fluids[f.name] = (s.fluids[f.name] or 0) + f.amount end
    elseif pt.kind == "items" then
      s.itemSources = pt.sources or 0
      for _ in pairs(pt.items or {}) do s.itemTypes = s.itemTypes + 1 end
    elseif pt.kind == "station" then
      s.stations = s.stations + 1
    end
  end
  for name, amount in pairs(s.fluids) do s.fluidList[#s.fluidList + 1] = { name = name, amount = amount } end
  table.sort(s.fluidList, function(a, b) return a.amount > b.amount end)
  return s
end

-- Kilka czujnikow z ta sama etykieta = jedna grupa (jak na duzej SCADA)
local function receiveSensor(id, msg)
  local key = tostring(msg.label or ("#" .. id))
  for label, og in pairs(groups) do
    if label ~= key and og.members[id] then
      og.members[id] = nil
      if next(og.members) == nil then groups[label] = nil end
    end
  end
  local g = groups[key] or { members = {} }
  groups[key] = g
  g.members[id] = { last = now(), points = type(msg.points) == "table" and msg.points or {} }
  g.last = now()
  local all = {}
  for _, m in pairs(g.members) do
    if isOnline(m) then
      for _, pt in ipairs(m.points) do all[#all + 1] = pt end
    end
  end
  g.sum = summarize(all)
end

local function demoTick()
  local t = os.clock()
  turtles[3] = { last = now(), data = { label = "Kopacz", state = "work", program = "flatten",
                                        progress = (t / 60) % 1, fuel = 4200 } }
  turtles[7] = { last = now(), data = { state = "idle", fuel = 320 } }
  turtles[21] = turtles[21] or { last = now() - 60000, data = { state = "idle", fuel = 0 } }
  receiveSensor(9001, { label = "Wyspa Glowna", points = {
    { kind = "energy", energy = math.floor(35e6 + 30e6 * math.sin(t / 30)), capacity = 70e6 },
    { kind = "stress", stress = 1500, capacity = 2048 },
    { kind = "fluid", fluids = { { name = "minecraft:lava", amount = math.floor(400000 + 200000 * math.sin(t / 20)) } } },
    { kind = "fluid", fluids = { { name = "minecraft:water", amount = 512000 } } },
    { kind = "items", sources = 3, items = { a = 1, b = 2, c = 3 } },
    { kind = "station" },
  } })
  receiveSensor(9002, { label = "Kopalnia", points = {
    { kind = "energy", energy = 1.5e6, capacity = 10e6 },
    { kind = "stress", stress = 4100, capacity = 4096 },
  } })
  if #alarmList == 0 then
    setAlarms({
      { key = "g_su_Kopalnia", text = "[Kopalnia] PRZECIAZENIE sieci", crit = true, group = "Kopalnia",
        since = now(), active = true, acked = false },
      { key = "t_off_21", text = "Zolw #21 offline", crit = false,
        since = now() - 300000, active = true, acked = true },
      { key = "g_en_Kopalnia", text = "[Kopalnia] malo pradu: 15%", crit = true, group = "Kopalnia",
        since = now() - 600000, active = false, acked = false },
    })
  end
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

local function sortedIds(t)
  local ids = {}
  for id in pairs(t) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    if type(a) == "number" and type(b) == "number" then return a < b end
    return tostring(a) < tostring(b)
  end)
  return ids
end

local TABS = {
  { x = 1,  label = " ZOLW ", view = "turtles" },
  { x = 7,  label = " ZAKL ", view = "plant" },
  { x = 13, label = " ALM ",  view = "alarms" },
}

local function drawTabs()
  fillRow(1, c(colors.blue, colors.black))
  local alarm = {
    turtles = false,
    plant = unackedCount(true) > 0,
    alarms = unackedCount() > 0,
  }
  for _, a in ipairs(alarmList) do
    if not a.acked and not a.group and a.active then alarm.turtles = true end
  end
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
    elseif d.waiting then st, col = "BRAK", colors.orange
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
    if isOnline(e) and d.waiting and y <= h - 1 then
      put(2, y, fit("! " .. d.waiting, w - 2), c(colors.orange), colors.black)
      y = y + 1
    elseif d.label and y <= h - 1 then
      put(2, y, fit(d.label, w - 2), c(colors.lightGray), colors.black)
      y = y + 1
    end
  end
  if y == 3 then put(1, 4, "Brak zolwi w zasiegu", c(colors.lightGray), colors.black) end
end

-- Liczba alarmow grupy (z listy SCADA)
local function groupAlarms(label)
  local act, unacked = 0, 0
  for _, a in ipairs(alarmList) do
    if a.group == label then
      if a.active then act = act + 1 end
      if not a.acked then unacked = unacked + 1 end
    end
  end
  return act, unacked
end

-- ZAKL: karty grup; kazda grupa to kilka linii, calosc przewijana
local function drawPlant()
  local lines = {}
  local function L(text, fg, bg) lines[#lines + 1] = { text = text, fg = fg, bg = bg } end

  for _, label in ipairs(sortedIds(groups)) do
    local g = groups[label]
    local act, unacked = groupAlarms(label)
    local status, scol
    if not isOnline(g) then status, scol = "OFFLN", colors.red
    elseif unacked > 0 then status, scol = "ALM" .. unacked, colors.red
    elseif act > 0 then status, scol = "ALM" .. act, colors.orange
    else status, scol = "OK", colors.lime end
    L(fit(label, w - 6) .. ("%6s"):format(status), c(scol), c(colors.gray, colors.black))

    if isOnline(g) then
      local s = g.sum
      local parts = {}
      if s.energyCap > 0 then parts[#parts + 1] = ("FE %d%%"):format(math.floor(s.energy / s.energyCap * 100)) end
      if s.suMax then parts[#parts + 1] = ("SU %d%%"):format(math.floor(s.suMax)) end
      if #parts > 0 then
        L(" " .. table.concat(parts, "  "),
          (s.suMax and s.suMax > 100) and c(colors.red) or colors.white)
      end
      for i = 1, math.min(3, #s.fluidList) do
        local f = s.fluidList[i]
        L((" %-14s%9s"):format(shortName(f.name):sub(1, 14), ("%.1f B"):format(f.amount / 1000)), c(colors.cyan))
      end
      if s.itemSources > 0 or s.stations > 0 then
        L((" magazyn %d poz.  stacje %d"):format(s.itemTypes, s.stations), c(colors.lightGray))
      end
    end
  end
  if #lines == 0 then
    L("Brak czujnikow w zasiegu", c(colors.lightGray))
    L("(sensor na komputerach)", c(colors.lightGray))
  end

  local top, n = 2, h - 2
  plantScroll = clamp(plantScroll, 0, math.max(0, #lines - n))
  for i = 1, n do
    local l = lines[plantScroll + i]
    if not l then break end
    put(1, top + i - 1, fit(l.text, w), l.fg or colors.white, l.bg or colors.black)
  end
end

-- ALM: kazdy alarm zajmuje 2 wiersze (czas + tekst)
local function drawAlarms()
  alarmRows = {}
  if not DEMO and (not scadaId or now() - lastSync > OFFLINE * 1000) then
    put(1, 3, "Brak polaczenia ze SCADA", c(colors.red), colors.black)
    put(1, 4, "(alarmy liczy duza SCADA)", c(colors.lightGray), colors.black)
    return
  end

  local y = 3
  for _, a in ipairs(alarmList) do
    if y + 1 > h - 3 then
      put(1, y, "...", c(colors.lightGray), colors.black)
      break
    end
    local col = colors.yellow                                   -- ustapil
    if a.active and not a.acked then col = colors.red
    elseif a.active then col = colors.orange end
    local head = os.date("%H:%M", math.floor(a.since / 1000))
                 .. (a.crit and " ALARM" or " uwaga")
                 .. (a.active and "" or " (ok)")
                 .. (a.acked and "" or " *")
    put(1, y, fit(head, w), c(col), colors.black)
    put(2, y + 1, fit(a.text, w - 1), colors.white, colors.black)
    alarmRows[y], alarmRows[y + 1] = a.key, a.key
    y = y + 2
  end
  if #alarmList == 0 then
    put(1, 3, "Brak alarmow - OK", c(colors.lime), colors.black)
  end

  if unackedCount() > 0 then
    put(1, h - 1, " POTWIERDZ WSZYSTKIE (A) ", colors.white, c(colors.green, colors.black))
  end
end

local function draw()
  w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  drawTabs()

  if view == "plant" then drawPlant()
  elseif view == "alarms" then drawAlarms()
  else drawTurtles() end

  if now() < newAlarmUntil then
    fillRow(h, c(colors.red, colors.white))
    put(1, h, "!! NOWY ALARM - klawisz 3", colors.white, c(colors.red, colors.white))
  else
    fillRow(h, c(colors.gray, colors.black))
    put(1, h, DEMO and "DEMO | 1-3, Q-wyjscie" or "1-3 zakladki, Q-wyjscie",
        colors.white, c(colors.gray, colors.black))
  end
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
      elseif proto == SENSOR_PROTOCOL and msg.cmd == "data" then
        receiveSensor(id, msg)
        if view == "plant" then draw() end
      elseif proto == ALARM_PROTOCOL and msg.cmd == "alarms" and type(msg.list) == "table" then
        scadaId, lastSync = id, now()
        local before = newAlarmUntil
        setAlarms(msg.list)
        if newAlarmUntil ~= before or view == "alarms" then draw() end
      end
    end
  end
end

local function pinger()
  while true do
    if DEMO then demoTick() else rednet.broadcast({ cmd = "ping" }, PROTOCOL) end
    sleep(1.5)
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
    elseif ev == "mouse_click" and view == "alarms" then
      if y == h - 1 and unackedCount() > 0 then sendAck(nil)
      elseif alarmRows[y] then sendAck(alarmRows[y]) end
      newAlarmUntil = 0
      draw()
    elseif ev == "mouse_scroll" and view == "plant" then
      plantScroll = plantScroll + a
      draw()
    elseif ev == "key" then
      if a == keys.one then view = "turtles"
      elseif a == keys.two then view = "plant"
      elseif a == keys.three then view = "alarms"; newAlarmUntil = 0
      elseif a == keys.up and view == "plant" then plantScroll = plantScroll - 1
      elseif a == keys.down and view == "plant" then plantScroll = plantScroll + 1
      elseif a == keys.a and view == "alarms" then sendAck(nil)
      elseif a == keys.q then return end
      draw()
    end
  end
end

if DEMO then demoTick() end
draw()
parallel.waitForAny(receiver, pinger, ui)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

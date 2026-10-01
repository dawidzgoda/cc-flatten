-- scadalib/data.lua - grupy z czujnikow, historia do wykresow, dane demo
--
-- groups[nazwa] = { label, last, members, points, sum, hist, series }
--   members - czujniki z ta etykieta: id -> { last, points }; kilka
--             komputerow z ta sama nazwa tworzy JEDNA grupe
--   points  - polaczone punkty aktywnych czujnikow grupy
--   sum     - podsumowanie punktow (patrz summarize)
--   hist    - historia energii { t, v, sig } do bilansu FE/t
--   series  - historia do wykresow (patrz pushSeries)

local app    = require("scadalib.app")
local config = require("scadalib.config")

local data = {}
local groups = {}
data.groups = groups

local now, isOnline = app.now, app.isOnline

---------------------------------------------------------------------------
-- Podsumowanie punktow grupy

function data.summarize(points)
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
      -- kilka czujnikow w grupie -> sumujemy magazyny
      for name, count in pairs(pt.items or {}) do s.items[name] = (s.items[name] or 0) + count end
      s.itemSources = s.itemSources + (pt.sources or 0)
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
function data.histRate(hist, msPerUnit)
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

-- Bilans pradu grupy w FE/t (1 tick = 50 ms)
function data.energyRate(g) return data.histRate(g.hist, 50) end

---------------------------------------------------------------------------
-- Historia do wykresow
--
-- g.series[klucz] (klucze jak w progach: energy, su:<id>, rpm:<id>,
-- fluid:<nazwa>, item:<nazwa>), wartosci w jednostkach wykresu:
-- energy/su w %, rpm, plyny w wiadrach, przedmioty w sztukach.
--   short - ostatnie 10 min (probka co 5 s)
--   long  - ostatnie 2 h (srednia z kazdej minuty)

local SHORT_MAX, LONG_MAX, LONG_STEP = 120, 120, 60000
local HIST_FILE = "scada_hist"

-- Historia z dysku; trafia do serii przy pierwszych danych grupy.
-- Format: { t = czas zapisu, groups = { grupa = { klucz = { long, short } } } }
local savedHist, savedAt = {}, 0

function data.loadHistory()
  local d = app.readTable(HIST_FILE)
  if not d then return end
  if type(d.groups) == "table" then savedHist, savedAt = d.groups, tonumber(d.t) or 0
  else savedHist = d end   -- stary format: { grupa = { klucz = long } }
end

local function pushSeries(label, g, key, v)
  g.series = g.series or {}
  local s = g.series[key]
  if not s then
    local old = savedHist[label] and savedHist[label][key]
    local long, short = {}, {}
    if type(old) == "table" then
      if type(old.long) == "table" then
        long = old.long
        -- 10 min z dysku ma sens tylko, jesli zapis jest swiezy
        if type(old.short) == "table" and now() - savedAt < SHORT_MAX * app.REFRESH * 1000 then
          short = old.short
        end
      else
        long = old
      end
    end
    s = { short = short, long = long, acc = 0, n = 0, t0 = now() }
    g.series[key] = s
  end
  s.last = v
  s.short[#s.short + 1] = v
  if #s.short > SHORT_MAX then table.remove(s.short, 1) end
  s.acc, s.n = s.acc + v, s.n + 1
  if now() - s.t0 >= LONG_STEP then
    s.long[#s.long + 1] = s.acc / s.n
    if #s.long > LONG_MAX then table.remove(s.long, 1) end
    s.acc, s.n, s.t0 = 0, 0, now()
  end
end

local function sampleSeries(label, g)
  local s = g.sum
  if s.energyCap > 0 then pushSeries(label, g, "energy", s.energy / s.energyCap * 100) end
  for _, st in ipairs(s.stress) do
    if st.capacity > 0 then pushSeries(label, g, "su:" .. st.id, st.stress / st.capacity * 100) end
  end
  for _, sp in ipairs(s.speed) do pushSeries(label, g, "rpm:" .. sp.id, sp.speed) end
  if s.tanks > 0 then
    for _, f in ipairs(s.fluidList) do pushSeries(label, g, "fluid:" .. f.name, f.amount / 1000) end
    for name in pairs(config.watched(label, "fluid:")) do
      if not s.fluids[name] then pushSeries(label, g, "fluid:" .. name, 0) end
    end
  end
  if s.itemSources > 0 then
    -- tylko obserwowane i 15 najliczniejszych (jak na ekranie)
    local watch = config.watched(label, "item:")
    for name in pairs(watch) do pushSeries(label, g, "item:" .. name, s.items[name] or 0) end
    local n = 0
    for _, it in ipairs(s.itemList) do
      if not watch[it.name] then
        pushSeries(label, g, "item:" .. it.name, it.count)
        n = n + 1
        if n >= 15 then break end
      end
    end
  end
end

function data.saveHistory()
  local out = {}
  for label, g in pairs(groups) do
    out[label] = {}
    for key, s in pairs(g.series or {}) do
      out[label][key] = { long = s.long, short = s.short }
    end
  end
  -- grupy, ktore jeszcze sie nie odezwaly po starcie - zachowaj stara historie
  for label, keys in pairs(savedHist) do
    if not out[label] then out[label] = keys end
  end
  app.writeTable(HIST_FILE, { t = now(), groups = out })
end

-- Tempo zmiany serii na minute z ostatniej minuty probek
function data.seriesRate(series)
  if not series or #series.short < 3 then return 0 end
  local n = math.min(#series.short, 60 / app.REFRESH + 1)
  local a, b = series.short[#series.short - n + 1], series.short[#series.short]
  local r = (b - a) / ((n - 1) * app.REFRESH / 60)
  if math.abs(r) < 1e-6 then return 0 end
  return r
end

---------------------------------------------------------------------------
-- Czujniki -> grupy

-- Laczy punkty aktywnych czujnikow grupy. Przy kilku czujnikach nazwy
-- urzadzen dostaja prefiks "#id/" (kazdy komputer numeruje od 0).
function data.mergeMembers(g)
  local active = {}
  for mid, m in pairs(g.members) do
    if isOnline(m) then active[#active + 1] = mid end
  end
  table.sort(active)
  local multi = #active > 1
  local all = {}
  for _, mid in ipairs(active) do
    for _, pt in ipairs(g.members[mid].points) do
      if multi then
        local copy = {}
        for k, v in pairs(pt) do copy[k] = v end
        copy.id = "#" .. mid .. "/" .. tostring(pt.id)
        pt = copy
      end
      all[#all + 1] = pt
    end
  end
  g.points = all
  g.sum = data.summarize(all)
end

function data.receiveSensor(id, msg)
  local key = tostring(msg.label or ("#" .. id))
  local g = groups[key]
  if not g then
    g = { label = key, hist = {}, members = {} }
    groups[key] = g
  end
  -- czujnik mogl zmienic nazwe - usun go ze starej grupy
  for label, og in pairs(groups) do
    if label ~= key and og.members[id] then
      og.members[id] = nil
      if next(og.members) == nil then groups[label] = nil else data.mergeMembers(og) end
    end
  end
  g.members[id] = { last = now(), points = type(msg.points) == "table" and msg.points or {} }
  g.last = now()
  data.mergeMembers(g)
  -- historia raz na cykl, nawet gdy grupa ma kilka czujnikow
  if not g.lastSample or now() - g.lastSample >= app.REFRESH * 1000 - 1000 then
    g.lastSample = now()
    g.hist[#g.hist + 1] = { t = now(), v = g.sum.energy, sig = g.sum.energyCap }
    if #g.hist > 24 then table.remove(g.hist, 1) end
    sampleSeries(key, g)
  end
end

-- Czujnik, ktory przestal nadawac, wypada z polaczonych danych grupy
function data.refreshGroups()
  for _, g in pairs(groups) do data.mergeMembers(g) end
end

function data.removeMember(label, mid)
  local g = groups[label]
  if not g then return end
  g.members[mid] = nil
  if next(g.members) == nil then groups[label] = nil else data.mergeMembers(g) end
end

function data.groupNames()
  local names = {}
  for k in pairs(groups) do names[#names + 1] = k end
  table.sort(names)
  return names
end

---------------------------------------------------------------------------
-- Tryb demo

function data.initDemo()
  if not config.data["Wyspa Glowna"] then
    config.data["Wyspa Glowna"] = { ["fluid:minecraft:lava"] = 200, ["item:minecraft:coal"] = 128,
                                    ["cap:fluid:minecraft:lava"] = 720 }
  end
end

function data.tickDemo()
  local t = os.clock()
  data.receiveSensor(9001, { label = "Wyspa Glowna", points = {
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
  data.receiveSensor(9002, { label = "Kopalnia", points = {
    { kind = "energy", id = "powah:energy_cell_1", energy = 1.5e6, capacity = 10e6 },
    { kind = "stress", id = "Create_Stressometer_1", stress = math.floor(3900 + 300 * math.sin(t / 8)), capacity = 4096 },
    { kind = "fluid",  id = "create:fluid_tank_0", fluids = { { name = "minecraft:lava", amount = 64000 } } },
  } })
  if not groups["Magazyn Stary"] then
    data.receiveSensor(9003, { label = "Magazyn Stary", points = {} })
    groups["Magazyn Stary"].last = now() - 60000
    groups["Magazyn Stary"].members[9003].last = now() - 60000
  end
end

return data

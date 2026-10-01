-- scadalib/sections.lua - sekcje kategorii (wiersze listy) dla jednej grupy
--
-- Kazda funkcja kategorii dopisuje wiersze do 'rows' i zwraca true, jesli
-- grupa ma cos w tej kategorii. Uzywaja ich:
--   * widok kategorii (sidebar: PRAD, KINETYKA, ...) - wszystkie grupy,
--   * widok grupy (PRZEGLAD -> grupa) - wszystkie kategorie jednej grupy.

local app    = require("scadalib.app")
local config = require("scadalib.config")
local data   = require("scadalib.data")
local alarms = require("scadalib.alarms")

local sections = {}

local shortName, fmtNum, fmtFE, buckets = app.shortName, app.fmtNum, app.fmtFE, app.buckets

---------------------------------------------------------------------------
-- Pozycje z wykresem i progiem alarmu (widok "point")

function sections.openPoint(t)
  app.cfgTarget = t
  app.go("point")
end

local function pointEnergy(label)
  return { group = label, key = "energy", title = "Prad", desc = "Alarm, gdy naladowanie ponizej",
           unit = "%", default = 20, big = 10, small = 1, max = 100 }
end
local function pointSU(label, id)
  return { group = label, key = "su:" .. id, title = "SU " .. shortName(id),
           desc = "Ostrzezenie od obciazenia", unit = "%", default = 90, big = 10, small = 1, max = 100 }
end
local function pointRPM(label, id)
  return { group = label, key = "rpm:" .. id, title = "RPM " .. shortName(id),
           desc = "Ostrzezenie, gdy predkosc ponizej", unit = "RPM", default = 0, big = 32, small = 1, max = 256 }
end
local function pointFluid(label, name)
  return { group = label, key = "fluid:" .. name, title = shortName(name),
           desc = "Alarm, gdy mniej niz (wiadra)", unit = "B", default = 0, big = 64, small = 8,
           max = 99999, capKey = "cap:fluid:" .. name }
end
local function pointItem(label, name)
  return { group = label, key = "item:" .. name, title = shortName(name),
           desc = "Ostrzezenie, gdy mniej niz (szt.)", unit = "szt", default = 0, big = 64, small = 1,
           max = 99999 }
end

---------------------------------------------------------------------------
-- Pomocnicze

local function sec(rows, text)
  rows[#rows + 1] = { text = text, fg = colors.black, bg = colors.lightGray }
end

-- Stan grupy do naglowkow i kart: tekst, kolor
function sections.groupStatus(label, g)
  local act, unacked = alarms.counts(label)
  if not app.isOnline(g) then return "OFFLINE", colors.red end
  if unacked > 0 then return ("ALM %d"):format(math.max(act, unacked)), colors.red end
  if act > 0 then return ("ALM %d"):format(act), colors.orange end
  return "OK", colors.lime
end

-- Naglowek grupy w widoku kategorii (dotkniecie -> widok grupy)
function sections.groupHeader(rows, label, g)
  local status, scol = sections.groupStatus(label, g)
  rows[#rows + 1] = { text = label, fg = colors.white, bg = colors.blue, right = status, rfg = scol,
                      action = function() app.selGroup = label; app.go("group") end }
end

---------------------------------------------------------------------------
-- PRAD

function sections.energy(label, g, rows, titled)
  local s = g.sum
  if s.energyCap <= 0 then return false end
  local pct = s.energy / s.energyCap * 100
  local min = config.get(label, "energy", 20)
  local col = (min > 0 and pct < min) and colors.red or (pct < 50 and colors.yellow or colors.lime)
  local rate = data.energyRate(g)
  local open = function() sections.openPoint(pointEnergy(label)) end

  if titled then sec(rows, "PRAD") end
  rows[#rows + 1] = { bar = pct / 100, barCol = col }
  rows[#rows + 1] = { text = fmtFE(s.energy) .. " / " .. fmtFE(s.energyCap),
                      right = (rate > 0 and "+" or "") .. fmtFE(rate) .. "/t",
                      rfg = rate < 0 and colors.red or (rate > 0 and colors.lime or colors.lightGray),
                      action = open }
  -- prognoza: FE/t -> FE/min (1200 tickow na minute)
  local eta, etaCol = app.etaText(rate * 1200, s.energy, s.energyCap)
  rows[#rows + 1] = { text = eta or "bilans zerowy", fg = eta and etaCol or colors.lightGray,
                      right = "alarm < " .. (min > 0 and (min .. "%") or "wyl."), rfg = colors.lightBlue,
                      action = open }
  if #s.energySrc > 1 then
    for _, src in ipairs(s.energySrc) do
      rows[#rows + 1] = { text = "  " .. shortName(src.id), fg = colors.lightGray,
                          right = ("%s %d%%"):format(fmtFE(src.energy), math.floor(src.energy / src.capacity * 100)) }
    end
  end
  return true
end

---------------------------------------------------------------------------
-- KINETYKA (Create: Stressometer, Speedometer)

function sections.kinetic(label, g, rows, titled)
  local s = g.sum
  if #s.stress + #s.speed == 0 then return false end
  if titled then sec(rows, "KINETYKA") end
  for _, st in ipairs(s.stress) do
    local pct = st.capacity > 0 and st.stress / st.capacity * 100 or 0
    local max = config.get(label, "su:" .. st.id, 90)
    local col = st.stress > st.capacity and colors.red
             or ((max > 0 and pct >= max) and colors.orange or colors.lime)
    local open = function() sections.openPoint(pointSU(label, st.id)) end
    rows[#rows + 1] = { text = "SU " .. shortName(st.id), fg = col,
                        right = st.capacity > 0
                          and ("%s/%s %d%%"):format(fmtNum(st.stress), fmtNum(st.capacity), math.floor(pct))
                          or "siec stoi",
                        action = open }
    if st.capacity > 0 then rows[#rows + 1] = { bar = math.min(pct / 100, 1), barCol = col } end
  end
  for _, sp in ipairs(s.speed) do
    local min = config.get(label, "rpm:" .. sp.id, 0)
    local col = (min > 0 and math.abs(sp.speed) < min) and colors.orange or colors.white
    rows[#rows + 1] = { text = "RPM " .. shortName(sp.id), fg = col,
                        right = ("%d RPM"):format(sp.speed) .. (min > 0 and (" /min " .. min) or ""),
                        action = function() sections.openPoint(pointRPM(label, sp.id)) end }
  end
  return true
end

---------------------------------------------------------------------------
-- PLYNY (zbiorniki; pojemnosc ustawiana recznie -> pasek i prognoza)

function sections.fluid(label, g, rows, titled)
  local s = g.sum
  if s.tanks == 0 then return false end
  if titled then sec(rows, ("PLYNY (%d zbiornikow)"):format(s.tanks)) end
  local watch = config.watched(label, "fluid:")
  local shown = {}

  local function fluidRow(name, amount, tanks)
    local min = config.get(label, "fluid:" .. name, 0)
    local cap = config.get(label, "cap:fluid:" .. name, 0)
    local low = min > 0 and amount < min * 1000
    local open = function() sections.openPoint(pointFluid(label, name)) end
    local right = cap > 0 and ("%s/%d B"):format(fmtNum(amount / 1000), cap) or buckets(amount)
    if min > 0 then right = right .. " /min " .. min end
    rows[#rows + 1] = { text = shortName(name) .. (tanks and (" (" .. tanks .. ")") or ""),
                        fg = low and colors.red or colors.cyan, right = right,
                        rfg = low and colors.red or colors.white, action = open }
    if cap > 0 then
      rows[#rows + 1] = { bar = amount / 1000 / cap,
                          barCol = low and colors.red or (name:find("lava") and colors.orange or colors.cyan) }
      local series = g.series and g.series["fluid:" .. name]
      local r = data.seriesRate(series)
      local eta, etaCol = app.etaText(r, amount / 1000, cap)
      if eta then
        rows[#rows + 1] = { text = "  " .. eta, fg = etaCol, right = ("%+.1f B/min"):format(r),
                            rfg = etaCol, action = open }
      end
    end
    shown[name] = true
  end

  for _, f in ipairs(s.fluidList) do fluidRow(f.name, f.amount, f.tanks) end
  for name in pairs(watch) do if not shown[name] then fluidRow(name, 0) end end
  if #s.fluidList == 0 and next(watch) == nil then
    rows[#rows + 1] = { text = "wszystkie zbiorniki puste", fg = colors.lightGray }
  end
  return true
end

---------------------------------------------------------------------------
-- MAGAZYN (obserwowane + najliczniejsze)

function sections.items(label, g, rows, titled, limit)
  local s = g.sum
  if s.itemSources == 0 then return false end
  if titled then sec(rows, ("MAGAZYN (%d rodzajow, %d zrodel)"):format(#s.itemList, s.itemSources)) end
  local watch = config.watched(label, "item:")

  local function itemRow(name, count)
    local min = config.get(label, "item:" .. name, 0)
    local low = min > 0 and count < min
    rows[#rows + 1] = { text = shortName(name),
                        fg = low and colors.red or (min > 0 and colors.yellow or colors.white),
                        right = fmtNum(count) .. (min > 0 and (" /min " .. fmtNum(min)) or ""),
                        rfg = low and colors.red or colors.white,
                        action = function() sections.openPoint(pointItem(label, name)) end }
  end

  local wl = {}
  for name in pairs(watch) do wl[#wl + 1] = name end
  table.sort(wl)
  for _, name in ipairs(wl) do itemRow(name, s.items[name] or 0) end
  local n = 0
  for _, it in ipairs(s.itemList) do
    if not watch[it.name] then
      itemRow(it.name, it.count)
      n = n + 1
      if n >= (limit or 15) then break end
    end
  end
  if #s.itemList == 0 then rows[#rows + 1] = { text = "magazyn pusty", fg = colors.lightGray } end
  return true
end

---------------------------------------------------------------------------
-- POCIAGI (Create: stacje i sygnaly)

function sections.trains(label, g, rows, titled)
  local s = g.sum
  if #s.stations + #s.signals == 0 then return false end
  if titled then sec(rows, "POCIAGI") end
  for _, st in ipairs(s.stations) do
    local state, col
    if st.present then state, col = "stoi: " .. tostring(st.train or "?"), colors.lime
    elseif st.imminent then state, col = "nadjezdza", colors.yellow
    elseif st.enroute then state, col = "w drodze", colors.lightGray
    else state, col = "pusto", colors.gray end
    rows[#rows + 1] = { text = "Stacja " .. tostring(st.station or shortName(st.id)), right = state, rfg = col }
  end
  for _, sg in ipairs(s.signals) do
    local col = sg.state == "GREEN" and colors.lime or (sg.state == "RED" and colors.red or colors.yellow)
    rows[#rows + 1] = { text = "Sygnal " .. shortName(sg.id), right = tostring(sg.state), rfg = col }
  end
  return true
end

---------------------------------------------------------------------------
-- CZUJNIKI grupy (offline mozna usunac dotykiem)

function sections.members(label, g, rows)
  local ids = {}
  for mid in pairs(g.members) do ids[#ids + 1] = mid end
  table.sort(ids)
  sec(rows, ("CZUJNIKI (%d)"):format(#ids))
  for _, mid in ipairs(ids) do
    local m = g.members[mid]
    if app.isOnline(m) then
      rows[#rows + 1] = { text = ("#%d"):format(mid), right = ("OK, %d urzadzen"):format(#m.points), rfg = colors.lime }
    else
      rows[#rows + 1] = { text = ("#%d offline od %s - dotknij = usun"):format(mid, app.hhmm(m.last)),
                          fg = colors.red,
                          action = function()
                            data.removeMember(label, mid)
                            if not data.groups[label] then app.go("overview") end
                          end }
    end
  end
end

---------------------------------------------------------------------------
-- Kategorie w sidebarze (kolejnosc menu)

sections.CATEGORIES = {
  { view = "energy",  label = "PRAD",     cat = "energy",  build = sections.energy },
  { view = "kinetic", label = "KINETYKA", cat = "kinetic", build = sections.kinetic },
  { view = "fluid",   label = "PLYNY",    cat = "fluid",   build = sections.fluid },
  { view = "items",   label = "MAGAZYN",  cat = "items",   build = sections.items },
  { view = "trains",  label = "POCIAGI",  cat = nil,       build = sections.trains },
}

return sections

-- scadalib/views.lua - ekrany SCADA i sidebar
--
-- Sidebar: ALARMY, PRZEGLAD (karty grup), PRAD, KINETYKA, PLYNY, MAGAZYN,
-- POCIAGI (kazda kategoria pokazuje wszystkie grupy), na dole TEST SYRENY
-- i UPDATE. Z kategorii/przegladu: dotknij grupy -> widok grupy, dotknij
-- pozycji -> wykres i prog alarmu.

local app      = require("scadalib.app")
local config   = require("scadalib.config")
local data     = require("scadalib.data")
local alarms   = require("scadalib.alarms")
local ui       = require("scadalib.ui")
local sections = require("scadalib.sections")

local views = {}

local clamp, fit, now = app.clamp, ui.fit, app.now

---------------------------------------------------------------------------
-- UPDATE: pierwsze dotkniecie uzbraja (5 s), drugie zleca (wykonuje scada.lua)

app.updateArmed, app.updateRequested, app.updating = 0, false, nil

local function hasAutostart()
  if not fs.exists("startup.lua") then return false end
  local f = fs.open("startup.lua", "r"); local c = f.readAll(); f.close()
  local header = c:match("^%-%- autostart: ([^\n]*)")
  return header ~= nil and ("," .. header .. ","):find(",scada,", 1, true) ~= nil
end

local function pressUpdate()
  if now() < app.updateArmed then
    app.updateArmed, app.updateRequested = 0, true
  else
    app.updateArmed = now() + 5000
    if hasAutostart() then
      app.setMsg("UPDATE: dotknij jeszcze raz, aby potwierdzic", colors.yellow)
    else
      app.setMsg("Brak autostartu (scada install)! Dotknij ponownie", colors.orange)
    end
  end
end

---------------------------------------------------------------------------
-- Sidebar

local function drawSidebar()
  local active, unacked = alarms.counts()
  local names = data.groupNames()
  local online, totalE, totalC, maxSu, fluids, stations = 0, 0, 0, nil, {}, 0
  local itemTypes = 0
  for _, label in ipairs(names) do
    local g = data.groups[label]
    if app.isOnline(g) then
      online = online + 1
      local s = g.sum
      totalE, totalC = totalE + s.energy, totalC + s.energyCap
      for _, st in ipairs(s.stress) do
        if st.capacity > 0 then maxSu = math.max(maxSu or 0, st.stress / st.capacity * 100) end
      end
      for name in pairs(s.fluids) do fluids[name] = true end
      itemTypes = itemTypes + #s.itemList
      stations = stations + #s.stations
    end
  end
  local nFluids = 0
  for _ in pairs(fluids) do nFluids = nFluids + 1 end

  local function catAlarm(cat)
    local _, u = alarms.counts(nil, cat)
    return u > 0
  end

  local badges = {
    energy  = totalC > 0 and ("%d%%"):format(math.floor(totalE / totalC * 100)) or nil,
    kinetic = maxSu and ("%d%%"):format(math.floor(maxSu)) or nil,
    fluid   = nFluids > 0 and nFluids or nil,
    items   = itemTypes > 0 and app.fmtNum(itemTypes) or nil,
    trains  = stations > 0 and stations or nil,
  }

  local entries = {
    { label = "ALARMY", view = "alarms", badge = active > 0 and active or nil, alarm = unacked > 0 },
    { label = "PRZEGLAD", view = "overview", badge = ("%d/%d"):format(online, #names),
      alarm = catAlarm("sensor") },
  }
  for _, c in ipairs(sections.CATEGORIES) do
    entries[#entries + 1] = { label = c.label, view = c.view, badge = badges[c.view],
                              alarm = c.cat and catAlarm(c.cat) or false }
  end

  local bottom = {
    { label = "TEST SYRENY", bg = colors.lightGray, fg = colors.black,
      action = function() alarms.sound(true) end },
    now() < app.updateArmed
      and { label = "PEWNE?", bg = colors.orange, fg = colors.black, action = pressUpdate }
      or  { label = "UPDATE", bg = colors.blue, fg = colors.white, action = pressUpdate },
  }
  ui.sidebar(entries, bottom)
end

---------------------------------------------------------------------------
-- PRZEGLAD: podsumowanie zakladu i karty grup

local function groupSummary(g)
  local s, parts = g.sum, {}
  if s.energyCap > 0 then parts[#parts + 1] = ("FE %d%%"):format(math.floor(s.energy / s.energyCap * 100)) end
  local maxSu
  for _, st in ipairs(s.stress) do
    if st.capacity > 0 then maxSu = math.max(maxSu or 0, st.stress / st.capacity * 100) end
  end
  if maxSu then parts[#parts + 1] = ("SU %d%%"):format(math.floor(maxSu)) end
  if s.fluidList[1] then
    local f = s.fluidList[1]
    local cap = config.get(g.label, "cap:fluid:" .. f.name, 0)
    parts[#parts + 1] = app.shortName(f.name) .. " " .. (cap > 0
      and ("%d%%"):format(math.floor(f.amount / 1000 / cap * 100))
      or (app.fmtNum(f.amount / 1000) .. "B"))
  end
  if s.tanks > 0 and not s.fluidList[1] then parts[#parts + 1] = s.tanks .. " zb. pustych" end
  if #s.speed > 0 then parts[#parts + 1] = ("%d RPM"):format(s.speed[1].speed) end
  if s.itemSources > 0 then parts[#parts + 1] = #s.itemList .. " poz." end
  if #s.stations > 0 then parts[#parts + 1] = #s.stations .. " stacji" end
  if #s.signals > 0 then parts[#parts + 1] = #s.signals .. " sygn." end
  if #parts == 0 then
    if #s.stress > 0 then return "SU: siec stoi (0 SU)" end
    return "nic nie wykryto - na czujniku: sensor test"
  end
  local n = 0
  for _ in pairs(g.members) do n = n + 1 end
  return (n > 1 and (n .. " czujn. | ") or "") .. table.concat(parts, " | ")
end

local function drawOverview()
  ui.header("PRZEGLAD ZAKLADU")
  local names = data.groupNames()
  local rows = {}

  -- caly prad zakladu
  local totalE, totalC, totalRate = 0, 0, 0
  for _, label in ipairs(names) do
    local g = data.groups[label]
    if app.isOnline(g) then
      totalE, totalC = totalE + g.sum.energy, totalC + g.sum.energyCap
      totalRate = totalRate + data.energyRate(g)
    end
  end
  if totalC > 0 then
    rows[#rows + 1] = { text = "PRAD RAZEM", fg = colors.black, bg = colors.lightGray }
    rows[#rows + 1] = { bar = totalE / totalC, barCol = colors.yellow }
    local eta, etaCol = app.etaText(totalRate * 1200, totalE, totalC)
    rows[#rows + 1] = { text = eta or (app.fmtFE(totalE) .. " / " .. app.fmtFE(totalC)),
                        fg = eta and etaCol or colors.white,
                        right = (totalRate > 0 and "+" or "") .. app.fmtFE(totalRate) .. "/t",
                        rfg = totalRate < 0 and colors.red or colors.lime,
                        action = function() app.go("energy") end }
  end

  rows[#rows + 1] = { text = ("GRUPY (%d)"):format(#names), fg = colors.black, bg = colors.lightGray }
  for _, label in ipairs(names) do
    local g = data.groups[label]
    local status, scol = sections.groupStatus(label, g)
    local open = function() app.selGroup = label; app.go("group") end
    rows[#rows + 1] = { text = label, fg = colors.white, right = status, rfg = scol, action = open }
    rows[#rows + 1] = { text = " " .. (app.isOnline(g) and groupSummary(g) or "brak polaczenia"),
                        fg = colors.lightGray, action = open }
  end
  if #names == 0 then
    rows[#rows + 1] = { text = "Brak czujnikow. Na komputerze przy maszynach:", fg = colors.lightGray }
    rows[#rows + 1] = { text = "sensor install  (nazwa grupy = label)", fg = colors.lightGray }
  end

  local over = ui.drawRows(rows, 2, ui.h - 1, "overview")
  ui.footer("Dotknij grupy = szczegoly")
  if over then ui.scrollButtons("overview", ui.h - 2) end
end

---------------------------------------------------------------------------
-- Kategoria: ta sama sekcja ze wszystkich grup

local function drawCategory(cat)
  ui.header(cat.label .. " - wszystkie grupy")
  local rows = {}
  local any = false
  for _, label in ipairs(data.groupNames()) do
    local g = data.groups[label]
    if app.isOnline(g) then
      local part = {}
      if cat.build(label, g, part, false, 8) then
        sections.groupHeader(rows, label, g)
        for _, r in ipairs(part) do rows[#rows + 1] = r end
        any = true
      end
    end
  end
  if not any then
    rows[#rows + 1] = { text = "Zadna grupa nie ma tu nic.", fg = colors.lightGray }
    rows[#rows + 1] = { text = "Na czujniku: sensor test", fg = colors.lightGray }
  end
  local key = "cat:" .. cat.view
  local over = ui.drawRows(rows, 2, ui.h - 1, key)
  ui.footer("Grupa = szczegoly | pozycja = wykres i alarm")
  if over then ui.scrollButtons(key, ui.h - 2) end
end

---------------------------------------------------------------------------
-- Grupa: wszystkie kategorie jednej grupy

local function drawGroup()
  local label = app.selGroup
  local g = label and data.groups[label]
  if not g then app.view = "overview"; return drawOverview() end
  ui.header(label, function() app.go("overview") end)

  local rows = {}
  local n = 0
  for _ in pairs(g.members) do n = n + 1 end
  if n > 1 or not app.isOnline(g) then sections.members(label, g, rows) end
  local any = false
  for _, c in ipairs(sections.CATEGORIES) do
    if c.build(label, g, rows, true) then any = true end
  end
  if not any and app.isOnline(g) then
    rows[#rows + 1] = { text = "Czujnik nic nie wykrywa.", fg = colors.lightGray }
    rows[#rows + 1] = { text = "Na jego komputerze: sensor test", fg = colors.lightGray }
  end

  local key = "group:" .. label
  local over = ui.drawRows(rows, 2, ui.h - 1, key)
  ui.footer("Dotknij pozycji = wykres i alarm")
  if over then ui.scrollButtons(key, ui.h - 2) end
end

---------------------------------------------------------------------------
-- Pozycja: wykres historii + prog alarmu (+ pojemnosc dla plynow)

local chartRange = "short"   -- "short" = 10 min, "long" = 2 h

local function seriesFmt(key, v)
  if key == "energy" or key:sub(1, 3) == "su:" then return ("%d%%"):format(math.floor(v + 0.5)) end
  if key:sub(1, 4) == "rpm:" then return ("%d RPM"):format(math.floor(v + 0.5)) end
  if key:sub(1, 6) == "fluid:" then return ("%.1f B"):format(v) end
  return app.fmtNum(v)
end

local function seriesColor(key)
  if key == "energy" then return colors.yellow end
  if key:sub(1, 3) == "su:" then return colors.lime end
  if key:sub(1, 4) == "rpm:" then return colors.lightBlue end
  if key:sub(1, 6) == "fluid:" then return key:find("lava") and colors.orange or colors.cyan end
  return colors.magenta
end

-- Sciska serie do szerokosci wykresu (srednie z kolejnych przedzialow)
local function resample(series, cw)
  if #series <= cw then return series end
  local out, step = {}, #series / cw
  for i = 1, cw do
    local a, b = math.floor((i - 1) * step) + 1, math.floor(i * step)
    local sum = 0
    for j = a, b do sum = sum + series[j] end
    out[i] = sum / (b - a + 1)
  end
  return out
end

-- Wykres slupkowy w obszarze tresci; prog = czerwona linia.
-- full > 0 (znana pojemnosc): gora wykresu = pelny zbiornik. Zwraca skale.
local function drawChart(x0, y0, cw, ch, series, thr, isMax, col, full)
  series = resample(series, cw)
  local n = #series
  local peak = (thr and thr > 0) and thr or 0
  for i = 1, n do peak = math.max(peak, series[i]) end
  if peak <= 0 then peak = 1 end
  local maxV, label = peak * 1.1, peak
  if full and full > 0 and peak <= full then maxV, label = full, full end

  local heights = {}
  for i = 1, n do
    local v = series[i]
    local x = x0 + cw - n + i - 1
    local bad = thr and thr > 0 and ((isMax and v >= thr) or (not isMax and v < thr))
    local bh = math.floor(clamp(v / maxV, 0, 1) * ch + 0.5)
    heights[x] = bh
    for r = 0, bh - 1 do ui.cput(x, y0 + ch - 1 - r, " ", nil, bad and colors.red or col) end
  end
  if thr and thr > 0 then
    local rThr = math.floor(clamp(thr / maxV, 0, 1) * ch + 0.5)
    local ty = clamp(y0 + ch - rThr, y0, y0 + ch - 1)
    for x = x0, x0 + cw - 1 do
      if ty < y0 + ch - (heights[x] or 0) then ui.cput(x, ty, "-", colors.red, colors.black) end
    end
  end
  return label
end

local function drawPoint()
  local t = app.cfgTarget
  if not t then app.view = "overview"; return drawOverview() end
  local g = data.groups[t.group]
  local series = g and g.series and g.series[t.key]
  local thr = config.get(t.group, t.key, t.default)
  local isMax = t.key:sub(1, 3) == "su:"
  local col = seriesColor(t.key)
  local cw, h = ui.cw, ui.h
  local cap = t.capKey and config.get(t.group, t.capKey, 0) or 0

  ui.header(t.title .. " - " .. t.group, function() app.view = app.prevView end)

  -- wartosc biezaca (+ % wypelnienia) i zakres wykresu
  if series and series.last then
    local v = series.last
    local bad = thr > 0 and ((isMax and v >= thr) or (not isMax and v < thr))
    local txt = "Teraz: " .. seriesFmt(t.key, v)
    if cap > 0 then txt = txt .. (" (%d%%)"):format(math.floor(v / cap * 100)) end
    ui.cput(2, 2, fit(txt, cw - 17), bad and colors.red or col, colors.black)
  end
  ui.toggle(cw - 14, 2, " 10 MIN ", chartRange == "short", function() chartRange = "short" end)
  ui.toggle(cw - 5, 2, " 2 H ", chartRange == "long", function() chartRange = "long" end)

  -- prognoza i prog
  local eta, etaCol
  if t.key == "energy" and g then
    eta, etaCol = app.etaText(data.energyRate(g) * 1200, g.sum.energy, g.sum.energyCap)
  elseif cap > 0 and series and series.last then
    local r = data.seriesRate(series)
    eta, etaCol = app.etaText(r, series.last, cap)
    if eta then eta = eta .. (" (%+.1f B/min)"):format(r) end
  end
  if eta then ui.cput(2, 3, fit(eta, cw - 18), etaCol, colors.black) end
  if thr > 0 then
    local tt = (isMax and "prog od " or "prog < ") .. seriesFmt(t.key, thr)
    ui.cput(cw - #tt + 1, 3, tt, colors.red, colors.black)
  end

  -- wykres (przy plynach nizszy - pod nim pojemnosc)
  local top, bottom = 5, t.capKey and (h - 10) or (h - 7)
  local values = series and (chartRange == "short" and series.short or series.long) or {}
  if #values < 2 or bottom - top < 1 then
    ui.cput(2, top + 1, chartRange == "short" and "Zbieram dane... (probka co 5 s)"
                                              or "Zbieram dane... (probka co minute)",
            colors.lightGray, colors.black)
  else
    local maxV = drawChart(2, top, cw - 1, bottom - top + 1, values, thr, isMax, col, cap)
    ui.cput(2, 4, "maks " .. seriesFmt(t.key, maxV), colors.lightGray, colors.black)
    local span = chartRange == "short" and (#values * app.REFRESH / 60) or #values
    local left = span >= 60 and ("-%.1f h"):format(span / 60)
                 or ("-%d min"):format(math.max(1, math.floor(span + 0.5)))
    ui.cput(2, bottom + 1, left, colors.gray, colors.black)
    ui.cput(cw - 4, bottom + 1, "teraz", colors.gray, colors.black)
  end

  -- pojemnosc zbiornikow z tym plynem (do % i prognozy)
  if t.capKey then
    ui.cput(2, h - 8, fit("Pojemnosc (wiadra)" .. (cap > 0 and "" or " - nieznana")
                          .. ", Create: 8 B/blok", cw - 2), colors.lightGray, colors.black)
    ui.numberRow(h - 7, "Poj.", cap, function(v) config.set(t.group, t.capKey, clamp(v, 0, 99999)) end, 64, 8,
                 { title = "pojemnosc " .. t.title, unit = "B" })
  end

  -- prog alarmu
  ui.cput(2, h - 5, fit(t.desc .. (thr > 0 and "" or " (wyl.)"), cw - 2),
          thr > 0 and colors.white or colors.gray, colors.black)
  ui.numberRow(h - 4, t.unit, thr, function(v) config.set(t.group, t.key, clamp(v, 0, t.max)) end, t.big, t.small,
               { title = "prog " .. t.title, unit = t.unit })
  ui.cbutton(2, h - 3, " WYLACZ ", colors.gray, function() config.set(t.group, t.key, 0) end)
  ui.cbutton(11, h - 3, " DOMYSLNE ", colors.gray, function() config.set(t.group, t.key, nil) end)

  ui.footer("Dotknij liczby = wpisz z klawiatury")
end

---------------------------------------------------------------------------
-- ALARMY: lista (dotkniecie = potwierdz) i dziennik zdarzen

local function drawAlarms()
  ui.header("ALARMY")
  local rows = {}
  local list = alarms.sorted()
  for _, a in ipairs(list) do
    local fg, bg = colors.yellow, colors.black          -- ustapil, niepotwierdzony
    if a.active and not a.acked then
      fg = colors.red
      if app.blink and a.crit then fg, bg = colors.white, colors.red end
    elseif a.active then
      fg = colors.orange
    end
    rows[#rows + 1] = { text = ("%s %s%s%s"):format(app.hhmm(a.since), a.crit and "!" or " ",
                                                    a.active and "" or "(ok) ", a.text),
                        fg = fg, bg = bg, action = function() alarms.ack(a.key) end }
  end
  if #list == 0 then rows[#rows + 1] = { text = "Brak alarmow - wszystko OK", fg = colors.lime } end

  local _, unacked = alarms.counts()
  if unacked > 0 then
    rows[#rows + 1] = { text = "", fg = colors.black }
    rows[#rows + 1] = { text = "POTWIERDZ WSZYSTKIE", fg = colors.white, bg = colors.green,
                        action = alarms.ackAll }
  end

  rows[#rows + 1] = { text = "", fg = colors.black }
  rows[#rows + 1] = { text = "ZDARZENIA", fg = colors.black, bg = colors.lightGray }
  for _, ev in ipairs(alarms.log) do
    rows[#rows + 1] = { text = app.hhmm(ev.t) .. " " .. ev.text, fg = ev.color }
  end

  local over = ui.drawRows(rows, 2, ui.h - 1, "alarms")
  ui.footer(("Dotknij = potwierdz | ntfy: %s | syrena: %s"):format(
    alarms.ntfyOn and "ON" or "off",
    alarms.speakerCount > 0 and (alarms.speakerCount .. "x " .. alarms.sirenType) or "brak"))
  if over then ui.scrollButtons("alarms", ui.h - 2) end
end

---------------------------------------------------------------------------
-- Ekran aktualizacji (bez sidebara)

local function drawUpdating()
  local w, h = ui.w, ui.h
  ui.put(1, 1, (" "):rep(w), nil, colors.orange)
  ui.put(2, 1, "AKTUALIZACJA", colors.black, colors.orange)
  ui.put(2, 3, "Wyslano UPDATE do czujnikow", colors.white, colors.black)
  local y = 5
  for _, r in ipairs(app.updating.replies) do
    if y > h - 2 then break end
    ui.put(2, y, fit(("#%d %s"):format(r.id, r.label or ""), w - 15), colors.white, colors.black)
    ui.put(w - 12, y, r.busy and "zajety-pomin" or "aktualizuje",
           r.busy and colors.orange or colors.lime, colors.black)
    y = y + 1
  end
  ui.put(2, h - 1, "Zaraz aktualizacja i restart SCADA", colors.yellow, colors.black)
end

---------------------------------------------------------------------------

function views.draw()
  local okSize = ui.begin()
  if not okSize then
    ui.put(1, 1, "Monitor za maly", colors.red, colors.black)
    ui.put(1, 2, ("min. %dx%d znakow"):format(ui.MIN_W, ui.MIN_H), colors.red, colors.black)
    ui.put(1, 3, "(rozbuduj monitor albo", colors.lightGray, colors.black)
    ui.put(1, 4, " set scada.scale 0.5)", colors.lightGray, colors.black)
    return
  end
  if app.updating then return drawUpdating() end

  drawSidebar()
  if app.keypad then return ui.drawKeypad() end
  local v = app.view
  if v == "alarms" then drawAlarms()
  elseif v == "group" then drawGroup()
  elseif v == "point" then drawPoint()
  else
    for _, c in ipairs(sections.CATEGORIES) do
      if c.view == v then return drawCategory(c) end
    end
    app.view = "overview"
    drawOverview()
  end
end

return views

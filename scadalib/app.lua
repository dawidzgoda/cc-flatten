-- scadalib/app.lua - wspolny stan, stale i narzedzia SCADA
-- Wszystkie moduly dostaja ten sam obiekt (require trzyma jedna kopie).

local app = {}

app.SENSOR_PROTOCOL = "scada_sensor"  -- czujniki (sensor)
app.ALARM_PROTOCOL  = "scada_alarm"   -- alarmy -> pockety (pscada)
app.ADMIN_PROTOCOL  = "scada_admin"   -- zdalny UPDATE czujnikow
app.REFRESH  = 5       -- sekundy miedzy odswiezeniami
app.OFFLINE  = 15      -- po tylu sekundach bez danych: OFFLINE
app.TERM_ROW = 11      -- wiersz statusu na ekranie komputera (1-8 zajmuje sensor)
app.DEMO     = false   -- ustawia scada.lua

-- Stan interfejsu
app.view      = "overview"   -- overview / energy / kinetic / fluid / items / trains /
                             -- alarms / group / point
app.prevView  = "overview"   -- dokad wraca WSTECZ z wykresu
app.selGroup  = nil          -- grupa w widoku "group"
app.cfgTarget = nil          -- pozycja w widoku "point"
app.scroll    = {}           -- klucz listy -> przesuniecie
app.message   = nil          -- { text, color, time } w stopce
app.blink     = false        -- miganie niepotwierdzonych alarmow

---------------------------------------------------------------------------
-- Narzedzia

function app.now() return os.epoch("utc") end
function app.clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
function app.isOnline(e) return e ~= nil and (app.now() - e.last) < app.OFFLINE * 1000 end

function app.setMsg(text, color)
  app.message = { text = text, color = color or colors.white, time = app.now() }
end

-- Przejscie do widoku; "point" pamieta, skad przyszlismy
function app.go(view)
  if view == "point" and app.view ~= "point" then app.prevView = app.view end
  app.view = view
end

function app.shortName(n) return (tostring(n):match(":(.+)$") or tostring(n)) end

function app.fmtNum(n)
  if math.abs(n) >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if math.abs(n) >= 1e4 then return ("%.1fk"):format(n / 1e3) end
  return tostring(math.floor(n))
end

function app.fmtFE(n)
  local units = { "", "k", "M", "G", "T" }
  local i = 1
  while math.abs(n) >= 1000 and i < #units do n = n / 1000; i = i + 1 end
  return ("%.1f %sFE"):format(n, units[i])
end

function app.buckets(mB) return ("%.1f B"):format(mB / 1000) end
function app.hhmm(ms) return os.date("%H:%M", math.floor(ms / 1000)) end

function app.fmtMins(m)
  if m >= 600 then return ">10 h" end
  if m >= 60 then return ("%.1f h"):format(m / 60) end
  return ("%d min"):format(math.max(1, math.floor(m + 0.5)))
end

-- Prognoza: za ile pelne/puste. rate i value w tych samych jednostkach
-- (rate na minute); cap 0/nil = nieznana pojemnosc.
function app.etaText(rate, value, cap)
  if rate > 0 and cap and cap > 0 then
    if value >= cap then return "pelne", colors.lime end
    return "pelne za " .. app.fmtMins((cap - value) / rate), colors.lime
  elseif rate < 0 then
    if value <= 0 then return "puste", colors.red end
    return "puste za " .. app.fmtMins(value / -rate), colors.orange
  end
  return nil
end

-- Zapis/odczyt tabeli (zwarty format, jesli wersja CC: Tweaked go obsluguje)
function app.writeTable(path, data)
  local ok, text = pcall(textutils.serialize, data, { compact = true })
  if not ok then text = textutils.serialize(data) end
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

function app.readTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  return type(data) == "table" and data or nil
end

return app

-- scadalib/alarms.lua - alarmy, syrena, powiadomienia ntfy, stan na dysku
--
-- Stany: AKTYWNY niepotwierdzony (czerwony, miga), AKTYWNY potwierdzony
-- (pomaranczowy), USTAPIL niepotwierdzony (zolty). Potwierdzony i ustapiony
-- znika z listy. Kazda zmiana trafia do dziennika zdarzen.
--
-- Kategoria alarmu (cat) = pozycja w sidebarze: energy, kinetic, fluid,
-- items, sensor (czujnik offline).

local app    = require("scadalib.app")
local config = require("scadalib.config")
local data   = require("scadalib.data")

local alarms = {}

local now, isOnline, shortName = app.now, app.isOnline, app.shortName

alarms.list    = {}   -- key -> { key, text, crit, group, cat, since, active, acked }
alarms.latched = {}   -- key -> warunek zdarzeniowy, trwa do potwierdzenia
alarms.log     = {}   -- { t, text, color }, najnowsze na poczatku

-- Push na prawdziwy telefon przez ntfy.sh:  set scada.ntfy <tajny_temat>
local NTFY_TOPIC = settings.get("scada.ntfy")
if NTFY_TOPIC == "" then NTFY_TOPIC = nil end
alarms.ntfyOn = NTFY_TOPIC ~= nil

---------------------------------------------------------------------------
-- Syrena: wszystkie speakery podlaczone do komputera (mozna rozstawic kilka
-- po bazie przez wired modemy). Rodzaj dzwieku alarmu krytycznego:
--   set scada.siren bell    - dzwon + syrena dwutonowa (domyslnie)
--   set scada.siren notes   - sama syrena dwutonowa
--   set scada.siren horn    - rog rajdu (bardzo glosny, slychac daleko)
--   set scada.siren_volume 3   (0.5 - 3)

local speakers  = { peripheral.find("speaker") }
local SIREN     = settings.get("scada.siren", "bell")
local SIREN_VOL = app.clamp(tonumber(settings.get("scada.siren_volume", 3)) or 3, 0.5, 3)
alarms.speakerCount, alarms.sirenType = #speakers, SIREN

local function forSpeakers(fn)
  for _, s in ipairs(speakers) do pcall(fn, s) end
end

-- Odtwarza dzwiek (blokuje ok. 2 s - uruchamiane w osobnym watku)
function alarms.playSiren(crit)
  if #speakers == 0 then return end
  if not crit then
    -- ostrzezenie: dwa krotkie, wysokie sygnaly
    for _ = 1, 2 do
      forSpeakers(function(s) s.playNote("pling", SIREN_VOL, 18) end)
      sleep(0.15)
    end
    return
  end
  if SIREN == "horn" then
    forSpeakers(function(s) s.playSound("minecraft:event.raid.horn", SIREN_VOL) end)
    return
  end
  if SIREN ~= "notes" then
    forSpeakers(function(s) s.playSound("minecraft:block.bell.use", SIREN_VOL, 1) end)
    sleep(0.1)   -- w tym samym ticku co playSound speaker nie zagra nut
  end
  -- syrena dwutonowa: wysoki / niski, 4 razy
  for _ = 1, 4 do
    forSpeakers(function(s) s.playNote("bit", SIREN_VOL, 20); s.playNote("bell", SIREN_VOL, 20) end)
    sleep(0.2)
    forSpeakers(function(s) s.playNote("bit", SIREN_VOL, 10); s.playNote("bell", SIREN_VOL, 10) end)
    sleep(0.2)
  end
end

-- Zlecenie dzwieku dla watku syreny (scada.lua)
function alarms.sound(crit) os.queueEvent("scada_siren", crit and "crit" or "warn") end

---------------------------------------------------------------------------

function alarms.logEvent(text, color)
  table.insert(alarms.log, 1, { t = now(), text = text, color = color })
  if #alarms.log > 30 then table.remove(alarms.log) end
end

local function notifyPhone(a)
  if not NTFY_TOPIC or not http or app.DEMO then return end
  pcall(http.post, "https://ntfy.sh/" .. NTFY_TOPIC, a.text, {
    Title = a.crit and "SCADA ALARM" or "SCADA ostrzezenie",
    Priority = a.crit and "high" or "default",
    Tags = a.crit and "rotating_light" or "warning",
  })
end

-- Wszystkie warunki alarmowe w tej chwili: key -> { text, crit, group, cat }
local function conditions()
  local c = {}
  local function add(key, text, crit, group, cat)
    c[key] = { text = text, crit = crit, group = group, cat = cat }
  end

  for label, g in pairs(data.groups) do
    local tag, s = "[" .. label .. "] ", g.sum
    -- kazdy czujnik grupy osobno (grupa moze miec kilka komputerow)
    for mid, m in pairs(g.members) do
      if not isOnline(m) then
        add("g_off_" .. label .. "#" .. mid, tag .. "czujnik #" .. mid .. " offline", false, label, "sensor")
      end
    end
    if isOnline(g) then
      if s.energyCap > 0 then
        local pct, min = s.energy / s.energyCap * 100, config.get(label, "energy", 20)
        if min > 0 and pct < min then
          add("g_en_" .. label, tag .. ("malo pradu: %d%%"):format(math.floor(pct)), true, label, "energy")
        end
      end
      for _, st in ipairs(s.stress) do
        if st.capacity > 0 then
          local pct, max = st.stress / st.capacity * 100, config.get(label, "su:" .. st.id, 90)
          if st.stress > st.capacity then
            add("g_su_" .. label .. st.id, tag .. "PRZECIAZENIE sieci " .. shortName(st.id), true, label, "kinetic")
          elseif max > 0 and pct >= max then
            add("g_su_" .. label .. st.id, tag .. ("obciazenie %d%% (%s)"):format(math.floor(pct), shortName(st.id)),
                false, label, "kinetic")
          end
        end
      end
      for _, sp in ipairs(s.speed) do
        local min = config.get(label, "rpm:" .. sp.id, 0)
        if min > 0 and math.abs(sp.speed) < min then
          add("g_rpm_" .. label .. sp.id, tag .. ("wolno: %d RPM (%s)"):format(sp.speed, shortName(sp.id)),
              false, label, "kinetic")
        end
      end
      for name, min in pairs(config.watched(label, "fluid:")) do
        local amount = s.fluids[name] and s.fluids[name].amount or 0
        if amount < min * 1000 then
          add("g_fl_" .. label .. name, tag .. ("malo: %s %s"):format(shortName(name), app.buckets(amount)),
              true, label, "fluid")
        end
      end
      if s.itemSources > 0 then
        for name, min in pairs(config.watched(label, "item:")) do
          local count = s.items[name] or 0
          if count < min then
            add("g_it_" .. label .. name, tag .. ("malo: %s %d/%d"):format(shortName(name), count, min),
                false, label, "items")
          end
        end
      end
    end
  end

  for key, l in pairs(alarms.latched) do c[key] = l end
  return c
end

function alarms.sorted()
  local list = {}
  for _, a in pairs(alarms.list) do list[#list + 1] = a end
  local function rank(a) return (a.active and 0 or 2) + (a.acked and 1 or 0) end
  table.sort(list, function(x, y)
    if rank(x) ~= rank(y) then return rank(x) < rank(y) end
    if x.crit ~= y.crit then return x.crit end
    return x.since > y.since
  end)
  return list
end

-- Liczniki: active, unacked, critUnacked; filtr po grupie i/lub kategorii
function alarms.counts(group, cat)
  local active, unacked, critUnacked = 0, 0, false
  for _, a in pairs(alarms.list) do
    if (group == nil or a.group == group) and (cat == nil or a.cat == cat) then
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
function alarms.sync()
  if app.DEMO then return end
  local list = {}
  for _, a in ipairs(alarms.sorted()) do
    list[#list + 1] = { key = a.key, text = a.text, crit = a.crit, group = a.group,
                        since = a.since, active = a.active, acked = a.acked }
  end
  rednet.broadcast({ cmd = "alarms", list = list }, app.ALARM_PROTOCOL)
end

-- Po starcie czekamy, az czujniki sie odezwa; inaczej odtworzone z dysku
-- alarmy "ustapilyby" na chwile i wrocily jako nowe (z ntfy).
local STARTUP_GRACE = 20000
local startTime = now()

function alarms.evaluate()
  if not app.DEMO and now() - startTime < STARTUP_GRACE then
    alarms.sync()
    return
  end
  local cond = conditions()
  local newCrit, newWarn = false, false

  for key, cnd in pairs(cond) do
    local a = alarms.list[key]
    if not a or not a.active then
      a = { key = key, text = cnd.text, crit = cnd.crit, group = cnd.group, cat = cnd.cat,
            since = now(), active = true, acked = false }
      alarms.list[key] = a
      alarms.logEvent((cnd.crit and "ALARM: " or "UWAGA: ") .. cnd.text,
                      cnd.crit and colors.red or colors.orange)
      if cnd.crit then newCrit = true else newWarn = true end
      notifyPhone(a)
    else
      a.text, a.crit, a.cat = cnd.text, cnd.crit, cnd.cat
    end
  end

  for key, a in pairs(alarms.list) do
    if a.active and not cond[key] then
      a.active = false
      alarms.logEvent("OK: " .. a.text, colors.lime)
      if a.acked then alarms.list[key] = nil end
    end
  end

  -- syrena: co cykl, dopoki jest niepotwierdzony alarm krytyczny;
  -- nowe ostrzezenie (bez krytycznych) - krotki sygnal
  local _, _, critUnacked = alarms.counts()
  if critUnacked or newCrit then alarms.sound(true)
  elseif newWarn then alarms.sound(false) end

  alarms.sync()
end

function alarms.ack(key)
  local a = alarms.list[key]
  if not a or a.acked then return end
  a.acked = true
  alarms.latched[key] = nil
  alarms.logEvent("Potwierdzono: " .. a.text, colors.lightGray)
  if not a.active then alarms.list[key] = nil end
end

function alarms.ackAll()
  for key in pairs(alarms.list) do alarms.ack(key) end
end

---------------------------------------------------------------------------
-- Stan na dysku: alarmy (z potwierdzeniami) i dziennik zdarzen.

local STATE_FILE = "scada_state"

function alarms.saveState()
  if app.DEMO then return end
  app.writeTable(STATE_FILE, { alarms = alarms.list, latched = alarms.latched, log = alarms.log })
end

function alarms.loadState()
  if app.DEMO then return end
  local d = app.readTable(STATE_FILE)
  if not d then return end
  for k, v in pairs(d.alarms or {}) do
    -- alarmy zolwi ze starej wersji pomijamy (zolwie nie sa juz w SCADA)
    if not tostring(k):match("^t_") then alarms.list[k] = v end
  end
  for k, v in pairs(d.latched or {}) do
    if not tostring(k):match("^t_") then alarms.latched[k] = v end
  end
  for _, e in ipairs(d.log or {}) do alarms.log[#alarms.log + 1] = e end
end

return alarms

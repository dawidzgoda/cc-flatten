-- scada.lua - panel stanu zakladu na advanced monitorze
--
-- Uzycie:  scada           - normalna praca
--          scada demo      - dane testowe (bez czujnikow)
--          scada install   - autostart
--
-- Wymaga: komputer + advanced monitor (im wiekszy, tym lepiej; min. ok.
--         4x3 bloki) + wireless/ender modem. Opcjonalnie speakery (syrena).
--
-- Kod jest podzielony na moduly w folderze scadalib/:
--   app      - wspolny stan, stale, formatowanie, zapis plikow
--   config   - progi alarmow i pojemnosci (settings)
--   data     - grupy z czujnikow, historia do wykresow, dane demo
--   alarms   - alarmy, syrena, ntfy, stan na dysku
--   ui       - monitor, sidebar, przyciski, listy, paski
--   sections - sekcje kategorii (PRAD, KINETYKA, PLYNY, MAGAZYN, POCIAGI)
--   views    - ekrany (przeglad, kategorie, grupa, wykres, alarmy)
--
-- Zolwie sa niezalezne od SCADA (remote na pockecie, update recznie).

local arg1 = ({ ... })[1]

if arg1 == "install" then
  -- stary update nie pobieral 'autostart' - dociagnij go w razie potrzeby
  if not fs.exists("autostart") and not fs.exists("autostart.lua") then shell.run("update") end
  shell.run("autostart", "add", "scada")
  return
end

if not fs.exists("scadalib/app.lua") then
  print("Brak modulow scadalib/ - pobieram (update)...")
  shell.run("update")
end

local app = require("scadalib.app")
app.DEMO = arg1 == "demo"

local data   = require("scadalib.data")
local alarms = require("scadalib.alarms")
local ui     = require("scadalib.ui")
local views  = require("scadalib.views")

ui.init()

if not app.DEMO then
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then error("Brak wireless/ender modemu!") end
  rednet.open(peripheral.getName(modem))
  data.loadHistory()
  alarms.loadState()
end

local draw = views.draw

---------------------------------------------------------------------------
-- Watki

-- Odbior danych z czujnikow, odpowiedzi na UPDATE, potwierdzenia z pocketow
local function receiver()
  while true do
    local id, msg, proto = rednet.receive()
    if type(msg) ~= "table" then
      -- nic
    elseif proto == app.SENSOR_PROTOCOL and msg.cmd == "data" then
      if not app.DEMO then data.receiveSensor(id, msg) end
    elseif proto == app.ADMIN_PROTOCOL and (msg.cmd == "updating" or msg.cmd == "busy") then
      if app.updating then
        local r = app.updating.replies
        r[#r + 1] = { id = id, label = msg.label, busy = msg.cmd == "busy" }
        draw()
      end
    elseif proto == app.ALARM_PROTOCOL and msg.cmd == "ack" then
      if msg.all then alarms.ackAll() elseif msg.key then alarms.ack(msg.key) end
      alarms.sync()
      pcall(alarms.saveState)
      draw()
    end
  end
end

-- Co REFRESH sekund: dane, alarmy, ekran, zapis na dysk
local function ticker()
  local lastHist, lastState = app.now(), app.now()
  while true do
    if app.DEMO then data.tickDemo() end
    data.refreshGroups()
    alarms.evaluate()
    draw()
    if not app.DEMO then
      -- historia wykresow co minute, stan alarmow co 30 s (przetrwa restart i UPDATE)
      if app.now() - lastHist > 60000 then lastHist = app.now(); pcall(data.saveHistory) end
      if app.now() - lastState > 30000 then lastState = app.now(); pcall(alarms.saveState) end
    end
    sleep(app.REFRESH)
  end
end

-- Miganie niepotwierdzonych alarmow (odswieza tylko gdy sa takie alarmy)
local function blinker()
  while true do
    sleep(1)
    app.blink = not app.blink
    local _, unacked = alarms.counts()
    if unacked > 0 then draw() end
  end
end

-- Syrena w osobnym watku, zeby dzwiek (ok. 2 s) nie blokowal ekranu.
-- Zlecenia przychodzace w trakcie grania sa pomijane (sleep je odrzuca).
local function siren()
  while true do
    local _, kind = os.pullEvent("scada_siren")
    alarms.playSiren(kind == "crit")
  end
end

-- UPDATE: zdalnie czujniki, potem sama SCADA + restart komputera
local function runUpdate()
  app.updating = { replies = {} }
  if not app.DEMO then rednet.broadcast({ cmd = "update" }, app.ADMIN_PROTOCOL) end
  draw()
  sleep(3) -- odpowiedzi zbiera receiver i dopisuje na ekranie
  if app.DEMO then
    app.updating = nil
    app.setMsg("Demo: aktualizacja pominieta", colors.yellow)
    draw()
    return
  end
  pcall(data.saveHistory)
  pcall(alarms.saveState)
  term.setCursorPos(1, app.TERM_ROW + 1)
  shell.run("update")
  os.reboot()
end

-- Dotyk monitora
local function touch()
  while true do
    local ev, _, x, y = os.pullEvent()
    if ev == "monitor_touch" then
      ui.touch(x, y)
      if app.view == "alarms" then alarms.sync() end   -- potwierdzenia -> pockety
      pcall(alarms.saveState)
      draw()
      if app.updateRequested then
        app.updateRequested = false
        runUpdate()
      end
    elseif ev == "monitor_resize" then
      ui.pickScale()   -- monitor rozbudowany/zmniejszony - dobierz tekst od nowa
      draw()
    end
  end
end

---------------------------------------------------------------------------

-- Bez term.clear(): na tym samym komputerze moze dzialac sensor (wiersze 1-8)
term.setCursorPos(1, app.TERM_ROW); term.clearLine()
term.write("SCADA dziala na monitorze. Ctrl+T - wyjscie.")
term.setCursorPos(1, app.TERM_ROW + 1)

if app.DEMO then data.initDemo(); data.tickDemo() end
draw()
parallel.waitForAny(receiver, ticker, touch, blinker, siren)

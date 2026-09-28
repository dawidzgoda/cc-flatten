-- sensor.lua - uniwersalny czujnik dla SCADA
--
-- Uzycie:  sensor           - uruchom czujnik
--          sensor install   - autostart
--          sensor test      - pokaz, co czujnik wykrywa (diagnostyka)
--
-- Sam wykrywa podlaczone urzadzenia (obok komputera albo przez wired modem
-- + kabel) i co INTERVAL sekund wysyla ich stan do SCADA:
--   * PLYNY    - kazdy zbiornik (Create Fluid Tank i inne): wszystkie plyny
--   * PRAD     - magazyny FE (Powah, Thermal, ...): energia i pojemnosc
--   * KINETYKA - Create Stressometer (SU) i Speedometer (RPM)
--   * MAGAZYN  - skrzynie, Create Item Vault, Create Stock Ticker
--   * POCIAGI  - Create Train Station i Train Signal
--
-- Grupa na SCADA = etykieta tego komputera (label set <nazwa>).
-- Wymaga wireless/ender modemu.

local SENSOR_PROTOCOL = "scada_sensor"
local ADMIN_PROTOCOL  = "scada_admin"   -- zdalny UPDATE ze SCADA
local INTERVAL        = 5

local arg1 = ({ ... })[1]

if arg1 == "install" then
  if not fs.exists("autostart") and not fs.exists("autostart.lua") then shell.run("update") end
  shell.run("autostart", "add", "sensor")
  return
end

---------------------------------------------------------------------------
-- Moduly: kazdy dostaje peripheral i dopisuje punkty pomiarowe.
-- Wykrywanie po metodach, nie po typie (nazwy typow roznia sie miedzy
-- wersjami Create, np. "stressometer" / "Create_Stressometer").

local function call(p, m, ...)
  local ok, a, b = pcall(p[m], ...)
  if ok then return a, b end
end

local function scan()
  local points = {}
  local items, itemSources = {}, 0

  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)

    -- PLYNY: tanks() -> { {name, amount}, ... }
    if p.tanks then
      local tanks = call(p, "tanks")
      if type(tanks) == "table" then
        local fluids = {}
        for _, t in pairs(tanks) do
          if t.name and (t.amount or 0) > 0 then
            fluids[#fluids + 1] = { name = t.name, amount = t.amount }
          end
        end
        points[#points + 1] = { kind = "fluid", id = name, fluids = fluids }
      end
    end

    -- PRAD: getEnergy / getEnergyCapacity (energy_storage)
    if p.getEnergy and p.getEnergyCapacity then
      local e, c = call(p, "getEnergy"), call(p, "getEnergyCapacity")
      if tonumber(e) and tonumber(c) and c > 0 then
        points[#points + 1] = { kind = "energy", id = name, energy = e, capacity = c }
      end
    end

    -- KINETYKA: Stressometer / Speedometer
    if p.getStress and p.getStressCapacity then
      local s, c = call(p, "getStress"), call(p, "getStressCapacity")
      if tonumber(s) and tonumber(c) then
        points[#points + 1] = { kind = "stress", id = name, stress = s, capacity = c }
      end
    elseif p.getSpeed then
      local s = call(p, "getSpeed")
      if tonumber(s) then points[#points + 1] = { kind = "speed", id = name, speed = s } end
    end

    -- POCIAGI: Train Station / Train Signal
    if p.getStationName and p.isTrainPresent then
      points[#points + 1] = {
        kind = "station", id = name,
        station = call(p, "getStationName"),
        present = call(p, "isTrainPresent") == true,
        imminent = call(p, "isTrainImminent") == true,
        enroute = call(p, "isTrainEnroute") == true,
        train = call(p, "isTrainPresent") and call(p, "getTrainName") or nil,
      }
    elseif p.getState and p.getSignalType then
      local blocking = call(p, "listBlockingTrainNames")
      points[#points + 1] = {
        kind = "signal", id = name, state = call(p, "getState"),
        trains = type(blocking) == "table" and #blocking or 0,
      }
    end

    -- MAGAZYN: Stock Ticker (stock) albo zwykle inwentarze (list + size)
    if p.stock then
      local st = call(p, "stock")
      if type(st) == "table" then
        itemSources = itemSources + 1
        for _, it in pairs(st) do
          if it.name then items[it.name] = (items[it.name] or 0) + (it.count or 0) end
        end
      end
    elseif p.list and p.size then
      local l = call(p, "list")
      if type(l) == "table" then
        itemSources = itemSources + 1
        for _, it in pairs(l) do
          if it.name then items[it.name] = (items[it.name] or 0) + (it.count or 0) end
        end
      end
    end
  end

  if itemSources > 0 then
    points[#points + 1] = { kind = "items", id = "items", items = items, sources = itemSources }
  end
  return points
end

---------------------------------------------------------------------------
-- Diagnostyka: sensor test

if arg1 == "test" then
  local pts = scan()
  print(("Wykryto %d punktow:"):format(#pts))
  for _, pt in ipairs(pts) do
    local extra = ""
    if pt.kind == "fluid" then
      local parts = {}
      for _, f in ipairs(pt.fluids) do parts[#parts + 1] = ("%s %d mB"):format(f.name, f.amount) end
      extra = #parts > 0 and table.concat(parts, ", ") or "(pusty)"
    elseif pt.kind == "energy" then extra = ("%d / %d FE"):format(pt.energy, pt.capacity)
    elseif pt.kind == "stress" then extra = ("%d / %d SU"):format(pt.stress, pt.capacity)
    elseif pt.kind == "speed" then extra = ("%d RPM"):format(pt.speed)
    elseif pt.kind == "station" then extra = tostring(pt.station) .. (pt.present and " (pociag)" or "")
    elseif pt.kind == "signal" then extra = tostring(pt.state)
    elseif pt.kind == "items" then
      local n = 0
      for _ in pairs(pt.items) do n = n + 1 end
      extra = ("%d rodzajow z %d zrodel"):format(n, pt.sources)
    end
    print(("- %s [%s] %s"):format(pt.id, pt.kind, extra))
  end
  return
end

---------------------------------------------------------------------------

-- Stare autostarty moga uruchamiac lavasensor i energysensor naraz -
-- oba sa teraz aliasami tego programu; wystarczy jedna kopia.
if _G.ccSensorRunning then
  print("sensor juz dziala na tym komputerze.")
  while true do os.pullEvent("__never") end
end
_G.ccSensorRunning = true

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Brak wireless/ender modemu!") end
rednet.open(peripheral.getName(modem))

local label = os.getComputerLabel() or ("Czujnik_" .. os.getComputerID())
local STATUS_ROW = 1   -- wiersze 1-8 (scada na tym samym komputerze pisze od 11)

local function line(row, text)
  term.setCursorPos(1, STATUS_ROW + row - 1); term.clearLine(); term.write(text)
end

-- Czeka INTERVAL sekund, obslugujac zdalny UPDATE ze SCADA
local function waitInterval()
  local timer = os.startTimer(INTERVAL)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then return end
    if ev == "rednet_message" and c == ADMIN_PROTOCOL and type(b) == "table"
       and b.cmd == "update" and not _G.ccUpdating then
      _G.ccUpdating = true
      rednet.send(a, { cmd = "updating", label = label }, ADMIN_PROTOCOL)
      line(8, "Zdalna aktualizacja...")
      shell.run("update")
      os.reboot()
    end
  end
end

line(1, ("Czujnik '%s' (#%d)"):format(label, os.getComputerID()))
line(2, "Wysylam dane do SCADA co " .. INTERVAL .. " s.")

while true do
  local points = scan()
  local msg = { cmd = "data", label = label, points = points }
  rednet.broadcast(msg, SENSOR_PROTOCOL)
  -- SCADA na tym samym komputerze nie slyszy wlasnego modemu - podajemy lokalnie
  os.queueEvent("rednet_message", os.getComputerID(), msg, SENSOR_PROTOCOL)

  local counts = {}
  for _, pt in ipairs(points) do counts[pt.kind] = (counts[pt.kind] or 0) + 1 end
  line(3, ("[%s] punktow: %d"):format(textutils.formatTime(os.time(), true), #points))
  line(4, ("plyny %d  prad %d  SU %d  RPM %d"):format(
    counts.fluid or 0, counts.energy or 0, counts.stress or 0, counts.speed or 0))
  line(5, ("magazyn %d  stacje %d  sygnaly %d"):format(
    counts.items or 0, counts.station or 0, counts.signal or 0))

  waitInterval()
end

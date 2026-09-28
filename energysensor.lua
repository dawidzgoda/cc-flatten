-- energysensor.lua - czujnik pradu (FE): odczytuje magazyny energii
-- (np. Powah Energy Cell) przy tym komputerze i wysyla dane do SCADA.
--
-- Uzycie:  energysensor           - uruchom czujnik
--          energysensor install   - autostart (dziala tez razem z lavasensor)
--
-- Wymaga: Forge/NeoForge, komputer + wireless/ender modem, magazyny FE obok
--         komputera albo podlaczone wired modemem + kablem.
-- Nazwa czujnika na SCADA = etykieta komputera (label set <nazwa>).

local ENERGY_PROTOCOL = "scada_energy"
local INTERVAL        = 5            -- sekundy miedzy wysylkami
local ADMIN_PROTOCOL  = "scada_admin"  -- zdalny UPDATE ze SCADA
local STATUS_ROW      = 6            -- wiersze 6-9 ekranu (lavasensor 1-4, scada 11)

if ({ ... })[1] == "install" then shell.run("autostart", "add", "energysensor"); return end

---------------------------------------------------------------------------

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Brak wireless/ender modemu!") end
rednet.open(peripheral.getName(modem))

-- Kazdy peripheral z getEnergy/getEnergyCapacity (energy_storage w CC: Tweaked)
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

local function fmtFE(n)
  local units = { "", "k", "M", "G", "T" }
  local i = 1
  while math.abs(n) >= 1000 and i < #units do n = n / 1000; i = i + 1 end
  return ("%.1f %sFE"):format(n, units[i])
end

local label = os.getComputerLabel() or ("czujnik_" .. os.getComputerID())

local function line(row, text)
  term.setCursorPos(1, row); term.clearLine(); term.write(text)
end

-- Czeka INTERVAL sekund, obslugujac zdalny UPDATE ze SCADA
local function waitInterval()
  local timer = os.startTimer(INTERVAL)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then return end
    if ev == "rednet_message" and c == ADMIN_PROTOCOL and type(b) == "table"
       and b.cmd == "update" and not _G.ccUpdating then
      _G.ccUpdating = true -- drugi czujnik na tym komputerze nie powtorzy
      rednet.send(a, { cmd = "updating", label = label }, ADMIN_PROTOCOL)
      line(STATUS_ROW + 3, "Zdalna aktualizacja...")
      shell.run("update")
      os.reboot()
    end
  end
end

line(STATUS_ROW, ("Czujnik pradu '%s' (#%d)"):format(label, os.getComputerID()))
line(STATUS_ROW + 1, "Wysylam dane do SCADA co " .. INTERVAL .. " s.")

while true do
  local total, capacity, sources = scanEnergy()
  rednet.broadcast({
    cmd = "energy", label = label,
    energy = total, capacity = capacity, sources = sources,
  }, ENERGY_PROTOCOL)

  local pct = capacity > 0 and math.floor(total / capacity * 100 + 0.5) or 0
  line(STATUS_ROW + 2, ("[%s] Magazynow: %d"):format(
    textutils.formatTime(os.time(), true), #sources))
  line(STATUS_ROW + 3, ("%s / %s (%d%%)"):format(fmtFE(total), fmtFE(capacity), pct))

  waitInterval()
end

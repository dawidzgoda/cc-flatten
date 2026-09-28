-- lavasensor.lua - czujnik lawy: odczytuje zbiorniki/skrzynie przy tym
-- komputerze i wysyla dane bezprzewodowo do SCADA.
--
-- Uzycie:  lavasensor           - uruchom czujnik
--          lavasensor install   - autostart (dziala tez razem z energysensor)
--
-- Wymaga: komputer + wireless/ender modem, zbiorniki lub skrzynie z wiadrami
--         lawy obok komputera albo podlaczone wired modemem + kablem.
-- Nazwa czujnika na SCADA = etykieta komputera (label set <nazwa>).

local LAVA_PROTOCOL = "scada_lava"
local INTERVAL      = 5  -- sekundy miedzy wysylkami

local LAVA        = "minecraft:lava"
local LAVA_BUCKET = "minecraft:lava_bucket"

local ADMIN_PROTOCOL = "scada_admin"   -- zdalny UPDATE ze SCADA
local STATUS_ROW = 1   -- wiersze 1-4 ekranu (energysensor 6-9, scada 11)

if ({ ... })[1] == "install" then shell.run("autostart", "add", "lavasensor"); return end

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Brak wireless/ender modemu!") end
rednet.open(peripheral.getName(modem))

-- Te same zasady co w SCADA: zbiorniki z lawa (lub puste) i skrzynie z wiadrami
local function scanLava()
  local total, sources = 0, {}
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    local amount, show = 0, false

    if p.tanks then
      local ok, tanks = pcall(p.tanks)
      if ok and type(tanks) == "table" then
        local other = false
        for _, t in pairs(tanks) do
          if t.name == LAVA then amount = amount + t.amount
          elseif t.amount and t.amount > 0 then other = true end
        end
        show = amount > 0 or not other
      end
    end

    if p.list then
      local ok, items = pcall(p.list)
      if ok and type(items) == "table" then
        for _, it in pairs(items) do
          if it.name == LAVA_BUCKET then
            amount = amount + it.count * 1000
            show = true
          end
        end
      end
    end

    if show then
      sources[#sources + 1] = { name = name, amount = amount }
      total = total + amount
    end
  end
  return total, sources
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

line(STATUS_ROW, ("Czujnik lawy '%s' (#%d)"):format(label, os.getComputerID()))
line(STATUS_ROW + 1, "Wysylam dane do SCADA co " .. INTERVAL .. " s.")

while true do
  local total, sources = scanLava()
  rednet.broadcast({
    cmd = "lava", label = label, total = total, sources = sources,
  }, LAVA_PROTOCOL)

  line(STATUS_ROW + 2, ("[%s] Zrodel: %d, lawa: %.1f B"):format(
    textutils.formatTime(os.time(), true), #sources, total / 1000))

  waitInterval()
end

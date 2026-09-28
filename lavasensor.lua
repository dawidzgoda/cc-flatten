-- lavasensor.lua - czujnik lawy: odczytuje zbiorniki/skrzynie przy tym
-- komputerze i wysyla dane bezprzewodowo do SCADA.
--
-- Uzycie:  lavasensor           - uruchom czujnik
--          lavasensor install   - uruchamiaj automatycznie po starcie komputera
--
-- Wymaga: komputer + wireless/ender modem, zbiorniki lub skrzynie z wiadrami
--         lawy obok komputera albo podlaczone wired modemem + kablem.
-- Nazwa czujnika na SCADA = etykieta komputera (label set <nazwa>).

local LAVA_PROTOCOL = "scada_lava"
local INTERVAL      = 5  -- sekundy miedzy wysylkami

local LAVA        = "minecraft:lava"
local LAVA_BUCKET = "minecraft:lava_bucket"

if ({ ... })[1] == "install" then
  local f = fs.open("startup.lua", "w")
  f.write('shell.run("lavasensor")\n')
  f.close()
  print("Zapisano startup.lua - czujnik ruszy po kazdym starcie.")
  print("Wpisz 'reboot' albo 'lavasensor', zeby uruchomic teraz.")
  return
end

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

term.clear(); term.setCursorPos(1, 1)
print(("Czujnik lawy '%s' (#%d)"):format(label, os.getComputerID()))
print("Wysylam dane do SCADA co " .. INTERVAL .. " s. Ctrl+T - stop.")
print()

while true do
  local total, sources = scanLava()
  rednet.broadcast({
    cmd = "lava", label = label, total = total, sources = sources,
  }, LAVA_PROTOCOL)

  local _, y = term.getCursorPos()
  term.setCursorPos(1, 4); term.clearLine()
  write(("[%s] Zrodel: %d, lawa: %.1f B"):format(
    textutils.formatTime(os.time(), true), #sources, total / 1000))
  term.setCursorPos(1, y)

  sleep(INTERVAL)
end

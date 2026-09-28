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

local SENSORS    = { "lavasensor", "energysensor" }
local STATUS_ROW = 1   -- wiersze 1-4 ekranu (energysensor ma 6-9)

-- Autostart: startup.lua uruchamia rownolegle wszystkie zainstalowane czujniki
local function install(me)
  local list, content = {}, ""
  if fs.exists("startup.lua") then
    local f = fs.open("startup.lua", "r"); content = f.readAll(); f.close()
  end
  for _, n in ipairs(SENSORS) do
    if n == me or content:find(n, 1, true) then list[#list + 1] = n end
  end
  if content ~= "" and not content:find("^%-%- sensors:") then
    fs.delete("startup.bak"); fs.copy("startup.lua", "startup.bak")
    print("Stary startup.lua zapisano jako startup.bak")
  end

  local names = table.concat(list, ",")
  local f = fs.open("startup.lua", "w")
  f.writeLine("-- sensors: " .. names)
  f.writeLine("term.clear()")
  f.writeLine("local fns = {}")
  f.writeLine(('for n in ("%s"):gmatch("[^,]+") do'):format(names))
  f.writeLine("  fns[#fns + 1] = function() shell.run(n) end")
  f.writeLine("end")
  f.writeLine("parallel.waitForAll(table.unpack(fns))")
  f.close()
  print("Autostart: " .. names)
  print("Wpisz 'reboot', zeby uruchomic.")
end

if ({ ... })[1] == "install" then install("lavasensor"); return end

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

line(STATUS_ROW, ("Czujnik lawy '%s' (#%d)"):format(label, os.getComputerID()))
line(STATUS_ROW + 1, "Wysylam dane do SCADA co " .. INTERVAL .. " s.")

while true do
  local total, sources = scanLava()
  rednet.broadcast({
    cmd = "lava", label = label, total = total, sources = sources,
  }, LAVA_PROTOCOL)

  line(STATUS_ROW + 2, ("[%s] Zrodel: %d, lawa: %.1f B"):format(
    textutils.formatTime(os.time(), true), #sources, total / 1000))

  sleep(INTERVAL)
end

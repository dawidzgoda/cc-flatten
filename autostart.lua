-- autostart.lua - zarzadza plikiem startup.lua na zwyklym komputerze
--
-- Uzycie:  autostart add <program>      - uruchamiaj program po starcie
--          autostart remove <program>   - przestan uruchamiac
--          autostart list               - pokaz, co startuje
--
-- Obslugiwane programy: scada, lavasensor, energysensor.
-- Kilka programow dziala rownolegle; jesli ktorys sie wywali, restartuje
-- sie po 5 s. Ctrl+T (dwa razy) zatrzymuje wszystko.

local KNOWN = { "scada", "lavasensor", "energysensor" }
local FILE = "startup.lua"

local function isKnown(n)
  for _, k in ipairs(KNOWN) do if k == n then return true end end
  return false
end

-- Aktualna lista z startup.lua (naglowek "-- autostart:" albo stary "-- sensors:")
local function readList()
  if not fs.exists(FILE) then return {}, "" end
  local f = fs.open(FILE, "r"); local content = f.readAll(); f.close()
  local header = content:match("^%-%- autostart: ([^\n]*)") or content:match("^%-%- sensors: ([^\n]*)")
  local list = {}
  if header then
    for n in header:gmatch("[^,]+") do if isKnown(n) then list[#list + 1] = n end end
  else
    -- stary format (np. shell.run("lavasensor")) - szukamy znanych nazw
    for _, n in ipairs(KNOWN) do
      if content:find('"' .. n .. '"', 1, true) then list[#list + 1] = n end
    end
  end
  return list, content
end

local function writeList(list, oldContent)
  local ours = oldContent:find("^%-%- autostart:") or oldContent:find("^%-%- sensors:")
  if oldContent ~= "" and not ours then
    fs.delete("startup.bak"); fs.copy(FILE, "startup.bak")
    print("Stary startup.lua zapisano jako startup.bak")
  end
  if #list == 0 then
    fs.delete(FILE)
    return
  end

  local names = table.concat(list, ",")
  local f = fs.open(FILE, "w")
  f.writeLine("-- autostart: " .. names)
  f.writeLine("-- plik generowany przez 'autostart' - nie edytuj recznie")
  f.writeLine("term.clear()")
  f.writeLine("local fns = {}")
  f.writeLine(('for n in ("%s"):gmatch("[^,]+") do'):format(names))
  f.writeLine("  fns[#fns + 1] = function()")
  f.writeLine("    while true do")
  f.writeLine("      shell.run(n)")
  f.writeLine("      print(n .. ' zakonczony - restart za 5 s (Ctrl+T = stop)')")
  f.writeLine("      sleep(5)")
  f.writeLine("    end")
  f.writeLine("  end")
  f.writeLine("end")
  f.writeLine("parallel.waitForAll(table.unpack(fns))")
  f.close()
end

local cmd, name = ...
local list, content = readList()

if cmd == "add" and isKnown(name) then
  local has = false
  for _, n in ipairs(list) do if n == name then has = true end end
  if not has then list[#list + 1] = name end
  writeList(list, content)
  print("Autostart: " .. table.concat(list, ", "))
  print("Wpisz 'reboot', zeby uruchomic.")

elseif cmd == "remove" and isKnown(name) then
  for i = #list, 1, -1 do if list[i] == name then table.remove(list, i) end end
  writeList(list, content)
  print("Autostart: " .. (#list > 0 and table.concat(list, ", ") or "(nic)"))

elseif cmd == "list" then
  print("Autostart: " .. (#list > 0 and table.concat(list, ", ") or "(nic)"))

else
  print("Uzycie: autostart add|remove <program>")
  print("        autostart list")
  print("Programy: " .. table.concat(KNOWN, ", "))
end

-- energysensor.lua - STARA NAZWA. Czujnik pradu jest teraz czescia programu
-- 'sensor' (sekcja PRAD).
-- Ten plik zostaje, zeby dzialaly stare autostarty i polecenia.

local args = { ... }
if args[1] == "install" then
  if not fs.exists("autostart") and not fs.exists("autostart.lua") then shell.run("update") end
  shell.run("autostart", "add", "sensor")   -- autostart sam usunie stare nazwy
  return
end
-- stary update (zdalny UPDATE) nie znal pliku sensor - dociagnij go
if not fs.exists("sensor") and not fs.exists("sensor.lua") then shell.run("update") end
shell.run("sensor", table.unpack(args))

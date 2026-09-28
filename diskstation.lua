-- diskstation.lua - stacja nagrywania dyskietek instalacyjnych
--
-- Uzycie:  diskstation           - uruchom stacje
--          diskstation install   - autostart
--
-- Komputer z internetem i stacja dyskow (mozna podlaczyc kilka stacji).
-- Wloz dyskietke -> stacja sama nagrywa najnowszy instalator z GitHuba
-- (mkdisk) i wysuwa gotowa dyskietke. Nagrywa tylko puste dyskietki
-- albo stare instalatory - innych dyskietek nie rusza.
--
-- Ten program NIE trafia na dyskietki instalacyjne.

if ({ ... })[1] == "install" then
  if not fs.exists("autostart") and not fs.exists("autostart.lua") then shell.run("update") end
  shell.run("autostart", "add", "diskstation")
  return
end

if not http then error("HTTP jest wylaczone w configu CC: Tweaked") end
if not peripheral.find("drive") then error("Podlacz stacje dyskow (disk drive)!") end
if not fs.exists("mkdisk") and not fs.exists("mkdisk.lua") then shell.run("update") end

local done, failed = 0, 0

local function header()
  term.clear(); term.setCursorPos(1, 1)
  print("=== Stacja dyskietek cc-flatten ===")
  print(("Nagrane: %d   bledy: %d"):format(done, failed))
  print("Wloz dyskietke do stacji...")
  print()
end

local function burn(name)
  if not disk.isPresent(name) or not disk.hasData(name) then return end
  term.setCursorPos(1, 5)
  local ok = shell.run("mkdisk", "auto", name)
  if ok then done = done + 1 else failed = failed + 1 end
  sleep(1)
  header()
end

header()

-- dyskietki wlozone przed startem stacji
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.hasType(name, "drive") and disk.isPresent(name) then burn(name) end
end

while true do
  local _, side = os.pullEvent("disk")
  burn(side)
end

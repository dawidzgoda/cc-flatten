-- installer.lua - instalator z dyskietki (mkdisk zapisuje go jako disk/startup.lua)
--
-- Uruchamia sie sam, gdy komputer/zolw startuje z podlaczona stacja dyskow
-- i wlozona dyskietka. Kopiuje programy z dyskietki (bez internetu),
-- ustawia nazwe i autostart, wysuwa dyskietke i restartuje urzadzenie.
--
-- Jesli urzadzenie ma juz zainstalowane oprogramowanie, a nikt nie nacisnie
-- Enter w ciagu 10 s, instalator uruchamia normalny startup urzadzenia.

local diskDir  = fs.getDir(shell.getRunningProgram())   -- np. "disk"
local filesDir = fs.combine(diskDir, "files")

local version = "?"
if fs.exists(fs.combine(diskDir, "version")) then
  local f = fs.open(fs.combine(diskDir, "version"), "r"); version = f.readAll(); f.close()
end

-- Strona, po ktorej stoi stacja z ta dyskietka (do wysuniecia)
local driveSide
for _, n in ipairs(peripheral.getNames()) do
  if disk.isPresent(n) and disk.getMountPath(n) == diskDir then driveSide = n end
end

-- Programy zwyklego komputera, ktore moga byc w autostarcie
-- (diskstation celowo pomijamy - nie jest instalowana z dyskietki)
local AUTOSTART = { "scada", "sensor" }

local ROLES = {
  { key = keys.one,   name = "SCADA (monitor)",            start = { "scada" } },
  { key = keys.two,   name = "Czujnik (Create, FE, ...)",  start = { "sensor" } },
  { key = keys.three, name = "SCADA + czujnik",            start = { "scada", "sensor" } },
}

---------------------------------------------------------------------------

local function waitKey(timeout)
  local timer = timeout and os.startTimer(timeout)
  while true do
    local ev, p = os.pullEvent()
    if ev == "key" then return p end
    if ev == "timer" and p == timer then return nil end
  end
end

local function runLocalStartup()
  for _, p in ipairs({ "/startup.lua", "/startup" }) do
    if fs.exists(p) and not fs.isDir(p) then
      term.clear(); term.setCursorPos(1, 1)
      shell.run(p)
      return
    end
  end
end

local function copy(name, dst)
  local src = fs.combine(filesDir, name .. ".lua")
  if not fs.exists(src) then
    print("  BRAK na dyskietce: " .. name)
    return false
  end
  if fs.exists(dst) then fs.delete(dst) end
  fs.copy(src, dst)
  print("  " .. dst)
  return true
end

local function askLabel(default)
  local cur = os.getComputerLabel()
  write(("Nazwa urzadzenia [%s]: "):format(cur or default))
  local s = read()
  if s ~= "" then os.setComputerLabel(s)
  elseif not cur then os.setComputerLabel(default) end
end

local function finish()
  print()
  print("Gotowe! Wysuwam dyskietke i restartuje...")
  if driveSide then disk.eject(driveSide) end
  sleep(2)
  os.reboot()
end

---------------------------------------------------------------------------

term.clear(); term.setCursorPos(1, 1)
print("=== Instalator cc-flatten ===")
print("Wersja dyskietki: " .. version)

if pocket then
  print("Pocket computer nie obsluguje stacji dyskow.")
  print("Na pockecie uzyj: update")
  return
end

local installed = turtle and fs.exists("flatten") or (not turtle and fs.exists("autostart"))
print(turtle and ("Urzadzenie: ZOLW #" .. os.getComputerID())
             or ("Urzadzenie: KOMPUTER #" .. os.getComputerID()))
print()

if installed then
  print("Oprogramowanie juz jest zainstalowane.")
  print("Enter = zainstaluj ponownie")
  print("(za 10 s normalny start urzadzenia)")
  if waitKey(10) ~= keys.enter then runLocalStartup(); return end
else
  print("Enter = instaluj, Q = anuluj")
  while true do
    local k = waitKey()
    if k == keys.enter then break end
    if k == keys.q then print("Anulowano."); return end
  end
end

term.clear(); term.setCursorPos(1, 1)

if turtle then
  print("Instalacja na zolwiu:")
  copy("flatten", "flatten")
  copy("torches", "torches")
  copy("listener", "startup")
  copy("update", "update")
  print()
  askLabel("Zolw_" .. os.getComputerID())
  finish()
  return
end

-- Zwykly komputer: wybor roli
print("Co ma robic ten komputer?")
for i, r in ipairs(ROLES) do print(("  %d) %s"):format(i, r.name)) end
print("  Q) anuluj")
local role
while not role do
  local k = waitKey()
  if k == keys.q then print("Anulowano."); return end
  for _, r in ipairs(ROLES) do if r.key == k then role = r end end
end

term.clear(); term.setCursorPos(1, 1)
print("Instalacja: " .. role.name)
for _, n in ipairs({ "scada", "sensor", "autostart", "remote", "update" }) do
  copy(n, n)
end

-- autostart: dokladnie programy z wybranej roli
for _, n in ipairs(AUTOSTART) do shell.run("autostart", "remove", n) end
for _, n in ipairs(role.start) do shell.run("autostart", "add", n) end

print()
if role.start[1] == "sensor" or role.start[2] == "sensor" then
  print("Nazwa = nazwa GRUPY na SCADA (np. miejsce:")
  print("'Wyspa Glowna', 'Kopalnia', 'Huta').")
end
local defaultName = role.start[1] == "scada" and "SCADA" or ("Czujnik_" .. os.getComputerID())
askLabel(defaultName)
finish()

-- mkdisk.lua - nagrywa dyskietke instalacyjna cc-flatten
--
-- Uzycie:  mkdisk                - nagraj dyskietke w podlaczonej stacji
--          mkdisk auto <stacja>  - tryb dla diskstation: bez pytania,
--                                  na koncu wysuwa dyskietke
--
-- Pobiera najnowsze programy z GitHuba na dyskietke i dodaje instalator
-- (disk/startup.lua). Potem dyskietka instaluje wszystko bez internetu:
-- wystarczy postawic stacje obok zolwia/komputera, wlozyc dyskietke
-- i zrestartowac urzadzenie.
--
-- Na dyskietke NIE trafiaja programy stacji (mkdisk, diskstation).

local BASE  = "https://raw.githubusercontent.com/dawidzgoda/cc-flatten/main/"
local FILES = {
  "flatten", "torches", "listener",      -- zolw
  "scada", "sensor", "autostart",        -- komputery
  "remote", "update",
}
local DISK_LABEL = "Instalator cc-flatten"

local mode, driveName = ...
local auto = mode == "auto"

if not http then error("HTTP jest wylaczone w configu CC: Tweaked") end

local drive
if driveName then
  drive = peripheral.wrap(driveName)
else
  drive = peripheral.find("drive", function(_, d) return d.isDiskPresent() and d.hasData() end)
end
if not drive or not drive.isDiskPresent() or not drive.hasData() then
  error("Podlacz stacje dyskow i wloz dyskietke!")
end
local dir = drive.getMountPath()

print(("Dyskietka: /%s (%s)"):format(dir, drive.getDiskLabel() or "bez nazwy"))

if auto then
  -- stacja nagrywa tylko puste dyskietki albo nasze instalatory
  local label = drive.getDiskLabel()
  if #fs.list(dir) > 0 and label ~= DISK_LABEL then
    drive.ejectDisk()
    error("To nie jest pusta dyskietka ani instalator - pominieto", 0)
  end
else
  print("UWAGA: cala zawartosc dyskietki zostanie usunieta.")
  write("Enter = nagraj, inny klawisz = anuluj ")
  local _, key = os.pullEvent("key")
  print()
  if key ~= keys.enter then print("Anulowano."); return end
end

for _, f in ipairs(fs.list(dir)) do fs.delete(fs.combine(dir, f)) end

local function download(src, dst)
  write(("  %-14s "):format(src))
  local res, err = http.get(BASE .. src .. "?t=" .. os.epoch("utc"))
  if not res then print("BLAD: " .. tostring(err)); return false end
  local body = res.readAll(); res.close()
  local ok, werr = pcall(function()
    local h = fs.open(dst, "w"); h.write(body); h.close()
  end)
  if not ok then print("BLAD zapisu: " .. tostring(werr)); return false end
  print(("%d B"):format(#body))
  return true
end

print("Pobieram programy:")
local allOk = true
for _, name in ipairs(FILES) do
  allOk = download(name .. ".lua", fs.combine(dir, "files/" .. name .. ".lua")) and allOk
end
allOk = download("installer.lua", fs.combine(dir, "startup.lua")) and allOk

local v = fs.open(fs.combine(dir, "version"), "w")
v.write(os.date("%Y-%m-%d %H:%M"))
v.close()
drive.setDiskLabel(DISK_LABEL)

print()
if allOk then
  print("Dyskietka gotowa! Wolne miejsce: " .. fs.getFreeSpace(dir) .. " B")
  if not auto then
    print("Stacja obok zolwia/komputera + dyskietka + restart")
    print("(przytrzymaj Ctrl+R albo wpisz: reboot).")
  end
else
  print("Niektore pliki sie nie nagraly - sprawdz bledy wyzej.")
end

if auto then
  drive.ejectDisk()
  -- blad -> diskstation policzy dyskietke jako nieudana
  if not allOk then error("Dyskietka nagrana niekompletnie", 0) end
end

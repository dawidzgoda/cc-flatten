-- mkdisk.lua - nagrywa dyskietke instalacyjna cc-flatten
--
-- Uzycie: podlacz stacje dyskow (disk drive) do komputera, wloz dyskietke
--         i wpisz: mkdisk
--
-- Pobiera najnowsze programy z GitHuba na dyskietke i dodaje instalator
-- (disk/startup.lua). Potem dyskietka instaluje wszystko bez internetu:
-- wystarczy postawic stacje obok zolwia/komputera, wlozyc dyskietke
-- i zrestartowac urzadzenie.

local BASE  = "https://raw.githubusercontent.com/dawidzgoda/cc-flatten/main/"
local FILES = {
  "flatten", "torches", "listener",                      -- zolw
  "scada", "lavasensor", "energysensor", "autostart",    -- komputery
  "remote", "update",
}

if not http then error("HTTP jest wylaczone w configu CC: Tweaked") end

local drive = peripheral.find("drive", function(_, d) return d.isDiskPresent() and d.hasData() end)
if not drive then error("Podlacz stacje dyskow i wloz dyskietke!") end
local dir = drive.getMountPath()

print(("Dyskietka: /%s (%s)"):format(dir, drive.getDiskLabel() or "bez nazwy"))
print("UWAGA: cala zawartosc dyskietki zostanie usunieta.")
write("Enter = nagraj, inny klawisz = anuluj ")
local _, key = os.pullEvent("key")
print()
if key ~= keys.enter then print("Anulowano."); return end

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
drive.setDiskLabel("Instalator cc-flatten")

print()
if allOk then
  print("Dyskietka gotowa! Wolne miejsce: " .. fs.getFreeSpace(dir) .. " B")
  print("Stacja obok zolwia/komputera + dyskietka + restart")
  print("(przytrzymaj Ctrl+R albo wpisz: reboot).")
else
  print("Niektore pliki sie nie nagraly - sprawdz bledy wyzej.")
end

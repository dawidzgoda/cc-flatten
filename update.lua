-- update.lua - pobiera najnowsze wersje programow z GitHuba
-- Na zolwiu: flatten, torches, startup (listener), update
-- Na pocket computerze: remote, pscada, update
-- Na zwyklym komputerze: scada, lavasensor, energysensor, remote, update

local BASE = "https://raw.githubusercontent.com/dawidzgoda/cc-flatten/main/"

local files
if turtle then
  files = {
    { "flatten.lua",  "flatten" },
    { "torches.lua",  "torches" },
    { "listener.lua", "startup" },
    { "update.lua",   "update" },
  }
elseif pocket then
  files = {
    { "remote.lua", "remote" },
    { "pscada.lua", "pscada" },
    { "update.lua", "update" },
  }
else
  -- zwykly komputer: panel SCADA, czujnik lawy, pilot
  files = {
    { "scada.lua",      "scada" },
    { "lavasensor.lua", "lavasensor" },
    { "energysensor.lua", "energysensor" },
    { "remote.lua", "remote" },
    { "update.lua", "update" },
  }
end

if not http then error("HTTP jest wylaczone w configu CC: Tweaked") end

print(turtle and "Aktualizuje zolwia..."
  or pocket and "Aktualizuje pilota..."
  or "Aktualizuje komputer...")
local allOk = true
for _, f in ipairs(files) do
  local src, dst = f[1], f[2]
  write(("  %-8s "):format(dst))
  -- parametr ?t= omija cache GitHuba
  local res, err = http.get(BASE .. src .. "?t=" .. os.epoch("utc"))
  if not res then
    print("BLAD: " .. tostring(err))
    allOk = false
  else
    local body = res.readAll()
    res.close()
    local h = fs.open(dst, "w")
    h.write(body)
    h.close()
    print(("OK (%d B)"):format(#body))
  end
end

if not allOk then
  print("Niektore pliki sie nie pobraly - stare wersje zostaly.")
elseif turtle then
  print("Gotowe. Wpisz 'reboot', zeby uruchomic nowy listener.")
else
  print("Gotowe.")
end

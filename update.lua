-- update.lua - pobiera najnowsze wersje programow z GitHuba
-- Na zolwiu: flatten, torches, startup (listener), update
-- Na pocket computerze: remote, pscada, update
-- Na zwyklym komputerze: scada (+ moduly scadalib/), sensor (+ stare nazwy
--                        lavasensor/energysensor), autostart, mkdisk,
--                        diskstation, remote, update

local REPO = "dawidzgoda/cc-flatten"

-- Adresy z "main" GitHub potrafi serwowac z nieaktualnej pamieci podrecznej
-- (nawet kilka minut). Pytamy wiec API o numer najnowszego commita i
-- pobieramy pliki spod adresu z tym numerem - ten zawsze jest aktualny.
local function latestBase()
  local res = http and http.get("https://api.github.com/repos/" .. REPO .. "/commits/main",
                                { Accept = "application/vnd.github.sha" })
  if res then
    local sha = res.readAll():match("^%x+")
    res.close()
    if sha and #sha >= 7 then
      return "https://raw.githubusercontent.com/" .. REPO .. "/" .. sha .. "/", sha:sub(1, 7)
    end
  end
  -- API niedostepne (np. limit zapytan) - awaryjnie "main"
  return "https://raw.githubusercontent.com/" .. REPO .. "/main/", "main"
end

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
  -- zwykly komputer: SCADA, czujnik, stacja dyskietek, pilot
  files = {
    { "scada.lua",        "scada" },
    { "sensor.lua",       "sensor" },
    { "lavasensor.lua",   "lavasensor" },     -- alias -> sensor
    { "energysensor.lua", "energysensor" },   -- alias -> sensor
    { "autostart.lua",    "autostart" },
    { "mkdisk.lua",       "mkdisk" },
    { "diskstation.lua",  "diskstation" },
    { "remote.lua",       "remote" },
    { "update.lua",       "update" },
  }
  -- moduly SCADA (scada.lua laduje je przez require)
  for _, m in ipairs({ "app", "config", "data", "alarms", "ui", "sections", "views" }) do
    files[#files + 1] = { "scadalib/" .. m .. ".lua", "scadalib/" .. m .. ".lua" }
  end
end

if not http then error("HTTP jest wylaczone w configu CC: Tweaked") end

local BASE, version = latestBase()
print((turtle and "Aktualizuje zolwia"
  or pocket and "Aktualizuje pilota"
  or "Aktualizuje komputer") .. " (wersja " .. version .. ")...")
local allOk = true
for _, f in ipairs(files) do
  local src, dst = f[1], f[2]
  write(("  %-12s "):format(dst:gsub("%.lua$", "")))
  local res, err = http.get(BASE .. src)
  if not res then
    print("BLAD: " .. tostring(err))
    allOk = false
  else
    local body = res.readAll()
    res.close()
    local dir = fs.getDir(dst)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
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

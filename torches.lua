-- torches.lua - stawianie pochodni w siatce (CC: Tweaked)
--
-- Uzycie:  torches <dlugosc> <szerokosc> [odstep=5] [-c]
--
-- Ustawienie zolwia (tak samo jak w flatten):
--   * zolw stoi na ziemi, w lewym-dolnym rogu obszaru, przodem wzdluz
--     "dlugosci"; obszar idzie do przodu i w PRAWO,
--   * albo z flaga -c: na srodku obszaru.
--
-- Dziala na terenie plaskim i gorzystym:
--   * miedzy pochodniami zolw leci nad terenem - przed zboczem, pniem albo
--     skala WZNOSI SIE (nie kopie tunelu); liscie i trawe usuwa po drodze,
--   * w miejscu pochodni opada az do gruntu (przez liscie, trawe, snieg)
--     i stawia pochodnie na prawdziwym podlozu,
--   * pomija miejsca z woda/lawa, pniem drzewa, przepascia glebsza niz
--     MAX_DROP i miejsca, gdzie pochodnia juz stoi,
--   * na koniec wraca na pozycje startowa.

local TORCH     = "minecraft:torch"
local MAX_DROP  = 64    -- max opadanie w miejscu pochodni (przepasc/wawoz)
local MAX_CLIMB = 128   -- max wysokosc ponad start (zabezpieczenie)

local args, CENTER = {}, false
for _, a in ipairs({ ... }) do
  if a == "-c" then CENTER = true else args[#args + 1] = a end
end
local LENGTH  = tonumber(args[1])
local WIDTH   = tonumber(args[2])
local SPACING = tonumber(args[3]) or 5

if not LENGTH or not WIDTH or LENGTH < 1 or WIDTH < 1 or SPACING < 1 then
  print("Uzycie: torches <dlugosc> <szerokosc> [odstep=5] [-c]")
  print("Zolw stoi w rogu (lub na srodku z -c),")
  print("przodem wzdluz dlugosci; obszar idzie w prawo.")
  return
end

---------------------------------------------------------------------------
-- Rozpoznawanie blokow (turtle.inspect*)

local function hasTag(b, tag) return b.tags ~= nil and b.tags[tag] == true end

-- Bloki "miekkie": zolw je usuwa zamiast omijac (liscie, trawa, kwiaty, snieg)
local function isSoft(b)
  local n = b.name
  if hasTag(b, "minecraft:leaves") or hasTag(b, "minecraft:replaceable")
     or hasTag(b, "minecraft:flowers") or hasTag(b, "minecraft:replaceable_by_trees") then
    return true
  end
  return n:find("leaves") ~= nil or n == "minecraft:grass" or n == "minecraft:short_grass"
      or n == "minecraft:tall_grass" or n == "minecraft:fern" or n == "minecraft:large_fern"
      or n == "minecraft:snow" or n == "minecraft:vine" or n == "minecraft:dead_bush"
end

local function isLiquid(b)
  return b.name == "minecraft:water" or b.name == "minecraft:lava"
      or b.name:find("flowing") ~= nil
end

local function isLog(b)
  return hasTag(b, "minecraft:logs") or b.name:find("_log") ~= nil or b.name:find("_stem") ~= nil
end

local function isTorchBlock(b) return b.name:find("torch") ~= nil end

---------------------------------------------------------------------------
-- Pozycja wzgledem startu: x = do przodu, z = w prawo, y = w gore
-- dir: 0 = +x, 1 = +z, 2 = -x, 3 = -z
local x, y, z, dir = 0, 0, 0, 0

local function turnRight() turtle.turnRight(); dir = (dir + 1) % 4 end
local function turnLeft()  turtle.turnLeft();  dir = (dir + 3) % 4 end

-- Obraca sie najkrotsza droga (max jeden obrot w lewo).
local function face(d)
  if (dir + 3) % 4 == d then turnLeft() end
  while dir ~= d do turnRight() end
end

local function up()
  local tries = 0
  while not turtle.up() do
    if not turtle.digUp() then turtle.attackUp() end
    tries = tries + 1
    if tries > 30 then error("Nie moge wzniesc sie w gore") end
  end
  y = y + 1
end

local function down()
  local tries = 0
  while not turtle.down() do
    if not turtle.digDown() then turtle.attackDown() end
    tries = tries + 1
    if tries > 30 then error("Nie moge zejsc w dol") end
  end
  y = y - 1
end

-- Ruch do przodu nad terenem: miekkie bloki usuwa, przed reszta sie wznosi.
local function forward()
  local tries = 0
  while not turtle.forward() do
    local ok, b = turtle.inspect()
    if ok and isSoft(b) then
      turtle.dig()
    elseif ok then
      -- zbocze, skala, pien, pochodnia... - lecimy wyzej, nic nie niszczac
      if y >= MAX_CLIMB then error("Przeszkoda za wysoka (MAX_CLIMB)") end
      up()
    else
      turtle.attack() -- mob
      tries = tries + 1
      if tries > 30 then error("Cos blokuje droge") end
    end
  end
  if dir == 0 then x = x + 1 elseif dir == 1 then z = z + 1
  elseif dir == 2 then x = x - 1 else z = z - 1 end
end

local function goTo(tx, tz)
  if x > tx then face(2) elseif x < tx then face(0) end
  while x ~= tx do forward() end
  if z > tz then face(3) elseif z < tz then face(1) end
  while z ~= tz do forward() end
end

---------------------------------------------------------------------------
-- Ekwipunek i paliwo

local function isTorch(slot)
  local d = turtle.getItemDetail(slot)
  return d ~= nil and d.name == TORCH
end

local function countTorches()
  local n = 0
  for s = 1, 16 do
    if isTorch(s) then n = n + turtle.getItemCount(s) end
  end
  return n
end

local function selectTorch()
  while true do
    for s = 1, 16 do
      if isTorch(s) then turtle.select(s); return end
    end
    print("Brak pochodni! Doloz do ekwipunku...")
    _G.ccWaiting = "brak pochodni" -- widoczne na SCADA
    os.pullEvent("turtle_inventory")
    _G.ccWaiting = nil
  end
end

local function refuel(needed)
  if turtle.getFuelLevel() == "unlimited" then return end
  while turtle.getFuelLevel() < needed do
    local ok = false
    for s = 1, 16 do
      if turtle.getItemCount(s) > 0 and not isTorch(s) then
        turtle.select(s)
        if turtle.refuel(1) then ok = true; break end
      end
    end
    if not ok then
      print(("Malo paliwa (%d/%d). Dodaj wegiel..."):format(turtle.getFuelLevel(), needed))
      _G.ccWaiting = "brak paliwa" -- widoczne na SCADA
      os.pullEvent("turtle_inventory")
      _G.ccWaiting = nil
    end
  end
end

---------------------------------------------------------------------------
-- Siatka pochodni

-- Wspolrzedne rogu obszaru wzgledem startu
local x0, z0 = 0, 0
if CENTER then
  x0 = -math.floor((LENGTH - 1) / 2)
  z0 = -math.floor((WIDTH - 1) / 2)
end

-- Pierwsza pochodnia ~pol odstepu od krawedzi obszaru.
local offset = math.floor(SPACING / 2)

-- Lista miejsc na pochodnie w kolejnosci lotu: rzad po rzedzie, wezykiem.
-- Zolw odwiedza tylko te miejsca, a nie caly obszar.
local spots = {}
local reverse = false
for pz = z0 + offset, z0 + WIDTH - 1, SPACING do
  local xs = {}
  for px = x0 + offset, x0 + LENGTH - 1, SPACING do
    -- pole startowe pomijamy: zolw na nie laduje na koniec
    if not (px == 0 and pz == 0) then xs[#xs + 1] = px end
  end
  if reverse then
    for i = #xs, 1, -1 do spots[#spots + 1] = { xs[i], pz } end
  else
    for i = 1, #xs do spots[#spots + 1] = { xs[i], pz } end
  end
  reverse = not reverse
end

-- Dlugosc trasy w poziomie (bez wznoszenia/opadania, ktore zalezy od terenu)
local pathLen, px, pz = 2, 0, 0
for _, s in ipairs(spots) do
  pathLen = pathLen + math.abs(s[1] - px) + math.abs(s[2] - pz)
  px, pz = s[1], s[2]
end
pathLen = pathLen + math.abs(px) + math.abs(pz)

print(("Obszar %dx%d, odstep %d: potrzeba %d pochodni (masz %d)."):format(
  LENGTH, WIDTH, SPACING, #spots, countTorches()))
print(("Trasa w poziomie: %d ruchow (+ gory/doliny)."):format(pathLen))

local stats = { placed = 0, already = 0, liquid = 0, deep = 0, tree = 0, failed = 0 }

-- Opada do gruntu. Wynik:
--   "ok"     - zolw jest tuz nad gruntem,
--   "torch"  - pod spodem juz stoi pochodnia,
--   "liquid" - woda/lawa, "tree" - pien drzewa, "deep" - przepasc > MAX_DROP
local function descendToGround()
  local drop = 0
  while true do
    local ok, b = turtle.inspectDown()
    if not ok then
      if drop >= MAX_DROP then return "deep" end
      down()
      drop = drop + 1
    elseif isTorchBlock(b) then return "torch"
    elseif isLiquid(b) then return "liquid"
    elseif isSoft(b) then turtle.digDown()   -- liscie/trawa/snieg: usun i opadaj dalej
    elseif isLog(b) then return "tree"
    else return "ok" end
  end
end

local function placeTorchHere()
  local r = descendToGround()
  if r == "torch" then stats.already = stats.already + 1; return end
  if r ~= "ok" then stats[r] = stats[r] + 1; return end

  up() -- zwalniamy pole nad gruntem i stawiamy w nim pochodnie
  selectTorch()
  if turtle.placeDown() then
    stats.placed = stats.placed + 1
  else
    stats.failed = stats.failed + 1
  end
end

---------------------------------------------------------------------------
-- Glowna petla: lot nad terenem od pochodni do pochodni

refuel(pathLen + 10)
up()

for i, s in ipairs(spots) do
  local nxt = spots[i + 1] or { 0, 0 }
  -- zapas: powrot do domu + kolejny odcinek + opadanie i wznoszenie
  refuel(math.abs(x) + math.abs(z) + math.abs(y)
         + math.abs(nxt[1] - s[1]) + math.abs(nxt[2] - s[2]) + 2 * MAX_DROP + 20)
  goTo(s[1], s[2])
  placeTorchHere()
  _G.ccProgress = i / #spots -- postep dla listenera / SCADA
end

-- Powrot: nad teren startu, potem pionowo na wysokosc startowa
goTo(0, 0)
while y > 0 do down() end
while y < 0 do up() end
face(0)

print(("Gotowe! Postawiono %d pochodni."):format(stats.placed))
if stats.already > 0 then print(("Juz stalo: %d"):format(stats.already)) end
local skippedTotal = stats.liquid + stats.deep + stats.tree + stats.failed
if skippedTotal > 0 then
  print(("Pominieto %d: woda/lawa %d, drzewo %d, przepasc %d, inne %d"):format(
    skippedTotal, stats.liquid, stats.tree, stats.deep, stats.failed))
end

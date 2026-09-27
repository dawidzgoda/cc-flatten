-- torches.lua - stawianie pochodni w siatce (CC: Tweaked)
--
-- Uzycie:  torches <dlugosc> <szerokosc> [odstep=5] [-c]
--
-- Ustawienie zolwia (tak samo jak w flatten):
--   * zolw stoi NA poziomie terenu (blok pod nim = podloga),
--   * w lewym-dolnym rogu obszaru, przodem wzdluz "dlugosci",
--     obszar idzie do przodu i w PRAWO,
--   * albo z flaga -c: na srodku obszaru.
--
-- Zolw leci 1 blok nad ziemia prosto od pochodni do pochodni (nie przelatuje
-- calego obszaru), stawia je pod soba co <odstep> kratek i wraca na start.
-- Najlepiej dziala na terenie wyrownanym programem flatten.

local TORCH = "minecraft:torch"

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

local function forward()
  local tries = 0
  while not turtle.forward() do
    -- dig() radzi sobie tez z trawa/kwiatami; jak nie ma czego kopac - mob
    if not turtle.dig() then turtle.attack() end
    tries = tries + 1
    if tries > 30 then error("Nie moge jechac do przodu (bedrock?)") end
  end
  if dir == 0 then x = x + 1 elseif dir == 1 then z = z + 1
  elseif dir == 2 then x = x - 1 else z = z - 1 end
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
    os.pullEvent("turtle_inventory")
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
      os.pullEvent("turtle_inventory")
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

-- Dlugosc trasy: start -> kolejne miejsca -> powrot, plus wzlot i ladowanie
local pathLen, px, pz = 2, 0, 0
for _, s in ipairs(spots) do
  pathLen = pathLen + math.abs(s[1] - px) + math.abs(s[2] - pz)
  px, pz = s[1], s[2]
end
pathLen = pathLen + math.abs(px) + math.abs(pz)

print(("Obszar %dx%d, odstep %d: potrzeba %d pochodni (masz %d)."):format(
  LENGTH, WIDTH, SPACING, #spots, countTorches()))
print(("Trasa: %d ruchow."):format(pathLen))

local placed, skipped = 0, 0

local function placeTorch()
  selectTorch()
  -- trawa/kwiat pod zolwiem blokuje postawienie - usun je
  if turtle.detectDown() then turtle.digDown() end
  if turtle.placeDown() then
    placed = placed + 1
  else
    skipped = skipped + 1 -- np. dziura pod spodem
  end
end

---------------------------------------------------------------------------
-- Glowna petla: lot 1 blok nad ziemia od pochodni do pochodni

refuel(pathLen + 10)
up()

for _, s in ipairs(spots) do
  goTo(s[1], s[2])
  placeTorch()
end

goTo(0, 0)
down()
face(0)

print(("Gotowe! Postawiono %d pochodni."):format(placed))
if skipped > 0 then
  print(("Pominieto %d miejsc (brak podlogi)."):format(skipped))
end

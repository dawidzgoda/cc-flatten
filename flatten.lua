-- flatten.lua - wyrownywanie terenu zolwiem (CC: Tweaked)
--
-- Uzycie:  flatten <dlugosc> <szerokosc> [maxWGore=32] [maxWDol=8]
--
-- Ustawienie zolwia:
--   * zolw stoi NA docelowym poziomie terenu (blok pod nim = przyszla powierzchnia),
--   * w lewym-dolnym rogu obszaru, przodem wzdluz "dlugosci",
--   * obszar rozciaga sie do przodu i w PRAWO od zolwia.
--   * albo z flaga -c: na srodku obszaru (kierunek przodu = "dlugosc").
--
-- Zolw:
--   * wycina wszystko na swoim poziomie i powyzej (wzgorza, drzewa) do maxWGore,
--   * zasypuje dziury pod soba (do glebokosci maxWDol) blokami z listy FILLER,
--   * wykopane bloki (ziemia, kamien) sam wykorzystuje do zasypywania,
--   * na koniec wraca na pozycje startowa.

-- Flaga "-c": zolw stoi na SRODKU obszaru (przodem wzdluz dlugosci),
-- sam dojezdza do rogu, a po pracy wraca na srodek.

local args, CENTER = {}, false
for _, a in ipairs({ ... }) do
  if a == "-c" then CENTER = true else args[#args + 1] = a end
end
local LENGTH   = tonumber(args[1])
local WIDTH    = tonumber(args[2])
local MAX_UP   = tonumber(args[3]) or 32
local MAX_DOWN = tonumber(args[4]) or 8

if not LENGTH or not WIDTH or LENGTH < 1 or WIDTH < 1 then
  print("Uzycie: flatten <dlugosc> <szerokosc> [maxWGore] [maxWDol] [-c]")
  print("Zolw stoi w rogu, na docelowym poziomie,")
  print("przodem wzdluz dlugosci; obszar idzie w prawo.")
  print("-c: zolw stoi na srodku obszaru.")
  return
end

-- Bloki uzywane do zasypywania dziur (bez piasku/zwiru - spadaja)
local FILLER = {
  ["minecraft:dirt"] = true,
  ["minecraft:coarse_dirt"] = true,
  ["minecraft:cobblestone"] = true,
  ["minecraft:cobbled_deepslate"] = true,
  ["minecraft:stone"] = true,
  ["minecraft:andesite"] = true,
  ["minecraft:diorite"] = true,
  ["minecraft:granite"] = true,
  ["minecraft:tuff"] = true,
  ["minecraft:calcite"] = true,
  ["minecraft:sandstone"] = true,
  ["minecraft:netherrack"] = true,
}

---------------------------------------------------------------------------
-- Pozycja wzgledem startu: x = do przodu, z = w prawo, y = w gore
-- dir: 0 = +x, 1 = +z, 2 = -x, 3 = -z
local x, y, z, dir = 0, 0, 0, 0

local function turnRight() turtle.turnRight(); dir = (dir + 1) % 4 end
local function turnLeft()  turtle.turnLeft();  dir = (dir + 3) % 4 end
local function face(d) while dir ~= d do turnRight() end end

local function forward()
  while not turtle.forward() do
    if turtle.detect() then
      if not turtle.dig() then error("Nie moge wykopac bloku przed soba (bedrock?)") end
    else
      turtle.attack() -- mob lub byt blokuje droge
    end
  end
  if dir == 0 then x = x + 1 elseif dir == 1 then z = z + 1
  elseif dir == 2 then x = x - 1 else z = z - 1 end
end

local function up()
  while not turtle.up() do
    if turtle.detectUp() then
      if not turtle.digUp() then error("Nie moge wykopac bloku nade mna") end
    else
      turtle.attackUp()
    end
  end
  y = y + 1
end

local function down()
  while not turtle.down() do
    if turtle.detectDown() then
      if not turtle.digDown() then error("Nie moge wykopac bloku pode mna") end
    else
      turtle.attackDown()
    end
  end
  y = y - 1
end

---------------------------------------------------------------------------
-- Ekwipunek i paliwo

local function isFiller(slot)
  local d = turtle.getItemDetail(slot)
  return d ~= nil and FILLER[d.name] == true
end

local function selectFiller()
  while true do
    for s = 1, 16 do
      if isFiller(s) then turtle.select(s); return end
    end
    print("Brak blokow do zasypywania! Dodaj ziemie/cobble do ekwipunku...")
    _G.ccWaiting = "brak blokow do zasypywania" -- widoczne na SCADA
    os.pullEvent("turtle_inventory")
    _G.ccWaiting = nil
  end
end

local function placeDown()
  for _ = 1, 10 do
    selectFiller()
    if turtle.placeDown() then return end
    turtle.attackDown() -- cos stoi w miejscu bloku
  end
end

local function refuel(needed)
  if turtle.getFuelLevel() == "unlimited" then return end
  while turtle.getFuelLevel() < needed do
    local ok = false
    for s = 1, 16 do
      if turtle.getItemCount(s) > 0 and not isFiller(s) then
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

local function inventoryFull()
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then return false end
  end
  return true
end

-- Gdy ekwipunek pelny: wyrzuc smieci (nie-wypelniacz i nie-paliwo),
-- a jesli to nie wystarczy - jeden pelny stack wypelniacza.
local function makeRoom()
  if not inventoryFull() then return end
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and not isFiller(s) then
      turtle.select(s)
      if not turtle.refuel(0) then turtle.dropUp() end
    end
  end
  if inventoryFull() then
    for s = 16, 1, -1 do
      if isFiller(s) and turtle.getItemCount(s) == 64 then
        turtle.select(s); turtle.dropUp(); break
      end
    end
  end
end

---------------------------------------------------------------------------
-- Praca na jednym polu

-- Wycina kolumne nad zolwiem, dopoki cos tam jest (wzgorze, pien drzewa).
local function clearAbove()
  local h = 0
  while h < MAX_UP and turtle.detectUp() do
    up(); h = h + 1
  end
  for _ = 1, h do down() end
end

-- Zasypuje dziure pod zolwiem od dna w gore.
local function fillBelow()
  local d = 0
  while d < MAX_DOWN and not turtle.detectDown() do
    down(); d = d + 1
  end
  for _ = 1, d do
    up(); placeDown()
  end
end

local function processCell()
  refuel(math.abs(x) + math.abs(z) + 2 * (MAX_UP + MAX_DOWN) + 10)
  makeRoom()
  clearAbove()
  fillBelow()
end

-- Jedzie na poziomie y do punktu (tx, tz) wzgledem startu.
local function goTo(tx, tz)
  if x > tx then face(2) elseif x < tx then face(0) end
  while x ~= tx do forward() end
  if z > tz then face(3) elseif z < tz then face(1) end
  while z ~= tz do forward() end
end

local function goHome()
  goTo(0, 0)
  face(0)
end

---------------------------------------------------------------------------
-- Glowna petla: przejazd "wezykiem"

print(("Wyrownuje obszar %dx%d..."):format(LENGTH, WIDTH))

if CENTER then
  -- dojazd do lewego-dolnego rogu
  refuel(LENGTH + WIDTH + 10)
  goTo(-math.floor((LENGTH - 1) / 2), -math.floor((WIDTH - 1) / 2))
  face(0)
end

for row = 1, WIDTH do
  for col = 1, LENGTH do
    processCell()
    if col < LENGTH then forward() end
  end
  _G.ccProgress = row / WIDTH -- postep dla listenera / SCADA
  if row < WIDTH then
    if row % 2 == 1 then
      turnRight(); forward(); turnRight()
    else
      turnLeft(); forward(); turnLeft()
    end
  end
end

goHome()
print("Gotowe! Teren wyrownany.")

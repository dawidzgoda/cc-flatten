-- remote.lua - pilot na pocket computer
-- Podajesz ID zolwia i wymiary, a zolw zdalnie odpala flatten.

local PROTOCOL = "flatten"
local LAST_FILE = ".remote_last_id"

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Pocket computer nie ma modemu!") end
rednet.open(peripheral.getName(modem))

local function ask(prompt, default)
  if default then write(("%s [%s]: "):format(prompt, default))
  else write(prompt .. ": ") end
  local s = read()
  if s == "" then return default end
  return s
end

-- Ostatnio uzyte ID
local lastId
if fs.exists(LAST_FILE) then
  local f = fs.open(LAST_FILE, "r"); lastId = f.readAll(); f.close()
end

term.clear(); term.setCursorPos(1, 1)
print("== Pilot zolwia ==")

-- Pokaz dostepne zolwie
local found = { rednet.lookup(PROTOCOL) }
if #found > 0 then
  write("Dostepne: ")
  for i, id in ipairs(found) do write(("#%d "):format(id)) end
  print()
else
  print("Nie znaleziono zolwi (daleko?)")
end

local id = tonumber(ask("ID zolwia", lastId or (found[1] and tostring(found[1]))))
if not id then print("Zle ID."); return end
local f = fs.open(LAST_FILE, "w"); f.write(tostring(id)); f.close()

-- Sprawdz, czy zolw odpowiada
rednet.send(id, { cmd = "ping" }, PROTOCOL)
local _, pong = rednet.receive(PROTOCOL, 3)
if type(pong) ~= "table" or pong.cmd ~= "pong" then
  print(("Zolw #%d nie odpowiada."):format(id)); return
end
print(("Zolw #%d OK, paliwo: %s"):format(id, tostring(pong.fuel)))

print("Program: 1) wyrownaj teren  2) pochodnie")
local choice = ask("Wybor", "1")
local program = (choice == "2") and "torches" or "flatten"

local length = tonumber(ask("Dlugosc", "16"))
local width  = tonumber(ask("Szerokosc", "16"))
if not length or not width then print("Zle wymiary."); return end
local spacing
if program == "torches" then
  spacing = tonumber(ask("Odstep pochodni", "5"))
  if not spacing or spacing < 1 then print("Zly odstep."); return end
end
local center = ask("Zolw na srodku? (t/n)", "t"):lower() == "t"

rednet.send(id, {
  cmd = "start", program = program,
  length = length, width = width, spacing = spacing, center = center,
}, PROTOCOL)

print("Czekam... (Ctrl+T aby wyjsc)")
while true do
  local sender, msg = rednet.receive(PROTOCOL)
  if sender == id and type(msg) == "table" then
    if msg.cmd == "started" then
      print(("Zolw #%d pracuje: %dx%d"):format(id, length, width))
    elseif msg.cmd == "done" then
      print(msg.ok and "Gotowe!" or "Zolw przerwal prace (blad).")
      break
    elseif msg.cmd == "error" then
      print("Blad: " .. tostring(msg.text)); break
    end
  end
end

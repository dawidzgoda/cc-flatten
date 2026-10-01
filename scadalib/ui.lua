-- scadalib/ui.lua - monitor, sidebar i podstawowe elementy ekranu
--
-- Ekran:  | SIDEBAR (SB kolumn) | odstep | TRESC (od kolumny cx) |
-- Funkcje z "c" na poczatku (cput, cbutton, ...) i drawRows/numberRow/
-- toggle/header/footer rysuja w obszarze tresci (wspolrzedne wzgledne).

local app = require("scadalib.app")

local ui = {}
local clamp, fit

ui.SB = 14          -- szerokosc sidebara
ui.MIN_W = 52       -- minimum: sidebar + 37 kolumn tresci (suwaki progow)
ui.MIN_H = 14
ui.buttons = {}

---------------------------------------------------------------------------
-- Monitor

function ui.init()
  ui.mon = peripheral.find("monitor")
  if not ui.mon then error("Brak monitora!") end
  if not ui.mon.isColor() then error("Potrzebny ADVANCED monitor (kolorowy)") end
  ui.pickScale()
end

-- Wielkosc tekstu: najwieksza, przy ktorej ekran ma min. 52x18 znakow.
-- Recznie:  set scada.scale 1   (0.5 - 5, co 0.5)
function ui.pickScale()
  local forced = tonumber(settings.get("scada.scale"))
  if forced then ui.mon.setTextScale(forced); return end
  for _, s in ipairs({ 3, 2.5, 2, 1.5, 1, 0.5 }) do
    ui.mon.setTextScale(s)
    local mw, mh = ui.mon.getSize()
    if mw >= 52 and mh >= 18 then return end
  end
end

-- Poczatek klatki: rozmiar, czyszczenie, reset przyciskow
function ui.begin()
  ui.w, ui.h = ui.mon.getSize()
  ui.cx = ui.SB + 2
  ui.cw = ui.w - ui.cx + 1
  ui.buttons = {}
  ui.mon.setBackgroundColor(colors.black)
  ui.mon.clear()
  return ui.w >= ui.MIN_W and ui.h >= ui.MIN_H
end

-- Obsluga dotyku: wykonuje akcje trafionego przycisku
function ui.touch(x, y)
  for _, b in ipairs(ui.buttons) do
    if y == b.y and x >= b.x1 and x <= b.x2 then b.action(); return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Rysowanie (wspolrzedne bezwzgledne)

clamp = app.clamp

function ui.fit(s, n)
  s = tostring(s or "")
  if n <= 0 then return "" end
  if #s > n then return s:sub(1, n) end
  return s .. (" "):rep(n - #s)
end
fit = ui.fit

function ui.put(x, y, s, fg, bg)
  ui.mon.setCursorPos(x, y)
  if bg then ui.mon.setBackgroundColor(bg) end
  if fg then ui.mon.setTextColor(fg) end
  ui.mon.write(s)
end

function ui.button(x, y, label, bg, action, fg)
  ui.put(x, y, label, fg or colors.white, bg)
  ui.buttons[#ui.buttons + 1] = { x1 = x, x2 = x + #label - 1, y = y, action = action }
end

-- Pasek z procentem na koncu (szerokosc lacznie z "100%")
function ui.drawBar(x, y, width, p, col)
  if width < 6 then return end
  local barW = width - 5
  local filled = math.floor(barW * clamp(p, 0, 1) + 0.5)
  ui.put(x, y, (" "):rep(filled), nil, col or colors.lime)
  ui.put(x + filled, y, (" "):rep(barW - filled), nil, colors.gray)
  ui.put(x + barW, y, ("%4d%%"):format(math.floor(p * 100 + 0.5)), colors.white, colors.black)
end

---------------------------------------------------------------------------
-- Obszar tresci (x wzgledne: 1 = pierwsza kolumna tresci)

function ui.cput(x, y, s, fg, bg) ui.put(ui.cx + x - 1, y, s, fg, bg) end
function ui.cbutton(x, y, label, bg, action, fg) ui.button(ui.cx + x - 1, y, label, bg, action, fg) end
function ui.cfill(y, bg) ui.put(ui.cx, y, (" "):rep(ui.cw), nil, bg) end

-- Naglowek tresci: tytul i opcjonalny przycisk WSTECZ
function ui.header(title, back)
  ui.cfill(1, colors.blue)
  ui.cput(2, 1, fit(title, ui.cw - (back and 11 or 2)), colors.white, colors.blue)
  if back then ui.cbutton(ui.cw - 8, 1, " WSTECZ ", colors.gray, back) end
end

-- Stopka tresci: komunikat (10 s) albo tekst domyslny
function ui.footer(default, color)
  ui.cfill(ui.h, colors.gray)
  local m = app.message
  if m and app.now() - m.time < 10000 then
    ui.cput(2, ui.h, fit(m.text, ui.cw - 2), m.color, colors.gray)
  else
    ui.cput(2, ui.h, fit(default, ui.cw - 2), color or colors.white, colors.gray)
  end
end

-- Przewijana lista wierszy w obszarze tresci. Wiersz:
-- { text, fg, bg, right, rfg, action, bar = 0..1, barCol }
-- Zwraca true, jesli lista sie nie miesci (wtedy dodaj scrollButtons).
function ui.drawRows(rows, top, bottom, key)
  local n = bottom - top + 1
  local off = clamp(app.scroll[key] or 0, 0, math.max(0, #rows - n))
  app.scroll[key] = off
  for i = 1, n do
    local r = rows[off + i]
    if not r then break end
    local y = top + i - 1
    local bg = r.bg or colors.black
    if r.bar then
      ui.drawBar(ui.cx + 1, y, ui.cw - 1, r.bar, r.barCol)
    else
      local rightW = r.right and (#r.right + 1) or 0
      local text = " " .. fit(r.text, ui.cw - 1 - rightW)
      if r.action then ui.cbutton(1, y, text, bg, r.action, r.fg)
      else ui.cput(1, y, text, r.fg or colors.white, bg) end
      if r.right then
        ui.put(ui.w - #r.right + 1, y, r.right, r.rfg or r.fg or colors.white, bg)
        if r.action then ui.buttons[#ui.buttons].x2 = ui.w end
      end
    end
  end
  return #rows > n
end

function ui.scrollButtons(key, pageSize)
  ui.cbutton(ui.cw - 7, ui.h, " ^ ", colors.lightGray, function()
    app.scroll[key] = math.max(0, (app.scroll[key] or 0) - (pageSize - 1))
  end, colors.black)
  ui.cbutton(ui.cw - 3, ui.h, " v ", colors.lightGray, function()
    app.scroll[key] = (app.scroll[key] or 0) + (pageSize - 1)
  end, colors.black)
end

-- Wiersz z wartoscia i przyciskami -duzy -maly wartosc +maly +duzy.
-- kp = { title, unit }: wartosc staje sie przyciskiem otwierajacym
-- klawiature numeryczna (wpisanie dokladnej liczby).
function ui.numberRow(y, label, value, set, bigStep, smallStep, kp)
  smallStep = smallStep or 1
  ui.cput(2, y, label, colors.lightGray, colors.black)
  local x = 10
  local function btn(txt, col, v)
    ui.cbutton(x, y, " " .. txt .. " ", col, function() set(v) end)
    x = x + #txt + 3
  end
  btn("-" .. bigStep, colors.red, value - bigStep)
  btn("-" .. smallStep, colors.red, value - smallStep)
  if kp then
    ui.cbutton(x, y, ("%5d"):format(value), colors.gray, function()
      ui.openKeypad({ title = kp.title, unit = kp.unit, value = value, onOk = set })
    end, colors.white)
  else
    ui.cput(x, y, ("%5d"):format(value), colors.white, colors.black)
  end
  x = x + 6
  btn("+" .. smallStep, colors.green, value + smallStep)
  btn("+" .. bigStep, colors.green, value + bigStep)
end

function ui.toggle(x, y, label, active, action)
  ui.cbutton(x, y, label, active and colors.blue or colors.gray, action,
             active and colors.white or colors.lightGray)
end

-- Przycisk na kilka wierszy (latwiej trafic palcem); etykieta w srodku
function ui.bigButton(x, y, width, height, label, bg, action, fg)
  local mid = y + math.floor((height - 1) / 2)
  for r = 0, height - 1 do
    local row = y + r
    local text = row == mid
      and fit((" "):rep(math.floor((width - #label) / 2)) .. label, width)
      or (" "):rep(width)
    ui.cbutton(x, row, text, bg, action, fg)
  end
end

---------------------------------------------------------------------------
-- Klawiatura numeryczna (okno w obszarze tresci)
--
-- ui.openKeypad{ title, unit, value, onOk = function(liczba) }
-- Cyfry dopisuja, C czysci, < kasuje ostatnia cyfre, OK zapisuje
-- (pusty wpis = bez zmian), ANULUJ / WSTECZ zamyka bez zmian.

local KEYPAD_ROWS = { { "7", "8", "9" }, { "4", "5", "6" }, { "1", "2", "3" }, { "C", "0", "<" } }
local KEYPAD_MAX_DIGITS = 6

function ui.openKeypad(opts)
  app.keypad = { title = opts.title or "Wartosc", unit = opts.unit or "",
                 old = opts.value or 0, text = "", onOk = opts.onOk }
end

local function keypadPress(key)
  local k = app.keypad
  if not k then return end
  if key == "C" then
    k.text = ""
  elseif key == "<" then
    k.text = k.text:sub(1, -2)
  elseif #k.text < KEYPAD_MAX_DIGITS then
    k.text = (k.text == "0") and key or (k.text .. key)
  end
end

local function keypadOk()
  local k = app.keypad
  app.keypad = nil
  if k and k.text ~= "" and k.onOk then k.onOk(tonumber(k.text)) end
end

function ui.drawKeypad()
  local k = app.keypad
  local cw, h = ui.cw, ui.h
  ui.header("Wpisz: " .. k.title, function() app.keypad = nil end)

  -- wyswietlacz: wpisywana liczba (albo obecna wartosc na szaro)
  local typing = k.text ~= ""
  local disp = (typing and k.text or tostring(k.old)) .. (k.unit ~= "" and (" " .. k.unit) or "")
  local dw = math.min(cw - 2, 23)
  local dx = math.floor((cw - dw) / 2) + 1
  ui.cput(dx, 3, (" "):rep(dw), nil, colors.lightGray)
  ui.cput(dx + dw - #disp - 1, 3, disp, typing and colors.black or colors.gray, colors.lightGray)
  ui.cput(dx, 4, fit(typing and "OK = zapisz" or "obecnie - wpisz nowa wartosc", dw),
          colors.lightGray, colors.black)

  -- klawisze: 3 kolumny po 7 znakow; wysokosc zalezna od monitora
  local keyW, gap = 7, 1
  local gridW = keyW * 3 + gap * 2
  local gx = math.floor((cw - gridW) / 2) + 1
  local avail = h - 1 - 6                       -- od wiersza 6 do stopki
  local keyH = math.max(1, math.min(3, math.floor((avail - 4) / 5)))
  local vgap = (avail >= keyH * 5 + 4) and 1 or 0
  local y = 6
  for _, row in ipairs(KEYPAD_ROWS) do
    for i, key in ipairs(row) do
      local bg = (key == "C" or key == "<") and colors.orange or colors.gray
      ui.bigButton(gx + (i - 1) * (keyW + gap), y, keyW, keyH, key, bg,
                   function() keypadPress(key) end, colors.white)
    end
    y = y + keyH + vgap
  end
  local half = math.floor((gridW - gap) / 2)
  ui.bigButton(gx, y, half, keyH, "ANULUJ", colors.red, function() app.keypad = nil end, colors.white)
  ui.bigButton(gx + half + gap, y, gridW - half - gap, keyH, "OK", colors.green, keypadOk, colors.white)

  ui.footer("Dotknij cyfr, OK = zapisz")
end

---------------------------------------------------------------------------
-- Sidebar
--
-- entries: { { label, view, badge, alarm, action } ... }  - menu
-- bottom:  { { label, bg, fg, action } ... }              - przyciski na dole

function ui.sidebar(entries, bottom)
  local SB, h = ui.SB, ui.h
  for y = 1, h do ui.put(1, y, (" "):rep(SB), nil, colors.gray) end

  -- naglowek: nazwa + zegar
  local clock = textutils.formatTime(os.time(), true)
  ui.put(1, 1, fit(app.DEMO and " DEMO" or " SCADA", SB - #clock - 1) .. clock .. " ", colors.white, colors.blue)

  local step = h >= 22 and 2 or 1
  local y = 3
  for _, e in ipairs(entries) do
    if y > h - #bottom * step then break end
    local active = app.view == e.view
    local bg, fg = colors.gray, colors.white
    if active then bg, fg = colors.lightBlue, colors.black
    elseif e.alarm then bg, fg = app.blink and colors.red or colors.orange, colors.white end
    local badge = e.badge and tostring(e.badge) or ""
    local text = " " .. fit(e.label, SB - 2 - #badge) .. badge .. " "
    ui.button(1, y, text:sub(1, SB), bg, e.action or function() app.go(e.view) end, fg)
    y = y + step
  end

  -- przyciski na dole sidebara
  local by = h - (#bottom - 1) * step
  for _, b in ipairs(bottom) do
    ui.button(1, by, fit(" " .. b.label, SB), b.bg, b.action, b.fg)
    by = by + step
  end
end

return ui

-- =====================================================================
--  GlideStat - widget EdgeTX dla szybowcow z napedem (TX16S MK3 800x480
--  i inne radia z kolorowym ekranem; uklad i czcionki skaluja sie do strefy)
--
--  Pokazuje:
--   * telemetrie na zywo: wysokosc, wario, napiecie odbiornika, jakosc
--     lacza, liczba satelitow
--   * czas lotu      - z silnikiem / bez silnika / razem
--   * dystans (GPS)  - z silnikiem / bez silnika / razem
--   * zdobyta wysokosc (suma wznoszen) - z silnikiem / bez silnika (termika)
--   * max wysokosc i max wznoszenie podczas szybowania
--
--  Instalacja: skopiuj folder GlideStat do /WIDGETS/ na karcie SD radia.
--
--  Opcje widgetu:
--   MotorSrc - zrodlo silnika (drazek gazu lub kanal ESC, np. CH3)
--   MotorThr - prog w % (-100..100); powyzej progu = silnik pracuje
--   ResetSw  - przelacznik kasujacy statystyki (zbocze narastajace)
--   Hyst     - histereza wysokosci w metrach (filtr szumu barometru)
--   Color    - kolor tekstu
--
--  Reset mozliwy tez dlugim nacisnieciem ENTER w trybie pelnoekranowym.
-- =====================================================================

local NAME = "GlideStat"

-- --- stale konfiguracyjne -------------------------------------------
local MOTOR_OFF_DELAY = 300   -- 3 s (w tickach 10 ms): wznoszenie z rozpedu
                              -- po wylaczeniu silnika nie liczy sie jako termika
local START_CLIMB     = 10    -- m: start lotu bez silnika (hol/gumy/rzut)
local GPS_MIN_STEP    = 5     -- m: minimalny krok GPS (filtr drgan pozycji)
local GPS_MAX_JUMP    = 300   -- m: wiekszy skok = blad GPS, punkt odniesienia od nowa
local GPS_MIN_SATS    = 5     -- min. liczba satelitow, by ufac pozycji
local FIND_INTERVAL   = 200   -- 2 s: ponowne szukanie czujnikow telemetrii

local options = {
  { "MotorSrc", SOURCE, 0 },
  { "MotorThr", VALUE, -80, -100, 100 },
  { "ResetSw",  SWITCH, 0 },
  { "Hyst",     VALUE, 2, 1, 20 },
  { "Color",    COLOR, WHITE },
}

-- nazwy czujnikow (pierwszy znaleziony wygrywa); CRSF/ELRS, INAV, FrSky
local SENSORS = {
  alt  = { "Alt", "GAlt" },
  vspd = { "VSpd" },
  gps  = { "GPS" },
  gspd = { "GSpd" },
  sats = { "Sats" },
  rxbt = { "RxBt", "A1" },
  lq   = { "RQly", "1RSS", "RSSI" },
}

-- --- narzedzia --------------------------------------------------------
local function findSensors(w)
  for key, names in pairs(SENSORS) do
    w.ids[key] = nil
    for _, n in ipairs(names) do
      local fi = getFieldInfo(n)
      if fi then
        w.ids[key] = fi.id
        w.names[key] = n
        break
      end
    end
  end
end

local function getVal(w, key)
  local id = w.ids[key]
  if id then return getValue(id) end
  return nil
end

-- odleglosc dla malych krokow (przyblizenie rownoprostokatne), w metrach
local function distance(lat1, lon1, lat2, lon2)
  local rad = math.pi / 180
  local x = (lon2 - lon1) * rad * math.cos((lat1 + lat2) * 0.5 * rad)
  local y = (lat2 - lat1) * rad
  return 6371000 * math.sqrt(x * x + y * y)
end

local function fmtTime(s)
  s = math.floor(s)
  local h = math.floor(s / 3600)
  local m = math.floor((s % 3600) / 60)
  local sec = s % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
  return string.format("%02d:%02d", m, sec)
end

local function fmtDist(m)
  if m < 1000 then return string.format("%d m", math.floor(m + 0.5)) end
  return string.format("%.2f km", m / 1000)
end

local function fmtAlt(m)
  return string.format("%d m", math.floor(m + 0.5))
end

-- --- statystyki -------------------------------------------------------
local function resetStats(w)
  w.flying = false
  w.tMotor, w.tGlide = 0, 0     -- s
  w.dMotor, w.dGlide = 0, 0     -- m
  w.gMotor, w.gGlide = 0, 0     -- m zdobytej wysokosci
  w.maxAlt = nil
  w.maxVspd = 0
  w.refAlt = nil
  w.startAlt = nil
  w.lastLat, w.lastLon = nil, nil
  w.motorOffTick = nil
  w.prevMotor = nil
  w.lastTick = getTime()
end

local function updateStats(w)
  local now = getTime()
  local dt = (now - (w.lastTick or now)) / 100
  w.lastTick = now
  if dt < 0 or dt > 5 then dt = 0 end

  local opt = w.options

  -- reset przelacznikiem
  if opt.ResetSw and opt.ResetSw ~= 0 and getSwitchValue then
    local on = getSwitchValue(opt.ResetSw)
    if on and not w.resetPrev then resetStats(w) end
    w.resetPrev = on
  end

  -- czujniki moga pojawic sie dopiero po polaczeniu
  if now - w.lastFind > FIND_INTERVAL then
    findSensors(w)
    w.lastFind = now
  end

  local link = getRSSI() > 0
  w.link = link

  -- stan silnika
  local motor = false
  if opt.MotorSrc and opt.MotorSrc ~= 0 then
    local v = getValue(opt.MotorSrc) or 0
    motor = v > opt.MotorThr * 10.24
  end
  w.motor = motor

  local alt  = link and getVal(w, "alt") or nil
  local vspd = link and getVal(w, "vspd") or nil
  w.alt, w.vspd = alt, vspd

  -- start lotu: pierwsze wlaczenie silnika albo wyrazne wznoszenie
  if not w.flying and link then
    if alt and not w.startAlt then w.startAlt = alt end
    if motor or (alt and w.startAlt and alt - w.startAlt > START_CLIMB) then
      w.flying = true
    end
  end

  -- zmiana trybu silnik <-> szybowanie
  if w.prevMotor ~= nil and w.prevMotor ~= motor then
    w.refAlt = nil
    if not motor then w.motorOffTick = now end
  end
  w.prevMotor = motor
  local inDelay = (not motor) and w.motorOffTick ~= nil
                  and (now - w.motorOffTick < MOTOR_OFF_DELAY)
  w.inDelay = inDelay

  if not (w.flying and link) then return end

  -- czas
  if motor then w.tMotor = w.tMotor + dt else w.tGlide = w.tGlide + dt end

  -- zdobyta wysokosc: sumujemy wznoszenia wieksze od histerezy,
  -- liczone od lokalnego minimum
  if alt then
    if not w.maxAlt or alt > w.maxAlt then w.maxAlt = alt end
    local hyst = opt.Hyst or 2
    if inDelay or w.refAlt == nil or alt < w.refAlt then
      w.refAlt = alt
    elseif alt - w.refAlt >= hyst then
      local g = alt - w.refAlt
      if motor then w.gMotor = w.gMotor + g else w.gGlide = w.gGlide + g end
      w.refAlt = alt
    end
  end

  if vspd and not motor and not inDelay and vspd > w.maxVspd then
    w.maxVspd = vspd
  end

  -- dystans: GPS, a gdy brak fixu - calkowanie predkosci GSpd (km/h)
  local d = 0
  local gps = getVal(w, "gps")
  local sats = getVal(w, "sats")
  if type(gps) == "table" and gps.lat and gps.lon and gps.lat ~= 0
     and (sats == nil or sats >= GPS_MIN_SATS) then
    if w.lastLat then
      local step = distance(w.lastLat, w.lastLon, gps.lat, gps.lon)
      if step > GPS_MAX_JUMP then
        w.lastLat, w.lastLon = gps.lat, gps.lon
      elseif step >= GPS_MIN_STEP then
        d = step
        w.lastLat, w.lastLon = gps.lat, gps.lon
      end
    else
      w.lastLat, w.lastLon = gps.lat, gps.lon
    end
  else
    w.lastLat, w.lastLon = nil, nil
    local gs = getVal(w, "gspd")
    if gs and gs > 2 then d = gs / 3.6 * dt end
  end
  if motor then w.dMotor = w.dMotor + d else w.dGlide = w.dGlide + d end
end

-- --- rysowanie --------------------------------------------------------
local function txt(x, y, s, flags, color)
  lcd.setColor(CUSTOM_COLOR, color)
  lcd.drawText(math.floor(x), math.floor(y), s, (flags or 0) + CUSTOM_COLOR)
end

local function stateInfo(w)
  if not w.link then return "BRAK TELEM.", w.colDim end
  if w.motor then return "SILNIK", w.colMotor end
  if w.inDelay then return "WYLACZONY", w.colWarn end
  return "SZYBOWANIE", w.colGlide
end

-- wysokosc czcionki (lcd.sizeText gdy dostepne, inaczej szacunek)
local FONT_H = { [SMLSIZE] = 13, [0] = 18, [MIDSIZE] = 26, [DBLSIZE] = 36 }
local function textH(f)
  if lcd.sizeText then
    local _, h = lcd.sizeText("0", f)
    if h and h > 0 then return h end
  end
  return FONT_H[f] or 18
end

local function textW(s, f)
  if lcd.sizeText then
    local w = lcd.sizeText(s, f)
    if w then return w end
  end
  return #s * (FONT_H[f] or 18) * 0.6
end

-- najwieksza czcionka z listy, w ktorej wszystkie teksty mieszcza sie w maxW / maxH
local function fitFont(texts, maxW, maxH, fonts)
  for _, f in ipairs(fonts) do
    local ok = textH(f) <= maxH
    if ok then
      for _, s in ipairs(texts) do
        if textW(s, f) > maxW then ok = false break end
      end
    end
    if ok then return f end
  end
  return fonts[#fonts]
end

local BIG_FONTS = { DBLSIZE, MIDSIZE, 0, SMLSIZE }
local SML_FONTS = { MIDSIZE, 0, SMLSIZE }

local function drawFull(w)
  local z = w.zone
  local x0, y0, W, H = z.x, z.y, z.w, z.h
  local fg = w.options.Color
  -- skala wzgledem projektu 480x272 (800x480 -> ok. 1.67)
  local s = math.min(W / 480, H / 272)
  local function S(v) return math.floor(v * s + 0.5) end
  local pad = S(4)

  -- ---- pasek stanu ----
  local barH = S(34)
  local label, col = stateInfo(w)
  local bw = S(130)
  lcd.setColor(CUSTOM_COLOR, col)
  lcd.drawFilledRectangle(x0 + 2, y0 + 2, bw, barH - 4, CUSTOM_COLOR)
  local fb = fitFont({ "BRAK TELEM.", "SZYBOWANIE" }, bw - 6, barH - 6, SML_FONTS)
  txt(x0 + 2 + bw / 2, y0 + 2 + (barH - 4 - textH(fb)) / 2, label, fb + CENTER, w.colBlack)

  local altS = w.alt and fmtAlt(w.alt) or "--- m"
  local vs = w.vspd
  local vsS = vs and string.format("%+.1f m/s", vs) or "--- m/s"
  local xAlt = x0 + bw + S(12)
  local slot = math.floor(W * 0.24)
  local ft = fitFont({ "8888 m", "+88.8 m/s" }, slot - S(8), barH, BIG_FONTS)
  local yt = y0 + (barH - textH(ft)) / 2
  txt(xAlt, yt, altS, ft, fg)
  txt(xAlt + slot, yt, vsS, ft,
      (vs and vs > 0.2) and w.colGlide or ((vs and vs < -0.2) and w.colMotor or fg))

  local rx = getVal(w, "rxbt")
  local lq = getVal(w, "lq")
  local sat = getVal(w, "sats")
  local info1 = "RxBt " .. (rx and w.link and string.format("%.1fV", rx) or "--")
  local info2 = (w.names.lq or "LQ") .. " " .. (lq and w.link and tostring(lq) or "--")
                .. "  Sat " .. (sat and w.link and tostring(sat) or "--")
  local infoW = x0 + W - (xAlt + 2 * slot) - pad
  local fi = fitFont({ info1, info2 }, infoW, barH / 2, SML_FONTS)
  local ih = textH(fi)
  txt(x0 + W - pad, y0 + barH / 2 - ih, info1, fi + RIGHT, fg)
  txt(x0 + W - pad, y0 + barH / 2, info2, fi + RIGHT, fg)

  -- ---- tabela ----
  local c1 = x0 + math.floor(W * 0.47)
  local c2 = x0 + math.floor(W * 0.74)
  local c3 = x0 + W - pad - 2
  local colW = math.floor(W * 0.26) - S(10)

  local fh = fitFont({ "Bez silnika" }, colW, S(20), SML_FONTS)
  local ty = y0 + barH + S(6)
  txt(c1, ty, "Silnik", fh + RIGHT, w.colMotor)
  txt(c2, ty, "Bez silnika", fh + RIGHT, w.colGlide)
  txt(c3, ty, "Razem", fh + RIGHT, w.colDim)

  local footerTxt = "Max wys.: " .. (w.maxAlt and fmtAlt(w.maxAlt) or "--")
      .. "    Max wznosz.: " .. string.format("%.1f m/s", w.maxVspd)
  local ff = fitFont({ footerTxt }, W * 0.68, S(22), SML_FONTS)
  local footerH = textH(ff) + S(8)

  local rowTop = ty + textH(fh) + S(6)
  local rowH = math.floor((y0 + H - footerH - rowTop) / 3)

  local rows = {
    { "Czas lotu", fmtTime(w.tMotor), fmtTime(w.tGlide), fmtTime(w.tMotor + w.tGlide) },
    { "Dystans",   fmtDist(w.dMotor), fmtDist(w.dGlide), fmtDist(w.dMotor + w.dGlide) },
    { "Wznios",    fmtAlt(w.gMotor),  fmtAlt(w.gGlide),  fmtAlt(w.gMotor + w.gGlide) },
  }
  local vals = { "8:88:88", "888.88 km", "8888 m" }   -- rezerwa na najszersze wartosci
  for _, r in ipairs(rows) do
    for j = 2, 4 do vals[#vals + 1] = r[j] end
  end
  local fv = fitFont(vals, colW, rowH - S(6), BIG_FONTS)
  local fl = fitFont({ "Czas lotu", "Dystans", "Wznios" },
                     c1 - colW - x0 - pad, rowH - S(6), SML_FONTS)

  for i, r in ipairs(rows) do
    local y = rowTop + (i - 1) * rowH
    lcd.setColor(CUSTOM_COLOR, w.colLine)
    lcd.drawLine(x0 + 2, y, x0 + W - 2, y, SOLID, CUSTOM_COLOR)
    local yv = y + (rowH - textH(fv)) / 2
    txt(x0 + pad, y + (rowH - textH(fl)) / 2, r[1], fl, w.colDim)
    txt(c1, yv, r[2], fv + RIGHT, fg)
    txt(c2, yv, r[3], fv + RIGHT, w.colGlide)
    txt(c3, yv, r[4], fv + RIGHT, fg)
  end

  -- ---- stopka ----
  local fy = y0 + H - footerH + S(4)
  lcd.setColor(CUSTOM_COLOR, w.colLine)
  lcd.drawLine(x0 + 2, fy - S(3), x0 + W - 2, fy - S(3), SOLID, CUSTOM_COLOR)
  txt(x0 + pad, fy, footerTxt, ff, fg)
  if not w.options.MotorSrc or w.options.MotorSrc == 0 then
    txt(x0 + W - pad, fy, "Ustaw MotorSrc!", ff + RIGHT, w.colWarn)
  elseif not w.flying then
    txt(x0 + W - pad, fy, "czeka na start", ff + RIGHT, w.colDim)
  end
end

local function drawCompact(w)
  local z = w.zone
  local x0, y0, W, H = z.x, z.y, z.w, z.h
  local fg = w.options.Color

  local label, col = stateInfo(w)
  local lines = {
    { label .. "  " .. (w.alt and fmtAlt(w.alt) or "---"), col },
    { "Termika: +" .. fmtAlt(w.gGlide), w.colGlide },
    { "Szyb.: " .. fmtTime(w.tGlide) .. "  " .. fmtDist(w.dGlide), fg },
    { "Silnik: " .. fmtTime(w.tMotor) .. "  " .. fmtDist(w.dMotor), fg },
    { "Lot: " .. fmtTime(w.tMotor + w.tGlide), fg },
  }
  -- dobierz czcionke tak, by zmiescily sie co najmniej 4 linie
  local texts = {}
  for i = 1, 4 do texts[i] = lines[i][1] end
  local f = fitFont(texts, W - 4, H / 4 - 2, BIG_FONTS)
  local lh = textH(f) + 2
  local n = math.max(1, math.floor(H / lh))
  for i = 1, math.min(n, #lines) do
    txt(x0 + 2, y0 + (i - 1) * lh, lines[i][1], f, lines[i][2])
  end
end

-- --- API widgetu ------------------------------------------------------
local function create(zone, opts)
  local w = {
    zone = zone, options = opts, ids = {}, names = {}, lastFind = 0,
    colMotor = lcd.RGB(235, 70, 60),
    colGlide = lcd.RGB(60, 210, 100),
    colWarn  = lcd.RGB(240, 200, 40),
    colDim   = lcd.RGB(160, 160, 160),
    colLine  = lcd.RGB(80, 80, 80),
    colBlack = lcd.RGB(0, 0, 0),
  }
  findSensors(w)
  resetStats(w)
  return w
end

local function update(w, opts)
  w.options = opts
end

local function background(w)
  updateStats(w)
end

local function refresh(w, event, touchState)
  updateStats(w)
  if event and EVT_VIRTUAL_ENTER_LONG and event == EVT_VIRTUAL_ENTER_LONG then
    resetStats(w)
  end
  if w.zone.w >= 380 and w.zone.h >= 150 then
    drawFull(w)
  else
    drawCompact(w)
  end
end

return {
  name = NAME,
  options = options,
  create = create,
  update = update,
  background = background,
  refresh = refresh,
}

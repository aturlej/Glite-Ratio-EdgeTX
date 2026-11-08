-- =====================================================================
--  GlideStat - widget EdgeTX dla szybowcow z napedem (TX16S MK3 i inne
--  radia z kolorowym ekranem)
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
  lcd.drawText(x, y, s, (flags or 0) + CUSTOM_COLOR)
end

local function stateInfo(w)
  if not w.link then return "BRAK TELEM.", w.colDim end
  if w.motor then return "SILNIK", w.colMotor end
  if w.inDelay then return "WYLACZONY", w.colWarn end
  return "SZYBOWANIE", w.colGlide
end

local function drawFull(w)
  local z = w.zone
  local x0, y0, W, H = z.x, z.y, z.w, z.h
  local fg = w.options.Color
  local big = W >= 440 and MIDSIZE or 0

  -- pasek stanu
  local label, col = stateInfo(w)
  lcd.setColor(CUSTOM_COLOR, col)
  lcd.drawFilledRectangle(x0 + 2, y0 + 2, 128, 30, CUSTOM_COLOR)
  txt(x0 + 66, y0 + 7, label, CENTER, w.colBlack)

  txt(x0 + 140, y0 + 1,
      w.alt and fmtAlt(w.alt) or "--- m", MIDSIZE, fg)
  local vs = w.vspd
  txt(x0 + 140 + W * 0.22, y0 + 1,
      vs and string.format("%+.1f m/s", vs) or "--- m/s", MIDSIZE,
      (vs and vs > 0.2) and w.colGlide or ((vs and vs < -0.2) and w.colMotor or fg))

  local rx = getVal(w, "rxbt")
  local lq = getVal(w, "lq")
  local sat = getVal(w, "sats")
  txt(x0 + W - 4, y0 + 1,
      "RxBt " .. (rx and w.link and string.format("%.1fV", rx) or "--"),
      SMLSIZE + RIGHT, fg)
  txt(x0 + W - 4, y0 + 17,
      (w.names.lq or "LQ") .. " " .. (lq and w.link and tostring(lq) or "--")
      .. "  Sat " .. (sat and w.link and tostring(sat) or "--"),
      SMLSIZE + RIGHT, fg)

  -- tabela
  local ty = y0 + 40
  local c1 = x0 + math.floor(W * 0.47)
  local c2 = x0 + math.floor(W * 0.74)
  local c3 = x0 + W - 6
  txt(c1, ty, "Silnik", SMLSIZE + RIGHT, w.colMotor)
  txt(c2, ty, "Bez silnika", SMLSIZE + RIGHT, w.colGlide)
  txt(c3, ty, "Razem", SMLSIZE + RIGHT, w.colDim)

  local footerH = 22
  local rowTop = ty + 18
  local rowH = math.min(42, math.floor((H - (rowTop - y0) - footerH) / 3))
  local font = (big ~= 0 and rowH >= 28) and MIDSIZE or 0
  local labelDy = font == MIDSIZE and 6 or 0

  local rows = {
    { "Czas lotu", fmtTime(w.tMotor), fmtTime(w.tGlide), fmtTime(w.tMotor + w.tGlide) },
    { "Dystans",   fmtDist(w.dMotor), fmtDist(w.dGlide), fmtDist(w.dMotor + w.dGlide) },
    { "Wznios",    fmtAlt(w.gMotor),  fmtAlt(w.gGlide),  fmtAlt(w.gMotor + w.gGlide) },
  }
  for i, r in ipairs(rows) do
    local y = rowTop + (i - 1) * rowH
    lcd.setColor(CUSTOM_COLOR, w.colLine)
    lcd.drawLine(x0 + 2, y - 1, x0 + W - 2, y - 1, SOLID, CUSTOM_COLOR)
    txt(x0 + 4, y + labelDy, r[1], 0, w.colDim)
    txt(c1, y, r[2], font + RIGHT, fg)
    txt(c2, y, r[3], font + RIGHT, w.colGlide)
    txt(c3, y, r[4], font + RIGHT, fg)
  end

  -- stopka
  local fy = y0 + H - footerH + 2
  txt(x0 + 4, fy,
      "Max wys.: " .. (w.maxAlt and fmtAlt(w.maxAlt) or "--")
      .. "    Max wznosz.: " .. string.format("%.1f m/s", w.maxVspd),
      SMLSIZE, fg)
  if not w.options.MotorSrc or w.options.MotorSrc == 0 then
    txt(x0 + W - 4, fy, "Ustaw MotorSrc!", SMLSIZE + RIGHT, w.colWarn)
  elseif not w.flying then
    txt(x0 + W - 4, fy, "czeka na start", SMLSIZE + RIGHT, w.colDim)
  end
end

local function drawCompact(w)
  local z = w.zone
  local x0, y0, W, H = z.x, z.y, z.w, z.h
  local fg = w.options.Color
  local font = H < 90 and SMLSIZE or 0
  local lh = H < 90 and 15 or 21

  local label, col = stateInfo(w)
  local lines = {
    { label .. "  " .. (w.alt and fmtAlt(w.alt) or "---"), col },
    { "Termika: +" .. fmtAlt(w.gGlide), w.colGlide },
    { "Szyb.: " .. fmtTime(w.tGlide) .. "  " .. fmtDist(w.dGlide), fg },
    { "Silnik: " .. fmtTime(w.tMotor) .. "  " .. fmtDist(w.dMotor), fg },
    { "Lot: " .. fmtTime(w.tMotor + w.tGlide), fg },
  }
  local n = math.max(1, math.floor(H / lh))
  for i = 1, math.min(n, #lines) do
    txt(x0 + 2, y0 + (i - 1) * lh, lines[i][1], font, lines[i][2])
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

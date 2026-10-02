--[[ Wrekkit :: ui/threatframes

Threat where you are already looking: on the target frame, on the
nameplates, and -- when it matters -- across the middle of the screen.

  target frame   a percentage badge and a coloured border around whichever
                 target frame is in use: pfUI's, the stock one, or any frame
                 named in settings (Luna, XPerl, ...)
  nameplates     a percentage beside each mob's plate, or the plate's own
                 health bar tinted by threat. Works on the stock plates and
                 on ShaguPlates and pfUI's, picked in settings or found on
                 its own. The target's is live; a mob you tabbed off keeps
                 its last reading, dimmed, for a few seconds; a tank sees
                 every mob they hold, and LOST on one that turned away.
  warnings       large text and a red edge around the screen when you cross
                 a line, pull aggro, or -- tanking -- lose a mob

Everything is drawn on frames of our own. The one exception is the plate
health-bar tint, which is the point of that option; it is put back the way
the plate addon had it as soon as it is switched off or the mob drops out.
]]

local W = Wrekkit
local UI = W.ui
UI.threatFrames = {}
local TF = UI.threatFrames

local T = W.threat

local TICK = 0.1          -- seconds between plate / frame updates
local MESSAGE_TIME = 2.2  -- seconds a warning stays up before fading
local FLASH_TIME = 1.2

local PLATE_BORDER = "Interface\\Tooltips\\Nameplate-Border"

----------------------------------------------------------------------
-- target frame
----------------------------------------------------------------------

--[[ The target frame to decorate: a name from settings, then pfUI's, then
     the stock one. The candidate list is rebuilt only when the setting
     changes, since this is asked ten times a second. ]]
local candidates, candidatesFor = {}, nil

function TF:TargetFrame()
  local s = T:Settings()
  if candidatesFor ~= s.frameName then
    candidatesFor = s.frameName
    candidates = {}
    if s.frameName ~= "" then table.insert(candidates, s.frameName) end
    table.insert(candidates, "pfTarget")
    table.insert(candidates, "TargetFrame")
  end
  if not getglobal then return nil end
  for i = 1, table.getn(candidates) do
    local f = getglobal(candidates[i])
    if type(f) == "table" and f.IsVisible and f:IsVisible() then return f end
  end
  return nil
end

--[[ The indicator: the number, a slim bar under it, and a soft glow.

     No box around the target frame. The first version drew four strips
     around the whole frame and a bordered square for the number, which
     read as a debug overlay rather than part of the UI. This is drawn the
     way unit-frame addons draw their own text -- outlined type straight
     on the art, a hairline bar for the fill, colour doing the talking --
     so it sits on any target frame without fighting it.

     Three looks (Settings -> Threat -> Style):
       clean   number with a slim bar under it (default)
       number  the number alone
       badge   number on a soft dark plate, for busy frames

     It is placed relative to the target frame, wherever you drag it: the
     offset is saved, so it follows the frame if the frame moves, and the
     frame can be the stock one, pfUI's, or any named in settings. ]]

local BASE_W, BASE_H = 54, 22

function TF:CreateIndicator()
  if self.ind then return self.ind end
  local ind = CreateFrame("Button", "WrekkitThreatTarget", UIParent)
  ind:SetFrameStrata("HIGH")
  ind:SetWidth(BASE_W) ind:SetHeight(BASE_H)
  ind:SetMovable(true)
  ind:SetClampedToScreen(true)
  ind:Hide()
  self.ind = ind

  -- Soft glow behind the number, coloured by level.
  ind.glow = ind:CreateTexture(nil, "BACKGROUND")
  ind.glow:SetTexture(UI.media.glow)
  ind.glow:SetBlendMode("ADD")
  ind.glow:SetPoint("CENTER", ind, "CENTER", 0, 2)

  -- The badge style's plate: dark, translucent, no hard border.
  ind.plate = ind:CreateTexture(nil, "BORDER")
  ind.plate:SetTexture(UI.media.white)
  ind.plate:SetVertexColor(0, 0, 0, 0.55)
  ind.plate:SetAllPoints(ind)

  ind.text = ind:CreateFontString(nil, "OVERLAY")
  ind.text:SetFont(UI.font, 14, "OUTLINE")
  ind.text:SetJustifyH("CENTER")
  ind.text:SetShadowColor(0, 0, 0, 0.8)
  ind.text:SetShadowOffset(1, -1)

  -- The bar: a dim track and a fill along it.
  ind.track = ind:CreateTexture(nil, "ARTWORK")
  ind.track:SetTexture(UI.media.white)
  ind.track:SetVertexColor(0, 0, 0, 0.6)
  ind.fill = ind:CreateTexture(nil, "OVERLAY")
  ind.fill:SetTexture(UI.media.bar)

  -- The tank's other mobs, in one line: "4 held  1 slipping  1 loose".
  ind.summary = ind:CreateFontString(nil, "OVERLAY")
  ind.summary:SetFont(UI.font, 10, "OUTLINE")
  ind.summary:SetPoint("TOP", ind, "BOTTOM", 0, -1)
  ind.summary:Hide()

  -- Shown only while it is being placed.
  ind.outline = ind:CreateTexture(nil, "BACKGROUND")
  ind.outline:SetTexture(UI.media.white)
  ind.outline:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 0.18)
  ind.outline:SetAllPoints(ind)
  ind.hint = ind:CreateFontString(nil, "OVERLAY")
  ind.hint:SetFont(UI.font, 10, "OUTLINE")
  ind.hint:SetPoint("TOP", ind, "BOTTOM", 0, -3)
  ind.hint:SetTextColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 1)
  ind.hint:SetText("drag to place  -  right-click to lock")

  ind:RegisterForDrag("LeftButton")
  ind:RegisterForClicks("RightButtonUp")
  ind:SetScript("OnDragStart", function()
    if TF.moving then ind:StartMoving() end
  end)
  ind:SetScript("OnDragStop", function()
    ind:StopMovingOrSizing()
    TF:SavePlacement()
  end)
  ind:SetScript("OnClick", function()
    if TF.moving then TF:SetMoving(false) end
  end)
  return ind
end

--- Size, type and the style's parts. Re-done only when a setting changes.
function TF:StyleIndicator()
  local ind = self.ind
  local s = T:Settings()
  local sc = s.frameScale
  local key = s.frameStyle .. ":" .. sc .. ":" .. tostring(s.frameGlow)
  if self.indStyle == key then return end
  self.indStyle = key

  local w, h = math.floor(BASE_W * sc + 0.5), math.floor(BASE_H * sc + 0.5)
  ind:SetWidth(w) ind:SetHeight(h)
  ind.text:SetFont(UI.font, math.floor(14 * sc + 0.5), "OUTLINE")
  ind.summary:SetFont(UI.font, math.floor(10 * sc + 0.5), "OUTLINE")
  ind.glow:SetWidth(w * 1.9) ind.glow:SetHeight(h * 2.4)

  local bar = (s.frameStyle == "clean")
  local barH = math.max(2, math.floor(3 * sc + 0.5))
  ind.text:ClearAllPoints()
  if bar then
    ind.text:SetPoint("CENTER", ind, "CENTER", 0, barH)
    ind.track:ClearAllPoints()
    ind.track:SetPoint("BOTTOMLEFT", ind, "BOTTOMLEFT", 4, 1)
    ind.track:SetPoint("BOTTOMRIGHT", ind, "BOTTOMRIGHT", -4, 1)
    ind.track:SetHeight(barH)
    ind.fill:ClearAllPoints()
    ind.fill:SetPoint("TOPLEFT", ind.track, "TOPLEFT", 0, 0)
    ind.fill:SetPoint("BOTTOMLEFT", ind.track, "BOTTOMLEFT", 0, 0)
    ind.track:Show() ind.fill:Show()
  else
    ind.text:SetPoint("CENTER", ind, "CENTER", 0, 0)
    ind.track:Hide() ind.fill:Hide()
  end
  if s.frameStyle == "badge" then ind.plate:Show() else ind.plate:Hide() end
  if s.frameGlow then ind.glow:Show() else ind.glow:Hide() end
end

--[[ Where it goes. Dragged once, it keeps that offset from the target
     frame's centre. Never dragged, it sits just above the frame. With no
     target frame to hang from -- placing it before anything is targeted --
     it goes where it was last seen, or the middle of the screen. ]]
function TF:PlaceIndicator(target)
  local ind = self.ind
  local s = T:Settings()
  local key = tostring(target) .. ":" .. tostring(s.frameX) .. ":" .. tostring(s.frameY)
  if self.indPlaced == key or (self.moving and self.dragging) then return end
  self.indPlaced = key
  ind:ClearAllPoints()
  if target and s.frameX then
    ind:SetPoint("CENTER", target, "CENTER", s.frameX, s.frameY)
  elseif target then
    ind:SetPoint("BOTTOM", target, "TOP", 0, 4)
  else
    ind:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  end
end

--- Store the dragged position as an offset from the target frame.
function TF:SavePlacement()
  local ind = self.ind
  local target = self:TargetFrame() or self.lastTarget
  if not ind or not target then return end
  local ix, iy = ind:GetCenter()
  local tx, ty = target:GetCenter()
  if not (ix and tx) then return end
  -- Into the indicator's own units: the target frame may be scaled.
  local k = (target:GetEffectiveScale() or 1) / (ind:GetEffectiveScale() or 1)
  local s = T:Settings()
  s.frameX = math.floor(ix - tx * k + 0.5)
  s.frameY = math.floor(iy - ty * k + 0.5)
  self.indPlaced = nil
end

--- Forget the dragged position: back to just above the frame.
function TF:ResetPlacement()
  local s = T:Settings()
  s.frameX, s.frameY = nil, nil
  self.indPlaced = nil
  self:UpdateIndicator()
end

--[[ Placement mode: the indicator shows a sample reading, takes the mouse,
     and says how to finish. Out of it, the indicator ignores the mouse
     entirely, so it can never eat a click meant for the target frame. ]]
function TF:SetMoving(on)
  self.moving = on and true or nil
  local ind = self:CreateIndicator()
  ind:EnableMouse(self.moving and true or false)
  if self.moving then
    ind.outline:Show() ind.hint:Show()
    W.Print("drag the threat % where you want it; right-click it to lock.")
  else
    ind.outline:Hide() ind.hint:Hide()
    self:SavePlacement()
    W.Print("threat % locked in place.")
  end
  self.indPlaced = nil
  self:UpdateIndicator()
  -- The taunt popup is placed in the same pass, with a sample showing.
  if UI.taunt then UI.taunt:Update() end
  if UI.settings and UI.settings.Refresh then UI.settings:Refresh() end
end

local SAMPLE_COLOR = { 1.00, 0.55, 0.10 }

function TF:UpdateIndicator()
  local s = T:Settings()
  local ind = self.ind
  local cur = s.enabled and s.frame and T:Live()
  local pct, color, text
  if cur then
    local _
    pct, color, _, text = T:Display(cur)
  end
  if self.moving and not pct then
    pct, color, text = 82, SAMPLE_COLOR, "82%"
  end
  local target = self:TargetFrame()
  if target then self.lastTarget = target end
  if not pct or (not target and not self.moving) then
    if ind and ind:IsShown() then ind:Hide() end
    return
  end

  ind = self:CreateIndicator()
  if not self.moving then
    ind.outline:Hide() ind.hint:Hide()
  end
  self:StyleIndicator()
  self:PlaceIndicator(target)

  ind.text:SetText(text)
  ind.text:SetTextColor(color[1], color[2], color[3], 1)

  local summary, sumColor = T:MobSummary()
  if self.moving and not summary then summary, sumColor = "4 held  1 slipping", T.TANK_COLOR end
  if summary and not self.moving then
    ind.summary:SetText(summary)
    ind.summary:SetTextColor(sumColor[1], sumColor[2], sumColor[3], 1)
    ind.summary:Show()
  elseif self.moving then
    ind.summary:Hide()
  else
    ind.summary:Hide()
  end

  if s.frameStyle == "clean" then
    local f = (pct or 0) / 100
    if f > 1 then f = 1 elseif f < 0.02 then f = 0.02 end
    local trackW = ind.track:GetWidth() or (ind:GetWidth() - 8)
    if not trackW or trackW <= 0 then trackW = ind:GetWidth() - 8 end
    ind.fill:SetWidth(trackW * f)
    ind.fill:SetVertexColor(color[1], color[2], color[3], 1)
  end

  if s.frameGlow then
    -- Red breathes; anything calmer glows steady and faint.
    local a = 0.35
    if color == T.RED then a = 0.35 + 0.35 * math.abs(math.sin(GetTime() * 4)) end
    ind.glow:SetVertexColor(color[1], color[2], color[3], a)
  end
  if not ind:IsShown() then ind:Show() end
end

----------------------------------------------------------------------
-- nameplates
----------------------------------------------------------------------

--[[ Plates are children of WorldFrame. The client creates them as mobs come
     into view and reuses them after; it never destroys one. So only the
     children added since the last look need checking -- the count says how
     many -- which is the same trick ShaguPlates and pfUI use, and it means
     the usual pass builds no table at all. ]]
TF.plates = {}     -- every plate seen, in the order found
local plateSet = {}
local scanned = 0

--- Is this child of WorldFrame a nameplate? The plate's first region is
--- its border texture, which no other frame there carries.
local function isPlate(frame)
  local ok, result = pcall(function()
    if frame:GetName() then return false end
    local region = frame:GetRegions()
    if not region or not region.GetTexture then return false end
    return region:GetTexture() == PLATE_BORDER
  end)
  return ok and result == true
end

function TF:ScanPlates()
  if not WorldFrame or not WorldFrame.GetChildren then return end
  local n = WorldFrame.GetNumChildren and WorldFrame:GetNumChildren()
  if n and n <= scanned then return end
  local kids = { WorldFrame:GetChildren() }
  local total = table.getn(kids)
  for i = (n and scanned or 0) + 1, total do
    local k = kids[i]
    if k and not plateSet[k] and isPlate(k) then
      plateSet[k] = true
      table.insert(self.plates, k)
    end
  end
  scanned = total
end

--[[ Which plate addon is drawing this plate.

     ShaguPlates and pfUI share one design: each hangs its own frame on the
     stock plate as plate.nameplate, hides the stock health bar, and draws
     its own as plate.nameplate.health. "auto" uses theirs when it is
     there; forcing "stock" ignores it, and forcing "shagu" falls back to
     the stock bar on a plate they have not dressed yet. ]]
local function customPlate(plate)
  local np = plate.nameplate
  if type(np) == "table" and type(np.health) == "table" and np.health.SetStatusBarColor then
    return np
  end
  return nil
end

--- The health bar actually on screen for a plate.
local function healthBar(plate, style)
  if style ~= "stock" then
    local np = customPlate(plate)
    if np then return np.health, np end
  end
  if plate.wrekStockBar == nil then
    local bar = plate.GetChildren and plate:GetChildren()
    plate.wrekStockBar = (bar and bar.SetStatusBarColor) and bar or false
  end
  return plate.wrekStockBar or nil, nil
end

--- The mob a plate belongs to. SuperWoW names the plate's unit outright;
--- without it, the name on the plate is the best there is.
local function plateKey(plate)
  local ok, guid = pcall(plate.GetName, plate, 1)
  if ok and type(guid) == "string" and string.sub(guid, 1, 2) == "0x" then
    return guid, guid
  end
  if plate.wrekNameText == nil then
    local _, _, nameText = plate:GetRegions()
    plate.wrekNameText = (nameText and nameText.GetText) and nameText or false
  end
  local fs = plate.wrekNameText
  local name = fs and fs:GetText()
  if not name then return nil end
  return "name:" .. name, nil
end

--- The name written on a plate, for messages about mobs not targeted.
local function plateName(plate)
  if plate.wrekNameText == nil then
    local _, _, nameText = plate:GetRegions()
    plate.wrekNameText = (nameText and nameText.GetText) and nameText or false
  end
  local fs = plate.wrekNameText
  return fs and fs:GetText()
end

local function plateOverlay(plate)
  local o = plate.wrekThreat
  if o then return o end
  o = CreateFrame("Frame", nil, plate)
  o:SetWidth(44) o:SetHeight(14)
  -- Above ShaguPlates' and pfUI's own frames, which sit a few levels up.
  if o.SetFrameLevel and plate.GetFrameLevel then
    o:SetFrameLevel((plate:GetFrameLevel() or 0) + 12)
  end
  -- A plain font string, not UI.Text: those follow the addon's text-size
  -- setting, and the plates have a size setting of their own.
  o.text = o:CreateFontString(nil, "OVERLAY")
  o.text:SetFont(UI.fontNum, 11, "OUTLINE")
  o.text:SetJustifyH("CENTER")
  o.text:SetPoint("CENTER", o, "CENTER", 0, 0)
  plate.wrekThreat = o
  return o
end

--[[ Give a tinted bar back to whoever owns it.

     The stock bar gets the colour it had. ShaguPlates and pfUI cache the
     colour they last set and only repaint when their own answer changes,
     so the cache is cleared and an update queued: they repaint on their
     next frame with whatever is right for the mob now. ]]
local function restoreBar(plate)
  local t = plate.wrekTint
  if not t then return end
  plate.wrekTint = nil
  if t.np then
    if type(t.np.cache) == "table" then
      t.np.cache.r, t.np.cache.g, t.np.cache.b = nil, nil, nil
    end
    t.np.eventcache = true
  elseif t.bar then
    t.bar:SetStatusBarColor(t.r, t.g, t.b)
  end
end

local function tintBar(plate, bar, np, color)
  local t = plate.wrekTint
  if not t or t.bar ~= bar then
    restoreBar(plate)
    local r, g, b = bar:GetStatusBarColor()
    t = { bar = bar, np = np, r = r or 1, g = g or 0, b = b or 0 }
    plate.wrekTint = t
  end
  -- Only when it differs: their own update may have painted over ours.
  local r, g, b = bar:GetStatusBarColor()
  if r ~= color[1] or g ~= color[2] or b ~= color[3] then
    bar:SetStatusBarColor(color[1], color[2], color[3])
  end
end

local function hidePlate(plate)
  local o = plate.wrekThreat
  if o and o:IsShown() then o:Hide() end
  restoreBar(plate)
end

function TF:UpdatePlate(plate, s)
  if not plate:IsVisible() then
    hidePlate(plate)
    return
  end
  local key, guid = plateKey(plate)
  -- Every mob in view is looked at, targeted or not: that is the point.
  if guid then T:WatchMob(guid, plateName(plate)) end
  local pct, color, fresh, text
  if key then pct, color, fresh, text = T:ForMob(key, guid) end
  if not pct then
    hidePlate(plate)
    return
  end

  local bar, np = healthBar(plate, s.plateStyle)
  local anchor = bar or plate

  if s.platePercent then
    local o = plateOverlay(plate)
    if o.size ~= s.plateSize then
      o.size = s.plateSize
      o.text:SetFont(UI.fontNum, s.plateSize, "OUTLINE")
      o:SetHeight(s.plateSize + 4)
    end
    -- Re-anchored when the side changes or the plate addon swaps bars.
    if o.side ~= s.plateAnchor or o.anchoredTo ~= anchor then
      o.side, o.anchoredTo = s.plateAnchor, anchor
      o:ClearAllPoints()
      local a = s.plateAnchor
      if a == "LEFT" then o:SetPoint("RIGHT", anchor, "LEFT", -2, 0)
      elseif a == "TOP" then o:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
      elseif a == "BOTTOM" then o:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
      else o:SetPoint("LEFT", anchor, "RIGHT", 4, 0) end
    end
    o.text:SetText(text)
    if s.plateColor == "none" then
      o.text:SetTextColor(1, 1, 1, 1)
    else
      o.text:SetTextColor(color[1], color[2], color[3], 1)
    end
    --[[ Blink a mob that needs you and is not the one you are looking at:
         loose, on you, lost, or -- tanking -- with someone at the flash
         limit. The target has the target-frame % for that. ]]
    local urgent = fresh and color == T.RED and s.flash
    if urgent and T.current and T.current.key == key then urgent = false end
    if urgent then
      o:SetAlpha(0.3 + 0.7 * TF:Blink())
    else
      o:SetAlpha(fresh and 1 or 0.55)
    end
    if not o:IsShown() then o:Show() end
  elseif plate.wrekThreat and plate.wrekThreat:IsShown() then
    plate.wrekThreat:Hide()
  end

  -- A remembered reading is not tinted: a bar coloured by a number from
  -- several seconds ago reads as current, and the dimmed text does not.
  if s.plateColor == "bar" and bar and fresh then
    tintBar(plate, bar, np, color)
  else
    restoreBar(plate)
  end
end

function TF:UpdatePlates()
  local s = T:Settings()
  local plates = self.plates
  --[[ Nothing to show on any plate: put everything back once, then skip
       the pass altogether. This runs ten times a second, and outside a
       fight that is every time. ]]
  if not (s.enabled and s.plates) or not T:AnythingForPlates() then
    if self.platesShown then
      for i = 1, table.getn(plates) do hidePlate(plates[i]) end
      self.platesShown = nil
    end
    return
  end
  self.platesShown = true
  self:ScanPlates()
  for i = 1, table.getn(plates) do
    self:UpdatePlate(plates[i], s)
  end
end

--- Which plate addon is in charge right now, in words, for settings.
function TF:PlateAddon()
  if ShaguPlates then return "ShaguPlates" end
  if pfUI and pfUI.nameplates then return "pfUI" end
  for i = 1, table.getn(self.plates) do
    if customPlate(self.plates[i]) then return "ShaguPlates/pfUI" end
  end
  return "stock"
end

----------------------------------------------------------------------
-- warnings
----------------------------------------------------------------------

function TF:CreateWarning()
  if self.warn then return self.warn end
  local f = CreateFrame("Frame", "WrekkitThreatWarning", UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetAllPoints(UIParent)
  f:Hide()
  self.warn = f

  -- Sized by its own setting rather than the addon's text size.
  f.text = f:CreateFontString(nil, "OVERLAY")
  f.text:SetFont(UI.font, 26, "OUTLINE")
  f.text:SetJustifyH("CENTER")
  f.text:SetShadowColor(0, 0, 0, 0.9)
  f.text:SetShadowOffset(1, -1)
  f.text:SetPoint("CENTER", UIParent, "CENTER", 0, 170)

  -- Screen-edge flash: four soft bands fading inward.
  local function band(p1, p2, horizontal, startA, endA)
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(UI.media.white)
    t:SetPoint(p1, f, p1, 0, 0)
    t:SetPoint(p2, f, p2, 0, 0)
    if horizontal then t:SetHeight(70) else t:SetWidth(70) end
    t._grad = { horizontal and "VERTICAL" or "HORIZONTAL", startA, endA }
    t:Hide()
    return t
  end
  f.bands = {
    band("TOPLEFT", "TOPRIGHT", true, 0, 1),
    band("BOTTOMLEFT", "BOTTOMRIGHT", true, 1, 0),
    band("TOPLEFT", "BOTTOMLEFT", false, 1, 0),
    band("TOPRIGHT", "BOTTOMRIGHT", false, 0, 1),
  }
  return f
end

local WARN_COLOR = { 1.00, 0.55, 0.10 }
local DANGER_COLOR = { 0.95, 0.20, 0.20 }
local function levelColor(level)
  if level == "danger" then return DANGER_COLOR end
  return WARN_COLOR
end

function TF:Message(text, level)
  local f = self:CreateWarning()
  local c = levelColor(level)
  local size = T:Settings().textSize
  if f.textSize ~= size then
    f.textSize = size
    f.text:SetFont(UI.font, size, "OUTLINE")
  end
  f.text:SetText(text)
  f.text:SetTextColor(c[1], c[2], c[3], 1)
  f.text:SetAlpha(1)
  f.text:Show()
  self.messageAt = GetTime()
  f:Show()
end

function TF:Flash(level)
  local f = self:CreateWarning()
  local c = levelColor(level)
  for _, b in ipairs(f.bands) do
    local g = b._grad
    if b.SetGradientAlpha then
      b:SetGradientAlpha(g[1], c[1], c[2], c[3], g[2] * 0.6, c[1], c[2], c[3], g[3] * 0.6)
    else
      b:SetVertexColor(c[1], c[2], c[3], 0.3)
    end
    b:Show()
  end
  self.flashAt = GetTime()
  f:SetAlpha(1)
  f:Show()
end

--[[ The continuous flash. The condition is asked ten times a second (in
     the tick); the blink itself runs every frame so it is smooth. A
     one-off warning flash still plays over it. ]]
function TF:UpdateAlarm()
  local s = T:Settings()
  local pct, color = T:Alarm()
  if self.moving then pct = nil end
  self.alarm = pct and color or nil
  if self.alarm and s.flashScreen then
    local f = self:CreateWarning()
    if not self.alarmScreen then
      self.alarmScreen = true
      local c = self.alarm
      for _, b in ipairs(f.bands) do
        local g = b._grad
        if b.SetGradientAlpha then
          b:SetGradientAlpha(g[1], c[1], c[2], c[3], g[2] * 0.45, c[1], c[2], c[3], g[3] * 0.45)
        else
          b:SetVertexColor(c[1], c[2], c[3], 0.25)
        end
        b:Show()
      end
    end
    if not f:IsShown() then f:Show() end
  elseif self.alarmScreen then
    self.alarmScreen = nil
    if self.warn and not self.flashAt then
      for _, b in ipairs(self.warn.bands) do b:Hide() end
    end
  end
end

--- 0..1, the blink at this moment.
function TF:Blink()
  local speed = T:Settings().flashSpeed
  return math.abs(math.sin(GetTime() * math.pi * speed))
end

function TF:UpdateWarning()
  -- The target-frame % blinks while the alarm holds, steady otherwise.
  local ind = self.ind
  if ind and ind:IsShown() then
    if self.alarm and T:Settings().flashFrame then
      ind:SetAlpha(0.25 + 0.75 * self:Blink())
    elseif ind:GetAlpha() ~= 1 then
      ind:SetAlpha(1)
    end
  end

  local f = self.warn
  if not f or not f:IsShown() then return end
  local now = GetTime()
  local textOn, flashOn = false, false

  if self.alarmScreen and not self.flashAt then
    local a = self:Blink()
    for _, b in ipairs(f.bands) do b:SetAlpha(a) end
    flashOn = true
  end

  if self.messageAt then
    local age = now - self.messageAt
    if age < MESSAGE_TIME then
      textOn = true
    elseif age < MESSAGE_TIME + 0.6 then
      f.text:SetAlpha(1 - (age - MESSAGE_TIME) / 0.6)
      textOn = true
    else
      f.text:Hide()
      self.messageAt = nil
    end
  end

  if self.flashAt then
    local age = now - self.flashAt
    if age < FLASH_TIME then
      -- Two pulses, then gone.
      local a = math.abs(math.sin(age / FLASH_TIME * math.pi * 2))
      for _, b in ipairs(f.bands) do b:SetAlpha(a) end
      flashOn = true
    else
      self.flashAt = nil
      if self.alarmScreen then
        -- Back to the alarm's own colour after the one-off flash.
        self.alarmScreen = nil
      else
        for _, b in ipairs(f.bands) do b:Hide() end
      end
    end
  end

  if not textOn and not flashOn then f:Hide() end
end

----------------------------------------------------------------------
-- the meter, while fighting
----------------------------------------------------------------------

--[[ In "meter" mode the meter becomes the threat meter for the fight and
     goes back to whatever it was showing afterwards. What it was showing is
     remembered here, not in the saved setting, so a /reload mid-fight
     cannot leave it stuck on threat. ]]
function TF:UpdateMeterSwitch()
  local s = T:Settings()
  local meter = UI.meter
  if not meter.frame then return end
  local ms = meter:Settings()
  local fighting = s.enabled and s.display == "meter" and W.encounter:ReallyInCombat()
  if fighting and T:Live() and ms.metric ~= "threat" and not self.switchedFrom then
    self.switchedFrom = ms.metric
    meter:SetMetric("threat")
  elseif not fighting and self.switchedFrom then
    if ms.metric == "threat" then meter:SetMetric(self.switchedFrom) end
    self.switchedFrom = nil
  end
end

----------------------------------------------------------------------
-- driver
----------------------------------------------------------------------

--- Redraw everything that hangs off a unit. Called on every new reading
--- and on a short timer in between, because frames and plates move.
function TF:Update()
  W.Guard("threat target frame", function() TF:UpdateIndicator() end)
  W.Guard("threat nameplates", function() TF:UpdatePlates() end)
end

local function tick()
  TF:UpdateWarning()
  local now = GetTime()
  if now - (TF.lastTick or 0) < TICK then return end
  TF.lastTick = now
  TF:UpdateAlarm()
  TF:UpdateIndicator()
  TF:UpdatePlates()
  if UI.taunt then UI.taunt:Update() end
  UI.threat:UpdateVisibility()
  TF:UpdateMeterSwitch()
end

function TF:Start()
  if self.frame or not CreateFrame then return end
  local f = CreateFrame("Frame", "WrekkitThreatDriver")
  self.frame = f
  f:SetScript("OnUpdate", function() W.Guard("threat frames", tick) end)
end

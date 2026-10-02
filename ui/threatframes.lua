--[[ Wrekkit :: ui/threatframes

Threat where you are already looking: on the target frame, on the
nameplates, and -- when it matters -- across the middle of the screen.

  target frame   a percentage badge and a coloured border around whichever
                 target frame is in use: the stock one, pfUI's, or any frame
                 named in settings (Luna, XPerl, ...)
  nameplates     a percentage beside each mob's plate, coloured by level.
                 The target's is live; a mob you tabbed off keeps its last
                 reading, dimmed, for a few seconds; in tank mode every mob
                 the server reports on gets one.
  warnings       large text and a red edge around the screen when you cross
                 the warning or danger line, or lose aggro you were holding

Everything here is drawn on its own frames, parented to UIParent or to the
plate, and never re-skins another addon's frames: a unit-frame addon that
redraws itself every frame would simply paint over anything done to its
own textures.
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

--- The target frame to decorate: a name from settings, then pfUI's, then
--- the stock one. Returns nil when none of them is on screen.
function TF:TargetFrame()
  local s = T:Settings()
  local candidates = {}
  if s.frameName and s.frameName ~= "" then table.insert(candidates, s.frameName) end
  table.insert(candidates, "pfTarget")
  table.insert(candidates, "TargetFrame")
  for _, name in ipairs(candidates) do
    local f = getglobal and getglobal(name)
    if type(f) == "table" and f.IsVisible and f:IsVisible() then return f end
  end
  return nil
end

local function edge(parent)
  local t = parent:CreateTexture(nil, "OVERLAY")
  t:SetTexture(UI.media.white)
  return t
end

function TF:CreateIndicator()
  if self.ind then return self.ind end
  local ind = CreateFrame("Frame", "WrekkitThreatTarget", UIParent)
  ind:SetFrameStrata("HIGH")
  ind:SetWidth(10) ind:SetHeight(10)
  ind:Hide()
  self.ind = ind

  -- percentage badge
  local badge = UI.Panel(ind, W.color.bg, W.color.border)
  badge:SetWidth(46) badge:SetHeight(18)
  ind.badge = badge
  ind.text = UI.Text(badge, 12, W.color.text, "CENTER", UI.fontNum)
  ind.text:SetPoint("CENTER", badge, "CENTER", 0, 0)

  -- border around the target frame: four strips, so the frame itself is
  -- left untouched underneath
  ind.edges = { edge(ind), edge(ind), edge(ind), edge(ind) }
  return ind
end

--- Fit the border to the frame and put the badge on the chosen side.
function TF:PlaceIndicator(target)
  local ind = self.ind
  local s = T:Settings()
  local sc = s.frameScale or 1
  if self.indTarget ~= target or self.indAnchor ~= s.frameAnchor or self.indScale ~= sc then
    self.indTarget, self.indAnchor, self.indScale = target, s.frameAnchor, sc
    ind:ClearAllPoints()
    ind:SetAllPoints(target)

    local b = ind.badge
    b:SetWidth(math.floor(46 * sc + 0.5))
    b:SetHeight(math.floor(18 * sc + 0.5))
    b:ClearAllPoints()
    local a = s.frameAnchor or "TOP"
    if a == "BOTTOM" then
      b:SetPoint("TOP", target, "BOTTOM", 0, -2)
    elseif a == "LEFT" then
      b:SetPoint("RIGHT", target, "LEFT", -2, 0)
    elseif a == "RIGHT" then
      b:SetPoint("LEFT", target, "RIGHT", 2, 0)
    else
      b:SetPoint("BOTTOM", target, "TOP", 0, 2)
    end

    local e = ind.edges
    local th = 2
    e[1]:ClearAllPoints()
    e[1]:SetPoint("BOTTOMLEFT", target, "TOPLEFT", -th, 0)
    e[1]:SetPoint("BOTTOMRIGHT", target, "TOPRIGHT", th, 0)
    e[1]:SetHeight(th)
    e[2]:ClearAllPoints()
    e[2]:SetPoint("TOPLEFT", target, "BOTTOMLEFT", -th, 0)
    e[2]:SetPoint("TOPRIGHT", target, "BOTTOMRIGHT", th, 0)
    e[2]:SetHeight(th)
    e[3]:ClearAllPoints()
    e[3]:SetPoint("TOPRIGHT", target, "TOPLEFT", 0, 0)
    e[3]:SetPoint("BOTTOMRIGHT", target, "BOTTOMLEFT", 0, 0)
    e[3]:SetWidth(th)
    e[4]:ClearAllPoints()
    e[4]:SetPoint("TOPLEFT", target, "TOPRIGHT", 0, 0)
    e[4]:SetPoint("BOTTOMLEFT", target, "BOTTOMRIGHT", 0, 0)
    e[4]:SetWidth(th)
  end
end

function TF:UpdateIndicator()
  local s = T:Settings()
  local ind = self.ind
  local cur = s.enabled and s.frame and T:Live()
  local pct, color, _, text
  if cur then pct, color, _, text = T:Display(cur) end
  local target = pct and self:TargetFrame()
  if not target then
    if ind then ind:Hide() end
    return
  end
  ind = self:CreateIndicator()
  self:PlaceIndicator(target)

  if s.framePercent then
    ind.badge:Show()
    ind.text:SetText(text)
    ind.text:SetTextColor(color[1], color[2], color[3], 1)
    ind.badge:SetBorderColor(color, 0.9)
  else
    ind.badge:Hide()
  end

  -- Danger pulses; anything below it is a steady line.
  local alpha = 0.85
  if T:Level(pct) == "danger" and text ~= "tank" then
    alpha = 0.55 + 0.45 * math.abs(math.sin(GetTime() * 5))
  end
  for _, e in ipairs(ind.edges) do
    if s.frameGlow then
      e:SetVertexColor(color[1], color[2], color[3], alpha)
      e:Show()
    else
      e:Hide()
    end
  end
  ind:Show()
end

----------------------------------------------------------------------
-- nameplates
----------------------------------------------------------------------

TF.plates = {}     -- plate frame -> true, every plate seen so far

--- Is this child of WorldFrame a nameplate? The plate's first region is
--- its border texture, which no other frame there carries.
local function isPlate(frame)
  if frame.wrekIsPlate ~= nil then return frame.wrekIsPlate end
  local ok, result = pcall(function()
    if frame:GetName() then return false end
    local region = frame:GetRegions()
    if not region or not region.GetTexture then return false end
    return region:GetTexture() == PLATE_BORDER
  end)
  frame.wrekIsPlate = (ok and result) and true or false
  return frame.wrekIsPlate
end

function TF:ScanPlates()
  if not WorldFrame or not WorldFrame.GetChildren then return end
  local kids = { WorldFrame:GetChildren() }
  for i = 1, table.getn(kids) do
    local k = kids[i]
    if not self.plates[k] and isPlate(k) then self.plates[k] = true end
  end
end

--- The mob a plate belongs to. SuperWoW names the plate's unit outright;
--- without it the targeted mob's plate is the opaque one with its name.
local function plateKey(plate)
  local ok, guid = pcall(plate.GetName, plate, 1)
  if ok and type(guid) == "string" and string.sub(guid, 1, 2) == "0x" then
    return guid, guid
  end
  local regions = { plate:GetRegions() }
  local nameText = regions[3]
  local name = nameText and nameText.GetText and nameText:GetText()
  if not name then return nil end
  return "name:" .. name, nil
end

local function plateOverlay(plate)
  if plate.wrekThreat then return plate.wrekThreat end
  local o = CreateFrame("Frame", nil, plate)
  o:SetWidth(40) o:SetHeight(14)
  -- A plain font string, not UI.Text: those follow the addon's text-size
  -- setting, and the plates have a size setting of their own.
  o.text = o:CreateFontString(nil, "OVERLAY")
  o.text:SetFont(UI.fontNum, 11, "OUTLINE")
  o.text:SetJustifyH("CENTER")
  o.text:SetPoint("CENTER", o, "CENTER", 0, 0)
  plate.wrekThreat = o
  return o
end

local function plateBar(plate)
  if plate.wrekBar ~= nil then return plate.wrekBar or nil end
  local bar = plate.GetChildren and plate:GetChildren()
  if bar and bar.SetStatusBarColor then
    plate.wrekBar = bar
  else
    plate.wrekBar = false
  end
  return plate.wrekBar or nil
end

local function restoreBar(plate)
  local bar = plate.wrekBar
  if bar and plate.wrekTinted then
    local c = plate.wrekTinted
    bar:SetStatusBarColor(c[1], c[2], c[3])
    plate.wrekTinted = nil
  end
end

function TF:UpdatePlate(plate, s)
  local o = plate.wrekThreat
  if not plate:IsVisible() then
    if o then o:Hide() end
    return
  end
  local key, guid = plateKey(plate)
  local pct, color, fresh, text
  if key then pct, color, fresh, text = T:ForMob(key, guid) end
  if not pct then
    if o then o:Hide() end
    restoreBar(plate)
    return
  end

  o = plateOverlay(plate)
  if s.platePercent then
    local size = s.plateSize or 11
    if o.size ~= size then
      o.size = size
      o.text:SetFont(UI.fontNum, size, "OUTLINE")
      o:SetHeight(size + 4)
    end
    if o.anchor ~= s.plateAnchor then
      o.anchor = s.plateAnchor
      local bar = plateBar(plate) or plate
      o:ClearAllPoints()
      local a = s.plateAnchor or "RIGHT"
      if a == "LEFT" then o:SetPoint("RIGHT", bar, "LEFT", -2, 0)
      elseif a == "TOP" then o:SetPoint("BOTTOM", bar, "TOP", 0, 10)
      elseif a == "BOTTOM" then o:SetPoint("TOP", bar, "BOTTOM", 0, -2)
      else o:SetPoint("LEFT", bar, "RIGHT", 2, 0) end
    end
    o.text:SetText(text)
    if s.plateColor == "none" then
      o.text:SetTextColor(1, 1, 1, 1)
    else
      o.text:SetTextColor(color[1], color[2], color[3], 1)
    end
    o:SetAlpha(fresh and 1 or 0.55)
    o:Show()
  elseif o then
    o:Hide()
  end

  local bar = plateBar(plate)
  if s.plateColor == "bar" and bar then
    if not plate.wrekTinted then
      local r, g, b = bar:GetStatusBarColor()
      plate.wrekTinted = { r or 1, g or 0, b or 0 }
    end
    bar:SetStatusBarColor(color[1], color[2], color[3])
  else
    restoreBar(plate)
  end
end

function TF:UpdatePlates()
  local s = T:Settings()
  if not (s.enabled and s.plates) then
    if self.platesShown then
      for plate in pairs(self.plates) do
        if plate.wrekThreat then plate.wrekThreat:Hide() end
        restoreBar(plate)
      end
      self.platesShown = nil
    end
    return
  end
  --[[ Nothing to put on any plate: skip the walk over WorldFrame. This
       runs ten times a second, and outside a fight that is every time. ]]
  if not T.current and next(T.memory) == nil and next(T.tankMobs) == nil then
    if self.platesShown then
      for plate in pairs(self.plates) do
        if plate.wrekThreat then plate.wrekThreat:Hide() end
        restoreBar(plate)
      end
      self.platesShown = nil
    end
    return
  end
  self.platesShown = true
  self:ScanPlates()
  for plate in pairs(self.plates) do
    self:UpdatePlate(plate, s)
  end
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

local function levelColor(level)
  if level == "danger" then return { 0.95, 0.20, 0.20 } end
  return { 1.00, 0.55, 0.10 }
end

function TF:Message(text, level)
  local f = self:CreateWarning()
  local c = levelColor(level)
  local size = T:Settings().textSize or 26
  f.text:SetFont(UI.font, size, "OUTLINE")
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

function TF:UpdateWarning()
  local f = self.warn
  if not f or not f:IsShown() then return end
  local now = GetTime()
  local textOn, flashOn = false, false

  if self.messageAt then
    local age = now - self.messageAt
    if age < MESSAGE_TIME then
      f.text:SetAlpha(1)
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
      for _, b in ipairs(f.bands) do b:Hide() end
      self.flashAt = nil
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
  local now = GetTime()
  TF:UpdateWarning()
  if now - (TF.lastTick or 0) < TICK then return end
  TF.lastTick = now
  TF:Update()
  UI.threat:UpdateVisibility()
  TF:UpdateMeterSwitch()
end

function TF:Start()
  if self.frame or not CreateFrame then return end
  local f = CreateFrame("Frame", "WrekkitThreatDriver")
  self.frame = f
  f:SetScript("OnUpdate", function() W.Guard("threat frames", tick) end)
end

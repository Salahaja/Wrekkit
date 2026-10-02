--[[ Wrekkit :: ui/mobs

Mob frames: one small frame for every mob in the fight, showing who it is
hitting.

Five mobs on the tank, and one that was patrolling walks into the healer:
the threat table cannot show that (the server only reports mobs you hold)
and the nameplates are a crowd. This lists every mob in the fight in a
fixed order, each with its health and its target:

  Onyxian Whelp   [=========     ]   you           held, safe
  Onyxian Whelp   [======        ]   you   88%     held, someone closing in
  Onyxian Warder  [==============]   Mendy         LOOSE - red, blinking

Mobs are found two ways: every nameplate (with SuperWoW a plate names its
mob's guid), and every enemy the combat log has shown in this pull -- so a
mob with no plate in view is listed too, as long as the client knows it.
For each, SuperWoW answers health and target by guid.

  left-click    target it
  right-click   taunt it (as the Taunt bar would)

Order is first-seen and never reshuffles, so a row stays where the eye left
it; trouble is shown by colour, not by moving. Drag the title to move the
stack, or place it with the rest in /wrek threat move.

Needs SuperWoW. Without it no mob can be asked about by guid, and the stack
stays hidden.
]]

local W = Wrekkit
local UI = W.ui
UI.mobs = {}
local MF = UI.mobs

local T = W.threat

local ROW_H = 18
local WIDTH = 220
local UPDATE = 0.2

-- guid -> { guid, name, order, hp, max, who, onMe, state, seen }
MF.list = {}
local nextOrder = 0

----------------------------------------------------------------------
-- data
----------------------------------------------------------------------

--- Is this a living hostile in the fight, as far as the client knows?
local function fighting(guid)
  if not UnitExists or not UnitExists(guid) then return false end
  if UnitIsDead and UnitIsDead(guid) then return false end
  if UnitCanAttack and not UnitCanAttack("player", guid) then return false end
  if UnitAffectingCombat and not UnitAffectingCombat(guid) then return false end
  return true
end

local function consider(guid, now)
  if type(guid) ~= "string" or string.sub(guid, 1, 2) ~= "0x" then return end
  local m = MF.list[guid]
  if m and m.seen == now then return end
  if not fighting(guid) then
    if m then MF.list[guid] = nil end
    return
  end
  if not m then
    nextOrder = nextOrder + 1
    m = { guid = guid, order = nextOrder }
    MF.list[guid] = m
  end
  m.seen = now
  m.name = UnitName(guid) or m.name or "?"
  m.hp = UnitHealth(guid) or 0
  m.max = UnitHealthMax(guid) or 0

  local tok = guid .. "target"
  m.who, m.onMe, m.whoClass = nil, false, nil
  if UnitExists(tok) then
    m.onMe = UnitIsUnit(tok, "player") and true or false
    m.who = UnitName(tok)
    local _, class = UnitClass(tok)
    m.whoClass = class
  end

  -- What tank mode and the watcher already know about it.
  local low = T.LowGuid(guid)
  local held = low and T.tankMobs[low]
  m.pull = (held and now - held.at <= 3) and held.pull or nil
  -- Through the same watcher as the plates, so a mob with no plate in
  -- view is still caught going loose, and alerted once.
  m.state = T:WatchMob(guid, m.name)
end

--- Rebuild from the plates and the pull's enemies. Entries are reused, so
--- this makes no garbage once the fight's mobs are known.
function MF:Collect()
  local now = GetTime()
  local plates = UI.threatFrames and UI.threatFrames.plates or {}
  for i = 1, table.getn(plates) do
    local p = plates[i]
    if p:IsVisible() then
      local ok, guid = pcall(p.GetName, p, 1)
      if ok then consider(guid, now) end
    end
  end
  local enc = W.encounter.live
  if enc and enc.enemies then
    for guid in pairs(enc.enemies) do consider(guid, now) end
  end
  for guid, m in pairs(self.list) do
    if m.seen ~= now then self.list[guid] = nil end
  end
end

--- The mobs in display order.
function MF:Sorted()
  local out = {}
  for _, m in pairs(self.list) do table.insert(out, m) end
  table.sort(out, function(a, b) return a.order < b.order end)
  return out
end

----------------------------------------------------------------------
-- frames
----------------------------------------------------------------------

local function classHex(class)
  local c = W.ClassColor(class)
  return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255),
    math.floor(c[2] * 255), math.floor(c[3] * 255))
end

local function makeRow(parent, i)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(ROW_H)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, -(14 + (i - 1) * (ROW_H + 1)))
  b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -(14 + (i - 1) * (ROW_H + 1)))
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  b.bg = UI.Fill(b, W.color.panelHi, 0.9)
  -- Health, as a dim bar behind the text.
  b.hp = b:CreateTexture(nil, "BORDER")
  b.hp:SetTexture(UI.media.bar)
  b.hp:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b.hp:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
  b.hp:SetVertexColor(0.55, 0.16, 0.16, 0.7)
  -- Trouble: a red wash over the whole row that blinks.
  b.alarm = UI.Fill(b, { 0.95, 0.2, 0.2 }, 0, "ARTWORK")
  b.hl = UI.Fill(b, W.color.text, 0, "OVERLAY")

  b.name = UI.Text(b, 10, W.color.text)
  b.name:SetPoint("LEFT", b, "LEFT", 4, 0)
  b.name:SetWidth(108)
  b.who = UI.Text(b, 10, W.color.text, "RIGHT")
  b.who:SetPoint("RIGHT", b, "RIGHT", -34, 0)
  b.who:SetWidth(70)
  b.pct = UI.Text(b, 10, W.color.textDim, "RIGHT", UI.fontNum)
  b.pct:SetPoint("RIGHT", b, "RIGHT", -3, 0)
  b.pct:SetWidth(30)

  b:SetScript("OnEnter", function() b.hl:SetVertexColor(1, 1, 1, 0.06) end)
  b:SetScript("OnLeave", function() b.hl:SetVertexColor(1, 1, 1, 0) end)
  b:SetScript("OnClick", function()
    W.Guard("mob frame click", function()
      local m = b.mob
      if not m or m.sample then return end
      if arg1 == "RightButton" then
        T:Taunt({ guid = m.guid, name = m.name, who = m.who })
      elseif TargetUnit then
        TargetUnit(m.guid)
      end
    end)
  end)
  b:Hide()
  return b
end

function MF:Create()
  if self.frame then return self.frame end
  local s = T:Settings()
  local f = CreateFrame("Frame", "WrekkitMobs", UIParent)
  self.frame = f
  f:SetWidth(WIDTH)
  f:SetFrameStrata("MEDIUM")
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:Hide()
  f.bg = UI.Fill(f, W.color.bg, 0.8)

  local title = CreateFrame("Button", nil, f)
  title:SetHeight(13)
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  title:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  title:RegisterForDrag("LeftButton")
  title:SetScript("OnDragStart", function() f:StartMoving() end)
  title:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    MF:SavePosition()
  end)
  f.title = UI.Text(title, 9, W.color.accent)
  f.title:SetPoint("LEFT", title, "LEFT", 4, 0)
  f.count = UI.Text(title, 9, W.color.textFaint, "RIGHT")
  f.count:SetPoint("RIGHT", title, "RIGHT", -4, 0)
  f.count:SetText("click: target  -  right-click: taunt")

  self.rows = {}
  self:RestorePosition()
  return f
end

--- Saved by its top edge, so the stack grows downward from where it was put.
function MF:SavePosition()
  local f = self.frame
  local x, y = f:GetCenter()
  local ux, uy = UIParent:GetCenter()
  if not (x and ux) then return end
  local s = T:Settings()
  s.mobsX = math.floor(x - ux + 0.5)
  s.mobsY = math.floor(y + (f:GetHeight() or 0) / 2 - uy + 0.5)
end

function MF:RestorePosition()
  local f = self.frame
  local s = T:Settings()
  f:ClearAllPoints()
  f:SetPoint("TOP", UIParent, "CENTER", s.mobsX or 330, s.mobsY or 120)
end

--- Should the stack be up at all?
function MF:Wanted(count)
  local s = T:Settings()
  if not s.enabled or not s.mobFrames then return false end
  if s.mobFramesFor == "tank" and not T:IsTank() then return false end
  return count >= s.mobFramesMin
end

local SAMPLE = {
  { name = "Onyxian Whelp", hp = 80, max = 100, who = nil, onMe = true, pull = 40, sample = true },
  { name = "Onyxian Whelp", hp = 55, max = 100, who = nil, onMe = true, pull = 88, sample = true },
  { name = "Onyxian Warder", hp = 100, max = 100, who = "Mendy", whoClass = "PRIEST",
    onMe = false, state = "loose", sample = true },
}

function MF:Update()
  local now = GetTime()
  if now - (self.lastUpdate or 0) < UPDATE then return end
  self.lastUpdate = now

  local s = T:Settings()
  local moving = UI.threatFrames and UI.threatFrames.moving
  local list
  if moving then
    list = SAMPLE
  elseif SpellInfo and s.enabled and s.mobFrames then
    self:Collect()
    list = self:Sorted()
  else
    list = {}
  end
  if not moving and not self:Wanted(table.getn(list)) then
    if self.frame and self.frame:IsShown() then self.frame:Hide() end
    return
  end

  local f = self:Create()
  local tank = T:IsTank()
  local blink = 0.25 + 0.3 * math.abs(math.sin(now * math.pi * (s.flashSpeed or 3)))
  local n = math.min(table.getn(list), s.mobFramesMax)
  f.title:SetText("Mobs  " .. table.getn(list))

  for i = 1, n do
    local b = self.rows[i]
    if not b then
      b = makeRow(f, i)
      self.rows[i] = b
    end
    local m = list[i]
    b.mob = m
    b.name:SetText(m.name or "?")

    local frac = (m.max and m.max > 0) and (m.hp / m.max) or 1
    if frac > 1 then frac = 1 elseif frac < 0.01 then frac = 0.01 end
    local w = b:GetWidth()
    if not w or w <= 0 then w = WIDTH - 4 end
    b.hp:SetWidth(w * frac)

    -- Who it is on, and whether that is trouble.
    local trouble = false
    if m.onMe then
      b.who:SetText("|cff5a9bffyou|r")
      trouble = (not tank)
    elseif m.who then
      b.who:SetText(classHex(m.whoClass) .. m.who .. "|r")
      -- Loose is the watcher's word: it knows co-tanks, pets and the
      -- one-second grace for a mob that only cast at someone.
      trouble = tank and m.state == "loose"
    else
      b.who:SetText("|cff9d9d9d-|r")
    end

    if m.pull then
      local c = T:TankColor(m.pull)
      b.pct:SetText(T.PctText(m.pull))
      b.pct:SetTextColor(c[1], c[2], c[3], 1)
      if m.pull >= s.tankFlashAt then trouble = true end
    else
      b.pct:SetText(trouble and "|cfff23333!|r" or "")
    end

    b.trouble = trouble
    b.alarm:SetVertexColor(0.95, 0.2, 0.2, trouble and blink or 0)
    b:Show()
  end
  for i = n + 1, table.getn(self.rows) do self.rows[i]:Hide() end
  f:SetHeight(14 + n * (ROW_H + 1) + 2)
  if not f:IsShown() then f:Show() end
end

--- The fight is over: forget its mobs and start numbering afresh.
function MF:Reset()
  self.list = {}
  nextOrder = 0
end

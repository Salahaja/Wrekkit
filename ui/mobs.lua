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
      if b.summary then
        MF:ToggleCollapse()
        return
      end
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
  title:RegisterForClicks("LeftButtonUp")
  title:SetScript("OnClick", function() W.Guard("mob frames toggle", function() MF:ToggleCollapse() end) end)
  title:SetScript("OnDragStart", function() f:StartMoving() end)
  title:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    MF:SavePosition()
  end)
  f.title = UI.Text(title, 9, W.color.accent)
  f.title:SetPoint("LEFT", title, "LEFT", 4, 0)
  f.count = UI.Text(title, 9, W.color.textFaint, "RIGHT")
  f.count:SetPoint("RIGHT", title, "RIGHT", -4, 0)
  f.count:SetText("click title: expand / collapse")

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

--[[ Which mobs need a row of their own.

     Tanking, a mob is
       trouble   loose on someone, or held with someone at the warning line
       fine      on you
       elsewhere on a co-tank, a pet, or nobody
     Not tanking, a mob on YOU is the trouble and the rest are elsewhere. ]]
local function classify(m, tank, s)
  if tank then
    if m.state == "loose" then return "trouble" end
    if m.pull and m.pull >= s.tankWarnAt then return "trouble" end
    if m.onMe then return "fine" end
    return "elsewhere"
  end
  if m.onMe then return "trouble" end
  return "elsewhere"
end

--- Collapse now? "always", "never", or "auto" past mobFramesCollapseAt.
--- A click on the title flips it until the fight ends.
function MF:Collapsed(count)
  local s = T:Settings()
  local want
  if s.mobFramesCollapse == "always" then want = true
  elseif s.mobFramesCollapse == "never" then want = false
  else want = count > s.mobFramesCollapseAt end
  if self.flipped then want = not want end
  return want
end

local function paintMob(b, m, tank, s, blink)
  b.mob, b.summary = m, nil
  b.name:SetText(m.name or "?")
  b.hp:Show()
  local frac = (m.max and m.max > 0) and (m.hp / m.max) or 1
  if frac > 1 then frac = 1 elseif frac < 0.01 then frac = 0.01 end
  local w = b:GetWidth()
  if not w or w <= 0 then w = WIDTH - 4 end
  b.hp:SetWidth(w * frac)

  local trouble = classify(m, tank, s) == "trouble"
  if m.onMe then
    b.who:SetText("|cff5a9bffyou|r")
  elseif m.who then
    b.who:SetText(classHex(m.whoClass) .. m.who .. "|r")
  else
    b.who:SetText("|cff9d9d9d-|r")
  end

  if m.pull then
    local c = T:TankColor(m.pull)
    b.pct:SetText(T.PctText(m.pull))
    b.pct:SetTextColor(c[1], c[2], c[3], 1)
  else
    b.pct:SetText(trouble and "|cfff23333!|r" or "")
  end

  b.trouble = trouble
  b.alarm:SetVertexColor(0.95, 0.2, 0.2, trouble and blink or 0)
end

--[[ The collapsed line: everything that needs no row, in one. "All 10 on
     you" in blue is the line a tank wants to read and then ignore. ]]
local function paintSummary(b, fine, elsewhere, hidden, tank, total)
  b.mob, b.summary, b.trouble = nil, true, false
  b.hp:Hide()
  b.alarm:SetVertexColor(0, 0, 0, 0)
  local text
  if tank then
    if fine == total then
      text = "|cff5a9bffAll " .. total .. " on you|r"
    else
      text = "|cff5a9bff" .. fine .. " on you|r"
      if elsewhere > 0 then text = text .. "  |cff9d9d9d" .. elsewhere .. " elsewhere|r" end
    end
  else
    text = "|cff9d9d9d" .. elsewhere .. " on others|r"
  end
  b.name:SetText(text)
  b.who:SetText("")
  b.pct:SetText(hidden > 0 and ("|cfff23333+" .. hidden .. "|r") or "")
end

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
  local total = table.getn(list)
  if not moving and not self:Wanted(total) then
    if self.frame and self.frame:IsShown() then self.frame:Hide() end
    self.flipped = nil
    return
  end

  local f = self:Create()
  local tank = moving or T:IsTank()
  local blink = 0.25 + 0.3 * math.abs(math.sin(now * math.pi * (s.flashSpeed or 3)))
  local collapsed = self:Collapsed(total)
  self.collapsed = collapsed

  -- What gets a row: everything, or the summary line and the trouble.
  local show, fine, elsewhere = {}, 0, 0
  for _, m in ipairs(list) do
    local kind = classify(m, tank, s)
    if not collapsed or kind == "trouble" then
      table.insert(show, m)
    elseif kind == "fine" then
      fine = fine + 1
    else
      elsewhere = elsewhere + 1
    end
  end

  local maxRows = s.mobFramesMax
  local rowsUsed = 0
  local function row(i)
    local b = self.rows[i]
    if not b then
      b = makeRow(f, i)
      self.rows[i] = b
    end
    b:Show()
    return b
  end

  if collapsed then
    local room = maxRows - 1
    local hidden = table.getn(show) - room
    if hidden < 0 then hidden = 0 end
    rowsUsed = 1
    paintSummary(row(1), fine, elsewhere, hidden, tank, total)
    for i = 1, math.min(table.getn(show), room) do
      rowsUsed = rowsUsed + 1
      paintMob(row(rowsUsed), show[i], tank, s, blink)
    end
  else
    for i = 1, math.min(table.getn(show), maxRows) do
      rowsUsed = i
      paintMob(row(i), show[i], tank, s, blink)
    end
  end

  for i = rowsUsed + 1, table.getn(self.rows) do
    self.rows[i].mob, self.rows[i].summary = nil, nil
    self.rows[i]:Hide()
  end
  f.title:SetText("Mobs  " .. total .. (collapsed and "  |cff9d9d9d(collapsed)|r" or ""))
  f:SetHeight(14 + rowsUsed * (ROW_H + 1) + 2)
  if not f:IsShown() then f:Show() end
end

--- Expand or collapse until the fight ends (a click on the title or on
--- the summary line).
function MF:ToggleCollapse()
  self.flipped = not self.flipped
  self.lastUpdate = nil
  self:Update()
end

--- The fight is over: forget its mobs and start numbering afresh.
function MF:Reset()
  self.list = {}
  self.flipped = nil
  nextOrder = 0
end

--[[ Wrekkit :: ui/threat

The threat window, and the rows it shares with the meter.

Three ways to see it, picked in settings (Threat tab) or from the title menu:

  window   its own window, moved and sized on its own
  docked   hangs under the damage meter at the meter's width, and moves
           with it -- one block on screen instead of two to arrange
  meter    no window of its own; the damage meter turns into the threat
           meter while you fight and goes back to what it was showing after

"Threat (live)" is also in the meter's metric menu in every mode, for anyone
who would rather switch by hand.

A tank also gets a second section: every mob they hold, who is closest to
pulling it, and how close. That list comes from the server's tank mode and
covers mobs the tank is not targeting -- which is the whole problem on a
multi-mob pull.

The rows are drawn by one painter for both the window and the meter, so the
two can never show the same table differently.
]]

local W = Wrekkit
local UI = W.ui
UI.threat = {}
local TW = UI.threat

local T = W.threat

----------------------------------------------------------------------
-- rows, shared with the meter
----------------------------------------------------------------------

local function byPull(a, b)
  if a.mob.pull == b.mob.pull then return a.mob.creature < b.mob.creature end
  return a.mob.pull > b.mob.pull
end

--[[ The rows to draw: the target's threat table with the pull-aggro line
     sorted in where it falls, then -- for a tank -- the mobs they hold. ]]
function TW.Rows(cur)
  local s = T:Settings()
  local items = {}

  if cur then
    local top = 0
    for _, r in ipairs(cur.rows) do
      local item = { row = r, shown = r.tank and 100 or T:Shown(r) }
      if item.shown > top then top = item.shown end
      table.insert(items, item)
    end

    --[[ The line is the one number on a threat meter that is not anybody's:
         where aggro would move to you. Placed by threat like every other
         row, above the first player with less than it takes. ]]
    local me = cur.me
    if s.showPullLine and me and not me.tank and cur.tank then
      local mult = (me.melee and T.PULL_MELEE or T.PULL_RANGED)
      local line = (s.basis == "tank") and mult or 100
      local lineItem = { pullLine = true, shown = line, threat = cur.tank.threat * mult / 100,
                         melee = me.melee }
      if line > top then top = line end
      local at = table.getn(items) + 1
      for i, it in ipairs(items) do
        if it.row.threat < lineItem.threat then at = i break end
      end
      table.insert(items, at, lineItem)
    end

    if top <= 0 then top = 1 end
    local rank = 0
    for _, it in ipairs(items) do
      it._frac = it.shown / top
      if not it.pullLine then
        rank = rank + 1
        it._rank = rank
      end
    end
  end

  if T:IsTank() and next(T.tankMobs) then
    local mobs = {}
    local targetLow = cur and cur.low
    for low, m in pairs(T.tankMobs) do
      table.insert(mobs, { mob = m, isTarget = (low == targetLow) })
    end
    table.sort(mobs, byPull)
    table.insert(items, { header = "Mobs you are holding" })
    for _, it in ipairs(mobs) do
      it._frac = math.min(1, (it.mob.pull or 0) / 100)
      table.insert(items, it)
    end
  end
  return items
end

local PULL_COLOR = { 0.83, 0.31, 0.33 }
local DIM = { 0.62, 0.65, 0.72 }
local LABEL = { 0.78, 0.80, 0.85 }

local function rowTooltip(frame, item)
  if not GameTooltip then return end
  GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")

  if item.pullLine then
    GameTooltip:AddLine("Pull aggro", PULL_COLOR[1], PULL_COLOR[2], PULL_COLOR[3])
    GameTooltip:AddLine(string.format("Aggro moves to you at %d%% of the tank's threat",
      item.melee and T.PULL_MELEE or T.PULL_RANGED), LABEL[1], LABEL[2], LABEL[3])
    GameTooltip:AddLine(item.melee and "(you are in melee range)." or
      "(you are out of melee range).", DIM[1], DIM[2], DIM[3])
    GameTooltip:AddDoubleLine("Threat needed", W.Comma(item.threat), LABEL[1], LABEL[2], LABEL[3], 1, 1, 1)
    GameTooltip:Show()
    return
  end

  if item.mob then
    local m = item.mob
    GameTooltip:AddLine(m.creature, 1, 1, 1)
    GameTooltip:AddLine("You have aggro.", T.TANK_COLOR[1], T.TANK_COLOR[2], T.TANK_COLOR[3])
    GameTooltip:AddDoubleLine("Closest to pulling it", m.name, LABEL[1], LABEL[2], LABEL[3], 1, 1, 1)
    GameTooltip:AddDoubleLine("Their share of your threat", T.PctText(m.perc),
      LABEL[1], LABEL[2], LABEL[3], 1, 1, 1)
    GameTooltip:AddLine("Shown as the way to pulling, assuming melee", DIM[1], DIM[2], DIM[3])
    GameTooltip:AddLine("range (110%): the earlier of the two lines.", DIM[1], DIM[2], DIM[3])
    GameTooltip:Show()
    return
  end

  local r = item.row
  local c = W.ClassColor(r.class)
  GameTooltip:AddLine(r.name, c[1], c[2], c[3])
  GameTooltip:AddDoubleLine("Threat", W.Comma(r.threat), LABEL[1], LABEL[2], LABEL[3], 1, 1, 1)
  GameTooltip:AddDoubleLine("Threat / sec", W.Comma(r.tps or 0), LABEL[1], LABEL[2], LABEL[3], 1, 1, 1)
  GameTooltip:AddDoubleLine("Of the tank's", T.PctText(r.perc), LABEL[1], LABEL[2], LABEL[3], 1, 1, 1)
  if r.tank then
    GameTooltip:AddLine("Has aggro.", T.TANK_COLOR[1], T.TANK_COLOR[2], T.TANK_COLOR[3])
  else
    GameTooltip:AddDoubleLine("To pulling aggro", T.PctText(r.pull), LABEL[1], LABEL[2], LABEL[3], 1, 1, 1)
    GameTooltip:AddLine(r.melee and "In melee range: pulls at 110%." or
      "At range: pulls at 130%.", DIM[1], DIM[2], DIM[3])
  end
  GameTooltip:Show()
end

local function tooltipFor(item)
  return function(self) rowTooltip(self, item) end
end

--- Paint one threat row. Same signature as every ScrollList painter.
function TW.Paint(row, item, index)
  local s = T:Settings()
  row:SetScript("OnClick", nil)

  if item.header then
    row.tip = nil
    row:SetData(nil, "|cffe0a22c" .. item.header .. "|r", "", "", 0, W.color.panelHi, 10)
    return
  end
  row.tip = tooltipFor(item)

  if item.pullLine then
    local value = s.showThreat and W.Short(item.threat) or ""
    row:SetData(nil, "|cffd44f53-- pull aggro --|r", value,
      T.PctText(item.shown), item._frac, PULL_COLOR, 40)
    return
  end

  if item.mob then
    local m = item.mob
    local cc = W.ClassColor(W.capture.rosterClass[m.name])
    local who = string.format("|cff%02x%02x%02x%s|r", math.floor(cc[1] * 255),
      math.floor(cc[2] * 255), math.floor(cc[3] * 255), m.name)
    local mobName = item.isTarget and ("|cffe0a22c>|r " .. m.creature) or m.creature
    row:SetData(nil, mobName, who, T.PctText(m.pull), item._frac, T:TankColor(m.pull), 40)
    return
  end

  local r = item.row
  local name = r.name
  if r.tank then name = "|cff5a9bff[T]|r " .. name end
  if r.isMe then name = "|cffe0a22c>|r " .. name end

  local value
  if s.showThreat and s.showTPS then
    value = W.Short(r.threat) .. "  |cff9d9d9d" .. W.Short(r.tps or 0) .. "/s|r"
  elseif s.showThreat then
    value = W.Short(r.threat)
  elseif s.showTPS then
    value = "|cff9d9d9d" .. W.Short(r.tps or 0) .. "/s|r"
  else
    value = ""
  end

  local color = W.ClassColor(r.class)
  if r.isMe and not r.tank then color = T:Color(item.shown) end

  row:SetData(item._rank, name, value, r.tank and "tank" or T.PctText(item.shown),
    item._frac, color, 40)
end

--- Why there is nothing to show, in words.
function TW.EmptyNote()
  local s = T:Settings()
  if not s.enabled then return "threat is switched off" end
  if T.why then return T.why end
  if not T.lastPacket then return "waiting for the server" end
  return "no threat yet"
end

local function paintNote(row, item)
  row:SetData(nil, item.label, "", "", 0, W.color.panelHi, 10)
  row.tip = nil
  row:SetScript("OnClick", nil)
end
TW.PaintNote = paintNote

----------------------------------------------------------------------
-- window
----------------------------------------------------------------------

function TW:Create()
  if self.frame then return self.frame end
  local s = T:Settings()

  local f = UI.Window("WrekkitThreat", s.window.w, s.window.h, "Threat", {
    minW = 180, minH = 80, barHeight = 20,
  })
  self.frame = f
  UI.BindGeometry(f, s.window)

  local cogBtn = UI.IconButton(f.bar, UI.media.cog, 14, function()
    W.Guard("open threat settings", function() UI.settings:Show("threat") end)
  end, { title = "Threat settings", lines = { "Role, warnings, target frame,",
                                             "nameplates and where this goes." } })
  cogBtn:SetPoint("RIGHT", f.closeButton, "LEFT", -1, 0)
  self.cogBtn = cogBtn

  local titleHit = CreateFrame("Button", nil, f.bar)
  titleHit:SetPoint("TOPLEFT", f.bar, "TOPLEFT", 0, 0)
  titleHit:SetPoint("BOTTOMRIGHT", cogBtn, "BOTTOMLEFT", -2, 0)
  titleHit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  titleHit:SetScript("OnClick", function()
    W.Guard("threat menu", function() TW:Menu(titleHit) end)
  end)
  titleHit:RegisterForDrag("LeftButton")
  titleHit:SetScript("OnDragStart", function() TW:StartDrag() end)
  titleHit:SetScript("OnDragStop", function() TW:StopDrag() end)
  f.bar:SetScript("OnDragStart", function() TW:StartDrag() end)
  f.bar:SetScript("OnDragStop", function() TW:StopDrag() end)

  local list = UI.ScrollList(f.body, 16)
  list:SetPoint("TOPLEFT", f.body, "TOPLEFT", 2, -2)
  list:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -2, 14)
  self.list = list

  local foot = UI.Text(f.body, 10, W.color.textFaint)
  foot:SetPoint("BOTTOMLEFT", f.body, "BOTTOMLEFT", 6, 2)
  self.footL = foot
  local footR = UI.Text(f.body, 10, W.color.textFaint, "RIGHT")
  footR:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -16, 2)
  self.footR = footR

  f.closeButton:SetScript("OnClick", function()
    TW:SetDisplay("off")
    W.Print("threat window hidden. |cffe0a22c/wrek threat|r brings it back; " ..
      "frames, plates and warnings stay on.")
  end)

  f.OnResize = function() TW:Refresh() end
  self:ApplyLayout()
  return f
end

function TW:StartDrag()
  local s = T:Settings()
  local f = self.frame
  if s.locked then return end
  -- Docked, the meter is what moves: drag that and this follows.
  if s.display == "docked" then
    local m = UI.meter.frame
    if m and not UI.meter:Settings().locked then
      m:StartMoving()
      self.draggingMeter = true
    end
    return
  end
  f:StartMoving()
end

function TW:StopDrag()
  local f = self.frame
  if self.draggingMeter then
    self.draggingMeter = nil
    local m = UI.meter.frame
    if m then
      m:StopMovingOrSizing()
      m:SavePosition()
    end
    return
  end
  f:StopMovingOrSizing()
  f:SavePosition()
end

--- Position and chrome for the current display mode.
function TW:ApplyLayout()
  local f = self.frame
  if not f then return end
  local s = T:Settings()
  local scale = UI.FontScale()
  local rowH = math.floor(16 * scale + 0.5)
  self.list:SetRowHeight(rowH)

  if s.display == "docked" then
    local m = UI.meter:Create()
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", m, "BOTTOMLEFT", 0, -2)
    f:SetPoint("TOPRIGHT", m, "BOTTOMRIGHT", 0, -2)
    f:SetHeight(20 + 18 + rowH * math.max(2, math.min(s.rows, 12)))
    f.grip:Hide()
    -- Matches the meter it hangs from.
    if f.SetOpacity then f:SetOpacity(UI.meter:Settings().opacity) end
  else
    f:RestorePosition()
    f.grip:Show()
    if f.SetOpacity then f:SetOpacity(s.opacity) end
  end
  self:Refresh()
end

local ROLE_LABEL = { auto = "auto (stance/form)", on = "always", off = "never" }

function TW:Menu(anchor)
  local s = T:Settings()
  local items = {
    { text = "Show threat", header = true },
    { text = "In its own window", value = "d:window", checked = s.display == "window" },
    { text = "Docked under the meter", value = "d:docked", checked = s.display == "docked" },
    { text = "In the meter while fighting", value = "d:meter", checked = s.display == "meter" },
    { text = "I'm the tank", header = true },
    { text = "Auto (stance / form)", value = "r:auto", checked = s.tankMode == "auto" },
    { text = "Always", value = "r:on", checked = s.tankMode == "on" },
    { text = "Never", value = "r:off", checked = s.tankMode == "off" },
    { text = "Columns", header = true },
    { text = "Threat", value = "col:showThreat", checked = s.showThreat == true },
    { text = "Threat per second", value = "col:showTPS", checked = s.showTPS == true },
    { text = "Pull-aggro line", value = "col:showPullLine", checked = s.showPullLine == true },
    { text = "Window", header = true },
    { text = "Lock position", value = "lock", checked = s.locked == true },
    { text = "Preview with test data", value = "demo" },
    { text = "Settings...", value = "settings" },
    { text = "Hide window", value = "d:off" },
  }
  UI.Menu(self.frame, anchor, items, function(value)
    if not value then return end
    local _, _, mode = string.find(value, "^d:(.*)$")
    local _, _, role = string.find(value, "^r:(.*)$")
    local _, _, col = string.find(value, "^col:(.*)$")
    if mode then
      TW:SetDisplay(mode)
    elseif role then
      s.tankMode = role
      T.roleAt = nil
      W.Print("tank alerts: " .. ROLE_LABEL[role] .. ".")
      TW:Refresh()
    elseif col then
      s[col] = not s[col]
      TW:Refresh()
    elseif value == "lock" then
      s.locked = not s.locked
    elseif value == "demo" then
      T:Demo(15)
    elseif value == "settings" then
      UI.settings:Show("threat")
    end
  end, 200)
end

--- Change where threat is shown.
function TW:SetDisplay(mode)
  local s = T:Settings()
  if mode ~= "window" and mode ~= "docked" and mode ~= "meter" and mode ~= "off" then
    return false
  end
  s.display = mode
  -- So "/wrek threat" brings back the window the way it was last used.
  if mode == "window" or mode == "docked" then s.lastWindow = mode end
  if mode == "docked" or mode == "meter" then UI.meter:Show() end
  self:UpdateVisibility()
  if self.frame then self:ApplyLayout() end
  if UI.settings and UI.settings.Refresh then UI.settings:Refresh() end
  return true
end

--[[ Shown when the mode says so and the moment calls for it: "group" (the
     default) keeps an empty window off the screen while you quest alone,
     which is when the server has nothing to say anyway. A preview always
     shows, or there would be nothing to place. ]]
function TW:WantShown()
  local s = T:Settings()
  if not s.enabled then return false end
  if s.display ~= "window" and s.display ~= "docked" then return false end
  if T.demoUntil then return true end
  if s.show == "group" then return T:Channel() ~= nil end
  if s.show == "combat" then
    return W.encounter:ReallyInCombat() or T:Live() ~= nil
  end
  return true
end

function TW:UpdateVisibility()
  if self:WantShown() then
    local f = self:Create()
    if not f:IsShown() then
      f:Show()
      self:ApplyLayout()
    end
  elseif self.frame and self.frame:IsShown() then
    self.frame:Hide()
  end
end

function TW:Refresh()
  W.Guard("threat window", function() TW:RefreshInner() end)
end

function TW:RefreshInner()
  local f = self.frame
  if not f or not f:IsShown() then return end
  local cur = T:Live()
  local rows = TW.Rows(cur)
  local tank = T:IsTank()

  if table.getn(rows) == 0 then
    f.title:SetText(tank and "Threat  |cff5a9bfftank|r" or "Threat")
    self.list:SetData({ { label = TW.EmptyNote() } }, paintNote)
    self.footL:SetText("")
    self.footR:SetText("")
    return
  end

  local title = cur and ("Threat: " .. (cur.name or "?")) or "Threat"
  if tank then title = title .. "  |cff5a9bfftank|r" end
  f.title:SetText(title)
  self.list:SetData(rows, TW.Paint)
  self.footL:SetText(cur and ("aggro: " .. (cur.tank and cur.tank.name or "?")) or "")
  self.footR:SetText(T.demoUntil and "preview" or "")
end

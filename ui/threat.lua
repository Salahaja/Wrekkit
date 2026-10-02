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

--[[ The rows to draw for a table, plus the pull-aggro line as a row of its
     own, sorted in where it falls. The line is the one number on a threat
     meter that is not anybody's: where aggro would move to you. ]]
function TW.Rows(cur)
  if not cur then return {} end
  local s = T:Settings()
  local items = {}
  local top = 0
  for _, r in ipairs(cur.rows) do
    local item = { row = r, shown = T:Shown(r) }
    if r.tank then item.shown = 100 end
    if item.shown > top then top = item.shown end
    table.insert(items, item)
  end

  local me = cur.me
  if s.showPullLine and me and not me.tank and cur.tank then
    local line = (s.basis == "tank") and (me.melee and T.PULL_MELEE or T.PULL_RANGED) or 100
    local mult = (me.melee and T.PULL_MELEE or T.PULL_RANGED) / 100
    local lineItem = { pullLine = true, shown = line, threat = cur.tank.threat * mult,
                       melee = me.melee }
    if line > top then top = line end
    -- Placed by threat, like every other row: above the first player
    -- with less than it takes to pull.
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
  return items
end

local PULL_COLOR = { 0.83, 0.31, 0.33 }

local function rowTooltip(frame, item)
  if not GameTooltip then return end
  local r = item.row
  GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
  if item.pullLine then
    GameTooltip:AddLine("Pull aggro", PULL_COLOR[1], PULL_COLOR[2], PULL_COLOR[3])
    GameTooltip:AddLine(string.format("Aggro moves to you at %d%% of the tank's",
      item.melee and T.PULL_MELEE or T.PULL_RANGED), 0.78, 0.80, 0.85)
    GameTooltip:AddLine(item.melee and "threat: you are in melee range."
      or "threat: you are out of melee range.", 0.78, 0.80, 0.85)
    GameTooltip:AddDoubleLine("Threat needed", W.Comma(item.threat), 0.78, 0.80, 0.85, 1, 1, 1)
    GameTooltip:Show()
    return
  end
  local c = W.ClassColor(r.class)
  GameTooltip:AddLine(r.name, c[1], c[2], c[3])
  GameTooltip:AddDoubleLine("Threat", W.Comma(r.threat), 0.78, 0.80, 0.85, 1, 1, 1)
  GameTooltip:AddDoubleLine("Threat / sec", W.Comma(r.tps or 0), 0.78, 0.80, 0.85, 1, 1, 1)
  GameTooltip:AddDoubleLine("Of the tank's", string.format("%.0f%%", r.perc or 0),
    0.78, 0.80, 0.85, 1, 1, 1)
  if r.tank then
    GameTooltip:AddLine("Has aggro.", T.TANK_COLOR[1], T.TANK_COLOR[2], T.TANK_COLOR[3])
  else
    GameTooltip:AddDoubleLine("To pulling aggro", string.format("%.0f%%", r.pull or 0),
      0.78, 0.80, 0.85, 1, 1, 1)
    GameTooltip:AddLine(r.melee and "In melee range: pulls at 110%." or
      "At range: pulls at 130%.", 0.62, 0.65, 0.72)
  end
  GameTooltip:Show()
end

--- Paint one threat row. Same signature as every ScrollList painter.
function TW.Paint(row, item, index)
  local s = T:Settings()
  row.tip = function(self) rowTooltip(self, item) end
  row:SetScript("OnClick", nil)

  if item.pullLine then
    local value = s.showThreat and W.Short(item.threat) or ""
    row:SetData(nil, "|cffd44f53-- pull aggro --|r", value,
      string.format("%d%%", item.shown), item._frac, PULL_COLOR, 40)
    return
  end

  local r = item.row
  local name = r.name
  if r.tank then name = "|cff5a9bff[T]|r " .. name end
  if r.isMe then name = "|cffe0a22c>|r " .. name end

  local parts = {}
  if s.showThreat then table.insert(parts, W.Short(r.threat)) end
  if s.showTPS then table.insert(parts, "|cff9d9d9d" .. W.Short(r.tps or 0) .. "/s|r") end

  local color = W.ClassColor(r.class)
  if r.isMe and not r.tank then color = T:Color(item.shown) end

  local pctText = r.tank and "tank" or string.format("%d%%", math.floor(item.shown + 0.5))
  row:SetData(item._rank, name, table.concat(parts, "  "), pctText, item._frac, color, 40)
end

--- Why there is nothing to show, in words.
function TW.EmptyNote()
  local s = T:Settings()
  if not s.enabled then return "threat is switched off" end
  if T.why then return T.why end
  if not T.lastPacket then return "waiting for the server" end
  return "no threat yet"
end

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
  end, { title = "Threat settings", lines = { "Warnings, unit frames, nameplates", "and where this window goes." } })
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
    T:Settings().display = "off"
    TW:UpdateVisibility()
    W.Print("threat window hidden. |cffe0a22c/wrek threat|r brings it back.")
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
  self.list:SetRowHeight(math.floor(16 * scale + 0.5))

  if s.display == "docked" then
    local m = UI.meter:Create()
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", m, "BOTTOMLEFT", 0, -2)
    f:SetPoint("TOPRIGHT", m, "BOTTOMRIGHT", 0, -2)
    local rowH = math.floor(16 * scale + 0.5)
    f:SetHeight(20 + 18 + rowH * math.max(2, math.min(s.rows or 8, 12)))
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

function TW:Menu(anchor)
  local s = T:Settings()
  local items = {
    { text = "-- show threat --", disabled = true },
    { text = "In its own window", value = "d:window", checked = s.display == "window" },
    { text = "Docked under the meter", value = "d:docked", checked = s.display == "docked" },
    { text = "In the meter while fighting", value = "d:meter", checked = s.display == "meter" },
    { text = "-- options --", disabled = true },
    { text = "Tank mode (all mobs)", value = "tank", checked = s.tankMode == true },
    { text = "Show threat", value = "col:showThreat", checked = s.showThreat == true },
    { text = "Show threat/sec", value = "col:showTPS", checked = s.showTPS == true },
    { text = "Show pull-aggro line", value = "col:showPullLine", checked = s.showPullLine == true },
    { text = s.locked and "Unlock window" or "Lock window", value = "lock" },
    { text = "Preview (test data)", value = "demo" },
    { text = "Settings...", value = "settings" },
    { text = "Hide", value = "d:off" },
  }
  UI.Menu(self.frame, anchor, items, function(value)
    if not value then return end
    local _, _, mode = string.find(value, "^d:(.*)$")
    local _, _, col = string.find(value, "^col:(.*)$")
    if mode then
      TW:SetDisplay(mode)
    elseif col then
      s[col] = not s[col]
      TW:Refresh()
    elseif value == "tank" then
      s.tankMode = not s.tankMode
    elseif value == "lock" then
      s.locked = not s.locked
    elseif value == "demo" then
      T:Demo(15)
    elseif value == "settings" then
      UI.settings:Show("threat")
    end
  end, 190)
end

--- Change where threat is shown, and say where it went.
function TW:SetDisplay(mode)
  local s = T:Settings()
  if mode ~= "window" and mode ~= "docked" and mode ~= "meter" and mode ~= "off" then
    return false
  end
  s.display = mode
  -- So "/wrek threat" brings back the window the way it was last used.
  if mode == "window" or mode == "docked" then s.lastWindow = mode end
  if mode == "docked" then UI.meter:Show() end
  if mode == "meter" then UI.meter:Show() end
  self:UpdateVisibility()
  if self.frame then self:ApplyLayout() end
  if UI.settings and UI.settings.Refresh then UI.settings:Refresh() end
  return true
end

--- Shown when the mode says so; the meter mode has no window.
function TW:UpdateVisibility()
  local s = T:Settings()
  local want = s.enabled and (s.display == "window" or s.display == "docked")
  if want then
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
  if not cur then
    f.title:SetText("Threat")
    self.list:SetData({ { label = TW.EmptyNote(), value = "" } }, function(row, item)
      row:SetData(nil, item.label, "", "", 0, W.color.panelHi, 10)
      row.tip = nil
      row:SetScript("OnClick", nil)
    end)
    self.footL:SetText(T:Settings().tankMode and "tank mode" or "")
    self.footR:SetText("")
    return
  end
  f.title:SetText("Threat: " .. (cur.name or "?"))
  self.list:SetData(TW.Rows(cur), TW.Paint)
  local holder = cur.tank and cur.tank.name or "?"
  self.footL:SetText("aggro: " .. holder)
  self.footR:SetText(T.demoUntil and "preview" or "")
end

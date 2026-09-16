--[[ Wrekkit :: ui/meter

The live window. Deliberately spare: a title bar that doubles as the mode
menu, one optional toolbar, and rows. Everything else lives in the report.

Interaction map, so the chrome can stay minimal:
  left-click title    metric menu (damage, dps, healing, taken, ...)
  right-click title   segment menu (current pull, last pull, all session)
  left-click row      drill into that player's abilities
  right-click row     back out of the drilldown
  mouse wheel         scroll
  drag corner         resize; the row count follows the height
]]

local W = Wrekkit
local UI = W.ui
UI.meter = {}
local M = UI.meter

local REFRESH = 0.5

M.defaults = {
  -- Visible on login unless the user closed it last time. A meter you have
  -- to go and find is a meter nobody uses, but overriding a deliberate close
  -- every session would be worse, so the choice is remembered.
  shown = true,
  metric = "damage",
  segment = "current",
  petMode = "merge",
  groupOnly = false,
  search = "",
  showToolbar = true,
  compact = false,
  rowHeight = 18,
  locked = false,
  window = { point = "CENTER", x = -320, y = 0, w = 260, h = 200 },
}

----------------------------------------------------------------------
-- state
----------------------------------------------------------------------

function M:Settings()
  if not W.db.meter then W.db.meter = {} end
  local s = W.db.meter
  for k, v in pairs(self.defaults) do
    if s[k] == nil then
      if type(v) == "table" then
        s[k] = {}
        for k2, v2 in pairs(v) do s[k][k2] = v2 end
      else
        s[k] = v
      end
    end
  end
  return s
end

----------------------------------------------------------------------
-- data
----------------------------------------------------------------------

--- Which encounters the current segment covers.
function M:Encounters()
  local s = self:Settings()
  local seg = s.segment

  if seg == "current" then
    local live = W.encounter.live
    if live then return { live }, "Current" end
    -- Nothing in progress: fall through to the last pull rather than an
    -- empty window, which reads as "the addon is broken".
    seg = "last"
  end

  -- The session being logged now, not merely the newest on record: after a
  -- reset the newest stored session is the one that was just closed.
  local session = W.report:CurrentSession()
  if not session then return {}, "No data" end

  if seg == "last" then
    local list = session.encounters
    local last = list[table.getn(list)]
    if last then return { last }, last.name end
    return {}, "No data"
  end

  return session.encounters, "All Session"
end

----------------------------------------------------------------------
--- What an announcement of this window would contain: the metric on show,
--- the segment on show, and the filters currently applied. Announcing then
--- reports what you are looking at rather than a separate query.
function M:AnnounceContext()
  local s = self:Settings()
  local encounters, segLabel = self:Encounters()
  return {
    metric = s.metric,
    encounters = encounters,
    label = segLabel,
    filter = { search = s.search, groupOnly = s.groupOnly },
    petMode = s.petMode,
  }
end

----------------------------------------------------------------------
-- construction
----------------------------------------------------------------------

function M:Create()
  if self.frame then return self.frame end
  local s = self:Settings()

  local f = UI.Window("WrekkitMeter", s.window.w, s.window.h, "Damage", {
    --[[ 200 was too narrow to be useful: after the rank gutter, the value
         and the per-second column, the name was left about 40px, which is
         two characters and an ellipsis. 260 leaves room for a full name
         like "Shieldbarbie" at the default text size, and for the filter
         box and tabs on the header. ]]
    minW = 260, minH = 110, barHeight = 22,
  })
  self.frame = f
  UI.BindGeometry(f, s.window)

  ------------------------------------------------------------------
  -- title bar behaviour
  ------------------------------------------------------------------

  -- Settings, on the title bar next to the close button.
  local cogBtn = UI.IconButton(f.bar, UI.media.cog, 16, function()
    W.Guard("open settings", function() UI.settings:Toggle() end)
  end, {
    title = "Settings",
    lines = { "Compact mode, text size, recording", "and history options." },
  })
  cogBtn:SetPoint("RIGHT", f.closeButton, "LEFT", -1, 0)
  self.cogBtn = cogBtn

  --[[ The segment indicator is its own button rather than a label.

       "Current / Onyxia / All Session" is the thing people most want to
       change, and hunting for it in a menu behind the title is a step too
       many -- so the word itself is the control. Both buttons open the same
       picker; a right-click on a label is not discoverable enough to be the
       only way in. ]]
  local segBtn = CreateFrame("Button", nil, f.bar)
  segBtn:SetHeight(14)
  segBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  segBtn.label = UI.Text(segBtn, 10, W.color.textDim)
  segBtn.label:SetPoint("LEFT", segBtn, "LEFT", 3, 0)
  segBtn.wash = UI.Fill(segBtn, W.color.accent, 0, "BACKGROUND")
  segBtn:SetScript("OnClick", function()
    W.Guard("segment click", function() M:SegmentMenu(segBtn) end)
  end)
  segBtn:SetScript("OnEnter", function()
    segBtn.wash:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 0.16)
    segBtn.label:SetTextColor(W.color.text[1], W.color.text[2], W.color.text[3], 1)
  end)
  segBtn:SetScript("OnLeave", function()
    segBtn.wash:SetVertexColor(0, 0, 0, 0)
    segBtn.label:SetTextColor(W.color.textDim[1], W.color.textDim[2], W.color.textDim[3], 1)
  end)
  segBtn:SetPoint("LEFT", f.title, "RIGHT", 6, 0)
  self.segBtn = segBtn

  -- The window's own subtitle is replaced by that button.
  f.subtitle:Hide()

  local titleHit = CreateFrame("Button", nil, f.bar)
  titleHit:SetPoint("TOPLEFT", f.bar, "TOPLEFT", 0, 0)
  titleHit:SetPoint("BOTTOMRIGHT", cogBtn, "BOTTOMLEFT", -2, 0)
  titleHit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  titleHit:SetScript("OnClick", function()
    if arg1 == "RightButton" then M:SegmentMenu(titleHit) else M:MetricMenu(titleHit) end
  end)

  -- titleHit covers the whole bar, so the segment button has to sit above it
  -- or it never sees a click. Siblings created later win by default.
  segBtn:SetFrameLevel(titleHit:GetFrameLevel() + 2)
  -- Dragging must still work through the hit area.
  titleHit:RegisterForDrag("LeftButton")
  titleHit:SetScript("OnDragStart", function() if not M:Settings().locked then f:StartMoving() end end)
  titleHit:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    f:SavePosition()
  end)

  ------------------------------------------------------------------
  -- toolbar
  ------------------------------------------------------------------

  local tb = CreateFrame("Frame", nil, f.body)
  tb:SetHeight(22)
  tb:SetPoint("TOPLEFT", f.body, "TOPLEFT", 0, 0)
  tb:SetPoint("TOPRIGHT", f.body, "TOPRIGHT", 0, 0)
  UI.Fill(tb, W.color.panel, 0.6)
  local tbRule = UI.Line(tb, W.color.border)
  tbRule:SetPoint("BOTTOMLEFT", tb, "BOTTOMLEFT", 0, 0)
  tbRule:SetPoint("BOTTOMRIGHT", tb, "BOTTOMRIGHT", 0, 0)
  self.toolbar = tb

  local search = UI.SearchBox(tb, 110, function(text)
    M:Settings().search = text
    M:Refresh()
  end, "Filter name")
  search:SetPoint("LEFT", tb, "LEFT", 4, 0)
  search:SetHeight(18)
  self.search = search

  local petBtn = UI.Button(tb, "Pets", 40, 18, function()
    local st = M:Settings()
    st.petMode = (st.petMode == "merge") and "separate" or "merge"
    M:UpdatePetButton()
    M:Refresh()
  end)
  petBtn:SetPoint("LEFT", search, "RIGHT", 4, 0)
  self.petBtn = petBtn

  local reportBtn = UI.Button(tb, "Report", 48, 18, function()
    if UI.report then UI.report:Toggle() end
  end)
  reportBtn:SetPoint("RIGHT", tb, "RIGHT", -4, 0)

  ------------------------------------------------------------------
  -- toggles
  ------------------------------------------------------------------

  -- Ignore anyone outside the party/raid.
  local groupBtn = UI.IconButton(tb, UI.media.group, 18, function()
    local st = M:Settings()
    st.groupOnly = not st.groupOnly
    M:UpdateToggles()
    M:Refresh()
  end, {
    title = "Group only",
    lines = {
      "Lit: only your party or raid is counted.",
      "Dim: everyone nearby is counted.",
    },
  })
  groupBtn:SetPoint("RIGHT", reportBtn, "LEFT", -4, 0)
  self.groupBtn = groupBtn

  -- Record combat outside instances.
  local worldBtn = UI.IconButton(tb, UI.media.globe, 18, function()
    W.db.trackOpenWorld = not W.db.trackOpenWorld
    M:UpdateToggles()
    W.Print("open-world combat " ..
      (W.db.trackOpenWorld and "is now recorded." or "is ignored (instances only)."))
  end, {
    title = "Open-world recording",
    lines = {
      "Lit: combat anywhere is recorded.",
      "Dim: only inside dungeons and raids.",
    },
  })
  worldBtn:SetPoint("RIGHT", groupBtn, "LEFT", -2, 0)
  self.worldBtn = worldBtn

  -- Reset. Left-click closes the current log and starts a fresh one, keeping
  -- what came before; deleting the history outright is behind a right-click
  -- and a confirmation, because it cannot be undone.
  local resetBtn = UI.IconButton(tb, UI.media.reset, 18, function()
    if arg1 == "RightButton" then
      if StaticPopup_Show then
        StaticPopup_Show("WREKKIT_RESET_ALL")
      else
        W.ResetData("all")
      end
    else
      W.ResetData("new")
    end
  end, {
    title = "Reset",
    lines = {
      "Left-click: start a new log.",
      "Earlier pulls stay in the report.",
      "Right-click: delete the history entirely.",
    },
  })
  resetBtn:SetPoint("RIGHT", worldBtn, "LEFT", -2, 0)
  self.resetBtn = resetBtn

  ------------------------------------------------------------------
  -- list
  ------------------------------------------------------------------

  local list = UI.ScrollList(f.body, s.rowHeight)
  list:SetPoint("TOPLEFT", tb, "BOTTOMLEFT", 2, -2)
  list:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -2, 16)
  self.list = list

  ------------------------------------------------------------------
  -- footer
  ------------------------------------------------------------------

  local footer = CreateFrame("Frame", nil, f.body)
  self.footer = footer
  footer:SetHeight(15)
  footer:SetPoint("BOTTOMLEFT", f.body, "BOTTOMLEFT", 0, 0)
  footer:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", 0, 0)

  self.footL = UI.Text(footer, 10, W.color.textFaint)
  self.footL:SetPoint("LEFT", footer, "LEFT", 6, 0)
  self.footR = UI.Text(footer, 10, W.color.textFaint, "RIGHT")
  self.footR:SetPoint("RIGHT", footer, "RIGHT", -6, 0)

  ------------------------------------------------------------------

  --[[ The title bar's X hides the meter and remembers it.

       UI.Window's default handler just calls Hide(), which would come back
       on the next login and make the close look broken. Overriding it here
       also lets us say how to get it back -- a hidden window with no visible
       affordance is the one way this addon can look like it stopped
       working. ]]
  f.closeButton:SetScript("OnClick", function()
    M:Hide()
    W.Print("meter hidden. |cffe0a22c/wrek|r or the minimap button brings it back.")
  end)

  f.OnResize = function() M:Refresh() end
  f:SetScript("OnShow", function() M:StartTicker() end)

  self:UpdatePetButton()
  self:UpdateToggles()
  self:ApplyLayout()
  return f
end

function M:UpdatePetButton()
  local merged = (self:Settings().petMode == "merge")
  self.petBtn:SetActive(merged)
  self.petBtn.label:SetText(merged and "Pets+" or "Pets")
end

--- Sync the icon toggles with the state they represent. Called after any
--- change, including ones made by slash command, so the HUD never disagrees
--- with the setting.
function M:UpdateToggles()
  if self.groupBtn then self.groupBtn:SetLit(self:Settings().groupOnly == true) end
  if self.worldBtn then self.worldBtn:SetLit(W.db.trackOpenWorld == true) end
  if self.resetBtn then self.resetBtn:SetLit(false) end
end

--[[ Lay the meter out for the current density settings.

     Three independent knobs feed this:
       compact     drops the toolbar and footer and tightens the title bar
       rowHeight   how dense the list is
       fontScale   global text size

     Font scale multiplies the pixel dimensions as well as the text. Scaling
     the letters without scaling what contains them just clips them, which is
     the usual way a "text size" option ends up useless. ]]
function M:ApplyLayout()
  local f = self.frame
  if not f then return end

  local s = self:Settings()
  local compact = (s.compact == true)
  local scale = UI.FontScale()

  local function px(n) return math.floor(n * scale + 0.5) end

  -- title bar
  f.bar:SetHeight(px(compact and 18 or 22))
  if self.cogBtn then
    local size = px(compact and 13 or 16)
    self.cogBtn:SetWidth(size)
    self.cogBtn:SetHeight(size)
  end

  -- toolbar: compact mode hides it regardless of the preference, so the
  -- preference survives being toggled in and out of compact.
  local showToolbar = (not compact) and (s.showToolbar ~= false)
  if showToolbar then
    self.toolbar:Show()
    self.toolbar:SetHeight(px(22))
    self.list:SetPoint("TOPLEFT", self.toolbar, "BOTTOMLEFT", 2, -2)
  else
    self.toolbar:Hide()
    self.list:SetPoint("TOPLEFT", f.body, "TOPLEFT", 2, -2)
  end

  -- footer
  local footerH = compact and 0 or px(15)
  if compact then self.footer:Hide() else self.footer:Show() end
  self.footer:SetHeight(footerH > 0 and footerH or 1)
  self.list:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -2, footerH + 1)

  self.list:SetRowHeight(px(s.rowHeight or 18))

  --[[ Move the minimum size with the chrome.

       It was fixed at 260x110, but the title bar, toolbar, footer and rows
       all scale with the text size. At a large setting the chrome alone
       exceeds 110, so dragging the window to its minimum left the list a
       NEGATIVE height -- a frame whose size is impossible, handed to the
       layout resolver on every frame of the drag. Keep room for the chrome
       plus two rows, so the window can always show something. ]]
  if f.SetMinResize then
    local rowH = px(s.rowHeight or 18)
    local chrome = px(compact and 18 or 22)            -- title bar
                 + (showToolbar and px(22) or 0)
                 + footerH
                 + 8                                   -- borders and insets
    f:SetMinResize(px(260), chrome + rowH * 2)
  end

  self:Refresh()
end

--- Kept for the segment menu's toolbar entry and older call sites.
function M:ApplyToolbar()
  self:ApplyLayout()
end

--- Put the current segment on its button and size the button to the word.
--- FontStrings do not size their parent, so without measuring the text the
--- clickable area would be a fixed guess -- too small for "All Session",
--- absurdly wide for "Current".
function M:SetSegmentLabel(text)
  local b = self.segBtn
  if not b then return end
  text = text or ""
  b.label:SetText(text)
  local w = b.label:GetStringWidth() or 0
  b:SetWidth(w + 8)
  b:SetHeight(math.floor(13 * UI.FontScale() + 0.5))
end

----------------------------------------------------------------------
-- menus
----------------------------------------------------------------------

function M:MetricMenu(anchor)
  local s = self:Settings()
  local items = {}
  for _, m in ipairs(W.metrics.list) do
    table.insert(items, { text = m.label, value = m.key, checked = (m.key == s.metric) })
  end
  UI.Menu(self.frame, anchor, items, function(value)
    s.metric = value
    self.drill = nil
    self:Refresh()
  end, 170)
end

function M:SegmentMenu(anchor)
  local s = self:Settings()
  local items = {
    { text = "Current pull", value = "current", checked = (s.segment == "current") },
    { text = "Last pull", value = "last", checked = (s.segment == "last") },
    { text = "All Session", value = "overall", checked = (s.segment == "overall") },
    { text = "-- windows --", value = nil, disabled = true },
    { text = "Open report", value = "report" },
    { text = s.showToolbar and "Hide toolbar" or "Show toolbar", value = "toolbar" },
    { text = "Start a new log", value = "reset" },
    { text = "Announce to...", value = "announce" },
    { text = "Settings...", value = "settings" },
    { text = "Hide meter", value = "hide" },
  }
  UI.Menu(self.frame, anchor, items, function(value)
    if value == "settings" then
      UI.settings:Toggle()
    elseif value == "announce" then
      UI.AnnounceMenu(self.frame, anchor, M:AnnounceContext())
    elseif value == "hide" then
      M:Hide()
      W.Print("meter hidden. |cffe0a22c/wrek|r or the minimap button brings it back.")
    elseif value == "report" then
      if UI.report then UI.report:Toggle() end
    elseif value == "toolbar" then
      s.showToolbar = not s.showToolbar
      self:ApplyToolbar()
    elseif value == "reset" then
      W.ResetData()
    elseif value then
      s.segment = value
      self.drill = nil
      self:Refresh()
    end
  end, 150)
end

----------------------------------------------------------------------
-- painting
----------------------------------------------------------------------

local function paintActor(row, item, index)
  local color = item._color or W.ClassColor(item.class)
  row:SetData(item._rank, item.name, item._text, item._sub, item._frac, color, 58)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function()
    if arg1 == "RightButton" then
      UI.meter.drill = nil
      UI.meter.drillAbility = nil
    else
      UI.meter.drill = item.key
      UI.meter.drillAbility = nil
      UI.meter.drillAbility = nil
    end
    UI.meter:Refresh()
  end)
end

local function paintAbility(row, item, index)
  local color = item._color or W.color.accent
  row:SetData(index, item.name,
    W.Short(item.amount), string.format("%.0f%%", item._pct),
    item._frac, color, 42)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.abilityId = item.id
  row:SetScript("OnClick", function()
    local btn = this or row
    if arg1 == "RightButton" then
      UI.meter.drill = nil
    else
      -- Second level: the spread for this one ability.
      UI.meter.drillAbility = btn.abilityId
    end
    UI.meter:Refresh()
  end)
end

--- Label/value lines, no bar -- these are statistics, not a ranking, and a
--- proportional bar behind them would imply a comparison that isn't there.
local function paintStat(row, item, index)
  row:SetData(nil, item.label, item.value, item.note, 0, W.color.panelHi, 52)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function()
    UI.meter.drillAbility = nil
    UI.meter:Refresh()
  end)
end

--- Repaints run on a ticker, so an error here would fire twice a second and
--- bury its own first occurrence. Guard reports each distinct one once.
function M:Refresh()
  W.Guard("meter refresh", function() M:RefreshInner() end)
end

function M:RefreshInner()
  local f = self.frame
  if not f or not f:IsShown() then return end

  local s = self:Settings()
  local encounters, segLabel = self:Encounters()
  local metric = W.metrics.Get(s.metric)

  local view = W.report:View(encounters, { petMode = s.petMode })
  local rows, _, total = W.report:Rank(view, s.metric,
    { search = s.search, groupOnly = s.groupOnly })

  f.title:SetText(metric.label)
  self:SetSegmentLabel(segLabel)

  if self.drill then
    local target
    for _, r in ipairs(rows) do
      if r.key == self.drill then target = r end
    end
    if not target then
      self.drill = nil
      self.drillAbility = nil
    else
      local abilities = W.report:Abilities(target, s.metric)
      local color = W.ClassColor(target.class)
      for _, a in ipairs(abilities) do a._color = color end

      -- Level two: the spread for a single ability.
      if self.drillAbility then
        local ability
        for _, a in ipairs(abilities) do
          if a.id == self.drillAbility then ability = a end
        end
        if ability then
          local stats = W.report:AbilityStats(ability, s.metric)
          self:SetSegmentLabel(target.name .. " - " .. ability.name)
          self.list:SetData(stats, paintStat)
          self.footL:SetText(ability.name)
          self.footR:SetText("click to go back")
          return
        end
        self.drillAbility = nil
      end

      -- An empty drilldown needs to say why; see R:EmptyDetailNote.
      if table.getn(abilities) == 0 then
        self:SetSegmentLabel(target.name)
        self.list:SetData({ { label = W.report:EmptyDetailNote(view), value = "" } },
          paintStat)
        self.footL:SetText(target.name)
        self.footR:SetText("click to go back")
        return
      end

      -- Level one: which abilities made up that number.
      self:SetSegmentLabel(target.name .. " - " .. segLabel)
      self.list:SetData(abilities, paintAbility)
      self.footL:SetText(string.format("%d abilities", table.getn(abilities)))
      self.footR:SetText(W.Short(target._v) .. "  (click one for detail)")
      return
    end
  end

  for _, r in ipairs(rows) do
    r._color = metric.color or W.ClassColor(r.class)
  end

  self.list:SetData(rows, paintActor)

  local live = W.encounter.live and W.encounter:ReallyInCombat()
  self.footL:SetText((live and "|cffe0a22c* |r" or "") ..
    W.Duration(view.rateBase) .. " combat time")
  local totalText = W.metrics.Format(metric, total)
  if metric.percent or metric.integer then
    self.footR:SetText(table.getn(rows) .. " shown")
  else
    self.footR:SetText(totalText .. " total")
  end
end

----------------------------------------------------------------------
-- ticker
----------------------------------------------------------------------

function M:StartTicker()
  if self.ticking then return end
  self.ticking = true
  local function tick()
    if not self.frame or not self.frame:IsShown() then
      self.ticking = false
      return
    end
    self:Refresh()
    W.After(REFRESH, tick, "meterTick")
  end
  tick()
end

----------------------------------------------------------------------
-- public
----------------------------------------------------------------------

--[[ Visibility is persisted, so every path in and out of "shown" has to go
     through these rather than calling Hide()/Show() on the frame directly --
     otherwise the window and the saved setting drift apart and the meter
     reappears after you closed it. ]]

function M:Toggle()
  local f = self:Create()
  if f:IsShown() then self:Hide() else self:Show() end
end

function M:Show()
  local f = self:Create()
  self:Settings().shown = true
  f:Show()
  self:Refresh()
end

function M:Hide()
  self:Settings().shown = false
  if self.frame then self.frame:Hide() end
end

--- Restore last session's visibility. Called once at login.
function M:RestoreVisibility()
  if self:Settings().shown then
    local f = self:Create()
    f:Show()
    self:Refresh()
  end
end

function M:SetMetric(key)
  self:Settings().metric = key
  self.drill = nil
  self:Refresh()
end

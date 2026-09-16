--[[ Wrekkit :: ui/report

The full post-raid view. Same information architecture as the website that
used to host it: a session on the left broken into encounters you can
select, a summary that leads with the timeline, and per-aspect tabs behind
it that all read from the same merged view.

Selecting several encounters merges them, which is what the site's
"16 Encounters Selected" header means -- the merge happens in report.lua so
the meter and this window can never disagree about a number.
]]

local W = Wrekkit
local UI = W.ui
UI.report = {}
local R = UI.report

local SIDEBAR = 176
local TAB_H = 24
local HEADER_H = 44

R.tabs = {
  { key = "summary", label = "Summary" },
  { key = "damage", label = "Damage", metric = "damage" },
  { key = "healing", label = "Healing", metric = "healing" },
  { key = "taken", label = "Taken", metric = "taken" },
  { key = "enemies", label = "Enemies", metric = "enemy" },
  { key = "deaths", label = "Deaths" },
}

R.state = { tab = "summary", selected = {}, sessionIndex = 1, search = "",
            petMode = "merge", sortKey = nil, drill = nil, drillAbility = nil,
            groupOnly = false }

----------------------------------------------------------------------
-- data helpers
----------------------------------------------------------------------

local function encKey(enc)
  return tostring(enc.sessionId) .. ":" .. tostring(enc.id)
end

function R:Session()
  local sessions = W.report:Sessions()
  self.sessions = sessions
  local s = sessions[self.state.sessionIndex]
  if not s then
    self.state.sessionIndex = 1
    s = sessions[1]
  end
  return s
end

function R:SelectedEncounters()
  local session = self:Session()
  if not session then return {} end

  local out = {}
  for _, enc in ipairs(session.encounters) do
    if self.state.selected[encKey(enc)] then table.insert(out, enc) end
  end
  -- Nothing ticked means the whole night, which is the useful default when
  -- the window is first opened.
  if table.getn(out) == 0 then return session.encounters, true end
  return out, false
end

function R:SelectAll()
  self.state.selected = {}
  self:Refresh()
end

--[[ What an announcement of this window would contain.

     The metric follows the TAB you are on, which is the whole point: the
     Healing tab posts healing, Deaths posts deaths. Summary shows two panels
     side by side, so it posts both rather than silently picking one. ]]
function R:AnnounceContext()
  local encounters, isAll = self:SelectedEncounters()
  local session = self:Session()
  local n = table.getn(encounters)

  local label
  if isAll then
    label = (session and session.zone or "?") .. " - " .. n .. " encounters"
  elseif n == 1 then
    label = encounters[1].name or "?"
  else
    label = n .. " encounters"
  end

  local metrics
  local tab = self.state.tab
  if tab == "summary" then
    metrics = { "damage", "healing" }
  elseif tab == "deaths" then
    metrics = { "deaths" }
  else
    for _, t in ipairs(self.tabs) do
      if t.key == tab and t.metric then metrics = { t.metric } end
    end
  end
  metrics = metrics or { "damage" }

  return {
    metrics = metrics,
    -- The drill is rendered from a single metric, so name the one in use.
    metric = metrics[1],
    encounters = encounters,
    label = label,
    filter = { search = self.state.search, groupOnly = self.state.groupOnly },
    petMode = self.state.petMode,
    drill = self.state.drill,
    drillAbility = self.state.drillAbility,
  }
end

----------------------------------------------------------------------
-- construction
----------------------------------------------------------------------

function R:Create()
  if self.frame then return self.frame end
  if not W.db.report then W.db.report = { point = "CENTER", x = 0, y = 0, w = 900, h = 600 } end

  local f = UI.Window("WrekkitReport", W.db.report.w, W.db.report.h, "Wrekkit", {
    minW = 620, minH = 400,
    -- Above the live meter: they overlap constantly, and the meter is the
    -- one you want behind.
    strata = "HIGH",
  })
  self.frame = f
  UI.BindGeometry(f, W.db.report)
  UI.CloseOnEscape("WrekkitReport")

  ------------------------------------------------------------------
  -- sidebar
  ------------------------------------------------------------------

  local side = CreateFrame("Frame", nil, f.body)
  side:SetWidth(SIDEBAR)
  side:SetPoint("TOPLEFT", f.body, "TOPLEFT", 0, 0)
  side:SetPoint("BOTTOMLEFT", f.body, "BOTTOMLEFT", 0, 0)
  UI.Fill(side, W.color.panel, 0.5)
  local sideEdge = side:CreateTexture(nil, "BORDER")
  sideEdge:SetTexture(UI.media.white)
  sideEdge:SetVertexColor(W.color.border[1], W.color.border[2], W.color.border[3], 1)
  sideEdge:SetWidth(1)
  sideEdge:SetPoint("TOPRIGHT", side, "TOPRIGHT", 0, 0)
  sideEdge:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", 0, 0)

  local sessionBtn = UI.Button(side, "Session", SIDEBAR - 12, 22, function()
    R:SessionMenu()
  end)
  sessionBtn:SetPoint("TOPLEFT", side, "TOPLEFT", 6, -6)
  self.sessionBtn = sessionBtn

  local allBtn = UI.Button(side, "All encounters", SIDEBAR - 12, 18, function()
    R:SelectAll()
  end)
  allBtn:SetPoint("TOPLEFT", sessionBtn, "BOTTOMLEFT", 0, -4)

  local encList = UI.ScrollList(side, 30, function(parent, height)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(height)
    row.bg = UI.Fill(row, W.color.accent, 0)
    row.tick = row:CreateTexture(nil, "ARTWORK")
    row.tick:SetTexture(UI.media.white)
    row.tick:SetWidth(2)
    row.tick:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    row.tick:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
    row.name = UI.Text(row, 11, W.color.text)
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -20, -4)
    row.meta = UI.Text(row, 9, W.color.textFaint)
    row.meta:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 4)
    row.meta:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -20, 4)
    row.hl = UI.Fill(row, W.color.text, 0, "OVERLAY")

    -- Padlock: kept encounters survive pruning and reset.
    row.lock = UI.IconButton(row, UI.media.lock, 14, nil, {
      title = "Keep this encounter",
      lines = {
        "Locked encounters are never deleted",
        "by pruning, the ring buffer, or reset.",
      },
    })
    row.lock.dimAlpha = 0.20
    row.lock:SetPoint("RIGHT", row, "RIGHT", -3, 0)

    row:SetScript("OnEnter", function() row.hl:SetVertexColor(1, 1, 1, 0.05) end)
    row:SetScript("OnLeave", function() row.hl:SetVertexColor(1, 1, 1, 0) end)
    return row
  end)
  encList:SetPoint("TOPLEFT", allBtn, "BOTTOMLEFT", 0, -6)
  encList:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", -6, 6)
  self.encList = encList

  ------------------------------------------------------------------
  -- header strip
  ------------------------------------------------------------------

  local header = CreateFrame("Frame", nil, f.body)
  header:SetHeight(HEADER_H)
  header:SetPoint("TOPLEFT", side, "TOPRIGHT", 1, 0)
  header:SetPoint("TOPRIGHT", f.body, "TOPRIGHT", 0, 0)
  UI.Fill(header, W.color.panel, 0.35)

  self.hTitle = UI.Text(header, 14, W.color.text)
  self.hTitle:SetPoint("TOPLEFT", header, "TOPLEFT", 12, -7)

  self.hMeta = UI.Text(header, 10, W.color.textDim)
  self.hMeta:SetPoint("TOPLEFT", self.hTitle, "BOTTOMLEFT", 0, -3)

  self.hStats = UI.Text(header, 10, W.color.textDim, "RIGHT")
  self.hStats:SetPoint("TOPRIGHT", header, "TOPRIGHT", -12, -10)

  local search = UI.SearchBox(header, 120, function(text)
    R.state.search = text
    R:Refresh()
  end, "Filter name")
  search:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -12, 6)
  self.search = search

  local petBtn = UI.Button(header, "Pets merged", 78, 18, function()
    R.state.petMode = (R.state.petMode == "merge") and "separate" or "merge"
    R.petBtn.label:SetText(R.state.petMode == "merge" and "Pets merged" or "Pets split")
    R:Refresh()
  end)
  petBtn:SetPoint("RIGHT", search, "LEFT", -6, 0)
  self.petBtn = petBtn

  local groupBtn = UI.IconButton(header, UI.media.group, 18, function()
    R.state.groupOnly = not R.state.groupOnly
    R.groupBtn:SetLit(R.state.groupOnly)
    R:Refresh()
  end, {
    title = "Group only",
    lines = {
      "Lit: only your party or raid is counted.",
      "Dim: everyone recorded is counted.",
    },
  })
  groupBtn:SetPoint("RIGHT", petBtn, "LEFT", -4, 0)
  self.groupBtn = groupBtn

  local cogBtn = UI.IconButton(f.bar, UI.media.cog, 16, function()
    W.Guard("open settings", function() UI.settings:Toggle() end)
  end, { title = "Settings", lines = { "Appearance, recording and history." } })
  cogBtn:SetPoint("RIGHT", f.closeButton, "LEFT", -1, 0)
  self.cogBtn = cogBtn

  -- Posts whatever tab is open. Always via the channel picker and the
  -- confirmation; there is no one-click path to chat.
  local announceBtn = UI.Button(header, "Announce", 64, 18, nil)
  announceBtn:SetPoint("RIGHT", groupBtn, "LEFT", -4, 0)
  announceBtn:SetScript("OnClick", function()
    W.Guard("announce click", function()
      UI.AnnounceMenu(R.frame, announceBtn, R:AnnounceContext())
    end)
  end)
  self.announceBtn = announceBtn

  -- Other people's logs: browse who is sharing and pull from them.
  local peersBtn = UI.Button(header, "Shared", 52, 18, function()
    W.Guard("open peers", function() UI.peers:Toggle() end)
  end)
  peersBtn:SetPoint("RIGHT", announceBtn, "LEFT", -4, 0)
  self.peersBtn = peersBtn

  ------------------------------------------------------------------
  -- tabs
  ------------------------------------------------------------------

  local tabStrip = CreateFrame("Frame", nil, f.body)
  tabStrip:SetHeight(TAB_H)
  tabStrip:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
  tabStrip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
  local tabRule = UI.Line(tabStrip, W.color.border)
  tabRule:SetPoint("BOTTOMLEFT", tabStrip, "BOTTOMLEFT", 0, 0)
  tabRule:SetPoint("BOTTOMRIGHT", tabStrip, "BOTTOMRIGHT", 0, 0)

  --[[ Tab buttons.

       What each tab selects is stored ON the button rather than captured as
       a loop upvalue, and the handler reads it back through `this`. Vanilla's
       widget callbacks take no arguments and identify the clicked frame with
       the global `this`, so this is the shape the client expects; it also
       means the handler depends on nothing but the button it fired from.

       Guarded because the state assignments happen before Refresh, so an
       error here would escape the trap inside Refresh. ]]
  self.tabButtons = {}
  local x = 8
  for _, tab in ipairs(self.tabs) do
    local b = UI.Button(tabStrip, tab.label, 66, TAB_H - 2, nil)
    b:SetPoint("BOTTOMLEFT", tabStrip, "BOTTOMLEFT", x, 0)
    b.tabKey = tab.key
    b.tabMetric = tab.metric

    b:SetScript("OnClick", function()
      local btn = this or b
      W.Guard("tab click", function()
        if not R.state then R.state = {} end
        R.state.tab = btn.tabKey or "summary"
        R.state.drill = nil
        if btn.tabMetric then R.state.sortKey = btn.tabMetric end
        R:Refresh()
      end)
    end)

    self.tabButtons[tab.key] = b
    x = x + 68
  end

  ------------------------------------------------------------------
  -- content
  ------------------------------------------------------------------

  local content = CreateFrame("Frame", nil, f.body)
  content:SetPoint("TOPLEFT", tabStrip, "BOTTOMLEFT", 0, -1)
  content:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", 0, 0)
  self.content = content

  -- summary: chart on top, two tables underneath
  local chart = UI.Chart(content)
  chart:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -8)
  chart:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -8)
  chart:SetHeight(170)
  chart.onToggle = function() R:RefreshChart() end
  self.chart = chart

  local leftPane, leftList, leftTitle = self:MakeTablePane(content, "Damage Done")
  leftPane:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 0, -8)
  leftPane:SetPoint("BOTTOMRIGHT", content, "BOTTOM", -4, 8)
  self.sumLeft, self.sumLeftList, self.sumLeftTitle = leftPane, leftList, leftTitle

  local rightPane, rightList, rightTitle = self:MakeTablePane(content, "Healing Done")
  rightPane:SetPoint("TOPLEFT", chart, "BOTTOM", 4, -8)
  rightPane:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -8, 8)
  self.sumRight, self.sumRightList, self.sumRightTitle = rightPane, rightList, rightTitle

  -- single full-size table for the other tabs
  local mainPane, mainList, mainTitle = self:MakeTablePane(content, "")
  mainPane:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -8)
  mainPane:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -8, 8)
  self.mainPane, self.mainList, self.mainTitle = mainPane, mainList, mainTitle
  mainPane:Hide()

  f.OnResize = function() R:Refresh() end

  return f
end

--- A titled panel wrapping a scroll list, with a sort button on the right.
function R:MakeTablePane(parent, title)
  local pane = UI.Panel(parent, W.color.panel, W.color.border)

  local head = CreateFrame("Frame", nil, pane)
  head:SetHeight(22)
  head:SetPoint("TOPLEFT", pane, "TOPLEFT", 1, -1)
  head:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -1, -1)
  UI.Fill(head, W.color.panelHi, 0.7)

  local titleText = UI.Text(head, 11, W.color.text)
  titleText:SetPoint("LEFT", head, "LEFT", 8, 0)
  titleText:SetText(title)

  local total = UI.Text(head, 10, W.color.textDim, "RIGHT")
  total:SetPoint("RIGHT", head, "RIGHT", -8, 0)

  local rule = UI.Line(pane, W.color.border)
  rule:SetPoint("BOTTOMLEFT", head, "BOTTOMLEFT", 0, 0)
  rule:SetPoint("BOTTOMRIGHT", head, "BOTTOMRIGHT", 0, 0)

  local list = UI.ScrollList(pane, 18)
  list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 3, -3)
  list:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -4, 4)

  pane.titleText = titleText
  pane.totalText = total
  return pane, list, titleText
end

----------------------------------------------------------------------
-- menus
----------------------------------------------------------------------

function R:SessionMenu()
  local sessions = W.report:Sessions()
  local items = {}
  for i, s in ipairs(sessions) do
    local when = date("%m/%d %H:%M", s.startTime)
    table.insert(items, {
      text = (s.zone or "?") .. "  " .. when,
      value = i,
      checked = (i == self.state.sessionIndex),
    })
  end
  if table.getn(items) == 0 then
    items = { { text = "No sessions recorded", disabled = true } }
  end
  UI.Menu(self.frame, self.sessionBtn, items, function(value)
    self.state.sessionIndex = value
    self.state.selected = {}
    self:Refresh()
  end, SIDEBAR - 12)
end

----------------------------------------------------------------------
-- painting
----------------------------------------------------------------------

local function paintRow(row, item, index)
  local color = item._color or W.ClassColor(item.class)
  row:SetData(item._rank, item.name, item._text, item._sub, item._frac, color, 72)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function()
    W.Guard("row click", function()
      if arg1 == "RightButton" then
        R.state.drill = nil
      else
        R.state.drill = (R.state.drill == item.key) and nil or item.key
      end
      -- Any change of actor drops the ability we were inspecting.
      R.state.drillAbility = nil
      R:Refresh()
    end)
  end)
end

local function paintAbilityRow(row, item, index)
  row:SetData(index, item.name, W.Short(item.amount),
    string.format("%d hits  %.0f%%", item.hits, item._critPct),
    item._frac, item._color or W.color.accent, 92)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.abilityId = item.id
  row:SetScript("OnClick", function()
    local btn = this or row
    W.Guard("ability click", function()
      if arg1 == "RightButton" then
        R.state.drill = nil
        R.state.drillAbility = nil
      else
        R.state.drillAbility = btn.abilityId
      end
      R:Refresh()
    end)
  end)
end

--- Label/value lines for a single ability. No bar: these are statistics, not
--- a ranking, and a proportional bar would imply a comparison that isn't there.
local function paintStatRow(row, item, index)
  row:SetData(nil, item.label, item.value, item.note, 0, W.color.panelHi, 110)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function()
    W.Guard("stat click", function()
      R.state.drillAbility = nil
      R:Refresh()
    end)
  end)
end

--- Fill one table pane from a metric.
function R:FillTable(pane, list, view, metricKey, title)
  local rows, metric, total = W.report:Rank(view, metricKey,
    { search = self.state.search, groupOnly = self.state.groupOnly })

  pane.titleText:SetText(title or metric.label)

  if self.state.drill then
    local target
    for _, r in ipairs(rows) do if r.key == self.state.drill then target = r end end
    if target then
      local abilities, abTotal = W.report:Abilities(target, metricKey)
      local color = W.ClassColor(target.class)
      for _, a in ipairs(abilities) do a._color = color end

      -- Level two: the full spread for one ability.
      if self.state.drillAbility then
        local ability
        for _, a in ipairs(abilities) do
          if a.id == self.state.drillAbility then ability = a end
        end
        if ability then
          local stats = W.report:AbilityStats(ability, metricKey)
          pane.titleText:SetText(target.name .. "  -  " .. ability.name)
          pane.totalText:SetText("click to go back")
          list:SetData(stats, paintStatRow)
          return
        end
        self.state.drillAbility = nil
      end

      -- An empty drilldown needs to say why; see R:EmptyDetailNote.
      if table.getn(abilities) == 0 then
        pane.titleText:SetText(target.name .. "  -  " .. metric.label)
        pane.totalText:SetText("right-click to go back")
        list:SetData({ { label = W.report:EmptyDetailNote(view), value = "" } },
          paintStatRow)
        return
      end

      pane.titleText:SetText(target.name .. "  -  " .. metric.label)
      pane.totalText:SetText(W.Short(abTotal) .. "   (click an ability for detail)")
      list:SetData(abilities, paintAbilityRow)
      return
    end
  end

  for _, r in ipairs(rows) do
    r._color = metric.color or W.ClassColor(r.class)
  end

  if metric.percent or metric.integer then
    pane.totalText:SetText(table.getn(rows) .. " rows")
  else
    pane.totalText:SetText("Total " .. W.Short(total))
  end
  list:SetData(rows, paintRow)
end

function R:RefreshChart()
  local encounters = self:SelectedEncounters()
  local series, n, peak = W.report:Series(encounters, 3)
  local view = W.report:View(encounters, { petMode = self.state.petMode })
  self.chart:SetSeries(series, n, peak, view.deaths)
end

----------------------------------------------------------------------

function R:RefreshSidebar()
  local session = self:Session()
  if not session then
    self.sessionBtn.label:SetText("No data")
    self.encList:SetData({}, function() end)
    return
  end

  self.sessionBtn.label:SetText((session.zone or "?") .. "  " ..
    date("%m/%d", session.startTime))

  local _, isAll = self:SelectedEncounters()

  self.encList:SetData(session.encounters, function(row, enc, index)
    local key = encKey(enc)
    local on = self.state.selected[key] or isAll
    row.name:SetText(enc.name or "Trash")
    row.meta:SetText(W.Duration(enc.combat or 0) .. "   " ..
      W.Short((enc.totals and enc.totals.damage) or 0))

    row.lock:SetLit(enc.locked == true)
    row.lock:SetScript("OnClick", function()
      W.Guard("lock click", function()
        local nowLocked = W.ToggleLocked(enc)
        W.Print((nowLocked and "Keeping " or "Released ") ..
          "|cffe0a22c" .. (enc.name or "encounter") .. "|r" ..
          (nowLocked and " - it will survive pruning and reset." or "."))
      end)
    end)

    if on then
      row.bg:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 0.10)
      row.tick:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 1)
      row.name:SetTextColor(W.color.text[1], W.color.text[2], W.color.text[3], 1)
    else
      row.bg:SetVertexColor(0, 0, 0, 0)
      row.tick:SetVertexColor(0, 0, 0, 0)
      row.name:SetTextColor(W.color.textDim[1], W.color.textDim[2], W.color.textDim[3], 1)
    end

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function()
      if arg1 == "RightButton" then
        -- Toggle without clearing: build up a multi-encounter selection.
        if isAll then
          self.state.selected = {}
          for _, e in ipairs(session.encounters) do
            self.state.selected[encKey(e)] = true
          end
        end
        self.state.selected[key] = not self.state.selected[key] or nil
      else
        self.state.selected = { [key] = true }
      end
      self.state.drill = nil
      self:Refresh()
    end)
  end)
end

--- See the note on the meter's Refresh: a failure in here must not repeat
--- forever, and must name itself clearly enough to act on.
function R:Refresh()
  W.Guard("report refresh", function() R:RefreshInner() end)
end

function R:RefreshInner()
  local f = self.frame
  if not f or not f:IsShown() then return end

  for key, b in pairs(self.tabButtons) do b:SetActive(key == self.state.tab) end
  if self.groupBtn then self.groupBtn:SetLit(self.state.groupOnly == true) end
  self:RefreshSidebar()

  local session = self:Session()
  local encounters, isAll = self:SelectedEncounters()
  local view = W.report:View(encounters, { petMode = self.state.petMode })

  -- header
  local n = table.getn(encounters)
  if session then
    self.hTitle:SetText(session.zone or "Unknown")
    local label
    if isAll then
      label = n .. " encounters"
    elseif n == 1 then
      label = encounters[1].name .. (encounters[1].kill and "  (kill)" or "")
    else
      label = n .. " encounters selected"
    end
    self.hMeta:SetText(label .. "   -   " .. date("%d/%m/%y %H:%M", session.startTime))
  else
    self.hTitle:SetText("No raids recorded")
    self.hMeta:SetText("Wrekkit records automatically once you enter combat.")
  end

  self.hStats:SetText(
    W.Duration(view.combat) .. " combat    " ..
    W.Duration(view.elapsed) .. " elapsed\n" ..
    W.Short(view.totals.damage) .. " dmg    " ..
    W.Short(view.totals.healing) .. " heal")

  -- panes
  local tab = self.state.tab
  if tab == "summary" then
    self.mainPane:Hide()
    self.chart:Show() self.sumLeft:Show() self.sumRight:Show()
    self:RefreshChart()
    self:FillTable(self.sumLeft, self.sumLeftList, view, "damage", "Damage Done")
    self:FillTable(self.sumRight, self.sumRightList, view, "healing", "Healing Done")
  elseif tab == "deaths" then
    self.chart:Hide() self.sumLeft:Hide() self.sumRight:Hide()
    self.mainPane:Show()
    self:FillDeaths(view)
  else
    self.chart:Hide() self.sumLeft:Hide() self.sumRight:Hide()
    self.mainPane:Show()
    local metricKey = self.state.sortKey or "damage"
    for _, t in ipairs(self.tabs) do
      if t.key == tab and t.metric then metricKey = t.metric end
    end
    self:FillTable(self.mainPane, self.mainList, view, metricKey)
  end
end

function R:FillDeaths(view)
  local deaths = {}
  for _, d in ipairs(view.deaths) do table.insert(deaths, d) end
  table.sort(deaths, function(a, b) return (a.t or 0) < (b.t or 0) end)

  self.mainPane.titleText:SetText("Deaths")
  self.mainPane.totalText:SetText(table.getn(deaths) .. " total")

  self.mainList:SetData(deaths, function(row, d, index)
    row:SetData(index, d.name or "?", W.Clock(d.t or 0), d.encounter or "",
      0, W.ClassColor(d.class), 110)
    row:SetScript("OnClick", nil)
  end)
end

----------------------------------------------------------------------
-- public
----------------------------------------------------------------------

function R:Toggle()
  local f = self:Create()
  if f:IsShown() then f:Hide() else f:Show() self:Refresh() end
end

function R:Show()
  local f = self:Create()
  f:Show()
  self:Refresh()
end

--- Jump straight to a freshly finished encounter.
function R:OnEncounterFinished(enc)
  if self.frame and self.frame:IsShown() then self:Refresh() end
end

-- encounter.lua notifies W.ui; forward it to both windows.
function UI:OnEncounterFinished(enc)
  if UI.report and UI.report.frame then UI.report:OnEncounterFinished(enc) end
  if UI.meter and UI.meter.frame and UI.meter.frame:IsShown() then UI.meter:Refresh() end
end

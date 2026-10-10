--[[ Wrekkit :: ui/meter

The live window. Deliberately spare: a title bar that doubles as the mode
menu, one optional toolbar, and rows. Everything else lives in the report.

Interaction map, so the chrome can stay minimal:
  left-click title    metric menu, grouped (damage, healing, survival, ...)
  right-click title   window menu (report, threat window, compact, lock, ...)
  click the segment   which pulls: current, the last few, all session
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
-- The footer's height at text size 100%. It was 15, which with the text
-- centred left a band of space above the combat time (#15).
local FOOTER_H = 13

M.defaults = {
  -- Visible on login unless the user closed it last time. A meter you have
  -- to go and find is a meter nobody uses, but overriding a deliberate close
  -- every session would be worse, so the choice is remembered.
  shown = true,
  metric = "damage",
  -- Two metrics at once: "off" (one), "stacked" (`metric` on top, `metric2`
  -- underneath) or "side" (in columns), each list with its own drilldown.
  splitMode = "off",
  metric2 = "healing",
  segment = "current",
  petMode = "merge",
  groupOnly = false,
  -- Show only the players picked with shift-click (see W.report:Picked).
  pickedOnly = false,
  search = "",
  showToolbar = true,
  compact = false,
  rowHeight = 18,
  --[[ How the rows use the window's height:
         fixed    rows at rowHeight; the window decides how many fit
         stretch  as many as fit at rowHeight, stretched to fill it
         count    rowCount rows, stretched to fill it
         players  one row per player shown, stretched to fill it (each
                  at most PLAYERS_MAX times rowHeight)
       Fitting to rows (fitRows), when on, sizes the window instead. ]]
  rowMode = "fixed",
  rowCount = 8,
  -- Chrome opacity, 0-1. Only the panel, title bar and border fade; the
  -- text and bars stay fully opaque so the meter is readable at any value.
  opacity = 1.0,
  -- "show", "fade" or "hide": what the meter does while you are fighting.
  combat = "show",
  locked = false,
  -- Shrink to the rows shown, up to the height it was sized to (#15).
  fitRows = false,
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
--[[ How far back the segment menu offers to go, one pull at a time.

     "Last pull" on its own answers "how did that go", but the question after
     a wipe is usually comparative -- this attempt against the one before it --
     and the only way to ask it was to open the report window. ]]
M.PAST_PULLS = 4

--- Segment value -> how many pulls back it means. `last` is 1, kept under its
--- old name so a saved setting from an earlier version still resolves.
local BACK = { last = 1, back2 = 2, back3 = 3, back4 = 4, back5 = 5 }
M.BACK = BACK

local ORDINAL = { "Last pull", "2nd to last", "3rd to last", "4th to last",
                  "5th to last" }
M.ORDINAL = ORDINAL

--- The encounter `n` pulls back in this session, newest first, or nil.
function M:PullBack(n)
  local session = W.report:CurrentSession()
  if not session then return nil end
  local list = session.encounters
  local total = table.getn(list)
  if n > total then return nil end
  return list[total - n + 1], total
end

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

  local back = BACK[seg]
  if back then
    local enc = self:PullBack(back)
    --[[ Asked for a pull that is no longer there -- a reset, or a segment
         saved when the session was longer. Show the most recent one instead
         of an empty window, and let the label say which pull that is, so the
         title never claims to be showing something it is not. ]]
    if not enc then enc = self:PullBack(1) end
    if enc then return { enc }, enc.name end
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
    filter = self:Filter(),
    petMode = s.petMode,
    -- A drilldown IS what is on screen, so announcing has to know about it.
    drill = self.drill,
    drillAbility = self.drillAbility,
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

  --[[ Split: two metrics at once. On the title bar rather than the toolbar,
       which has no room left at the meter's narrowest and is gone in compact
       mode -- and a compact meter is exactly where a second metric saves
       opening another window. ]]
  local splitBtn = CreateFrame("Button", nil, f.bar)
  splitBtn:SetWidth(30)
  splitBtn:SetHeight(14)
  splitBtn:RegisterForClicks("LeftButtonUp")
  splitBtn.bg = UI.Fill(splitBtn, W.color.accent, 0)
  splitBtn.label = UI.Text(splitBtn, 9, W.color.textFaint, "CENTER")
  splitBtn.label:SetPoint("CENTER", splitBtn, "CENTER", 0, 0)
  splitBtn.label:SetText("1+2")
  splitBtn:SetPoint("RIGHT", cogBtn, "LEFT", -2, 0)
  splitBtn:SetScript("OnClick", function()
    W.Guard("meter split", function() M:CycleSplit() end)
  end)
  splitBtn:SetScript("OnEnter", function()
    if not GameTooltip then return end
    GameTooltip:SetOwner(splitBtn, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Two metrics: " .. (M.SPLIT_LABEL[M:SplitMode()] or ""))
    GameTooltip:AddLine("Click: one, over and under, side by side.", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("Click a half's header to pick its metric.", 0.72, 0.75, 0.8)
    GameTooltip:Show()
  end)
  splitBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  self.splitBtn = splitBtn

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
  titleHit:SetPoint("BOTTOMRIGHT", splitBtn, "BOTTOMLEFT", -2, 0)
  titleHit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  titleHit:SetScript("OnClick", function()
    if arg1 == "RightButton" then M:WindowMenu(titleHit) else M:MetricMenu(titleHit) end
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

  -- Show only the players picked. Next to group-only: both decide who is
  -- counted. Picking itself is shift-click on a row.
  local pickBtn = UI.IconButton(tb, UI.media.pick, 18, function()
    if arg1 == "RightButton" then
      UI.PickMenu(M.frame, M.pickBtn)
      return
    end
    local st = M:Settings()
    if not st.pickedOnly and not W.report:AnyPicked() then
      -- Filtering to nobody would only empty the meter; say how to pick.
      W.Print("nobody is picked yet: shift-click a player to pick them.")
      return
    end
    st.pickedOnly = not st.pickedOnly
    M:UpdateToggles()
    M:Refresh()
  end, UI.PICK_TIP)
  pickBtn:SetPoint("RIGHT", groupBtn, "LEFT", -2, 0)
  self.pickBtn = pickBtn

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
  worldBtn:SetPoint("RIGHT", pickBtn, "LEFT", -2, 0)
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

  --[[ The search box takes whatever width is left. At a fixed 110 it
       already met the icons at the meter's narrowest, and one more icon
       would have run them together; anchored between the edge and the Pets
       button it gives way instead of overlapping. ]]
  petBtn:ClearAllPoints()
  petBtn:SetPoint("RIGHT", resetBtn, "LEFT", -4, 0)
  search:ClearAllPoints()
  search:SetPoint("LEFT", tb, "LEFT", 4, 0)
  search:SetPoint("RIGHT", petBtn, "LEFT", -4, 0)

  ------------------------------------------------------------------
  -- list
  ------------------------------------------------------------------

  local list = UI.ScrollList(f.body, s.rowHeight)
  list:SetPoint("TOPLEFT", tb, "BOTTOMLEFT", 2, -2)
  list:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -2, 16)
  self.list = list

  -- The second half, when split: a header naming its metric -- click it
  -- to choose one, right-click to back out of a drilldown -- and its list.
  local head2 = CreateFrame("Button", nil, f.body)
  head2:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  head2.bg = UI.Fill(head2, W.color.panel, 0.8)
  head2.rule = UI.Line(head2, W.color.border)
  head2.rule:SetPoint("TOPLEFT", head2, "TOPLEFT", 0, 0)
  head2.rule:SetPoint("TOPRIGHT", head2, "TOPRIGHT", 0, 0)
  head2.label = UI.Text(head2, 10, W.color.text)
  head2.label:SetPoint("LEFT", head2, "LEFT", 6, 0)
  head2.right = UI.Text(head2, 10, W.color.textFaint, "RIGHT")
  head2.right:SetPoint("RIGHT", head2, "RIGHT", -6, 0)
  head2:SetScript("OnClick", function()
    if arg1 == "RightButton" then
      M.drill2, M.drillAbility2 = nil, nil
      M:Refresh()
    else
      W.Guard("second metric menu", function() M:MetricMenu(head2, 2) end)
    end
  end)
  head2:Hide()
  self.head2 = head2

  -- Side by side, the first column gets a header of its own, so the two
  -- columns line up and either metric is a click away.
  local head1 = CreateFrame("Button", nil, f.body)
  head1:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  head1.bg = UI.Fill(head1, W.color.panel, 0.8)
  head1.label = UI.Text(head1, 10, W.color.text)
  head1.label:SetPoint("LEFT", head1, "LEFT", 6, 0)
  head1.right = UI.Text(head1, 10, W.color.textFaint, "RIGHT")
  head1.right:SetPoint("RIGHT", head1, "RIGHT", -6, 0)
  head1:SetScript("OnClick", function()
    if arg1 == "RightButton" then
      M.drill, M.drillAbility = nil, nil
      M:Refresh()
    else
      W.Guard("metric menu", function() M:MetricMenu(head1) end)
    end
  end)
  head1:Hide()
  self.head1 = head1

  -- The line between the columns.
  local divider = f.body:CreateTexture(nil, "ARTWORK")
  divider:SetTexture(UI.media.white)
  divider:SetVertexColor(W.color.border[1], W.color.border[2], W.color.border[3], 1)
  divider:SetWidth(1)
  divider:Hide()
  self.divider = divider

  -- What the halves are laid out against (see LayoutPanes): the space
  -- between the toolbar and the footer, and a line across its middle.
  self.paneArea = CreateFrame("Frame", nil, f.body)
  self.paneMid = CreateFrame("Frame", nil, self.paneArea)

  local list2 = UI.ScrollList(f.body, s.rowHeight)
  list2:Hide()
  self.list2 = list2

  ------------------------------------------------------------------
  -- footer
  ------------------------------------------------------------------

  local footer = CreateFrame("Frame", nil, f.body)
  self.footer = footer
  footer:SetHeight(FOOTER_H)
  footer:SetPoint("BOTTOMLEFT", f.body, "BOTTOMLEFT", 0, 0)
  footer:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", 0, 0)

  self.footL = UI.Text(footer, 10, W.color.textFaint)
  -- Low in the footer: the space a footer needs is under its text, not over it.
  self.footL:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", 6, 2)
  self.footR = UI.Text(footer, 10, W.color.textFaint, "RIGHT")
  self.footR:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", -6, 2)

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

  f.OnResize = function()
    M:LayoutPanes()
    M:Refresh()
  end
  f.OnResizeEnd = function() M:SnapToRows() end
  f:SetScript("OnShow", function() M:StartTicker() end)

  self:UpdatePetButton()
  self:UpdateToggles()
  self:ApplyLayout()
  self:StartCombatWatch()
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
  if self.pickBtn then
    self.pickBtn:SetLit(self:Settings().pickedOnly == true and W.report:AnyPicked())
  end
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
  local footerH = compact and 0 or px(FOOTER_H)
  if compact then self.footer:Hide() else self.footer:Show() end
  self.footer:SetHeight(footerH > 0 and footerH or 1)
  self.list:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -2, footerH + 1)

  self.list:SetRowHeight(px(s.rowHeight or 18))
  if self.list2 then self.list2:SetRowHeight(px(s.rowHeight or 18)) end

  -- Where the lists may go, for LayoutPanes: below the toolbar (when there
  -- is one) and above the footer.
  self.paneTop = showToolbar and (px(22) + 2) or 2
  self.paneBottom = footerH + 1
  self.headH = px(16)
  self:LayoutPanes()
  self:UpdateSplitButton()

  if f.SetOpacity then f:SetOpacity(s.opacity) end

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
    -- Over and under: two rows in each half, and the second half's header.
    -- Side by side: the headers, and room for two columns.
    local minW = px(260)
    local mode = self:SplitMode()
    if mode == "stacked" then
      chrome = chrome + rowH * 2 + px(16)
    elseif mode == "side" then
      chrome = chrome + px(16)
      minW = M.SideMinWidth()
    end
    f:SetMinResize(minW, chrome + rowH * 2)
    -- Already narrower than that -- saved before the minimum was raised, or
    -- side by side switched on elsewhere: widen it now, not on the next drag.
    if (f:GetWidth() or minW) < minW then
      f:SetWidth(minW)
      if f.SavePosition then f:SavePosition() end
    end
  end

  self:Refresh()
end

--- Kept for the segment menu's toolbar entry and older call sites.
function M:ApplyToolbar()
  self:ApplyLayout()
end

----------------------------------------------------------------------
-- two metrics
----------------------------------------------------------------------

--[[ How many metrics, and how. "off": one. "stacked": two, the second
     under the first. "side": two in columns, each under its own header.
     A boolean `split` from before the third option means "stacked". ]]
local SPLIT_MODES = { off = true, stacked = true, side = true }
local SPLIT_NEXT = { off = "stacked", stacked = "side", side = "off" }
local SPLIT_LABEL = { off = "One metric", stacked = "Two: over and under", side = "Two: side by side" }
M.SPLIT_LABEL = SPLIT_LABEL

--[[ Columns need room for a name and a number each. 300 is two 150-pixel
     columns: a short name and its number, once a narrow row has dropped its
     per-second column (see UI.Row). 400 was roomier than people wanted. ]]
local SIDE_MIN_W = 300
M.SIDE_MIN_W = SIDE_MIN_W

--[[ How narrow side by side may go. Larger text needs more, but smaller
     text does not make do with less: the rank gutter and the gaps do not
     shrink with it, and at 70% a minimum scaled down to 280 left two
     140-pixel columns with no room for a name. ]]
function M.SideMinWidth()
  local scaled = math.floor(SIDE_MIN_W * UI.FontScale() + 0.5)
  if scaled < SIDE_MIN_W then return SIDE_MIN_W end
  return scaled
end

function M:SplitMode()
  local s = self:Settings()
  -- Checked before splitMode: the defaults have filled that in as "off" by
  -- now, and an old "on" must not be lost to it.
  if s.split == true then s.splitMode = "stacked" end
  s.split = nil
  if not SPLIT_MODES[s.splitMode or ""] then s.splitMode = "off" end
  return s.splitMode
end

--- Is the meter showing two metrics?
function M:Split()
  return self.list2 ~= nil and self:SplitMode() ~= "off"
end

--- One metric, two over and under, or two side by side. `true` and `false`
--- mean "stacked" and "off", for callers from before the third option.
function M:SetSplit(mode)
  if mode == true then mode = "stacked" elseif mode == false or mode == nil then mode = "off" end
  if not SPLIT_MODES[mode] then mode = "off" end
  local s = self:Settings()
  s.splitMode, s.split = mode, nil
  -- The second metric starts as something other than the first.
  if mode ~= "off" and s.metric2 == s.metric then
    s.metric2 = (s.metric == "healing") and "damage" or "healing"
  end
  self.drill2, self.drillAbility2 = nil, nil
  -- Side by side, widen a window too narrow for two columns.
  local f = self.frame
  if mode == "side" and f then
    local want = M.SideMinWidth()
    if (f:GetWidth() or 0) < want then
      f:SetWidth(want)
      if f.SavePosition then f:SavePosition() end
    end
  end
  self:ApplyLayout()
  if UI.settings and UI.settings.Refresh then UI.settings:Refresh() end
end

--- The title-bar button: one, over and under, side by side, in turn.
function M:CycleSplit()
  self:SetSplit(SPLIT_NEXT[self:SplitMode()] or "off")
end

function M:UpdateSplitButton()
  local b = self.splitBtn
  if not b then return end
  local mode = self:SplitMode()
  local on = (mode ~= "off")
  local c = on and W.color.accent or W.color.textFaint
  b.label:SetText(mode == "side" and "1||2" or (mode == "stacked" and "1/2" or "1+2"))
  b.label:SetTextColor(c[1], c[2], c[3], 1)
  b.bg:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], on and 0.18 or 0)
end

--[[ Share the space between the lists. Stacked, each gets half of the
     height between the toolbar and the footer, the second under its header.
     Side by side, each gets half the width, both under a header. One metric,
     the one list has all of it.

     Entirely by anchors, through an invisible area spanning the space and a
     1-pixel line across its middle: a frame anchored by its TOP to another's
     TOP sits at that one's horizontal centre, so the client keeps the halves
     equal at every size. This used to be worked out from the body's width,
     and right after a resize the client can still report the old one: the
     columns came out unequal, the first one narrower, until the next relayout. ]]
function M:LayoutPanes()
  local f = self.frame
  if not f or not self.list2 then return end
  local top, bottom = self.paneTop or 2, self.paneBottom or 16
  local mode = self:SplitMode()

  if mode == "off" then
    self.head1:Hide()
    self.head2:Hide()
    self.list2:Hide()
    self.divider:Hide()
    self.list:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -2, bottom)
    return
  end

  local headH = self.headH or 16
  local area, mid = self.paneArea, self.paneMid
  area:ClearAllPoints()
  area:SetPoint("TOPLEFT", f.body, "TOPLEFT", 0, -top)
  area:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", 0, bottom)
  mid:ClearAllPoints()
  self.head2:ClearAllPoints()
  self.head2:SetHeight(headH)
  self.list2:ClearAllPoints()

  if mode == "side" then
    -- A vertical line down the middle of the area.
    mid:SetWidth(1)
    mid:SetPoint("TOP", area, "TOP", 0, 0)
    mid:SetPoint("BOTTOM", area, "BOTTOM", 0, 0)
    self.head1:ClearAllPoints()
    self.head1:SetHeight(headH)
    self.head1:SetPoint("TOPLEFT", area, "TOPLEFT", 0, 0)
    self.head1:SetPoint("TOPRIGHT", mid, "TOPLEFT", 0, 0)
    self.list:SetPoint("TOPLEFT", self.head1, "BOTTOMLEFT", 2, -1)
    self.list:SetPoint("BOTTOMRIGHT", mid, "BOTTOMLEFT", -2, 0)
    self.head2:SetPoint("TOPLEFT", mid, "TOPRIGHT", 0, 0)
    self.head2:SetPoint("TOPRIGHT", area, "TOPRIGHT", 0, 0)
    self.divider:ClearAllPoints()
    self.divider:SetAllPoints(mid)
    self.head1:Show()
    self.divider:Show()
  else
    -- A horizontal line across the middle, raised by half a header so the
    -- second list, under its header, ends up the same height as the first.
    local lift = math.floor(headH / 2)
    mid:SetHeight(1)
    mid:SetPoint("LEFT", area, "LEFT", 0, lift)
    mid:SetPoint("RIGHT", area, "RIGHT", 0, lift)
    self.head1:Hide()
    self.divider:Hide()
    self.list:SetPoint("BOTTOMRIGHT", mid, "TOPRIGHT", -2, 0)
    self.head2:SetPoint("TOPLEFT", mid, "BOTTOMLEFT", 0, 0)
    self.head2:SetPoint("TOPRIGHT", mid, "BOTTOMRIGHT", 0, 0)
  end

  self.list2:SetPoint("TOPLEFT", self.head2, "BOTTOMLEFT", 2, -1)
  self.list2:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -2, 0)
  self.head2:Show()
  self.list2:Show()
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

--[[ Metrics in groups, each under a section header. Seventeen entries in
     one column is a list to read; five short groups is a menu to glance
     at. A metric not named here still appears, under "Other", so adding
     one to W.metrics can never make it unreachable. ]]
local METRIC_GROUPS = {
  { "Damage", { "damage", "dps", "crit" } },
  { "Healing", { "healing", "hps", "healingTotal", "overheal" } },
  { "Survival", { "taken", "absorbed", "deaths" } },
  { "Utility", { "dispels", "interrupts", "consumes", "uptime" } },
  { "Enemies", { "enemy", "enemyTaken" } },
}
M.METRIC_GROUPS = METRIC_GROUPS

--- `which` 2 picks the second metric of a split meter; otherwise the first.
function M:MetricMenu(anchor, which)
  local s = self:Settings()
  local second = (which == 2)
  local current = second and s.metric2 or s.metric
  local items, placed = {}, {}
  local function add(m)
    placed[m.key] = true
    table.insert(items, { text = W.metrics.Label(m), value = m.key, checked = (m.key == current) })
  end
  for _, g in ipairs(METRIC_GROUPS) do
    local first = true
    for _, key in ipairs(g[2]) do
      local m = W.metrics.byKey[key]
      if m then
        if first then
          table.insert(items, { text = g[1], header = true })
          first = false
        end
        add(m)
      end
    end
  end
  local other = false
  for _, m in ipairs(W.metrics.list) do
    if not placed[m.key] then
      if not other then
        table.insert(items, { text = "Other", header = true })
        other = true
      end
      add(m)
    end
  end
  -- Not in W.metrics: it ranks nobody's recorded totals, it is the server's
  -- live table for your target, so the report has nothing to sort by it.
  -- The first metric only: the threat table has one place to be drawn.
  if not second then
    table.insert(items, { text = "Live", header = true })
    table.insert(items, { text = "Threat", value = "threat", checked = (s.metric == "threat") })
  end

  UI.Menu(self.frame, anchor, items, function(value)
    if not value then return end
    if second then
      s.metric2 = value
      M.drill2, M.drillAbility2 = nil, nil
      M:Refresh()
    else
      M:SetMetric(value)
    end
  end, 180)
end

--- The segment picker: which pulls the meter covers, and nothing else.
function M:SegmentMenu(anchor)
  local s = self:Settings()
  local items = {
    { text = "Show", header = true },
    { text = "Current pull", value = "current", checked = (s.segment == "current") },
  }

  --[[ Named after the pull rather than numbered alone: "3rd to last" is only
       an answer if you already remember what the third to last pull was, and
       after a run of wipes on two different bosses nobody does. ]]
  for i = 1, M.PAST_PULLS do
    local enc = M:PullBack(i)
    if enc then
      local value = (i == 1) and "last" or ("back" .. i)
      table.insert(items, {
        text = ORDINAL[i] .. "  |cff9d9d9d" .. (enc.name or "?") .. "|r",
        value = value,
        checked = (s.segment == value),
      })
    end
  end

  table.insert(items,
    { text = "All Session", value = "overall", checked = (s.segment == "overall") })

  UI.Menu(self.frame, anchor, items, function(value)
    if not value then return end
    s.segment = value
    self.drill = nil
    self.drillAbility = nil
    self:Refresh()
  end, 200)
end

--[[ Everything about the window itself, on a right-click of the title.

     These used to sit under the segment list, behind a "-- windows --"
     divider, so changing what the meter showed and hiding it altogether
     were one misclick apart. ]]
function M:WindowMenu(anchor)
  local s = self:Settings()
  local ts = W.threat:Settings()
  local threatShown = (ts.display == "window" or ts.display == "docked")
  local items = {
    { text = "Windows", header = true },
    { text = "Full report", value = "report" },
    { text = "Threat window", value = "threat", checked = threatShown },
    { text = "Announce to chat...", value = "announce" },
    { text = "Meter", header = true },
    { text = "Compact", value = "compact", checked = s.compact == true },
    { text = "Toolbar", value = "toolbar", checked = s.showToolbar ~= false },
    { text = "Lock position", value = "lock", checked = s.locked == true },
    { text = "Metrics shown", header = true },
    { text = M.SPLIT_LABEL.off, value = "split:off", checked = M:SplitMode() == "off" },
    { text = M.SPLIT_LABEL.stacked, value = "split:stacked", checked = M:SplitMode() == "stacked" },
    { text = M.SPLIT_LABEL.side, value = "split:side", checked = M:SplitMode() == "side" },
    { text = "Log", header = true },
    { text = "Start a new log", value = "reset" },
    { text = "", header = true },
    { text = "Settings...", value = "settings" },
    { text = "Hide meter", value = "hide" },
  }

  UI.Menu(self.frame, anchor, items, function(value)
    if value == "settings" then
      UI.settings:Show()
    elseif value == "announce" then
      if s.metric == "threat" then
        W.Print("threat is live and changes every half second; switch the meter " ..
          "to a recorded metric to announce it.")
        return
      end
      UI.AnnounceMenu(self.frame, anchor, M:AnnounceContext())
    elseif value == "threat" then
      if threatShown then
        UI.threat:SetDisplay("off")
      else
        UI.threat:SetDisplay(ts.lastWindow or "docked")
      end
    elseif value == "hide" then
      M:Hide()
      W.Print("meter hidden. |cffe0a22c/wrek|r or the minimap button brings it back.")
    elseif value == "report" then
      if UI.report then UI.report:Toggle() end
    elseif value and string.sub(value, 1, 6) == "split:" then
      self:SetSplit(string.sub(value, 7))
    elseif value == "compact" then
      s.compact = not s.compact
      self:ApplyLayout()
    elseif value == "toolbar" then
      s.showToolbar = not (s.showToolbar ~= false)
      self:ApplyLayout()
    elseif value == "lock" then
      s.locked = not s.locked
    elseif value == "reset" then
      W.ResetData()
    end
    if UI.settings and UI.settings.Refresh then UI.settings:Refresh() end
  end, 190)
end

----------------------------------------------------------------------
-- painting
----------------------------------------------------------------------

--[[ What one person's number is made of, without having to click into it.

     The drilldown already computes exactly this, so the tooltip asks the same
     question of the same function rather than adding a second way to total up
     a row -- two of those would drift, and the one nobody is looking at would
     be the one that was wrong.

     The totals come off the row as already formatted, so what the tooltip
     says and what the bar says cannot disagree. ]]
local MAX_DETAIL = 12

local function actorTooltip(row, item, metricKey)
  if not GameTooltip then return end
  metricKey = metricKey or M:Settings().metric
  local metric = W.metrics.Get(metricKey)
  local c = item._color or W.ClassColor(item.class)

  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(item.name or "?", c[1], c[2], c[3])
  GameTooltip:AddDoubleLine(W.metrics.Label(metric), item._text or "",
    0.78, 0.80, 0.85, 1, 1, 1)
  if item._sub and item._sub ~= "" then
    GameTooltip:AddDoubleLine(" ", item._sub, 1, 1, 1, 0.62, 0.65, 0.72)
  end

  local abilities = W.report:Abilities(item, metricKey)
  local n = table.getn(abilities)
  if n > 0 then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Details:", 0.88, 0.64, 0.17)
    for i = 1, n do
      if i > MAX_DETAIL then
        GameTooltip:AddLine("and " .. (n - MAX_DETAIL) .. " more",
          0.62, 0.65, 0.72)
        break
      end
      local a = abilities[i]
      -- Buff rows arrive with their value already written (a share of the
      -- fight); abilities are an amount and a share of the total.
      local value = a._value or
        (W.Short(a.amount) .. string.format(" (%.1f%%)", a._pct or 0))
      GameTooltip:AddDoubleLine(a.label or a.name, value,
        0.78, 0.80, 0.85, 1, 1, 1)
    end
  else
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(W.report:EmptyDetailNote(M.lastView), 0.62, 0.65, 0.72, 1)
  end

  if item.remote then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("* includes this player's own report of their numbers:",
      0.62, 0.65, 0.72)
    GameTooltip:AddLine("  they were out of range, so their client filled the gap.",
      0.62, 0.65, 0.72)
  end

  GameTooltip:Show()
end

--[[ The meter's lists, as panes. One normally; two when split, the second
     ranking its own metric under its own header. Each pane keeps its own
     drilldown in fields on M -- drill/drillAbility for the first, which is
     what every older caller reads, drill2/drillAbility2 for the second -- so
     opening a player in one half leaves the other alone. ]]
local PANES = {
  { metricKey = "metric", drillField = "drill", abilityField = "drillAbility", listField = "list" },
  { metricKey = "metric2", drillField = "drill2", abilityField = "drillAbility2", listField = "list2" },
}
M.PANES = PANES

--- The three row painters for one pane: players, a player's abilities, and
--- one ability's statistics. They read the pane's metric and write its
--- drilldown, so the same code serves both halves.
local function makePainters(pane)
  local function metricKey() return M:Settings()[pane.metricKey] end
  local function setDrill(key, ability)
    M[pane.drillField] = key
    M[pane.abilityField] = ability
  end

  local function paintActor(row, item, index)
    local color = item._color or W.ClassColor(item.class)
    if item.isPlayer then row:SetClass(item.class) end
    row:SetData(item._rank, UI.RowName(item, M:Settings().pickedOnly),
      item._text, item._sub, item._frac, color, 58)
    row.tip = function(self) actorTooltip(self, item, metricKey()) end
    --[[ The meter repaints twice a second. Without this the numbers under the
         cursor are frozen at whatever they were when the tooltip opened, which
         is worst exactly when someone is watching a pull happen. ]]
    if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(row) then
      row:tip()
    end
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function()
      -- Shift-click picks or unpicks the player, rather than opening them.
      if UI.ShiftPick(item) then return end
      if arg1 == "RightButton" then setDrill(nil, nil) else setDrill(item.key, nil) end
      UI.meter:Refresh()
    end)
  end

  local function paintAbility(row, item, index)
    local color = item._color or W.color.accent
    local label = item.label or item.name
    -- The buff Buff Uptime is ranking by, so it can be found again to clear.
    if item._selected then label = "|cffe0a22c>|r " .. (label or "?") end
    row:SetData(index, label,
      item._value or W.Short(item.amount),
      item._note or string.format("%.0f%%", item._pct or 0),
      item._frac, color, 42)
    -- Rows are reused, so a row that carried the actor tooltip a moment ago
    -- would go on describing someone who is no longer in this list.
    row.tip = nil
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Stashed on the row, not captured, for the same reason: reuse.
    row.abilityId = item.id
    row.abilityName = item.name
    row.selectsBuff = item._select
    row:SetScript("OnClick", function()
      local btn = this or row
      if arg1 == "RightButton" then
        M[pane.drillField] = nil
      elseif btn.selectsBuff then
        -- A buff: rank everybody by it, or stop if it already was.
        W.metrics.SelectBuff(btn.abilityId, btn.abilityName)
        setDrill(nil, nil)
      else
        -- Second level: the spread for this one ability.
        M[pane.abilityField] = btn.abilityId
      end
      UI.meter:Refresh()
    end)
  end

  --- Label/value lines, no bar -- these are statistics, not a ranking, and a
  --- proportional bar behind them would imply a comparison that isn't there.
  local function paintStat(row, item, index)
    row:SetData(nil, item.label, item.value, item.note, 0, W.color.panelHi, 52)
    row.tip = nil
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function()
      M[pane.abilityField] = nil
      UI.meter:Refresh()
    end)
  end

  return paintActor, paintAbility, paintStat
end

for _, pane in ipairs(PANES) do
  pane.paintActor, pane.paintAbility, pane.paintStat = makePainters(pane)
end

--[[ The aggregate behind the rows, rebuilt only when it can have changed.

     Building a view merges every actor of every pull in the segment, and
     the meter repaints twice a second. For a segment of finished pulls --
     the last pull, All Session -- the answer is identical every time, so
     rebuilding it was all cost: hundreds of tables a second for a picture
     that did not move. A pull still being recorded is never cached.

     The cache and its fingerprint live in report.lua (R:NewCache). ]]
local viewCache

local function cachedView(encounters, petMode)
  viewCache = viewCache or W.report:NewCache()
  return viewCache:View(encounters, { petMode = petMode })
end

--- Forget the cached view, for anything that changes stored pulls in a
--- way the fingerprint cannot see.
function M:InvalidateView()
  W.report:Invalidate()
end

--- Repaints run on a ticker, so an error here would fire twice a second and
--- bury its own first occurrence. Guard reports each distinct one once.
function M:Refresh()
  W.Guard("meter refresh", function()
    M:RefreshInner()
    M:Fit()
  end)
end

--[[ After a resize, take off the part of a row the list cannot use.

     The list draws whole rows only, so whatever height is left under the
     last one is blank -- up to a row of it, right above the footer (#15).
     Trimmed a moment after the grip is let go, once the client reports the
     list's new height. Not when fitting to rows (that sizes to whole rows
     already), nor over and under, where the halves share the height. ]]
function M:SnapToRows()
  W.After(0.05, function()
    W.Guard("meter snap", function() M:TrimPartialRow() end)
  end, "meterSnap")
end

--[[ /wrek layout: the meter's real sizes, as the client reports them, for
     a drawing problem the offline tests cannot see -- they have no layout
     engine, so a width that is wrong only in the game never shows there. ]]
function M:DescribeLayout()
  local f = self.frame
  if not f then W.Print("the meter has not been built yet.") return end
  local s = self:Settings()
  local function n(v) return v and string.format("%.1f", v) or "nil" end
  W.Print(string.format("meter %sx%s  body %sx%s  inset %s  split %s  rows %s  fit %s",
    n(f:GetWidth()), n(f:GetHeight()), n(f.body:GetWidth()), n(f.body:GetHeight()),
    tostring(f.inset), self:SplitMode(), tostring(s.rowMode), tostring(s.fitRows)))
  local lists = { { "list", self.list } }
  if self:Split() and self.list2 then table.insert(lists, { "list2", self.list2 }) end
  for _, e in ipairs(lists) do
    local list = e[2]
    W.Print(string.format("  %s %sx%s  rowH %s  visible %d of %d  scroll inset %s  track %s",
      e[1], n(list:GetWidth()), n(list:GetHeight()), n(list.rowHeight),
      list:VisibleCount(), table.getn(list.data or {}), tostring(list._anchorW),
      list.track:IsShown() and "shown" or "hidden"))
    for i = 1, 2 do
      local r = list.rows[i]
      if r and r:IsShown() then
        local item = list.data[i + (list.offset or 0)]
        W.Print(string.format("    row %d: %sx%s  bar %s  share %s  left %s right %s",
          i, n(r:GetWidth()), n(r:GetHeight()), n(r.bar:GetWidth()),
          n(item and item._frac), n(r:GetLeft()), n(r:GetRight())))
      end
    end
  end
end

--- Take the blank part-row off now, if there is one. Also run on every
--- redraw (M:Fit), so a window sized before this existed -- or changed by
--- a text size, a row height or a layout -- loses it without a resize.
--- Once trimmed there is nothing left over, so it settles at once.
function M:TrimPartialRow()
  local f = self.frame
  -- Never mid-drag: re-anchoring or resizing a moving frame crashes the client.
  if not f or f._sizing or f._moving or self:Settings().fitRows or self:SplitMode() == "stacked" then return end
  -- Stretched rows fill the window already; there is no part-row to trim.
  if (self:Settings().rowMode or "fixed") ~= "fixed" then return end
  local rowH = self.list.rowHeight or 18
  local listH = self.list:GetHeight() or 0
  if listH <= rowH then return end
  local extra = math.mod(listH, rowH)
  if extra < 1 then return end
  UI.AnchorTop(f)
  f:SetHeight(f:GetHeight() - extra)
  if f.SavePosition then f:SavePosition() end
end

--[[ Fit the window to its rows, when asked to (#15). Side by side, to the
     longer column. Over and under, each half has its own share of the
     height, so the window keeps the height it was given. ]]
--[[ Set each list's row height for the row mode. "fixed": the Row height
     setting. "stretch": as many rows as fit at that height, stretched to
     fill the list exactly. "count": the chosen number of rows, stretched
     to fill it. Fitting to rows sizes the window to the rows instead, so
     there the rows keep the Row height. Each half of a split meter fills
     its own list. Run on every redraw, so a resize, a layout or a text
     size is followed at once. ]]
-- "players": the tallest a row may stretch, in Row heights.
local PLAYERS_MAX = 3

function M:SizeRows()
  -- Not mid-drag: the rows are laid out again once the window is let go.
  local f = self.frame
  if f and (f._moving or f._sizing) then return end
  local s = self:Settings()
  local mode = s.rowMode or "fixed"
  local base = math.floor((s.rowHeight or 18) * UI.FontScale() + 0.5)
  local lists = { self.list }
  if self:Split() and self.list2 then table.insert(lists, self.list2) end
  for _, list in ipairs(lists) do
    local h = base
    if mode ~= "fixed" and not s.fitRows then
      local listH = list:GetHeight() or 0
      local n
      if mode == "count" then
        n = tonumber(s.rowCount) or 8
      elseif mode == "players" then
        n = table.getn(list.data or {})
      else
        n = math.floor(listH / base + 0.001)
      end
      if n < 1 then n = 1 end
      if listH > 0 then h = listH / n end
      if h < 8 then h = 8 end
      -- One player is not one bar the height of the window.
      if mode == "players" and h > base * PLAYERS_MAX then h = base * PLAYERS_MAX end
    end
    if math.abs((list.rowHeight or 0) - h) > 0.01 then list:SetRowHeight(h) end
  end
end

function M:Fit()
  local f = self.frame
  if not f or not f:IsShown() then return end
  self:SizeRows()
  local mode = self:SplitMode()
  if not self:Settings().fitRows or mode == "stacked" then
    UI.UnfitHeight(f)
    self:TrimPartialRow()
    return
  end
  local n = table.getn(self.list.data or {})
  if mode == "side" and self.list2 then
    local n2 = table.getn(self.list2.data or {})
    if n2 > n then n = n2 end
  end
  UI.FitHeight(f, self.list, n)
end

--[[ Draw one pane from an already-built view, and say what its labels
     should read: { title, seg, footL, footR }. The first pane's go on the
     title bar and footer; the second's on its own header. ]]
function M:RenderPane(pane, view, segLabel)
  local s = self:Settings()
  local list = self[pane.listField]
  local metricKey = s[pane.metricKey]
  local metric = W.metrics.Get(metricKey)
  local rows, _, total = W.report:Rank(view, metricKey, self:Filter())
  local out = { title = W.metrics.Label(metric), seg = segLabel }

  local drill = self[pane.drillField]
  if drill then
    local target
    for _, r in ipairs(rows) do
      if r.key == drill then target = r end
    end
    if not target then
      self[pane.drillField] = nil
      self[pane.abilityField] = nil
    else
      local abilities = W.report:Abilities(target, metricKey)
      local color = W.ClassColor(target.class)
      for _, a in ipairs(abilities) do a._color = color end

      -- Level two: the spread for a single ability.
      local drillAbility = self[pane.abilityField]
      if drillAbility then
        local ability
        for _, a in ipairs(abilities) do
          if a.id == drillAbility then ability = a end
        end
        if ability then
          local stats = W.report:AbilityStats(ability, metricKey)
          out.seg = target.name .. " - " .. (ability.label or ability.name)
          list:SetData(stats, pane.paintStat)
          out.footL, out.footR = (ability.label or ability.name), "click to go back"
          return out
        end
        self[pane.abilityField] = nil
      end

      -- An empty drilldown needs to say why; see R:EmptyDetailNote.
      if table.getn(abilities) == 0 then
        out.seg = target.name
        list:SetData({ { label = W.report:EmptyDetailNote(view), value = "" } }, pane.paintStat)
        out.footL, out.footR = target.name, "click to go back"
        return out
      end

      -- Level one: which abilities made up that number.
      out.seg = target.name .. " - " .. segLabel
      list:SetData(abilities, pane.paintAbility)
      if metric.detail == "auras" then
        out.footL = string.format("%d buffs", table.getn(abilities))
        out.footR = "click one to rank everyone by it"
      else
        out.footL = string.format("%d abilities", table.getn(abilities))
        out.footR = W.Short(target._v) .. "  (click one for detail)"
      end
      return out
    end
  end

  for _, r in ipairs(rows) do
    r._color = metric.color or W.ClassColor(r.class)
  end
  list:SetData(rows, pane.paintActor)

  local live = W.encounter.live and W.encounter:ReallyInCombat()
  out.footL = (live and "|cffe0a22c* |r" or "") .. W.Duration(view.rateBase) .. " combat time"
  if metric.percent or metric.integer then
    out.footR = table.getn(rows) .. " shown"
  else
    out.footR = W.metrics.Format(metric, total) .. " total"
  end
  -- Only picked players, and none of them in this segment: say so, rather
  -- than show an empty meter that looks broken.
  if table.getn(rows) == 0 and s.pickedOnly and W.report:AnyPicked() then
    out.footR = "no picked players here"
  end
  return out
end

function M:RefreshInner()
  local f = self.frame
  if not f or not f:IsShown() then return end

  local s = self:Settings()
  local split = self:Split()
  local encounters, segLabel = self:Encounters()

  local view
  if s.metric ~= "threat" or split then
    view = cachedView(encounters, s.petMode)
    -- Kept for the hover tooltip, which needs it to explain an empty detail.
    self.lastView = view
  end

  -- The second half: its metric and, when drilled in, whose detail it is,
  -- on its header, with its total where the footer would put it.
  if split then
    local o = self:RenderPane(PANES[2], view, segLabel)
    local where = (o.seg ~= segLabel) and ("  |cff9d9d9d" .. o.seg .. "|r") or ""
    self.head2.label:SetText(o.title .. where)
    self.head2.right:SetText(o.footR or "")
  end

  local side = split and self:SplitMode() == "side"
  if s.metric == "threat" then
    self:RefreshThreat()
    if side then
      self.head1.label:SetText("Threat")
      self.head1.right:SetText("")
    end
    return
  end
  local o = self:RenderPane(PANES[1], view, segLabel)
  f.title:SetText(o.title)
  self:SetSegmentLabel(o.seg)
  self.footL:SetText(o.footL or "")
  self.footR:SetText(o.footR or "")
  -- Side by side, the first column's header says the same, so the two
  -- columns read alike; the footer keeps the combat time.
  if side then
    local where = (o.seg ~= segLabel) and ("  |cff9d9d9d" .. o.seg .. "|r") or ""
    self.head1.label:SetText(o.title .. where)
    self.head1.right:SetText(o.footR or "")
  end
end

--[[ The meter as a threat meter: the same rows the threat window draws,
     painted by the same function, so the two never disagree. ]]
function M:RefreshThreat()
  local f = self.frame
  local cur = W.threat:Live()
  local rows = UI.threat.Rows(cur)
  f.title:SetText("Threat")
  self.drill = nil
  self.drillAbility = nil
  if table.getn(rows) == 0 then
    self:SetSegmentLabel("")
    self.list:SetData({ { label = UI.threat.EmptyNote() } }, UI.threat.PaintNote)
    self.footL:SetText("")
    self.footR:SetText("")
    return
  end
  self:SetSegmentLabel(cur and cur.name or "")
  self.list:SetData(rows, UI.threat.Paint)
  self.footL:SetText(cur and ("aggro: " .. (cur.tank and cur.tank.name or "?")) or "")
  self.footR:SetText(W.threat.demoUntil and "preview" or "")
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
-- picked players
----------------------------------------------------------------------

-- Shared by the meter and the report: the same picks, the same gesture and
-- the same marks, so the two windows never disagree about who is picked.

UI.PICK_TIP = {
  title = "Picked players",
  lines = {
    "Shift-click a player to pick or unpick them.",
    "Lit: only picked players are shown.",
    "Right-click: see the picks, or clear them.",
  },
}

--- A player row's name as drawn. Marked if picked -- unless only picked
--- players are showing, when every row is one and the mark is noise -- and
--- marked * when filled from that player's own report, not measured here.
function UI.RowName(item, pickedOnly)
  local name = item.name or "?"
  if not pickedOnly and (item.isPlayer or item.class == "PET")
     and W.report:IsPicked(item.ownerName or item.name) then
    name = "|cffe0a22c>|r " .. name
  end
  if item.remote then name = name .. "|cff9d9d9d*|r" end
  return name
end

--- Shift-click on a row picks or unpicks that player; a pet picks its
--- owner. Returns true when it handled the click.
function UI.ShiftPick(item)
  if arg1 ~= "LeftButton" then return false end
  if not (IsShiftKeyDown and IsShiftKeyDown()) then return false end
  if not (item.isPlayer or item.class == "PET") then return false end
  W.report:TogglePick(item.ownerName or item.name)
  UI.PicksChanged()
  return true
end

--- After the picks change. With nobody left picked, "only picked" turns
--- itself off in both windows -- otherwise the next pick would silently
--- start filtering again -- and both windows redraw.
function UI.PicksChanged()
  if not W.report:AnyPicked() then
    M:Settings().pickedOnly = false
    if UI.report and UI.report.state then UI.report.state.pickedOnly = false end
  end
  M:UpdateToggles()
  M:Refresh()
  if UI.report and UI.report.frame and UI.report.frame:IsShown() then
    UI.report:UpdatePickButton()
    UI.report:Refresh()
  end
end

--- Right-click on either window's pick button: the picks, to take one off
--- or clear them all. It reopens after each, so several can go in a row.
function UI.PickMenu(parent, anchor)
  local names = {}
  for name in pairs(W.report:Picked()) do table.insert(names, name) end
  table.sort(names)

  local items = {}
  if table.getn(names) == 0 then
    table.insert(items, { text = "Nobody is picked yet.", disabled = true })
    table.insert(items, { text = "Shift-click a player to pick them.", disabled = true })
  else
    for i = 1, table.getn(names) do
      table.insert(items, { text = names[i], value = "unpick:" .. names[i], checked = true })
    end
    table.insert(items, { text = "Clear all picks", value = "clear" })
  end

  return UI.Menu(parent, anchor, items, function(value)
    if value == "clear" then
      W.report:ClearPicks()
    else
      local _, _, name = string.find(value or "", "^unpick:(.*)$")
      if name then W.report:TogglePick(name) end
    end
    UI.PicksChanged()
    if value ~= "clear" and W.report:AnyPicked() then UI.PickMenu(parent, anchor) end
  end, 200)
end

--- The rows the meter shows. One filter for ranking and for announcing, so
--- what gets posted is always what is on screen.
function M:Filter()
  local s = self:Settings()
  return {
    search = s.search,
    groupOnly = s.groupOnly,
    only = s.pickedOnly and W.report:Picked() or nil,
  }
end

----------------------------------------------------------------------
-- combat visibility
----------------------------------------------------------------------

--[[ Fade or hide the meter while fighting, if the player asks for it.

     Polled, not driven by the combat events. PLAYER_REGEN_ENABLED can be
     missed -- zoning, dying, a reconnect -- and a meter that hid on the way
     into a fight and never heard the way out would simply be gone.
     UnitAffectingCombat is the client's own answer, and cannot stick.

     The watcher is a frame of its own: the refresh ticker stops whenever
     the meter is hidden, so it could never notice the fight ending.

     Unlike the window opacity, this fades the WHOLE meter, text included.
     Opacity keeps a meter readable while you see the game through it; this
     is for getting it out of the way altogether.

     "Hide" ends in a real Hide(), not an alpha of zero: an invisible window
     still catches clicks, and hiding it has to mean you can click what is
     behind it. Neither mode touches the saved shown/hidden choice. A meter
     you closed yourself stays closed after the fight, one hidden for the
     fight comes back, and /wrek during a fight shows it until it ends. ]]

local COMBAT_POLL = 0.2    -- seconds between asking the client about combat
local FADE_TIME = 0.4      -- seconds for a full fade in or out
local FADED_ALPHA = 0.3    -- how far "fade" goes; pointing at it restores it

function M:CombatMode()
  local mode = self:Settings().combat
  if mode == "fade" or mode == "hide" then return mode end
  return "show"
end

--- Where the meter's alpha should be heading right now.
function M:CombatTarget()
  if not self.inCombat or self.peek then return 1 end
  local mode = self:CombatMode()
  if mode == "fade" then
    -- Pointing at it brings it back, so it can still be read and used.
    if self.frame and MouseIsOver and MouseIsOver(self.frame) then return 1 end
    return FADED_ALPHA
  elseif mode == "hide" then
    return 0
  end
  return 1
end

--- Ask the client whether we are fighting. Leaving combat ends a peek.
function M:UpdateCombatState()
  self.inCombat = W.encounter:ReallyInCombat() and true or false
  if not self.inCombat then self.peek = nil end
end

--- Move one step toward the target alpha, hiding or showing at the ends.
function M:StepFade(dt)
  local f = self.frame
  if not f then return end
  -- The usual state costs a few comparisons: out of combat, fully shown.
  if not self.inCombat and (self.combatAlpha or 1) == 1
     and not self.combatHidden then return end

  -- A meter the player closed takes no part. Its alpha is put back, so
  -- opening it again later does not open it faded.
  if self:Settings().shown == false then
    if (self.combatAlpha or 1) ~= 1 then
      self.combatAlpha = 1
      f:SetAlpha(1)
    end
    self.combatHidden = nil
    return
  end

  local target = self:CombatTarget()
  local a = self.combatAlpha or 1

  -- Coming back from hidden: on screen at nothing, then fade up.
  if target > 0 and self.combatHidden then
    self.combatHidden = nil
    a = 0
    f:SetAlpha(0)
    f:Show()
  end

  if a ~= target then
    local step = (dt or 0) / FADE_TIME
    if a < target then
      a = a + step
      if a > target then a = target end
    else
      a = a - step
      if a < target then a = target end
    end
    self.combatAlpha = a
    f:SetAlpha(a)
  end

  -- Faded all the way out: take it off the screen for real.
  if target == 0 and a <= 0 and f:IsShown() then
    self.combatHidden = true
    f:Hide()
  end
end

--- One frame of the watcher. A named function rather than a closure, so the
--- per-frame call allocates nothing.
local function combatTick()
  local now = GetTime()
  local dt = now - (M.lastFadeT or now)
  M.lastFadeT = now
  if now - (M.lastCombatPoll or 0) >= COMBAT_POLL then
    M.lastCombatPoll = now
    M:UpdateCombatState()
  end
  M:StepFade(dt)
end

function M:StartCombatWatch()
  if self.watcher then return end
  local w = CreateFrame("Frame", "WrekkitMeterCombat")
  self.watcher = w
  -- Guarded: this runs every frame, and Guard reports an error once rather
  -- than burying it under a copy per frame.
  w:SetScript("OnUpdate", function() W.Guard("meter combat fade", combatTick) end)
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
  -- Asked for in the middle of a fight it is faded or hidden for: that is
  -- a request to see it now, so it stays up until the fight ends.
  self:UpdateCombatState()
  if self.inCombat and self:CombatMode() ~= "show" then self.peek = true end
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
  self.drillAbility = nil
  self:Refresh()
end

--[[ Wrekkit :: ui/settings

Every option in one window, reached from the cog on either title bar.

Controls read and write the live setting through get/set closures rather than
holding a copy, so the window can never show something different from what
the addon is actually doing -- which matters here because several of these
options are also reachable from the toolbar toggles and slash commands.

Anything that changes how the windows are laid out applies immediately. A
settings panel that needs a /reload to take effect trains people not to trust
it.
]]

local W = Wrekkit
local UI = W.ui
UI.settings = {}
local S = UI.settings

--[[ Two columns, not one.

     A single column made a tall, narrow window, and narrow was the problem:
     every label scales with the text-size setting while the window did not.
     Pairing the controls buys the width back and halves the height, so
     nothing has to scroll or hide.

     Worth being precise, since it is easy to assume otherwise: control
     HEIGHTS here are fixed literals (18, 20, 30) and do NOT scale with the
     text. Only the text inside them does. So the window never grew taller
     at a larger setting -- it grew tighter, and the labels ran into the
     values beside them. ]]
local COLS = 2
local COL_GAP = 18

--[[ The width has to move with the text.

     It was a fixed 310px while every label scaled with the text-size
     setting, so at 180% "Record open-world combat" wanted 259px of a column
     that was not going to give it. Control HEIGHTS are fixed literals and do
     not scale, so the window never grew taller -- it just got tighter, and
     the labels ran into the values beside them.

     Capped against the screen, because scaling without a ceiling would walk
     the window off the edge at large text on a small resolution. ]]
local BASE_WIDTH = 560
local PAD = 14
local GAP = 3

local function windowWidth()
  local w = BASE_WIDTH * (UI.FontScale and UI.FontScale() or 1)
  local screen = UIParent and UIParent:GetWidth() or 1024
  local ceiling = screen - 40
  if w > ceiling then w = ceiling end
  if w < BASE_WIDTH then w = BASE_WIDTH end
  return math.floor(w)
end

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

--[[ Stack controls down the panel.

     `live` marks the ones that mirror a setting and therefore need
     re-reading when the window opens. It is passed explicitly rather than
     probed for with `control.Refresh`, because asking a frame whether it has
     a method is indistinguishable from calling one that does not exist --
     the caller already knows which controls are live. ]]
local function columnWidth()
  return (windowWidth() - PAD * 2 - COL_GAP * (COLS - 1)) / COLS
end

--- Close the row being filled, if any, and drop to the next one.
local function endRow(self, extraGap)
  if self.col > 0 then
    self.y = self.y + self.rowH + GAP + (extraGap or 0)
    self.col, self.rowH = 0, 0
    return true
  end
  return false
end

--[[ Place a control, either in the next column or across the whole row.

     `live` marks the ones that mirror a setting and therefore need
     re-reading when the window opens. It is passed explicitly rather than
     probed for with `control.Refresh`, because asking a frame whether it has
     a method is indistinguishable from calling one that does not exist --
     the caller already knows which controls are live.

     `full` is for anything that needs the width: a heading, which labels
     everything under it, and a slider, whose track is the control. Placing
     one closes whatever row was half-filled, so a heading can never end up
     beside the last setting of the section above it. ]]
local function position(self, control, full, extraGap)
  if full then endRow(self) end

  local w = columnWidth()
  local x = PAD + self.col * (w + COL_GAP)
  control:SetPoint("TOPLEFT", self.body, "TOPLEFT", x, -self.y)

  if full then
    control:SetPoint("TOPRIGHT", self.body, "TOPRIGHT", -PAD, -self.y)
  else
    control:SetWidth(w)
  end

  local h = control:GetHeight() or 18
  if h > self.rowH then self.rowH = h end

  if full then
    self.y = self.y + h + GAP + (extraGap or 0)
    self.col, self.rowH = 0, 0
  else
    self.col = self.col + 1
    if self.col >= COLS then endRow(self, extraGap) end
  end

  return control
end

--[[ Position a control AND remember it.

     The two are deliberately separate calls. Layout re-runs the positioning
     over the list, so if positioning also recorded, every re-layout would
     append the whole window to the list it was iterating -- a loop with no
     end, which is exactly what happened the first time this was written. ]]
local function place(self, control, live, full, extraGap)
  position(self, control, full, extraGap)
  if live then table.insert(self.controls, control) end
  table.insert(self.items, { control = control, full = full, gap = extraGap })
  return control
end

local function heading(self, label)
  return place(self, UI.Heading(self.body, label), false, true, 2)
end

local function check(self, label, get, set, tip)
  return place(self, UI.Check(self.body, label, get, set, tip), true, false)
end

local function stepper(self, label, get, set, min, max, step, fmt)
  return place(self, UI.Stepper(self.body, label, get, set, min, max, step, fmt),
    true, false)
end

--- Full width: the track IS the control, and half a window is not enough
--- of it to drag meaningfully.
local function slider(self, label, get, set, min, max, step, fmt)
  return place(self, UI.Slider(self.body, label, get, set, min, max, step, fmt),
    true, true)
end

local function choice(self, label, options, get, set, tip)
  return place(self, UI.Choice(self.body, label, options, get, set, tip),
    true, false)
end

----------------------------------------------------------------------
-- construction
----------------------------------------------------------------------

function S:Create()
  if self.frame then return self.frame end

  local f = UI.Window("WrekkitSettings", windowWidth(), 200, "Wrekkit Settings", {
    minW = windowWidth(), minH = 200,
    -- Above both windows: it is opened from them and must not hide behind.
    strata = "DIALOG",
  })
  self.frame = f
  UI.CloseOnEscape("WrekkitSettings")

  -- Not resizable: the contents are a fixed stack, so a drag handle would
  -- only ever produce empty space or clipping.
  f.grip:Hide()

  if not W.db.settingsWindow then
    W.db.settingsWindow = { point = "CENTER", x = 60, y = 0 }
  end
  UI.BindGeometry(f, W.db.settingsWindow)

  self.body = f.body
  self.controls = {}
  self.items = {}
  self.y = PAD
  -- Which column the next control goes in, and how tall the row it is in
  -- has grown so far. A row is only as tall as its tallest control.
  self.col = 0
  self.rowH = 0

  local meter = UI.meter

  ------------------------------------------------------------------
  heading(self, "Appearance")

  check(self, "Compact meter",
    function() return meter:Settings().compact == true end,
    function(v)
      meter:Settings().compact = v
      meter:ApplyLayout()
    end,
    { "Drops the toolbar and footer and tightens", "the rows, for a small always-on meter." })

  stepper(self, "Text size",
    function() return math.floor((W.db.fontScale or 1) * 100 + 0.5) end,
    function(v)
      W.db.fontScale = v / 100
      UI.ApplyFontScale()
      meter:ApplyLayout()
      -- This window is built once, so it has to be told to re-flow at the
      -- new size; otherwise the control you just used is the one that
      -- stops fitting.
      S:Layout()
    end,
    70, 180, 5,
    function(v) return v .. "%" end)

  stepper(self, "Row height",
    function() return meter:Settings().rowHeight or 18 end,
    function(v)
      meter:Settings().rowHeight = v
      meter:ApplyLayout()
    end,
    10, 32, 1,
    function(v) return v .. "px" end)

  slider(self, "Window opacity",
    function() return math.floor(((meter:Settings().opacity or 1) * 100) + 0.5) end,
    function(v)
      meter:Settings().opacity = v / 100
      meter:ApplyLayout()
    end,
    20, 100, 5,
    function(v) return v .. "%" end)

  check(self, "Show meter toolbar",
    function() return meter:Settings().showToolbar ~= false end,
    function(v)
      meter:Settings().showToolbar = v
      meter:ApplyLayout()
    end,
    { "The search box and the icon toggles.", "Compact mode hides these anyway." })

  check(self, "Lock meter position",
    function() return meter:Settings().locked == true end,
    function(v) meter:Settings().locked = v end,
    { "Stops the meter being dragged by accident." })

  ------------------------------------------------------------------
  heading(self, "Recording")

  check(self, "Track buff uptime",
    function() return W.db.trackAuras ~= false end,
    function(v) W.db.trackAuras = v and nil or false end,
    { "Follows buffs and debuffs as they come and",
      "go, so uptime is answerable: was the flask",
      "actually up, was the debuff kept on." })

  check(self, "Timeline detail",
    function() return W.db.timelineDetail ~= false end,
    function(v) W.db.timelineDetail = v and nil or false end,
    { "Hovering the timeline says who did what,",
      "with which spell, to whom. Costs storage:",
      "the busiest 60 seconds of each fight." })

  choice(self, "Per-second basis",
    {
      { value = "combat", label = "combat time" },
      { value = "active", label = "active time" },
    },
    function() return W.db.dpsBasis or "combat" end,
    function(v)
      W.db.dpsBasis = (v == "active") and "active" or nil
      meter:Refresh()
      if UI.report and UI.report.frame then UI.report:Refresh() end
    end,
    { "combat time divides by the length of the",
      "fight, like Skada. active time divides by",
      "the seconds each player was acting, like",
      "Recount. They disagree; both are defensible." })

  check(self, "Raise the combat log range",
    function() return W.db.combatLogRange ~= false end,
    function(v)
      W.db.combatLogRange = v and nil or false
      if v then W.capture:ApplyCombatLogRange() end
    end,
    { "The client only reports combat within this",
      "range. Its 30 yard default leaves most of a",
      "raid invisible to any meter." })

  stepper(self, "Log range",
    function() return W.db.combatLogRangeYards or W.capture.RANGE_DEFAULT end,
    function(v)
      W.db.combatLogRangeYards = v
      W.capture:ApplyCombatLogRange()
    end,
    30, 200, 10,
    function(v) return v .. " yd" end)

  check(self, "Record open-world combat",
    function() return W.db.trackOpenWorld == true end,
    function(v)
      W.db.trackOpenWorld = v
      meter:UpdateToggles()
    end,
    { "Off by default so questing does not bury", "the raid history." })

  check(self, "Only count my party/raid",
    function() return meter:Settings().groupOnly == true end,
    function(v)
      meter:Settings().groupOnly = v
      if UI.report then UI.report.state.groupOnly = v end
      meter:UpdateToggles()
      meter:Refresh()
    end,
    { "Ignores anyone nearby who is not grouped", "with you." })

  stepper(self, "Ignore pulls under",
    function() return W.db.minTrashDuration or 6 end,
    function(v) W.db.minTrashDuration = v end,
    1, 60, 1,
    function(v) return v .. "s" end)

  stepper(self, "Rejoin session within",
    function() return math.floor((W.db.resumeWindow or 1200) / 60) end,
    function(v) W.db.resumeWindow = v * 60 end,
    1, 120, 5,
    function(v) return v .. " min" end)

  ------------------------------------------------------------------
  heading(self, "History")

  stepper(self, "Keep at most",
    function() return W.db.maxEncounters or 60 end,
    function(v) W.db.maxEncounters = v end,
    10, 500, 10,
    function(v) return v .. " pulls" end)

  check(self, "Write each pull to disk",
    function() return W.db.autoSave ~= false end,
    function(v) W.db.autoSave = v end,
    { "Survives a crash; SavedVariables only", "write at a clean logout." })

  ------------------------------------------------------------------
  heading(self, "Sharing")

  check(self, "Share my logs",
    function() return W.db.shareEnabled == true end,
    function(v)
      W.db.shareEnabled = v
      if v then W.sync:Announce() end
      if UI.peers then UI.peers:Refresh() end
    end,
    { "Lets others see your name and pull logs", "from you. Off by default." })

  choice(self, "Visible on",
    {
      { value = "AUTO", label = "auto" },
      { value = "RAID", label = "raid" },
      { value = "PARTY", label = "party" },
      { value = "GUILD", label = "guild" },
    },
    function() return W.db.shareChannel or "AUTO" end,
    function(v)
      W.db.shareChannel = v
      if W.db.shareEnabled then W.sync:Announce() end
      if UI.peers then UI.peers:Refresh() end
    end,
    { "auto picks raid, else party, else guild." })

  check(self, "Accept logs from others",
    function() return W.db.acceptShares ~= false end,
    function(v) W.db.acceptShares = v end,
    { "Whether logs people send you are kept." })

  ------------------------------------------------------------------
  -- actions
  ------------------------------------------------------------------
  local row = CreateFrame("Frame", nil, self.body)
  row:SetHeight(22)
  -- Full width: the buttons sit along it, and it closes the last column row.
  place(self, row, false, true, 4)

  local saveBtn = UI.Button(row, "Save now", 72, 20, function()
    W.Guard("settings save", function() W.store:Save() end)
  end)
  saveBtn:SetPoint("LEFT", row, "LEFT", 0, 0)

  local loadBtn = UI.Button(row, "Load", 56, 20, function()
    W.Guard("settings load", function() W.store:Load() end)
  end)
  loadBtn:SetPoint("LEFT", saveBtn, "RIGHT", 5, 0)

  local pruneBtn = UI.Button(row, "Prune 7d", 68, 20, function()
    W.Guard("settings prune", function()
      local removed, kept, spared = W.PruneEncounters(7)
      W.Print("Pruned " .. removed .. ", kept " .. kept ..
        (spared > 0 and (" (" .. spared .. " locked)") or "") .. ".")
    end)
  end)
  pruneBtn:SetPoint("LEFT", loadBtn, "RIGHT", 5, 0)

  local statusBtn = UI.Button(row, "Status", 52, 20, function()
    W.Guard("settings status", function() W.Status() end)
  end)
  statusBtn:SetPoint("LEFT", pruneBtn, "RIGHT", 5, 0)

  local peersBtn = UI.Button(row, "Browse", 56, 20, function()
    W.Guard("settings peers", function() UI.peers:Toggle() end)
  end)
  peersBtn:SetPoint("LEFT", statusBtn, "RIGHT", 5, 0)

  ------------------------------------------------------------------
  -- A half-filled last row still occupies height; without this the
  -- window would clip whatever is sitting in it.
  self:Layout()
  return f
end

--[[ Re-place every control at the current text size.

     Cheap: it moves frames that already exist rather than building any, so
     it can run whenever the window opens or the text size changes. ]]
function S:Layout()
  local f = self.frame
  if not f or not self.items then return end

  local w = windowWidth()
  f:SetWidth(w)
  if f.SetMinResize then f:SetMinResize(w, 200) end

  self.y = PAD
  self.col = 0
  self.rowH = 0

  for _, item in ipairs(self.items) do
    position(self, item.control, item.full, item.gap)
  end

  endRow(self)
  f:SetHeight(self.y + PAD + (f.bar:GetHeight() or 26))
end

----------------------------------------------------------------------

--- Re-read every control from the live settings.
function S:Refresh()
  if not self.frame then return end
  for _, c in ipairs(self.controls) do
    if c.Refresh then c:Refresh() end
  end
end

function S:Toggle()
  local f = self:Create()
  if f:IsShown() then
    f:Hide()
  else
    self:Refresh()
    f:Show()
  end
end

function S:Show()
  local f = self:Create()
  self:Refresh()
  f:Show()
end

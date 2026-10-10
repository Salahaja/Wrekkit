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
if type(StaticPopupDialogs) == "table" then
  StaticPopupDialogs["WREKKIT_RELOAD_SKIN"] = {
    text = "Wrekkit's new look applies after reloading the UI.\nReload now?",
    button1 = "Reload",
    button2 = "Later",
    OnAccept = function() if ReloadUI then ReloadUI() end end,
    timeout = 30,
    whileDead = 1,
    hideOnEscape = 1,
  }
end

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
  table.insert(self.items, { control = control, full = full, gap = extraGap,
                             tab = self.building })
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
    skin = "dialog",
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
  self.tab = self.tab or "meter"

  --[[ Tabs rather than one long page. One page of everything was taller
       than a 768-line screen once threat arrived, and a page of thirty
       controls is a page nobody reads: four short ones, each about one
       thing, are. ]]
  self.tabs = {}
  local tabRow = CreateFrame("Frame", nil, f.body)
  tabRow:SetHeight(20)
  tabRow:SetPoint("TOPLEFT", f.body, "TOPLEFT", PAD, -8)
  tabRow:SetPoint("TOPRIGHT", f.body, "TOPRIGHT", -PAD, -8)
  local prev
  for _, t in ipairs(S.TABS) do
    local key = t[1]
    local b = UI.Button(tabRow, t[2], (key == "plates") and 104 or 84, 20,
      function() S:SetTab(key) end)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    else b:SetPoint("LEFT", tabRow, "LEFT", 0, 0) end
    self.tabs[key] = b
    prev = b
  end

  self.building = "meter"
  self.y = PAD
  -- Which column the next control goes in, and how tall the row it is in
  -- has grown so far. A row is only as tall as its tallest control.
  self.col = 0
  self.rowH = 0

  local meter = UI.meter

  ------------------------------------------------------------------
  heading(self, "Appearance")

  choice(self, "Look",
    {
      { value = "auto", label = "auto" },
      { value = "blizzard", label = "Blizzard" },
      { value = "pfui", label = "pfUI" },
      { value = "modern", label = "modern" },
    },
    function() return W.db.skin or "auto" end,
    function(v)
      W.db.skin = v
      if UI.ResolveSkin() ~= UI.skin then
        if StaticPopup_Show and StaticPopupDialogs then
          StaticPopup_Show("WREKKIT_RELOAD_SKIN")
        else
          W.Print("the new look applies after /reload.")
        end
      end
    end,
    { "Blizzard: the game's own frames -- tooltip", "and dialog borders, panel buttons, stock",
      "checkboxes, gold titles. pfUI: pfUI's dark", "one-pixel style, and its own textures and",
      "font when pfUI is loaded. auto: pfUI with", "pfUI or ShaguPlates, else Blizzard.",
      "Applies after a /reload." })

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

  slider(self, "Meter opacity",
    function() return math.floor(((meter:Settings().opacity or 1) * 100) + 0.5) end,
    function(v)
      meter:Settings().opacity = v / 100
      meter:ApplyLayout()
      -- The docked threat window wears the meter's opacity.
      if UI.threat.frame then UI.threat:ApplyLayout() end
    end,
    20, 100, 5,
    function(v) return v .. "%" end)

  slider(self, "Report opacity",
    function() return math.floor(((W.db.reportOpacity or 1) * 100) + 0.5) end,
    function(v) UI.SetReportOpacity(v / 100) end,
    20, 100, 5,
    function(v) return v .. "%" end)

  choice(self, "In combat",
    {
      { value = "show", label = "shown" },
      { value = "fade", label = "faded" },
      { value = "hide", label = "hidden" },
    },
    function() return meter:CombatMode() end,
    function(v)
      meter:Settings().combat = v
      meter:UpdateCombatState()
    end,
    { "Faded dims the meter while you fight, and",
      "pointing at it brings it back. Hidden takes",
      "it away until the fight ends. /wrek shows it",
      "anyway, and closing it yourself always wins." })

  choice(self, "Metrics in the meter",
    {
      { value = "off", label = "one" },
      { value = "stacked", label = "over and under" },
      { value = "side", label = "side by side" },
    },
    function() return meter:SplitMode() end,
    function(v) meter:SetSplit(v) end,
    { "Two metrics at once: the meter's own and a", "second (healing, to start with), one under",
      "the other or in columns. Click a half's", "header to change it. Also the 1+2 button." })

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
  self.building = "recording"
  heading(self, "Recording")

  --[[ These three store "on" as nil, the default, and only an explicit
       false as off. Written out as if/else on purpose: the and/or shorthand
       for it cannot produce nil, so it stored false both ways, and one
       click in either direction switched the feature off for good. ]]
  check(self, "Track buff uptime",
    function() return W.db.trackAuras ~= false end,
    function(v)
      if v then W.db.trackAuras = nil else W.db.trackAuras = false end
    end,
    { "Follows your group's buffs as they come and",
      "go, so uptime is answerable: was the flask",
      "actually up, and did it drop mid-fight." })

  check(self, "Timeline detail",
    function() return W.db.timelineDetail ~= false end,
    function(v)
      if v then W.db.timelineDetail = nil else W.db.timelineDetail = false end
    end,
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
      if v then
        W.db.combatLogRange = nil
        W.capture:ApplyCombatLogRange()
      else
        W.db.combatLogRange = false
        -- Off means off: put back what the client had, rather than leave
        -- the raised range in place behind a box that says otherwise.
        local restored, unknown = W.capture:RestoreCombatLogRange()
        if unknown > 0 then
          W.Print(string.format("log range: %d restored; %d were raised before " ..
            "Wrekkit kept their old values, so they are left as they are.",
            restored, unknown))
        end
      end
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

  check(self, "Save each raid to its own file",
    function() return W.db.archiveFiles ~= false end,
    function(v) W.db.archiveFiles = v and true or false end,
    { "One file per raid ID (one per dungeon", "run) in CustomData. Older raids load", "from their file when opened, so memory", "stays small. Needs Nampower." })

  stepper(self, "Keep pulls for",
    function() return W.db.keepDays or 7 end,
    function(v) W.db.keepDays = v W.TrimHistory() end,
    1, 90, 1,
    function(v) return v .. ((v == 1) and " day" or " days") end)

  stepper(self, "Keep at most",
    function() return W.db.maxEncounters or 0 end,
    function(v) W.db.maxEncounters = v end,
    0, 1000, 50,
    function(v) return (v == 0) and "no limit" or (v .. " pulls") end)

  check(self, "Write each pull to disk",
    function() return W.db.autoSave ~= false end,
    function(v) W.db.autoSave = v end,
    { "Survives a crash; SavedVariables only", "write at a clean logout." })

  check(self, "Free memory after fights",
    function() return W.db.tidy ~= false end,
    function(v)
      if v then W.db.tidy = nil else W.db.tidy = false end
    end,
    { "Once a fight is over and you have been out",
      "of combat a few seconds, Wrekkit hands back",
      "the memory the fight used. Never mid-pull." })

  ------------------------------------------------------------------
  self.building = "sharing"
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

  check(self, "Live raid sync",
    function() return W.db.liveSync == true end,
    function(v)
      W.db.liveSync = v or nil
      if not v then
        W.sync:StopLive()
      elseif W.encounter.inCombat then
        W.sync:StartLive()
      end
    end,
    { "Each player reports only their OWN totals,",
      "which fills in anyone the client cannot see",
      "because they are out of log range. Needs",
      "sharing on, and them running Wrekkit too." })

  stepper(self, "Report every",
    function() return W.db.liveSyncInterval or 30 end,
    function(v) W.db.liveSyncInterval = v end,
    10, 120, 5,
    function(v) return v .. "s" end)

  check(self, "Accept logs from others",
    function() return W.db.acceptShares ~= false end,
    function(v) W.db.acceptShares = v end,
    { "Whether logs people send you are kept." })

  ------------------------------------------------------------------
  -- actions, at the foot of the history they act on
  ------------------------------------------------------------------
  self.building = "recording"
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

  self:BuildThreat()

  ------------------------------------------------------------------
  -- A half-filled last row still occupies height; without this the
  -- window would clip whatever is sitting in it.
  self:Layout()
  return f
end

----------------------------------------------------------------------
-- threat tab
----------------------------------------------------------------------

--- A labelled text box, for the one setting that is a name.
local function textField(self, label, get, set)
  local f = CreateFrame("Frame", nil, self.body)
  f:SetHeight(18)
  local text = UI.Text(f, 11, W.color.text)
  text:SetPoint("LEFT", f, "LEFT", 0, 0)
  text:SetText(label)
  local box = UI.SearchBox(f, 110, function(v) set(v) end, "auto")
  -- Room for a list of names, not just one.
  if box.editBox then box.editBox:SetMaxLetters(120) end
  box:SetPoint("RIGHT", f, "RIGHT", 0, 0)
  box:SetHeight(18)
  f.Refresh = function() box:SetValue(get()) end
  return place(self, f, true, false)
end

function S:BuildThreat()
  local T = W.threat
  local function ts() return T:Settings() end
  local function redraw()
    T:Sanitize(ts())
    T:InvalidateCaches()
    if UI.threat.frame then UI.threat:ApplyLayout() end
    UI.threatFrames.indStyle = nil
    UI.threatFrames.indPlaced = nil
    UI.threatFrames:Update()
    UI.threat:UpdateVisibility()
  end
  local function opt(key)
    return function() return ts()[key] == true end,
           function(v) ts()[key] = v and true or false; redraw() end
  end
  local function pick(key)
    return function() return ts()[key] end,
           function(v) ts()[key] = v; redraw() end
  end
  local function pct(v) return v .. "%" end

  self.building = "threat"
  self.y = PAD

  heading(self, "Threat meter")

  local get, set = opt("enabled")
  check(self, "Threat meter on", get, set,
    { "Asks the server for the threat table of", "your target. Needs a party or raid." })

  choice(self, "Show it",
    {
      { value = "window", label = "own window" },
      { value = "docked", label = "under meter" },
      { value = "meter", label = "in meter" },
      { value = "off", label = "no window" },
    },
    function() return ts().display end,
    function(v) UI.threat:SetDisplay(v) end,
    { "own window: moved and sized by itself.",
      "under meter: hangs below the damage meter.",
      "in meter: the meter shows threat while you",
      "fight, then goes back. Frames, plates and",
      "warnings work in every mode." })

  get, set = pick("show")
  choice(self, "Window appears",
    {
      { value = "group", label = "in a group" },
      { value = "combat", label = "in combat" },
      { value = "always", label = "always" },
    }, get, set,
    { "The server only answers in a party or raid,", "so alone the window has nothing to show." })

  choice(self, "I'm the tank",
    {
      { value = "auto", label = "auto" },
      { value = "on", label = "always" },
      { value = "off", label = "never" },
    },
    function() return ts().tankMode end,
    function(v)
      ts().tankMode = v
      T.roleAt = nil       -- re-read the stance now, not in a second
      redraw()
    end,
    { "auto: in Defensive Stance, Bear Form or with",
      "Righteous Fury up. A tank gets the mobs they",
      "hold listed, and alerts when someone closes",
      "in on one or one turns away." })

  get, set = pick("basis")
  choice(self, "Percent means",
    {
      { value = "pull", label = "% to pull" },
      { value = "tank", label = "% of tank" },
    }, get, set,
    { "% to pull: 100 is where aggro moves to you", "(110% of the tank in melee, 130% at range).",
      "% of tank: the raw share of the tank's threat." })

  get, set = opt("eliteOnly")
  check(self, "Only elites and bosses", get, set,
    { "The server only reports elites and bosses;", "asking about anything else is wasted traffic." })

  stepper(self, "Players listed",
    function() return ts().rows end,
    function(v) ts().rows = v; redraw() end,
    3, 20, 1)

  stepper(self, "Update every",
    function() return math.floor(ts().interval * 1000 + 0.5) end,
    function(v) ts().interval = v / 1000 end,
    250, 2000, 250,
    function(v) return string.format("%.2fs", v / 1000) end)

  slider(self, "Threat window opacity  (docked: follows the meter)",
    function() return math.floor(ts().opacity * 100 + 0.5) end,
    function(v) ts().opacity = v / 100; redraw() end,
    20, 100, 5,
    function(v) return v .. "%" end)

  get, set = opt("showTPS")
  check(self, "Threat per second", get, set)
  get, set = opt("showPullLine")
  check(self, "Pull-aggro line", get, set,
    { "A row at the threat where aggro moves to you." })

  ------------------------------------------------------------------
  heading(self, "Warnings")

  stepper(self, "Warn at",
    function() return ts().warnAt end,
    function(v) ts().warnAt = v; redraw() end,
    10, 150, 5, pct)

  stepper(self, "Danger at",
    function() return ts().dangerAt end,
    function(v) ts().dangerAt = v; redraw() end,
    10, 150, 5, pct)

  get, set = opt("warnText")
  check(self, "Warning text", get, set, { "Large text mid-screen as you cross a line." })
  get, set = opt("warnFlash")
  check(self, "Flash screen edges", get, set)
  get, set = opt("warnSound")
  check(self, "Warning sound", get, set)
  get, set = opt("raidWarning")
  check(self, "Big raid warning", get, set,
    { "AGGRO, LOST AGGRO and danger-level THREAT", "also as a raid warning: big at the top of",
      "the screen. On your screen only; nothing", "is sent to the raid." })
  get, set = opt("warnPulled")
  check(self, "Alert when I pull aggro", get, set,
    { "Not tanking, and a mob turns on you." })

  ------------------------------------------------------------------
  heading(self, "Flash while close")

  get, set = opt("flash")
  check(self, "Flash while close", get, set,
    { "Keeps flashing for as long as you are over", "the limit, and stops on its own when you",
      "drop back. Warnings above say it once." })

  stepper(self, "Flash me at",
    function() return ts().flashAt end,
    function(v) ts().flashAt = v; redraw() end,
    30, 150, 5,
    function(v) return v .. "% to pull" end)

  stepper(self, "Tanking, flash at",
    function() return ts().tankFlashAt end,
    function(v) ts().tankFlashAt = v; redraw() end,
    30, 150, 5,
    function(v) return v .. "% (runner-up)" end)

  stepper(self, "Flash speed",
    function() return ts().flashSpeed end,
    function(v) ts().flashSpeed = v end,
    1, 6, 1,
    function(v) return v .. "/s" end)

  get, set = opt("flashFrame")
  check(self, "Blink the target %", get, set)
  get, set = opt("flashScreen")
  check(self, "Pulse screen edges", get, set,
    { "Red edges around the screen, pulsing until", "the danger passes. Hard to miss." })

  ------------------------------------------------------------------
  heading(self, "Tanking")

  get, set = opt("tankAlerts")
  check(self, "Someone is closing in", get, set,
    { "On any mob you hold: the runner-up has", "reached the line below." })

  stepper(self, "...at",
    function() return ts().tankWarnAt end,
    function(v) ts().tankWarnAt = v; redraw() end,
    30, 120, 5,
    function(v) return v .. "% to pull" end)

  get, set = opt("warnLostAggro")
  check(self, "A mob turned away", get, set,
    { "LOST AGGRO, with the mob's name, and LOST", "on its nameplate for a few seconds." })

  get, set = opt("watchMobs")
  check(self, "Watch mobs I'm not targeting", get, set,
    { "Reads every mob's own target: LOOSE on one",
      "hitting a group member, AGGRO (not tanking)", "on one hitting you. With SuperWoW, every mob",
      "with a plate; without, every mob your group", "has targeted." })

  get, set = opt("mobSummary")
  check(self, "Mob count under the %", get, set,
    { "\"4 held  1 slipping  1 loose\" under the", "target-frame %, with more than one mob." })

  textField(self, "Co-tanks",
    function() return ts().coTanks end,
    function(v) ts().coTanks = v or "" end)

  get, set = opt("coTankAuto")
  check(self, "Find the other tanks", get, set,
    { "A group member in Defensive Stance, Bear", "Form or with Righteous Fury counts as a",
      "co-tank, addon or not. Unmark one by hand", "and they stay unmarked." })

  get, set = opt("relayThreat")
  check(self, "Share threat on every mob", get, set,
    { "Tanking, your Wrekkit tells the group who", "is closest to pulling each mob you hold.",
      "Not tanking, you are warned on any of them", "you are about to pull, targeted or not." })

  get, set = opt("coTankShare")
  check(self, "Share tanks with the group", get, set,
    { "Marking or unmarking a tank does it for", "everyone in the party or raid running",
      "Wrekkit, and their Wrekkit tells yours", "when they are tanking, from any range." })

  get, set = opt("tauntPopup")
  check(self, "Taunt popup", get, set,
    { "A button for each mob that got away: click", "to taunt it, right-click to dismiss. Also",
      "on a key (Key Bindings -> Wrekkit) and", "/wrek taunt for a macro." })

  get, set = opt("tauntKeepTarget")
  check(self, "Taunt without retargeting", get, set,
    { "With SuperWoW the taunt goes straight at", "the mob and your target stays put. Off, or",
      "without SuperWoW, the mob is targeted first." })

  textField(self, "Taunt spells",
    function() return ts().tauntSpell end,
    function(v) ts().tauntSpell = v or ""; T.tauntCache = nil end)

  check(self, "Use AoE taunts too",
    function() return ts().tauntAoE == true end,
    function(v) ts().tauntAoE = v and true or false; T.tauntCache = nil end,
    { "Challenging Shout / Challenging Roar when", "the single-target taunts are on cooldown.",
      "Off by default: they are long cooldowns." })

  ------------------------------------------------------------------
  self.building = "plates"
  heading(self, "Target frame")

  get, set = opt("frame")
  check(self, "Show on target frame", get, set)
  get, set = pick("frameStyle")
  choice(self, "Style",
    {
      { value = "clean", label = "number + bar" },
      { value = "number", label = "number" },
      { value = "badge", label = "badge" },
    }, get, set,
    { "number + bar: the % with a slim threat bar", "under it. badge: on a soft dark plate, for",
      "busy frames." })

  get, set = opt("frameGlow")
  check(self, "Soft glow", get, set, { "A faint glow behind the %, in its colour.", "It breathes when red." })

  stepper(self, "Size",
    function() return math.floor(ts().frameScale * 100 + 0.5) end,
    function(v) ts().frameScale = v / 100; redraw() end,
    60, 250, 10, pct)

  check(self, "Move it (drag)",
    function() return UI.threatFrames.moving == true end,
    function(v) UI.threatFrames:SetMoving(v) end,
    { "Shows a sample % you can drag anywhere.", "Its place is saved relative to the target",
      "frame. Right-click it, or untick, to lock." })

  textField(self, "Frame name",
    function() return ts().frameName end,
    function(v) ts().frameName = v or ""; redraw() end)

  ------------------------------------------------------------------
  heading(self, "Nameplates")

  get, set = opt("plates")
  check(self, "Show on nameplates", get, set)


  get, set = pick("plateStyle")
  choice(self, "Nameplate addon",
    {
      { value = "auto", label = "auto" },
      { value = "shagu", label = "ShaguPlates/pfUI" },
      { value = "stock", label = "stock" },
    }, get, set,
    { "Whose plates to draw on. auto finds", "ShaguPlates or pfUI's plates and uses",
      "their health bar; stock uses Blizzard's." })

  get, set = pick("plateColor")
  choice(self, "Show as",
    {
      { value = "text", label = "coloured %" },
      { value = "bar", label = "tinted bar" },
      { value = "none", label = "plain %" },
    }, get, set,
    { "tinted bar colours the plate's own health", "bar by threat, and gives it back after." })

  get, set = pick("plateAnchor")
  choice(self, "Text side",
    {
      { value = "RIGHT", label = "right" },
      { value = "LEFT", label = "left" },
      { value = "TOP", label = "top" },
      { value = "BOTTOM", label = "bottom" },
    }, get, set)

  stepper(self, "Text size",
    function() return ts().plateSize end,
    function(v) ts().plateSize = v; redraw() end,
    7, 20, 1,
    function(v) return v .. "px" end)

  stepper(self, "Remember mobs for",
    function() return ts().plateMemory end,
    function(v) ts().plateMemory = v end,
    0, 30, 1,
    function(v) return v .. "s" end)

  ------------------------------------------------------------------
  heading(self, "Mob frames")

  get, set = opt("mobFrames")
  check(self, "Mob frames", get, set,
    { "A small frame per mob in the fight: its", "health, and who it is hitting. Click to",
      "target, right-click to taunt. A mob loose", "on someone else blinks red. Without",
      "SuperWoW: the mobs your group has targeted." })

  get, set = pick("mobFramesFor")
  choice(self, "Show them",
    {
      { value = "tank", label = "when tanking" },
      { value = "everyone", label = "DPS and healing too" },
    }, get, set,
    { "In every fight, tanking or not. Not tanking,", "a mob on you is red, and with a tank running",
      "Wrekkit a mob you are close to pulling gets", "a row with your %, red past your warning line." })

  -- Also by dragging its corner while the frames are being placed.
  stepper(self, "Width",
    function() return ts().mobFramesWidth end,
    function(v) if UI.mobs then UI.mobs:SetWidth(v) else ts().mobFramesWidth = v end end,
    160, 420, 10,
    function(v) return v .. "px" end)

  stepper(self, "From",
    function() return ts().mobFramesMin end,
    function(v) ts().mobFramesMin = v; redraw() end,
    1, 10, 1,
    function(v) return v .. (v == 1 and " mob" or " mobs") end)

  get, set = pick("mobFramesCollapse")
  choice(self, "Collapse",
    {
      { value = "auto", label = "when many" },
      { value = "always", label = "always" },
      { value = "never", label = "never" },
    }, get, set,
    { "Collapsed, mobs on you share one line --", "\"All 10 on you\" -- and only a mob that",
      "breaks off, or that someone is close to", "pulling, gets a row of its own. Click the",
      "title to flip it for this fight." })

  stepper(self, "Collapse above",
    function() return ts().mobFramesCollapseAt end,
    function(v) ts().mobFramesCollapseAt = v; redraw() end,
    1, 15, 1,
    function(v) return v .. " mobs" end)

  stepper(self, "Show a mob from",
    function() return ts().mobFramesExpandAt end,
    function(v) ts().mobFramesExpandAt = v; redraw() end,
    30, 130, 5,
    function(v) return v .. "% of mine" end)

  stepper(self, "At most",
    function() return ts().mobFramesMax end,
    function(v) ts().mobFramesMax = v; redraw() end,
    2, 15, 1,
    function(v) return v .. " rows" end)

  -- The buttons belong with the threat meter, at the foot of its tab.
  self.building = "threat"
  local row = CreateFrame("Frame", nil, self.body)
  row:SetHeight(22)
  place(self, row, false, true, 4)
  local demoBtn = UI.Button(row, "Preview", 64, 20, function()
    W.Guard("threat preview", function() W.threat:Demo(15) end)
  end)
  demoBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
  local placeBtn = UI.Button(row, "Reset %", 64, 20, function()
    W.Guard("threat reset placement", function()
      UI.threatFrames:ResetPlacement()
      W.Print("threat % is back above the target frame.")
    end)
  end)
  local resetBtn = UI.Button(row, "Defaults", 64, 20, function()
    W.Guard("threat defaults", function()
      T:ResetSettings()
      redraw()
      UI.threat:SetDisplay(ts().display)
      S:Refresh()
      W.Print("threat settings are back to their defaults.")
    end)
  end)
  placeBtn:SetPoint("LEFT", demoBtn, "RIGHT", 5, 0)
  resetBtn:SetPoint("LEFT", placeBtn, "RIGHT", 5, 0)
  local hint = UI.Text(row, 10, W.color.textDim)
  hint:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
  hint:SetText("Preview: 15s of test data")

  self.building = "meter"
end

--- Switch tab. Only that tab's controls are laid out and shown.
S.TABS = {
  { "meter", "Meter" },
  { "recording", "Recording" },
  { "sharing", "Sharing" },
  { "threat", "Threat" },
  { "plates", "Frames & plates" },
}

function S:SetTab(tab)
  local known = false
  for _, t in ipairs(S.TABS) do
    if t[1] == tab then known = true end
  end
  self.tab = known and tab or "meter"
  if self.frame then
    self:Layout()
    self:Refresh()
  end
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

  -- Room for the tab strip above the controls.
  self.y = PAD + 22
  self.col = 0
  self.rowH = 0

  local tab = self.tab or "meter"
  for _, item in ipairs(self.items) do
    if (item.tab or "meter") == tab then
      item.control:ClearAllPoints()
      position(self, item.control, item.full, item.gap)
      item.control:Show()
    else
      item.control:Hide()
    end
  end
  for key, b in pairs(self.tabs or {}) do
    if b.SetActive then b:SetActive(key == tab) end
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

function S:Show(tab)
  local f = self:Create()
  if tab then self:SetTab(tab) end
  self:Refresh()
  f:Show()
end

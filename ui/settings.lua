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

local WIDTH = 310
local PAD = 14
local GAP = 3

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

--[[ Stack controls down the panel.

     `live` marks the ones that mirror a setting and therefore need
     re-reading when the window opens. It is passed explicitly rather than
     probed for with `control.Refresh`, because asking a frame whether it has
     a method is indistinguishable from calling one that does not exist --
     the caller already knows which controls are live. ]]
local function stack(self, control, extraGap, live)
  control:SetPoint("TOPLEFT", self.body, "TOPLEFT", PAD, -self.y)
  control:SetPoint("TOPRIGHT", self.body, "TOPRIGHT", -PAD, -self.y)
  self.y = self.y + control:GetHeight() + GAP + (extraGap or 0)
  if live then table.insert(self.controls, control) end
  return control
end

local function heading(self, label)
  return stack(self, UI.Heading(self.body, label), 2, false)
end

local function check(self, label, get, set, tip)
  return stack(self, UI.Check(self.body, label, get, set, tip), 0, true)
end

local function stepper(self, label, get, set, min, max, step, fmt)
  return stack(self, UI.Stepper(self.body, label, get, set, min, max, step, fmt),
    0, true)
end

local function choice(self, label, options, get, set, tip)
  return stack(self, UI.Choice(self.body, label, options, get, set, tip), 0, true)
end

----------------------------------------------------------------------
-- construction
----------------------------------------------------------------------

function S:Create()
  if self.frame then return self.frame end

  local f = UI.Window("WrekkitSettings", WIDTH, 200, "Wrekkit Settings", {
    minW = WIDTH, minH = 200,
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
  self.y = PAD

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

  stepper(self, "Window opacity",
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

  check(self, "Timeline detail",
    function() return W.db.timelineDetail ~= false end,
    function(v) W.db.timelineDetail = v and nil or false end,
    { "Hovering the timeline says who did what,",
      "with which spell, to whom. Costs storage:",
      "the busiest 60 seconds of each fight." })

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
  stack(self, row, 4, false)

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
  f:SetHeight(self.y + PAD + (f.bar:GetHeight() or 26))
  return f
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

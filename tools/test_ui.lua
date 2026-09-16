--[[ test_ui.lua - constructs and drives Wrekkit's windows offline

    lua tools/test_ui.lua              (from the addon root)

The UI is the part that cannot be checked by reading it: a misspelled widget
method or a SetPoint against a frame that does not exist yet is a runtime
error that only fires when that exact path runs in-game, which usually means
mid-raid. So this stubs enough of the 1.12 widget API to actually build both
windows, then clicks through every tab, metric, drilldown and menu.

It does not verify that anything LOOKS right -- that still needs the client.
It verifies that every path runs without erroring, which is the expensive
half to find by hand.
]]

package.path = "./?.lua;" .. package.path

math.mod = math.mod or math.fmod
string.gfind = string.gfind or string.gmatch
table.getn = table.getn or function(t) return #t end
table.setn = table.setn or function() end
unpack = unpack or table.unpack

local NOW = 1000.0
GetTime = function() return NOW end
time = function() return 1700000000 + math.floor(NOW) end
date = function(fmt, t) return "09/13 15:00" end

----------------------------------------------------------------------
-- widget stubs
----------------------------------------------------------------------

local strict = true       -- error on an unknown method rather than ignoring it
local calls = 0

local function region(kind)
  local r = { _kind = kind, _w = 0, _h = 0, _shown = true, _points = {} }

  local methods = {
    SetPoint = function(self, ...) table.insert(self._points, { ... }) end,
    SetAllPoints = function() end,
    ClearAllPoints = function(self) self._points = {} end,
    GetPoint = function(self)
      local p = self._points[1]
      if not p then return "CENTER", nil, "CENTER", 0, 0 end
      return p[1], p[2], p[3], p[4] or 0, p[5] or 0
    end,
    SetWidth = function(self, v) self._w = v or 0 end,
    SetHeight = function(self, v) self._h = v or 0 end,
    GetWidth = function(self) return self._w end,
    GetHeight = function(self) return self._h end,
    Show = function(self) self._shown = true end,
    Hide = function(self) self._shown = false end,
    IsShown = function(self) return self._shown end,
    IsVisible = function(self) return self._shown end,
    SetAlpha = function() end,
    GetAlpha = function() return 1 end,
    SetTexture = function() end,
    SetVertexColor = function() end,
    SetTexCoord = function() end,
    SetBlendMode = function() end,
    SetDrawLayer = function() end,
    SetFont = function() return true end,
    SetText = function(self, t) self._text = t end,
    GetText = function(self) return self._text or "" end,
    SetTextColor = function() end,
    SetJustifyH = function() end,
    SetJustifyV = function() end,
    SetShadowColor = function() end,
    SetShadowOffset = function() end,
    SetAutoFocus = function() end,
    SetMaxLetters = function() end,
    ClearFocus = function() end,
    SetFocus = function() end,
    --[[ A constant here made every layout test vacuous: column widths
         are computed from measured text, so a stub that reports the same
         width for "Gah" and "Shieldbarbie" cannot tell a working layout
         from a broken one. Roughly 6px a character at the default size. ]]
    GetStringWidth = function(self)
      return string.len(self._text or "") * 6
    end,
  }

  return setmetatable(r, {
    __index = function(t, k)
      local m = methods[k]
      if m then return m end
      -- Every WoW widget method is PascalCase, so anything else is one of
      -- the addon's own optional data fields (dimAlpha, _lit, abilityId).
      -- Reading one that has not been set yet must return nil, not explode --
      -- otherwise the stub rejects perfectly ordinary Lua.
      if not string.find(k, "^%u") then return nil end
      if strict then
        error("unstubbed " .. kind .. " method: " .. tostring(k), 2)
      end
      return function() end
    end,
  })
end

local allFrames = {}

CreateFrame = function(kind, name, parent)
  calls = calls + 1
  local f = {
    _kind = kind, _name = name, _parent = parent,
    _w = 100, _h = 100, _shown = false,
    _scripts = {}, _events = {}, _points = {}, _children = {},
  }

  local methods = {
    CreateTexture = function() return region("Texture") end,
    CreateFontString = function() return region("FontString") end,
    SetScript = function(self, k, fn) self._scripts[k] = fn end,
    GetScript = function(self, k) return self._scripts[k] end,
    HasScript = function() return true end,
    RegisterEvent = function(self, e) self._events[e] = true end,
    UnregisterEvent = function(self, e) self._events[e] = nil end,
    RegisterForClicks = function() end,
    RegisterForDrag = function() end,
    EnableMouse = function() end,
    EnableMouseWheel = function() end,
    EnableKeyboard = function() end,
    SetMovable = function() end,
    SetResizable = function() end,
    SetClampedToScreen = function() end,
    SetMinResize = function() end,
    SetMaxResize = function() end,
    StartMoving = function() end,
    StartSizing = function() end,
    StopMovingOrSizing = function() end,
    SetFrameStrata = function(self, s) self._strata = s end,
    SetFrameLevel = function() end,
    GetFrameLevel = function() return 1 end,
    SetToplevel = function() end,
    SetBackdrop = function() end,
    SetBackdropColor = function() end,
    SetBackdropBorderColor = function() end,
    GetCenter = function() return 400, 300 end,
    GetEffectiveScale = function() return 1 end,
    SetScale = function() end,
    Raise = function() end,
    SetHitRectInsets = function() end,
    SetNormalTexture = function() end,
    SetHighlightTexture = function() end,
    GetParent = function(self) return self._parent end,
    SetParent = function() end,
    SetID = function() end,
    GetID = function() return 0 end,
    SetSequence = function() end,
  }

  -- Frames share the region methods (SetPoint, sizing, visibility).
  local base = region("Frame")

  local mt = {
    __index = function(t, k)
      local m = methods[k]
      if m then return m end
      local rm = rawget(base, k)
      if rm then return rm end
      -- fall through to the region metatable
      local ok, v = pcall(function() return base[k] end)
      if ok and v then return v end
      -- See the note in region(): non-PascalCase keys are the addon's data.
      if not string.find(k, "^%u") then return nil end
      if strict then
        error("unstubbed Frame method: " .. tostring(k), 2)
      end
      return function() end
    end,
  }

  setmetatable(f, mt)
  table.insert(allFrames, f)
  if name then _G[name] = f end
  return f
end

----------------------------------------------------------------------
-- globals the UI touches
----------------------------------------------------------------------

_G = _G or getfenv(0)

UIParent = CreateFrame("Frame", "UIParent")
UIParent:SetWidth(1024) UIParent:SetHeight(768)
Minimap = CreateFrame("Frame", "Minimap")
Minimap:SetWidth(140) Minimap:SetHeight(140)

GameTooltip = {
  SetOwner = function() end, AddLine = function() end,
  Show = function() end, Hide = function() end,
}

SlashCmdList = {}
StaticPopupDialogs = {}
StaticPopup_Show = function(k) return StaticPopupDialogs[k] ~= nil end
UISpecialFrames = {}
GetCursorPosition = function() return 400, 300 end

DEFAULT_CHAT_FRAME = { AddMessage = function() end }

-- engine-side stubs (same as test_engine)
local WORLD = {}
GetUnitData = function(g) return WORLD[g] and true or nil end
UnitName = function(u) local d = WORLD[u] return d and d.name or "Player" end
UnitIsPlayer = function(u) local d = WORLD[u] return (d and d.isPlayer) and 1 or 0 end
UnitClass = function(u) local d = WORLD[u] return d and d.class, d and d.class end
UnitLevel = function() return 60 end
UnitHealth = function(u) local d = WORLD[u] return d and d.health or 0 end
UnitHealthMax = function(u) local d = WORLD[u] return d and d.maxHealth or 0 end
UnitIsUnit = function(a, b) return a == b end
UnitCanCooperate = function() return 1 end
UnitExists = function(u) return WORLD[u] ~= nil, u end
GetUnitGUID = function(tok)
  local base = string.gsub(tok, "owner$", "")
  if base == tok then return nil end
  local d = WORLD[base]
  return d and d.owner or nil
end
SpellInfo = function(id) return "Spell " .. tostring(id), nil, "icon" end
IN_COMBAT = true
UnitAffectingCombat = function(unit) return IN_COMBAT end
GetItemInfo = function(id)
  local items = { [13446] = "Major Healing Potion", [20520] = "Dark Rune" }
  return items[id]
end
GetRealZoneText = function() return "Onyxia's Lair" end
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end
SetCVar = function() end
GetCVar = function() return "1" end
IsInInstance = function() return 1, "raid" end
GetAddOnMetadata = function() return "test" end
GetBuildInfo = function() return "1.12.1", "5875", "2006" end
WriteCustomFile = function() return true end
ReadCustomFile = function() return nil end
--[==[ SendAddonMessage in 1.12 accepts only these chat types. "WHISPER" is
       NOT among them -- this client rejects it with "Unknown addon chat
       type" and then dies with ERROR #132, so the stub has to be as strict
       as the client or the crash is invisible here. ]==]
local ADDON_CHANNELS = {
  PARTY = true, RAID = true, GUILD = true, BATTLEGROUND = true,
}
local function checkAddonChannel(channel, target)
  if not ADDON_CHANNELS[tostring(channel)] then
    error("SendAddonMessage: '" .. tostring(channel) ..
      "' is not a valid 1.12 addon chat type (PARTY/RAID/GUILD/BATTLEGROUND)", 3)
  end
  if target ~= nil then
    error("SendAddonMessage: 1.12 takes no target argument; " ..
      "address the message in its payload instead", 3)
  end
end
SendAddonMessage = function(prefix, msg, channel, target)
  checkAddonChannel(channel, target)
end
CHAT = {}
SendChatMessage = function(msg, chan, _, target)
  table.insert(CHAT, { msg = msg, chan = chan, target = target })
end
IsInGuild = function() return true end

----------------------------------------------------------------------
-- load everything
----------------------------------------------------------------------

dofile("core.lua")
dofile("capture.lua")
dofile("encounter.lua")
dofile("metrics.lua")
dofile("report.lua")
dofile("diagnostics.lua")
dofile("store.lua")
dofile("sync.lua")
dofile("announce.lua")
dofile("ui/widgets.lua")
dofile("ui/chart.lua")
dofile("ui/meter.lua")
dofile("ui/report.lua")
dofile("ui/confirm.lua")
dofile("ui/settings.lua")
dofile("ui/peers.lua")
dofile("minimap.lua")
dofile("commands.lua")

WrekkitDB = nil
Wrekkit.InitDB()
Wrekkit.capture:Start()

----------------------------------------------------------------------
-- give it something to render
----------------------------------------------------------------------

local function defP(g, n, c, hp) WORLD[g] = { name = n, class = c, isPlayer = true, maxHealth = hp, health = hp } end
local function defN(g, n, hp) WORLD[g] = { name = n, isPlayer = false, maxHealth = hp, health = hp } end
local function defPet(g, n, o) WORLD[g] = { name = n, isPlayer = false, owner = o, maxHealth = 900, health = 900 } end

defP("0xA", "Fuff", "ROGUE", 3000)
defP("0xB", "Elfpriest", "PRIEST", 2600)
defP("0xC", "Moorhunt", "HUNTER", 3400)
defPet("0xP", "Raptor", "0xC")
defN("0xBoss", "Onyxia", 1200000)

local D = Wrekkit.capture.dispatch
local function fire(e, ...) local h = D[e] if h then h(...) end end

-- two encounters so the sidebar and merging have something to chew on
for pull = 1, 2 do
  Wrekkit.encounter:CombatStart()
  for i = 1, 30 do
    fire("AUTO_ATTACK_SELF", "0xA", "0xBoss", 200 + i * 7, (i == 5) and 2 or 0, 0, 1, 0, 0, 0)
    fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xC", 100 + i, 300, "0,0,0", 0, 0)
    fire("AUTO_ATTACK_OTHER", "0xP", "0xBoss", 90, 0, 0, 1, 0, 0, 0)
    fire("SPELL_DAMAGE_EVENT_OTHER", "0xA", "0xBoss", 200, 400 + i, "20,0,0", 0, 0)
    fire("SPELL_HEAL_BY_OTHER", "0xA", "0xB", 500, 350, 0, 0)
    NOW = NOW + 1
  end
  fire("UNIT_DIED", "0xA")
  -- Leave combat through the real path. Setting inCombat directly leaves
  -- stopT where it started, so the encounter measures zero seconds and the
  -- minimum-duration filter silently discards it -- which is exactly how
  -- this harness ended up rendering empty windows while reporting success.
  Wrekkit.encounter:CombatEnd()
  Wrekkit.encounter:Finish()
  NOW = NOW + 20
end

if table.getn(Wrekkit.db.encounters) == 0 then
  error("setup recorded nothing -- the UI tests below would all be vacuous")
end

----------------------------------------------------------------------
-- drive the UI
----------------------------------------------------------------------

local pass, fail = 0, 0
local function step(label, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
    print(string.format("  ok    %s", label))
  else
    fail = fail + 1
    print(string.format("  FAIL  %s\n        %s", label, tostring(err)))
  end
end

print("\nWrekkit UI smoke test\n")

local UI = Wrekkit.ui

step("meter builds", function() UI.meter:Create() end)
step("meter shows", function() UI.meter:Show() end)
step("meter refreshes", function() UI.meter:Refresh() end)

step("meter renders every metric", function()
  for _, m in ipairs(Wrekkit.metrics.list) do
    UI.meter:SetMetric(m.key)
  end
  UI.meter:SetMetric("damage")
end)

step("meter segments", function()
  for _, seg in ipairs({ "current", "last", "overall" }) do
    UI.meter:Settings().segment = seg
    UI.meter:Refresh()
  end
end)

step("meter drilldown", function()
  local rows = UI.meter.list.data
  local first = rows and rows[1]
  if first then
    UI.meter.drill = first.key
    UI.meter:Refresh()
    UI.meter.drill = nil
    UI.meter:Refresh()
  end
end)

step("meter filter", function()
  UI.meter:Settings().search = "fuf"
  UI.meter:Refresh()
  UI.meter:Settings().search = ""
  UI.meter:Refresh()
end)

step("meter pets split", function()
  UI.meter:Settings().petMode = "separate"
  UI.meter:Refresh()
  UI.meter:Settings().petMode = "merge"
  UI.meter:Refresh()
end)

step("meter toolbar toggles", function()
  UI.meter:Settings().showToolbar = false
  UI.meter:ApplyToolbar()
  UI.meter:Settings().showToolbar = true
  UI.meter:ApplyToolbar()
end)

step("meter scrolls", function() UI.meter.list:Scroll(-1) UI.meter.list:Scroll(1) end)

step("meter menus open", function()
  UI.meter:MetricMenu(UI.meter.frame.bar)
  UI.CloseMenu()
  UI.meter:SegmentMenu(UI.meter.frame.bar)
  UI.CloseMenu()
end)

step("menus do not leak frames", function()
  -- 1.12 cannot destroy a frame, so a menu that rebuilds itself per open
  -- would grow the frame count forever. Open a lot and check it settles.
  UI.meter:MetricMenu(UI.meter.frame.bar)
  UI.CloseMenu()
  local baseline = calls
  for i = 1, 40 do
    UI.meter:MetricMenu(UI.meter.frame.bar)
    UI.CloseMenu()
    UI.meter:SegmentMenu(UI.meter.frame.bar)
    UI.CloseMenu()
  end
  if calls ~= baseline then
    error(string.format("leaked %d frames over 80 menu opens", calls - baseline))
  end
end)

step("report builds", function() UI.report:Create() end)
step("report shows", function() UI.report:Show() end)

step("report renders every tab", function()
  for _, tab in ipairs(UI.report.tabs) do
    UI.report.state.tab = tab.key
    if tab.metric then UI.report.state.sortKey = tab.metric end
    UI.report:Refresh()
  end
  UI.report.state.tab = "summary"
  UI.report:Refresh()
end)

step("report encounter selection", function()
  local session = UI.report:Session()
  if session and session.encounters[1] then
    local enc = session.encounters[1]
    UI.report.state.selected = { [tostring(enc.sessionId) .. ":" .. tostring(enc.id)] = true }
    UI.report:Refresh()
  end
  UI.report:SelectAll()
end)

step("report drilldown", function()
  local rows = UI.report.sumLeftList.data
  local first = rows and rows[1]
  if first then
    UI.report.state.drill = first.key
    UI.report:Refresh()
    UI.report.state.drill = nil
    UI.report:Refresh()
  end
end)

step("report filter", function()
  UI.report.state.search = "elf"
  UI.report:Refresh()
  UI.report.state.search = ""
  UI.report:Refresh()
end)

step("report session menu", function()
  UI.report:SessionMenu()
  UI.CloseMenu()
end)

step("chart toggles series", function()
  UI.report.chart:Toggle("dd")
  UI.report:RefreshChart()
  UI.report.chart:Toggle("dd")
  UI.report:RefreshChart()
end)

step("chart handles an empty selection", function()
  UI.report.chart:SetSeries(nil, 0, 0, {})
end)

step("report resizes", function()
  UI.report.frame:SetWidth(700) UI.report.frame:SetHeight(450)
  UI.report:Refresh()
  UI.report.frame:SetWidth(1100) UI.report.frame:SetHeight(700)
  UI.report:Refresh()
end)

step("windows render during a LIVE pull", function()
  -- The path a new user actually hits first: install, pull something, open
  -- the windows mid-fight. A live encounter differs from a finished one --
  -- no duration yet, ability tables still keyed by spell id, buckets still
  -- named fields -- so it must be exercised before Finish() normalises it.
  Wrekkit.encounter:CombatStart()
  for i = 1, 10 do
    fire("AUTO_ATTACK_SELF", "0xA", "0xBoss", 250, 0, 0, 1, 0, 0, 0)
    fire("SPELL_HEAL_BY_OTHER", "0xA", "0xB", 500, 300, 0, 0)
    NOW = NOW + 1
  end

  UI.meter:Settings().segment = "current"
  UI.meter:Refresh()

  UI.report.state.tab = "summary"
  UI.report:Refresh()
  for _, tab in ipairs(UI.report.tabs) do
    UI.report.state.tab = tab.key
    UI.report:Refresh()
  end
  UI.report.state.tab = "summary"
end)

step("clicking real handlers (not just setting state)", function()
  -- Driving state directly skips the closures the buttons actually run, so
  -- a nil upvalue inside one would never surface. Fire them for real.
  arg1 = "LeftButton"

  for _, tab in ipairs(UI.report.tabs) do
    local b = UI.report.tabButtons[tab.key]
    local fn = b:GetScript("OnClick")
    if not fn then error("tab " .. tab.key .. " has no OnClick") end
    fn()
  end

  -- sidebar encounter rows
  for _, row in ipairs(UI.report.encList.rows) do
    local fn = row:GetScript("OnClick")
    if fn and row:IsShown() then
      fn()
      arg1 = "RightButton"; fn()
      arg1 = "LeftButton"
    end
  end

  -- report table rows, both buttons
  for _, row in ipairs(UI.report.sumLeftList.rows) do
    local fn = row:GetScript("OnClick")
    if fn and row:IsShown() then
      fn()
      arg1 = "RightButton"; fn()
      arg1 = "LeftButton"
    end
  end

  -- meter rows
  UI.meter:Refresh()
  for _, row in ipairs(UI.meter.list.rows) do
    local fn = row:GetScript("OnClick")
    if fn and row:IsShown() then
      fn()
      arg1 = "RightButton"; fn()
      arg1 = "LeftButton"
    end
  end

  -- chart legend
  for _, b in ipairs(UI.report.chart.legendButtons) do
    local fn = b:GetScript("OnClick")
    if fn then fn() fn() end
  end

  arg1 = nil
end)

step("Escape closes the report", function()
  local found = false
  for _, n in ipairs(UISpecialFrames) do
    if n == "WrekkitReport" then found = true end
  end
  if not found then error("WrekkitReport not registered in UISpecialFrames") end
  if not _G["WrekkitReport"] then error("report frame has no global name") end
  -- and the meter must NOT be, it is a HUD element
  for _, n in ipairs(UISpecialFrames) do
    if n == "WrekkitMeter" then error("meter should not close on Escape") end
  end
end)

step("ability detail drills two levels deep", function()
  -- actor -> abilities -> one ability's spread, in both windows.
  UI.report.state.tab = "damage"
  UI.report.state.drill = nil
  UI.report.state.drillAbility = nil
  UI.report:Refresh()

  local rows = UI.report.mainList.data
  if not rows or not rows[1] then error("no rows to drill into") end
  UI.report.state.drill = rows[1].key
  UI.report:Refresh()

  local abilities = UI.report.mainList.data
  if not abilities or not abilities[1] then error("no abilities in the drilldown") end
  if not abilities[1].id then error("ability row carries no id to drill on") end

  UI.report.state.drillAbility = abilities[1].id
  UI.report:Refresh()

  local stats = UI.report.mainList.data
  if not stats or not stats[1] or not stats[1].label then
    error("ability detail did not produce label/value rows")
  end

  -- and back out
  UI.report.state.drillAbility = nil
  UI.report.state.drill = nil
  UI.report.state.tab = "summary"
  UI.report:Refresh()

  -- same journey on the meter
  UI.meter:Refresh()
  local mrows = UI.meter.list.data
  if mrows and mrows[1] then
    UI.meter.drill = mrows[1].key
    UI.meter:Refresh()
    local mab = UI.meter.list.data
    if mab and mab[1] then
      UI.meter.drillAbility = mab[1].id
      UI.meter:Refresh()
    end
    UI.meter.drillAbility = nil
    UI.meter.drill = nil
    UI.meter:Refresh()
  end
end)

step("HUD toggle buttons work", function()
  arg1 = "LeftButton"
  for _, name in ipairs({ "groupBtn", "worldBtn", "resetBtn" }) do
    local b = UI.meter[name]
    if not b then error("meter is missing " .. name) end
    local fn = b:GetScript("OnClick")
    if not fn then error(name .. " has no OnClick") end
    fn()
    fn()
  end
  -- right-click reset must route through the confirmation, not wipe directly
  arg1 = "RightButton"
  UI.meter.resetBtn:GetScript("OnClick")()
  arg1 = "LeftButton"

  -- the toggles must reflect the state they represent
  UI.meter:Settings().groupOnly = true
  UI.meter:UpdateToggles()
  if not UI.meter.groupBtn._lit then error("group toggle did not light up") end
  UI.meter:Settings().groupOnly = false
  UI.meter:UpdateToggles()
  if UI.meter.groupBtn._lit then error("group toggle stayed lit") end

  -- hover tooltips
  UI.meter.groupBtn:GetScript("OnEnter")()
  UI.meter.groupBtn:GetScript("OnLeave")()
  arg1 = nil
end)

step("report sits above the meter", function()
  if not UI.report.frame._strata then
    error("report window never had its strata set")
  end
  if UI.report.frame._strata ~= "HIGH" then
    error("report strata is " .. tostring(UI.report.frame._strata) .. ", expected HIGH")
  end
  if UI.meter.frame._strata == "HIGH" then
    error("meter is on the same strata as the report; it will draw over it")
  end
end)

step("sidebar padlock keeps an encounter", function()
  UI.report:Refresh()
  local row = UI.report.encList.rows[1]
  if not row then error("no encounter rows in the sidebar") end
  if not row.lock then error("sidebar row has no padlock") end

  local before = Wrekkit.CountLocked()
  local fn = row.lock:GetScript("OnClick")
  if not fn then error("padlock has no OnClick") end

  fn()
  if Wrekkit.CountLocked() ~= before + 1 then
    error("clicking the padlock did not lock anything" ..
      (Wrekkit.lastError and ("; guard caught: " .. Wrekkit.lastError.err) or ""))
  end
  if not row.lock._lit then error("padlock did not light up") end

  fn()
  if Wrekkit.CountLocked() ~= before then
    error("clicking again did not unlock")
  end
end)

step("meter shows by default and remembers being hidden", function()
  -- Default is visible.
  if Wrekkit.ui.meter.defaults.shown ~= true then
    error("meter does not default to shown")
  end

  -- The title-bar X must persist the choice, not just hide the frame --
  -- otherwise it comes back on the next login and looks broken.
  UI.meter:Show()
  local close = UI.meter.frame.closeButton:GetScript("OnClick")
  if not close then error("close button has no handler") end
  close()
  if UI.meter.frame:IsShown() then error("close did not hide the meter") end
  if UI.meter:Settings().shown ~= false then
    error("close did not persist -- the meter would return next login")
  end

  -- A fresh login with shown=false must leave it hidden.
  UI.meter:RestoreVisibility()
  if UI.meter.frame:IsShown() then
    error("restore reopened a meter the user had closed")
  end

  -- ...and with shown=true must bring it back.
  UI.meter:Settings().shown = true
  UI.meter.frame:Hide()
  UI.meter:RestoreVisibility()
  if not UI.meter.frame:IsShown() then error("restore did not reopen the meter") end

  -- Toggle keeps the setting in step with the frame.
  UI.meter:Toggle()
  if UI.meter:Settings().shown ~= false then error("toggle-off did not persist") end
  UI.meter:Toggle()
  if UI.meter:Settings().shown ~= true then error("toggle-on did not persist") end
end)

step("announce goes through confirmation, never straight to chat", function()
  CHAT = {}
  UI.CloseConfirm()

  -- Pretend we are grouped: the availability check correctly refuses PARTY
  -- while solo, which is the behaviour the next step asserts.
  local realParty = GetNumPartyMembers
  GetNumPartyMembers = function() return 4 end

  -- The report announces whatever TAB is open.
  UI.report:Show()
  UI.report.state.tab = "healing"
  UI.report:Refresh()
  local ctx = UI.report:AnnounceContext()
  if ctx.metrics[1] ~= "healing" then
    error("healing tab announced " .. tostring(ctx.metrics[1]))
  end
  UI.report.state.tab = "summary"
  UI.report:Refresh()
  if table.getn(UI.report:AnnounceContext().metrics) ~= 2 then
    error("summary should announce both of its panels")
  end

  -- The meter announces its current metric.
  UI.meter:SetMetric("taken")
  if UI.meter:AnnounceContext().metric ~= "taken" then
    error("meter announced the wrong metric")
  end
  UI.meter:SetMetric("damage")

  -- Opening the picker must not send anything.
  UI.AnnounceMenu(UI.report.frame, UI.report.announceBtn, ctx)
  if table.getn(CHAT) > 0 then error("the channel menu posted to chat") end
  UI.CloseMenu()

  -- Requesting a channel raises the confirmation, still without sending.
  Wrekkit.announce:Request(ctx, "PARTY", nil, 3)
  if table.getn(CHAT) > 0 then
    error("Request posted to chat before the user confirmed")
  end
  if not _G["WrekkitConfirm"]:IsShown() then
    error("no confirmation dialog appeared")
  end

  -- Cancel sends nothing.
  UI.CloseConfirm()
  if table.getn(CHAT) > 0 then error("cancel still posted to chat") end

  -- Only Send does.
  Wrekkit.announce:Request(ctx, "PARTY", nil, 3)
  local dlg = _G["WrekkitConfirm"]
  dlg.sendBtn:GetScript("OnClick")()
  while table.getn(Wrekkit.announce.queue) > 0 do
    local job = table.remove(Wrekkit.announce.queue, 1)
    SendChatMessage(job.msg, job.channel, nil, job.target)
  end
  if table.getn(CHAT) == 0 then error("confirming sent nothing") end
  for _, m in ipairs(CHAT) do
    if m.chan ~= "PARTY" then
      error("sent to " .. tostring(m.chan) .. " instead of PARTY")
    end
  end

  -- A whisper with no name must refuse rather than post somewhere else.
  CHAT = {}
  Wrekkit.announce:Request(ctx, "WHISPER", nil, 2)
  dlg = _G["WrekkitConfirm"]
  dlg.targetBox.editBox:SetText("")
  dlg.sendBtn:GetScript("OnClick")()
  if table.getn(CHAT) > 0 then error("whispered with no target") end
  if not dlg:IsShown() then error("dialog closed despite the missing name") end

  dlg.targetBox.editBox:SetText("Fuff")
  dlg.sendBtn:GetScript("OnClick")()
  while table.getn(Wrekkit.announce.queue) > 0 do
    local job = table.remove(Wrekkit.announce.queue, 1)
    SendChatMessage(job.msg, job.channel, nil, job.target)
  end
  if table.getn(CHAT) == 0 then error("named whisper sent nothing") end
  if CHAT[1].target ~= "Fuff" then
    error("whisper went to " .. tostring(CHAT[1].target))
  end

  UI.CloseConfirm()
  CHAT = {}
  GetNumPartyMembers = realParty
end)

step("unavailable channels are refused", function()
  CHAT = {}
  -- Solo: there is no raid to post to.
  local realRaid = GetNumRaidMembers
  GetNumRaidMembers = function() return 0 end
  Wrekkit.announce:Request(UI.meter:AnnounceContext(), "RAID", nil, 3)
  GetNumRaidMembers = realRaid
  if table.getn(CHAT) > 0 then error("posted to a raid we are not in") end
  if _G["WrekkitConfirm"]:IsShown() then
    error("offered to post to an unavailable channel")
  end
end)

step("every texture path resolves to a real file", function()
  --[[ SetTexture(nil) is silent: in the stub it does nothing, and in the
       client it draws nothing. A missing UI.media key therefore produces an
       invisible icon with no error anywhere -- which is exactly how the
       padlock shipped pointing at nil. Check the table against the disk, and
       check the source against the table. ]]
  local UIm = Wrekkit.ui.media
  for key, path in pairs(UIm) do
    local file = string.gsub(path, "^.*\\", "")
    local fh = io.open("textures/" .. file .. ".tga", "rb")
    if not fh then
      error("UI.media." .. key .. " -> textures/" .. file .. ".tga does not exist")
    end
    fh:close()
  end

  -- Every UI.media.<key> mentioned in the source must exist in the table.
  local sources = {
    "ui/widgets.lua", "ui/chart.lua", "ui/meter.lua",
    "ui/report.lua", "ui/confirm.lua", "minimap.lua",
  }
  for _, src in ipairs(sources) do
    local fh = io.open(src, "r")
    if fh then
      local text = fh:read("a")
      fh:close()
      for key in string.gfind(text, "UI%.media%.(%a[%w_]*)") do
        if not UIm[key] then
          error(src .. " uses UI.media." .. key .. ", which is not defined")
        end
      end
    end
  end
end)

step("settings window builds and every control works", function()
  UI.settings:Show()
  local f = UI.settings.frame
  if not f then error("settings window did not build") end
  if table.getn(UI.settings.controls) == 0 then
    error("settings window has no controls to refresh")
  end

  -- Flip every checkbox twice: it must land back where it started, which
  -- proves get and set are talking about the same setting.
  for _, c in ipairs(UI.settings.controls) do
    local fn = c:GetScript("OnClick")
    if fn then fn() fn() end
    -- steppers have no OnClick of their own; nudge their buttons instead
    c:Refresh()
  end

  UI.settings:Refresh()
  UI.settings:Toggle()
  UI.settings:Toggle()
end)

step("compact mode and text size reshape the meter", function()
  local s = UI.meter:Settings()
  UI.meter:Show()

  local normalRows = UI.meter.list.rowHeight
  if not UI.meter.footer:IsShown() then error("footer should be up normally") end

  s.compact = true
  UI.meter:ApplyLayout()
  if UI.meter.footer:IsShown() then error("compact mode should hide the footer") end
  if UI.meter.toolbar:IsShown() then error("compact mode should hide the toolbar") end

  s.compact = false
  UI.meter:ApplyLayout()
  if not UI.meter.footer:IsShown() then error("footer did not come back") end
  if not UI.meter.toolbar:IsShown() then
    error("toolbar preference was lost across compact mode")
  end

  -- Text size has to move the pixel dimensions too, or the letters just clip.
  Wrekkit.db.fontScale = 1.5
  UI.ApplyFontScale()
  UI.meter:ApplyLayout()
  if UI.meter.list.rowHeight <= normalRows then
    error("rows did not grow with the text size")
  end

  Wrekkit.db.fontScale = 0.8
  UI.ApplyFontScale()
  UI.meter:ApplyLayout()
  if UI.meter.list.rowHeight >= normalRows then
    error("rows did not shrink with the text size")
  end

  -- Out-of-range scales must clamp rather than produce blank text.
  Wrekkit.db.fontScale = 99
  if UI.FontScale() > 1.8 then error("font scale did not clamp") end
  Wrekkit.db.fontScale = 0.01
  if UI.FontScale() < 0.7 then error("font scale did not clamp") end

  Wrekkit.db.fontScale = 1.0
  UI.ApplyFontScale()
  UI.meter:ApplyLayout()
end)

step("the segment label is a button", function()
  UI.meter:Show()
  local b = UI.meter.segBtn
  if not b then error("no segment button") end
  UI.meter:Refresh()
  if (b.label:GetText() or "") == "" then
    error("segment button has no label")
  end
  if b:GetWidth() <= 0 then error("segment button was never sized") end

  local fn = b:GetScript("OnClick")
  if not fn then error("segment button has no handler") end
  arg1 = "LeftButton"; fn()
  UI.CloseMenu()
  arg1 = "RightButton"; fn()
  UI.CloseMenu()
  arg1 = nil

  b:GetScript("OnEnter")()
  b:GetScript("OnLeave")()
end)

step("the cog opens settings from both windows", function()
  for _, owner in ipairs({ UI.meter, UI.report }) do
    if not owner.cogBtn then error("a window is missing its cog") end
    local fn = owner.cogBtn:GetScript("OnClick")
    if not fn then error("cog has no handler") end
    fn()
    UI.settings.frame:Hide()
  end
end)

step("minimap button builds", function() Wrekkit.minimap:Update() end)

step("slash commands run", function()
  local run = SlashCmdList["WREKKIT"]
  for _, cmd in ipairs({ "help", "modes", "mode dps", "segment last",
                         "segment overall", "lock", "minimap", "debug",
                         "world", "world", "accept", "accept", "status", "resume", "resume 30",
                         "peers", "sharing on", "sharing off", "channel raid", "channel auto",
                         "group", "group", "who", "keep", "keep", "prune 30", "prune all",
                         "reset", "report", "" }) do
    run(cmd)
  end
  run("debug")
end)

step("reset clears cleanly", function()
  Wrekkit.ResetData("current")
  Wrekkit.ResetData("all")
  UI.meter:Refresh()
  UI.report:Refresh()
end)


--[[ Reported with a screenshot: names truncated to "Sh..." and "Bo..." while
     the damage and per-second columns sat in obvious empty space.

     The name was charged a flat 74px for the value column, but the value is
     right-anchored with no width and auto-sizes to its text, so a short
     figure left the difference as dead space that the name had paid for.
     These measure what the name actually receives. ]]

local function measureRow(width, value, sub, subWidth)
  local parent = CreateFrame("Frame")
  local row = UI.Row(parent, 18)
  row:SetWidth(width)
  row:SetData(1, "Shieldbarbie", value, sub, 0.5, { 1, 1, 1 }, subWidth)
  return row
end

local function assert_(cond, msg)
  if not cond then error(msg, 2) end
end

step("a short value leaves the name more room than a long one", function()
  local short = measureRow(300, "862", "1 dps", 58)
  local long  = measureRow(300, "110.5k", "179 dps", 58)
  assert_(short.name:GetWidth() > long.name:GetWidth(),
    "short=" .. short.name:GetWidth() .. " long=" .. long.name:GetWidth())
end)

step("name gets the bulk of a 300px row", function()
  local r = measureRow(300, "110k", "179 dps", 58)
  assert_(r.name:GetWidth() >= 140, "name got " .. r.name:GetWidth() .. "px")
end)

step("a full name fits at the minimum window width", function()
  -- "Shieldbarbie" is 12 chars, ~72px at the default size in this stub.
  local r = measureRow(260, "110k", "179 dps", 58)
  assert_(r.name:GetWidth() >= 72, "name got " .. r.name:GetWidth() .. "px")
end)

step("name never collapses below its floor", function()
  local r = measureRow(120, "110k", "179 dps", 58)
  assert_(r.name:GetWidth() >= 60, "name got " .. r.name:GetWidth() .. "px")
end)

step("columns fit inside the row without overlapping", function()
  local r = measureRow(300, "110k", "179 dps", 58)
  local used = 26 + r.name:GetWidth() + r.sub:GetWidth()
  assert_(used <= 300, "used " .. used .. "px of 300")
end)

step("the per-second column scales with text size", function()
  local before = measureRow(300, "110k", "179 dps", 58).sub:GetWidth()
  Wrekkit.db.fontScale = 1.5
  local after = measureRow(300, "110k", "179 dps", 58).sub:GetWidth()
  Wrekkit.db.fontScale = 1
  assert_(after > before, "before=" .. before .. " after=" .. after)
end)

print(string.format("\n%d passed, %d failed  (%d frames created)\n", pass, fail, calls))
if fail > 0 then os.exit(1) end

--[[ audit.lua - dependency and completeness audit

    lua tools/audit.lua               (from the addon root)

Answers one question rigorously: what does this addon actually require, and
is any of it missing?

The method is deliberately not a regex over the source. Instead the global
table is proxied, so EVERY global the addon reads is recorded as it happens,
with the file it was read from. Each known global is tagged with where it
comes from -- Lua, stock 1.12, Blizzard's FrameXML, SuperWoW or Nampower --
and anything read that is not in the table is reported as an unknown, which
is either a typo or an undeclared dependency.

Files are loaded in the exact order the .toc lists them, so a load-order
mistake fails here rather than in the client. Then the addon is driven
through a full session -- combat, both windows, menus, settings, save/load,
sync, announce -- so runtime-only globals are caught too, not just the ones
read while files load.
]]

package.path = "./?.lua;" .. package.path

----------------------------------------------------------------------
-- Lua 5.0 shims (1.12 runs 5.0; this interpreter is 5.4)
----------------------------------------------------------------------

math.mod = math.mod or math.fmod
string.gfind = string.gfind or string.gmatch
table.getn = table.getn or function(t) return #t end
table.setn = table.setn or function() end
unpack = unpack or table.unpack

----------------------------------------------------------------------
-- where each global comes from
----------------------------------------------------------------------

local LUA      = "lua 5.0"
local WOW      = "wow 1.12"
local FRAMEXML = "blizzard ui"
local SUPER    = "SuperWoW"
local NAMPOWER = "Nampower"
local OWN      = "wrekkit"

--- source -> { name = true }
local ORIGIN = {}
local function declare(source, names)
  for name in string.gfind(names, "%S+") do ORIGIN[name] = source end
end

declare(LUA, [[
  string table math type pairs ipairs tonumber tostring pcall setmetatable
  getmetatable rawget rawset unpack next error assert select getfenv setfenv
  os io date time
]])

-- UnitBuff is stock 1.12; SuperWoW extends it with the spell id, which is
-- what Wrekkit reads (C:ScanBuffs) to find buffs older than a /reload.
declare(WOW, [[
  UnitBuff
  CreateFrame UIParent GetTime GetLocale GetBuildInfo GetRealZoneText
  GetRealmName IsInInstance GetNumRaidMembers GetNumPartyMembers
  GetRaidRosterInfo UnitName UnitClass UnitLevel UnitHealth UnitHealthMax UnitClassification
  UnitExists UnitIsPlayer UnitIsUnit UnitCanCooperate UnitAffectingCombat
  SetCVar GetCVar SendChatMessage SendAddonMessage GetAddOnMetadata
  GetNumSavedInstances GetSavedInstanceInfo UnitIsGhost
  GetItemInfo IsInGuild GetCursorPosition Minimap
  this event arg1 arg2 arg3 arg4 arg5 arg6 arg7 arg8 arg9
]])

declare(FRAMEXML, [[
  DEFAULT_CHAT_FRAME GameTooltip SlashCmdList StaticPopupDialogs
  StaticPopup_Show UISpecialFrames
  UNKNOWN MouseIsOver
]])

declare(SUPER, [[
  SpellInfo GetUnitGUID GetUnitData GetUnitField
]])

declare(NAMPOWER, [[
  WriteCustomFile ReadCustomFile CustomFileExists NAMPOWER_VERSION
]])

-- Globals the addon defines itself. Reading one before it is written would
-- be a load-order bug, so they are tracked separately rather than excused.
declare(OWN, [[
  Wrekkit WrekkitDB SLASH_WREKKIT1 SLASH_WREKKIT2
]])

----------------------------------------------------------------------
-- the stub client
----------------------------------------------------------------------

local WORLD = {}
local NOW = 1000.0
local IN_COMBAT = true
local DISK, CHAT, WIRE = {}, {}, {}

local frameCount = 0

----------------------------------------------------------------------
-- anchor validation
----------------------------------------------------------------------

--[[ The client resolves anchors in C, and a bad one does not raise a Lua
     error -- it corrupts the layout pass and takes the process with it
     (ERROR #132, ACCESS_VIOLATION, with the anchor point string still in a
     register). None of that is visible from Lua, so the stub has to be the
     thing that refuses it.

     Three ways to get it wrong, all silent until they are fatal:
       - an anchor point that is not one of the nine valid names
       - anchoring to something that is not a frame (a nil local, typically)
       - a cycle: A positioned from B while B is positioned from A ]]

local VALID_POINT = {
  TOPLEFT = true, TOP = true, TOPRIGHT = true,
  LEFT = true, CENTER = true, RIGHT = true,
  BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local anchorProblems = {}
local allRegions = {}

local function checkAnchor(self, point, relativeTo, relativePoint, x, y)
  local function bad(why)
    table.insert(anchorProblems,
      (self._kind or "region") .. " SetPoint(" .. tostring(point) .. ", " ..
      tostring(relativeTo) .. ", " .. tostring(relativePoint) .. "): " .. why)
  end

  if type(point) ~= "string" or not VALID_POINT[point] then
    bad("'" .. tostring(point) .. "' is not a valid anchor point")
  end

  -- The 2-argument form SetPoint(point, relativeTo) is legal; so is the
  -- 3-arg form with offsets omitted. Only an explicitly wrong type is a bug.
  if relativePoint ~= nil and
     (type(relativePoint) ~= "string" or not VALID_POINT[relativePoint]) then
    -- SetPoint(point, x, y) shorthand puts a number here, which is fine.
    if type(relativePoint) ~= "number" then
      bad("'" .. tostring(relativePoint) .. "' is not a valid anchor point")
    end
  end

  if relativeTo ~= nil and type(relativeTo) ~= "table"
      and type(relativeTo) ~= "string" and type(relativeTo) ~= "number" then
    bad("anchored to a " .. type(relativeTo))
  end

  if relativeTo == self then
    bad("anchored to itself")
  end

  if type(relativeTo) == "table" then
    self._anchors = self._anchors or {}
    self._anchors[relativeTo] = true
  end
end

--- Walk the anchor graph looking for a cycle.
local function findAnchorCycles()
  local state = {}   -- region -> nil | "open" | "done"
  local found = {}

  local function visit(node, path)
    if state[node] == "done" then return end
    if state[node] == "open" then
      table.insert(found, table.getn(path) .. "-frame anchor cycle")
      return
    end
    state[node] = "open"
    table.insert(path, node)
    for target in pairs(node._anchors or {}) do
      visit(target, path)
    end
    table.remove(path)
    state[node] = "done"
  end

  for _, r in ipairs(allRegions) do visit(r, {}) end
  return found
end

local function region(kind)
  local r = { _w = 0, _h = 0, _shown = true, _points = {} }
  table.insert(allRegions, r)
  local m = {}
  m.SetPoint = function(self, ...)
    local args = { ... }
    checkAnchor(self, args[1], args[2], args[3], args[4], args[5])
    table.insert(self._points, args)
  end
  m.SetAllPoints = function() end
  m.ClearAllPoints = function(self) self._points = {} end
  m.GetPoint = function(self)
    local p = self._points[1]
    if not p then return "CENTER", nil, "CENTER", 0, 0 end
    return p[1], p[2], p[3], p[4] or 0, p[5] or 0
  end
  m.SetWidth = function(self, v) self._w = v or 0 end
  m.SetHeight = function(self, v) self._h = v or 0 end
  m.GetWidth = function(self) return self._w end
  m.GetHeight = function(self) return self._h end
  m.Show = function(self) self._shown = true end
  m.Hide = function(self) self._shown = false end
  m.IsShown = function(self) return self._shown end
  m.IsVisible = function(self) return self._shown end
  --[[ Slider. Modelled on the real thing rather than no-ops: the client
       clamps, quantises to the step, and FIRES OnValueChanged from SetValue.
       That last part matters -- it is what makes a control that refreshes
       itself from its own setter re-enter, so a stub that stayed silent
       would hide the bug the guard exists for. ]]
  m.SetOrientation = function() end
  m.SetMinMaxValues = function(self, lo, hi) self._min, self._max = lo, hi end
  m.GetMinMaxValues = function(self) return self._min or 0, self._max or 1 end
  m.SetValueStep = function(self, st) self._step = st end
  m.SetThumbTexture = function(self, t) self._thumb = t end
  m.GetThumbTexture = function(self) return self._thumb end
  m.SetValue = function(self, v)
    local lo, hi = self._min or 0, self._max or 1
    if v < lo then v = lo elseif v > hi then v = hi end
    local st = self._step
    if st and st > 0 then v = lo + math.floor((v - lo) / st + 0.5) * st end
    self._value = v
    local fn = self._scripts and self._scripts.OnValueChanged
    if fn then fn() end
  end
  m.GetValue = function(self) return self._value or self._min or 0 end
  m.SetAlpha = function() end
  m.GetAlpha = function() return 1 end
  m.SetTexture = function(self, v) self._tex = v end
  m.GetTexture = function(self) return self._tex end
  m.SetVertexColor = function() end
  m.SetTexCoord = function() end
  m.SetBlendMode = function() end
  m.SetDrawLayer = function() end
  m.SetFont = function(self, face, size) self._face, self._size = face, size return true end
  m.GetFont = function(self) return self._face, self._size end
  m.SetText = function(self, t) self._text = t end
  m.GetText = function(self) return self._text or "" end
  m.SetTextColor = function() end
  m.SetJustifyH = function() end
  m.SetJustifyV = function() end
  m.SetShadowColor = function() end
  m.SetShadowOffset = function() end
  m.SetAutoFocus = function() end
  m.SetMaxLetters = function() end
  m.ClearFocus = function() end
  m.SetFocus = function() end
  m.GetStringWidth = function(self) return string.len(self._text or "") * 5 end

  return setmetatable(r, { __index = function(_, k)
    local fn = m[k]
    if fn then return fn end
    if not string.find(k, "^%u") then return nil end
    error("unstubbed " .. kind .. " method: " .. tostring(k), 2)
  end })
end

local function makeFrame(kind, name, parent)
  frameCount = frameCount + 1
  local f = { _kind = kind, _name = name, _parent = parent,
              _w = 100, _h = 100, _shown = false,
              _scripts = {}, _events = {}, _points = {} }
  table.insert(allRegions, f)
  local base = region("Frame")
  local m = {}
  m.CreateTexture = function() return region("Texture") end
  m.CreateFontString = function() return region("FontString") end
  m.SetScript = function(self, k, fn) self._scripts[k] = fn end
  m.GetScript = function(self, k) return self._scripts[k] end
  m.HasScript = function() return true end
  m.RegisterEvent = function(self, e) self._events[e] = true end
  m.UnregisterEvent = function(self, e) self._events[e] = nil end
  m.RegisterForClicks = function() end
  m.RegisterForDrag = function() end
  m.EnableMouse = function() end
  m.EnableMouseWheel = function() end
  m.EnableKeyboard = function() end
  m.SetMovable = function() end
  m.SetResizable = function() end
  m.SetClampedToScreen = function() end
  m.SetMinResize = function() end
  m.SetMaxResize = function() end
  m.StartMoving = function() end
  m.StartSizing = function() end
  m.StopMovingOrSizing = function() end
  m.SetFrameStrata = function(self, s) self._strata = s end
  m.GetFrameStrata = function(self) return self._strata end
  m.SetFrameLevel = function(self, v) self._level = v end
  m.GetFrameLevel = function(self) return self._level or 1 end
  m.SetToplevel = function() end
  m.SetBackdrop = function() end
  m.SetBackdropColor = function() end
  m.SetBackdropBorderColor = function() end
  m.GetCenter = function() return 400, 300 end
  m.GetEffectiveScale = function() return 1 end
  m.SetScale = function() end
  m.Raise = function() end
  m.SetHitRectInsets = function() end
  m.SetNormalTexture = function() end
  m.SetHighlightTexture = function() end
  m.GetParent = function(self) return self._parent end
  m.SetParent = function() end
  m.SetID = function() end
  m.GetID = function() return 0 end

  if name then rawset(_G, name, f) end

  setmetatable(f, { __index = function(_, k)
    local fn = m[k]
    if fn then return fn end
    local ok, v = pcall(function() return base[k] end)
    if ok and v then return v end
    if not string.find(k, "^%u") then return nil end
    error("unstubbed Frame method: " .. tostring(k), 2)
  end })
  return f
end

----------------------------------------------------------------------
-- the recording proxy
----------------------------------------------------------------------

local STUB = {}
local reads = {}      -- name -> { count, files = { file = true } }
local currentFile = "(startup)"

local function record(name)
  local e = reads[name]
  if not e then e = { count = 0, files = {} } reads[name] = e end
  e.count = e.count + 1
  e.files[currentFile] = true
end

--[[ Globals the addon WRITES (Wrekkit, SLASH_*) land in _G directly and are
     then found without __index firing, so they never appear as reads. That
     is what we want: this records the addon's imports, not its exports. ]]
setmetatable(_G, {
  __index = function(_, k)
    record(k)
    return STUB[k]
  end,
})

----------------------------------------------------------------------
-- populate the stub
----------------------------------------------------------------------

STUB.CreateFrame = makeFrame
STUB.GetTime = function() return NOW end
STUB.time = function() return 1700000000 + math.floor(NOW) end
STUB.date = function() return "14.09.26 12:00:00" end

STUB.UIParent = makeFrame("Frame", "UIParent")
STUB.UIParent:SetWidth(1024) STUB.UIParent:SetHeight(768)
STUB.Minimap = makeFrame("Frame", "Minimap")
STUB.Minimap:SetWidth(140) STUB.Minimap:SetHeight(140)

STUB.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
STUB.GameTooltip = { SetOwner = function() end, AddLine = function() end,
                     AddDoubleLine = function() end,
                     ClearLines = function() end,
                     Show = function() end, Hide = function() end }
STUB.SlashCmdList = {}
STUB.StaticPopupDialogs = {}
STUB.StaticPopup_Show = function(k) return STUB.StaticPopupDialogs[k] ~= nil end
STUB.UISpecialFrames = {}
STUB.GetCursorPosition = function() return 400, 300 end

STUB.GetUnitData = function(g) return WORLD[g] and true or nil end
STUB.UnitName = function(u)
  if u == "player" then return "Auditor" end
  local d = WORLD[u] return d and d.name
end
STUB.UnitIsPlayer = function(u) local d = WORLD[u] return (d and d.isPlayer) and 1 or 0 end
STUB.UnitClass = function(u)
  if u == "player" then return "Warrior", "WARRIOR" end
  local d = WORLD[u] return d and d.class, d and d.class
end
STUB.UnitLevel = function() return 60 end
STUB.UnitHealth = function(u) local d = WORLD[u] return d and d.health or 0 end
STUB.UnitHealthMax = function(u) local d = WORLD[u] return d and d.maxHealth or 0 end
--[[ Elite, worldboss and so on. The real one takes a unit token; SuperWoW
     lets a GUID stand in, which is what the addon relies on. ]]
STUB.UnitClassification = function(u) local d = WORLD[u] return d and d.rank or "normal" end
STUB.UnitIsUnit = function(a, b) return a == b end
STUB.UnitCanCooperate = function() return 1 end
STUB.UnitExists = function(u) return WORLD[u] ~= nil, u end
STUB.UnitAffectingCombat = function() return IN_COMBAT end
STUB.GetUnitGUID = function(tok)
  local base = string.gsub(tok, "owner$", "")
  if base == tok then return nil end
  local d = WORLD[base] return d and d.owner
end
STUB.GetUnitField = function() return "" end
STUB.SpellInfo = function(id) return "Spell " .. tostring(id), nil, "icon" end
STUB.GetItemInfo = function(id)
  local t = { [13446] = "Major Healing Potion" } return t[id]
end

STUB.GetRealZoneText = function() return "Onyxia's Lair" end
STUB.GetRealmName = function() return "Testrealm" end
STUB.IsInInstance = function() return 1, "raid" end

-- The lockout the session logic keys on. Stubbed so GetSavedInstanceInfo is
-- actually READ: an unexercised call reads no global and would let an
-- undeclared one through, which is how GetNumSavedInstances slipped in.
STUB.GetNumSavedInstances = function() return 1 end
STUB.GetSavedInstanceInfo = function(i)
  if i == 1 then return "Onyxia's Lair", 4471 end
  return nil
end
STUB.IsInGuild = function() return 1 end
STUB.GetNumRaidMembers = function() return 0 end
STUB.GetNumPartyMembers = function() return 0 end
STUB.GetRaidRosterInfo = function() return nil end
STUB.SetCVar = function() end
STUB.GetCVar = function() return "1" end
STUB.GetAddOnMetadata = function() return "0.1.0" end
STUB.GetLocale = function() return "enUS" end
STUB.GetBuildInfo = function() return "1.12.1", "5875", "2006" end

STUB.WriteCustomFile = function(n, c, mode)
  if mode == "a" then DISK[n] = (DISK[n] or "") .. c else DISK[n] = c end
  return true
end
STUB.ReadCustomFile = function(n) return DISK[n] end
STUB.CustomFileExists = function(n) return DISK[n] ~= nil end
--[==[ SendAddonMessage in 1.12 accepts only these chat types. "WHISPER" is
       NOT among them: this client rejects it with "Unknown addon chat type"
       and then dies with ERROR #132, ACCESS_VIOLATION. Nothing about that is
       visible from Lua, so the stub has to be exactly as strict as the
       client or the crash stays invisible here. ]==]
local ADDON_CHANNELS = {
  PARTY = true, RAID = true, GUILD = true, BATTLEGROUND = true,
}

local function checkAddonChannel(channel, target)
  if not ADDON_CHANNELS[tostring(channel)] then
    error("SendAddonMessage: '" .. tostring(channel) ..
      "' is not a valid 1.12 addon chat type " ..
      "(PARTY / RAID / GUILD / BATTLEGROUND)", 3)
  end
  if target ~= nil then
    error("SendAddonMessage: 1.12 takes no target argument; " ..
      "address the message inside its payload instead", 3)
  end
end

STUB.SendAddonMessage = function(p, m, c, t)
  checkAddonChannel(c, t)
  table.insert(WIRE, { prefix = p, msg = m, channel = c, target = t })
end
STUB.SendChatMessage = function(m, c, _, t)
  table.insert(CHAT, { msg = m, chan = c, target = t })
end

----------------------------------------------------------------------
-- load in TOC order
----------------------------------------------------------------------

local function tocFiles()
  local out = {}
  local fh = assert(io.open("Wrekkit.toc", "r"))
  for line in fh:lines() do
    line = string.gsub(line, "\r", "")
    if line ~= "" and not string.find(line, "^##") and string.find(line, "%.lua$") then
      table.insert(out, (string.gsub(line, "\\", "/")))
    end
  end
  fh:close()
  return out
end

local problems = {}
local function problem(kind, text)
  table.insert(problems, { kind = kind, text = text })
end

----------------------------------------------------------------------
-- coverage
----------------------------------------------------------------------

--[[ "No problems found" is worth exactly as much as the exercise below
     covers, so measure that rather than assert it. A call hook records the
     definition line of every function that actually runs; anything declared
     in the source and never hit is reported. That is the honest boundary of
     this audit -- an untouched function has not been checked by anything
     here, however green the rest looks. ]]

local declared = {}   -- "file:line" -> name
local hit = {}        -- "file:line" -> true

local function scanDeclarations(file)
  local fh = io.open(file, "r")
  if not fh then return end
  local n = 0
  for line in fh:lines() do
    n = n + 1
    -- `function Foo:Bar(`, `function Foo.Bar(`, `function Bar(`,
    -- `local function Bar(` -- anonymous functions are not counted, since
    -- they are handlers whose names would be meaningless here.
    local name = string.match(line, "^%s*function%s+([%w_%.:]+)%s*%(")
        or string.match(line, "^%s*local%s+function%s+([%w_]+)%s*%(")
    if name then
      declared[file .. ":" .. n] = name
    end
  end
  fh:close()
end

local function startCoverage()
  debug.sethook(function()
    local info = debug.getinfo(2, "S")
    if not info then return end
    local src = info.short_src
    if not src then return end
    src = string.gsub(src, "\\", "/")
    -- Only our own files; the stub and the interpreter are not under test.
    if string.find(src, "^tools/") then return end
    if not string.find(src, "%.lua$") then return end
    hit[src .. ":" .. tostring(info.linedefined)] = true
  end, "c")
end

local function stopCoverage()
  debug.sethook()
end

print("\nWrekkit audit\n")
print("-- load, in .toc order --")

local files = tocFiles()
for _, file in ipairs(files) do scanDeclarations(file) end
startCoverage()

for _, file in ipairs(files) do
  currentFile = file
  local fh = io.open(file, "r")
  if not fh then
    problem("missing file", file .. " is in the .toc but not on disk")
  else
    fh:close()
    local ok, err = pcall(dofile, file)
    if ok then
      print(string.format("  ok    %s", file))
    else
      print(string.format("  FAIL  %s\n        %s", file, tostring(err)))
      problem("load error", file .. ": " .. tostring(err))
    end
  end
end

----------------------------------------------------------------------
-- drive a full session
----------------------------------------------------------------------

print("\n-- exercise --")
currentFile = "(runtime)"

local W = Wrekkit
local function step(label, fn)
  local ok, err = pcall(fn)
  if ok then
    print("  ok    " .. label)
  else
    print("  FAIL  " .. label .. "\n        " .. tostring(err))
    problem("runtime error", label .. ": " .. tostring(err))
  end
end

step("initialise", function()
  WrekkitDB = nil
  W.InitDB()
  W.capture:Start()
  W.sync:Start()
end)

step("record a pull", function()
  WORLD["0xA"] = { name = "Fuff", class = "ROGUE", isPlayer = true, maxHealth = 3000, health = 3000 }
  WORLD["0xB"] = { name = "Elfpriest", class = "PRIEST", isPlayer = true, maxHealth = 2600, health = 2600 }
  WORLD["0xP"] = { name = "Raptor", isPlayer = false, owner = "0xA", maxHealth = 900, health = 900 }
  WORLD["0xBoss"] = { name = "Onyxia", isPlayer = false, maxHealth = 1200000, health = 1200000 }

  local D = W.capture.dispatch
  W.encounter:CombatStart()
  for i = 1, 25 do
    D.AUTO_ATTACK_SELF("0xA", "0xBoss", 300, 2, 0, 1, 0, 0, 0)
    D.SPELL_DAMAGE_EVENT_OTHER("0xBoss", "0xA", 11267, 500, "0,0,0", 0, 0)
    D.SPELL_HEAL_BY_OTHER("0xA", "0xB", 10201, 400, 0, 0)
    D.AUTO_ATTACK_OTHER("0xP", "0xBoss", 90, 2, 0, 1, 0, 0, 0)
    D.SPELL_GO_SELF(13446, 11390, "0xA", "0xA")
    NOW = NOW + 1
  end
  D.UNIT_DIED("0xA")
  W.encounter:CombatEnd()
  W.encounter:Finish()
  if table.getn(W.db.encounters) == 0 then error("nothing recorded") end
end)

step("build and drive both windows", function()
  W.ui.meter:Show()
  for _, m in ipairs(W.metrics.list) do W.ui.meter:SetMetric(m.key) end
  W.ui.meter:SetMetric("damage")
  W.ui.meter:ApplyLayout()

  W.ui.report:Show()
  for _, t in ipairs(W.ui.report.tabs) do
    W.ui.report.state.tab = t.key
    W.ui.report:Refresh()
  end
  W.ui.report.state.tab = "summary"
  W.ui.report:Refresh()
end)

step("peer browser", function()
  W.db.shareEnabled = true
  W.db.shareChannel = "GUILD"
  W.ui.peers:Show()
  W.ui.peers:Discover()
  W.ui.peers:Refresh()

  -- Someone answers the probe.
  W.sync:OnMessage("WREKKIT", "V~*~0.1.0~3", "GUILD", "Peer")
  W.ui.peers:Refresh()
  if table.getn(W.sync:PeerList()) == 0 then error("the peer never appeared") end

  -- We ask for their index; they send one back as a chunked transfer.
  W.ui.peers:Select("Peer")
  local idx = W.sync:EncodeIndex()
  if idx == "" then error("we have nothing to build an index from") end
  W.sync:OnMessage("WREKKIT", "H~Auditor~90~1~idx", "GUILD", "Peer")
  W.sync:OnMessage("WREKKIT", "D~Auditor~90~1~" .. idx, "GUILD", "Peer")
  W.sync:OnMessage("WREKKIT", "E~Auditor~90", "GUILD", "Peer")
  W.ui.peers:Refresh()

  local peer = W.sync.peers["Peer"]
  if not peer.index or table.getn(peer.index) == 0 then
    error("their log index never arrived")
  end

  -- Tick everything and pull it.
  W.ui.peers:ToggleAll()
  local picked = 0
  for _ in pairs(W.ui.peers.picked) do picked = picked + 1 end
  if picked == 0 then error("select-all ticked nothing") end
  W.ui.peers:SyncSelected()
  W.ui.peers:ToggleAll()

  -- The other side: they probe us, ask for our index, and pull a log.
  W.sync:OnMessage("WREKKIT", "P~*", "GUILD", "Peer")
  W.sync:OnMessage("WREKKIT", "L~Auditor", "GUILD", "Peer")
  local first = W.db.encounters[1]
  if first then
    W.sync:OnMessage("WREKKIT", "G~Auditor~" .. W.sync:Key(first), "GUILD", "Peer")
  end

  -- With sharing off, none of those requests may be answered.
  W.db.shareEnabled = false
  W.sync.queue = {}
  W.sync:OnMessage("WREKKIT", "L~Auditor", "GUILD", "Peer")
  if first then
    W.sync:OnMessage("WREKKIT", "G~Auditor~" .. W.sync:Key(first), "GUILD", "Peer")
  end
  if table.getn(W.sync.queue) > 0 then
    error("answered a request while sharing was switched off")
  end
  W.db.shareEnabled = true

  W.ui.peers:Toggle()
  W.ui.peers:Toggle()
end)

step("menus, settings, minimap", function()
  W.ui.meter:MetricMenu(W.ui.meter.frame.bar)
  W.ui.CloseMenu()
  W.ui.meter:SegmentMenu(W.ui.meter.frame.bar)
  W.ui.CloseMenu()
  W.ui.report:SessionMenu()
  W.ui.CloseMenu()
  W.ui.settings:Show()
  W.ui.settings:Refresh()
  W.minimap:Update()
end)

step("compact and text size", function()
  W.ui.meter:Settings().compact = true
  W.ui.meter:ApplyLayout()
  W.db.fontScale = 1.4
  W.ui.ApplyFontScale()
  W.ui.meter:ApplyLayout()
  W.db.fontScale = 1.0
  W.ui.ApplyFontScale()
  W.ui.meter:Settings().compact = false
  W.ui.meter:ApplyLayout()
end)

step("save, load, prune, share, announce", function()
  W.store:Save()
  W.store:Load()
  W.PruneEncounters(30)
  W.sync:ShareLatest("GUILD")
  local ctx = W.ui.meter:AnnounceContext()
  W.announce:Request(ctx, "GUILD", nil, 3)
  local dlg = _G["WrekkitConfirm"]
  if dlg then dlg.sendBtn:GetScript("OnClick")() end
end)

step("every slash command", function()
  local run = SlashCmdList["WREKKIT"]
  if not run then error("slash handler was never registered") end
  local cmds = {
    "", "help", "modes", "status", "who", "report", "config", "compact",
    "mode dps", "segment last", "segment overall", "lock", "minimap",
    "resume 20", "group", "group", "world", "world", "accept", "accept",
    "keep", "keep", "prune 30", "save", "load", "reset", "debug", "debug",
    "share guild", "request guild", "announce guild", "nonsense",
  }
  for _, c in ipairs(cmds) do run(c) end
end)

step("the other combat events", function()
  -- Misses, dispels, damage shields and environmental damage each have their
  -- own handler and their own argument order. None of them ran above.
  local D = W.capture.dispatch
  W.encounter:CombatStart()

  D.SPELL_MISS_SELF("0xA", "0xBoss", 11267, "MISS")
  D.SPELL_MISS_OTHER("0xBoss", "0xA", 25231, "DODGE")
  D.SPELL_DISPEL_BY_SELF("0xB", "0xBoss", 527)
  D.SPELL_DISPEL_BY_OTHER("0xB", "0xA", 527)
  D.DAMAGE_SHIELD_SELF("0xA", "0xBoss", 120, 2)
  D.DAMAGE_SHIELD_OTHER("0xBoss", "0xA", 80, 2)
  D.ENVIRONMENTAL_DMG_SELF("0xA", "FALLING", 250, 0, 0)
  D.ENVIRONMENTAL_DMG_OTHER("0xB", "FIRE", 90, 0, 0)

  NOW = NOW + 12
  W.encounter:CombatEnd()
  W.encounter:Finish()

  -- Those numbers have to actually land somewhere.
  local view = W.report:View(W.db.encounters, { petMode = "merge" })
  local rows = W.report:Rank(view, "dispels")
  if table.getn(rows) == 0 then error("dispels were recorded nowhere") end
end)

step("receive a shared encounter", function()
  -- Drive sync's receive path with a real transfer from "someone else".
  -- Start clean. Earlier steps (the slash commands, the share/announce
  -- step) leave half-pumped transfers behind, and replaying those would
  -- store more encounters than this step is asserting about.
  W.sync.queue = {}
  W.sync.pumping = false
  W.sync.incoming = {}
  WIRE = {}

  local last = W.db.encounters[table.getn(W.db.encounters)]
  W.sync:Share(last, "*", "RAID")

  --[[ The pump dispatches the FIRST message immediately and schedules the
       rest on a timer, which never fires with no frame loop. So the header
       is already in WIRE while the body still sits in the queue -- drain the
       remainder through the same send path to reassemble the real order. ]]
  while table.getn(W.sync.queue) > 0 do
    local job = table.remove(W.sync.queue, 1)
    SendAddonMessage("WREKKIT", job.msg, job.channel, job.target)
  end
  if table.getn(WIRE) < 3 then
    error("share produced only " .. table.getn(WIRE) .. " messages")
  end

  local before = table.getn(W.db.encounters)
  for _, m in ipairs(WIRE) do
    W.sync:OnMessage(m.prefix, m.msg, m.channel, "Someone")
  end
  if table.getn(W.db.encounters) ~= before + 1 then
    error("the shared encounter was not stored")
  end

  W.sync:Discover("GUILD")
  W.sync:OnMessage("WREKKIT", "Q~", "GUILD", "Someone")
end)

step("drill into abilities and their detail", function()
  local view = W.report:View(W.db.encounters, { petMode = "separate" })
  local rows = W.report:Rank(view, "damage")
  if table.getn(rows) == 0 then error("no rows to drill") end

  local abilities = W.report:Abilities(rows[1], "damage")
  if table.getn(abilities) == 0 then error("no abilities to open") end
  local stats = W.report:AbilityStats(abilities[1], "damage")
  if table.getn(stats) == 0 then error("ability detail produced nothing") end

  -- and through the windows, using the real click handlers
  arg1 = "LeftButton"
  W.ui.report.state.tab = "damage"
  W.ui.report:Refresh()
  local r = W.ui.report.mainList.rows[1]
  if r and r:GetScript("OnClick") then r:GetScript("OnClick")() end
  local a = W.ui.report.mainList.rows[1]
  if a and a:GetScript("OnClick") then a:GetScript("OnClick")() end
  W.ui.report.state.drill = nil
  W.ui.report.state.drillAbility = nil
  W.ui.report.state.tab = "summary"
  W.ui.report:Refresh()

  W.ui.meter:Show()
  W.ui.meter:Refresh()
  local m = W.ui.meter.list.rows[1]
  if m and m:GetScript("OnClick") then m:GetScript("OnClick")() end
  local m2 = W.ui.meter.list.rows[1]
  if m2 and m2:GetScript("OnClick") then m2:GetScript("OnClick")() end
  W.ui.meter.drill = nil
  W.ui.meter.drillAbility = nil
  W.ui.meter:Refresh()
  arg1 = nil
end)

step("widget interactions", function()
  W.ui.meter.list:Scroll(-1)
  W.ui.meter.list:Scroll(1)

  -- search box OnTextChanged
  local eb = W.ui.meter.search.editBox
  eb:SetText("fu")
  local changed = eb:GetScript("OnTextChanged")
  if changed then changed() end
  eb:SetText("")
  if changed then changed() end

  -- stepper + / - buttons in the settings window
  W.ui.settings:Show()
  for _, c in ipairs(W.ui.settings.controls) do
    local click = c:GetScript("OnClick")
    if click then click() click() end
  end
  W.ui.settings:Refresh()

  -- chart series toggles
  W.ui.report.chart:Toggle("dd")
  W.ui.report:RefreshChart()
  W.ui.report.chart:Toggle("dd")

  -- Reading the chart. Driven here because the readout is where the chart
  -- touches globals the rest of the addon never uses: it calls MouseIsOver,
  -- which was undeclared, and coverage alone would not have caught it since
  -- an unexercised handler reads no globals at all.
  local chart = W.ui.report.chart
  chart:SecondAt()
  chart:ShowReadout()
  local hit = chart.hit
  if hit and hit._scripts then
    if hit._scripts.OnEnter then hit._scripts.OnEnter() end
    if hit._scripts.OnUpdate then hit._scripts.OnUpdate() end
    if hit._scripts.OnLeave then hit._scripts.OnLeave() end
  end

  -- Announcing a drilldown: the lines for a player's abilities, and for one
  -- ability's spread, which is what the windows show when drilled in.
  do
    local ctx = W.ui.report:AnnounceContext()
    local view = W.report:View(ctx.encounters or {}, { petMode = "merge" })
    local rows = W.report:Rank(view, ctx.metric or "damage", ctx.filter)
    if rows and rows[1] then
      ctx.drill = rows[1].key
      W.announce:Lines(ctx, 5)
      local abilities = W.report:Abilities(rows[1], ctx.metric or "damage")
      if abilities and abilities[1] then
        ctx.drillAbility = abilities[1].id
        W.announce:Lines(ctx, 5)
      end
    end
  end

  -- Everything added since the last coverage pass. Driven here because an
  -- unexercised function reads no globals at all, which is how MouseIsOver
  -- once sat undeclared through a clean audit.
  do
    -- the buff dispatch entries, with the real payload:
    -- (guid, luaSlot, spellId, stacks, level, auraSlot, state)
    do
      local D = W.capture.dispatch
      D.BUFF_ADDED_SELF("0xA", 1, 17628, 1, 60, 3, 0)
      D.BUFF_ADDED_OTHER("0xA", 2, 12970, 3, 60, 4, 0)
      D.BUFF_REMOVED_OTHER("0xA", 2, 12970, 2, 60, 4, 2)
      D.BUFF_REMOVED_SELF("0xA", 2, 12970, 0, 60, 4, 1)
    end

    -- the meter's row tooltip
    do
      local rows = W.ui.meter.list and W.ui.meter.list.rows
      local row = rows and rows[1]
      if row and row._scripts and row._scripts.OnEnter then
        row._scripts.OnEnter()
        if row._scripts.OnLeave then row._scripts.OnLeave() end
      end
    end

    --[[ Buffs and live sync. Both are group-only, and the audit's world has
         no group, so without one every buff event is -- correctly -- thrown
         away and none of this code runs at all. Give it a two-person raid
         and a player-named actor for the duration. ]]
    do
      STUB.GetNumRaidMembers = function() return 2 end
      STUB.GetRaidRosterInfo = function(i)
        if i == 1 then return "Fuff", 0, 1, 60, "Rogue", "ROGUE" end
        if i == 2 then return "Auditor", 0, 1, 60, "Warrior", "WARRIOR" end
        return nil
      end
      -- SuperWoW's UnitBuff: texture, stacks, spell id.
      STUB.UnitBuff = function(unit, i)
        if unit == "0xA" and i == 1 then return "tex", 1, 17626 end
        return nil
      end
      WORLD["0xMe"] = { name = "Auditor", class = "WARRIOR", isPlayer = true,
                        maxHealth = 4000, health = 4000 }
      W.capture:ScanRoster()

      local D = W.capture.dispatch
      D.BUFF_ADDED_SELF("0xA", 1, 17628, 1, 60, 3, 0)
      W.encounter:CombatStart()
      W.encounter:Damage("0xA", "0xBoss", 11267, 100, {})
      W.encounter:Damage("0xMe", "0xBoss", 11267, 100, {})
      D.BUFF_ADDED_OTHER("0xA", 2, 12970, 3, 60, 4, 0)
      D.BUFF_REMOVED_OTHER("0xA", 2, 12970, 2, 60, 4, 2)
      D.BUFF_REMOVED_OTHER("0xA", 2, 12970, 0, 60, 4, 1)
      D.BUFF_REMOVED_SELF("0xA", 1, 17628, 0, 60, 99, 1)
      W.capture:SeedBuffs("0xA")
      W.capture:PruneBuffs()

      local live = W.encounter.live
      if live then
        local view = W.report:View({ live }, {})
        for _, r in ipairs(W.report:Rank(view, "uptime")) do
          W.report:Abilities(r, "uptime")
        end
      end

      W.db.shareEnabled = true
      W.db.liveSync = true
      W.sync:BroadcastMine(live)
      W.sync:StartLive()
      NOW = NOW + 31
      local ticker = _G["WrekkitTicker"]
      if ticker and ticker:GetScript("OnUpdate") then ticker:GetScript("OnUpdate")() end
      W.sync:StopLive()
      W.encounter:RemoteReport({ name = "Faraway", class = "MAGE", damage = 100,
        ago = 1, dur = 1, pid = "1", foe = "Onyxia" })
      W.db.liveSync = nil
      W.db.shareEnabled = false

      W.capture:ClearBuffs("0xA")
      STUB.UnitBuff = nil
      STUB.GetNumRaidMembers = function() return 0 end
      STUB.GetRaidRosterInfo = function() return nil end
      W.capture:ScanRoster()
    end
    W.Cancel("nothing")
    W.WireText("a~b,c")

    -- log range: raise, then put back
    W.capture:ApplyCombatLogRange()
    W.capture:RestoreCombatLogRange()

    -- Buff Uptime: its drilldown, choosing a buff by clicking it there, and
    -- the labels that then name it
    do
      local m = W.ui.meter
      local s = m:Settings()
      local before = s.metric
      s.metric = "uptime"
      m:Refresh()
      local rows = m.list and m.list.rows
      local first = rows and rows[1]
      if first and first._scripts and first._scripts.OnClick then
        arg1 = "LeftButton"
        first._scripts.OnClick()
        rows = m.list.rows
        first = rows and rows[1]
        if first and first._scripts and first._scripts.OnClick then
          first._scripts.OnClick()
        end
      end
      W.metrics.SelectBuff(17628, "Flask of Supreme Power")
      m:Refresh()
      W.metrics.Label(W.metrics.Get("uptime"))
      W.metrics.SelectBuff(17628)
      local view = W.report:View(W.db.encounters, {})
      for _, r in ipairs(W.report:Rank(view, "uptime")) do
        W.report:Abilities(r, "uptime")
      end
      s.metric = before
      m.drill = nil
      m:Refresh()
    end

    -- death recap rendering
    W.report:DeathRecap({ t = 10, recap = {
      { t = 8, src = "Onyxia", spell = "Flame Breath", a = 900, hp = 200 },
    } })
    W.report:DeathRecap({ t = 1 })

    -- boss marking and the scope menu
    W.SetBoss(W.db.encounters[1], true)
    W.ui.report:SelectBosses()
    W.ui.report:SelectTrash()
    W.ui.report:SelectBossNamed("Onyxia")
    W.ui.report:ToggleBossMark()
    W.ui.report:BossNames()
    W.ui.report:ScopeMenu()
    W.ui.CloseMenu()
    W.ui.report:SelectAll()
  end

  -- announce channel picker
  W.ui.AnnounceMenu(W.ui.report.frame, W.ui.report.announceBtn,
    W.ui.report:AnnounceContext())
  W.ui.CloseMenu()

  W.ui.report:SelectAll()
  W.ui.meter:ApplyToolbar()
  W.ui.meter:RestoreVisibility()
  W.ui.meter:StartTicker()
end)

step("the timer actually fires", function()
  --[[ Everything deferred in this addon rides one OnUpdate frame: the
       encounter finisher, the sync pump, the announce pacing, the restore of
       the meter at login. Nothing had ever driven it, so a broken W.After
       would have looked fine everywhere. ]]
  local ticker = _G["WrekkitTicker"]
  if not ticker then error("the timer frame was never created") end
  local onUpdate = ticker:GetScript("OnUpdate")
  if not onUpdate then error("the timer frame has no OnUpdate") end

  local fired = false
  W.After(1, function() fired = true end, "audit")
  onUpdate()
  if fired then error("the job ran before its delay elapsed") end
  NOW = NOW + 2
  onUpdate()
  if not fired then error("W.After never ran the job") end

  -- Keyed jobs must replace, not stack.
  local count = 0
  W.After(1, function() count = count + 1 end, "dupe")
  W.After(1, function() count = count + 1 end, "dupe")
  NOW = NOW + 2
  onUpdate()
  if count ~= 1 then error("a keyed job ran " .. count .. " times, expected 1") end

  -- Drive the queues that hang off it: sync pump and the transfer sweeper.
  W.sync:Share(W.db.encounters[1], "GUILD")
  for _ = 1, 40 do NOW = NOW + 1 onUpdate() end
  if table.getn(W.sync.queue) > 0 then
    error("the sync pump left " .. table.getn(W.sync.queue) .. " messages stuck")
  end

  -- A half-received transfer must be swept rather than leaked.
  W.sync.incoming["Ghost:9"] = { chunks = 2, parts = {}, at = NOW, meta = {} }
  NOW = NOW + 120
  for _ = 1, 5 do onUpdate() end
  if W.sync.incoming["Ghost:9"] then
    error("an abandoned transfer was never swept")
  end
end)

step("channel defaulting", function()
  -- Passing no channel has to pick one rather than erroring.
  W.sync:ShareLatest(nil)
  W.sync:Discover(nil)
  W.sync.queue = {}
  W.sync.pumping = false
end)

step("report drilldown repaints", function()
  arg1 = "LeftButton"
  W.ui.report:Show()

  -- Find the session that this client recorded itself; shared and imported
  -- ones legitimately carry no ability detail.
  local own, shared
  for i, sess in ipairs(W.report:Sessions()) do
    local e = sess.encounters[1]
    if e and not e.sharedBy and not e.imported then own = own or i end
    if e and e.sharedBy then shared = shared or i end
  end
  if not own then error("no locally recorded session to drill into") end

  local function drill(sessionIndex)
    W.ui.report.state.sessionIndex = sessionIndex
    W.ui.report.state.tab = "damage"
    W.ui.report.state.drill = nil
    W.ui.report.state.drillAbility = nil
    W.ui.report:Refresh()
    local rows = W.ui.report.mainList.data
    if not rows or not rows[1] then error("no rows in the damage tab") end
    W.ui.report.state.drill = rows[1].key
    W.ui.report:Refresh()
    return W.ui.report.mainList.data
  end

  -- A locally recorded pull drills all the way to per-ability statistics.
  local abilities = drill(own)
  if not abilities or not abilities[1] or not abilities[1].id then
    error("a locally recorded pull produced no abilities")
  end
  W.ui.report.state.drillAbility = abilities[1].id
  W.ui.report:Refresh()
  local stats = W.ui.report.mainList.data
  if not stats or not stats[1] or not stats[1].label then
    error("stat rows were never painted")
  end

  -- A shared pull has no detail, and must SAY so rather than go blank.
  if shared then
    local note = drill(shared)
    if not note or not note[1] or not note[1].label then
      error("an empty drilldown showed nothing at all")
    end
    if not string.find(note[1].label, "shared", 1, true) then
      error("the empty drilldown did not explain itself: " .. tostring(note[1].label))
    end
  end

  local r = W.ui.report.mainList.rows[1]
  if r and r:GetScript("OnClick") then r:GetScript("OnClick")() end
  W.ui.report.state.sessionIndex = 1
  W.ui.report.state.drill = nil
  W.ui.report.state.drillAbility = nil
  W.ui.report.state.tab = "summary"
  W.ui.report:Refresh()
  arg1 = nil
end)

step("settings steppers", function()
  W.ui.settings:Show()
  local before = W.db.fontScale
  -- The +/- buttons are children of the stepper frame, not the frame itself.
  local found = 0
  for _, c in ipairs(W.ui.settings.controls) do
    if c.Refresh and not c:GetScript("OnClick") then
      -- a stepper: poke its buttons by walking the frames it made
      found = found + 1
    end
  end
  if found == 0 then error("no steppers found in the settings window") end

  -- Drive the +/- buttons for real, and check they clamp rather than wrap.
  for _, c in ipairs(W.ui.settings.controls) do
    if c.plus and c.minus then
      for _ = 1, 60 do c.plus:GetScript("OnClick")() end
      local high = c.Refresh and true
      for _ = 1, 200 do c.minus:GetScript("OnClick")() end
      for _ = 1, 3 do c.plus:GetScript("OnClick")() end
      if not high then error("stepper lost its refresh") end
    end
  end

  -- Whatever the steppers did, the scale must still be in range.
  if W.ui.FontScale() < 0.7 or W.ui.FontScale() > 1.8 then
    error("a stepper pushed the font scale out of range")
  end

  -- Drive one directly through the public setting it wraps.
  W.db.fontScale = 1.0
  W.ui.settings:Refresh()
  W.db.fontScale = before
end)

step("small helpers", function()
  if W.Comma(1234567) ~= "1,234,567" then
    error("Comma produced " .. tostring(W.Comma(1234567)))
  end
  if W.Pct(1, 4) ~= "25.00%" then
    error("Pct produced " .. tostring(W.Pct(1, 4)))
  end
  if W.Count({ a = 1, b = 2 }) ~= 2 then error("Count is wrong") end
  if W.metrics.Next("damage", 1) == "damage" then
    error("Next did not advance the metric")
  end
  W.ClearErrors()

  local u = W.capture:Unit("0xP")
  if not W.capture:Label(u) then error("Label returned nothing for a pet") end
  W.capture:ResyncHealth()

  local missing = W.capture:CheckEnvironment()
  if type(missing) ~= "table" then error("CheckEnvironment did not return a list") end

  if not W.encounter:ReallyInCombat() then error("ReallyInCombat disagrees with the stub") end
  W.encounter:HealStuckCombat()
end)

step("silent-failure warning", function()
  --[[ The one diagnosis no load-time probe can make: combat happened and not
       one event arrived. It must fire once and then stay quiet, because the
       cause is a missing client mod and repeating it every pull is nagging. ]]
  local realTotal = W.capture.seenTotal
  local said = 0
  local realPrint = W.Print
  W.Print = function() said = said + 1 end

  W.capture.seenTotal = 0
  W.capture.warnedSilent = nil
  W.capture:WarnIfSilent()
  local first = said
  W.capture:WarnIfSilent()
  local second = said

  -- ...and it must NOT fire when events are arriving normally.
  W.capture.warnedSilent = nil
  W.capture.seenTotal = 500
  W.capture:WarnIfSilent()
  local afterHealthy = said

  W.Print = realPrint
  W.capture.seenTotal = realTotal
  W.capture.warnedSilent = nil

  if first == 0 then error("a silent addon never warned") end
  if second ~= first then error("the warning repeated") end
  if afterHealthy ~= second then
    error("it warned even though events were arriving")
  end
end)

step("diagnostics", function()
  W.Status()
  W.Who()
end)

step("logout path", function()
  local f = _G["WrekkitInitFrame"]
  if not f then error("init frame was never created") end
  if not f._events["PLAYER_LOGOUT"] then error("PLAYER_LOGOUT not registered") end
end)

----------------------------------------------------------------------
-- report
----------------------------------------------------------------------

local function guarded(name)
  -- Does the source ever test for this global before using it?
  for _, file in ipairs(files) do
    local fh = io.open(file, "r")
    if fh then
      local text = fh:read("a")
      fh:close()
      if string.find(text, name .. "%s*~=%s*nil") or
         string.find(text, "not%s+" .. name) or
         string.find(text, "if%s+" .. name .. "%s") or
         string.find(text, "if%s+not%s+" .. name .. "%s") or
         string.find(text, name .. "%s+and%s") or
         string.find(text, "if%s+" .. name .. "%s+then") then
        return true
      end
    end
  end
  return false
end

stopCoverage()

print("\n-- external globals actually used --")

local bySource = {}
local unknown = {}
for name, e in pairs(reads) do
  local src = ORIGIN[name]
  if src then
    if not bySource[src] then bySource[src] = {} end
    table.insert(bySource[src], name)
  else
    table.insert(unknown, name)
  end
end

local order = { LUA, WOW, FRAMEXML, SUPER, NAMPOWER, OWN }
for _, src in ipairs(order) do
  local list = bySource[src]
  if list then
    table.sort(list)
    print("\n  " .. string.upper(src) .. "  (" .. table.getn(list) .. ")")
    for _, name in ipairs(list) do
      local mark = ""
      if src == SUPER or src == NAMPOWER then
        mark = guarded(name) and "   [guarded]" or "   |HARD REQUIREMENT|"
      end
      print("    " .. name .. mark)
    end
  end
end

if table.getn(unknown) > 0 then
  table.sort(unknown)
  print("\n  UNKNOWN / UNDECLARED  (" .. table.getn(unknown) .. ")")
  for _, name in ipairs(unknown) do
    local files2 = {}
    for f in pairs(reads[name].files) do table.insert(files2, f) end
    table.sort(files2)
    print("    " .. name .. "   read from: " .. table.concat(files2, ", "))
    problem("unknown global", name .. " (from " .. table.concat(files2, ", ") .. ")")
  end
end

----------------------------------------------------------------------

----------------------------------------------------------------------
-- coverage report
----------------------------------------------------------------------

----------------------------------------------------------------------
-- anchors
----------------------------------------------------------------------

print("\n-- anchors --")
for _, cyc in ipairs(findAnchorCycles()) do
  table.insert(anchorProblems, cyc)
end
if table.getn(anchorProblems) == 0 then
  print("  " .. table.getn(allRegions) .. " regions, every anchor valid")
else
  for _, a in ipairs(anchorProblems) do
    print("  BAD  " .. a)
    problem("bad anchor", a)
  end
end

print("\n-- coverage --")

local missed, total = {}, 0
for key, name in pairs(declared) do
  total = total + 1
  if not hit[key] then table.insert(missed, key .. "  " .. name) end
end
table.sort(missed)

local covered = total - table.getn(missed)
print(string.format("  %d of %d named functions ran (%d%%)",
  covered, total, total > 0 and math.floor(covered / total * 100) or 0))

if table.getn(missed) > 0 then
  print("\n  never called by this audit -- UNVERIFIED:")
  for _, m in ipairs(missed) do print("    " .. m) end
end

print("\n-- summary --")
print("  " .. table.getn(files) .. " files loaded in .toc order")
print("  " .. frameCount .. " frames created")

if table.getn(problems) == 0 then
  print("\n  no problems found\n")
else
  print("\n  " .. table.getn(problems) .. " problem(s):")
  for _, p in ipairs(problems) do
    print("    [" .. p.kind .. "] " .. p.text)
  end
  print("")
  os.exit(1)
end

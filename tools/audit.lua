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
-- 1.12 has no coroutine library; a call to it must fail here as it does in-game.
coroutine = nil
-- Nor math.huge (5.1); another addon may polyfill it in-game, but not reliably.
math.huge = nil
table.getn = table.getn or function(t) return #t end
table.setn = table.setn or function() end
unpack = unpack or table.unpack

-- The client's %d is a 32-bit int; see the same block in test_engine.lua.
do
  local realFormat = string.format
  string.format = function(fmt, ...)
    local args = table.pack(...)
    if type(fmt) == "string" then
      local i = 0
      for spec in string.gmatch(fmt, "%%[-+ #0]*%d*%.?%d*[%a%%]") do
        if spec ~= "%%" then
          i = i + 1
          local conv = string.sub(spec, -1)
          local v = args[i]
          if (conv == "d" or conv == "i") and type(v) == "number"
             and (v >= 2147483648 or v < -2147483648) then
            args[i] = -2147483648
          end
        end
      end
    end
    return realFormat(fmt, table.unpack(args, 1, args.n))
  end
end

----------------------------------------------------------------------
-- where each global comes from
----------------------------------------------------------------------

local LUA      = "lua 5.0"
local WOW      = "wow 1.12"
local FRAMEXML = "blizzard ui"
local SUPER    = "SuperWoW"
local NAMPOWER = "Nampower"
local OWN      = "wrekkit"
local OPTIONAL = "other addons, if loaded"

--- source -> { name = true }
local ORIGIN = {}
local function declare(source, names)
  for name in string.gfind(names, "%S+") do ORIGIN[name] = source end
end

declare(LUA, [[
  string table math type pairs ipairs tonumber tostring pcall setmetatable
  getmetatable rawget rawset unpack next error assert select getfenv setfenv
  os io date time gcinfo collectgarbage
]])

-- UnitBuff is stock 1.12; SuperWoW extends it with the spell id, which is
-- what Wrekkit reads (C:ScanBuffs) to find buffs older than a /reload.
declare(WOW, [[
  UnitBuff GetRaidTargetIndex
  CreateFrame UIParent GetTime GetLocale GetBuildInfo GetRealZoneText
  GetRealmName IsInInstance GetNumRaidMembers GetNumPartyMembers
  GetRaidRosterInfo UnitName UnitClass UnitLevel UnitHealth UnitHealthMax UnitClassification
  UnitExists UnitIsPlayer UnitIsUnit UnitCanCooperate UnitAffectingCombat UnitIsVisible
  SetCVar GetCVar SendChatMessage SendAddonMessage GetAddOnMetadata
  GetNumSavedInstances GetSavedInstanceInfo UnitIsGhost
  GetItemInfo IsInGuild GetCursorPosition Minimap IsShiftKeyDown
  WorldFrame PlaySound UnitIsDead UnitCanAttack getglobal
  GetNumShapeshiftForms GetShapeshiftFormInfo
  GetSpellName GetSpellTexture GetSpellCooldown CastSpell CastSpellByName
  GetPlayerBuff GetPlayerBuffTexture
  TargetUnit TargetByName TargetLastTarget ClearTarget
  this event arg1 arg2 arg3 arg4 arg5 arg6 arg7 arg8 arg9
]])

declare(FRAMEXML, [[
  CooldownFrame_SetTimer ReloadUI
  DEFAULT_CHAT_FRAME GameTooltip SlashCmdList StaticPopupDialogs
  StaticPopup_Show UISpecialFrames
  UNKNOWN MouseIsOver RaidWarningFrame
]])

declare(SUPER, [[
  SpellInfo GetUnitGUID GetUnitData GetUnitField
]])

declare(NAMPOWER, [[
  WriteCustomFile ReadCustomFile CustomFileExists NAMPOWER_VERSION
]])

-- Other addons Wrekkit cooperates with when they are there, and never
-- needs: their nameplates get threat drawn on them.
declare(OPTIONAL, [[
  ShaguPlates pfUI
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
  -- Drops the frame's anchor EDGES too, as the client does. Keeping them
  -- reported a cycle for code that re-anchors: clear A, point A at C, then
  -- point B at A reads as B -> A -> B although A no longer looks at B.
  m.ClearAllPoints = function(self) self._points = {} self._anchors = nil end
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
  m.SetGradientAlpha = function() end

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
  -- Edges follow the size, so UI.FrameWidth/FrameHeight read what GetWidth would.
  m.GetLeft = function() return 300 end
  m.GetTop = function() return 600 end
  m.GetRight = function(self) return 300 + (self:GetWidth() or 0) end
  m.GetBottom = function(self) return 600 - (self:GetHeight() or 0) end
  m.GetEffectiveScale = function() return 1 end
  m.SetScale = function() end
  m.Raise = function() end
  m.SetHitRectInsets = function() end
  m.SetNormalTexture = function() end
  m.SetHighlightTexture = function() end
  m.SetPushedTexture = function() end
  m.GetParent = function(self) return self._parent end
  m.SetParent = function() end
  m.SetID = function() end
  m.GetID = function() return 0 end
  -- Nameplates: SuperWoW answers GetName(1) with the plate's unit guid.
  m.GetName = function(self, wantGuid)
    if wantGuid then return self._guid end
    return self._name
  end
  m.GetRegions = function(self) return unpack(self._regions or {}) end
  m.GetChildren = function(self) return unpack(self._kids or {}) end
  m.GetNumChildren = function(self) return table.getn(self._kids or {}) end
  m.SetStatusBarColor = function(self, r, g, b) self._bar = { r, g, b } end
  m.GetStatusBarColor = function(self)
    local c = self._bar or { 1, 0, 0 }
    return c[1], c[2], c[3]
  end

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
  if (os.getenv("WREKKIT_SKIN") or "") ~= "" then
    W.db.skin = os.getenv("WREKKIT_SKIN")
    STUB.CooldownFrame_SetTimer = function() end
    W.ui.ApplySkin()
  end
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
  W.ui.meter:WindowMenu(W.ui.meter.frame.bar)
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

step("threat meter", function()
  local T = W.threat
  local UI = W.ui

  -- A party, a boss targeted, and a nameplate for it.
  local realParty, realExists, realName = STUB.GetNumPartyMembers, STUB.UnitExists, STUB.UnitName
  STUB.GetNumPartyMembers = function() return 2 end
  WORLD["0xF00000000000ABCD"] = { name = "Onyxia", isPlayer = false, rank = "worldboss",
                                  maxHealth = 1200000, health = 1200000 }
  WORLD["target"] = WORLD["0xF00000000000ABCD"]
  STUB.UnitExists = function(u)
    if u == "target" then return 1, "0xF00000000000ABCD" end
    return realExists(u)
  end
  STUB.UnitIsDead = function() return nil end
  STUB.UnitCanAttack = function() return 1 end
  STUB.PlaySound = function(s) STUB._sound = s end
  STUB.getglobal = function(n) return rawget(_G, n) or STUB[n] end

  STUB.WorldFrame = makeFrame("Frame", "WorldFrame")
  local plate = makeFrame("Button", nil, STUB.WorldFrame)
  plate._guid = "0xF00000000000ABCD"
  plate._shown = true
  local border = plate:CreateTexture()
  border:SetTexture("Interface\\Tooltips\\Nameplate-Border")
  local nameFS = plate:CreateFontString()
  nameFS:SetText("Onyxia")
  plate._regions = { border, plate:CreateTexture(), nameFS }
  local hp = makeFrame("StatusBar", nil, plate)
  plate._kids = { hp }
  STUB.WorldFrame._kids = { makeFrame("Frame", "SomethingElse", STUB.WorldFrame), plate }

  local target = makeFrame("Frame", "TargetFrame", STUB.UIParent)
  target._shown = true

  local sent = {}
  local realSend = STUB.SendAddonMessage
  STUB.SendAddonMessage = function(prefix, msg, chan, tgt)
    table.insert(sent, prefix)
    return realSend(prefix, msg, chan, tgt)
  end

  T:Start()
  UI.threatFrames:Start()
  W.encounter:CombatStart()

  -- The poll asks the server.
  T.nextPoll = 0
  T.frame:GetScript("OnUpdate")()
  if sent[1] ~= "TWT_UDTSv4" then error("no threat request went out: " .. tostring(sent[1])) end

  -- The server answers: the auditor is a caster at 120% of the tank.
  T:OnMessage("TWTv4=Tanky:1:1000:100:1;Auditor:0:1200:120:0;Fuff:0:500:50:1;")
  local cur = T:Live()
  if not cur or not cur.me then error("reply did not land on the target") end
  if math.floor(cur.me.pull + 0.5) ~= 92 then
    error("pull % should be 120/130 = 92, got " .. tostring(cur.me.pull))
  end
  if cur.rows[1].name ~= "Auditor" then error("rows are not sorted by threat") end
  if not STUB._sound then error("crossing the danger line made no sound") end

  -- Every place it is drawn.
  for _, mode in ipairs({ "window", "docked", "meter", "off", "window" }) do
    UI.threat:SetDisplay(mode)
    UI.threatFrames.lastTick = nil
    UI.threatFrames.frame:GetScript("OnUpdate")()
  end
  UI.threat:Refresh()
  UI.meter:SetMetric("threat")
  UI.meter:Refresh()
  UI.meter:SetMetric("damage")

  UI.threatFrames:Update()
  if not plate.wrekThreat or plate.wrekThreat.text:GetText() ~= "92%" then
    error("the nameplate does not show 92%: " ..
      tostring(plate.wrekThreat and plate.wrekThreat.text:GetText()))
  end
  if not UI.threatFrames.ind or not UI.threatFrames.ind:IsShown() then
    error("the target frame indicator is not shown")
  end
  T:Settings().plateColor = "bar"
  UI.threatFrames:Update()
  T:Settings().plateColor = "text"
  UI.threatFrames:Update()

  -- The tank's view: the runner-up's distance to pulling, not "tank".
  T:Settings().tankMode = "on"
  local alerts = {}
  local realAlert = T.Alert
  T.Alert = function(self, text, level)
    table.insert(alerts, text)
    return realAlert(self, text, level)
  end
  T:OnMessage("TWTv4=Auditor:1:3000:100:1;Fuff:0:2900:97:1;" ..
              "#TMTv1=Onyxia:43981:Fuff:97;Whelp:12:Elfpriest:80;Drake:13:Fuff:40;")
  if not T.tankMobs[43981] then error("tank mode section was not read") end
  local _, _, _, text = T:Display(T:Live())
  if text ~= "88%" then error("a tank should see the runner-up at 97/110 = 88%, got " .. tostring(text)) end
  local closing = false
  for _, a in ipairs(alerts) do
    if string.find(a, "Fuff at 88%", 1, true) then closing = true end
  end
  if not closing then error("no alert that Fuff is closing in: " .. table.concat(alerts, " | ")) end

  -- Another mob's plate, named only by tank mode's low 16 bits (0x000C).
  local _, _, _, whelp = T:ForMob("0xF00000000000000C", "0xF00000000000000C")
  if whelp ~= "73%" then error("tank mode did not reach another mob's plate: " .. tostring(whelp)) end
  UI.threat:Refresh()
  local mobRows = 0
  for _, it in ipairs(UI.threat.list.data) do
    if it.mob then mobRows = mobRows + 1 end
  end
  if mobRows ~= 3 then error("the window lists " .. mobRows .. " held mobs, not 3") end

  -- The Drake dies, the Whelp turns away: one LOST, not two.
  T:OnUnitDied("0xF00000000000000D")
  alerts = {}
  T:OnMessage("TWTv4=Auditor:1:3100:100:1;Fuff:0:2950:95:1;#TMTv1=Onyxia:43981:Fuff:95;")
  if not T.lost[12] then error("the Whelp turning away was not noticed") end
  if T.lost[13] then error("the Drake died; that is not lost aggro") end
  local _, _, _, lostText = T:ForMob("0xF00000000000000C", "0xF00000000000000C")
  if lostText ~= "LOST" then error("the lost mob's plate does not say LOST") end

  -- Then Onyxia herself turns, on the target table.
  T:OnMessage("TWTv4=Fuff:1:3400:100:1;Auditor:0:3000:88:1;")
  local lostBoss = false
  for _, a in ipairs(alerts) do
    if string.find(a, "LOST AGGRO: Onyxia", 1, true) then lostBoss = true end
  end
  if not lostBoss then error("losing the target was not announced: " .. table.concat(alerts, " | ")) end
  T.Alert = realAlert

  -- Not a tank, and it turns on you.
  T:Settings().tankMode = "off"
  T.fired, T.heldKey, T.lost = {}, nil, {}
  T:OnMessage("TWTv4=Fuff:1:3400:100:1;Auditor:0:3000:88:1;")
  T:OnMessage("TWTv4=Auditor:1:3800:100:0;Fuff:0:3400:89:1;")
  local _, _, _, aggro = T:Display(T:Live())
  if aggro ~= "AGGRO" then error("a non-tank holding aggro should read AGGRO") end
  T:Settings().tankMode = "auto"

  -- A ShaguPlates / pfUI plate: their own health bar, their colour cache.
  local splate = makeFrame("Button", nil, STUB.WorldFrame)
  splate._guid = "0xF00000000000ABCD"
  splate._shown = true
  local sborder = splate:CreateTexture()
  sborder:SetTexture("Interface\\Tooltips\\Nameplate-Border")
  splate._regions = { sborder }
  splate._kids = { makeFrame("StatusBar", nil, splate) }
  local np = makeFrame("Button", "pfNamePlate1", splate)
  np.health = makeFrame("StatusBar", nil, np)
  np.health:SetStatusBarColor(0.8, 0.1, 0.1)
  np.cache = { r = 0.8, g = 0.1, b = 0.1 }
  splate.nameplate = np
  table.insert(STUB.WorldFrame._kids, splate)
  T:Settings().plateColor = "bar"
  T:OnMessage("TWTv4=Fuff:1:3400:100:1;Auditor:0:3000:60:0;")
  UI.threatFrames:Update()
  local r = np.health:GetStatusBarColor()
  if r == 0.8 then error("ShaguPlates' health bar was not tinted") end
  if splate.wrekThreat == nil then error("no threat text on the ShaguPlates plate") end
  T:Settings().plateColor = "text"
  UI.threatFrames:Update()
  if np.cache.r ~= nil or not np.eventcache then
    error("the tint was not handed back to ShaguPlates")
  end
  T:Settings().plateStyle = "stock"
  T:Settings().plateColor = "bar"
  UI.threatFrames:Update()
  T:Settings().plateStyle = "auto"
  T:Settings().plateColor = "text"
  UI.threatFrames:Update()
  UI.threatFrames:PlateAddon()

  -- Dragging, docked and not, and a row's tooltip.
  UI.threat:StartDrag() UI.threat:StopDrag()
  UI.threat:SetDisplay("docked")
  UI.threat:StartDrag() UI.threat:StopDrag()
  UI.threat:SetDisplay("window")
  UI.threat:Refresh()
  local row = UI.threat.list.rows[1]
  if row and row.tip then row:tip() end

  -- Menus, the settings tab, the preview, the end of the fight.
  UI.threat:Menu(UI.threat.frame.bar)
  UI.CloseMenu()
  UI.settings:Show("threat")
  UI.settings:Refresh()
  UI.settings:SetTab("meter")
  T:Settings().tankMode = "on"
  T:Demo(5)
  UI.threat:Refresh()
  T:StopDemo()
  T:Settings().tankMode = "off"
  T:Demo(5)
  UI.threatFrames:Update()
  NOW = NOW + 6
  T.nextPoll = 0
  T.frame:GetScript("OnUpdate")()
  UI.threatFrames.frame:GetScript("OnUpdate")()
  T:OnTargetChanged()
  W.encounter:CombatEnd()
  T:OnCombatEnd()
  UI.threatFrames:Update()
  T:StatusLine()

  local run = SlashCmdList["WREKKIT"]
  for _, c in ipairs({ "threat", "threat", "threat docked", "threat meter", "threat tank",
                       "threat tank", "threat test", "threat move", "threat move", "threat resetpos",
                       "opacity meter 60", "opacity threat 50", "opacity report 70", "opacity 100",
                       "opacity threat 100", "opacity report 100", "opacity nonsense", "threat config", "threat disable",
                       "threat enable", "threat bogus", "mode threat", "mode damage",
                       "threat window" }) do
    run(c)
  end

  -- Flashing: on above the limit, off below it, for both roles.
  if T.demoUntil then T:StopDemo() end
  T:Settings().tankMode = "off"
  T:Settings().flashScreen = true
  T:OnMessage("TWTv4=Fuff:1:3400:100:1;Auditor:0:3000:96:1;")   -- 87% to pull
  if not T:Alarm() then error("87% to pull should flash at the default 85") end
  UI.threatFrames:UpdateAlarm()
  UI.threatFrames:UpdateWarning()
  T:Settings().flashAt = 95
  if T:Alarm() then error("87% should not flash with the limit at 95") end
  T:Settings().flashAt = 85
  T:Settings().tankMode = "on"
  T:OnMessage("TWTv4=Auditor:1:3400:100:1;Fuff:0:3300:97:1;")    -- runner 88%
  if T:Alarm() then error("a runner-up at 88% should not flash a tank at 90") end
  T:OnMessage("TWTv4=Auditor:1:3400:100:1;Fuff:0:3400:100:1;")   -- runner 91%
  if not T:Alarm() then error("a runner-up at 91% should flash a tank") end
  UI.threatFrames:UpdateAlarm()
  UI.threatFrames:UpdateWarning()
  T:Settings().flash = false
  if T:Alarm() then error("switched off, nothing should flash") end
  UI.threatFrames:UpdateAlarm()
  T:Settings().flash = true
  T:Settings().flashScreen = false
  T:Settings().tankMode = "off"
  T.heldKey, T.fired = nil, {}

  -- Mobs nobody targeted: one goes loose on the priest, seen by its plate.
  T:Settings().tankMode = "on"
  local whelpGuid = "0xF00000000000BEEF"
  WORLD[whelpGuid] = { name = "Whelp", isPlayer = false, maxHealth = 5000, health = 5000 }
  WORLD[whelpGuid .. "target"] = WORLD["0xB"]
  W.capture.groupMembers["Elfpriest"] = true
  local wplate = makeFrame("Button", nil, STUB.WorldFrame)
  wplate._guid = whelpGuid
  wplate._shown = true
  local wborder = wplate:CreateTexture()
  wborder:SetTexture("Interface\\Tooltips\\Nameplate-Border")
  local wname = wplate:CreateFontString()
  wname:SetText("Whelp")
  wplate._regions = { wborder, wplate:CreateTexture(), wname }
  wplate._kids = { makeFrame("StatusBar", nil, wplate) }
  table.insert(STUB.WorldFrame._kids, wplate)
  alerts = {}
  T.Alert = function(self, text, level) table.insert(alerts, text) end
  UI.threatFrames:UpdatePlates()
  if T:CountWatch("loose") ~= 0 then error("a mob counted loose before it stayed loose") end
  NOW = NOW + 1.2
  UI.threatFrames:UpdatePlates()
  if T:CountWatch("loose") ~= 1 then error("the Whelp on the priest is not counted loose") end
  if wplate.wrekThreat.text:GetText() ~= "LOOSE" then error("its plate does not say LOOSE") end
  if not string.find(table.concat(alerts, "|"), "LOOSE: Whelp on Elfpriest", 1, true) then
    error("no LOOSE alert: " .. table.concat(alerts, " | "))
  end
  T.tankMobs[1] = { creature = "Drake", name = "Fuff", perc = 99, pull = 90, at = NOW }
  T.tankMobs[2] = { creature = "Drake", name = "Fuff", perc = 40, pull = 36, at = NOW }
  local summary = T:MobSummary()
  if not (summary and string.find(summary, "2 held", 1, true) and string.find(summary, "1 loose", 1, true)) then
    error("summary reads: " .. tostring(summary))
  end
  if not T:Alarm() then error("a loose mob should flash") end

  -- The taunt popup: the loose Whelp is offered, clicking taunts it.
  local book = {
    { "Heroic Strike", "Interface\\Icons\\Ability_Rogue_Ambush" },
    { "Taunt", "Interface\\Icons\\Spell_Nature_Reincarnation" },
    { "Mocking Blow", "Interface\\Icons\\Ability_Warrior_PunishingBlow" },
  }
  local cooldown = {}
  local casts = {}
  STUB.GetSpellName = function(i) return book[i] and book[i][1] end
  STUB.GetSpellTexture = function(i) return book[i] and book[i][2] end
  STUB.GetSpellCooldown = function(i) local c = cooldown[i] return c and NOW or 0, c or 0, 1 end
  STUB.CastSpellByName = function(name, unit) table.insert(casts, name .. "@" .. tostring(unit)) end
  STUB.CastSpell = function(i) table.insert(casts, "book" .. i) end
  STUB.TargetUnit = function(u) table.insert(casts, "target:" .. tostring(u)) end
  STUB.TargetByName = function(n) table.insert(casts, "name:" .. tostring(n)) end
  T.tauntCache = nil
  local queue = T:Taunts()
  if table.getn(queue) ~= 1 or queue[1].guid ~= whelpGuid then error("the loose Whelp was not offered to taunt") end
  UI.taunt:Update()
  if not UI.taunt.frame:IsShown() then error("the taunt popup did not appear") end
  if UI.taunt.rows[1].label:GetText() ~= "Taunt Whelp" then error("popup reads " .. tostring(UI.taunt.rows[1].label:GetText())) end
  arg1 = "LeftButton"
  UI.taunt.rows[1]:GetScript("OnClick")()
  if casts[1] ~= "Taunt@" .. whelpGuid then error("clicking did not taunt the Whelp by guid: " .. tostring(casts[1])) end
  if table.getn(T:Taunts()) ~= 0 then error("a taunted mob stayed in the popup") end
  UI.taunt:Update()
  if UI.taunt.frame:IsShown() then error("the popup stayed up with nothing to taunt") end

  -- Taunt on cooldown: Mocking Blow instead. Neither ready: told so.
  cooldown[2] = 8
  T:QueueTaunt(whelpGuid, "Whelp", "Elfpriest", "loose")
  T:TauntNext()
  if casts[2] ~= "Mocking Blow@" .. whelpGuid then error("no fallback to Mocking Blow: " .. tostring(casts[2])) end
  cooldown[3] = 4
  T:QueueTaunt(whelpGuid, "Whelp", "Elfpriest", "loose")
  UI.taunt:Update()
  if T:TauntNext() then error("taunted with everything on cooldown") end
  cooldown = {}

  -- Keeping the target off: the mob is targeted, then the spell cast.
  T:Settings().tauntKeepTarget = false
  casts = {}
  Wrekkit_TauntBinding()
  if casts[1] ~= "target:" .. whelpGuid or casts[2] ~= "book2" then
    error("retarget path: " .. table.concat(casts, ", "))
  end
  T:Settings().tauntKeepTarget = true

  -- Right-click dismisses; the slash command with nothing queued says so.
  T:QueueTaunt(whelpGuid, "Whelp", "Elfpriest", "loose")
  UI.taunt:Update()
  arg1 = "RightButton"
  UI.taunt.rows[1]:GetScript("OnClick")()
  if table.getn(T:Taunts()) ~= 0 then error("right-click did not dismiss") end
  SlashCmdList["WREKKIT"]("taunt")

  -- Every tank class has its own taunts; a typed list overrides them.
  local realClassT = STUB.UnitClass
  local function taunts(class, spells, custom, aoe)
    STUB.UnitClass = function(u) return class, class end
    book = spells
    T:Settings().tauntSpell = custom or ""
    T:Settings().tauntAoE = aoe or false
    T.tauntCache = nil
    local out = {}
    for _, sp in ipairs(T:TauntSpells()) do table.insert(out, sp.name) end
    return table.concat(out, ",")
  end
  local got = taunts("WARRIOR", {
    { "Mocking Blow", "Interface\\Icons\\Ability_Warrior_PunishingBlow" },
    { "Challenging Shout", "Interface\\Icons\\Ability_BullRush" },
    { "Taunt", "interface\\icons\\spell_nature_reincarnation" } })
  if got ~= "Taunt,Mocking Blow" then error("warrior taunts: " .. got) end
  got = taunts("WARRIOR", book, nil, true)
  if got ~= "Taunt,Mocking Blow,Challenging Shout" then error("warrior with AoE: " .. got) end
  got = taunts("DRUID", { { "Growl", "Interface\\Icons\\Ability_Physical_Taunt" },
                          { "Challenging Roar", "Interface\\Icons\\Ability_Druid_ChallangingRoar" } })
  if got ~= "Growl" then error("druid taunts: " .. got) end
  got = taunts("PALADIN", { { "Seal of Righteousness", "x" }, { "Hand of Reckoning", "Interface\\Icons\\Spell_Whatever" } })
  if got ~= "Hand of Reckoning" then error("paladin taunts: " .. got) end
  got = taunts("SHAMAN", { { "Earthshaker Slam", "x" } })
  if got ~= "Earthshaker Slam" then error("shaman taunts: " .. got) end
  got = taunts("PALADIN", { { "Hand of Reckoning", "x" }, { "Judgement", "y" } }, " judgement , hand of reckoning")
  if got ~= "Judgement,Hand of Reckoning" then error("typed list, in its own order: " .. got) end
  got = taunts("MAGE", { { "Fireball", "x" } })
  if got ~= "" then error("a mage has no taunt, found: " .. got) end
  T:ExplainRole()
  STUB.UnitClass = realClassT
  T:Settings().tauntSpell, T:Settings().tauntAoE = "", false
  T.tauntCache = nil

  -- A mob lost from tank mode's list is offered by its full guid.
  T.guidByLow[0xBEEF] = whelpGuid
  T:LostAggro(0xBEEF, "Whelp", nil, NOW)
  if not T:Taunts()[1] or T:Taunts()[1].guid ~= whelpGuid then error("a lost mob was not offered with its guid") end
  UI.taunt:Update()
  UI.taunt:SavePosition()
  if T:Settings().tauntX == nil then error("the popup's place was not saved") end
  UI.taunt:RestorePosition()
  T.taunts, T.lost = {}, {}
  UI.threat:Refresh()
  local looseRows = 0
  for _, it in ipairs(UI.threat.list.data) do if it.loose then looseRows = looseRows + 1 end end
  if looseRows ~= 1 then error("the window does not list the loose mob") end
  UI.threatFrames:UpdateIndicator()

  -- Mob frames: two drakes on you, the Whelp loose on the priest.
  local drakes = { "0xF00000000000D001", "0xF00000000000D002" }
  local realIsUnitMF = STUB.UnitIsUnit
  STUB.UnitIsUnit = function(a, b)
    return b == "player" and (a == drakes[1] .. "target" or a == drakes[2] .. "target")
  end
  for i, g in ipairs(drakes) do
    WORLD[g] = { name = "Drake " .. i, isPlayer = false, maxHealth = 8000, health = 4000 * i }
    WORLD[g .. "target"] = { name = "Auditor", isPlayer = true, class = "WARRIOR" }
    local dp = makeFrame("Button", nil, STUB.WorldFrame)
    dp._guid = g
    dp._shown = true
    local db = dp:CreateTexture()
    db:SetTexture("Interface\\Tooltips\\Nameplate-Border")
    dp._regions = { db }
    dp._kids = { makeFrame("StatusBar", nil, dp) }
    table.insert(STUB.WorldFrame._kids, dp)
  end
  UI.threatFrames:UpdatePlates()
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  if not UI.mobs.frame or not UI.mobs.frame:IsShown() then error("mob frames did not appear for 3 mobs") end
  local onPriest, onMe = 0, 0
  for _, row in ipairs(UI.mobs.rows) do
    if row:IsShown() and row.mob then
      local who = row.who:GetText() or ""
      if string.find(who, "Elfpriest", 1, true) then
        onPriest = onPriest + 1
        if not row.trouble then error("the loose Whelp's row is not highlighted") end
      elseif string.find(who, "you", 1, true) then
        onMe = onMe + 1
      end
    end
  end
  if onPriest ~= 1 or onMe ~= 2 then
    error("mob frames show " .. onMe .. " on you and " .. onPriest .. " on the priest")
  end
  -- Raid markers: the skull on Drake 1 shows on its row, nothing on the rest.
  local markNow = NOW
  local realMark = STUB.GetRaidTargetIndex
  STUB.GetRaidTargetIndex = function(u) if u == drakes[1] then return 8 end end
  NOW = NOW + 0.1
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  local skulls, plain = 0, 0
  for _, row in ipairs(UI.mobs.rows) do
    if row:IsShown() and row.mob then
      if row.mob.guid == drakes[1] then
        if row.markShown ~= 8 or not row.mark:IsShown() then error("Drake 1's skull is not on its row") end
        skulls = skulls + 1
      elseif row.mark:IsShown() then
        error("an unmarked mob shows a marker: " .. tostring(row.mob.name))
      else
        plain = plain + 1
      end
    end
  end
  -- A mob name with spaces stays on one line (it wrapped over the next row).
  for _, row in ipairs(UI.mobs.rows) do
    if row:IsShown() and row.mob and (row.name:GetHeight() or 0) <= 0 then
      error("a mob row's name has no one-line height")
    end
  end
  if skulls ~= 1 or plain < 2 then error("markers on " .. skulls .. " rows, plain " .. plain) end
  -- Taken off again, it goes.
  STUB.GetRaidTargetIndex = realMark
  NOW = NOW + 0.1
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  for _, row in ipairs(UI.mobs.rows) do
    if row:IsShown() and row.mark:IsShown() then error("a marker stayed after it was cleared") end
  end
  NOW = markNow
  -- The width: set it, and the frame and every row's name column follow;
  -- outside its limits it is held to them.
  do
    local MF = UI.mobs
    local before = T:Settings().mobFramesWidth
    MF:SetWidth(300)
    if math.floor(MF.frame:GetWidth() + 0.5) ~= 300 then error("the mob frames are " .. MF.frame:GetWidth() .. " wide, not 300") end
    for _, row in ipairs(MF.rows) do
      if row.nameW ~= MF:NameWidth() then error("a row's name column did not follow the width") end
    end
    if MF:NameWidth() <= 83 then error("a wider frame gave the name no more room") end
    -- 60/40: the mob and its % on the left, the player at the right edge.
    local split = MF:Columns(300)
    local function at(frame, point, target, rel, x)
      for _, p in ipairs(frame._points or {}) do
        if p[1] == point and p[2] == target and p[3] == rel and p[4] == x then return true end
      end
      return false
    end
    local r1 = MF.rows[1]
    if split ~= math.floor((300 - 4 - 2 * (MF.pad or 0)) * 0.6) then error("the split is not at 60%") end
    if not at(r1.who, "RIGHT", r1, "RIGHT", -4) then error("the player is not at the right edge") end
    if not at(r1.pct, "RIGHT", r1, "LEFT", split - 4) then error("the mob's % is not at the end of its 60%") end
    if not at(r1.whoBtn, "TOPLEFT", r1, "TOPLEFT", split) then error("the player button does not start at 60%") end
    MF:SetWidth(1000)
    if T:Settings().mobFramesWidth ~= 420 then error("the width is not held to 420") end
    MF:SetWidth(10)
    if T:Settings().mobFramesWidth ~= 160 then error("the width is not held to 160") end
    -- The grip: only while placing, and dragging it saves the width.
    UI.threatFrames.moving = true
    MF.lastUpdate = nil
    MF:Update()
    if not MF.grip:IsShown() then error("no width grip while placing the frames") end
    -- Mid-drag the frames keep redrawing (the samples pulse). A redraw must
    -- not put the saved width back under the cursor.
    MF.grip:GetScript("OnDragStart")()
    MF.frame:SetWidth(340)
    NOW = NOW + 0.3
    MF.lastUpdate = nil
    MF:Update()
    if math.floor(MF.frame:GetWidth() + 0.5) ~= 340 then
      error("a redraw mid-drag snapped the frames back to " .. MF.frame:GetWidth())
    end
    for _, row in ipairs(MF.rows) do
      local _, liveName = MF:Columns(340)
      if row.nameW ~= liveName then error("mid-drag, a row's name column did not follow") end
    end
    MF.grip:GetScript("OnDragStop")()
    if T:Settings().mobFramesWidth ~= 340 then error("letting go of the grip did not save the width") end
    if MF.sizing then error("still sizing after letting go") end
    UI.threatFrames.moving = nil
    MF.lastUpdate = nil
    MF:Update()
    if MF.grip:IsShown() then error("the width grip stayed after placing") end
    MF:SetWidth(before)
  end
  -- Clicking the player a mob is hitting: the spell set for that click, at
  -- them; with no spell, they are targeted. Drake 1 is on you.
  do
    local ts = T:Settings()
    local real = { cast = STUB.CastSpellByName, target = STUB.TargetUnit, last = STUB.TargetLastTarget,
                   shift = STUB.IsShiftKeyDown, info = STUB.SpellInfo }
    local did = {}
    STUB.CastSpellByName = function(spell, unit) table.insert(did, "cast:" .. spell .. "@" .. tostring(unit)) end
    STUB.TargetUnit = function(u) table.insert(did, "target:" .. tostring(u)) end
    STUB.TargetLastTarget = function() table.insert(did, "back") end
    ts.mobWhoLeft, ts.mobWhoRight, ts.mobWhoShift = "Flash Heal", "", "Power Word: Shield"
    local row
    for _, r in ipairs(UI.mobs.rows) do
      if r:IsShown() and r.mob and r.mob.guid == drakes[1] then row = r end
    end
    if not row or not row.whoBtn then error("no player button on Drake 1's row") end
    local click = row.whoBtn:GetScript("OnClick")
    local function press(button, shift)
      did = {}
      STUB.IsShiftKeyDown = function() return shift end
      arg1 = button
      click()
      arg1 = nil
      return table.concat(did, " ")
    end
    local ok, err = pcall(function()
      -- With SuperWoW: straight at you, your target untouched.
      local got = press("LeftButton")
      if got ~= "cast:Flash Heal@player" then error("click cast " .. got) end
      got = press("RightButton")
      if got ~= "target:player" then error("right-click with no spell did " .. got) end
      got = press("LeftButton", true)
      if got ~= "cast:Power Word: Shield@player" then error("shift-click cast " .. got) end
      -- Without SuperWoW: target them, cast, and the old target back.
      STUB.SpellInfo = nil
      got = press("LeftButton")
      if got ~= "target:player cast:Flash Heal@nil back" then error("without SuperWoW the click did " .. got) end
    end)
    STUB.CastSpellByName, STUB.TargetUnit, STUB.TargetLastTarget = real.cast, real.target, real.last
    STUB.IsShiftKeyDown, STUB.SpellInfo = real.shift, real.info
    ts.mobWhoLeft, ts.mobWhoRight, ts.mobWhoShift = "", "", ""
    if not ok then error(err) end
  end
  -- Your target is marked, and every row with a reading shows its %.
  local realExistsMF = STUB.UnitExists
  STUB.UnitExists = function(u)
    if u == "target" then return 1, drakes[1] end
    return realExistsMF(u)
  end
  NOW = NOW + 0.3
  T.tankMobs[0xD002] = { creature = "Drake 2", name = "Fuff", perc = 88, pull = 80, at = NOW }
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  local marked, drake2pct = 0, nil
  for _, row in ipairs(UI.mobs.rows) do
    if row:IsShown() and row.mob then
      if row.selected then
        marked = marked + 1
        if row.mob.guid ~= drakes[1] then error("the wrong row is marked as the target") end
      end
      if row.mob.guid == drakes[2] then drake2pct = row.pct:GetText() end
    end
  end
  if marked ~= 1 then error(marked .. " rows marked as the target, not 1") end
  if drake2pct ~= "88%" then error("a held mob's row shows " .. tostring(drake2pct) .. ", not its 88% share") end
  -- Collapsed, the target keeps its row even when nothing is wrong with it.
  T:Settings().mobFramesCollapse = "always"
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  local targetRow = false
  for _, row in ipairs(UI.mobs.rows) do
    if row:IsShown() and row.mob and row.mob.guid == drakes[1] then targetRow = true end
  end
  if not targetRow then error("collapsed, the targeted mob lost its row") end
  -- Collapsed, a held mob with someone at 80% of your threat comes back out
  -- -- without blinking, which is for real trouble -- and goes back below it.
  local function drake2Row()
    for _, row in ipairs(UI.mobs.rows) do
      if row:IsShown() and row.mob and row.mob.guid == drakes[2] then return row end
    end
  end
  local r2 = drake2Row()
  if not r2 then error("a mob at 88% of your threat stayed collapsed") end
  if r2.trouble then error("a mob at 88% share but 80% to pull should not blink") end
  NOW = NOW + 0.3
  T.tankMobs[0xD002] = { creature = "Drake 2", name = "Fuff", perc = 70, pull = 64, at = NOW }
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  if drake2Row() then error("a mob at 70% of your threat came out of the summary") end
  T:Settings().mobFramesExpandAt = 65
  NOW = NOW + 0.3
  T.tankMobs[0xD002].at = NOW
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  if not drake2Row() then error("with the line at 65%, 70% should show") end
  T:Settings().mobFramesExpandAt = 80
  T:Settings().mobFramesCollapse = "auto"
  STUB.UnitExists = realExistsMF
  T.tankMobs[0xD002] = nil

  -- Collapsed: one line for the two on you, a row only for the Whelp.
  -- Nothing targeted here: a target would keep a row of its own.
  local realExistsC = STUB.UnitExists
  STUB.UnitExists = function(u)
    if u == "target" then return nil end
    return realExistsC(u)
  end
  local function shownRows()
    local n = 0
    for _, r in ipairs(UI.mobs.rows) do if r:IsShown() then n = n + 1 end end
    return n
  end
  T:Settings().mobFramesCollapse = "always"
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  if not UI.mobs.rows[1].summary then error("collapsed, the first row should be the summary") end
  if not string.find(UI.mobs.rows[1].name:GetText(), "2 on you", 1, true)
     or not string.find(UI.mobs.rows[1].name:GetText(), "1 elsewhere", 1, true) then
    error("summary reads " .. tostring(UI.mobs.rows[1].name:GetText()))
  end
  if shownRows() ~= 2 or not UI.mobs.rows[2].trouble then
    error("collapsed should show the summary and the loose Whelp only, shows " .. shownRows())
  end
  -- Clicking the summary expands for this fight; again collapses.
  arg1 = "LeftButton"
  UI.mobs.rows[1]:GetScript("OnClick")()
  -- Four: the boss from earlier is in the fight too, on nobody.
  if shownRows() ~= 4 then error("expanding should show all 4, shows " .. shownRows()) end
  UI.mobs:ToggleCollapse()
  -- The Whelp comes back: everything fits on the one line.
  WORLD[whelpGuid .. "target"] = { name = "Auditor", isPlayer = true, class = "WARRIOR" }
  local realIsUnitC = STUB.UnitIsUnit
  STUB.UnitIsUnit = function(a, b)
    return b == "player" and (a == drakes[1] .. "target" or a == drakes[2] .. "target"
      or a == whelpGuid .. "target")
  end
  T.watch = {}
  NOW = NOW + 0.3
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  local line = UI.mobs.rows[1].name:GetText()
  if shownRows() ~= 1 or not string.find(line, "3 on you", 1, true)
     or not string.find(line, "1 elsewhere", 1, true) then
    error("with nothing in trouble it should be the one line: " ..
      tostring(UI.mobs.rows[1].name:GetText()) .. " / " .. shownRows())
  end
  STUB.UnitIsUnit = realIsUnitC
  WORLD[whelpGuid .. "target"] = WORLD["0xB"]
  T:Settings().mobFramesCollapse = "never"
  STUB.UnitExists = realExistsC
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()

  -- Not tanking, with the frames on for everyone and collapsed: a tank's
  -- relay says you are about to pull Drake 2, so it gets a red row of its
  -- own, as a slipping mob does for a tank.
  do
    local ts = T:Settings()
    local was = { mode = ts.tankMode, forWho = ts.mobFramesFor, collapse = ts.mobFramesCollapse }
    ts.tankMode, ts.mobFramesFor, ts.mobFramesCollapse = "off", "everyone", "always"
    T.roleAt = nil
    local saveCur = T.current
    -- Drake 2 on the tank, not on you: only the relay can make it red.
    local saveIsUnit, saveTarget = STUB.UnitIsUnit, WORLD[drakes[2] .. "target"]
    STUB.UnitIsUnit = function() return false end
    WORLD[drakes[2] .. "target"] = { name = "Tanky", isPlayer = true, class = "WARRIOR" }
    T.current = nil
    T.relayMobs[T.LowGuid(drakes[2])] = { runner = "Auditor", perc = 105, pull = 105 / 1.1,
      at = NOW + 0.1, creature = "Drake 2", from = "Tanky" }
    NOW = NOW + 0.1
    UI.mobs.lastUpdate = nil
    UI.mobs:Update()
    -- Read now: the redraw below repaints the rows.
    local found, red = false, false
    for _, row in ipairs(UI.mobs.rows) do
      if row:IsShown() and row.mob and row.mob.guid == drakes[2] then found, red = true, row.trouble end
    end
    T.relayMobs, T.current = {}, saveCur
    STUB.UnitIsUnit, WORLD[drakes[2] .. "target"] = saveIsUnit, saveTarget
    ts.tankMode, ts.mobFramesFor, ts.mobFramesCollapse = was.mode, was.forWho, was.collapse
    T.roleAt = nil
    -- Drawn again under the settings put back: the next check clicks row 1.
    UI.mobs.lastUpdate = nil
    UI.mobs:Update()
    if not found then error("as DPS, the mob you are about to pull has no row of its own") end
    if not red then error("as DPS, the mob you are past your line on is not red") end
  end
  local casts = {}
  STUB.TargetUnit = function(u) table.insert(casts, "target:" .. u) end
  arg1 = "LeftButton"
  UI.mobs.rows[1]:GetScript("OnClick")()
  if not casts[1] then error("clicking a mob frame did not target it") end
  arg1 = "RightButton"
  UI.mobs.rows[1]:GetScript("OnClick")()
  T:Settings().mobFramesFor = "tank"
  T:Settings().tankMode = "off"
  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  if UI.mobs.frame:IsShown() then error("mob frames shown to a non-tank set to tank-only") end
  T:Settings().tankMode = "on"
  UI.mobs:SavePosition()
  UI.mobs:RestorePosition()
  UI.mobs:Reset()
  STUB.UnitIsUnit = realIsUnitMF
  for _, g in ipairs(drakes) do WORLD[g] = nil WORLD[g .. "target"] = nil end

  -- Not tanking, a mob nobody targeted turns on you.
  T:Settings().tankMode = "off"
  T.watch, T.tankMobs = {}, {}
  local realIsUnit = STUB.UnitIsUnit
  STUB.UnitIsUnit = function(a, b) return a == whelpGuid .. "target" and b == "player" end
  alerts = {}
  UI.threatFrames:UpdatePlates()
  NOW = NOW + 1.2
  UI.threatFrames:UpdatePlates()
  if wplate.wrekThreat.text:GetText() ~= "AGGRO" then error("a mob on you should say AGGRO") end
  if not string.find(table.concat(alerts, "|"), "AGGRO! Whelp is on you", 1, true) then
    error("no AGGRO alert: " .. table.concat(alerts, " | "))
  end
  STUB.UnitIsUnit = realIsUnit
  WORLD[whelpGuid .. "target"] = nil
  T.Alert = realAlert
  T.watch = {}
  wplate._shown = false

  -- The target-frame %: every style, dragged, saved, reset.
  local TFm = UI.threatFrames
  T:OnMessage("TWTv4=Fuff:1:3400:100:1;Auditor:0:3000:88:1;")
  for _, style in ipairs({ "number", "badge", "clean" }) do
    T:Settings().frameStyle = style
    TFm:UpdateIndicator()
  end
  TFm:SetMoving(true)
  TFm.ind:GetScript("OnDragStart")()
  TFm.ind:GetScript("OnDragStop")()
  if T:Settings().frameX == nil then error("dragging the % did not save where it went") end
  TFm.ind:GetScript("OnClick")()
  if TFm.moving then error("right-click did not lock the %") end
  TFm:ResetPlacement()
  if T:Settings().frameX ~= nil then error("reset did not forget the dragged place") end

  T:ResetSettings()
  if T:Settings().tankMode ~= "auto" then error("defaults did not come back") end

  STUB.GetNumPartyMembers, STUB.UnitExists, STUB.UnitName = realParty, realExists, realName
  STUB.SendAddonMessage = realSend
  WORLD["target"] = nil
end)

step("tank detection: Righteous Fury, every way a client may report it", function()
  local T = W.threat
  local realClass, realBuff = STUB.UnitClass, STUB.UnitBuff
  STUB.UnitClass = function(u) return "Paladin", "PALADIN" end
  local function with(buffs)
    STUB.UnitBuff = function(u, i) local b = buffs[i] if b then return b[1], 1, b[2] end end
    T.roleAt = nil
    return T:DetectTank()
  end
  T:Settings().tankMode = "auto"
  if with({ { "Interface\\Icons\\Spell_Holy_SealOfFury" } }) ~= true then error("stock icon path not seen") end
  if with({ { "interface\\icons\\spell_holy_sealoffury" } }) ~= true then error("lower-case icon path not seen") end
  if with({ { "Interface\\Icons\\Something_Else", 25780 } }) ~= true then error("spell id not seen") end
  if with({ { "Interface\\Icons\\Spell_Holy_Devotionaura" } }) ~= false then error("an aura counted as Fury") end
  if with({}) ~= false then error("no buffs counted as Fury") end
  with({ { "Interface\\Icons\\Spell_Holy_SealOfFury" } })
  T:ExplainRole()
  SlashCmdList["WREKKIT"]("threat role")
  STUB.UnitClass, STUB.UnitBuff = realClass, realBuff
  T.roleAt = nil
end)

step("without SuperWoW: mobs found through the group's targets", function()
  local T, UI = W.threat, W.ui
  local realSpell, realCast = STUB.SpellInfo, STUB.CastSpellByName
  local realParty = STUB.GetNumPartyMembers
  STUB.SpellInfo, STUB.CastSpellByName = nil, nil
  STUB.GetNumPartyMembers = function() return 2 end
  T:Settings().tankMode = "on"
  T:Settings().mobFramesFor = "tank"
  T:Settings().mobFramesMin = 1
  T:Settings().mobFramesCollapse = "never"
  T.watch, T.groupMobs, T.taunts = {}, {}, {}
  W.capture.groupMembers["Elfpriest"] = true
  W.encounter:CombatStart()

  -- party1 has the whelp targeted; the whelp is on the priest.
  WORLD["party1target"] = { name = "Whelp", isPlayer = false, maxHealth = 100, health = 60 }
  WORLD["party1targettarget"] = { name = "Elfpriest", isPlayer = true, class = "PRIEST" }
  -- party2 has the same whelp: one mob, not two (UnitIsUnit says so).
  WORLD["party2target"] = WORLD["party1target"]
  WORLD["party2targettarget"] = WORLD["party1targettarget"]
  local realIsUnit = STUB.UnitIsUnit
  STUB.UnitIsUnit = function(a, b)
    if (a == "party2target" and b == "party1target") or (a == "party1target" and b == "party2target") then
      return 1
    end
    return a == b
  end

  T.lastScan = nil
  T:ScanGroup()
  local count = 0
  for _ in pairs(T.groupMobs) do count = count + 1 end
  if count ~= 1 then error("the scan found " .. count .. " mobs, not 1") end
  NOW = NOW + 1.2
  T.lastScan = nil
  T:ScanGroup()
  if T:CountWatch("loose") ~= 1 then error("the whelp on the priest is not loose without SuperWoW") end
  local q = T:Taunts()[1]
  if not q or q.unit ~= "party1target" then error("the taunt bar cannot reach it: " .. tostring(q and q.unit)) end

  UI.mobs.lastUpdate = nil
  UI.mobs:Update()
  if not UI.mobs.frame or not UI.mobs.frame:IsShown() then error("no mob frames without SuperWoW") end
  local row
  for _, r in ipairs(UI.mobs.rows) do
    if r:IsShown() and r.mob and r.mob.name == "Whelp" then row = r end
  end
  if not (row and string.find(row.who:GetText() or "", "Elfpriest", 1, true)) then
    error("the mob frame does not show the whelp on the priest")
  end
  if not row.trouble then error("the loose whelp's frame is not marked") end

  local acts = {}
  STUB.TargetUnit = function(u) table.insert(acts, "target:" .. u) end
  STUB.CastSpell = function(i) table.insert(acts, "cast" .. i) end
  arg1 = "LeftButton"
  row:GetScript("OnClick")()
  if acts[1] ~= "target:party1target" then error("clicking did not target it: " .. tostring(acts[1])) end
  acts = {}
  local realName, realTex, realCd = STUB.GetSpellName, STUB.GetSpellTexture, STUB.GetSpellCooldown
  STUB.GetSpellName = function(i) return (i == 1) and "Taunt" or nil end
  STUB.GetSpellTexture = function(i) return "Interface\\Icons\\Spell_Nature_Reincarnation" end
  STUB.GetSpellCooldown = function() return 0, 0, 1 end
  T.tauntCache = nil
  T:TauntNext()
  STUB.GetSpellName, STUB.GetSpellTexture, STUB.GetSpellCooldown = realName, realTex, realCd
  T.tauntCache = nil
  if acts[1] ~= "target:party1target" or not acts[2] then
    error("taunting without SuperWoW: " .. table.concat(acts, ", "))
  end

  STUB.UnitIsUnit = realIsUnit
  STUB.SpellInfo, STUB.CastSpellByName = realSpell, realCast
  STUB.GetNumPartyMembers = realParty
  for _, k in ipairs({ "party1target", "party1targettarget", "party2target", "party2targettarget" }) do
    WORLD[k] = nil
  end
  T.watch, T.groupMobs, T.taunts = {}, {}, {}
  T:Settings().mobFramesMin = 2
  T:Settings().mobFramesCollapse = "auto"
  T:Settings().tankMode = "auto"
  W.encounter:CombatEnd()
end)

step("skins: pfUI's own backdrop is used when pfUI is loaded", function()
  local UI = W.ui
  local was = UI.skin
  local called = 0
  STUB.pfUI = { api = { CreateBackdrop = function(f) called = called + 1 f.backdrop = makeFrame("Frame") end },
                media = { ["img:bar"] = "Interface\\AddOns\\pfUI\\img\\bar" } }
  W.db.skin = "auto"
  if UI.ResolveSkin() ~= "pfui" then error("auto did not pick pfui with pfUI loaded") end
  UI.skin = "pfui"
  local f = makeFrame("Frame")
  UI.Backdrop(f, "window")
  if called ~= 1 then error("pfUI.api.CreateBackdrop was not used") end
  UI.BackdropAlpha(f, 0.5)
  for _, kind in ipairs({ "blizzard", "pfui" }) do
    UI.skin = kind
    STUB.pfUI = nil
    local g = makeFrame("Frame")
    for _, k in ipairs({ "window", "dialog", "small" }) do UI.Backdrop(g, k) UI.BackdropAlpha(g, 0.6) end
    UI.SkinBlizzardButton(UI.Button(UIParent, "x", 40, 20))
    UI.SkinPfuiButton(UI.Button(UIParent, "x", 40, 20))
  end
  STUB.pfUI = nil
  W.db.skin = "auto"
  UI.skin = was
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

  -- Per fight, and with what: clicking the row lists the spells.
  local last = W.db.encounters[table.getn(W.db.encounters)]
  local one = W.report:View({ last }, { petMode = "merge" })
  local drow = W.report:Rank(one, "dispels")[1]
  if not drow or drow.dispels ~= 2 then
    error("this fight's dispels read " .. tostring(drow and drow.dispels))
  end
  local list, total = W.report:Abilities(drow, "dispels")
  if total ~= 2 or not list[1] or list[1].id ~= 527 then
    error("the dispel detail lists " .. table.getn(list or {}) .. " spell(s), total " .. tostring(total))
  end

  -- The report has a tab for it.
  local found
  for _, t in ipairs(W.ui.report.tabs) do if t.key == "dispels" then found = t end end
  if not found or found.metric ~= "dispels" then error("the report has no Dispels tab") end
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

    -- Combat fade and hide: drive the meter's watcher through every mode,
    -- in and out of a fight. That code only ever runs from the watcher's
    -- OnUpdate, so without this its globals would first be read in a raid.
    do
      local m = W.ui.meter
      local s = m:Settings()
      local tick = m.watcher and m.watcher:GetScript("OnUpdate")
      local wasInCombat = IN_COMBAT
      W.lastError = nil
      if tick then
        for _, mode in ipairs({ "fade", "hide", "show" }) do
          s.combat = mode
          IN_COMBAT = true
          for _ = 1, 20 do NOW = NOW + 0.05 tick() end
          IN_COMBAT = false
          for _ = 1, 20 do NOW = NOW + 0.05 tick() end
        end
      end
      -- The watcher is guarded, so an error there is swallowed and printed
      -- once; surface it here instead of letting the audit pass over it.
      if W.lastError and W.lastError.label == "meter combat fade" then
        error("meter combat fade: " .. tostring(W.lastError.err))
      end
      IN_COMBAT = wasInCombat
      s.combat = "show"
      m:Show()
    end

    -- Picked players: shift-click a row, filter to the picks in both
    -- windows, open the pick list, unpick from it, clear.
    do
      local m = W.ui.meter
      m:Show()
      m:Refresh()
      local row = m.list and m.list.rows and m.list.rows[1]
      STUB.IsShiftKeyDown = function() return true end
      arg1 = "LeftButton"
      if row and row._scripts and row._scripts.OnClick then row._scripts.OnClick() end
      STUB.IsShiftKeyDown = nil
      W.report:TogglePick("Fuff")
      if m.pickBtn then m.pickBtn._scripts.OnClick() end
      if W.ui.report.pickBtn then
        W.ui.report:Show()
        W.ui.report.pickBtn._scripts.OnClick()
      end
      arg1 = "RightButton"
      if m.pickBtn then m.pickBtn._scripts.OnClick() end
      local menu = W.ui.PickMenu(m.frame, m.pickBtn)
      for _, r in ipairs((menu and menu.rows) or {}) do
        if r:IsShown() and r._scripts and r._scripts.OnClick then
          r._scripts.OnClick()
          break
        end
      end
      W.report:ClearPicks()
      W.ui.PicksChanged()
      W.ui.CloseMenu()
      arg1 = nil
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
    W.ui.report.state.sessionId = nil
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
  W.ui.report.state.sessionId = nil
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

step("crash recovery once a login, and the mark at logout", function()
  local f = _G["WrekkitInitFrame"]
  local runs = 0
  local realRecover = W.store.Recover
  W.store.Recover = function(self) runs = runs + 1 return realRecover(self) end
  W.store.recovered = nil
  event = "PLAYER_ENTERING_WORLD"
  f._scripts.OnEvent()
  f._scripts.OnEvent()           -- every loading screen fires it
  W.store.Recover = realRecover
  if runs ~= 1 then error("recovery ran " .. runs .. " times, not once") end

  event = "PLAYER_LOGOUT"
  f._scripts.OnEvent()
  local mark = W.db.journalMarks and W.db.journalMarks[W.store:Filename()]
  if not mark then error("logout left no journal mark") end
  if mark.bytes ~= string.len(DISK[W.store:Filename()] or "") then
    error("the mark's length disagrees with the journal on disk")
  end
end)

step("other tanks: their threat and the mobs they take raise nothing", function()
  local T, UI = W.threat, W.ui
  local s = T:Settings()
  s.tankMode, s.coTanks = "on", "Fuff"
  T.fired, T.lost, T.taunts, T.tankMobs, T.heldKey = {}, {}, {}, {}, nil
  local alerts = {}
  local realAlert = T.Alert
  T.Alert = function(self, text, level) table.insert(alerts, text) end
  -- Onyxia targeted.
  local realExists, realTarget = STUB.UnitExists, WORLD["target"]
  WORLD["0xF00000000000ABCD"] = WORLD["0xF00000000000ABCD"] or { name = "Onyxia", isPlayer = false,
    rank = "worldboss", maxHealth = 1200000, health = 1200000 }
  WORLD["target"] = WORLD["0xF00000000000ABCD"]
  STUB.UnitExists = function(u)
    if u == "target" then return 1, "0xF00000000000ABCD" end
    return realExists(u)
  end
  T.reqKey = nil
  local ok, err = pcall(function()
    -- Fuff, a co-tank, is right behind you; Elfpriest is the real runner-up.
    T:OnMessage("TWTv4=Auditor:1:3000:100:1;Fuff:0:2950:98:1;Elfpriest:0:1500:50:0;" ..
                "#TMTv1=Onyxia:43981:Fuff:98;")
    for _, a in ipairs(alerts) do
      if string.find(a, "Fuff", 1, true) then error("warned about a co-tank: " .. a) end
    end
    local live = T:Live()
    local runner = T:Runner(live)
    if not runner or runner.name ~= "Elfpriest" then
      local names = {}
      for _, r in ipairs((live and live.rows) or {}) do table.insert(names, r.name .. (r.tank and "*" or "")) end
      error("the runner-up is " .. tostring(runner and runner.name) .. " in " .. table.concat(names, ","))
    end
    if (T.tankMobs[43981].pull or 0) ~= 0 then error("a co-tank behind you still reads as danger") end
    local worst = T:Alarm()
    if worst and worst >= s.tankFlashAt then error("flashing for a co-tank") end

    -- Fuff taunts Onyxia off you: a swap, not lost aggro.
    alerts = {}
    T:OnMessage("TWTv4=Fuff:1:3400:100:1;Auditor:0:3000:88:1;")
    for _, a in ipairs(alerts) do
      if string.find(a, "LOST", 1, true) then error("a swap to a co-tank was called lost: " .. a) end
    end
    if table.getn(T:Taunts()) ~= 0 then error("the taunt bar offered a mob a co-tank took") end

    -- The same to someone who is not a tank is still lost.
    s.coTanks = ""
    T.fired, T.lost, T.taunts, T.heldKey = {}, {}, {}, nil
    T:OnMessage("TWTv4=Auditor:1:3000:100:1;Fuff:0:2950:98:1;")
    T:OnMessage("TWTv4=Fuff:1:3400:100:1;Auditor:0:3000:88:1;")
    local lost = false
    for _, a in ipairs(alerts) do if string.find(a, "LOST AGGRO", 1, true) then lost = true end end
    if not lost then error("losing a mob to a non-tank is no longer announced") end

    -- Marking: by name, by toggle, and by right-click in the threat window.
    if not T:ToggleCoTank("Fuff") or not T:IsCoTank("fuff") then error("marking by name failed") end
    T:ToggleCoTank("Bob")
    if s.coTanks ~= "Fuff, Bob" then error("the list reads " .. s.coTanks) end
    T:ToggleCoTank("Bob")
    if T:IsCoTank("Bob") or s.coTanks ~= "Fuff" then error("unmarking failed: " .. s.coTanks) end

    UI.threat:Refresh()
    local row = UI.threat.list.rows[1]
    UI.threat.Paint(row, { row = { name = "Elfpriest", class = "PRIEST", threat = 1, perc = 50, pull = 38 }, shown = 38 })
    local click = row:GetScript("OnClick")
    if not click then error("a player row takes no click") end
    arg1 = "RightButton"
    click()
    arg1 = nil
    if not T:IsCoTank("Elfpriest") then error("right-click did not mark them") end

    SlashCmdList["WREKKIT"]("threat tanks")
    SlashCmdList["WREKKIT"]("threat cotank elfpriest")
    if T:IsCoTank("Elfpriest") then error("/wrek threat cotank did not toggle them off") end
  end)
  T.Alert = realAlert
  STUB.UnitExists, WORLD["target"] = realExists, realTarget
  s.tankMode, s.coTanks = "auto", ""
  T.fired, T.lost, T.taunts, T.tankMobs, T.heldKey = {}, {}, {}, {}, nil
  if not ok then error(err) end
end)

step("other tanks: found by stance and shared with the group", function()
  local T = W.threat
  local s = T:Settings()
  local real = {
    raid = STUB.GetNumRaidMembers, name = STUB.UnitName, buff = STUB.UnitBuff,
    send = STUB.SendAddonMessage, members = W.capture.groupMembers,
  }
  -- A raid of three: Tanky in Defensive Stance, Bear in Dire Bear Form
  -- (seen by icon alone, as without SuperWoW), Healy in neither.
  local roster = { raid1 = "Tanky", raid2 = "Healy", raid3 = "Bear" }
  local buffs = {
    Tanky = { { "Interface\\Icons\\Ability_Warrior_DefensiveStance", 71 } },
    Healy = { { "Interface\\Icons\\Spell_Holy_PowerWordFortitude", 10938 } },
    Bear = { { "Interface\\Icons\\Ability_Racial_BearForm", nil } },
  }
  local sent = {}
  STUB.GetNumRaidMembers = function() return 3 end
  STUB.UnitName = function(u) return roster[u] or real.name(u) end
  STUB.UnitBuff = function(u, i)
    local b = buffs[roster[u] or ""]
    b = b and b[i]
    if b then return b[1], 1, b[2] end
  end
  STUB.SendAddonMessage = function(p, m, c)
    if p == T.TANK_PREFIX then table.insert(sent, m .. "@" .. c) end
  end
  W.capture.groupMembers = { Tanky = true, Healy = true, Bear = true, Auditor = true }
  s.coTanks, s.coTanksOff, s.coTankAuto, s.coTankShare = "", "", true, true
  T.seenTank, T.peerRoles, T.detectedAt, T.lastChannel, T.sentRole = {}, {}, nil, nil, nil

  local ok, err = pcall(function()
    if not T:IsCoTank("Tanky") then error("Defensive Stance was not found") end
    if not T:IsCoTank("Bear") then error("Dire Bear Form by icon was not found") end
    if T:IsCoTank("Healy") then error("a healer was taken for a tank") end

    -- Unmarking a found tank by hand sticks, and is sent to the raid.
    T:ToggleCoTank("Tanky")
    T.detectedAt = nil
    if T:IsCoTank("Tanky") then error("unmarking a found tank did not stick") end
    if sent[table.getn(sent)] ~= "K:Tanky:0@RAID" then
      error("the unmark went out as " .. tostring(sent[table.getn(sent)]))
    end
    T:ToggleCoTank("Tanky")
    if not T:IsCoTank("Tanky") or s.coTanksOff ~= "" then error("marking them again failed") end

    -- Someone else marks the healer: applied here, not echoed back.
    local before = table.getn(sent)
    T:OnTankMessage("K:healy:1", "Tanky")
    if not T:IsCoTank("Healy") then error("a mark from the raid was not applied") end
    if table.getn(sent) ~= before then error("a received mark was sent back out") end
    -- From outside the group: ignored.
    T:OnTankMessage("K:Bear:0", "Stranger")
    if not T:IsCoTank("Bear") then error("a mark from outside the group was applied") end
    -- Their unmark of a found tank sticks here too.
    T:OnTankMessage("K:Bear:0", "Healy")
    T.detectedAt = nil
    if T:IsCoTank("Bear") then error("an unmark from the raid did not stick") end

    -- A list only adds, and never over a hand unmark.
    s.coTanks, s.coTanksOff = "", "Bear"
    T:OnTankMessage("C:Healy,Bear", "Tanky")
    if not T:IsCoTank("Healy") then error("a shared list did not add a name") end
    if T:IsCoTank("Bear") then error("a shared list overrode a hand unmark") end

    -- Their Wrekkit says they tank, wherever they are.
    s.coTanks, s.coTanksOff = "", ""
    buffs.Healy = {}
    T:OnTankMessage("R:1", "Healy")
    if not T:IsCoTank("Healy") then error("a peer's role report was ignored") end
    T:OnTankMessage("R:0", "Healy")
    if T:IsCoTank("Healy") then error("a peer's 'not tanking' was ignored") end

    -- Joining asks the raid once, then says our role once.
    sent = {}
    T:TankWatch()
    T:TankWatch()
    local q, r = 0, 0
    for _, m in ipairs(sent) do
      if m == "Q@RAID" then q = q + 1 end
      if string.sub(m, 1, 2) == "R:" then r = r + 1 end
    end
    if q ~= 1 or r ~= 1 then error("joining sent " .. table.concat(sent, " ")) end

    -- The tank button: the warriors, druids and paladins, checked when
    -- they count as tanks, and a click toggles one.
    local realRoster, realMenu = STUB.GetRaidRosterInfo, W.ui.Menu
    local classes = { raid1 = "WARRIOR", raid2 = "PRIEST", raid3 = "DRUID" }
    STUB.GetRaidRosterInfo = function(i)
      local u = "raid" .. i
      return roster[u], 0, 1, 60, classes[u], classes[u]
    end
    local shown, pick
    W.ui.Menu = function(frame, anchor, items, cb)
      shown, pick = items, cb
      return realMenu(frame, anchor, items, cb)
    end
    local mok, merr = pcall(function()
      W.ui.threat:Create()
      if not W.ui.threat.tankBtn then error("the threat window has no tank button") end
      W.ui.threat.tankBtn:GetScript("OnClick")()
      local rows = {}
      for _, it in ipairs(shown or {}) do
        if it.value and string.sub(it.value, 1, 2) == "t:" then rows[string.sub(it.value, 3)] = it.checked end
      end
      if rows.Tanky == nil or rows.Bear == nil then error("the tank menu left out a warrior or druid") end
      if rows.Healy ~= nil then error("the tank menu listed a priest") end
      if not rows.Tanky then error("a found tank is not checked in the menu") end
      pick("t:Bear")
      if T:IsCoTank("Bear") then error("unticking Bear in the menu did not unmark them") end
      pick("t:Bear")
      if not T:IsCoTank("Bear") then error("ticking Bear in the menu did not mark them") end
    end)
    STUB.GetRaidRosterInfo, W.ui.Menu = realRoster, realMenu
    W.ui.CloseMenu()
    if not mok then error(merr) end

    -- The group disbands: once it has stayed gone, the marks go with it.
    s.coTanks, s.coTanksOff = "Healy", "Tanky"
    STUB.GetNumRaidMembers = function() return 0 end
    T.lastChannel, T.goneAt = "RAID", nil
    T:TankWatch()
    if s.coTanks ~= "Healy" then error("marks were cleared on the first empty roster") end
    T.goneAt = T.goneAt - 5
    T:TankWatch()
    if s.coTanks ~= "" or s.coTanksOff ~= "" then error("leaving the group kept the marks") end
    STUB.GetNumRaidMembers = function() return 3 end
    T.lastChannel = nil

    -- Detection off: only marks count.
    s.coTankAuto = false
    if T:IsCoTank("Tanky") then error("detection still marks with it switched off") end
    -- Sharing off: nothing goes out and nothing is taken in.
    s.coTankShare = false
    sent = {}
    T:ToggleCoTank("Healy")
    T:OnTankMessage("K:Tanky:1", "Healy")
    if table.getn(sent) ~= 0 then error("a mark went out with sharing off") end
    if T:IsCoTank("Tanky") then error("a mark came in with sharing off") end

    SlashCmdList["WREKKIT"]("threat tanks")
  end)

  STUB.GetNumRaidMembers, STUB.UnitName, STUB.UnitBuff = real.raid, real.name, real.buff
  STUB.SendAddonMessage, W.capture.groupMembers = real.send, real.members
  s.coTanks, s.coTanksOff, s.coTankAuto, s.coTankShare = "", "", true, true
  T.seenTank, T.peerRoles, T.detectedAt, T.lastChannel, T.sentRole = {}, {}, nil, nil, nil
  if not ok then error(err) end
end)

step("a tank's mobs relayed: warned on every mob you are about to pull", function()
  local T = W.threat
  local s = T:Settings()
  local real = { raid = STUB.GetNumRaidMembers, send = STUB.SendAddonMessage,
                 members = W.capture.groupMembers, alert = T.Alert }
  local sent, alerts = {}, {}
  STUB.GetNumRaidMembers = function() return 3 end
  STUB.SendAddonMessage = function(p, m, c)
    if p == T.TANK_PREFIX then table.insert(sent, m) end
  end
  W.capture.groupMembers = { Tanky = true, Healy = true, Auditor = true }
  T.Alert = function(self, text, level) table.insert(alerts, text .. "|" .. tostring(level)) end
  s.relayThreat, s.warnAt, s.dangerAt, s.flashAt, s.flash = true, 80, 95, 85, true
  T.fired, T.relayMobs, T.tankMobs, T.lastRelay, T.lastTM, T.current = {}, {}, {}, nil, nil, nil

  local ok, err = pcall(function()
    -- Tanking: tank mode names a runner-up on three mobs. One message goes
    -- out, closest first, and no second one inside a second.
    s.tankMode = "on"
    T:OnMessage("TWTv4=Auditor:1:3000:100:1;#TMTv1=Imp:777:Healy:50;Ragefang:4660:Mage:105;" ..
                "Rag, the Big:4661:Mage:70;")
    if table.getn(sent) ~= 1 then error("tanking sent " .. table.getn(sent) .. " relays, not 1") end
    if string.sub(sent[1], 1, 21) ~= "T:4660,Mage,105,Ragef" then error("relay reads " .. sent[1]) end
    if string.find(sent[1], "Rag, the", 1, true) then error("a comma in a mob's name went out raw") end
    T:OnMessage("TWTv4=Auditor:1:3000:100:1;#TMTv1=Imp:777:Healy:50;")
    if table.getn(sent) ~= 1 then error("relayed twice inside a second") end

    -- Not tanking: a tank's relay names this player on Ragefang. Warned and
    -- flashed for it; not for Imp, which Healy is closer to.
    s.tankMode = "off"
    T.roleAt = nil
    T.fired, T.tankMobs, alerts = {}, {}, {}
    T:OnTankMessage("T:4660,Auditor,105,Ragefang;777,Healy,50,Imp", "Tanky")
    if table.getn(alerts) ~= 1 or not string.find(alerts[1], "Ragefang", 1, true) then
      error("relay alerts: " .. table.concat(alerts, " / "))
    end
    if not string.find(alerts[1], "|danger", 1, true) then error("95% of the way was not a danger alert") end
    local pull = T:Alarm()
    if not pull or pull < s.flashAt then error("no flash for a relayed mob about to be pulled") end
    local pct, _, fresh = T:ForMob(nil, "0xF130000ABC001234")
    if not pct or not fresh then error("the relayed mob's nameplate shows nothing") end
    if T:ForMob(nil, "0xF130000ABC000309") then error("a plate showed a mob Healy is closer to") end
    -- The same reading again does not warn again.
    T:OnTankMessage("T:4660,Auditor,106,Ragefang", "Tanky")
    if table.getn(alerts) ~= 1 then error("a relayed mob warned twice") end

    -- Your own target: its own reply covers it, the relay does not.
    T.fired, T.relayMobs, alerts = {}, {}, {}
    T.current = { low = 4662, at = GetTime(), key = "x" }
    T:OnTankMessage("T:4662,Auditor,105,Whelp", "Tanky")
    if table.getn(alerts) ~= 0 then error("the relay warned about your own target") end
    T.current = nil

    -- From outside the group: ignored. Switched off: ignored.
    T.fired, T.relayMobs, alerts = {}, {}, {}
    T:OnTankMessage("T:4663,Auditor,105,Whelp", "Stranger")
    s.relayThreat = false
    T:OnTankMessage("T:4664,Auditor,105,Whelp", "Tanky")
    if table.getn(alerts) ~= 0 or next(T.relayMobs) then error("a relay was taken from outside or while off") end

    -- Gone stale: forgotten.
    s.relayThreat = true
    T:OnTankMessage("T:4665,Auditor,60,Whelp", "Tanky")
    NOW = NOW + 5
    T:Prune()
    if T.relayMobs[4665] then error("a stale relay was kept") end

    -- Danger alerts also go up as a raid warning, on this screen only.
    local rw = {}
    STUB.RaidWarningFrame = { AddMessage = function(self, m) table.insert(rw, m) end }
    T.Alert = real.alert
    s.raidWarning = true
    T:Alert("AGGRO! Ragefang is on you", "danger")
    T:Alert("THREAT 82%", "warn")
    T:Alert("AGGRO! Ragefang is on you", "danger")
    if table.getn(rw) ~= 1 or rw[1] ~= "WARNING: AGGRO! Ragefang is on you" then
      error("raid warnings: " .. table.concat(rw, " / "))
    end
    s.raidWarning = false
    NOW = NOW + 3
    T:Alert("LOST AGGRO: Imp", "danger")
    if table.getn(rw) ~= 1 then error("a raid warning showed with the setting off") end
    s.raidWarning = true
    STUB.RaidWarningFrame = nil
  end)

  STUB.GetNumRaidMembers, STUB.SendAddonMessage = real.raid, real.send
  W.capture.groupMembers, T.Alert = real.members, real.alert
  s.tankMode, s.relayThreat = "auto", true
  T.fired, T.relayMobs, T.tankMobs, T.lastRelay, T.lastTM, T.current = {}, {}, {}, nil, nil, nil
  T.roleAt = nil
  if not ok then error(err) end
end)

step("the TANK button: say you are the tank, whatever your stance", function()
  local T, TW = W.threat, W.ui.threat
  local s = T:Settings()
  local real = { raid = STUB.GetNumRaidMembers, send = STUB.SendAddonMessage }
  local sent = {}
  STUB.GetNumRaidMembers = function() return 3 end
  STUB.SendAddonMessage = function(p, m, c)
    if p == T.TANK_PREFIX then table.insert(sent, m) end
  end
  s.tankMode, s.coTankShare = "auto", true
  T.roleAt = nil

  local ok, err = pcall(function()
    TW:Create()
    local b = TW.roleBtn
    if not b then error("the threat window has no TANK button") end
    local click = b:GetScript("OnClick")
    TW:PaintRole()
    -- The audit plays a warrior in no stance: AUTO, not tanking.
    if b.label:GetText() ~= "AUTO" or T:IsTank() then error("auto, not tanking, reads " .. tostring(b.label:GetText())) end

    arg1 = "LeftButton" click()
    if s.tankMode ~= "on" or not T:IsTank() then error("left-click did not make you the tank") end
    if b.label:GetText() ~= "TANK" then error("the button reads " .. tostring(b.label:GetText())) end
    if sent[table.getn(sent)] ~= "R:1" then error("the group was not told: " .. tostring(sent[table.getn(sent)])) end

    arg1 = "LeftButton" click()
    if s.tankMode ~= "auto" then error("left-click again did not go back to auto") end

    arg1 = "RightButton" click()
    if s.tankMode ~= "off" or b.label:GetText() ~= "DPS" then error("right-click did not pick never") end
    if sent[table.getn(sent)] ~= "R:0" then error("never was not sent as not tanking") end

    arg1 = "LeftButton" click()
    if s.tankMode ~= "on" then error("left-click from never did not make you the tank") end
    arg1 = nil
  end)

  arg1 = nil
  STUB.GetNumRaidMembers, STUB.SendAddonMessage = real.raid, real.send
  s.tankMode = "auto"
  T.roleAt = nil
  if not ok then error(err) end
end)

step("click to warn someone; dead, the threat stays up while the raid fights", function()
  local T, TW = W.threat, W.ui.threat
  local s = T:Settings()
  local real = { raid = STUB.GetNumRaidMembers, send = STUB.SendAddonMessage,
                 chat = STUB.SendChatMessage, combat = STUB.UnitAffectingCombat,
                 members = W.capture.groupMembers, alert = T.Alert }
  local sent, whispers, alerts = {}, {}, {}
  STUB.GetNumRaidMembers = function() return 3 end
  STUB.SendAddonMessage = function(p, m, c) if p == T.TANK_PREFIX then table.insert(sent, m) end end
  STUB.SendChatMessage = function(m, kind, lang, to) table.insert(whispers, kind .. ":" .. tostring(to) .. ":" .. m) end
  W.capture.groupMembers = { Tanky = true, Healy = true, Auditor = true }
  T.Alert = function(self, text, level) table.insert(alerts, text) end
  T.nudged, T.peerRoles = {}, { Tanky = { tank = false, at = GetTime() } }

  local ok, err = pcall(function()
    -- Tanky runs Wrekkit: an alert on their screen, not a whisper.
    T:Nudge("Tanky", 94.6, "Ragefang")
    if sent[table.getn(sent)] ~= "N:Tanky:95:Ragefang" or table.getn(whispers) ~= 0 then
      error("a Wrekkit user was warned as " .. tostring(sent[table.getn(sent)]) .. " / " .. table.concat(whispers, ","))
    end
    -- Healy does not: a whisper.
    T:Nudge("Healy", 88, "Ragefang")
    if table.getn(whispers) ~= 1 or not string.find(whispers[1], "^WHISPER:Healy:", 1) then
      error("someone without Wrekkit got " .. table.concat(whispers, ","))
    end
    -- A double-click is one warning.
    T:Nudge("Healy", 90, "Ragefang")
    if table.getn(whispers) ~= 1 then error("a second click inside five seconds warned again") end
    -- Never yourself.
    if T:Nudge("Auditor", 99, "Ragefang") then error("you warned yourself") end

    -- On the other end: addressed to us, an alert; to someone else, nothing.
    T:OnTankMessage("N:Auditor:95:Ragefang", "Tanky")
    T:OnTankMessage("N:Healy:95:Ragefang", "Tanky")
    if table.getn(alerts) ~= 1 or not string.find(alerts[1], "Tanky: your threat is 95% on Ragefang", 1, true) then
      error("received warnings: " .. table.concat(alerts, " / "))
    end

    -- A click on a player's row is what sends it.
    T.nudged = {}
    whispers = {}
    TW:Create()
    TW:Refresh()
    local row = TW.list.rows[1]
    TW.Paint(row, { row = { name = "Healy", class = "PRIEST", threat = 1, perc = 80, pull = 73 }, shown = 73 })
    arg1 = "LeftButton"
    row:GetScript("OnClick")()
    arg1 = nil
    if table.getn(whispers) ~= 1 or not string.find(whispers[1], "73%", 1, true) then
      error("clicking Healy's row sent " .. table.concat(whispers, ","))
    end

    -- Dead: you leave combat, the raid fights on. Nothing is wiped and the
    -- window stays; once the raid stops, the fight ends.
    T.Alert = real.alert
    s.display, s.show = "window", "combat"
    STUB.UnitAffectingCombat = function(u) return u ~= "player" and u ~= "pet" end
    NOW = NOW + 1
    T.current = { key = "k", low = 1, at = GetTime(), rows = {}, name = "Ragefang" }
  end)

  local ok2, err2 = pcall(function()
    if not ok then return end
    event = "PLAYER_REGEN_ENABLED"
    T.frame:GetScript("OnEvent")()
    event = nil
    if not T.current then error("dying wiped the threat while the raid fought on") end
    if not T.endPending then error("the fight's end was not held for the raid") end
    if not TW:WantShown() then error("the window hid when you died mid-fight") end
    -- The raid stops.
    STUB.UnitAffectingCombat = function() return false end
    NOW = NOW + 2
    T.nextPoll, T.lastPrune = nil, nil
    T.frame:GetScript("OnUpdate")()
    if T.current or T.endPending then error("the fight did not end once the raid had stopped") end
  end)

  event, arg1 = nil, nil
  STUB.GetNumRaidMembers, STUB.SendAddonMessage = real.raid, real.send
  STUB.SendChatMessage, STUB.UnitAffectingCombat = real.chat, real.combat
  W.capture.groupMembers, T.Alert = real.members, real.alert
  T.nudged, T.peerRoles, T.endPending, T.current = {}, {}, nil, nil
  s.display, s.show = "window", s.show
  if not ok then error(err) end
  if not ok2 then error(err2) end
end)

step("raids saved to their own files: open, keep, delete from the report", function()
  local A = W.archive
  if not A:Active() then error("the file API stubs should make per-raid files active") end
  -- Everything recorded so far is on disk; move past the night in progress
  -- so it leaves SavedVariables, as the next day's login would find it.
  A:MigrateNow()
  if table.getn(A:List()) == 0 then error("no raid files were written") end
  NOW = NOW + A.HOLD + 60
  W.TrimHistory()
  local R = W.ui.report
  R:Show()

  local items, pick
  local realMenu = W.ui.Menu
  W.ui.Menu = function(_, _, its, onPick) items, pick = its, onPick end
  local ok, err = pcall(function()
    R:SessionMenu()
    local open
    for _, it in ipairs(items or {}) do
      if type(it.value) == "string" and string.sub(it.value, 1, 5) == "open:" then open = it end
    end
    if not open then error("the session menu lists no saved raids") end
    pick(open.value, open)
    local s = R:Session()
    if not s or s.archive ~= string.sub(open.value, 6) then error("opening a saved raid did not show it") end
    if table.getn(s.encounters) == 0 then error("the opened raid has no pulls") end

    -- Now the menu offers keep and delete for it.
    R:SessionMenu()
    local keep, del
    for _, it in ipairs(items) do
      if type(it.value) == "string" then
        if string.sub(it.value, 1, 5) == "keep:" then keep = it end
        if string.sub(it.value, 1, 7) == "delete:" then del = it end
      end
    end
    if not (keep and del) then error("no keep/delete for the raid on screen") end
    local key = string.sub(keep.value, 6)
    pick(keep.value, keep)
    if not A:Index()[key].kept then error("keep did not take") end
    pick(del.value, del)
    if R.pendingDelete ~= key then error("delete did not ask first") end
    R:ConfirmDeleteArchive()
    if A:Index()[key] then error("the raid was not deleted") end
  end)
  W.ui.Menu = realMenu
  if not ok then error(err) end

  -- And from chat.
  SlashCmdList["WREKKIT"]("raids")
  R.frame:Hide()
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

--[[ test_degraded.lua - what happens without SuperWoW and/or Nampower

    lua tools/test_degraded.lua full        everything present (baseline)
    lua tools/test_degraded.lua nosuper     SuperWoW missing
    lua tools/test_degraded.lua nonam       Nampower missing
    lua tools/test_degraded.lua neither     both missing

Each scenario is a separate process because the addon writes globals and a
second load in the same state would see the first one's leftovers.

The point is not "does it survive" -- it is to measure exactly WHAT still
works, so the requirement can be described honestly rather than as a vague
"needs these". Every scenario loads the addon, records a pull, builds both
windows and runs the slash commands, then reports which capabilities came
back.
]]

package.path = "./?.lua;" .. package.path

local scenario = ... or "full"
local HAVE_SUPER = (scenario == "full" or scenario == "nonam")
local HAVE_NAM = (scenario == "full" or scenario == "nosuper")

math.mod = math.mod or math.fmod
string.gfind = string.gfind or string.gmatch
table.getn = table.getn or function(t) return #t end
table.setn = table.setn or function() end
unpack = unpack or table.unpack

----------------------------------------------------------------------
-- minimal client
----------------------------------------------------------------------

local NOW = 1000.0
local WORLD = {}
local DISK = {}

GetTime = function() return NOW end
time = function() return 1700000000 + math.floor(NOW) end
date = function() return "14.09.26" end

local function region()
  local r = { _w = 0, _h = 0, _shown = true, _points = {} }
  return setmetatable(r, { __index = function(t, k)
    if k == "GetWidth" then return function(s) return s._w end end
    if k == "GetHeight" then return function(s) return s._h end end
    if k == "SetWidth" then return function(s, v) s._w = v or 0 end end
    if k == "SetHeight" then return function(s, v) s._h = v or 0 end end
    if k == "IsShown" or k == "IsVisible" then return function(s) return s._shown end end
    if k == "Show" then return function(s) s._shown = true end end
    if k == "Hide" then return function(s) s._shown = false end end
    if k == "GetText" then return function(s) return s._text or "" end end
    if k == "SetText" then return function(s, v) s._text = v end end
    if k == "GetStringWidth" then return function(s) return string.len(s._text or "") * 5 end end
    if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
    if not string.find(k, "^%u") then return nil end
    return function() end
  end })
end

CreateFrame = function(kind, name)
  local f = { _scripts = {}, _events = {}, _w = 100, _h = 100, _shown = false }
  setmetatable(f, { __index = function(t, k)
    if k == "SetScript" then return function(s, e, fn) s._scripts[e] = fn end end
    if k == "GetScript" then return function(s, e) return s._scripts[e] end end
    if k == "RegisterEvent" then return function(s, e) s._events[e] = true end end
    if k == "UnregisterEvent" then return function(s, e) s._events[e] = nil end end
    if k == "CreateTexture" or k == "CreateFontString" then return function() return region() end end
    if k == "GetWidth" then return function(s) return s._w end end
    if k == "GetHeight" then return function(s) return s._h end end
    if k == "SetWidth" then return function(s, v) s._w = v or 0 end end
    if k == "SetHeight" then return function(s, v) s._h = v or 0 end end
    if k == "IsShown" or k == "IsVisible" then return function(s) return s._shown end end
    if k == "Show" then return function(s) s._shown = true end end
    if k == "Hide" then return function(s) s._shown = false end end
    if k == "GetFrameLevel" then return function() return 1 end end
    if k == "GetCenter" then return function() return 400, 300 end end
    if k == "GetEffectiveScale" then return function() return 1 end end
    if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
    if k == "GetParent" then return function(s) return s._parent end end
    if not string.find(k, "^%u") then return nil end
    return function() end
  end })
  if name then _G[name] = f end
  return f
end

_G = _G or getfenv(0)

UIParent = CreateFrame("Frame", "UIParent")
Minimap = CreateFrame("Frame", "Minimap")
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
GameTooltip = { SetOwner = function() end, AddLine = function() end,
                Show = function() end, Hide = function() end }
SlashCmdList = {}
StaticPopupDialogs = {}
StaticPopup_Show = function() end
UISpecialFrames = {}
GetCursorPosition = function() return 0, 0 end

-- Stock 1.12 unit API: a GUID is NOT a valid unit token here, which is
-- exactly the point -- that is what SuperWoW adds.
UnitName = function(u)
  if u == "player" then return "Solo" end
  if WORLD[u] and HAVE_SUPER then return WORLD[u].name end
  return nil
end
UnitClass = function(u)
  if u == "player" then return "Warrior", "WARRIOR" end
  if WORLD[u] and HAVE_SUPER then return WORLD[u].class, WORLD[u].class end
  return nil, nil
end
UnitLevel = function() return 60 end
UnitHealth = function(u) local d = WORLD[u] return (d and HAVE_SUPER) and d.health or 0 end
UnitHealthMax = function(u) local d = WORLD[u] return (d and HAVE_SUPER) and d.maxHealth or 0 end
UnitIsPlayer = function(u) local d = WORLD[u] return (d and HAVE_SUPER and d.isPlayer) and 1 or 0 end
UnitIsUnit = function(a, b) return a == b end
UnitCanCooperate = function() return 1 end
UnitExists = function(u) return WORLD[u] ~= nil, u end
UnitAffectingCombat = function() return true end

GetRealZoneText = function() return "Onyxia's Lair" end
GetRealmName = function() return "Testrealm" end
IsInInstance = function() return 1, "raid" end
IsInGuild = function() return 1 end
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end
GetItemInfo = function() return nil end
SetCVar = function() end
GetCVar = function() return "0" end
GetAddOnMetadata = function() return "0.1.0" end
GetLocale = function() return "enUS" end
GetBuildInfo = function() return "1.12.1", "5875", "2006" end
SendChatMessage = function() end
SendAddonMessage = function() end

-- SuperWoW
if HAVE_SUPER then
  SpellInfo = function(id) return "Spell " .. tostring(id) end
  GetUnitGUID = function(tok)
    local b = string.gsub(tok, "owner$", "")
    if b == tok then return nil end
    local d = WORLD[b] return d and d.owner
  end
  GetUnitData = function(g) return WORLD[g] and true or nil end
  GetUnitField = function() return "" end
end

-- Nampower
if HAVE_NAM then
  WriteCustomFile = function(n, c, m)
    if m == "a" then DISK[n] = (DISK[n] or "") .. c else DISK[n] = c end
    return true
  end
  ReadCustomFile = function(n) return DISK[n] end
  CustomFileExists = function(n) return DISK[n] ~= nil end
end

----------------------------------------------------------------------

local function tocFiles()
  local out = {}
  for line in io.lines("Wrekkit.toc") do
    line = (string.gsub(line, "\r", ""))
    line = (string.gsub(line, "\\", "/"))
    if line ~= "" and not string.find(line, "^##") and string.find(line, "%.lua$") then
      table.insert(out, line)
    end
  end
  return out
end

local results = {}
local function note(label, ok, detail)
  table.insert(results, { label = label, ok = ok, detail = detail })
end

print("\nWrekkit degraded-mode check :: " .. scenario)
print(string.format("  SuperWoW %s    Nampower %s\n",
  HAVE_SUPER and "present" or "MISSING", HAVE_NAM and "present" or "MISSING"))

----------------------------------------------------------------------
-- load
----------------------------------------------------------------------

local loadOk = true
for _, file in ipairs(tocFiles()) do
  local ok, err = pcall(dofile, file)
  if not ok then
    loadOk = false
    print("  LOAD FAIL " .. file .. ": " .. tostring(err))
  end
end
note("addon loads", loadOk)

if not loadOk then
  print("\n  cannot continue\n")
  os.exit(1)
end

local W = Wrekkit

----------------------------------------------------------------------
-- start up and record
----------------------------------------------------------------------

note("initialises", pcall(function()
  WrekkitDB = nil
  W.InitDB()
  W.capture:Start()
  W.sync:Start()
end))

-- What does the addon itself say is missing?
local missing = {}
pcall(function() missing = W.capture:CheckEnvironment() end)
note("reports what is missing", table.getn(missing) > 0 or (HAVE_SUPER and HAVE_NAM),
  table.getn(missing) > 0 and table.concat(missing, ", ") or "nothing missing")

--[[ Nampower is what emits the combat events. Without it they simply never
     fire, so the honest simulation of "no Nampower" is to dispatch nothing
     at all -- not to dispatch events a client without Nampower could never
     produce. ]]
WORLD["0xA"] = { name = "Fuff", class = "ROGUE", isPlayer = true, maxHealth = 3000, health = 3000 }
WORLD["0xBoss"] = { name = "Onyxia", isPlayer = false, maxHealth = 100000, health = 100000 }

local recorded = false
pcall(function()
  if HAVE_NAM then
    local D = W.capture.dispatch
    W.encounter:CombatStart()
    for _ = 1, 20 do
      D.AUTO_ATTACK_SELF("0xA", "0xBoss", 300, 2, 0, 1, 0, 0, 0)
      D.SPELL_DAMAGE_EVENT_SELF("0xBoss", "0xA", 11267, 500, "0,0,0", 0, 0)
      NOW = NOW + 1
    end
    W.encounter:CombatEnd()
    W.encounter:Finish()
  end
  recorded = table.getn(W.db.encounters) > 0
end)
note("records combat", recorded,
  HAVE_NAM and "" or "no combat events without Nampower")

-- Are the numbers attributable to a named player?
local named, classed = false, false
if recorded then
  pcall(function()
    local view = W.report:View(W.db.encounters, { petMode = "merge" })
    local rows = W.report:Rank(view, "damage")
    for _, r in ipairs(rows) do
      if r.name and r.name ~= "?" then named = true end
      if r.class and r.class ~= "UNKNOWN" then classed = true end
    end
  end)
end
note("attributes damage to a NAME", named,
  (recorded and not named) and "rows exist but are unidentified" or "")
note("knows each player's CLASS", classed)

-- Spell names in the drilldown
local spellNamed = false
if recorded then
  pcall(function()
    local view = W.report:View(W.db.encounters, { petMode = "merge" })
    local rows = W.report:Rank(view, "damage")
    if rows[1] then
      local ab = W.report:Abilities(rows[1], "damage")
      for _, a in ipairs(ab) do
        if a.name and not string.find(a.name, "^Spell %d") then spellNamed = true end
      end
    end
  end)
end
note("resolves spell names", spellNamed or not recorded,
  (recorded and not spellNamed) and "abilities show as 'Spell <id>'" or "")

----------------------------------------------------------------------
-- UI and the rest
----------------------------------------------------------------------

note("both windows build", pcall(function()
  W.ui.meter:Show()
  W.ui.meter:Refresh()
  W.ui.report:Show()
  for _, t in ipairs(W.ui.report.tabs) do
    W.ui.report.state.tab = t.key
    W.ui.report:Refresh()
  end
  W.ui.report.state.tab = "summary"
  W.ui.report:Refresh()
  W.ui.settings:Show()
  W.minimap:Update()
end))

note("every slash command runs", pcall(function()
  local run = SlashCmdList["WREKKIT"]
  for _, c in ipairs({ "", "help", "status", "who", "report", "config",
                       "compact", "mode dps", "segment overall", "save",
                       "load", "keep", "prune 30", "reset", "share guild",
                       "announce guild", "group", "world", "lock" }) do
    run(c)
  end
end))

local journal = false
pcall(function() journal = W.store:Available() and W.store:Save() end)
note("writes the crash journal", journal,
  HAVE_NAM and "" or "no file API; SavedVariables only")

note("SavedVariables still hold history",
  recorded and table.getn(W.db.encounters) > 0)

----------------------------------------------------------------------

print("  capability                        result")
print("  " .. string.rep("-", 56))
for _, r in ipairs(results) do
  print(string.format("  %-32s  %-4s %s",
    r.label, r.ok and "yes" or "NO", r.detail or ""))
end

local fatal = false
for _, r in ipairs(results) do
  if (r.label == "addon loads" or r.label == "initialises"
      or r.label == "both windows build"
      or r.label == "every slash command runs") and not r.ok then
    fatal = true
  end
end

print("")
if fatal then
  print("  VERDICT: broken -- the addon errors in this configuration\n")
  os.exit(1)
elseif not recorded then
  print("  VERDICT: loads and runs cleanly, but records NOTHING\n")
else
  print("  VERDICT: usable\n")
end

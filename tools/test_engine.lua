--[[ test_engine.lua - runs Wrekkit's capture/aggregation offline

    lua tools/test_engine.lua            (from the addon root)

The real client can't be scripted from here, so this stubs the slice of the
1.12 + SuperWoW + nampower API the engine touches, replays a synthetic raid
through the same dispatch table the addon registers in-game, and asserts the
rollups. It catches the failure mode that costs the most time to find by
reloading in-game: argument order. Swings are source-first while spell damage
and heals are target-first, so a transposition shows up here as damage landing
on the healer rather than as an obvious error.
]]

package.path = "./?.lua;" .. package.path

----------------------------------------------------------------------
-- Lua 5.0 shims
----------------------------------------------------------------------

--[[ The addon must call the 5.0 spellings because that is what 1.12 ships,
     but 5.4 removed them. Restore them here rather than letting the addon
     drift toward 5.4-only syntax that would load fine in this harness and
     then fail in the client. vanilla_lint.lua enforces the same rule from
     the other direction. ]]

math.mod = math.mod or math.fmod
string.gfind = string.gfind or string.gmatch
table.getn = table.getn or function(t) return #t end
table.setn = table.setn or function() end
unpack = unpack or table.unpack

----------------------------------------------------------------------
-- clock
----------------------------------------------------------------------

local NOW = 1000.0
local function advance(dt) NOW = NOW + dt end

GetTime = function() return NOW end
time = function() return 1700000000 + math.floor(NOW) end
date = function(fmt) return "13.09.26 15:00:00" end

----------------------------------------------------------------------
-- world
----------------------------------------------------------------------

-- guid -> definition
local WORLD = {}

local function defPlayer(guid, name, class, maxHP)
  WORLD[guid] = { name = name, class = class, isPlayer = true,
                  maxHealth = maxHP or 4000, health = maxHP or 4000 }
end
local function defPet(guid, name, owner, maxHP)
  WORLD[guid] = { name = name, isPlayer = false, owner = owner,
                  maxHealth = maxHP or 2000, health = maxHP or 2000 }
end
local function defNPC(guid, name, maxHP, rank)
  WORLD[guid] = { name = name, isPlayer = false,
                  maxHealth = maxHP or 100000, health = maxHP or 100000,
                  rank = rank }
end

----------------------------------------------------------------------
-- API stubs
----------------------------------------------------------------------

GetUnitData = function(guid) return WORLD[guid] and true or nil end
-- SuperWoW lets a GUID stand in for a unit token, which is what the addon
-- relies on to ask whether a thing was a boss.
UnitClassification = function(guid)
  local d = WORLD[guid]
  return (d and d.rank) or "normal"
end
UnitName = function(u) local d = WORLD[u] return d and d.name end
UnitIsPlayer = function(u) local d = WORLD[u] return (d and d.isPlayer) and 1 or 0 end
UnitClass = function(u)
  local d = WORLD[u]
  if not d then return nil, nil end
  if u == "player" then return "Warrior", "WARRIOR" end
  return d.class and string.lower(d.class), d.class
end
UnitLevel = function(u) return 60 end
UnitHealth = function(u) local d = WORLD[u] return d and d.health or 0 end
UnitHealthMax = function(u) local d = WORLD[u] return d and d.maxHealth or 0 end
UnitIsUnit = function(a, b) return a == b end
UnitCanCooperate = function() return 1 end
UnitExists = function(u) return WORLD[u] ~= nil, u end
GetUnitGUID = function(token)
  local base = string.gsub(token, "owner$", "")
  if base == token then return nil end
  local d = WORLD[base]
  return d and d.owner or nil
end
GetUnitField = function() return "" end

SpellInfo = function(id)
  local names = {
    [11267] = "Sinister Strike", [25231] = "Cleave", [10201] = "Flash Heal",
    [25213] = "Healing Wave", [20647] = "Execute", [10444] = "Flametongue",
    [1766] = "Kick",
  }
  -- SpellInfo returns name, RANK, texture -- confirmed against BigWigs and
  -- ShaguPlates, which both destructure it that way. Two ids for the same
  -- spell is the case that used to make every rank read identically.
  local ranks = { [11661] = "Rank 10", [11660] = "Rank 9" }
  if ranks[id] then return "Shadow Bolt", ranks[id], "Interface\\Icons\\Temp" end
  return names[id] or ("Spell " .. tostring(id)), nil, "Interface\\Icons\\Temp"
end

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
CVARS = {}
SetCVar = function(k, v) CVARS[k] = v end
GetCVar = function(k) return CVARS[k] or "1" end
IsInInstance = function() return true, "raid" end

-- Saved-instance lockout. SAVED_ID is what the server hands out per reset;
-- two raids sharing it are the same raid however many days apart.
SAVED_ID = 4471
GetNumSavedInstances = function() return 1 end
GetSavedInstanceInfo = function(i)
  if i == 1 then return "Onyxia's Lair", SAVED_ID end
  return nil
end
IsInGuild = function() return 1 end
GetAddOnMetadata = function() return "test" end
GetLocale = function() return "enUS" end
GetBuildInfo = function() return "1.12.1", "5875", "2006" end

DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("  [chat] " .. m) end }

-- Frames: the engine only needs event registration and script slots.
local frames = {}
CreateFrame = function(kind, name)
  local f = {
    _scripts = {}, _events = {},
    SetScript = function(self, k, fn) self._scripts[k] = fn end,
    GetScript = function(self, k) return self._scripts[k] end,
    RegisterEvent = function(self, e) self._events[e] = true end,
    UnregisterEvent = function(self, e) self._events[e] = nil end,
    Show = function() end, Hide = function() end,
    SetWidth = function() end, SetHeight = function() end,
    SetPoint = function() end,
  }
  table.insert(frames, f)
  if name then _G[name] = f end
  return f
end

_G = _G or getfenv(0)

----------------------------------------------------------------------
-- load the addon (order matches the .toc)
----------------------------------------------------------------------

-- Nampower's file API, backed by a table so save/load can be round-tripped.
DISK = {}
WriteCustomFile = function(name, content, mode)
  if mode == "a" then DISK[name] = (DISK[name] or "") .. content
  else DISK[name] = content end
  return true
end
ReadCustomFile = function(name) return DISK[name] end
CustomFileExists = function(name) return DISK[name] ~= nil end

-- Addon channel, captured rather than sent.
WIRE = {}
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
  table.insert(WIRE, { prefix = prefix, msg = msg, channel = channel, target = target })
end
SendChatMessage = function(msg) table.insert(WIRE, { chat = msg }) end

dofile("core.lua")
dofile("capture.lua")
dofile("encounter.lua")
dofile("metrics.lua")
dofile("report.lua")
dofile("diagnostics.lua")
dofile("store.lua")
dofile("sync.lua")
dofile("announce.lua")

WrekkitDB = nil
Wrekkit.InitDB()
Wrekkit.capture:Start()

----------------------------------------------------------------------
-- event replay
----------------------------------------------------------------------

local D = Wrekkit.capture.dispatch

local function fire(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
  local h = D[event]
  if h then h(a1, a2, a3, a4, a5, a6, a7, a8, a9) return end
  if event == "PLAYER_REGEN_DISABLED" then Wrekkit.encounter:CombatStart()
  elseif event == "PLAYER_REGEN_ENABLED" then Wrekkit.encounter:CombatEnd() end
end

----------------------------------------------------------------------
-- assertions
----------------------------------------------------------------------

local pass, fail = 0, 0

local function check(label, got, want, tol)
  tol = tol or 0
  local ok
  if type(want) == "number" then
    ok = math.abs((got or 0) - want) <= tol
  else
    ok = (got == want)
  end
  if ok then
    pass = pass + 1
    print(string.format("  ok    %-46s %s", label, tostring(got)))
  else
    fail = fail + 1
    print(string.format("  FAIL  %-46s got %s want %s",
      label, tostring(got), tostring(want)))
  end
end

----------------------------------------------------------------------
-- scenario
----------------------------------------------------------------------

print("\nWrekkit engine test\n")

defPlayer("0xP1", "Fuff", "ROGUE", 3000)
defPlayer("0xP2", "Elfpriest", "PRIEST", 2600)
defPlayer("0xP3", "Moorhunt", "HUNTER", 3400)

-- In the client UnitName("player") is never nil, and the sync address filter
-- relies on that. The stub has to say who we are, or it is testing a state
-- the game cannot be in.
WORLD["player"] = WORLD["0xP1"]

defPet("0xPet1", "Raptor", "0xP3", 1800)
defNPC("0xBoss", "Onyxia", 1200000)
defNPC("0xAdd", "Onyxian Whelp", 4000)

print("-- pull --")
fire("PLAYER_REGEN_DISABLED")

-- Rogue hits the boss: swings are (attacker, target, dmg, hitInfo, ...).
-- hitInfo is the raw HitInfo bitfield, so realistic values matter here:
-- 0x02 (AFFECTS_VICTIM) is set on every landed swing and 0x200 is the crit.
-- Using 0 and 2 as "normal" and "crit" -- as this test originally did --
-- hides a reversed crit test completely.
local HIT_NORMAL = 2            -- 0x002 AFFECTS_VICTIM
local HIT_CRIT   = 2 + 512      -- 0x202 AFFECTS_VICTIM | CRITICALHIT

fire("AUTO_ATTACK_SELF", "0xP1", "0xBoss", 300, HIT_NORMAL, 0, 1, 0, 0, 0)
advance(1)
fire("AUTO_ATTACK_SELF", "0xP1", "0xBoss", 700, HIT_CRIT, 0, 1, 0, 0, 0)
-- Spell damage is (target, caster, spellId, amount, mitigation, hitInfo, school)
fire("SPELL_DAMAGE_EVENT_SELF", "0xBoss", "0xP1", 11267, 500, "0,0,0", 0, 0)
advance(1)

-- Pet damage should roll up under its owner when pets are merged.
fire("AUTO_ATTACK_OTHER", "0xPet1", "0xBoss", 250, HIT_NORMAL, 0, 1, 0, 0, 0)
fire("AUTO_ATTACK_OTHER", "0xP3", "0xBoss", 400, HIT_NORMAL, 0, 1, 0, 0, 0)
advance(1)

-- Boss hits the rogue for 1000; 200 of it absorbed. Health is tracked from
-- the event itself, so the harness does not fake UnitHealth here.
fire("SPELL_DAMAGE_EVENT_OTHER", "0xP1", "0xBoss", 25231, 1000, "200,0,0", 0, 0)
advance(1)

-- Priest heals the rogue for 800 into a 1000 deficit: all effective.
fire("SPELL_HEAL_BY_OTHER", "0xP1", "0xP2", 10201, 800, 0, 0)
advance(1)

-- Heals for 900 into a 200 deficit: 200 effective, 700 overheal.
fire("SPELL_HEAL_BY_OTHER", "0xP1", "0xP2", 10201, 900, 1, 0)
advance(1)

-- An add dies, then the rogue dies.
fire("AUTO_ATTACK_SELF", "0xP1", "0xAdd", 4000, HIT_NORMAL, 0, 1, 0, 0, 0)
fire("UNIT_DIED", "0xAdd")
advance(2)
fire("UNIT_DIED", "0xP1")

advance(1)
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

----------------------------------------------------------------------

print("\n-- stored --")
local stored = Wrekkit.db.encounters
check("encounters persisted", table.getn(stored), 1)

local enc = stored[1]
check("encounter name", enc.name, "Onyxia")
check("registered a kill", enc.kill, true)

local view = Wrekkit.report:View({ enc }, { petMode = "merge" })

print("\n-- damage (pets merged into owner) --")
local rows, metric, total = Wrekkit.report:Rank(view, "damage")
for _, r in ipairs(rows) do
  print(string.format("  #%d %-12s %8s  %6.2f%%  %s",
    r._rank, r.name, r._text, r._pct, r._sub))
end

local byName = {}
for _, r in ipairs(rows) do byName[r.name] = r end

check("Fuff damage", byName["Fuff"] and byName["Fuff"].damage, 300 + 700 + 500 + 4000)
check("Moorhunt damage incl. pet", byName["Moorhunt"] and byName["Moorhunt"].damage, 400 + 250)
check("raid damage total", view.totals.damage, 300 + 700 + 500 + 250 + 400 + 4000)

print("\n-- healing --")
local hrows = Wrekkit.report:Rank(view, "healing")
for _, r in ipairs(hrows) do
  print(string.format("  #%d %-12s %8s  %s", r._rank, r.name, r._text, r._sub))
end
local priest = nil
for _, r in ipairs(hrows) do if r.name == "Elfpriest" then priest = r end end
check("effective healing", priest and priest.healing, 800 + 200)
check("overhealing", priest and priest.overheal, 700)

print("\n-- damage taken --")
local trows = Wrekkit.report:Rank(view, "taken")
for _, r in ipairs(trows) do
  print(string.format("  #%d %-12s %8s  %s", r._rank, r.name, r._text, r._sub))
end
local fuffTaken = nil
for _, r in ipairs(trows) do if r.name == "Fuff" then fuffTaken = r end end
check("Fuff damage taken", fuffTaken and fuffTaken.taken, 1000)

print("\n-- enemies --")
local erows = Wrekkit.report:Rank(view, "enemy")
for _, r in ipairs(erows) do
  print(string.format("  #%d %-16s %8s", r._rank, r.name, r._text))
end
check("enemy row count", table.getn(erows), 1)

print("\n-- pets kept separate --")
local sepView = Wrekkit.report:View({ enc }, { petMode = "separate" })
local srows = Wrekkit.report:Rank(sepView, "damage")
local foundPet = false
for _, r in ipairs(srows) do
  if string.find(r.name, "Raptor", 1, true) then foundPet = true end
end
check("pet has its own row", foundPet, true)

print("\n-- deaths --")
check("player deaths recorded", table.getn(enc.deaths), 1)
check("death is the rogue", enc.deaths[1] and enc.deaths[1].name, "Fuff")

print("\n-- abilities --")
local abil = Wrekkit.report:Abilities(byName["Fuff"], "damage")
for _, a in ipairs(abil) do
  print(string.format("  %-18s %8s  %dx  avg %.0f  crit %.0f%%",
    a.name, Wrekkit.Short(a.amount), a.hits, a._avg, a._critPct))
end
check("melee and spell split out", table.getn(abil) >= 2, true)

print("\n-- timeline --")
local series, n, peak = Wrekkit.report:Series({ enc }, 3)
check("series has samples", n > 0, true)
check("peak is positive", peak > 0, true)
print(string.format("  %d samples, peak %.0f", n, peak))

print("\n-- filters --")
local fRows = Wrekkit.report:Rank(view, "damage", { search = "fuf" })
check("name search narrows to one", table.getn(fRows), 1)
local cRows = Wrekkit.report:Rank(view, "damage", { classes = { HUNTER = true } })
check("class filter narrows", table.getn(cRows), 1)

----------------------------------------------------------------------
-- ability detail
----------------------------------------------------------------------

print("\n-- ability detail --")

local melee
for _, a in ipairs(abil) do if a.name == "Melee" then melee = a end end

-- Fuff's melee was 300, a 700 crit, and a 4000 finisher on the add.
check("melee landed three times", melee and melee.hits, 3)
check("one of them crit", melee and melee.crits, 1)
check("largest is the finisher", melee and melee.max, 4000)
check("smallest is the opener", melee and melee.min, 300)
check("crit amount tracked apart", melee and melee.critAmount, 700)

-- The regression that started this: 0x02 is AFFECTS_VICTIM, set on every
-- landed swing. Testing it as the crit bit reported 100% melee crit.
check("plain swings are not crits", melee and (melee.hits - melee.crits), 2)
check("crit rate is not 100%",
  melee and (melee.crits / melee.hits) < 1, true)

local stats = Wrekkit.report:AbilityStats(melee, "damage")
for _, s in ipairs(stats) do
  print(string.format("  %-18s %12s %s", s.label, s.value, s.note or ""))
end

local statBy = {}
for _, s in ipairs(stats) do statBy[s.label] = s.value end
check("total line", statBy["Total"], "5,000")
check("average is blended", statBy["Average"], "1,666")
check("average normal excludes the crit", statBy["Average normal"], "2,150")
check("average crit is the crit alone", statBy["Average crit"], "700")
check("largest reported", statBy["Largest"], "4,000")
check("smallest reported", statBy["Smallest"], "300")

-- Healing spread is measured on raw output, not the effective part.
local healAbil = Wrekkit.report:Abilities(priest, "healing")
local flash = healAbil[1]
check("heal counted both casts", flash and flash.hits, 2)
check("heal max is the raw 900", flash and flash.max, 900)

----------------------------------------------------------------------
-- group filter
----------------------------------------------------------------------

print("\n-- group filter --")

-- Only Fuff and Elfpriest are grouped with us; Moorhunt is a passer-by.
Wrekkit.capture.groupMembers = { Fuff = true, Elfpriest = true }

local allRows = Wrekkit.report:Rank(view, "damage")
local grpRows = Wrekkit.report:Rank(view, "damage", { groupOnly = true })
check("ungrouped view has everyone", table.getn(allRows) >= 2, true)

local sawOutsider = false
for _, r in ipairs(grpRows) do
  if r.name == "Moorhunt" then sawOutsider = true end
end
check("outsider filtered out", sawOutsider, false)
check("group member kept", (function()
  for _, r in ipairs(grpRows) do if r.name == "Fuff" then return true end end
  return false
end)(), true)

-- Enemies must survive the filter, or the Enemies tab empties itself.
local enemyRows = Wrekkit.report:Rank(view, "enemy", { groupOnly = true })
check("enemies are not group-filtered", table.getn(enemyRows) > 0, true)

Wrekkit.capture.groupMembers = {}

----------------------------------------------------------------------
-- consumables
----------------------------------------------------------------------

print("\n-- consumables --")

--[[ SPELL_GO carries the item that triggered a cast as its FIRST argument:
     zero for an ordinary spell, non-zero for a potion, elixir, flask,
     scroll, bandage or food. That one field is the entire tracker, so the
     test that matters is that a zero itemId is ignored. ]]
Wrekkit.encounter.live = enc          -- re-open the finished pull
fire("SPELL_GO_SELF", 13446, 11390, "0xP1", "0xP1")   -- a potion, twice
fire("SPELL_GO_SELF", 13446, 11390, "0xP1", "0xP1")
fire("SPELL_GO_SELF", 20520, 24707, "0xP1", "0xP1")   -- a different item
fire("SPELL_GO_SELF", 0, 11267, "0xP1", "0xBoss")     -- a plain spell cast
fire("SPELL_GO_OTHER", 13446, 11390, "0xP2", "0xP2")  -- someone else's potion
Wrekkit.encounter.live = nil

local consView = Wrekkit.report:View({ enc }, { petMode = "merge" })
local consRows, consMetric = Wrekkit.report:Rank(consView, "consumes")
local consBy = {}
for _, r in ipairs(consRows) do consBy[r.name] = r end

for _, r in ipairs(consRows) do
  print(string.format("  %-12s %d used", r.name, r.consumes))
end

check("counted three items for the rogue", consBy["Fuff"] and consBy["Fuff"].consumes, 3)
check("and one for the priest", consBy["Elfpriest"] and consBy["Elfpriest"].consumes, 1)
check("a plain spell cast is NOT a consumable",
  consBy["Fuff"] and consBy["Fuff"].consumes ~= 4, true)

-- The drilldown separates them by item, not one lumped total.
local consDetail = Wrekkit.report:Abilities(consBy["Fuff"], "consumes")
for _, a in ipairs(consDetail) do
  print(string.format("    %-24s x%d", a.name, a.amount))
end
check("two distinct items", table.getn(consDetail), 2)
check("the repeated one is counted twice", consDetail[1].amount, 2)

----------------------------------------------------------------------
-- combat time cannot run away
----------------------------------------------------------------------

print("\n-- stuck combat --")

--[[ inCombat is our own flag, set on PLAYER_REGEN_DISABLED. If its partner
     event is ever missed the flag sticks, and CombatTime then extrapolates
     from combatMark forever -- a meter sitting in a city counting combat
     time upward, which is exactly what was reported. ]]
Wrekkit.encounter:CombatStart()
local stuck = Wrekkit.encounter.live
advance(10)
check("combat time accrues while fighting",
  Wrekkit.encounter:CombatTime(stuck) >= 10, true)

-- Now the client says combat is over but the event never arrived.
IN_COMBAT = false
local frozen = Wrekkit.encounter:CombatTime(stuck)
advance(600)
check("it stops accruing once the client says we are out",
  Wrekkit.encounter:CombatTime(stuck), frozen, 0.01)

-- ...and the ticker closes the segment rather than leaving it half-open.
Wrekkit.encounter:HealStuckCombat()
check("the stuck flag was cleared", Wrekkit.encounter.inCombat, false)

IN_COMBAT = true
Wrekkit.encounter.live = nil
Wrekkit.encounter.inCombat = false

----------------------------------------------------------------------
-- announce
----------------------------------------------------------------------

print("\n-- announce --")

local ctx = {
  metric = "damage",
  encounters = { enc },
  label = "Onyxia",
  filter = {},
  petMode = "merge",
}

local aLines = Wrekkit.announce:Lines(ctx, 3)
for _, l in ipairs(aLines) do print("  | " .. l) end

check("has a header plus rows", table.getn(aLines) >= 2, true)
check("header names the metric and segment",
  string.find(aLines[1], "Damage Done", 1, true) ~= nil
  and string.find(aLines[1], "Onyxia", 1, true) ~= nil, true)
check("first row is the top damage dealer",
  string.find(aLines[2], "Fuff", 1, true) ~= nil, true)

-- Every line has to survive the chat length limit.
check("no line exceeds chat's limit", (function()
  for _, l in ipairs(aLines) do
    if string.len(l) > 255 then return false end
  end
  return true
end)(), true)

-- A filtered post must say so, or a partial top-N reads as the whole raid.
local filtered = Wrekkit.announce:Lines(
  { metric = "damage", encounters = { enc }, label = "Onyxia",
    filter = { groupOnly = true }, petMode = "merge" }, 3)
check("filters are disclosed in the header",
  string.find(filtered[1], "group only", 1, true) ~= nil, true)

-- The report's Summary shows two panels, so it announces both.
local twin = Wrekkit.announce:Lines(
  { metrics = { "damage", "healing" }, encounters = { enc },
    label = "Onyxia", filter = {}, petMode = "merge" }, 2)
local headers = 0
for _, l in ipairs(twin) do
  if string.find(l, "^Wrekkit  ") then headers = headers + 1 end
end
check("two metrics produce two sections", headers, 2)

-- Nothing reaches chat without the dialog.
WIRE = {}
local sentAnyway = false
local realPrint = Wrekkit.Print
Wrekkit.Print = function() end
Wrekkit.ui = nil
Wrekkit.announce:Request(ctx, "RAID", nil, 3)
Wrekkit.Print = realPrint
for _, m in ipairs(WIRE) do if m.chat then sentAnyway = true end end
check("no confirmation dialog means nothing is sent", sentAnyway, false)

-- ...and confirming does send, paced one line at a time.
WIRE = {}
local queued = Wrekkit.announce:Send(aLines, "PARTY")
check("send queues every line", queued, table.getn(aLines))
check("but posts them gradually, not all at once",
  table.getn(WIRE) < queued, true)

-- Drain the pacing queue by hand.
while table.getn(Wrekkit.announce.queue) > 0 do
  local job = table.remove(Wrekkit.announce.queue, 1)
  SendChatMessage(job.msg, job.channel, nil, job.target)
end
check("all of them arrive eventually",
  table.getn(WIRE) >= queued - 1, true)

check("a whisper with no name is refused",
  Wrekkit.announce:Send(aLines, "WHISPER", nil), 0)

----------------------------------------------------------------------
-- peer browsing
----------------------------------------------------------------------

print("\n-- peer browsing --")

--[==[ The sections below add encounters -- a borrowed one, then a pulled
       copy -- to exercise the browser. Snapshot the history first and put it
       back afterwards, or every later section inherits them and starts
       asserting against doubled numbers. ]==]
local historyBefore = {}
for i, e in ipairs(Wrekkit.db.encounters) do historyBefore[i] = e end

Wrekkit.db.shareEnabled = true
Wrekkit.db.shareChannel = "GUILD"

-- The index is what the browser lists before anything is transferred.
local idxBody = Wrekkit.sync:EncodeIndex()
check("index is not empty", string.len(idxBody) > 0, true)

local decoded = Wrekkit.sync:DecodeIndex(idxBody)
check("index round-trips", table.getn(decoded) > 0, true)
check("entries carry a key", decoded[1] and decoded[1].key ~= nil, true)
check("entries carry a name", decoded[1] and decoded[1].name, enc.name)

-- The key has to match what a pull request would ask for.
check("key matches the encounter", decoded[1].key, Wrekkit.sync:Key(enc))

-- Someone else's logs are never offered back to the network.
local borrowed = {
  id = 99, sessionId = "sync:Bob", name = "Borrowed", zone = "Z",
  startTime = time(), duration = 10, combat = 10, sharedBy = "Bob",
  totals = { damage = 1 }, actors = {}, deaths = {}, bucket = {}, maxBucket = 0,
}
table.insert(Wrekkit.db.encounters, borrowed)
local idx2 = Wrekkit.sync:DecodeIndex(Wrekkit.sync:EncodeIndex())
local offeredBorrowed = false
for _, e in ipairs(idx2) do
  if e.name == "Borrowed" then offeredBorrowed = true end
end
check("a borrowed log is not re-offered", offeredBorrowed, false)

----------------------------------------------------------------------
-- sharing is opt-in
----------------------------------------------------------------------

print("\n-- sharing gate --")

local function resetWire()
  WIRE = {}
  Wrekkit.sync.queue = {}
  Wrekkit.sync.pumping = false
end

--- Messages the addon produced: those already dispatched by the pump plus
--- those still waiting behind it.
local function produced()
  local n = table.getn(WIRE) + table.getn(Wrekkit.sync.queue)
  resetWire()
  return n
end

local me = UnitName("player")

resetWire()
Wrekkit.db.shareEnabled = false
Wrekkit.sync:OnMessage("WREKKIT", "L~" .. me, "GUILD", "Nosy")
check("index request refused when sharing is off", produced(), 0)

Wrekkit.sync:OnMessage("WREKKIT", "G~" .. me .. "~" .. Wrekkit.sync:Key(enc), "GUILD", "Nosy")
check("log request refused when sharing is off", produced(), 0)

Wrekkit.sync:Announce("GUILD")
check("presence is not broadcast when sharing is off", produced(), 0)

Wrekkit.db.shareEnabled = true
Wrekkit.sync:OnMessage("WREKKIT", "L~" .. me, "GUILD", "Nosy")
check("index request answered when sharing is on", produced() > 0, true)

Wrekkit.sync:Announce("GUILD")
check("presence is broadcast when sharing is on", produced(), 1)

-- Addressing: every message is a broadcast, so the filter is the only thing
-- stopping ten raiders from all answering one person s request.
Wrekkit.sync:OnMessage("WREKKIT", "L~SomeoneElse", "GUILD", "Nosy")
check("index request for another player ignored", produced(), 0)

Wrekkit.sync:OnMessage("WREKKIT", "G~SomeoneElse~" .. Wrekkit.sync:Key(enc), "GUILD", "Nosy")
check("log request for another player ignored", produced(), 0)

-- Our own broadcast comes back to us; answering it would loop.
Wrekkit.sync:OnMessage("WREKKIT", "L~" .. me, "GUILD", me)
check("our own request is not answered", produced(), 0)

----------------------------------------------------------------------
-- channel resolution
----------------------------------------------------------------------

print("\n-- channel --")

local realRaid, realParty = GetNumRaidMembers, GetNumPartyMembers
Wrekkit.db.shareChannel = "RAID"
GetNumRaidMembers = function() return 0 end
check("raid refused while not in a raid", Wrekkit.sync:ActiveChannel(), nil)
GetNumRaidMembers = function() return 25 end
check("raid used while in one", Wrekkit.sync:ActiveChannel(), "RAID")

Wrekkit.db.shareChannel = "AUTO"
check("auto prefers raid", Wrekkit.sync:ActiveChannel(), "RAID")
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 4 end
check("auto falls back to party", Wrekkit.sync:ActiveChannel(), "PARTY")
GetNumPartyMembers = function() return 0 end
check("auto falls back to guild", Wrekkit.sync:ActiveChannel(), "GUILD")

GetNumRaidMembers, GetNumPartyMembers = realRaid, realParty

----------------------------------------------------------------------
-- pulling the same log twice
----------------------------------------------------------------------

print("\n-- duplicate pull --")

WIRE = {}
Wrekkit.db.shareEnabled = true
Wrekkit.sync:Share(enc, "Receiver", "GUILD")
while table.getn(Wrekkit.sync.queue) > 0 do
  local job = table.remove(Wrekkit.sync.queue, 1)
  SendAddonMessage("WREKKIT", job.msg, job.channel, job.target)
end

local realName = UnitName
UnitName = function(u) if u == "player" then return "Receiver" end return realName(u) end
local quietPrint = Wrekkit.Print
Wrekkit.Print = function() end

local before = table.getn(Wrekkit.db.encounters)
for _, m in ipairs(WIRE) do
  Wrekkit.sync:OnMessage(m.prefix, m.msg, m.channel, "Someone")
end
local afterFirst = table.getn(Wrekkit.db.encounters)

-- Pull the identical log again: it must replace, not accumulate.
for _, m in ipairs(WIRE) do
  Wrekkit.sync:OnMessage(m.prefix, m.msg, m.channel, "Someone")
end
local afterSecond = table.getn(Wrekkit.db.encounters)

Wrekkit.Print = quietPrint
UnitName = realName

check("first pull stored it", afterFirst, before + 1)
check("second pull replaced rather than duplicated", afterSecond, afterFirst)

-- Hand the history back exactly as it was found.
Wrekkit.db.encounters = historyBefore
Wrekkit.db.shareEnabled = false
resetWire()

----------------------------------------------------------------------
-- save file round trip
----------------------------------------------------------------------

print("\n-- save / load --")

check("save wrote a file", Wrekkit.store:Save(), true)

local text = ReadCustomFile(Wrekkit.store:Filename())
check("file starts with the magic", string.sub(text or "", 1, 8), "WREKKIT1")

local reloaded = Wrekkit.store:Deserialize(text)
check("one encounter came back", table.getn(reloaded), 1)

local rView = Wrekkit.report:View(reloaded, { petMode = "merge" })
local rRows = Wrekkit.report:Rank(rView, "damage")
local rByName = {}
for _, r in ipairs(rRows) do rByName[r.name] = r end

-- The lockout id rides in the S~ session header, appended rather than
-- inserted so a file written before it existed still parses.
check("the lockout id survived the round trip",
  (reloaded[1] or {}).instanceId, SAVED_ID)

check("damage survived the round trip",
  rByName["Fuff"] and rByName["Fuff"].damage, 5500)
check("pet still merges after reload",
  rByName["Moorhunt"] and rByName["Moorhunt"].damage, 650)
check("healing survived", (function()
  local h = Wrekkit.report:Rank(rView, "healing")
  for _, r in ipairs(h) do if r.name == "Elfpriest" then return r.healing end end
end)(), 1000)
check("overheal survived", (function()
  local h = Wrekkit.report:Rank(rView, "overheal")
  for _, r in ipairs(h) do if r.name == "Elfpriest" then return r.overheal end end
end)(), 700)
check("deaths survived", table.getn(reloaded[1].deaths), 1)

local rSeries, rn, rpeak = Wrekkit.report:Series(reloaded, 3)
check("timeline survived", rpeak > 0, true)

-- Loading twice must not double the numbers.
Wrekkit.store:Load()
local before = table.getn(Wrekkit.db.encounters)
Wrekkit.store:Load()
check("re-loading does not duplicate", table.getn(Wrekkit.db.encounters), before)

----------------------------------------------------------------------
-- sync round trip
----------------------------------------------------------------------

print("\n-- sync --")

WIRE = {}
local queued = Wrekkit.sync:Share(enc, "*", "RAID")
check("share queued messages", queued > 2, true)

-- Drain the throttled queue by hand; the harness has no frame loop.
while table.getn(Wrekkit.sync.queue) > 0 do
  local job = table.remove(Wrekkit.sync.queue, 1)
  SendAddonMessage("WREKKIT", job.msg, job.channel, job.target)
end

check("every message fits the addon limit", (function()
  for _, m in ipairs(WIRE) do
    if m.msg and string.len(m.msg) > 250 then return false end
  end
  return true
end)(), true)

-- Replay them into a "second client": same code, different player name.
local realName = UnitName
UnitName = function(u) if u == "player" then return "Someone Else" end return realName(u) end

local receivedCount = 0
local originalPrint = Wrekkit.Print
Wrekkit.Print = function(msg) receivedCount = receivedCount + 1 end

Wrekkit.db.encounters = {}
for _, m in ipairs(WIRE) do
  if m.msg then Wrekkit.sync:OnMessage(m.prefix, m.msg, m.channel, "Fuff") end
end
Wrekkit.Print = originalPrint
UnitName = realName

check("receiver stored the encounter", table.getn(Wrekkit.db.encounters), 1)

local sView = Wrekkit.report:View(Wrekkit.db.encounters, { petMode = "merge" })
local sRows = Wrekkit.report:Rank(sView, "damage")
local sByName = {}
for _, r in ipairs(sRows) do sByName[r.name] = r end
for _, r in ipairs(sRows) do
  print(string.format("  %-12s %8s", r.name, r._text))
end
check("shared damage matches the sender",
  sByName["Fuff"] and sByName["Fuff"].damage, 5500)
check("shared pet merged to owner",
  sByName["Moorhunt"] and sByName["Moorhunt"].damage, 650)

----------------------------------------------------------------------
-- session continuity across reload / crash / disconnect
----------------------------------------------------------------------

print("\n-- session continuity --")

-- Start clean: fresh DB, fresh disk.
WrekkitDB = nil
Wrekkit.InitDB()
Wrekkit.encounter.live = nil
Wrekkit.encounter.session = nil
Wrekkit.store.journalSession = nil
DISK = {}
for k in pairs(DISK) do DISK[k] = nil end

--- Record one pull of the given length, through the real combat events --
--- leaving combat is what stamps the encounter's end time, so short-cutting
--- it produces a zero-length encounter that the minimum-duration filter then
--- silently discards.
local function pull(seconds, bossGuid)
  fire("PLAYER_REGEN_DISABLED")
  for i = 1, seconds do
    fire("AUTO_ATTACK_SELF", "0xP1", bossGuid or "0xBoss", 500, 0, 0, 1, 0, 0, 0)
    advance(1)
  end
  fire("PLAYER_REGEN_ENABLED")
  -- The real addon finishes this on a timer; drive it directly here.
  Wrekkit.encounter:Finish()
end

--- Everything a reload destroys: in-memory state, but not SavedVariables.
local function simulateReload()
  Wrekkit.encounter.live = nil
  Wrekkit.encounter.session = nil
  Wrekkit.encounter.inCombat = false
  Wrekkit.store.journalSession = nil
  Wrekkit.capture.units = {}
end

pull(20)
local firstSessionId = Wrekkit.db.encounters[1].sessionId
check("first encounter recorded", table.getn(Wrekkit.db.encounters), 1)

-- Disconnect, five minutes of downtime, come back.
simulateReload()
advance(300)
pull(20)

check("second encounter recorded", table.getn(Wrekkit.db.encounters), 2)
check("session survived the reload",
  Wrekkit.db.encounters[2].sessionId, firstSessionId)
check("encounter ids keep counting", Wrekkit.db.encounters[2].id, 2)
check("offset advanced past the gap",
  Wrekkit.db.encounters[2].offset > Wrekkit.db.encounters[1].offset, true)

local sessions = Wrekkit.report:Sessions()
check("report shows ONE session", table.getn(sessions), 1)
check("with both encounters", table.getn(sessions[1].encounters), 2)

--[[ A new raid, not a continuation.

     This used to be expressed as a gap longer than resumeWindow, which no
     longer says it: inside a lockout a gap means a wipe and a corpse run,
     and the session is meant to survive one. What makes a raid NEW is the
     instance resetting, and the server says so by issuing a new id. ]]
simulateReload()
SAVED_ID = SAVED_ID + 1
advance(Wrekkit.db.resumeWindow + 120)
pull(20)
check("a long gap starts a new session",
  Wrekkit.db.encounters[3].sessionId ~= firstSessionId, true)
check("report now shows two sessions",
  table.getn(Wrekkit.report:Sessions()), 2)

----------------------------------------------------------------------
-- reset starts a new log
----------------------------------------------------------------------

print("\n-- reset starts a new log --")

WrekkitDB = nil
Wrekkit.InitDB()
simulateReload()
DISK[Wrekkit.store:Filename()] = nil

pull(20)
local beforeReset = Wrekkit.db.encounters[1].sessionId
check("logged a pull", table.getn(Wrekkit.db.encounters), 1)

Wrekkit.ResetData()          -- the reset button's left-click
advance(30)                  -- well inside the resume window
pull(20)

check("history was kept", table.getn(Wrekkit.db.encounters), 2)
check("the new pull is a NEW session",
  Wrekkit.db.encounters[2].sessionId ~= beforeReset, true)
check("report still shows both sessions",
  table.getn(Wrekkit.report:Sessions()), 2)

-- The barrier has to beat the resume window, or the two features cancel out.
check("resume did not rejoin across the reset",
  Wrekkit.encounter.session.id ~= beforeReset, true)

-- And the meter must follow the new log, not the newest stored session.
local cur = Wrekkit.report:CurrentSession()
check("current session is the new one", cur and cur.id ~= beforeReset, true)
check("current session holds one pull", cur and table.getn(cur.encounters), 1)

-- Immediately after a reset, with nothing logged since, the meter is empty
-- rather than showing the session that was just closed.
Wrekkit.ResetData()
check("nothing is current right after a reset",
  Wrekkit.report:CurrentSession(), nil)
check("but the history survives", table.getn(Wrekkit.db.encounters), 2)

-- A wipe clears everything and also leaves nothing to resume.
Wrekkit.ResetData("all")
check("reset all empties the history", table.getn(Wrekkit.db.encounters), 0)
check("and nothing is current", Wrekkit.report:CurrentSession(), nil)

-- It must reach the disk too, or the next login's auto-recovery would
-- restore exactly what was just deleted.
local leftover = Wrekkit.store:Deserialize(ReadCustomFile(Wrekkit.store:Filename()) or "")
check("the journal was emptied as well", table.getn(leftover), 0)

----------------------------------------------------------------------
-- keeping and pruning
----------------------------------------------------------------------

print("\n-- keep / prune --")

WrekkitDB = nil
Wrekkit.InitDB()
simulateReload()
DISK[Wrekkit.store:Filename()] = nil

pull(20)                         -- this one gets locked
local keeper = Wrekkit.db.encounters[1]
advance(2000)                    -- past the resume window: a separate session
pull(20)
advance(2000)
pull(20)
check("three encounters recorded", table.getn(Wrekkit.db.encounters), 3)

check("locking reports back", Wrekkit.ToggleLocked(keeper), true)
check("one is locked", Wrekkit.CountLocked(), 1)

-- Pruning everything unlocked must spare it.
local removed, kept, spared = Wrekkit.PruneEncounters(nil)
check("pruned the unlocked ones", removed, 2)
check("kept the locked one", kept, 1)
check("and said so", spared, 1)
check("the survivor is the one we locked",
  Wrekkit.db.encounters[1] and Wrekkit.db.encounters[1].locked, true)

-- The lock has to hold against the nuclear option too, or it means nothing.
Wrekkit.ResetData("all")
check("reset all spares locked encounters", table.getn(Wrekkit.db.encounters), 1)

-- ...and it has to survive a round trip through the file.
local text = ReadCustomFile(Wrekkit.store:Filename())
local reread = Wrekkit.store:Deserialize(text or "")
check("lock flag persisted", reread[1] and reread[1].locked, true)

-- Unlocking then clearing really does remove it.
Wrekkit.ToggleLocked(Wrekkit.db.encounters[1])
check("unlocked again", Wrekkit.CountLocked(), 0)
Wrekkit.ResetData("all")
check("now it is gone", table.getn(Wrekkit.db.encounters), 0)

-- Age-based pruning keeps anything newer than the cutoff.
pull(20)
local r2 = Wrekkit.PruneEncounters(7)
check("a fresh pull is not 7 days old", r2, 0)
check("and is still there", table.getn(Wrekkit.db.encounters), 1)

----------------------------------------------------------------------
-- roster-first classification (cross-faction groups)
----------------------------------------------------------------------

print("\n-- roster beats the unit API --")

--[[ A group member the client cannot resolve -- out of range, or an
     opposite-faction player the faction-aware calls refuse to confirm --
     must still be counted as a player. Before this, UnitIsPlayer returning
     nil dropped them into the enemy table and cached it there forever. ]]
Wrekkit.capture.units = {}
Wrekkit.capture.rosterClass["Ghostly"] = "MAGE"
Wrekkit.capture.groupMembers["Ghostly"] = true

-- Exists by name only: no unit data, and UnitIsPlayer says nothing.
WORLD["0xGhost"] = { name = "Ghostly", isPlayer = false,
                     maxHealth = 2000, health = 2000 }

local ghost = Wrekkit.capture:Unit("0xGhost")
check("resolved as a player via the roster", ghost and ghost.isPlayer, true)
check("with the roster's class", ghost and ghost.class, "MAGE")

-- An unresolvable unit that is NOT in the roster stays unknown rather than
-- being guessed at as an enemy, so a later event can classify it properly.
Wrekkit.capture.units = {}
GetUnitData = function() return nil end
WORLD["0xVague"] = { name = "Vague", isPlayer = false, maxHealth = 1, health = 1 }
local vague = Wrekkit.capture:Unit("0xVague")
check("unresolvable strangers are not guessed as enemies",
  vague and vague.class, "UNKNOWN")
GetUnitData = function(guid) return WORLD[guid] and true or nil end

----------------------------------------------------------------------
-- crash recovery
----------------------------------------------------------------------

print("\n-- crash recovery --")

-- Self-contained: the reset tests above deliberately emptied everything.
WrekkitDB = nil
Wrekkit.InitDB()
simulateReload()
DISK[Wrekkit.store:Filename()] = nil

pull(20)
advance(40)
pull(20)

local journal = ReadCustomFile(Wrekkit.store:Filename())
check("journal was written as we went", journal ~= nil, true)

local beforeCrash = table.getn(Wrekkit.db.encounters)
check("two pulls to lose", beforeCrash, 2)

-- A crash loses SavedVariables entirely (they are only written at a clean
-- logout) but cannot touch what already reached the disk journal.
WrekkitDB = nil
Wrekkit.InitDB()
check("SavedVariables are gone after the crash",
  table.getn(Wrekkit.db.encounters), 0)

Wrekkit.store:Load()
check("everything came back from the journal",
  table.getn(Wrekkit.db.encounters), beforeCrash)

-- Both pulls were 40s apart, so they belong to one session -- recovery has
-- to preserve that grouping rather than splitting on the file's structure.
local recovered = Wrekkit.report:Sessions()
check("sessions regrouped correctly", table.getn(recovered), 1)
check("with both pulls in it", table.getn(recovered[1].encounters), 2)

-- Loading again must be a no-op, not a doubling.
local afterFirstLoad = table.getn(Wrekkit.db.encounters)
Wrekkit.store:Load()
check("loading twice changes nothing",
  table.getn(Wrekkit.db.encounters), afterFirstLoad)

-- And the recovered session must still be resumable.
simulateReload()
advance(60)
pull(20)
local ids = {}
for _, e in ipairs(Wrekkit.db.encounters) do
  ids[tostring(e.sessionId)] = true
end
check("resumed into the recovered session, not a new one",
  Wrekkit.Count(ids), 1)


----------------------------------------------------------------------
print("\n-- late-resolving names (the crash-in-a-group bug) --")
----------------------------------------------------------------------

--[[ Reported from a live group: after a crash the report showed the player
     plus a single "Unknown", and two warlocks vanished entirely.

     The client returns its "Unknown" placeholder for a unit it has not
     loaded yet. That was being cached as the name, and because the CLASS
     resolved the entry counted as finished and was never retried. Two
     consequences, both observed: players collapse into one row since they
     now share a name, and each is dropped by the ignore-outsiders filter
     because "Unknown" is not in the roster. ]]

Wrekkit.capture.units = {}
Wrekkit.encounter.live = nil

WORLD["0xLock1"] = { name = "Unknown", class = "WARLOCK", isPlayer = true,
                     maxHealth = 2000, health = 2000 }
WORLD["0xLock2"] = { name = "Unknown", class = "WARLOCK", isPlayer = true,
                     maxHealth = 2000, health = 2000 }

local u1 = Wrekkit.capture:Unit("0xLock1")
check("placeholder is not accepted as a name", u1.name, nil)

WORLD["0xLock1"].name = "Gah"
WORLD["0xLock2"].name = "Bobthekiller"
NOW = NOW + 5

u1 = Wrekkit.capture:Unit("0xLock1")
local u2 = Wrekkit.capture:Unit("0xLock2")
check("re-resolves once the client knows them", u1.name, "Gah")
check("and the second one too", u2.name, "Bobthekiller")
check("they stay distinct, not merged", u1.name ~= u2.name, true)

Wrekkit.capture.units = {}
WORLD["0xOwner"] = { name = "Unknown", class = "WARLOCK", isPlayer = true,
                     maxHealth = 2000, health = 2000 }
WORLD["0xImp"] = { name = "Brylia", isPlayer = false, owner = "0xOwner",
                   maxHealth = 500, health = 500 }
local p = Wrekkit.capture:Unit("0xImp")
check("pet owner placeholder refused", p.ownerName, nil)

WORLD["0xOwner"].name = "Bobthekiller"
NOW = NOW + 5
p = Wrekkit.capture:Unit("0xImp")
check("pet owner resolves later", p.ownerName, "Bobthekiller")

Wrekkit.capture.units = {}
WORLD["0xLate"] = { name = "Unknown", class = "MAGE", isPlayer = true,
                    maxHealth = 2000, health = 2000 }
Wrekkit.encounter:CombatStart()
local row = Wrekkit.encounter:Actor("0xLate")
check("row starts unnamed", row.name, "?")
WORLD["0xLate"].name = "Elfpriest"
NOW = NOW + 5
row = Wrekkit.encounter:Actor("0xLate")
check("row adopts the real name", row.name, "Elfpriest")

Wrekkit.capture.units = {}
WORLD["0xGhosty"] = { name = "Unknown", class = "ROGUE", isPlayer = true,
                      maxHealth = 1, health = 1 }
local calls = 0
local realUnitName = UnitName
UnitName = function(x) calls = calls + 1 return realUnitName(x) end
for i = 1, 50 do Wrekkit.capture:Unit("0xGhosty") end
UnitName = realUnitName
check("retries are throttled, not once per event", calls <= 4, true)


----------------------------------------------------------------------
print("\n-- instance sessions --")
----------------------------------------------------------------------

--[[ Reported: dying and zoning out for a corpse run split one night into
     several reports, and a raid continued on another night in the same
     lockout could not be appended to.

     The zone name alone cannot tell last week's Molten Core from this
     week's, and it CHANGES the moment someone releases, because most
     instance graveyards sit in a different zone. The lockout id is the real
     identity. ]]

local function freshSession()
  Wrekkit.db.session = nil
  Wrekkit.db.sessionBarrier = 0
  Wrekkit.encounter.session = nil
end

freshSession()
local s1 = Wrekkit.encounter:ResumeOrNew("Onyxia's Lair", NOW, "raid", SAVED_ID)
check("a raid session records its lockout", s1.instanceId, SAVED_ID)

-- Persist it the way CombatEnd does, then come back much later.
Wrekkit.db.session = {
  id = s1.id, zone = s1.zone, instanceType = "raid", instanceId = SAVED_ID,
  startTime = s1.startTime, nextId = 4,
  lastActivity = time() - 2 * 86400,      -- two days ago
}
Wrekkit.encounter.session = nil
local s2 = Wrekkit.encounter:ResumeOrNew("Onyxia's Lair", NOW, "raid", SAVED_ID)
check("same lockout resumes two days later", s2.resumed, true)
check("and keeps counting encounter ids", s2.nextId, 4)

-- A reset issues a new id, which must NOT join the old run.
Wrekkit.encounter.session = nil
local s3 = Wrekkit.encounter:ResumeOrNew("Onyxia's Lair", NOW, "raid", SAVED_ID + 1)
check("a new lockout starts a new session", s3.resumed, nil)

-- The corpse run: released to a graveyard in another zone, back 25 minutes
-- later. That is one attempt, not two nights.
freshSession()
local d1 = Wrekkit.encounter:ResumeOrNew("Blackrock Depths", NOW, "party", 0)
Wrekkit.db.session = {
  id = d1.id, zone = "Blackrock Depths", instanceType = "party", instanceId = 0,
  startTime = d1.startTime, nextId = 2,
  lastActivity = time() - 1500,           -- 25 min: past the 20 min default
}
Wrekkit.encounter.session = nil
local d2 = Wrekkit.encounter:ResumeOrNew("Blackrock Depths", NOW, "party", 0)
check("a long corpse run does not split a dungeon", d2.id, d1.id)

-- But a visit the next day is a different run.
Wrekkit.db.session = {
  id = d1.id, zone = "Blackrock Depths", instanceType = "party", instanceId = 0,
  startTime = d1.startTime, nextId = 2,
  lastActivity = time() - 86400,
}
Wrekkit.encounter.session = nil
local d3 = Wrekkit.encounter:ResumeOrNew("Blackrock Depths", NOW, "party", 0)
check("a separate visit is a separate session", d3.resumed, nil)

-- Outside an instance the original window still applies.
freshSession()
local w1 = Wrekkit.encounter:ResumeOrNew("Gilneas", NOW, nil, 0)
Wrekkit.db.session = {
  id = w1.id, zone = "Gilneas", instanceId = 0,
  startTime = w1.startTime, nextId = 2,
  lastActivity = time() - 1500,
}
Wrekkit.encounter.session = nil
local w2 = Wrekkit.encounter:ResumeOrNew("Gilneas", NOW, nil, 0)
check("open world keeps the short window", w2.resumed, nil)

-- A manual reset still wins over a matching lockout.
freshSession()
Wrekkit.db.session = {
  id = s1.id, zone = "Onyxia's Lair", instanceType = "raid",
  instanceId = SAVED_ID, startTime = s1.startTime, nextId = 2,
  lastActivity = time() - 600,
}
Wrekkit.db.sessionBarrier = time()
Wrekkit.encounter.session = nil
local b1 = Wrekkit.encounter:ResumeOrNew("Onyxia's Lair", NOW, "raid", SAVED_ID)
check("a manual reset still draws the line", b1.resumed, nil)
Wrekkit.db.sessionBarrier = 0

-- Where() should read the lockout out of the saved-instance list.
local z, kind, id = Wrekkit.encounter:Where()
check("Where finds the lockout id", id, SAVED_ID)
check("Where reports the instance type", kind, "raid")

freshSession()

----------------------------------------------------------------------
print("\n-- timeline detail --")
----------------------------------------------------------------------

--[[ The four bucket totals say a spike happened but never say what it was.
     These check the contributions behind them: who, with what, against whom.

     Bounded on purpose, so verify the bound holds as well as the content --
     this runs for every second of every encounter kept. ]]

Wrekkit.ResetData("all")
Wrekkit.db.timelineDetail = nil
Wrekkit.encounter.session = nil
Wrekkit.db.session = nil

IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11605, 500, {})
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11605, 300, {})
Wrekkit.encounter:Damage("0xP2", "0xBoss", 25289, 700, {})
Wrekkit.encounter:Damage("0xBoss", "0xP1", 99001, 250, {})
Wrekkit.encounter:Heal("0xP2", "0xP1", 2050, 400, 0, {})

local live = Wrekkit.encounter.live
local b = live.bucket[0]
check("the second has a detail table", b.top ~= nil, true)

local byKey = {}
for _, r in pairs(b.top or {}) do
  byKey[(r.k or "") .. (r.s or "") .. tostring(r.id) .. (r.t or "")] = r
end

local dmg = byKey["d0xP1" .. tostring(11605) .. "0xBoss"]
check("same source, spell and target merge", dmg and dmg.n, 2)
check("and their amounts add up", dmg and dmg.a, 800)

local taken = byKey["t0xBoss" .. tostring(99001) .. "0xP1"]
check("damage taken records who hit whom", taken and taken.a, 250)

local heal = byKey["h0xP2" .. tostring(2050) .. "0xP1"]
check("healing records the target", heal and heal.a, 400)

-- A second cannot grow without limit, however busy it gets.
for i = 1, 200 do
  Wrekkit.encounter:Damage("0xP1", "0xBoss", 50000 + i, 10, {})
end
check("a busy second is capped", b.topKeys <= 24, true)
local existing = byKey["d0xP1" .. tostring(11605) .. "0xBoss"]
check("but existing entries keep accumulating", existing.a, 800)

Wrekkit.encounter:Damage("0xP1", "0xBoss", 11605, 200, {})
check("a known contributor still grows past the cap", existing.a, 1000)

--[[ Persisting resolves guids to names and keeps only the largest few.

     The fight has to last longer than minTrashDuration or Finish discards
     it, and stopT only moves when something lands -- so advance the clock
     and land one more hit rather than just waiting. ]]
advance(8)
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11605, 100, {})
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local stored = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)] or {}
check("the encounter was stored at all",
  table.getn(Wrekkit.db.encounters) > 0, true)
check("stored encounter carries timeline detail", stored.top ~= nil, true)
local kept = stored.top and stored.top[0]
check("kept the top few, not all of them", kept and table.getn(kept) <= 4, true)

local named = false
for _, r in ipairs(kept or {}) do
  if r.src == "Fuff" then named = true end
end
check("guids were resolved to names", named, true)

local hasTarget = false
for _, r in ipairs(kept or {}) do
  if r.dst and r.dst ~= "" then hasTarget = true end
end
check("the target survived to storage", hasTarget, true)

-- Off means off: no table, no per-event work.
Wrekkit.ResetData("all")
Wrekkit.db.timelineDetail = false
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11605, 500, {})
check("the setting can turn it off",
  (Wrekkit.encounter.live.bucket[0] or {}).top, nil)
Wrekkit.db.timelineDetail = nil

IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
Wrekkit.ResetData("all")
--[[ A long fight must not blow up SavedVariables. Four rows a second over a
     five-minute boss is 1200 rows, around 100KB for one pull, rewritten
     whole at logout and parsed whole at login. The budget keeps the busiest
     seconds and drops the quiet ones, because a quiet second is not what
     anyone clicks. ]]

Wrekkit.ResetData("all")
Wrekkit.db.timelineDetail = nil
Wrekkit.db.timelineDetailSeconds = 10

IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
for sec = 1, 40 do
  -- Rising damage, so the busiest seconds are the last ones.
  Wrekkit.encounter:Damage("0xP1", "0xBoss", 11605, sec * 100, {})
  advance(1)
end
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11605, 50, {})
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local long = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)] or {}
local secondsKept, rowsKept = 0, 0
for _, rows in pairs(long.top or {}) do
  secondsKept = secondsKept + 1
  rowsKept = rowsKept + table.getn(rows)
end

check("detail is budgeted per encounter", secondsKept <= 12, true)
check("and some detail was kept", secondsKept > 0, true)
check("every bucket still has its totals",
  table.getn(long.bucket or {}) >= secondsKept, true)

-- The busiest seconds are the ones that survive.
local keptLast = false
for i = 35, 40 do if long.top[i] then keptLast = true end end
check("the busiest seconds are the ones kept", keptLast, true)

Wrekkit.db.timelineDetailSeconds = nil
Wrekkit.ResetData("all")


----------------------------------------------------------------------
print("\n-- resists --")
----------------------------------------------------------------------

--[[ Full and partial resists are different events and different problems.

     A FULL resist arrives as a miss with reason 2 and did no damage at all.
     A PARTIAL resist LANDED -- it is in hits and in the total, with part of
     its damage eaten by the target's resistance. Reporting them together
     hides both: full resists are a hit-table problem, partials are a gear
     problem. ]]

Wrekkit.ResetData("all")
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")

-- Landed for 750 with 250 eaten: a 25% partial off a 1000 potential.
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11661, 750, { resisted = 250 })
-- Landed for 500 with 500 eaten: 50%.
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11661, 500, { resisted = 500 })
-- Landed clean.
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11661, 1000, {})
-- Fully resisted, which is a MISS with reason 2.
Wrekkit.encounter:Miss("0xP1", "0xBoss", 11661, 2)
-- And an ordinary miss, reason 1.
Wrekkit.encounter:Miss("0xP1", "0xBoss", 11661, 1)

local act = Wrekkit.encounter.live.actors["0xP1"]
local row = act.dmgAbility[11661]

check("partial resists counted", row.resistHits, 2)
check("full resist is NOT a partial", row.resistHits ~= 3, true)
check("damage lost to partials", row.resisted, 750)
check("25% tier", row.r25, 1)
check("50% tier", row.r50, 1)
check("75% tier stayed empty", row.r75, 0)
check("partials still count as hits", row.hits, 3)
check("both misses counted", row.misses, 2)
check("the full resist is recorded by reason", row.missBy[2], 1)
check("and the plain miss separately", row.missBy[1], 1)

--[==[ Go through the REAL drilldown path, not straight to AbilityStats.
       R:Abilities rebuilds every row from an explicit field list, so a stat
       that is not named there is invisible on screen no matter how
       correctly it was recorded. Testing AbilityStats directly misses that
       entirely -- and did. ]==]
local drillRows = Wrekkit.report:Abilities(act, "damage")
local drilled
for _, r in ipairs(drillRows) do if r.id == 11661 then drilled = r end end
check("the drilldown row survives with its resist data",
  drilled and drilled.resistHits, 2)
check("and its miss reasons", drilled and drilled.missBy and drilled.missBy[2], 1)

local stats = Wrekkit.report:AbilityStats(drilled, "damage")
local byLabel = {}
for _, r in ipairs(stats) do byLabel[r.label] = r end

check("full resists get their own line", byLabel["Fully resisted"] ~= nil, true)
check("partials get their own line", byLabel["Partially resisted"] ~= nil, true)
check("and they do not share a number",
  byLabel["Fully resisted"].value ~= byLabel["Partially resisted"].value, true)
check("the damage lost is reported", byLabel["Lost to resists"] ~= nil, true)
check("the tiers are broken out", byLabel["Resist tiers"] ~= nil, true)
check("an ordinary miss is named, not lumped in", byLabel["Missed"] ~= nil, true)

-- Survives storage.
advance(8)
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11661, 100, {})
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local stored = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)] or {}
local savedRow
for _, a in pairs(stored.actors or {}) do
  for _, r in ipairs(a.dmgAbility or {}) do
    if r.id == 11661 then savedRow = r end
  end
end
check("resist stats survived persisting", savedRow and savedRow.resistHits, 2)
check("and the miss reasons did too", savedRow and savedRow.missBy and savedRow.missBy[2], 1)

Wrekkit.ResetData("all")

----------------------------------------------------------------------
print("\n-- spell names and ranks --")
----------------------------------------------------------------------

--[[ Ranks are tracked as separate rows on purpose: different ranks are
     different spells with different coefficients and costs. But SpellInfo
     returns name, RANK, texture and the rank was being discarded, so every
     row read "Shadow Bolt" and the separation was useless to look at. ]]

local n10 = Wrekkit.capture:Spell(11661)
local n9  = Wrekkit.capture:Spell(11660)
check("rank 10 names its rank", n10, "Shadow Bolt (Rank 10)")
check("rank 9 names its rank", n9, "Shadow Bolt (Rank 9)")
check("the two ranks are distinguishable", n10 ~= n9, true)
check("a rankless spell is unchanged",
  Wrekkit.capture:Spell(11267), "Sinister Strike")

--[[ Without SuperWoW there is no SpellInfo at all and every spell reads as
     its raw id. SPELLCAST_START is stock 1.12 and its arg1 IS the name, so
     pairing it with the id from SPELL_GO_SELF teaches one spell per cast. ]]

local realSpellInfo = SpellInfo
SpellInfo = nil
Wrekkit.db.spellNames = {}

local freshId = 25309
fire("SPELLCAST_START", "Immolate")
fire("SPELL_GO_SELF", 0, freshId, "0xP1", "0xBoss")
check("the name was learned from the cast",
  Wrekkit.db.spellNames[freshId], "Immolate")

-- A stale cast start must not label an unrelated spell seconds later.
fire("SPELLCAST_START", "Corruption")
advance(5)
fire("SPELL_GO_SELF", 0, 25310, "0xP1", "0xBoss")
check("a stale cast name is not bound", Wrekkit.db.spellNames[25310], nil)

-- And with SuperWoW present, learning is skipped entirely.
SpellInfo = realSpellInfo
fire("SPELLCAST_START", "Shadow Bolt")
fire("SPELL_GO_SELF", 0, 25311, "0xP1", "0xBoss")
check("SuperWoW makes learning unnecessary",
  Wrekkit.db.spellNames[25311], nil)

Wrekkit.db.spellNames = nil

----------------------------------------------------------------------
-- damage schools
----------------------------------------------------------------------

--[[ What a mob is hitting you with, and with what school. Recorded from the
     school nampower passes on the damage event, which was being handed to
     E:Damage and dropped on the floor before this. ]]
Wrekkit.ResetData("all")
Wrekkit.encounter:CombatStart()
for i = 1, 8 do
  -- Boss casts Fire (school 2) and Shadow (school 5) at a player, and swings.
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xP1", "0xBoss", 20811, 400, "0,0,0", 0, 2)
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xP1", "0xBoss", 20812, 250, "0,0,0", 0, 5)
  fire("AUTO_ATTACK_OTHER", "0xBoss", "0xP1", 180, 0, 0, 1, 0, 0, 0)
  advance(1)
end
Wrekkit.encounter:CombatEnd()
Wrekkit.encounter:Finish()

local function abilityNamed(list, name)
  for _, a in ipairs(list) do
    if a.name == name or string.find(a.label or "", name, 1, true) then return a end
  end
  return nil
end

local view = Wrekkit.report:View(Wrekkit.report:CurrentSession().encounters, {})
local mobs = Wrekkit.report:Rank(view, "enemy", {})
local boss
for _, r in ipairs(mobs) do if r.damage and r.damage > 0 then boss = r end end
check("the mob is ranked by what it dealt", boss ~= nil, true)

local abilities = Wrekkit.report:Abilities(boss, "enemy")
check("the mob's attacks are listed", table.getn(abilities) >= 2, true)

local fireSpell, shadowSpell, melee
for _, a in ipairs(abilities) do
  if a.school == 2 then fireSpell = a end
  if a.school == 5 then shadowSpell = a end
  if a.id == 0 then melee = a end
end

check("a fire attack kept its school", fireSpell ~= nil, true)
check("a shadow attack kept its school", shadowSpell ~= nil, true)
check("fire is labelled Fire",
  fireSpell and string.find(fireSpell.label, "(Fire)", 1, true) ~= nil, true)
check("shadow is labelled Shadow",
  shadowSpell and string.find(shadowSpell.label, "(Shadow)", 1, true) ~= nil, true)
check("melee reads as Physical",
  melee and string.find(melee.label, "(Physical)", 1, true) ~= nil, true)

--[[ The school decorates `label`; `name` stays the plain ability name that
     every other lookup compares against. Folding it into the name turned a
     key into a display string and broke thirteen tests at once. ]]
check("the name is not decorated",
  fireSpell and string.find(fireSpell.name, "(", 1, true) == nil, true)

-- Damage taken answers the same question from the other side.
local players = Wrekkit.report:Rank(view, "taken", {})
local victim
for _, r in ipairs(players) do if (r.taken or 0) > 0 then victim = r end end
check("a player took damage", victim ~= nil, true)
local takenBy = victim and Wrekkit.report:Abilities(victim, "taken") or {}
local takenFire
for _, a in ipairs(takenBy) do if a.school == 2 then takenFire = a end end
check("what hit you keeps its school too", takenFire ~= nil, true)

-- Schools that do not map to a name are shown as the raw number rather than
-- confidently mislabelled.
check("an unknown school is not given a name",
  Wrekkit.SchoolName(99), "School 99")
check("a missing school on a spell is unknown", Wrekkit.SchoolName(nil, 1234), nil)
check("a missing school on melee is Physical", Wrekkit.SchoolName(nil, 0), "Physical")
check("school zero is Physical", Wrekkit.SchoolName(0, 0), "Physical")

--[[ Persistence rebuilds every ability from an explicit field list, which is
     exactly where the resist statistics were lost once already. ]]
Wrekkit.encounter:Persist(Wrekkit.report:CurrentSession().encounters[1])
local keptSchool, keptMobDetail = false, false
for _, enc in ipairs((Wrekkit.db and Wrekkit.db.encounters) or {}) do
  for _, actor in pairs(enc.actors or {}) do
    if not actor.isPlayer and actor.dmgAbility then keptMobDetail = true end
    for _, a in ipairs(actor.dmgAbility or {}) do
      if a.school then keptSchool = true end
    end
  end
end
check("a mob keeps its attacks in history at all", keptMobDetail, true)
check("the school survives being written to history", keptSchool, true)


----------------------------------------------------------------------
-- boss pulls
----------------------------------------------------------------------

Wrekkit.ResetData("all")
Wrekkit.db.bossHealth = 40000

local function pullOn(guid, seconds)
  Wrekkit.encounter:CombatStart()
  for _ = 1, (seconds or 8) do
    fire("AUTO_ATTACK_SELF", "0xP1", guid, 300, 0, 0, 1, 0, 0, 0)
    fire("AUTO_ATTACK_OTHER", guid, "0xP1", 120, 0, 0, 1, 0, 0, 0)
    advance(1)
  end
  Wrekkit.encounter:CombatEnd()
  Wrekkit.encounter:Finish()
  local list = Wrekkit.report:CurrentSession().encounters
  return list[table.getn(list)]
end

defNPC("0xBigBoss", "Ragnaros", 900000)
defNPC("0xTrashA", "Molten Giant", 9000)
defNPC("0xWorldBoss", "Azuregos", 12000, "worldboss")

local bossPull = pullOn("0xBigBoss")
local trashPull = pullOn("0xTrashA")
local wbPull = pullOn("0xWorldBoss")

check("a huge enemy reads as a boss", Wrekkit.IsBoss(bossPull), true)
check("a small enemy does not", Wrekkit.IsBoss(trashPull), false)
--[[ The health fallback would call this trash -- it has less health than the
     threshold. The client's own classification is why it is not. ]]
check("classification beats the health guess", Wrekkit.IsBoss(wbPull), true)
check("the pull is named after what it fought", bossPull.name, "Ragnaros")

-- Marking by hand overrules the guess, and sticks in history.
Wrekkit.SetBoss(trashPull, true)
check("marking by hand makes it a boss", Wrekkit.IsBoss(trashPull), true)
local inHistory
for _, rec in ipairs(Wrekkit.db.encounters or {}) do
  if rec.id == trashPull.id and rec.sessionId == trashPull.sessionId then
    inHistory = rec
  end
end
check("the mark is written to history too", inHistory and inHistory.boss, true)
check("and says it was you, not a guess", inHistory and inHistory.bossBy, "you")
Wrekkit.SetBoss(trashPull, false)
check("unmarking works as well", Wrekkit.IsBoss(trashPull), false)

-- The threshold is a setting, because no one number fits all content.
Wrekkit.db.bossHealth = 5000
local nowBoss = pullOn("0xTrashA")
check("lowering the threshold catches smaller bosses",
  Wrekkit.IsBoss(nowBoss), true)
Wrekkit.db.bossHealth = 40000

Wrekkit.ResetData("all")

----------------------------------------------------------------------
print("\n-- combat log range --")
----------------------------------------------------------------------
do

--[[ The client only reports combat within CombatLogRange, and its default
     on this client is 30 yards. Anyone further away generates no events at
     all, so they are missing from the meter rather than wrong in it. That
     is the most common complaint about every 1.12 meter, and DPSMate's own
     documentation tells people to raise exactly these. ]]

CVARS = {}
Wrekkit.db.combatLogRange = nil
Wrekkit.db.combatLogRangeYards = nil
Wrekkit.capture:ApplyCombatLogRange()

check("creature range was raised", tonumber(CVARS["CombatLogRangeCreature"]), 200)
check("party range too", tonumber(CVARS["CombatLogRangeParty"]), 200)
check("and party PETS, which are easy to forget",
  tonumber(CVARS["CombatLogRangePartyPet"]), 200)

local raised = 0
for _, cv in ipairs(Wrekkit.capture.rangeCvars) do
  if CVARS[cv] then raised = raised + 1 end
end
check("every category was raised, not just one", raised, 7)

-- The user can pick their own figure.
CVARS = {}
Wrekkit.db.combatLogRangeYards = 80
Wrekkit.capture:ApplyCombatLogRange()
check("a chosen range is honoured", tonumber(CVARS["CombatLogRangeCreature"]), 80)

-- And opt out entirely.
CVARS = {}
Wrekkit.db.combatLogRange = false
Wrekkit.capture:ApplyCombatLogRange()
check("opting out leaves the client alone", CVARS["CombatLogRangeCreature"], nil)

Wrekkit.db.combatLogRange = nil
Wrekkit.db.combatLogRangeYards = nil

-- Reported, so a short range is diagnosable rather than mysterious.
CVARS = { CombatLogRangeCreature = "30" }
check("status can read the range back", Wrekkit.capture:CombatLogRange(), 30)
CVARS = {}

end

----------------------------------------------------------------------
print("\n-- history eviction --")
----------------------------------------------------------------------
do

--[[ A ring buffer silently dropping the oldest pull is correct for a buffer
     and wrong for a log. Someone raiding all week has no way to know their
     Tuesday is being deleted to make room for Thursday. ]]

Wrekkit.ResetData("all")
Wrekkit.encounter.warnedEviction = nil
Wrekkit.db.maxEncounters = 3

local said = 0
local realPrint = Wrekkit.Print
Wrekkit.Print = function(msg)
  if string.find(tostring(msg), "history is full", 1, true) then said = said + 1 end
end

for i = 1, 6 do
  IN_COMBAT = true
  fire("PLAYER_REGEN_DISABLED")
  for k = 1, 8 do
    Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
    advance(1)
  end
  IN_COMBAT = false
  fire("PLAYER_REGEN_ENABLED")
  Wrekkit.encounter:Finish()
end
Wrekkit.Print = realPrint

check("the buffer held its cap", table.getn(Wrekkit.db.encounters), 3)
check("and said so, once", said, 1)

-- A locked pull is never the one thrown away.
Wrekkit.ResetData("all")
Wrekkit.encounter.warnedEviction = nil
Wrekkit.db.maxEncounters = 2
Wrekkit.Print = function() end
for i = 1, 4 do
  IN_COMBAT = true
  fire("PLAYER_REGEN_DISABLED")
  for k = 1, 8 do
    Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
    advance(1)
  end
  IN_COMBAT = false
  fire("PLAYER_REGEN_ENABLED")
  Wrekkit.encounter:Finish()
  if i == 1 then
    local first = Wrekkit.db.encounters[1]
    if first then first.locked = true end
  end
end
Wrekkit.Print = realPrint

local keptLocked = false
for _, e in ipairs(Wrekkit.db.encounters) do
  if e.locked then keptLocked = true end
end
check("the locked pull survived eviction", keptLocked, true)

Wrekkit.db.maxEncounters = nil
Wrekkit.encounter.warnedEviction = nil
Wrekkit.ResetData("all")

end

----------------------------------------------------------------------
print("\n-- per-second basis --")
----------------------------------------------------------------------
do

--[[ Skada divides by the length of the fight, Recount by the seconds the
     player actually acted. The two genuinely disagree, and a player who
     stood around for half a pull is where you see it. ]]

Wrekkit.ResetData("all")
Wrekkit.db.dpsBasis = nil

IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")

-- Ten seconds of fight. Fuff swings throughout; Elfpriest acts for two.
for sec = 1, 10 do
  Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
  if sec <= 2 then
    Wrekkit.encounter:Damage("0xP2", "0xBoss", 11267, 100, {})
  end
  advance(1)
end
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local enc = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
local byName = {}
for _, a in pairs(enc.actors or {}) do byName[a.name] = a end

check("a full-fight actor banked ~one second each", byName["Fuff"].active >= 10, true)
check("a brief actor banked only its own", byName["Elfpriest"].active, 2)

local view = Wrekkit.report:View({ enc }, { petMode = "merge" })

Wrekkit.db.dpsBasis = "combat"
local combatRows = Wrekkit.report:Rank(view, "dps")
local combatBy = {}
for _, r in ipairs(combatRows) do combatBy[r.name] = r._v end

Wrekkit.db.dpsBasis = "active"
local activeRows = Wrekkit.report:Rank(view, "dps")
local activeBy = {}
for _, r in ipairs(activeRows) do activeBy[r.name] = r._v end

Wrekkit.db.dpsBasis = nil

--[[ The player who acted throughout should read about the same either way;
     the one who acted briefly should read much HIGHER on active time,
     because the idle seconds stop counting against them. That difference
     is the entire reason the setting exists. ]]
check("the brief actor rises on active time",
  activeBy["Elfpriest"] > combatBy["Elfpriest"] * 2, true)
check("the constant actor barely moves",
  math.abs(activeBy["Fuff"] - combatBy["Fuff"]) < combatBy["Fuff"] * 0.5, true)
check("and the two bases really differ",
  activeBy["Elfpriest"] ~= combatBy["Elfpriest"], true)

-- An old log with no recorded active time must not divide by zero.
local stale = { name = "Old", damage = 1000, active = 0 }
Wrekkit.db.dpsBasis = "active"
local m = Wrekkit.metrics.Get("dps")
local v = m.value(stale, { duration = 10 })
Wrekkit.db.dpsBasis = nil
check("no active time falls back to the fight length", v, 100)

Wrekkit.ResetData("all")

end

----------------------------------------------------------------------
print("\n-- death recap --")
----------------------------------------------------------------------
do

-- The question after a wipe is not who died, it is what the last few
-- seconds looked like. The ring keeps being overwritten as the fight goes
-- on, so the snapshot has to be taken AT the death and copied, not
-- referenced -- otherwise it would describe whatever happened next.

Wrekkit.ResetData("all")
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")

Wrekkit.encounter:Damage("0xBoss", "0xP1", 11605, 300, {})
advance(1)
Wrekkit.encounter:Damage("0xBoss", "0xP1", 99001, 450, {})
advance(1)
Wrekkit.encounter:Damage("0xBoss", "0xP1", 11605, 900, {})
Wrekkit.encounter:Death("0xP1")

local live = Wrekkit.encounter.live
local death = live.deaths[1]
check("the death was recorded", death ~= nil, true)
check("with a recap attached", death.recap ~= nil, true)
check("holding the hits before it", table.getn(death.recap) >= 3, true)

local last = death.recap[table.getn(death.recap)]
check("the killing blow is last", last.a, 900)
check("and names what did it", last.src, "Onyxia")

-- Hits AFTER the death must not rewrite what killed them.
local before = table.getn(death.recap)
for i = 1, 12 do
  advance(1)
  Wrekkit.encounter:Damage("0xBoss", "0xP1", 11605, 5, {})
end
check("the snapshot did not drift", table.getn(death.recap), before)
check("and still ends on the killing blow",
  death.recap[table.getn(death.recap)].a, 900)

-- The ring is bounded, however long the fight runs.
local act = live.actors["0xP1"]
local ringSize = 0
for _ in pairs(act.recent or {}) do ringSize = ringSize + 1 end
check("the ring stays bounded", ringSize <= 8, true)

-- And it formats into something readable.
local rows = Wrekkit.report:DeathRecap(death)
check("the recap renders rows", table.getn(rows) >= 3, true)
check("timed relative to the death",
  string.find(rows[1].label, "^%-%d") ~= nil, true)

-- A death with nothing recorded says so rather than showing an empty box.
local empty = Wrekkit.report:DeathRecap({ t = 5, recap = {} })
check("an empty recap explains itself", table.getn(empty), 1)

advance(8)
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local stored = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
local sd = stored and stored.deaths and stored.deaths[1]
check("the recap survived persisting", sd and sd.recap and table.getn(sd.recap) >= 3, true)

local view = Wrekkit.report:View({ stored }, { petMode = "merge" })
check("and reached the view the window reads",
  view.deaths[1] and view.deaths[1].recap ~= nil, true)

Wrekkit.ResetData("all")
end

----------------------------------------------------------------------
print("\n-- aura uptime --")
----------------------------------------------------------------------
do
-- Nampower fires these on change, never on a timer, so uptime is intervals
-- rather than samples. The cases that matter: a refresh must not restart
-- the interval, and something still up at the end of the pull was up until
-- the end of the pull.

Wrekkit.ResetData("all")
Wrekkit.db.trackAuras = nil
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")

-- Flask on at t0, still on at the end.
fire("BUFF_ADDED_SELF", "0xP1", 1, 17628)
advance(5)
-- Re-applied while already up: a refresh, not a second application.
fire("BUFF_ADDED_SELF", "0xP1", 1, 17628)
advance(5)

-- A debuff that goes on and comes off.
fire("DEBUFF_ADDED_OTHER", "0xBoss", 2, 11722)
advance(4)
fire("DEBUFF_REMOVED_OTHER", "0xBoss", 2, 11722)
advance(2)

local live = Wrekkit.encounter.live
local me = live.actors["0xP1"]
local flask = me.auras[17628]

check("the aura was tracked", flask ~= nil, true)
check("a refresh is not a second application", flask.applied, 1)
check("and did not restart the interval", flask.since ~= nil, true)

local boss = live.actors["0xBoss"]
local curse = boss.auras[11722]
check("a removed debuff banked its uptime", math.floor(curse.up + 0.5), 4)
check("and is no longer running", curse.since, nil)

-- Finishing closes whatever is still up.
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local stored = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
local savedAuras
for _, a in pairs(stored.actors or {}) do
  if a.name == "Fuff" then savedAuras = a.auras end
end
check("uptime persisted", savedAuras ~= nil and table.getn(savedAuras) > 0, true)

local kept
for _, au in ipairs(savedAuras or {}) do
  if au.id == 17628 then kept = au end
end
check("the open aura was closed at the end", kept and kept.up > 9, true)

-- It reaches the view, and the metric reads it.
local view = Wrekkit.report:View({ stored }, { petMode = "merge" })
local rows = Wrekkit.report:Rank(view, "uptime")
local found = false
for _, r in ipairs(rows) do
  if r.name == "Fuff" and r._v > 0 then found = true end
end
check("the uptime metric ranks on it", found, true)

-- Off means off.
Wrekkit.ResetData("all")
Wrekkit.db.trackAuras = false
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
fire("BUFF_ADDED_SELF", "0xP1", 1, 17628)
local off = Wrekkit.encounter.live.actors["0xP1"]
local n = 0
for _ in pairs((off and off.auras) or {}) do n = n + 1 end
check("the setting can turn it off", n, 0)

Wrekkit.db.trackAuras = nil
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
Wrekkit.ResetData("all")
end

print(string.format("\n%d passed, %d failed\n", pass, fail))

if fail > 0 then os.exit(1) end

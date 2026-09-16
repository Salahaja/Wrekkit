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
local function defNPC(guid, name, maxHP)
  WORLD[guid] = { name = name, isPlayer = false,
                  maxHealth = maxHP or 100000, health = maxHP or 100000 }
end

----------------------------------------------------------------------
-- API stubs
----------------------------------------------------------------------

GetUnitData = function(guid) return WORLD[guid] and true or nil end
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
SetCVar = function() end
GetCVar = function() return "1" end
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
print(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end

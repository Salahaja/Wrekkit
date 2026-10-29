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
-- 1.12 has no coroutine library; a call to it must fail here as it does in-game.
coroutine = nil
-- Nor math.huge (5.1); another addon may polyfill it in-game, but not reliably.
math.huge = nil
table.getn = table.getn or function(t) return #t end
table.setn = table.setn or function() end
unpack = unpack or table.unpack

--[[ The client's Lua is a 32-bit build: %d goes through a C int, so any
     value from 2^31 up prints as -2147483648 there, where 5.4 prints it
     whole. Print it the client's way, or a %d on a big number passes here
     and prints nonsense in game. ]]
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
UnitLevel = function(u) local d = WORLD[u] return (d and d.level) or 60 end
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
  -- name, link, quality, level, type: the type tells a potion from a weapon.
  local items = { [13446] = "Major Healing Potion", [20520] = "Dark Rune",
                  [61277] = "Fist of the Forgotten Order" }
  local types = { [61277] = "Weapon" }
  if not items[id] then return nil end
  return items[id], "item:" .. id, 1, 60, types[id] or "Consumable"
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
dofile("consumes_db.lua")
dofile("capture.lua")
dofile("encounter.lua")
dofile("metrics.lua")
dofile("report.lua")
dofile("diagnostics.lua")
dofile("store.lua")
dofile("archive.lua")
dofile("sync.lua")
dofile("announce.lua")
dofile("export.lua")
dofile("threat.lua")
dofile("talents.lua")
dofile("prices.lua")
dofile("ahscan.lua")
dofile("raidvalue.lua")

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
-- 0x02 (AFFECTS_VICTIM) is set on every landed swing and 0x80 is the crit (1.12;
-- later expansions moved it to 0x200, which no swing here ever sets).
-- Using 0 and 2 as "normal" and "crit" -- as this test originally did --
-- hides a reversed crit test completely.
local HIT_NORMAL = 2            -- 0x002 AFFECTS_VICTIM
local HIT_CRIT   = 2 + 128      -- 0x082 AFFECTS_VICTIM | CRITICALHIT, as the server sends it

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
;(function()
  -- The pet's swings are a line of their own, not folded into the hunter's.
  local lines = {}
  for _, ab in ipairs(Wrekkit.report:Abilities(byName["Moorhunt"], "damage")) do lines[ab.name] = ab end
  check("a merged pet keeps its own melee line", lines["Raptor: Melee"] and lines["Raptor: Melee"].amount, 250)
  check("and the hunter's melee is the hunter's", lines["Melee"] and lines["Melee"].amount, 400)
  check("still reads as physical", lines["Raptor: Melee"] and lines["Raptor: Melee"].label, "Raptor: Melee (Physical)")
end)()
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

;(function()
  -- 10/20 Molten Core: two healers left after the raid, and "group only"
  -- took them out of every pull they had healed. Someone in your group
  -- during a pull stays in it; a passer-by still does not show.
  local was = enc.inGroup
  enc.inGroup = { Elfpriest = true, Fuff = true }
  Wrekkit.capture.groupMembers = { Fuff = true }   -- Elfpriest has left
  local rows = Wrekkit.report:Rank(Wrekkit.report:View({ enc }, { petMode = "merge" }), "healing", { groupOnly = true })
  local seen = {}
  for _, r in ipairs(rows) do seen[r.name] = true end
  check("someone who left still counts for the pulls they were in", seen["Elfpriest"], true)
  rows = Wrekkit.report:Rank(Wrekkit.report:View({ enc }, { petMode = "merge" }), "damage", { groupOnly = true })
  seen = {}
  for _, r in ipairs(rows) do seen[r.name] = true end
  check("a passer-by is still left out", seen["Moorhunt"], nil)
  -- Someone invited since the pull counts too (the group as it is now).
  enc.inGroup = {}
  Wrekkit.capture.groupMembers = { Fuff = true, Elfpriest = true }
  rows = Wrekkit.report:Rank(Wrekkit.report:View({ enc }, { petMode = "merge" }), "healing", { groupOnly = true })
  seen = {}
  for _, r in ipairs(rows) do seen[r.name] = true end
  check("and someone in the group now, as before", seen["Elfpriest"], true)
  enc.inGroup = was
  Wrekkit.capture.groupMembers = {}
end)()

Wrekkit.capture.groupMembers = {}

----------------------------------------------------------------------
-- consumables
----------------------------------------------------------------------

print("\n-- consumables --")

--[[ A consumable is known by the spell it casts. SPELL_GO's item is
     filled in for your own casts -- procs included -- and left 0 for
     everyone else's, as this client really sends them. ]]
Wrekkit.encounter.live = enc          -- re-open the finished pull
fire("SPELL_GO_SELF", 13446, 17534, "0xP1", "0xP1")   -- your potion, twice
fire("SPELL_GO_SELF", 13446, 17534, "0xP1", "0xP1")
fire("SPELL_GO_SELF", 20520, 27869, "0xP1", "0xP1")   -- a different item
fire("SPELL_GO_SELF", 0, 11267, "0xP1", "0xBoss")     -- a plain spell cast
fire("SPELL_GO_SELF", 61277, 20007, "0xP1", "0xP1")   -- a weapon's Crusader proc
fire("SPELL_GO_OTHER", 0, 17534, "0xP2", "0xP2")      -- someone else's potion: no item
fire("SPELL_GO_OTHER", 0, 17534, "0xBoss", "0xBoss")  -- a mob casting the same spell
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
check("nor is a weapon's proc, though an item came with it",
  consBy["Fuff"] and consBy["Fuff"].consumes, 3)
check("another player's potion, with no item, is known by its spell",
  consBy["Elfpriest"] and consBy["Elfpriest"].consumes, 1)
check("a mob casting a potion's spell is not a consumer", consBy["Onyxia"] and consBy["Onyxia"].consumes or 0, 0)
check("your own use teaches the spell", Wrekkit.db.consumeSpells and Wrekkit.db.consumeSpells[17534], 13446)
check("a shared spell goes to the original item",
  Wrekkit.capture:ConsumableItem(0, 17531, "0xP2"), 13444)
check("named from the table when the client has not cached it",
  Wrekkit.capture:Item(13444, 17531), "Major Mana Potion")

-- Drink and food: one spell for dozens of items, so another player's is
-- Drink or Food -- not the item you last ate, at its price.
;(function()
  local realInfo = SpellInfo
  SpellInfo = function(id)
    if id == 1137 then return "Drink", nil, "x" end
    if id == 24707 then return "Food", nil, "x" end
    return realInfo(id)
  end
  local C = Wrekkit.capture
  local was = Wrekkit.db.consumeSpells[24707]
  check("another player's drink is a Drink, not one of its items", C:ConsumableItem(0, 1137, "0xP2"), -1)
  check("  named Drink", C:Item(-1, 1137), "Drink")
  check("  and unpriced", Wrekkit.prices:Value(-1), nil)
  Wrekkit.db.consumeSpells[24707] = 83004     -- you once ate a Conjured Mana Orange
  check("your own food does not name everyone's", C:ConsumableItem(0, 24707, "0xP2"), -2)
  check("  your own still names its item", C:ConsumableItem(83004, 24707, "0xP1"), 83004)
  check("a food spell the client cannot name, cast by many items", C:ConsumableItem(0, 433, "0xP2"), -3)
  check("a potion and its look-alike still go to the potion", C:ConsumableItem(0, 17531, "0xP2"), 13444)
  Wrekkit.db.consumeSpells[24707] = was
  SpellInfo = realInfo
end)()

-- Exported for the officers: each player's consumables, priced, then each
-- consumable and who used it, then the raid's total -- saved as a file.
;(function()
  local P = Wrekkit.prices
  local realValue = P.Value
  P.Value = function(self, id) return ({ [13446] = 5000 })[id] end
  local ctx = { encounters = { enc }, label = "Test", petMode = "merge" }
  local text = Wrekkit.export:Consumes(ctx)
  local function has(s) return string.find(text, s, 1, true) ~= nil end
  check("export: the rogue, his uses and their cost", has("Fuff (1 death): 3 uses, 1g 0s"), true)
  check("export: a priced item and its cost", has("Major Healing Potion") and has("1g 0s"), true)
  check("export: an unpriced one says so", has("Dark Rune"), true)
  check("export: each consumable and who used it", has("Fuff x2, Elfpriest"), true)
  check("export: the raid's total", has("Raid: ") and has("1 use with no price"), true)
  check("export: no colour codes in a file", has("|c"), false)
  DISK = {}
  local name = Wrekkit.export:Run(ctx, "consumes", "file")
  check("export: saved under its own name", name and string.find(name, "^Wrekkit_Consumes_") ~= nil, true)
  check("  with the list in it", name and DISK[name] == text, true)
  check("  a name the file API takes", name and string.find(name, "^[%w_%-]+%.txt$") ~= nil, true)
  local shown, head = Wrekkit.export:Shown({ metric = "consumes", encounters = { enc }, label = "Test", petMode = "merge" })
  check("export: what is on screen, its heading first", string.find(shown, head, 1, true) == 1, true)
  P.Value = realValue
end)()

-- Between pulls: held, and credited to the next pull -- the pre-pull fire
-- protection potion, the flask. Only your group's.
;(function()
  local E = Wrekkit.encounter
  local realGroup, realLive, realIn = Wrekkit.capture.groupMembers, E.live, E.inCombat
  Wrekkit.capture.groupMembers = { Fuff = true }
  E.live, E.inCombat, E.held = nil, false, {}
  fire("SPELL_GO_SELF", 13446, 17534, "0xP1", "0xP1")    -- you, before the pull
  fire("SPELL_GO_OTHER", 0, 17534, "0xP2", "0xP2")       -- not in your group (yet)
  check("used between pulls: held, whoever drank", table.getn(E.held), 2)
  E:CombatStart()
  local fuff, priest
  for _, a in pairs(E.live.actors) do
    if a.name == "Fuff" then fuff = a end
    if a.name == "Elfpriest" then priest = a end
  end
  check("  and credited to the next pull", fuff and fuff.consumes, 1)
  check("  only if in the group when it starts", priest and priest.consumes or 0, 0)
  check("  and unmarked, so it can count later", Wrekkit.db.consumeCredit["0xP2:17534"], nil)
  check("  the hold emptied", table.getn(E.held), 0)
  -- Long before (yesterday's flask): not tonight's first pull's.
  E.live, E.inCombat = nil, false
  fire("SPELL_GO_SELF", 13446, 17534, "0xP1", "0xP1")
  advance(7201)
  E:CombatStart()
  local stale = 0
  for _, a in pairs(E.live.actors) do stale = stale + (a.consumes or 0) end
  check("  but not from hours before", stale, 0)
  E.live, E.inCombat, E.held = realLive, realIn, {}
  Wrekkit.capture.groupMembers = realGroup
end)()

-- Drunk where we could not see: only the buff is left. Counted once per
-- buff, never twice with its own drink, nor again after a /reload.
;(function()
  local E, C = Wrekkit.encounter, Wrekkit.capture
  local realGroup, realLive, realBuffs, realUB = C.groupMembers, E.live, C.buffs, UnitBuff
  C.groupMembers = { Fuff = true }
  E.live, E.held, C.buffs, Wrekkit.db.consumeCredit = nil, {}, {}, {}
  -- Logged in wearing Flask of the Titans.
  UnitBuff = function(unit, i) if unit == "0xP1" and i == 1 then return "tex", 1, 17626 end end
  C:SeedBuffs("0xP1")
  check("a flask they arrived with is counted", E.held[1] and E.held[1].itemId, 13510)
  -- A /reload forgets every buff and finds the flask again: not twice.
  C.buffs = {}
  C:SeedBuffs("0xP1")
  check("  once, not again after a reload", table.getn(E.held), 1)
  UnitBuff = realUB
  -- A drink seen, then its buff: one use.
  fire("SPELL_GO_SELF", 13452, 17538, "0xP1", "0xP1")
  C:Buff("0xP1", 2, 17538, true, 0)
  check("a seen drink and its buff are one use", table.getn(E.held), 2)
  -- The buff beating its own cast here: still one.
  C:Buff("0xP1", 3, 17543, true, 0)
  fire("SPELL_GO_SELF", 13457, 17543, "0xP1", "0xP1")
  check("  as is a buff that beat its drink here", table.getn(E.held), 3)
  -- A buff that is no consumable's: nothing.
  C:Buff("0xP1", 4, 25290, true, 0)
  check("other buffs are not consumables", table.getn(E.held), 3)
  -- 10/17 Molten Core: a tank flasks before the invite. Its drink is
  -- not the group's yet, but its flask, found on them once they are, is.
  E.held = {}
  C.groupMembers = { Fuff = true }
  fire("SPELL_GO_OTHER", 0, 17626, "0xP2", "0xP2")   -- Elfpriest, not yet invited
  E:CombatStart()
  E:CombatEnd()
  C.groupMembers = { Fuff = true, Elfpriest = true }
  UnitBuff = function(unit, i) if unit == "0xP2" and i == 1 then return "tex", 1, 17626 end end
  C.buffs["0xP2"] = nil
  E.live, E.held = nil, {}
  C:SeedBuffs("0xP2")
  UnitBuff = realUB
  check("a flask drunk before the invite counts once they join", E.held[1] and E.held[1].itemId, 13510)
  E.live, E.held, C.buffs = realLive, {}, realBuffs
  C.groupMembers, Wrekkit.db.consumeCredit = realGroup, {}
end)()

-- The drilldown separates them by item, not one lumped total.
local consDetail = Wrekkit.report:Abilities(consBy["Fuff"], "consumes")
for _, a in ipairs(consDetail) do
  print(string.format("    %-24s x%d", a.name, a.amount))
end
check("two distinct items", table.getn(consDetail), 2)
check("the repeated one is counted twice", consDetail[1].amount, 2)

-- Priced at the auction house, through aux (and so through the scans other
-- accounts share into it). A function of its own: the main chunk is at
-- Lua's 200 locals.
;(function()
  local P = Wrekkit.prices
  check("no aux, no price", P:Value(13446), nil)
  check("money: gold and silver", Wrekkit.Money(123456), "12g 34s")
  check("money: silver and copper", Wrekkit.Money(4510), "45s 10c")
  check("money: copper", Wrekkit.Money(8), "8c")
  check("money: nothing", Wrekkit.Money(0), "-")

  -- aux's saved table, read straight (never through aux's functions, which
  -- write as they read): "next_push#today's lowest#price@day;..." newest
  -- first. Its weighted "Value" is deliberately not used: it lags.
  local now = time()
  local function rec(lowest, ...)
    local days, given = {}, { ... }   -- the harness is Lua 5.4: no implicit `arg`
    for i = 1, table.getn(given), 2 do
      table.insert(days, string.format("%.0f@%.0f", given[i], now - given[i + 1] * 86400))
    end
    return string.format("%.0f#%s#%s", now + 3600, lowest and string.format("%.0f", lowest) or "",
      table.concat(days, ";"))
  end
  local hist = {
    ["13446:0"] = rec(nil, 12000, 1, 15000, 2),   -- out of stock today: yesterday's, not older
    ["20520:0"] = rec(300),                       -- listed today
    ["13444:0"] = rec(9000, 5000, 1),             -- today beats yesterday
    ["61198:0"] = rec(50000),
    ["61675:0"] = rec(999999),
  }
  local realCVar, realFaction = GetCVar, UnitFactionGroup
  GetCVar = function(k) if k == "realmName" then return "Testrealm" end return realCVar and realCVar(k) end
  UnitFactionGroup = function() return "Alliance" end
  aux = { faction = { ["Testrealm|Alliance"] = { history = hist } } }
  P.cache = {}
  check("not listed today: the latest day's price, kept while out of stock", P:Value(13446), 12000)
  check("listed today: today's lowest buyout", P:Value(20520), 300)
  check("today's price beats an older day's", P:Value(13444), 9000)
  check("nothing for an item aux never saw", P:Value(99999), nil)
  -- Nordanaar Herbal Tea and Dreamtonic are valued by the Small Dream
  -- Shard, whatever their own listings say.
  check("Nordanaar Herbal Tea: a fifth of a Small Dream Shard", P:Value(61675), 10000)
  check("Dreamtonic: one Small Dream Shard", P:Value(61423), 50000)
  hist["13446:0"] = rec(99)
  check("  and a minute's cache, not a lookup per repaint", P:Value(13446), 12000)
  advance(61)
  check("  then read again", P:Value(13446), 99)
  hist["13446:0"] = rec(nil, 12000, 1)
  P.cache = {}

  local cost = Wrekkit.metrics.Get("consumeCost")
  check("Consumes (gold): two potions and the cheap item", cost.value(consBy["Fuff"]), 2 * 12000 + 300)
  check("  shown as money", cost.sub(consBy["Fuff"]), "2g 43s")
  local priced = Wrekkit.report:Abilities(consBy["Fuff"], "consumeCost")
  check("  the dearest item first", priced[1].id, 13446)
  check("  its cost", priced[1]._value, "2g 40s")
  check("  how many, at what", priced[1]._note, "2 x 1g 20s")
  -- Something aux has never priced counts for nothing, and says so.
  P.cache = {}
  hist["20520:0"] = nil
  check("an unpriced item is flagged in the row", cost.sub(consBy["Fuff"]), "2g 40s |cff9d9d9d+1?|r")
  local unpriced = Wrekkit.report:Abilities(consBy["Fuff"], "consumeCost")
  check("  and in the detail", unpriced[2]._value, "no price")
  -- Saved pulls keep their items as a list: priced the same.
  P.cache = {}
  check("a saved pull's item list is priced too",
    P:Cost({ { id = 13446, name = "Potion", amount = 3 } }), 36000)

  -- Closing the auction house takes in today's aux prices (not older days')
  -- as our own sightings, so they are shared like ones.
  hist["20520:0"] = rec(300)
  Wrekkit.db.prices = {}
  local imported = P:ImportAux()
  check("aux's prices from today are taken in", Wrekkit.db.prices[20520] and Wrekkit.db.prices[20520].p, 300)
  check("  but not an older day's", Wrekkit.db.prices[13446], nil)
  check("  as our own sighting", Wrekkit.db.prices[20520] and Wrekkit.db.prices[20520].by, UnitName("player"))
  check("  the shard among them", Wrekkit.db.prices[61198] and Wrekkit.db.prices[61198].p, 50000)
  check("  counted", imported >= 3, true)
  Wrekkit.db.prices = {}

  aux, GetCVar, UnitFactionGroup = nil, realCVar, realFaction
  P.cache = {}
end)()

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

-- The server flags about ten messages in a row as spam: eight go, then a
-- pause, then the rest.
;(function()
  local A = Wrekkit.announce
  A.burst, A.lastSentAt = 0, nil
  local t = NOW
  for i = 1, A.BURST do
    check("  burst line " .. i .. " goes now", A:SendWait(t), 0)
    A.burst, A.lastSentAt = (A.burst or 0) + 1, t
    t = t + 0.4
  end
  local wait = A:SendWait(t)
  check("the ninth waits out the pause", wait > 0 and math.abs(wait - (A.BURST_PAUSE - 0.4)) < 0.01, true)
  check("after the pause the count starts over", A:SendWait(t + wait), 0)
  check("  and the guard has let go", A.burst, 0)
  A.burst, A.lastSentAt = 0, nil
end)()

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

-- One pull picked from late in the night is charted on its own clock.
do
  local late = {}
  for k, v in pairs(reloaded[1]) do late[k] = v end
  late.offset = 5400
  local _, ln, _, _, lbase = Wrekkit.report:Series({ late }, 3)
  local _, n0 = Wrekkit.report:Series({ reloaded[1] }, 3)
  check("a late pull's timeline starts at its own second 0", lbase, 5400)
  check("and spans only that pull", ln, n0 - math.floor(reloaded[1].offset or 0))
  local early = {}
  for k, v in pairs(reloaded[1]) do early[k] = v end
  early.offset = 5000
  local _, both = Wrekkit.report:Series({ early, late }, 3)
  check("two pulls keep their distance apart", both, 400 + ln)
end

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
  Wrekkit.store.journalBytes = nil
  Wrekkit.store.journalExists = nil
  Wrekkit.store.needNewline = nil
  Wrekkit.store.recovered = nil
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

--[[ The crash that actually happens, and the history's cap.

     A crash does not wipe SavedVariables: they keep the last CLEAN save, and
     the pulls since exist only in the journal. Every login restores those --
     and only those. The journal keeps every pull ever recorded while the
     history keeps its newest few, so restoring everything the history lacks
     would undo the cap at every login. Its own scope: the main chunk is near
     Lua's 200-local limit. ]]
do
local function copyOf(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copyOf(v) end
  return c
end

local said = {}
local keepPrint = Wrekkit.Print
Wrekkit.Print = function(msg) table.insert(said, tostring(msg)) end
local function saidOnce(text)
  return table.getn(said) == 1 and string.find(said[1], text, 1, true) ~= nil
end

local function journal() return DISK[Wrekkit.store:Filename()] or "" end

--- A clean logout: PLAYER_LOGOUT marks the journal, then SavedVariables are
--- written out. The copy is what they hold.
local function cleanLogout()
  Wrekkit.store:MarkSaved()
  return copyOf(WrekkitDB)
end

--- The next login, from whatever the last save left -- a clean logout's, or
--- an older one when a crash came since. Recovery runs as it loads.
local function login(saved)
  WrekkitDB = copyOf(saved)
  Wrekkit.InitDB()
  simulateReload()
  said = {}
  Wrekkit.store:Recover()
end

local function fresh(cap)
  WrekkitDB = nil
  Wrekkit.InitDB()
  Wrekkit.db.maxEncounters = cap
  simulateReload()
  DISK[Wrekkit.store:Filename()] = nil
  advance(3600)                  -- clear of any earlier section's session
end

local function pulls(n)
  for i = 1, n do advance(40) pull(20) end
end

local function starts()
  local out = {}
  for _, e in ipairs(Wrekkit.db.encounters) do table.insert(out, e.startTime) end
  return table.concat(out, ",")
end

-- The crash.
fresh()
pulls(1)
local saved = cleanLogout()
pulls(2)                         -- journaled as they end; then the crash
local lost = starts()
login(saved)
check("the login after a crash brings back the pulls it lost", starts(), lost)
check("  and says so", saidOnce("recovered 2 fight"), true)
said = {}
Wrekkit.store:Recover()
check("recovering again changes nothing", starts(), lost)
check("  and says nothing", table.getn(said), 0)

-- The saved session pointer is from before the crash. Resuming from it
-- would reuse the ids of the pulls just restored.
pulls(1)
local ids, reused = {}, false
for _, e in ipairs(Wrekkit.db.encounters) do
  local k = tostring(e.sessionId) .. ":" .. tostring(e.id)
  if ids[k] then reused = true end
  ids[k] = true
end
check("the next pull gets an id none of the restored ones has", reused, false)
check("  and carries on their session",
  Wrekkit.db.encounters[4].sessionId, Wrekkit.db.encounters[3].sessionId)

-- The same crash on a history saved before there were marks (0.4.2).
fresh()
pulls(1)
saved = copyOf(WrekkitDB)
pulls(2)
lost = starts()
login(saved)
check("a crash before the first mark is recovered too", starts(), lost)
said = {}
DISK[Wrekkit.store:Filename()] = nil
Wrekkit.store:Recover()
check("a login with no journal at all says nothing", table.getn(said), 0)

-- A full history. The cap dropped pulls the journal still has, and a login
-- has to leave them dropped: the first cut of this restored all of them.
fresh(3)
pulls(6)
check("the journal keeps every pull",
  table.getn(Wrekkit.store:Deserialize(journal())), 6)
check("  the history just the newest 3", table.getn(Wrekkit.db.encounters), 3)
local kept = starts()
saved = cleanLogout()
login(saved)
check("the next login restores nothing the cap dropped", starts(), kept)
check("  and says nothing", table.getn(said), 0)
local unmarked = copyOf(saved)
unmarked.journalMarks = nil
login(unmarked)
check("nor does the first login without a mark", starts(), kept)
check("  which says nothing either", table.getn(said), 0)

-- Raise the cap, as the "history is full" warning suggests, then crash. Only
-- the pull the crash lost comes back -- not the old ones the cap dropped
-- before, which would now fit.
fresh(3)
pulls(6)
Wrekkit.db.maxEncounters = 10
saved = cleanLogout()
unmarked = copyOf(saved)
unmarked.journalMarks = nil
pulls(1)
kept = starts()
login(saved)
check("after raising the cap, a crash brings back only what it lost", starts(), kept)
check("  and counts just that", saidOnce("recovered 1 fight"), true)
login(unmarked)
check("  the same without a mark", starts(), kept)

-- A crash after the history filled: what comes back is what a clean logout
-- would have kept, and only the restored pulls it kept are counted.
fresh(3)
pulls(3)
saved = cleanLogout()
pulls(4)
kept = starts()
login(saved)
check("a crash past the cap comes back as a clean logout would have left it",
  starts(), kept)
check("  counting the restored pulls it kept", saidOnce("recovered 3 fight"), true)

-- A journal that has not grown since the clean save is not even parsed: it
-- holds every pull ever, and parsing it at every login costs more each raid.
fresh()
pulls(2)
check("the journal's length is tracked as pulls are appended",
  Wrekkit.store.journalBytes, string.len(journal()))
saved = cleanLogout()
local parses = 0
local realDeserialize = Wrekkit.store.Deserialize
Wrekkit.store.Deserialize = function(self, text)
  parses = parses + 1
  return realDeserialize(self, text)
end
login(saved)
check("a journal unchanged since the clean save is not parsed", parses, 0)
check("  its length known from the read", Wrekkit.store.journalBytes, string.len(journal()))
pulls(1)
login(saved)                     -- a crash: that pull was never saved
check("  one that grew is", parses, 1)
check("  and gives the pull back", table.getn(Wrekkit.db.encounters), 3)
Wrekkit.store.Deserialize = realDeserialize
Wrekkit.SetLocked(Wrekkit.db.encounters[1], true)     -- rewrites the journal
check("the length stays right through a rewrite",
  Wrekkit.store.journalBytes, string.len(journal()))
Wrekkit.store:Save()
check("  a full save", Wrekkit.store.journalBytes, string.len(journal()))
pulls(1)
check("  and the appends after them", Wrekkit.store.journalBytes, string.len(journal()))

-- A crash in the middle of a write, rather than between them.
print("\n-- crash during a write --")

-- Torn append: the pull being written when the client died is cut off.
fresh()
pulls(2)
saved = cleanLogout()
pulls(1)
local whole = journal()
DISK[Wrekkit.store:Filename()] = string.sub(whole, 1, string.len(whole) - 40)
login(saved)
check("a pull torn mid-write is dropped, not half-imported",
  table.getn(Wrekkit.db.encounters), 2)
local reread, dropped = Wrekkit.store:Deserialize(journal())
check("  the journal is repaired at login", dropped, 0)
check("  and ends on a whole line", string.sub(journal(), -1), "\n")
pulls(1)
reread, dropped = Wrekkit.store:Deserialize(journal())
check("  the next pull lands whole after it", table.getn(reread), 3)
check("  with nothing torn", dropped, 0)

-- A torn tail with no repair in between: the next append must not glue
-- its first line onto the torn one.
fresh()
pulls(1)
whole = journal()
DISK[Wrekkit.store:Filename()] = string.sub(whole, 1, string.len(whole) - 5)
simulateReload()
Wrekkit.store:ReadJournal()
pulls(1)
reread, dropped = Wrekkit.store:Deserialize(journal())
check("an append after a torn tail starts on a new line", table.getn(reread), 1)
check("  the torn one is the only loss", dropped, 1)

-- Torn rewrite: the backup was written whole first, the journal half way.
fresh()
saved = cleanLogout()
pulls(3)
Wrekkit.SetLocked(Wrekkit.db.encounters[1], true)    -- a full rewrite
whole = journal()
check("a rewrite writes the backup too",
  DISK[Wrekkit.store:BackupName()] == whole, true)
DISK[Wrekkit.store:Filename()] = string.sub(whole, 1, math.floor(string.len(whole) / 2))
login(saved)
check("a journal torn mid-rewrite is recovered from the backup",
  table.getn(Wrekkit.db.encounters), 3)
reread, dropped = Wrekkit.store:Deserialize(journal())
check("  and repaired from it", table.getn(reread), 3)

-- Files from before the end marker read exactly as they always did.
local legacy = string.gsub(string.gsub(journal(), "Z~[^\n]*\n", ""), "V~2\n", "")
reread, dropped = Wrekkit.store:Deserialize(legacy)
check("a journal without end markers still reads", table.getn(reread), 3)
check("  and nothing in it is called torn", dropped, 0)

-- Growth: past the limit the journal is cut back to the history.
fresh(4)
Wrekkit.store.COMPACT_AT = 2000
pulls(7)
saved = cleanLogout()
login(saved)
check("an oversized journal is compacted to the history",
  table.getn((Wrekkit.store:Deserialize(journal()))), 4)
check("  its length tracked", Wrekkit.store.journalBytes, string.len(journal()))
Wrekkit.store.COMPACT_AT = 1024 * 1024

print("\n-- freeing memory after a fight --")
local collected = 0
local realCollect = collectgarbage
collectgarbage = function(...)
  if select("#", ...) == 0 then collected = collected + 1 end
  return realCollect(...)
end
Wrekkit.tidyFloor = -1e9
local wasInCombat = IN_COMBAT
IN_COMBAT = true
check("never in combat", Wrekkit.Tidy(true), false)
IN_COMBAT = false
Wrekkit.encounter.live = { }
check("never while a pull is open", Wrekkit.Tidy(true), false)
Wrekkit.encounter.live = nil
check("out of combat, with memory to free, it collects", Wrekkit.Tidy(), true)
check("  once", collected, 1)
check("not again until memory has grown", Wrekkit.Tidy(), false)
check("  forced, it does", Wrekkit.Tidy(true), true)
local scheduled = 0
local realAfter = Wrekkit.After
Wrekkit.After = function(delay, fn, key)
  if key == "tidy" then scheduled = scheduled + 1 end
  return realAfter(delay, fn, key)
end
Wrekkit.ScheduleTidy()
check("a finished fight schedules it", scheduled, 1)
Wrekkit.db.tidy = false
Wrekkit.ScheduleTidy()
check("  switched off, it does not", scheduled, 1)
Wrekkit.db.tidy = nil
Wrekkit.After = realAfter
Wrekkit.Cancel("tidy")
IN_COMBAT = wasInCombat
collectgarbage = realCollect

print("\n-- saved settings are kept in range --")
WrekkitDB = { fontScale = 0, meter = { rowHeight = 0, opacity = 7, combat = "sometimes",
  metric = "gone", segment = "back9", window = { w = 1, h = 1 } },
  shareChannel = "WHISPER", threat = { tankMode = true, warnAt = 95, dangerAt = 60,
  display = "sideways", interval = 0 } }
Wrekkit.InitDB()
check("a zero text scale is restored", Wrekkit.db.fontScale, 0.7)
check("a zero row height is restored", Wrekkit.db.meter.rowHeight, 10)
check("opacity is capped", Wrekkit.db.meter.opacity, 1)
check("an unknown combat mode is reset", Wrekkit.db.meter.combat, "show")
check("a metric that no longer exists is reset", Wrekkit.db.meter.metric, "damage")
check("an unknown segment is reset", Wrekkit.db.meter.segment, "current")
check("WHISPER is not an addon channel", Wrekkit.db.shareChannel, "AUTO")
local ts = Wrekkit.threat:Settings()
check("tank mode from an older build carries over", ts.tankMode, "on")
check("danger is never below warn", ts.dangerAt >= ts.warnAt, true)
check("an unknown display is reset", ts.display, "docked")
check("the request interval has a floor", ts.interval, 0.25)

-- The history is the account's, the journals each character's. A crash on
-- one character still comes back after another has logged out cleanly since,
-- with a pull newer than anything the crash lost. The other character raids
-- on its own lockout: on the SAME one it would resume the crashed session
-- from the stale pointer and could take a lost pull's id -- a limit of
-- identity by session and id that /wrek load shares.
fresh()
local realUnitName = UnitName
local function playAs(name)
  UnitName = function(u)
    if u == "player" then return name end
    return realUnitName(u)
  end
  DISK[Wrekkit.store:Filename()] = nil
end
playAs("Bee")
pulls(1)
saved = cleanLogout()
pulls(2)                         -- then two more, and a crash
local beeJournal = journal()
playAs("Ay")
login(saved)
local beeLockout = SAVED_ID
SAVED_ID = beeLockout + 1
pulls(1)
SAVED_ID = beeLockout
saved = cleanLogout()
playAs("Bee")
DISK[Wrekkit.store:Filename()] = beeJournal
login(saved)
check("a crash on one character comes back after another's clean logout",
  saidOnce("recovered 2 fight"), true)
check("  into the account's history", table.getn(Wrekkit.db.encounters), 4)
UnitName = realUnitName

Wrekkit.Print = keepPrint
Wrekkit.db.maxEncounters = nil
end


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

REAL_NP = GetSpellNameAndRankForId
GetSpellNameAndRankForId = nil
-- Names learned before 0.9.27 were paired loosely and are dropped.
Wrekkit.db.spellNamesVersion = nil
Wrekkit.db.spellNames = { [75] = "Roasted Boar Meat" }
check("names learned the old way are dropped", Wrekkit.capture:LearnedNames()[75], nil)

local freshId = 25309
fire("SPELLCAST_START", "Immolate", 2000)
advance(2)
fire("SPELL_GO_SELF", 0, freshId, "0xP1", "0xBoss")
check("the name was learned from the cast",
  Wrekkit.db.spellNames[freshId], "Immolate")

-- An instant landing mid-cast (an Auto Shot while eating) is not the cast.
fire("SPELLCAST_START", "Roasted Boar Meat", 3000)
advance(1)
fire("SPELL_GO_SELF", 0, 75, "0xP1", "0xBoss")
check("an instant mid-cast does not take the name", Wrekkit.db.spellNames[75], nil)
-- Nor someone else's cast landing when yours was due.
advance(2)
fire("SPELL_GO_OTHER", 0, 25312, "0xP2", "0xBoss")
check("someone else's cast does not take it", Wrekkit.db.spellNames[25312], nil)
fire("SPELL_GO_SELF", 0, 25313, "0xP1", "0xBoss")
check("your own, on time, does", Wrekkit.db.spellNames[25313], "Roasted Boar Meat")
fire("SPELL_GO_SELF", 0, 25314, "0xP1", "0xBoss")
check("and a name is used once", Wrekkit.db.spellNames[25314], nil)

-- Nampower names any id, instants too, when SuperWoW is missing.
GetSpellNameAndRankForId = function(id)
  if id == 14285 then return "Arcane Shot", "Rank 6" end
end
check("nampower names a spell without SuperWoW", Wrekkit.capture:Spell(14285), "Arcane Shot (Rank 6)")
GetSpellNameAndRankForId = nil

-- A stale cast start must not label an unrelated spell seconds later.
fire("SPELLCAST_START", "Corruption")
advance(5)
fire("SPELL_GO_SELF", 0, 25310, "0xP1", "0xBoss")
check("a stale cast name is not bound", Wrekkit.db.spellNames[25310], nil)

-- And with SuperWoW present, learning is skipped entirely.
SpellInfo = realSpellInfo
GetSpellNameAndRankForId = REAL_NP
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
     exactly where the resist statistics were lost once already. The pull
     above went through it when combat ended; Persist only ever takes a live
     pull, so a stored record is not handed back to it. ]]
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

-- In a raid, the client's word beats health. Molten Core trash has far
-- more than the threshold and used to be saved as a boss every time.
do
  local realRaid = GetNumRaidMembers
  GetNumRaidMembers = function() return 20 end
  WORLD["0xSurger"] = { name = "Lava Surger", isPlayer = false, maxHealth = 180000,
    health = 180000, rank = "elite", level = 62 }
  WORLD["0xMagma"] = { name = "Magmadar", isPlayer = false, maxHealth = 800000,
    health = 800000, rank = "elite", level = -1 }
  WORLD["0xTwin"] = { name = "Basalthar", isPlayer = false, maxHealth = 600000,
    health = 600000, rank = "elite", level = 63 }
  WORLD["0xSkull"] = { name = "Some New Boss", isPlayer = false, maxHealth = 300000,
    health = 300000, rank = "elite", level = -1 }
  check("raid trash with lots of health is trash", Wrekkit.IsBoss(pullOn("0xSurger")), false)
  check("a skull-level raid boss is a boss", Wrekkit.IsBoss(pullOn("0xMagma")), true)
  check("a known boss is a boss whatever its level", Wrekkit.IsBoss(pullOn("0xTwin")), true)
  check("an unknown skull is a boss too", Wrekkit.IsBoss(pullOn("0xSkull")), true)

  -- A boss fight is named after the boss, not a bigger add.
  WORLD["0xBigAdd"] = { name = "Core Rager", isPlayer = false, maxHealth = 2000000,
    health = 2000000, rank = "elite", level = 62 }
  Wrekkit.encounter:CombatStart()
  for _ = 1, 8 do
    fire("AUTO_ATTACK_SELF", "0xP1", "0xBigAdd", 300, 0, 0, 1, 0, 0, 0)
    fire("AUTO_ATTACK_SELF", "0xP1", "0xMagma", 300, 0, 0, 1, 0, 0, 0)
    advance(1)
  end
  Wrekkit.encounter:CombatEnd()
  Wrekkit.encounter:Finish()
  local list = Wrekkit.report:CurrentSession().encounters
  local mixed = list[table.getn(list)]
  check("a boss with a bigger add is named after the boss", mixed.name, "Magmadar")
  check("and is a boss", Wrekkit.IsBoss(mixed), true)
  local rec = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
  check("the boss's level is saved for later", rec.bossLevel, -1)
  GetNumRaidMembers = realRaid
end

-- Pulls saved under the old rule are judged again, once.
do
  local recs = {
    { name = "Lava Surger", boss = true, bossBy = "guess", actors = {} },
    { name = "Garr", boss = false, bossBy = "guess", actors = {} },
    { name = "Firesworn", boss = false, bossBy = "guess",
      actors = { x = { name = "Garr", isPlayer = false } } },
    { name = "Lava Surger", boss = true, bossBy = "you", actors = {} },
  }
  local changed = Wrekkit.RejudgeBosses(recs)
  check("old trash marked a boss is trash now", recs[1].boss, false)
  check("a known boss is a boss now", recs[2].boss, true)
  check("a known boss among the enemies counts", recs[3].boss, true)
  check("a mark made by hand is left alone", recs[4].boss, true)
  check("the re-check counts what it changed", changed, 3)
  recs[1].boss = true
  Wrekkit.RejudgeBosses(recs)
  check("and runs once per pull", recs[1].boss, true)
end

Wrekkit.ResetData("all")

-- History: a raid week, however many pulls that is.
do
  local saved = Wrekkit.db.encounters
  local now = time()
  local list = {}
  for i = 1, 150 do table.insert(list, { id = i, startTime = now - 3600 }) end
  table.insert(list, 1, { id = "old", startTime = now - 8 * 86400 })
  table.insert(list, 1, { id = "oldLocked", startTime = now - 30 * 86400, locked = true })
  Wrekkit.db.keepDays, Wrekkit.db.maxEncounters = 7, 0
  local removed = Wrekkit.TrimHistory(list)
  check("a week of pulls is kept, with no count cap", table.getn(list), 151)
  check("a pull older than the week goes", removed, 1)
  check("a locked pull stays however old", list[1].id, "oldLocked")
  Wrekkit.db.maxEncounters = 100
  Wrekkit.TrimHistory(list)
  check("a count cap still applies if set", table.getn(list), 100)
  Wrekkit.db.maxEncounters = 0
  Wrekkit.db.encounters = saved

  local db = { maxEncounters = 60 }
  Wrekkit.SanitizeDB(db)
  check("the old 60-pull cap becomes no limit", db.maxEncounters, 0)
  db.maxEncounters = 60
  Wrekkit.SanitizeDB(db)
  check("but a 60 chosen later is kept", db.maxEncounters, 60)
  check("a week is the default", db.keepDays, 7)
end

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
  if string.find(tostring(msg), "history is capped", 1, true) then said = said + 1 end
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
print("\n-- shared helpers for the sections below --")
----------------------------------------------------------------------
-- Globals, not locals: this file's main chunk is at Lua's 200-local cap.
TH = {}

function TH.setRaid(names)
  GetNumRaidMembers = function() return table.getn(names) end
  GetRaidRosterInfo = function(i)
    local n = names[i]
    if not n then return nil end
    local token
    for _, d in pairs(WORLD) do
      if d.name == n and d.isPlayer then token = d.class end
    end
    return n, 0, 1, 60, token, token
  end
  Wrekkit.capture:ScanRoster()
end

function TH.clearRaid()
  GetNumRaidMembers = function() return 0 end
  GetRaidRosterInfo = function() return nil end
  Wrekkit.capture:ScanRoster()
end

function TH.runTimers()
  local t = _G.WrekkitTicker
  if t and t:GetScript("OnUpdate") then t:GetScript("OnUpdate")() end
end

function TH.lastStored()
  return Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
end

function TH.rowOf(view, metric, name)
  for _, r in ipairs(Wrekkit.report:Rank(view, metric)) do
    if r.name == name then return r end
  end
  return nil
end

function TH.rate(view, name, basisName)
  Wrekkit.db.dpsBasis = basisName
  local r = TH.rowOf(view, "dps", name)
  Wrekkit.db.dpsBasis = nil
  return r and r._v
end

----------------------------------------------------------------------
print("\n-- active time --")
----------------------------------------------------------------------
do
-- Recount divides by the time someone spent acting. Every action covers
-- the next 3.5 seconds and active time is the union of those windows.
-- Counting seconds-that-held-an-event read a busy caster at 2.5x their
-- real rate; summing owner and pet counted a hunter as busier than the
-- fight was long.

Wrekkit.ResetData("all")
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
for sec = 1, 10 do
  Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
  if sec <= 2 then Wrekkit.encounter:Damage("0xP2", "0xBoss", 11267, 100, {}) end
  advance(1)
end
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local enc = TH.lastStored()
local byName = {}
for _, a in pairs(enc.actors or {}) do byName[a.name] = a end
check("busy all fight: active is the fight, no more", byName["Fuff"].active, 10, 0.01)
check("two early actions: one window, first to last + 3.5s",
  byName["Elfpriest"].active, 4.5, 0.01)

local view = Wrekkit.report:View({ enc }, { petMode = "merge" })
check("busy all fight reads the same on both bases",
  TH.rate(view, "Fuff", "active"), TH.rate(view, "Fuff", "combat"), 0.5)
check("the brief actor rises on active time",
  TH.rate(view, "Elfpriest", "active") > TH.rate(view, "Elfpriest", "combat") * 2, true)

-- A caster landing 2.5s casts back to back is acting the whole pull.
Wrekkit.ResetData("all")
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
for i = 1, 8 do
  advance(2.5)
  Wrekkit.encounter:Damage("0xP2", "0xBoss", 25304, 1000, {})
end
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
enc = TH.lastStored()
view = Wrekkit.report:View({ enc }, {})
local caster = TH.rowOf(view, "damage", "Elfpriest")
-- The first cast lands 2.5s in, and nothing before it can be seen.
check("a caster busy throughout is active from the first landing on",
  caster.active, 17.5, 0.01)
check("so their active rate is close to combat, not 2.5x it",
  TH.rate(view, "Elfpriest", "active") < TH.rate(view, "Elfpriest", "combat") * 1.2, true)

-- Hunter and pet, both busy every second: the union, not the sum.
Wrekkit.ResetData("all")
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
for sec = 1, 10 do
  Wrekkit.encounter:Damage("0xP3", "0xBoss", 75, 100, {})
  Wrekkit.encounter:Damage("0xPet1", "0xBoss", 16827, 100, {})
  advance(1)
end
local live = Wrekkit.encounter.live
local liveView = Wrekkit.report:View({ live }, { petMode = "merge" })
check("live: hunter with pet is active for the fight, not twice it",
  TH.rowOf(liveView, "damage", "Moorhunt").active, 10, 0.01)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
enc = TH.lastStored()
check("the union is stored per player", enc.activeGroup["Moorhunt"], 10, 0.01)

local merged = Wrekkit.report:View({ enc }, { petMode = "merge" })
check("merged: the pet does not halve the active rate",
  TH.rate(merged, "Moorhunt", "active"), TH.rate(merged, "Moorhunt", "combat"), 0.5)
local separate = Wrekkit.report:View({ enc }, { petMode = "separate" })
check("separate: the owner row is the owner alone",
  TH.rowOf(separate, "damage", "Moorhunt").active, 10, 0.01)

-- A pull stored before the union existed falls back to the larger, not the sum.
local old = {}
for k, v in pairs(enc) do old[k] = v end
old.activeGroup = nil
local fallback = Wrekkit.report:View({ old }, { petMode = "merge" })
check("an older record never counts a moment twice",
  TH.rowOf(fallback, "damage", "Moorhunt").active, 10, 0.01)

-- Owner and pet overlapping only in part tells the union apart from both
-- wrong answers: the sum would be 9 and the larger 4.5.
Wrekkit.ResetData("all")
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP3", "0xBoss", 75, 100, {})
advance(1)
Wrekkit.encounter:Damage("0xP3", "0xBoss", 75, 100, {})
advance(2)
Wrekkit.encounter:Damage("0xPet1", "0xBoss", 16827, 100, {})
advance(1)
Wrekkit.encounter:Damage("0xPet1", "0xBoss", 16827, 100, {})
advance(6)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
enc = TH.lastStored()
merged = Wrekkit.report:View({ enc }, { petMode = "merge" })
check("owner and pet partly together: the union, not sum or larger",
  TH.rowOf(merged, "damage", "Moorhunt").active, 7.5, 0.01)

-- Dodged and parried swings are still swings.
Wrekkit.ResetData("all")
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP1", "0xBoss", 0, 100, {})
for i = 1, 4 do
  advance(2)
  Wrekkit.encounter:Miss("0xP1", "0xBoss", 0, 3)
end
advance(2)
Wrekkit.encounter:Damage("0xP1", "0xBoss", 0, 100, {})
advance(1)
live = Wrekkit.encounter.live
check("a run of dodges still counts as acting",
  Wrekkit.encounter:ActiveSeconds(live, live.actors["0xP1"]), 11, 0.01)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

-- Dividing by more than the fight lasted is never right.
local dps = Wrekkit.metrics.Get("dps")
Wrekkit.db.dpsBasis = "active"
check("active time is capped at the fight",
  dps.value({ damage = 1000, active = 50 }, { duration = 10 }), 100)
check("no active time falls back to the fight",
  dps.value({ damage = 1000, active = 0 }, { duration = 10 }), 100)
Wrekkit.db.dpsBasis = nil

Wrekkit.ResetData("all")
end

----------------------------------------------------------------------
print("\n-- death recap --")
----------------------------------------------------------------------
do
-- The question after a wipe is what the last few seconds looked like.
-- Hits go through capture here, not straight to the encounter, because
-- capture is what tracks health -- and the recap shows it.

Wrekkit.ResetData("all")
Wrekkit.capture:Unit("0xP1").health = 3000
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")

fire("AUTO_ATTACK_OTHER", "0xBoss", "0xP1", 300, 2, 0, 1, 0, 0, 0)
advance(1)
fire("SPELL_DAMAGE_EVENT_OTHER", "0xP1", "0xBoss", 99001, 450, "0,0,0", 0, 4)
advance(1)
fire("AUTO_ATTACK_OTHER", "0xBoss", "0xP1", 900, 2, 0, 1, 0, 0, 0)
fire("UNIT_DIED", "0xP1")

local live = Wrekkit.encounter.live
local death = live.deaths[1]
check("the death was recorded", death ~= nil, true)
check("holding the hits before it", table.getn(death.recap), 3)
local last = death.recap[3]
check("the killing blow is last", last.a, 900)
check("naming what did it", last.src, "Onyxia")
check("with the health left after each hit", last.hp, 1350)
check("and each line knows how long before the death it was",
  death.recap[1].ago, 2, 0.01)

-- Hits after the death must not rewrite what killed them.
for i = 1, 12 do
  advance(1)
  Wrekkit.encounter:Damage("0xBoss", "0xP1", 11605, 5, {})
end
check("the snapshot did not drift", table.getn(death.recap), 3)
check("and still ends on the killing blow", death.recap[3].a, 900)

-- Rezzed, then killed again: only the hits of THIS life.
fire("UNIT_DIED", "0xP1")
advance(20)
Wrekkit.encounter:Damage("0xBoss", "0xP1", 11605, 222, {})
Wrekkit.encounter:Damage("0xBoss", "0xP1", 11605, 333, {})
fire("UNIT_DIED", "0xP1")
local second = live.deaths[table.getn(live.deaths)]
check("a second death does not reach back past the first", table.getn(second.recap), 2)
-- Same frame, same timestamp: the order they landed in is kept.
check("the last hit in a frame is still the last line", second.recap[2].a, 333)

-- Lava and falling kill people too.
fire("ENVIRONMENTAL_DMG_OTHER", "0xP2", 3, 800, 0, 0)
fire("UNIT_DIED", "0xP2")
local lava = live.deaths[table.getn(live.deaths)]
local line = lava.recap[table.getn(lava.recap)]
check("environmental damage is in the recap", line and line.src, "Environment")
check("named for what it was", line and line.spell, "Lava")
local tookLava = false
for _, row in pairs(live.actors["0xP2"].takenAbility) do
  if row.name == "Environment (Lava)" then tookLava = true end
end
check("and named in the Taken table too, not as a number", tookLava, true)

-- The ring stays bounded however long the fight runs.
local ring = 0
for _ in pairs(live.actors["0xP1"].recent or {}) do ring = ring + 1 end
check("the ring stays bounded", ring <= 8, true)

advance(3)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local stored = TH.lastStored()
check("the recap survived persisting", stored.deaths[1].recap ~= nil, true)
local empty = Wrekkit.report:DeathRecap({ t = 5, recap = {} })
check("an empty recap explains itself", table.getn(empty), 1)
local restoredDeath = Wrekkit.report:DeathRecap({ t = 5, noRecap = true })
check("a restored log says it keeps no recap, not that nothing happened",
  string.find(restoredDeath[1].label, "totals", 1, true) ~= nil, true)

--[[ A later pull. The view moves every death onto the session timeline,
     and measuring the recap against THAT time put every line off by
     however far into the night the pull was. ]]
advance(60)
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP2", "0xBoss", 25304, 100, {})
advance(4)
Wrekkit.encounter:Damage("0xBoss", "0xP2", 11605, 700, {})
advance(1)
fire("UNIT_DIED", "0xP2")
advance(5)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local n = table.getn(Wrekkit.db.encounters)
local night = Wrekkit.report:View({ Wrekkit.db.encounters[n - 1], Wrekkit.db.encounters[n] }, {})
local lateDeath
for _, d in ipairs(night.deaths) do
  if d.name == "Elfpriest" and (not lateDeath or d.t > lateDeath.t) then
    lateDeath = d
  end
end
check("the later pull sits well into the night", lateDeath and lateDeath.t > 30, true)
local rows = Wrekkit.report:DeathRecap(lateDeath)
-- The first event, past the summary lines.
local _, _, secs = string.find((function()
  for _, r in ipairs(rows) do if r.kind ~= "sum" then return r.label end end
  return ""
end)(), "^%-(%d+%.%d)s")
check("a later pull's recap is timed from its own death", tonumber(secs), 1, 0.01)

-- The last 10 seconds, all of it: the heals that reached them and the hits
-- they avoided, not only the hits that landed -- and a summary on top.
;(function()
  Wrekkit.ResetData("all")
  IN_COMBAT = true
  fire("PLAYER_REGEN_DISABLED")
  local E = Wrekkit.encounter
  E:Damage("0xBoss", "0xP1", 0, 300, {})          -- 11s before: past the window
  advance(6)
  E:Heal("0xP2", "0xP1", 2061, 500, 100, {})
  advance(1)
  E:Miss("0xBoss", "0xP1", 0, 3)
  advance(1)
  E:Damage("0xBoss", "0xP1", 0, 2000, { crit = true })
  advance(3)
  E:Damage("0xBoss", "0xP1", 0, 900, {})
  fire("UNIT_DIED", "0xP1")
  local d = E.live.deaths[1]
  check("the recap keeps the last 10 seconds", d and table.getn(d.recap), 4)
  check("  a heal that reached them", d.recap[1].k, "h")
  check("  with its overheal", d.recap[1].x, 100)
  check("  a hit they avoided, and how", d.recap[2].x, "dodged")
  check("  a crit is marked", d.recap[3].crit, true)
  local rows = Wrekkit.report:DeathRecap(d)
  check("summary: what killed them", rows[1].label, "Killed by Onyxia (Melee)")
  check("summary: the damage they took", rows[2].value, Wrekkit.Short(2900))
  check("summary: who healed them", string.find(rows[3].label, "Elfpriest " .. Wrekkit.Short(500), 1, true) ~= nil, true)
  check("a heal reads as one", rows[4].value, "+500 (100 over)")
  check("an avoided hit says how", rows[5].value, "dodged")
  check("a crit says so", rows[6].value, "-2,000 crit")
  IN_COMBAT = false
  fire("PLAYER_REGEN_ENABLED")
end)()

Wrekkit.ResetData("all")
end

----------------------------------------------------------------------
print("\n-- buff uptime --")
----------------------------------------------------------------------
do
-- Buff events carry (guid, luaSlot, spellId, stacks, level, auraSlot, state)
-- where state is 0 added, 1 removed, 2 a stack moved on a buff that stays.

Wrekkit.ResetData("all")
Wrekkit.db.trackAuras = nil
Wrekkit.capture.buffs = {}
TH.setRaid({ "Fuff", "Elfpriest", "Moorhunt" })

-- Debuffs are followed only for Raid value, and only while it is on.
Wrekkit.db.raidValue = nil
Wrekkit.value.mob = {}
fire("DEBUFF_ADDED_OTHER", "0xBoss", 1, 17937, 1, 60, 5, 0)
check("debuffs are not followed while Raid value is off", next(Wrekkit.value.mob), nil)

-- The flask goes on BEFORE the pull, as it always does.
fire("BUFF_ADDED_SELF", "0xP1", 1, 17628, 1, 60, 3, 0)
advance(30)
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
local live = Wrekkit.encounter.live
for i = 1, 10 do
  Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
  advance(1)
end

local view = Wrekkit.report:View({ live }, {})
local fuff = TH.rowOf(view, "damage", "Fuff")
check("a flask drunk before the pull is tracked", fuff.auras[17628] ~= nil, true)
check("live, it counts from the pull start to now", fuff.auras[17628].up, 10, 0.01)
local drill = Wrekkit.report:Abilities(fuff, "uptime", { view = view })
check("the drilldown shows it as a share of the fight", drill[1] and drill[1]._value, "100%")
check("with real seconds behind the row, not zero", drill[1] and drill[1].amount, 10, 0.01)

-- A charge buff: spending charges fires removals with state 2.
fire("BUFF_ADDED_SELF", "0xP1", 2, 12970, 3, 60, 4, 0)
advance(1)
fire("BUFF_REMOVED_SELF", "0xP1", 2, 12970, 2, 60, 4, 2)
advance(1)
fire("BUFF_REMOVED_SELF", "0xP1", 2, 12970, 1, 60, 4, 2)
advance(1)
fire("BUFF_REMOVED_SELF", "0xP1", 2, 12970, 0, 60, 4, 1)
advance(1)
local flurry = live.actors["0xP1"].auras[12970]
check("spending a charge does not end the buff", flurry.up, 3, 0.01)
check("applied once, not once per charge", flurry.applied, 1)

-- Two priests' Renews: two slots of one spell.
fire("BUFF_ADDED_OTHER", "0xP1", 3, 10929, 1, 60, 5, 0)
fire("BUFF_ADDED_OTHER", "0xP1", 4, 10929, 1, 60, 6, 0)
advance(2)
fire("BUFF_REMOVED_OTHER", "0xP1", 3, 10929, 0, 60, 5, 1)
advance(2)
local renew = live.actors["0xP1"].auras[10929]
check("one of two copies ending leaves it up", renew.since ~= nil, true)
fire("BUFF_REMOVED_OTHER", "0xP1", 3, 10929, 0, 60, 6, 1)
check("the last copy ending takes it down", renew.since, nil)
check("and it counted the whole time either was up", renew.up, 4, 0.01)

-- An add for a slot already held is a repeat, not a new application.
fire("BUFF_ADDED_SELF", "0xP1", 1, 17628, 1, 60, 3, 0)
check("a repeat add changes nothing", live.actors["0xP1"].auras[17628].applied, 1)

-- Units nobody is watching.
fire("BUFF_ADDED_OTHER", "0xAdd", 1, 22222, 1, 60, 1, 0)
check("a mob gaining a buff is not made an actor", live.actors["0xAdd"], nil)
check("nor remembered", Wrekkit.capture.buffs["0xAdd"], nil)
defPlayer("0xOut", "Stranger", "MAGE", 3000)
fire("BUFF_ADDED_OTHER", "0xOut", 1, 17628, 1, 60, 1, 0)
check("a player outside the group is not followed", Wrekkit.capture.buffs["0xOut"], nil)

-- A buff alone does not put someone in the pull; acting does, and then
-- the buff is there from when it went on. (This flask's drink was counted
-- already -- otherwise its buff would count it, and using a consumable in
-- a pull does put you in it.)
Wrekkit.db.consumeCredit = { ["0xP2:17627"] = { t = time() } }
fire("BUFF_ADDED_OTHER", "0xP2", 1, 17627, 1, 60, 2, 0)
check("a buff alone makes nobody an actor", live.actors["0xP2"], nil)
advance(2)
Wrekkit.encounter:Heal("0xP2", "0xP1", 2060, 500, 0, {})
local priestFlask = live.actors["0xP2"].auras[17627]
check("once they act it is there, from when it went on",
  Wrekkit.encounter:AuraSeconds(live, priestFlask), 2, 0.01)

-- Up since before a /reload: no event was ever seen for it, so the client
-- is asked directly. SuperWoW's UnitBuff returns the spell id third.
WORLD["0xP3"].buffs = { 17626 }
UnitBuff = function(unit, i)
  local d = WORLD[unit]
  local id = d and d.buffs and d.buffs[i]
  if id then return "tex", 1, id end
  return nil
end
Wrekkit.encounter:Damage("0xP3", "0xBoss", 75, 100, {})
local hunter = live.actors["0xP3"].auras[17626]
check("a buff from before a reload is found by asking", hunter ~= nil, true)
check("and counted from the pull start", hunter and hunter.since, live.startT)
UnitBuff = nil
WORLD["0xP3"].buffs = nil

-- Dying ends every buff there and then.
local flask = live.actors["0xP1"].auras[17628]
fire("UNIT_DIED", "0xP1")
check("dying ends the flask at that moment", flask.since, nil)
check("and capture forgets the dead unit's buffs", Wrekkit.capture.buffs["0xP1"], nil)

advance(1)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local stored = TH.lastStored()
local sv = Wrekkit.report:View({ stored }, {})
local up = TH.rowOf(sv, "damage", "Fuff").auras[17628].up
check("stored: up from the pull start until the death", up, 20, 0.01)

-- Stored packed: one short string per player, each name once per pull.
-- In a function of its own: this block is at the 200-local limit.
local function packedStorage()
  local fuffStored = stored.actors["0xP1"]
  check("stored buffs are one packed string per player", type(fuffStored.auras), "string")
  check("the boss is stored", type(stored.actors["0xBoss"]), "table")
  check("  with nothing at all for buffs it never had",
    stored.actors["0xBoss"] and stored.actors["0xBoss"].auras, nil)
  check("each buff's name is kept once for the pull",
    stored.auraNames and stored.auraNames[17628], live.actors["0xP1"].auras[17628].name)
  check("and comes back with the row", TH.rowOf(sv, "damage", "Fuff").auras[17628].name,
    live.actors["0xP1"].auras[17628].name)
  check("the count of applications survives",
    TH.rowOf(sv, "damage", "Fuff").auras[17628].applied, live.actors["0xP1"].auras[17628].applied)

  --[[ 0.4.0 and 0.4.1 stored a list of rows. Those pulls are still in
       everybody's SavedVariables and have to keep reading, alone and mixed
       in with new ones. ]]
  local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
  end
  local legacy = deepCopy(stored)
  legacy.auraNames = nil
  legacy.id = (stored.id or 0) + 1000
  for guid, a in pairs(legacy.actors) do
    local liveActor = live.actors[guid]
    if a.auras and liveActor then
      local list = {}
      for id, r in pairs(liveActor.auras or {}) do
        if (r.up or 0) > 0.5 then
          table.insert(list, { id = id, name = r.name, up = r.up, applied = r.applied })
        end
      end
      a.auras = list
    end
  end
  local lv = Wrekkit.report:View({ legacy }, {})
  check("a pull stored by 0.4.1 still reads",
    TH.rowOf(lv, "damage", "Fuff").auras[17628].up, 20, 0.01)
  check("  with its names", TH.rowOf(lv, "damage", "Fuff").auras[17628].name,
    live.actors["0xP1"].auras[17628].name)
  local mixed = Wrekkit.report:View({ legacy, stored }, {})
  check("old and new pulls add up together",
    TH.rowOf(mixed, "damage", "Fuff").auras[17628].up, 40, 0.01)

  -- A name the first pull lacked is filled in by a later one.
  local unnamed = deepCopy(stored)
  unnamed.auraNames = nil
  unnamed.id = (stored.id or 0) + 2000
  local filled = Wrekkit.report:View({ unnamed, stored }, {})
  check("a later pull fills in a missing name",
    TH.rowOf(filled, "damage", "Fuff").auras[17628].name,
    live.actors["0xP1"].auras[17628].name)
end
packedStorage()

-- Ranking one chosen buff across everybody.
local metric = Wrekkit.metrics.Get("uptime")
local counted = TH.rowOf(sv, "uptime", "Fuff")
check("before a buff is chosen, rows count buffs", counted and counted._text, "3")
Wrekkit.metrics.SelectBuff(17628, "Flask of Supreme Power")
check("the title names the buff", Wrekkit.metrics.Label(metric), "Uptime: Flask of Supreme Power")
local fuffUp = TH.rowOf(sv, "uptime", "Fuff")
check("ranked by one buff, as a share of the pull", fuffUp and fuffUp._text, "95%")
local priest = TH.rowOf(sv, "uptime", "Elfpriest")
check("a player without it is listed, not hidden", priest ~= nil, true)
check("and says so", priest and priest._sub, "missing")
Wrekkit.metrics.SelectBuff(17628)
check("choosing it again clears the choice", Wrekkit.metrics.SelectedBuff(), nil)

-- Switched off, nothing is followed.
Wrekkit.db.trackAuras = false
fire("BUFF_ADDED_SELF", "0xP1", 1, 17628, 1, 60, 3, 0)
check("the setting can turn it off", Wrekkit.capture.buffs["0xP1"], nil)
Wrekkit.db.trackAuras = nil

Wrekkit.capture.buffs = {}
TH.clearRaid()
Wrekkit.ResetData("all")
end

----------------------------------------------------------------------
print("\n-- live raid sync --")
----------------------------------------------------------------------
do
-- Each client reports only its own totals; a report only ever fills a gap,
-- and has to be placed in the right pull -- including after that pull has
-- already ended here, which is when the last report of a pull arrives.

Wrekkit.ResetData("all")
Wrekkit.db.shareEnabled = true
Wrekkit.db.liveSync = true
Wrekkit.db.acceptShares = nil
GetNumRaidMembers = function() return 25 end
WIRE = {}
Wrekkit.sync.queue = {}
Wrekkit.sync.pumping = false

-- M~*~name~class~dmg~petDmg~heal~taken~petTaken~active~activeOwn~ago~dur~pid~foe
local function rep(name, class, dmg, ago, dur, pid, foe, x)
  x = x or {}
  return table.concat({ "M", "*", name, class, dmg, x.pet or 0, x.heal or 0,
    x.taken or 0, x.petTaken or 0, x.active or 0, x.activeOwn or 0,
    ago, dur, pid, foe or "" }, "~")
end
local function hear(msg, sender)
  Wrekkit.sync:OnMessage("WREKKIT", msg, "RAID", sender)
end
local function reportsSent()
  local out = {}
  for _, m in ipairs(WIRE) do
    if m.msg and string.sub(m.msg, 1, 2) == "M~" then table.insert(out, m.msg) end
  end
  for _, q in ipairs(Wrekkit.sync.queue) do
    if string.sub(q.msg, 1, 2) == "M~" then table.insert(out, q.msg) end
  end
  return out
end
local function fields(msg)
  local f = {}
  for piece in string.gfind(msg .. "~", "([^~]*)~") do table.insert(f, piece) end
  return f
end

IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
local live = Wrekkit.encounter.live
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 5000, {})
advance(3)

Wrekkit.sync:BroadcastMine()
local sent = reportsSent()
check("our own totals go out", table.getn(sent), 1)
local f = fields(sent[1] or "")
check("in the full format", table.getn(f), 15)
check("addressed to everyone, naming us", (f[2] or "") .. (f[3] or ""), "*Fuff")
check("with our damage", tonumber(f[5]), 5000)
check("how long ago our pull began", tonumber(f[12]), 3, 0.05)
check("and the enemy we fought", f[15], "Onyxia")

-- Built while another waits: it replaces that one, ahead of a transfer.
WIRE = {}
Wrekkit.sync.pumping = true
Wrekkit.sync.queue = { { msg = "D~*~1~1~x", channel = "RAID" } }
Wrekkit.sync:BroadcastMine()
Wrekkit.sync:BroadcastMine()
local waiting = 0
for _, q in ipairs(Wrekkit.sync.queue) do if q.latest then waiting = waiting + 1 end end
check("only the newest report waits", waiting, 1)
check("and it goes first", Wrekkit.sync.queue[1].latest, true)
Wrekkit.sync.queue = {}
Wrekkit.sync.pumping = false

-- A report for the pull we are in.
hear(rep("Faraway", "MAGE", 9000, 3, 3, 11, "Onyxia"), "Faraway")
local view = Wrekkit.report:View({ live }, {})
local far = TH.rowOf(view, "damage", "Faraway")
check("a report for our pull fills the gap", far and far.damage, 9000)
check("and the row is marked as reported", far and far.remote, true)

-- Measured here beats reported.
Wrekkit.encounter:Damage("0xP2", "0xBoss", 25304, 800, {})
hear(rep("Elfpriest", "PRIEST", 10, 3, 3, 12, "Onyxia"), "Elfpriest")
view = Wrekkit.report:View({ live }, {})
local pr = TH.rowOf(view, "damage", "Elfpriest")
check("a smaller report never lowers a measurement", pr and pr.damage, 800)
check("and does not mark it", pr and pr.remote, nil)

-- Refused outright.
hear(rep("Someone", "MAGE", 99999, 3, 3, 1, "Onyxia"), "Liar")
check("a report about someone else", live.remote["Someone"], nil)
Wrekkit.db.acceptShares = false
hear(rep("Another", "MAGE", 500, 3, 3, 1, "Onyxia"), "Another")
check("with accept-logs switched off", live.remote["Another"], nil)
Wrekkit.db.acceptShares = nil
hear(rep("Early", "MAGE", 500, 60, 60, 1, "Onyxia"), "Early")
check("from a pull that began well before ours", live.remote["Early"], nil)
hear(rep("Elsewhere", "MAGE", 500, 3, 3, 1, "Ragnaros"), "Elsewhere")
check("naming an enemy we never saw in this pull", live.remote["Elsewhere"], nil)
hear("M~*~Oldver~MAGE~9000~0~0~5", "Oldver")
check("in an older, shorter format", live.remote["Oldver"], nil)

-- Two pulls of the sender inside one of ours add up.
hear(rep("Split", "MAGE", 400, 3, 1, 501, ""), "Split")
hear(rep("Split", "MAGE", 300, 1, 1, 502, ""), "Split")
view = Wrekkit.report:View({ live }, {})
check("two of their pulls in one of ours add up",
  TH.rowOf(view, "damage", "Split").damage, 700)

-- Pets: merged holds the pet, separated does not.
hear(rep("Petowner", "HUNTER", 1000, 3, 3, 21, "", { pet = 500 }), "Petowner")
view = Wrekkit.report:View({ live }, { petMode = "merge" })
check("merged, the report includes the pet", TH.rowOf(view, "damage", "Petowner").damage, 1500)
view = Wrekkit.report:View({ live }, { petMode = "separate" })
check("separated, the owner row is the owner", TH.rowOf(view, "damage", "Petowner").damage, 1000)

-- The ticker reports while fighting and stops when combat does.
local calls = 0
local realBroadcast = Wrekkit.sync.BroadcastMine
Wrekkit.sync.BroadcastMine = function(self, enc)
  calls = calls + 1
  return realBroadcast(self, enc)
end
Wrekkit.sync:StartLive()
advance(31)
TH.runTimers()
check("a report goes out on the timer while in combat", calls, 1)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
calls = 0
advance(6)
TH.runTimers()
advance(31)
TH.runTimers()
advance(31)
TH.runTimers()
-- Only the final one, sent by Finish when the finish timer fires.
check("after combat only the final report goes out", calls, 1)
Wrekkit.sync.BroadcastMine = realBroadcast

-- A pull shorter than the interval still reports, at its end.
Wrekkit.ResetData("all")
WIRE = {}
Wrekkit.sync.queue = {}
Wrekkit.sync.pumping = false
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 1234, {})
advance(20)
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 1000, {})
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
sent = reportsSent()
check("a short pull reports once, at its end", table.getn(sent), 1)
f = fields(sent[1] or "")
check("with its final numbers", tonumber(f[5]), 2234)
check("and how long it ran", tonumber(f[13]), 20, 0.05)

-- The last report of a pull lands after it ended here.
advance(6)
hear(rep("Faraway", "MAGE", 7000, 26, 20, 900, "Onyxia"), "Faraway")
local stored = TH.lastStored()
check("a late report lands on the stored pull",
  stored.remote and stored.remote["Faraway"] ~= nil, true)
local sv = Wrekkit.report:View({ stored }, {})
check("and shows in it", TH.rowOf(sv, "damage", "Faraway").damage, 7000)

-- Several pulls in one view: a report fills ITS pull, never the night.
Wrekkit.ResetData("all")
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP2", "0xBoss", 25304, 300, {})
advance(10)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
advance(30)
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP2", "0xBoss", 25304, 200, {})
advance(10)
hear(rep("Elfpriest", "PRIEST", 900, 10, 10, 77, "Onyxia"), "Elfpriest")
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
local n = table.getn(Wrekkit.db.encounters)
local night = Wrekkit.report:View({ Wrekkit.db.encounters[n - 1], Wrekkit.db.encounters[n] }, {})
check("two pulls: the first is kept and the second filled",
  TH.rowOf(night, "damage", "Elfpriest").damage, 1200)
check("and the total agrees with the rows", night.totals.damage, 1200)

Wrekkit.db.liveSync = nil
Wrekkit.db.shareEnabled = false
GetNumRaidMembers = function() return 0 end
WIRE = {}
Wrekkit.sync.queue = {}
Wrekkit.sync.pumping = false
Wrekkit.ResetData("all")
end

----------------------------------------------------------------------
print("\n-- log range restore --")
----------------------------------------------------------------------
do
-- Turning the setting off puts back what the client had.
CVARS = { CombatLogRangeCreature = "30", CombatLogRangeParty = "50" }
Wrekkit.db.combatLogRange = nil
Wrekkit.db.combatLogRangeYards = nil
Wrekkit.db.combatLogRangeSaved = nil
Wrekkit.capture:ApplyCombatLogRange()
check("raised", tonumber(CVARS["CombatLogRangeCreature"]), 200)
local restored, unknown = Wrekkit.capture:RestoreCombatLogRange()
check("switched off, the old creature range is back", tonumber(CVARS["CombatLogRangeCreature"]), 30)
check("and the old party range", tonumber(CVARS["CombatLogRangeParty"]), 50)
check("nothing it could not restore", unknown, 0)

-- A value raised before anything was kept is not restored to itself.
CVARS = { CombatLogRangeCreature = "200" }
Wrekkit.capture:ApplyCombatLogRange()
restored, unknown = Wrekkit.capture:RestoreCombatLogRange()
check("an already-raised value is reported as unknown", unknown, 1)
CVARS = {}
Wrekkit.db.combatLogRangeSaved = nil
end

----------------------------------------------------------------------
print("\n-- picked players --")
----------------------------------------------------------------------
do
-- Show only chosen characters. One shared list, a switch per window. The
-- filter reaches players and their pets (a pet follows its owner), never
-- enemies, and an empty list filters nothing.

Wrekkit.ResetData("all")
Wrekkit.report:ClearPicks()
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 500, {})
Wrekkit.encounter:Damage("0xP2", "0xBoss", 25304, 400, {})
Wrekkit.encounter:Damage("0xP3", "0xBoss", 75, 300, {})
Wrekkit.encounter:Damage("0xPet1", "0xBoss", 16827, 200, {})
Wrekkit.encounter:Damage("0xBoss", "0xP1", 11605, 900, {})
advance(10)
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()
local enc = TH.lastStored()

local function shown(view, metric, filter)
  local out = {}
  for _, r in ipairs(Wrekkit.report:Rank(view, metric, filter)) do
    table.insert(out, r.name)
  end
  table.sort(out)
  return table.concat(out, ",")
end
local function picks() return { only = Wrekkit.report:Picked() } end

local merged = Wrekkit.report:View({ enc }, { petMode = "merge" })
check("nobody picked: the filter shows everyone",
  shown(merged, "damage", picks()), "Elfpriest,Fuff,Moorhunt")

Wrekkit.report:TogglePick("Fuff")
Wrekkit.report:TogglePick("Moorhunt")
check("picks are kept with the saved settings", Wrekkit.db.picked["Fuff"], true)
check("only the picked players", shown(merged, "damage", picks()), "Fuff,Moorhunt")

local byName = {}
for _, r in ipairs(Wrekkit.report:Rank(merged, "damage", picks())) do byName[r.name] = r end
check("a merged pet still counts for its picked owner", byName["Moorhunt"].damage, 500)
check("shares are of the picked players, not the raid", byName["Fuff"]._pct, 50, 0.01)

local split = Wrekkit.report:View({ enc }, { petMode = "separate" })
check("a split pet follows its picked owner",
  shown(split, "damage", picks()), "Fuff,Moorhunt,Raptor (Moorhunt)")
check("enemies are never filtered by picks", shown(merged, "enemy", picks()), "Onyxia")

-- A filtered post has to say so, or two names read as the whole raid.
local posted = Wrekkit.announce:Lines(
  { metric = "damage", encounters = { enc }, label = "Onyxia",
    filter = picks(), petMode = "merge" }, 5)
check("an announcement says it is picked players only",
  string.find(posted[1], "picked players", 1, true) ~= nil, true)
local mentionsPriest = false
for _, l in ipairs(posted) do
  if string.find(l, "Elfpriest", 1, true) then mentionsPriest = true end
end
check("and posts only the picked players", mentionsPriest, false)

Wrekkit.report:TogglePick("Fuff")
check("picking again unpicks", Wrekkit.report:IsPicked("Fuff"), false)
Wrekkit.report:TogglePick("?")
check("a name still resolving cannot be picked", Wrekkit.report:IsPicked("?"), false)
Wrekkit.report:ClearPicks()
check("clearing leaves nobody picked", Wrekkit.report:AnyPicked(), false)

Wrekkit.ResetData("all")
end

----------------------------------------------------------------------
print("\n-- more buffs than are stored --")
----------------------------------------------------------------------
do
Wrekkit.ResetData("all")
Wrekkit.db.trackAuras = nil
Wrekkit.capture.buffs = {}
TH.setRaid({ "Fuff" })

-- Thirty buffs, all up before the pull. 30001 drops a second in, so it has
-- the least uptime and is one the cap has to leave out.
for b = 1, 30 do
  fire("BUFF_ADDED_SELF", "0xP1", b, 30000 + b, 1, 60, b - 1, 0)
end
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
advance(1)
fire("BUFF_REMOVED_SELF", "0xP1", 1, 30001, 0, 60, 0, 1)
for i = 1, 9 do
  Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
  advance(1)
end
IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
Wrekkit.encounter:Finish()

local packed = TH.lastStored().actors["0xP1"].auras or ""
local _, kept = string.gsub(packed, "[^;]+", "")
check("a player's stored buffs are capped", kept, 24)
check("  keeping the longest-running",
  string.find(";" .. packed, ";30001:", 1, true), nil)

Wrekkit.capture.buffs = {}
TH.clearRaid()
Wrekkit.ResetData("all")
end

----------------------------------------------------------------------
print("\n-- per-raid files --")
----------------------------------------------------------------------
;(function()
local A = Wrekkit.archive
Wrekkit.ResetData("all")
Wrekkit.db.archives = {}
A.loaded = nil

local function aPull(seconds)
  IN_COMBAT = true
  fire("PLAYER_REGEN_DISABLED")
  for _ = 1, (seconds or 8) do
    Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {})
    advance(1)
  end
  IN_COMBAT = false
  fire("PLAYER_REGEN_ENABLED")
  Wrekkit.encounter:Finish()
  -- Writing a pull to its file is spread over frames; finish it here.
  A:Flush()
  return Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
end

local p1 = aPull(10)
local p2 = aPull(12)
local key = A:KeyFor(p1)
local e = A:Index()[key]
check("a raid pull lands in its raid's file", p1.archived, key)
check("  the file is named after the raid ID", e and string.find(e.file, tostring(p1.instanceId), 1, true) ~= nil and (p1.instanceId or 0) > 0, true)
check("  two pulls on one raid ID share it", p2.archived, key)
check("  the index counts them", e and e.pulls, 2)

-- Written whole and read back the same.
local back = A:Read(key)
check("the file reads back every pull", table.getn(back), 2)
local v1 = Wrekkit.report:View({ p1 }, {})
local v2 = Wrekkit.report:View({ back[1] }, {})
check("  with the same damage", v2.totals.damage, v1.totals.damage)
check("  and the same players", table.getn(v2.rows), table.getn(v1.rows))
check("  and the ability detail", back[1].actors and next(back[1].actors) ~= nil, true)

-- Another raid ID is another file.
local realId = SAVED_ID
SAVED_ID = 9999
Wrekkit.encounter:StartNewSession()
local p3 = aPull(8)
SAVED_ID = realId
check("another raid ID gets its own file", p3.archived ~= key, true)
check("  and its own index entry", table.getn(A:List()), 2)

-- A dungeon has no raid ID: one file per run.
local realSaved = GetNumSavedInstances
GetNumSavedInstances = function() return 0 end
Wrekkit.encounter:StartNewSession()
advance(5000)
local d1 = aPull(8)
GetNumSavedInstances = realSaved
check("a dungeon run is filed by its run", string.sub(d1.archived or "", 1, 4), "run:")

-- A write torn by a crash costs that line and nothing else.
DISK[e.file] = DISK[e.file] .. "\nR~{[\"id\"]=77,[\"sess"
local p4 = aPull(8)
Wrekkit.encounter:StartNewSession()
-- (p4 went to the same raid only if it is the same ID)
local after = A:Read(key)
check("a torn line is skipped, the rest still read", table.getn(after) >= 2, true)

-- Nothing in a file can run code.
check("a file cannot call a function", A.Deserialize("{[1]=print(\"x\")}"), nil)
check("or reach a global", A.Deserialize("os"), nil)

-- Older than the night in progress: out of SavedVariables, still on disk.
local before = table.getn(Wrekkit.db.encounters)
advance(A.HOLD + 60)
Wrekkit.TrimHistory()
check("old archived pulls leave SavedVariables", table.getn(Wrekkit.db.encounters) < before, true)
local function inSessions(rec)
  for _, s in ipairs(Wrekkit.report:Sessions()) do
    for _, r in ipairs(s.encounters) do
      if r.id == rec.id and r.sessionId == rec.sessionId then return true end
    end
  end
  return false
end
check("  and from the report until opened", inSessions(p1), false)
A:Load(key)
check("opening the raid brings them back", inSessions(p1), true)

-- A change to a pull from a file is written to the file.
local loadedP1
for _, r in ipairs(A.loaded.list) do if r.id == p1.id and r.sessionId == p1.sessionId then loadedP1 = r end end
Wrekkit.SetBoss(loadedP1, true)
A:Unload()
local reread
for _, r in ipairs(A:Read(key)) do if r.id == p1.id and r.sessionId == p1.sessionId then reread = r end end
check("marking a boss in an old raid sticks", reread and reread.boss, true)
check("letting go of it frees it", inSessions(p1), false)

-- Keep, expire, delete.
check("keeping a raid", A:SetKept(key, true), true)
advance(8 * 86400)
local gone = A:Cleanup()
check("expired raids are removed", gone, 2)
check("  but a kept one stays", A:Index()[key] ~= nil, true)
local file = A:Index()[key].file
A:Delete(key)
check("deleting a raid removes it from the list", A:Index()[key], nil)
check("  and empties its file", DISK[file], "")

-- The index survives a lost SavedVariables through its mirror.
local p5 = aPull(8)
local k5 = p5.archived
Wrekkit.db.archives = {}
check("the index comes back from its mirror", A:RestoreIndex() >= 1, true)
check("  with the raid in it", A:Index()[k5] ~= nil, true)

-- History from before this release moves into files.
local old = aPull(8)
old.archived = nil
A:Index()[A:KeyFor(old)].ids = {}
local moved = A:MigrateNow()
check("earlier pulls are moved into files", moved >= 1, true)
check("  and marked as moved", old.archived ~= nil, true)
local again = A:MigrateNow()
check("  only once", again, 0)

-- The write is spread over frames: queued at the end of the pull, on
-- disk once the slices are done, and the same text as one write.
do
  IN_COMBAT = true
  fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 8 do Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) end
  IN_COMBAT = false
  fire("PLAYER_REGEN_ENABLED")
  Wrekkit.encounter:Finish()
  local q = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
  check("a finished pull is queued, not written in that frame", q.archived, nil)
  local ticker = _G["WrekkitTicker"]
  for _ = 1, 200 do
    if q.archived then break end
    advance(0.02)
    ticker:GetScript("OnUpdate")()
  end
  check("  and is on disk a few frames later", q.archived ~= nil, true)
  local found
  for _, r in ipairs(A:Read(q.archived)) do if r.id == q.id and r.sessionId == q.sessionId then found = r end end
  check("  whole", found and found.totals and found.totals.damage, q.totals.damage)
end

-- Deleting everything also drops writes still waiting in the queue.
do
  IN_COMBAT = true
  fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 8 do Wrekkit.encounter:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) end
  IN_COMBAT = false
  fire("PLAYER_REGEN_ENABLED")
  Wrekkit.encounter:Finish()
  local q = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
  Wrekkit.ResetData("all")
  A:Flush()
  check("a reset does not write the pulls it removed", q.archived, nil)
end

-- Turned off, nothing is written.
Wrekkit.db.archiveFiles = false
local off = aPull(8)
check("turned off, a pull stays out of files", off.archived, nil)
Wrekkit.db.archiveFiles = nil

A.loaded = nil
Wrekkit.ResetData("all")
Wrekkit.db.archives = {}
end)()

----------------------------------------------------------------------
print("\n-- a pull lasts while the group fights --")
----------------------------------------------------------------------
do
-- You leave combat (dead, or done) while the raid fights on. The pull has
-- to keep going: ending it on your own REGEN_ENABLED cut the rest of the
-- fight into sub-6-second scraps, and every one of them was dropped.
local realUAC, realRaid = UnitAffectingCombat, GetNumRaidMembers
local fighting = { player = true, raid2 = true }
UnitAffectingCombat = function(unit) return fighting[unit] end
GetNumRaidMembers = function() return 2 end
local E = Wrekkit.encounter
local ticker = function() E:HealStuckCombat() end

advance(10)
local before = table.getn(Wrekkit.db.encounters)
fire("PLAYER_REGEN_DISABLED")
for _ = 1, 10 do E:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) ticker() end

fighting.player = nil
E:LeftCombat()
check("you leaving combat does not end the pull", E.inCombat, true)
for _ = 1, 20 do E:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) ticker() end
check("  nor does the ticker, while the raid fights", E.live ~= nil and E.inCombat, true)
check("  and combat time keeps counting", E:CombatTime(E.live), 30, 0.01)

fighting.raid2 = nil
advance(1)
ticker()
check("the pull ends once nobody is fighting", E.inCombat, false)
advance(6)
E:Finish()
check("  one pull, not scraps", table.getn(Wrekkit.db.encounters), before + 1)
local rec = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
check("  with all of the damage", rec and rec.totals.damage, 3000)

-- The tank pulls, and you join several seconds later. The pull the tank's
-- damage opened is the one you join; it must not be taken for a stale one,
-- finished at length 0 and dropped.
fighting.player, fighting.raid2 = nil, true
advance(30)
before = table.getn(Wrekkit.db.encounters)
for _ = 1, 8 do E:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) ticker() end
fighting.player = true
fire("PLAYER_REGEN_DISABLED")
for _ = 1, 10 do E:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) ticker() end
fighting.player, fighting.raid2 = nil, nil
E:LeftCombat()
advance(6)
E:Finish()
check("joining a pull the tank opened keeps it whole", table.getn(Wrekkit.db.encounters), before + 1)
rec = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
check("  with the damage from before you joined", rec and rec.totals.damage, 1800)
check("  and its full length", rec and rec.duration, 18, 0.01)

-- Someone stays flagged in combat long after the pack is dead. The pull
-- must still end once nothing is happening, and the next pack must be a
-- pull of its own -- not swallowed, and not dropped with it.
fighting.player, fighting.raid2 = true, true
advance(30)
before = table.getn(Wrekkit.db.encounters)
fire("PLAYER_REGEN_DISABLED")
for _ = 1, 10 do E:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) ticker() end
fighting.player = nil
E:LeftCombat()
for _ = 1, 20 do advance(1) ticker() end
check("a lingering combat flag does not hold the pull open", E.inCombat, false)
advance(6)
if E.live and not E.inCombat then E:Finish() end
rec = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
check("  it is saved", table.getn(Wrekkit.db.encounters), before + 1)
check("  and its length is the fighting, not the wait", rec and rec.duration, 10, 1)
advance(30)
for _ = 1, 5 do E:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) ticker() end
fighting.player = true
fire("PLAYER_REGEN_DISABLED")
for _ = 1, 10 do E:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) ticker() end
fighting.player, fighting.raid2 = nil, nil
E:LeftCombat()
advance(6)
E:Finish()
check("  the next pack is its own pull", table.getn(Wrekkit.db.encounters), before + 2)
rec = Wrekkit.db.encounters[table.getn(Wrekkit.db.encounters)]
check("  whole", rec and rec.totals.damage, 1500)

-- Solo, leaving combat still ends it straight away.
GetNumRaidMembers = function() return 0 end
fighting.player = true
advance(10)
fire("PLAYER_REGEN_DISABLED")
for _ = 1, 8 do E:Damage("0xP1", "0xBoss", 11267, 100, {}) advance(1) end
fighting.player = nil
E:LeftCombat()
check("solo, leaving combat ends the pull", E.inCombat, false)
E:Finish()

UnitAffectingCombat, GetNumRaidMembers = realUAC, realRaid
IN_COMBAT = true
end

----------------------------------------------------------------------
print("\n-- crit % counts what could crit --")
----------------------------------------------------------------------
do
-- What a paladin's fight looked like in the Chronicle log: swings of 2
-- (hit), 16386 (0x4002 glancing) and 130 (0x82 crit); Seal of Command
-- crits with hitInfo 2; Consecration ticks ("27,0,0,3": periodic, never
-- crits); Retribution Aura (a damage shield); and heals, some crits.
local E = Wrekkit.encounter
local IN = IN_COMBAT
IN_COMBAT = true
advance(30)
fire("PLAYER_REGEN_DISABLED")
local a = E.live and E:Actor("0xP1")
local b = { hits = a.hits, crits = a.crits, critHits = a.critHits or 0,
            healHits = a.healHits or 0, healCrits = a.healCrits or 0 }

fire("AUTO_ATTACK_SELF", "0xP1", "0xBoss", 300, 2, 0, 1, 0, 0, 0)        -- hit
fire("AUTO_ATTACK_SELF", "0xP1", "0xBoss", 200, 16386, 0, 1, 0, 0, 0)    -- glancing
fire("AUTO_ATTACK_SELF", "0xP1", "0xBoss", 600, 130, 0, 1, 0, 0, 0)      -- crit
-- On its own, before anything else could make the count come out right.
check("a 0x82 swing is a crit, and 0x4002 is not", a.crits - b.crits, 1)
fire("SPELL_DAMAGE_EVENT_SELF", "0xBoss", "0xP1", 20424, 500, "0,0,0", 2, 2, "31,0,0,0")  -- SoC crit
fire("SPELL_DAMAGE_EVENT_SELF", "0xBoss", "0xP1", 20424, 250, "0,0,0", 0, 2, "31,0,0,0")  -- SoC hit
for _ = 1, 6 do
  fire("SPELL_DAMAGE_EVENT_SELF", "0xBoss", "0xP1", 20924, 50, "0,0,0", 0, 2, "27,0,0,3")  -- Consecration tick
end
fire("DAMAGE_SHIELD_SELF", "0xP1", "0xBoss", 30, 2)                       -- Retribution Aura
-- Heals: a crit, a plain one, and two HoT ticks that cannot crit.
fire("SPELL_HEAL_BY_SELF", "0xP2", "0xP1", 10917, 900, 1, 0)
fire("SPELL_HEAL_BY_SELF", "0xP2", "0xP1", 10917, 450, 0, 0)
fire("SPELL_HEAL_BY_SELF", "0xP2", "0xP1", 25299, 100, 0, 1)
fire("SPELL_HEAL_BY_SELF", "0xP2", "0xP1", 25299, 100, 0, 1)

local d = function(k) return (a[k] or 0) - b[k] end
check("one swing crit and one spell crit", d("crits"), 2)
check("  every damage event is still a hit", d("hits"), 12)
check("  but only the 5 that could crit count toward Crit %", d("critHits"), 5)
check("  a heal crit is not a damage crit", d("crits"), 2)
check("heal crits are counted apart", d("healCrits"), 1)
check("  HoT ticks are not chances to crit", d("healHits"), 2)
-- The metric, on just these events.
local crit = Wrekkit.metrics.byKey.crit.value({ crits = d("crits"), critHits = d("critHits"), hits = d("hits") })
check("Crit % is 2 of 5", crit, 40, 0.01)
local hcrit = Wrekkit.metrics.byKey.healCrit.value({ healCrits = d("healCrits"), healHits = d("healHits") })
check("Heal Crit % is 1 of 2", hcrit, 50, 0.01)
-- A pull saved before critHits existed reads as it did.
check("an old pull with no critHits uses its hits", Wrekkit.metrics.byKey.crit.value({ crits = 3, hits = 12 }), 25, 0.01)

IN_COMBAT = false
E:LeftCombat()
advance(6)
E:Finish()
IN_COMBAT = IN
end

----------------------------------------------------------------------
print("\n-- enemy casts, for the mob window's cast bars --")
----------------------------------------------------------------------
;(function()
  local C = Wrekkit.capture
  C.casts = {}
  -- SPELL_START_OTHER(itemId, spellId, caster, target, castFlags, castTime, duration, spellType)
  fire("SPELL_START_OTHER", 0, 18435, "0xBoss", "0xP1", 0, 2000, 0, 0)
  local c = C:Casting("0xBoss")
  check("a mob's cast is followed", c and c.spellId, 18435)
  check("  for its cast time", c and c.dur, 2)
  fire("SPELL_GO_OTHER", 0, 18435, "0xBoss", "0xP1")
  check("  and ends when it lands", C:Casting("0xBoss"), nil)
  -- A channel's GO is its start: only time, a failure or death end it.
  fire("SPELL_START_OTHER", 0, 22686, "0xBoss", "0xP1", 0, 0, 5000, 1)
  fire("SPELL_GO_OTHER", 0, 22686, "0xBoss", "0xP1")
  check("a channel outlives its GO", C:Casting("0xBoss") and C:Casting("0xBoss").channel, true)
  fire("SPELL_FAILED_OTHER", "0xBoss", 22686)
  check("  and ends when interrupted", C:Casting("0xBoss"), nil)
  fire("SPELL_START_OTHER", 0, 18435, "0xBoss", "0xP1", 0, 2000, 0, 0)
  advance(3)
  check("a cast past its time is over", C:Casting("0xBoss"), nil)
  fire("SPELL_START_OTHER", 0, 18435, "0xBoss", "0xP1", 0, 2000, 0, 0)
  fire("UNIT_DIED", "0xBoss")
  check("  as is a dead mob's", C:Casting("0xBoss"), nil)
  -- Players' casts are not the mob window's business.
  fire("SPELL_START_OTHER", 0, 10329, "0xP2", "0xP1", 0, 2500, 0, 0)
  check("players' casts are not followed", C:Casting("0xP2"), nil)
  C.casts = {}
end)()

----------------------------------------------------------------------
print("\n-- mob watch: no AGGRO shouts when solo --")
----------------------------------------------------------------------
;(function()
  local T = Wrekkit.threat
  local alerts = {}
  local real = { Alert = T.Alert, IsTank = T.IsTank, UAC = UnitAffectingCombat, UCA = UnitCanAttack,
                 UE = UnitExists, UIU = UnitIsUnit, party = GetNumPartyMembers, raid = GetNumRaidMembers }
  T.Alert = function(self, text) table.insert(alerts, text) end
  T.IsTank = function() return false end
  UnitAffectingCombat = function() return true end
  UnitCanAttack = function() return true end
  UnitExists = function(u) return u == "0xMob1target" or u == "0xMob2target" end
  UnitIsUnit = function(a, b) return b == "player" end
  GetNumRaidMembers = function() return 0 end
  GetNumPartyMembers = function() return 0 end
  T.watch = {}

  -- Solo: a mob on you is marked (the mob window uses it), but nothing shouts.
  T:WatchMob("0xMob1", "Defias Thug")
  advance(1.5)
  local state = T:WatchMob("0xMob1", "Defias Thug")
  check("solo, a mob on you is still marked", state, "onme")
  check("  but raises no AGGRO warning", table.getn(alerts), 0)

  -- In a party the same thing is worth a shout.
  GetNumPartyMembers = function() return 4 end
  T:WatchMob("0xMob2", "Defias Pillager")
  advance(1.5)
  T:WatchMob("0xMob2", "Defias Pillager")
  check("in a group, a mob turning on you warns", alerts[1], "AGGRO! Defias Pillager is on you")

  T.Alert, T.IsTank = real.Alert, real.IsTank
  UnitAffectingCombat, UnitCanAttack, UnitExists, UnitIsUnit = real.UAC, real.UCA, real.UE, real.UIU
  GetNumPartyMembers, GetNumRaidMembers = real.party, real.raid
  T.watch = {}
end)()

----------------------------------------------------------------------
print("\n-- prices: own scans, guild sharing, the auction scan --")
----------------------------------------------------------------------
;(function()
  local P, A = Wrekkit.prices, Wrekkit.ahscan
  local realDB = Wrekkit.db.prices
  local realCVar, realFaction = GetCVar, UnitFactionGroup
  GetCVar = function(k) if k == "realmName" then return "Testrealm" end return realCVar and realCVar(k) end
  UnitFactionGroup = function() return "Alliance" end
  aux = nil                                          -- no aux: only our own record
  Wrekkit.db.prices, P.cache = {}, {}

  -- The newest sighting wins; an older one arriving late does not.
  check("a price is recorded", P:Record(13446, 12000, 1000, "Me"), true)
  check("  and used", P:Value(13446), 12000)
  check("an older sighting does not replace it", P:Record(13446, 9000, 900, "Bob"), false)
  P.cache = {}
  check("  the price stands", P:Value(13446), 12000)
  check("a newer one does", P:Record(13446, 11000, 1100, "Bob"), true)
  check("  and is used", P:Value(13446), 11000)

  -- Against aux: whichever was seen later. (A day in aux's list is stamped
  -- by the push at its end; it counts from that day's start.)
  aux = { faction = { ["Testrealm|Alliance"] = { history = {
    ["13446:0"] = string.format("%.0f##15000@%.0f", time() + 3600, 1200 + 86400) } } } }
  P.cache = {}
  check("aux's newer day beats an older own record", P:Value(13446), 15000)
  P:Record(13446, 10000, 1300, "Me")
  check("an own scan newer than aux's day beats it", P:Value(13446), 10000)
  aux, P.cache = nil, {}

  -- Guild sharing: only your own sightings go out, as Q~*~id:copper:time.
  local sent = {}
  local realSend, realGuild = Wrekkit.sync.Send, IsInGuild
  Wrekkit.sync.Send = function(self, to, body, channel) table.insert(sent, { to, body, channel }) return true end
  IsInGuild = function() return 1 end
  Wrekkit.db.prices = {}
  local now = time()
  P:Record(13446, 12000, now, UnitName("player"))
  P:Record(13444, 9000, now, "SomeoneElse")   -- told to us: never re-sent
  check("shares your own sightings", P:Share(), 1)
  check("  to the guild", sent[1] and sent[1][3], "GUILD")
  check("  as id:copper:time", sent[1] and sent[1][2], string.format("Q~13446:12000:%.0f", now))
  -- And the other way: a guildmate's message, through the sync dispatcher.
  local inbound = string.format("Q~*~20520:300:%.0f,13446:1:%.0f", now, now - 99999)
  Wrekkit.sync:OnMessage("WREKKIT", inbound, "GUILD", "Guildie")
  P.cache = {}
  check("a guildmate's price is taken", P:Value(20520), 300)
  check("  but not an older one than yours", P:Value(13446), 12000)
  Wrekkit.db.priceShare = false
  check("switched off, nothing is shared", P:Share(), 0)
  Wrekkit.sync:OnMessage("WREKKIT", string.format("Q~*~9155:7:%.0f", now), "GUILD", "Guildie")
  P.cache = {}
  check("  nor taken", P:Value(9155), nil)
  Wrekkit.db.priceShare = nil
  Wrekkit.sync.Send, IsInGuild = realSend, realGuild

  -- What a scan looks for: every consumable, on any character (a bank alt
  -- with no raids recorded too), plus the Dream Shard behind the tea and
  -- Dreamtonic; not the derived items, nor conjured food and water.
  local want = A:Wanted()
  local n = 0
  for _ in pairs(want) do n = n + 1 end
  check("it wants every consumable", n > 300, true)
  check("  Major Healing Potion among them", want[13446], "Major Healing Potion")
  check("  and the Small Dream Shard behind the tea", want[61198], "Small Dream Shard")
  check("  not the tea itself", want[61675], nil)
  check("  nor conjured water", want[8079], nil)

  -- How: the Consumable category by pages, then names only for what the
  -- auction house files elsewhere -- never a search per potion, nor for
  -- healthstones and the like that are never listed.
  local realClasses = GetAuctionItemClasses
  GetAuctionItemClasses = function() return "Weapon", "Armor", "Container", "Consumable", "Trade Goods" end
  local jobs, names = A:Jobs(want)
  local byName = {}
  for _, j in ipairs(jobs) do if j.kind == "name" then byName[j.name] = true end end
  check("first the Consumable category, by pages", jobs[1].kind .. ":" .. jobs[1].class, "class:4")
  check("  then names for the trade-goods ones: oils", byName["Brilliant Wizard Oil"], true)
  check("  jujus", byName["Juju Power"], true)
  check("  not a potion, which the category covers", byName["Major Healing Potion"], nil)
  check("  a few dozen searches, not hundreds", names < 80, true)

  -- The scan, against a stub auction house: two pages of the category (a
  -- stack, an unwanted item, a bid-only listing), then the oil by name.
  local listings = {
    [""] = {
      [0] = { { 13446, 5, 50000 }, { 2589, 1, 100 }, { 13446, 1, 0 } },   -- 10000 each; linen; bid only
      [1] = { { 13446, 2, 16000 } },                                     -- 8000 each: the cheapest
    },
    ["Brilliant Wizard Oil"] = { [0] = { { 20749, 1, 2500 } } },
  }
  local cur, queries = {}, {}
  local real = { AuctionFrame = AuctionFrame, Can = CanSendAuctionQuery, Query = QueryAuctionItems,
                 Num = GetNumAuctionItems, Info = GetAuctionItemInfo, Link = GetAuctionItemLink }
  AuctionFrame = { IsVisible = function() return true end }
  CanSendAuctionQuery = function() return true end
  QueryAuctionItems = function(name, _, _, _, class, _, page)
    table.insert(queries, name .. "#" .. page)
    local all = listings[name] or {}
    cur = all[page] or {}
    local total = 0
    for _, p in pairs(all) do total = total + table.getn(p) end
    cur.total = (name == "") and 60 or total
    A.got = true
  end
  GetNumAuctionItems = function() return table.getn(cur), cur.total end
  GetAuctionItemLink = function(_, i) return cur[i] and ("|Hitem:" .. cur[i][1] .. ":0:0:0|h") end
  GetAuctionItemInfo = function(_, i)
    local l = cur[i]
    return "x", "tex", l[2], 1, 1, 60, 0, 0, l[3]
  end
  Wrekkit.db.prices = {}
  P:Record(13452, 7777, 1, "Me")           -- Mongoose, from long ago
  A.Wanted = function() return { [13446] = "Major Healing Potion", [20749] = "Brilliant Wizard Oil",
                                 [13452] = "Elixir of the Mongoose" } end
  local shares = 0
  local realShare = P.Share
  P.Share = function() shares = shares + 1 return 0 end
  A:Start()
  for _ = 1, 20 do if A.running then A:Tick() end end
  check("the category's every page was read", queries[2], "#1")
  check("  then the oil by name", queries[3], "Brilliant Wizard Oil#0")
  check("  and nothing else searched", table.getn(queries), 3)
  check("the cheapest unit price of exactly that item", Wrekkit.db.prices[13446] and Wrekkit.db.prices[13446].p, 8000)
  check("  the oil's from its own search", Wrekkit.db.prices[20749] and Wrekkit.db.prices[20749].p, 2500)
  check("an item with nothing listed keeps its old price", Wrekkit.db.prices[13452].p, 7777)
  check("  and the scan finished", A.running, false)
  check("  having priced two", A.priced, 2)

  -- It never spins silently. The client holding every search back...
  A.Wanted = function() return { [1] = "A", [2] = "B Oil", [3] = "C Oil", [4] = "D Oil" } end
  CanSendAuctionQuery = function() return false end
  A:Start()
  A:Tick()
  advance(21)
  A:Tick()
  check("a search the client will not send stops the scan", A.running, false)
  -- ...or searches going out and nothing coming back (the session ended).
  CanSendAuctionQuery = function() return true end
  QueryAuctionItems = function() end
  A:Start()
  for _ = 1, 6 do
    A:Tick()
    advance(9)
    A:Tick()
  end
  check("three searches unanswered in a row stop it too", A.running, false)

  -- Paced by the server: an answer is read and the next search sent at
  -- once, in the event, with no tick in between.
  local asked = {}
  QueryAuctionItems = function(name, _, _, _, _, _, page) table.insert(asked, name .. "#" .. page) cur = { total = 0 } end
  A.Wanted = function() return { [13446] = "Major Healing Potion", [20749] = "Brilliant Wizard Oil" } end
  A:StartEvents()
  A:Start()                                   -- the first search goes out on start
  check("the first search goes out at once", asked[1], "#0")
  local was = event
  event = "AUCTION_ITEM_LIST_UPDATE"
  A.frame:GetScript("OnEvent")()              -- the category answered
  event = was
  check("its answer sends the next search straight away", asked[2], "Brilliant Wizard Oil#0")

  -- Somebody else's search mid-scan -- aux scanning, you browsing -- stops
  -- ours rather than reading their page and searching into the middle of it.
  A:Stop()
  CanSendAuctionQuery = function() return false end   -- ours not yet sent
  A:Start()
  event = "AUCTION_ITEM_LIST_UPDATE"
  A.frame:GetScript("OnEvent")()              -- an answer to nothing of ours
  event = was
  check("another search's answer stops the scan, untouched", A.running, false)

  -- Closing the auction house: aux's prices from today are taken in, and
  -- the lot shared once.
  aux = { faction = { ["Testrealm|Alliance"] = { history = {
    ["13510:0"] = string.format("%.0f#60000#", time() + 3600) } } } }
  shares = 0
  Wrekkit.db.prices = {}
  A:Closed()
  check("closing the AH takes in aux's prices", Wrekkit.db.prices[13510] and Wrekkit.db.prices[13510].p, 60000)
  check("  and shares once", shares, 1)

  P.Share, A.Wanted = realShare, nil
  GetAuctionItemClasses = realClasses
  AuctionFrame, CanSendAuctionQuery, QueryAuctionItems = real.AuctionFrame, real.Can, real.Query
  GetNumAuctionItems, GetAuctionItemInfo, GetAuctionItemLink = real.Num, real.Info, real.Link
  aux, GetCVar, UnitFactionGroup = nil, realCVar, realFaction
  Wrekkit.db.prices, P.cache = realDB, {}
end)()

----------------------------------------------------------------------
print("\n-- click spells on players outside the group --")
----------------------------------------------------------------------
;(function()
  local T = Wrekkit.threat
  local s = T:Settings()
  local casts = {}
  local real = { cast = CastSpellByName, target = TargetUnit, byName = TargetByName, assist = UnitCanAssist,
                 info = SpellInfo, exists = UnitExists, name = UnitName, last = TargetLastTarget,
                 party = GetNumPartyMembers, raid = GetNumRaidMembers }
  CastSpellByName = function(spell, unit) table.insert(casts, spell .. "@" .. tostring(unit)) end
  GetNumPartyMembers = function() return 0 end
  GetNumRaidMembers = function() return 0 end
  local friendly = true
  UnitCanAssist = function() return friendly end

  -- Off (the default): not in the group, nothing cast.
  s.castOutsideGroup = false
  check("off by default", T:CastOn("Stranger", "Flash of Light", "0xFriend"), false)
  check("  and nothing was cast", table.getn(casts), 0)

  -- On, with SuperWoW: straight at the guid the mob frame read.
  s.castOutsideGroup = true
  SpellInfo = SpellInfo or function() return "x" end
  check("on: cast on someone outside the group", T:CastOn("Stranger", "Flash of Light", "0xFriend"), true)
  check("  at their guid", casts[1], "Flash of Light@0xFriend")

  -- Never at someone you cannot help.
  friendly = false
  check("never on a player you can't help", T:CastOn("Hostile", "Flash of Light", "0xFoe"), false)
  check("  nothing cast", table.getn(casts), 1)
  friendly = true

  -- No guid (no SuperWoW): by name, then the old target back.
  local targeted, backed = nil, false
  local current = "Mob"
  TargetByName = function(n) targeted = n current = n end
  UnitExists = function(u) if u == "target" then return current ~= nil end return real.exists(u) end
  UnitName = function(u) if u == "target" then return current end return real.name(u) end
  TargetLastTarget = function() backed = true current = "Mob" end
  check("without a guid: by name", T:CastOn("Stranger", "Renew", nil), true)
  check("  targeted by name", targeted, "Stranger")
  check("  cast on the target", casts[2], "Renew@nil")
  check("  and the old target came back", backed, true)

  CastSpellByName, TargetUnit, TargetByName, UnitCanAssist = real.cast, real.target, real.byName, real.assist
  SpellInfo, UnitExists, UnitName, TargetLastTarget = real.info, real.exists, real.name, real.last
  GetNumPartyMembers, GetNumRaidMembers = real.party, real.raid
  s.castOutsideGroup = false
end)()

----------------------------------------------------------------------
print("\n-- talents: specs from the server's inspect, or a guess --")
----------------------------------------------------------------------
do
local TL = Wrekkit.talents
TL.specs, TL.pending, TL.queue, TL.asking = {}, {}, {}, nil

-- An inspection answer, as it arrives: the server leads each line with a
-- tab. A tree line's numbers are the same for every paladin (its size, not
-- points spent); the points are in the talent lines, as ranks.
local function talents(name, tree, points)
  local idx = 0
  while points > 0 do
    idx = idx + 1
    local r = points > 5 and 5 or points
    points = points - r
    TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentInfo;" .. tree .. ";" .. idx ..
      ";Talent " .. idx .. ";1;2;" .. r .. ";5;1;0;0;0", name)
  end
  TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentInfo;" .. tree .. ";" .. (idx + 1) ..
    ";Untaken;3;1;0;5;0;0;0;0", name)
end
local function answer(name, a, b, c)
  TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentTabInfo;1;Holy;14;14", name)
  talents(name, 1, a)
  TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentTabInfo;2;Protection;15;15", name)
  talents(name, 2, b)
  TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentTabInfo;3;Retribution;15;15", name)
  talents(name, 3, c)
  TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentEND", name)
end
answer("Pempuk", 5, 11, 35)
local sp = TL:Spec("Pempuk")
check("an inspection gives the spec", sp and sp.tree, "Retribution")
check("  with its points, added up from the talents", TL:Describe("Pempuk"), "Retribution (5/11/35)")
-- The same answer heard twice over (two addons asked) counts once.
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentTabInfo;1;Holy;14;14", "Twice")
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentInfo;1;1;Divine Strength;1;2;5;5;1", "Twice")
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentInfo;1;1;Divine Strength;1;2;5;5;1", "Twice")
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentInfo;1;2;Divine Intellect;1;3;3;5;1", "Twice")
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentEND", "Twice")
check("  an answer heard twice counts once", TL:Spec("Twice").points[1], 8)
check("  and the tree's icon", TL:Icon("Pempuk", "PALADIN"), "Interface\\Icons\\Spell_Holy_AuraOfLight")
answer("Albintank", 0, 31, 20)
check("a Protection paladin's shield is the paladin's", TL:Icon("Albintank", "PALADIN"),
  "Interface\\Icons\\Spell_Holy_DevotionAura")
check("  a Protection warrior's is the warrior's", TL:Icon("Albintank", "WARRIOR"),
  "Interface\\Icons\\INV_Shield_06")
-- Another addon's messages on other prefixes are not answers.
TL:OnMessage("WREKKIT", "INSTalentTabInfo;1;Arms;15;31", "Nobody")
TL:OnMessage("WREKKIT", "INSTalentEND", "Nobody")
check("other prefixes are ignored", TL:Spec("Nobody"), nil)

-- A guess from a deep talent cast, for a group member not yet inspected.
local realInfo, realGroup = SpellInfo, Wrekkit.capture.groupMembers
SpellInfo = function(id)
  if id == 21553 then return "Mortal Strike", "Rank 4", "x" end
  if id == 20066 then return "Repentance", nil, "x" end
  return realInfo(id)
end
Wrekkit.capture.groupMembers = { Rogue = true, Pempuk = true }
WORLD["0xGuess"] = { name = "Rogue", class = "WARRIOR", isPlayer = true }
Wrekkit.capture.units["0xGuess"] = nil
TL:OnCast("0xGuess", 21553)
check("a deep talent cast guesses the spec", TL:Describe("Rogue"), "Arms (guessed: Mortal Strike)")
-- An inspection replaces a guess; a guess never replaces an inspection.
WORLD["0xPemp"] = { name = "Pempuk", class = "PALADIN", isPlayer = true }
TL:OnCast("0xPemp", 21553)
check("a cast does not overrule an inspection", TL:Spec("Pempuk").tree, "Retribution")
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentTabInfo;1;Arms;18;18", "Rogue")
talents("Rogue", 1, 31)
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentTabInfo;2;Fury;17;17", "Rogue")
talents("Rogue", 2, 20)
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentTabInfo;3;Protection;17;17", "Rogue")
TL:OnMessage("TW_CHAT_MSG_WHISPER", "\tINSTalentEND", "Rogue")
check("an inspection replaces a guess", TL:Describe("Rogue"), "Arms (31/20/0)")
-- Someone outside the group is not guessed at.
WORLD["0xStranger"] = { name = "Stranger", class = "PALADIN", isPlayer = true }
TL:OnCast("0xStranger", 20066)
check("no guesses about strangers", TL:Spec("Stranger"), nil)
SpellInfo, Wrekkit.capture.groupMembers = realInfo, realGroup

-- Asking: never in combat, one at a time, ChronicleCompanion or not.
local sent = {}
local realSend, realRaid, realName, realUAC = SendAddonMessage, GetNumRaidMembers, UnitName, UnitAffectingCombat
local oldForm = {}
SendAddonMessage = function(p, m, c)
  if m == "INSShowTalents" then table.insert(oldForm, p) return end
  table.insert(sent, p .. "|" .. m .. "|" .. c)
end
GetNumRaidMembers = function() return 2 end
UnitName = function(u)
  if u == "raid1" then return "Moras" end
  if u == "raid2" then return "Shejian" end
  return realName(u)
end
UnitAffectingCombat = function() return false end
TL.specs, TL.queue, TL.asking = {}, {}, nil
UnitAffectingCombat = function() return true end
TL:Step()
check("  nor in combat", table.getn(sent), 0)
UnitAffectingCombat = function() return false end
TL:Step()
check("without it, the first player is asked", sent[1], "TW_CHAT_MSG_WHISPER<Moras>|INSTalentShow|GUILD")
check("  in the older form too, for older clients", oldForm[1], "TW_CHAT_MSG_WHISPER<Moras>")
TL:Step()
check("  one at a time", table.getn(sent), 1)
advance(11)
TL:Step()
check("  and the next after a timeout", sent[2], "TW_CHAT_MSG_WHISPER<Shejian>|INSTalentShow|GUILD")
-- Offline: the server says so, and the next is not held up.
TL:OnMessage("TW_CHAT_MSG_WHISPER", "Error:CantFindPlayer:Shejian", "Shejian")
check("  an offline player frees the line at once", TL.asking, nil)
-- Nobody answered: not asked again for a minute.
TL:Step()
check("  nor a non-answerer straight away", table.getn(sent), 2)
advance(61)
TL:Step()
check("  but again after a minute", sent[3], "TW_CHAT_MSG_WHISPER<Moras>|INSTalentShow|GUILD")
-- Silent twice: half the clients never answer, so wait longer each time.
-- (Shejian, long silent, stays out of it.)
TL.misses["Shejian"], TL.lastAsk["Shejian"], TL.queue = 3, GetTime(), {}
advance(11)
TL:Step()
check("  a second silence is counted", TL.misses["Moras"], 2)
advance(61)
TL:Step()
check("  and then not asked again for five minutes", table.getn(sent), 3)
advance(240)
TL:Step()
check("  but after them", sent[4], "TW_CHAT_MSG_WHISPER<Moras>|INSTalentShow|GUILD")
table.remove(sent, 4)
TL.asking = nil
-- Someone ChronicleCompanion inspected (its answers land here too) is not asked.
TL.asking, TL.queue = nil, {}
answer("Moras", 0, 5, 46)
answer("Shejian", 0, 5, 46)
advance(61)
TL:Step()
check("  someone answered lately is not asked", table.getn(sent), 3)
-- /wrek inspect asks now, ahead of the rest.
TL:Inspect("moras")
TL:Step()
check("/wrek inspect asks at once", sent[4], "TW_CHAT_MSG_WHISPER<Moras>|INSTalentShow|GUILD")
TL.asking = nil
-- "%t" reaches a slash command as typed: it means the target.
local realExists, realIsPlayer = UnitExists, UnitIsPlayer
UnitExists = function(u) return u == "target" end
UnitIsPlayer = function(u) return u == "target" end
UnitName = function(u) if u == "target" then return "Khtalla" end return realName(u) end
TL:Inspect("%t")
TL:Step()
check("/wrek inspect %t asks the target", sent[5], "TW_CHAT_MSG_WHISPER<Khtalla>|INSTalentShow|GUILD")
TL.asking = nil
TL:Inspect()
check("  as does no name at all", TL.queue[1], "Khtalla")
-- Targeting a player asks them at once -- the server passes an ask on
-- while its player is your target -- even mid-fight, ahead of the round.
TL.specs, TL.asking = {}, "Shejian"
UnitAffectingCombat = function() return true end
TL:OnTarget()
check("targeting a player asks them", sent[table.getn(sent)], "TW_CHAT_MSG_WHISPER<Khtalla>|INSTalentShow|GUILD")
check("  taking over from the round's ask", TL.asking, "Khtalla")
local n = table.getn(sent)
TL:OnTarget()
check("  not again while waiting on them", table.getn(sent), n)
answer("Khtalla", 0, 5, 46)
advance(30)
TL:OnTarget()
check("  nor once known", table.getn(sent), n)
UnitIsPlayer = function() return false end
TL.specs = {}
TL:OnTarget()
check("  and never a mob", table.getn(sent), n)
UnitAffectingCombat = function() return false end
UnitExists, UnitIsPlayer = realExists, realIsPlayer
TL.queue, TL.misses, TL.lastAsk, TL.asking = {}, {}, {}, nil
SendAddonMessage, GetNumRaidMembers, UnitName, UnitAffectingCombat = realSend, realRaid, realName, realUAC

-- The client's Talents tab only hears answers it can be waiting for: while
-- open, from the target or yourself. An ask always reaches it (it answers).
-- (A function of its own: the file's main chunk is at Lua's 200 locals.)
;(function()
  local got = {}
  InspectTalentsFrame_HandleMessage = function(m, s) table.insert(got, s .. ":" .. m) end
  local open = false
  InspectTalentsFrame = { IsVisible = function() return open end }
  local realName2 = UnitName
  UnitName = function(u)
    if u == "target" then return "Duskii" end
    if u == "player" then return "Salahaja" end
    return realName2(u)
  end
  local shown, asked = 0, {}
  InspectTalentsFrame_OnShow = function() shown = shown + 1 end
  local realSend2 = SendAddonMessage
  SendAddonMessage = function(p, m) table.insert(asked, p .. "|" .. m) end
  TL.inspectHooked = nil
  TL:HookInspectUI()
  InspectTalentsFrame_OnShow()
  check("opening the tab still runs the client's own", shown, 1)
  check("  and asks the target in the older form too", asked[1], "TW_CHAT_MSG_WHISPER<Duskii>|INSShowTalents")
  SendAddonMessage = realSend2
  InspectTalentsFrame_HandleMessage("\tINSShowTalents", "Khtalla")
  check("an older-form ask reaches it too", got[1], "Khtalla:\tINSShowTalents")
  got = {}
  InspectTalentsFrame_HandleMessage("\tINSTalentEND;", "Khtalla")
  check("tab shut: a background answer does not reach it", table.getn(got), 0)
  InspectTalentsFrame_HandleMessage("\tINSTalentShow", "Khtalla")
  check("  but an ask always does", got[1], "Khtalla:\tINSTalentShow")
  open = true
  InspectTalentsFrame_HandleMessage("\tINSTalentEND;", "Khtalla")
  check("tab open: someone else's answer still does not", table.getn(got), 1)
  InspectTalentsFrame_HandleMessage("\tINSTalentEND;", "Duskii")
  check("  the target's does", got[2], "Duskii:\tINSTalentEND;")
  InspectTalentsFrame_HandleMessage("\tINSTalentEND;", "Salahaja")
  check("  and your own", got[3], "Salahaja:\tINSTalentEND;")
  check("  each answer's end is traced for /wrek specs", TL.log[table.getn(TL.log)],
    string.format("%.0f", GetTime()) .. "s tab: Salahaja 1 in, 0 held; talents shown no, in range no")
  InspectTalentsFrame_HandleMessage("\tINSTransmogs;start", "Khtalla")
  check("  other messages pass untouched", got[4], "Khtalla:\tINSTransmogs;start")
  TL:HookInspectUI()
  InspectTalentsFrame_HandleMessage("\tINSTalentEND;", "Duskii")
  check("  hooked once, however often asked", table.getn(got), 5)
  UnitName = realName2
  InspectTalentsFrame_HandleMessage, InspectTalentsFrame, TL.inspectHooked = nil, nil, nil
  InspectTalentsFrame_OnShow = nil
end)()

-- Your own, from the talent API.
local realTab = GetTalentTabInfo
GetTalentTabInfo = function(i)
  local t = { { "Holy", "x", 0 }, { "Protection", "x", 15 }, { "Retribution", "x", 36 } }
  return t[i][1], t[i][2], t[i][3]
end
TL:ReadOwn()
check("your own spec comes from the talent API", TL:Describe(UnitName("player")), "Retribution (0/15/36)")
GetTalentTabInfo = realTab
TL.specs, TL.pending, TL.queue, TL.asking = {}, {}, {}, nil
end

----------------------------------------------------------------------
print("\n-- raid value --")
----------------------------------------------------------------------
;(function()
Wrekkit.ResetData("all")
local V = Wrekkit.value
V.mob, V.lastCast, V.buffBy, V.lastJudge, V.lastHit, V.lastTarget = {}, {}, {}, {}, {}, {}
V.lastShadowCrit, V.recentMelee, V.procScore, V.partyCache = {}, {}, {}, {}
Wrekkit.capture.buffs = {}
local realInfo = SpellInfo
SpellInfo = function(id)
  if id == 20271 then return "Judgement", nil, "x" end
  if id == 20218 then return "Sanctity Aura", nil, "x" end
  if id == 51750 then return "Judgement of Wisdom", "Rank 5", "x" end
  if id == 20343 then return "Judgement of Light", "Rank 4", "x" end
  return realInfo(id)
end
defPlayer("0xLock", "Curser", "WARLOCK")
defPlayer("0xLock2", "Bolter", "WARLOCK")
defPlayer("0xPri", "Weaver", "PRIEST")
defPlayer("0xMage", "Scorcher", "MAGE")
defPlayer("0xPal", "Holyguy", "PALADIN")
defPlayer("0xPal2", "Retguy", "PALADIN")
defPlayer("0xWar", "Tanky", "WARRIOR", 6000)
defPlayer("0xDru", "Barky", "DRUID")
defPlayer("0xHoly", "Farpriest", "PRIEST")
for _, g in ipairs({ "0xV1", "0xV2", "0xV3", "0xV4", "0xV5", "0xV6" }) do defNPC(g, "Target " .. g, 1000000) end
TH.setRaid({ "Curser", "Bolter", "Weaver", "Scorcher", "Holyguy", "Retguy", "Tanky", "Barky", "Farpriest" })
Wrekkit.capture.subgroups = { Curser = 1, Bolter = 1, Weaver = 1, Scorcher = 1, Holyguy = 1,
  Retguy = 1, Tanky = 1, Barky = 1, Farpriest = 2 }

Wrekkit.db.raidValue = true
IN_COMBAT = true
fire("PLAYER_REGEN_DISABLED")
local enc = Wrekkit.encounter.live
local function val(g) local a = enc.actors[g] return a and a.valueAdded or 0 end
local function eff(g, id) local a = enc.actors[g] local r = a and a.valueEffect[id] return r and r.amount or 0 end
local function hit(target, caster, id, amount, school, info)
  fire("SPELL_DAMAGE_EVENT_OTHER", target, caster, id, amount, "0,0,0", info or 0, school)
end

-- A curse goes to whoever cast it, from another warlock's Shadow Bolt.
fire("AURA_CAST_ON_OTHER", 17937, "0xLock", "0xV1")
fire("DEBUFF_ADDED_OTHER", "0xV1", 1, 17937, 1, 60, 5, 0)
hit("0xV1", "0xLock2", 11661, 1100, 5)
check("Curse of Shadow credits its caster", val("0xLock"), 100, 0.01)
check("not the warlock who hit", val("0xLock2"), 0)

-- Shadow Weaving: the priest whose shadow spell just hit, per stack.
advance(3)
hit("0xV1", "0xPri", 10894, 500, 5)
fire("DEBUFF_ADDED_OTHER", "0xV1", 2, 15258, 2, 60, 6, 0)
hit("0xV1", "0xLock2", 11661, 1166, 5)
-- 1.10 x 1.06: 166 extra, split by log(1.10) : log(1.06).
-- (the priest's own 500 was cursed too: 45.45 of it)
check("two effects split the extra: the curse", eff("0xLock", 17937), 145.45 + 166 * 0.09531 / (0.09531 + 0.05827), 0.05)
check("and two stacks of Shadow Weaving", eff("0xPri", 15258), 166 * 0.05827 / (0.09531 + 0.05827), 0.05)

-- Improved Shadow Bolt: the warlock whose Shadow Bolt just crit.
hit("0xV2", "0xLock2", 11661, 2000, 5, 2)
fire("DEBUFF_ADDED_OTHER", "0xV2", 1, 17794, 4, 60, 5, 0)
hit("0xV2", "0xLock", 11661, 1200, 5)
check("Shadow Vulnerability goes to the critter", eff("0xLock2", 17794), 200, 0.01)

-- Power Infusion on the mage, and their own Fire Vulnerability.
fire("AURA_CAST_ON_OTHER", 10060, "0xPri", "0xMage")
fire("BUFF_ADDED_OTHER", "0xMage", 5, 10060, 1, 60, 7, 0)
hit("0xV3", "0xMage", 10207, 600, 2)
fire("DEBUFF_ADDED_OTHER", "0xV3", 1, 22959, 5, 60, 5, 0)
check("PI credits the priest who cast it", eff("0xPri", 10060), 100, 0.01)
hit("0xV3", "0xMage", 10207, 1380, 2)
check("PI's share beside 5 stacks of Fire Vulnerability", eff("0xPri", 10060), 100 + 380 * 0.18232 / (0.18232 + 0.13976), 0.05)
check("Fire Vulnerability goes to the mage", eff("0xMage", 22959), 380 * 0.13976 / (0.18232 + 0.13976), 0.05)

-- Sanctity: only for the paladin's own group -- and only the paladin who
-- put it up, not another one holding it.
fire("AURA_CAST_ON_OTHER", 20218, "0xPal", "0xPal")
fire("BUFF_ADDED_OTHER", "0xPal", 1, 20218, 1, 60, 1, 0)
fire("BUFF_ADDED_OTHER", "0xPal2", 1, 20218, 1, 60, 1, 0)
fire("BUFF_ADDED_OTHER", "0xHoly", 1, 20218, 1, 60, 1, 0)
hit("0xV4", "0xPal2", 20293, 1100, 1)
check("Sanctity credits the paladin who cast it", val("0xPal"), 100, 0.01)
check("not another paladin holding it", val("0xPal2"), 0)
local before = val("0xPal") + val("0xPal2")
hit("0xV4", "0xHoly", 15261, 1100, 1)
check("not a paladin of another group", val("0xPal") + val("0xPal2"), before, 0.01)
check("which is kept unattributed", enc.valueUnknown, 100, 0.01)
;(function()
  -- Nothing seen cast: two paladins hold it, and you (Retguy) run another
  -- aura -- your stance bar says so -- so it is the other one's.
  local V = Wrekkit.value
  V.castBy, V.partyCache = {}, {}
  local realPlayer = WORLD["player"]
  WORLD["player"] = WORLD["0xPal2"]
  GetNumShapeshiftForms = function() return 2 end
  GetShapeshiftFormInfo = function(i)
    if i == 1 then return "x", "Retribution Aura", 1 end
    return "x", "Devotion Aura", nil
  end
  local before = val("0xPal")
  hit("0xV4", "0xPal2", 20293, 1100, 1)
  check("your own aura rules you out of another's Sanctity", val("0xPal") - before, 100, 0.01)
  GetShapeshiftFormInfo = function(i) return "x", "Sanctity Aura", i == 1 and 1 or nil end
  V.partyCache = {}
  local both = val("0xPal") + val("0xPal2")
  hit("0xV4", "0xPal2", 20293, 1100, 1)
  check("two who could be it, none known: nobody guessed", val("0xPal") + val("0xPal2"), both, 0.01)
  GetNumShapeshiftForms, GetShapeshiftFormInfo = nil, nil
  WORLD["player"] = realPlayer
  V.partyCache = {}
end)()

-- Judgement of the Crusader: a flat 140 Holy, to the judging paladin.
fire("SPELL_GO_OTHER", 0, 20271, "0xPal", "0xV5")
fire("DEBUFF_ADDED_OTHER", "0xV5", 1, 20303, 1, 60, 5, 0)
local palBefore = val("0xPal")
hit("0xV5", "0xPri", 15261, 600, 1)
check("Crusader adds its flat 140", val("0xPal") - palBefore, 140, 0.01)
hit("0xV5", "0xPri", 15261, 90, 1)
check("never more than the hit", val("0xPal") - palBefore, 230, 0.01)

-- Damage shields go to the provider, never to the wearer.
fire("BUFF_ADDED_OTHER", "0xWar", 2, 10301, 1, 60, 2, 0)
fire("BUFF_ADDED_OTHER", "0xPal", 2, 10301, 1, 60, 2, 0)
V.partyCache = {}
fire("DAMAGE_SHIELD_OTHER", "0xWar", "0xV6", 20, 1)
check("Retribution Aura on a groupmate", eff("0xPal", 10301), 20, 0.01)
fire("DAMAGE_SHIELD_OTHER", "0xPal", "0xV6", 20, 1)
check("not on the paladin themselves", eff("0xPal", 10301), 20, 0.01)
fire("AURA_CAST_ON_OTHER", 9910, "0xDru", "0xWar")
fire("BUFF_ADDED_OTHER", "0xWar", 3, 9910, 1, 60, 3, 0)
fire("DAMAGE_SHIELD_OTHER", "0xWar", "0xV6", 18, 3)
check("Thorns credits the druid", eff("0xDru", 9910), 18, 0.01)

-- Judgement of Wisdom and Light: what the hitter got back, as support.
fire("SPELL_GO_OTHER", 0, 20271, "0xPal", "0xV6")
fire("DEBUFF_ADDED_OTHER", "0xV6", 1, 51752, 1, 60, 5, 0)
fire("SPELL_GO_OTHER", 0, 20271, "0xPal2", "0xV6")
fire("DEBUFF_ADDED_OTHER", "0xV6", 2, 20346, 1, 60, 6, 0)
fire("SPELL_DAMAGE_EVENT_OTHER", "0xWar", "0xV6", 25231, 1000, "0,0,0", 0, 0)
fire("AUTO_ATTACK_OTHER", "0xWar", "0xV6", 400, 2, 0, 1, 0, 0, 0)
fire("SPELL_ENERGIZE_BY_OTHER", "0xWar", "0xWar", 51750, 0, 59, 0)
fire("SPELL_HEAL_BY_OTHER", "0xWar", "0xWar", 20343, 61, 0, 0)
fire("SPELL_HEAL_ON_SELF", "0xWar", "0xWar", 20343, 61, 0, 0)
-- A heal on the recording player arrives twice: BY_OTHER, then ON_SELF.
-- Counted once, even with other heals landing in between (10/25).
;(function()
  local E = Wrekkit.encounter
  local live = E.live
  local function healOf(g) local a = live and live.actors[g] return a and ((a.healing or 0) + (a.overheal or 0)) or 0 end
  local before = healOf("0xP2")
  fire("SPELL_HEAL_BY_OTHER", "0xP1", "0xP2", 10960, 700, 0, 0)   -- Prayer of Healing on you
  fire("SPELL_HEAL_BY_OTHER", "0xP3", "0xP2", 10960, 650, 0, 0)   -- and on someone else
  fire("SPELL_HEAL_ON_SELF", "0xP1", "0xP2", 10960, 700, 0, 0)    -- its restatement
  check("a heal on you is counted once", healOf("0xP2") - before, 1350)
end)()
check("Judgement of Wisdom: mana to its paladin", enc.actors["0xPal"].valueMana, 59)
check("Judgement of Light: health, counted once", enc.actors["0xPal2"].valueHeal, 61)
fire("SPELL_ENERGIZE_BY_OTHER", "0xWar", "0xWar", 51750, 1, 10, 0)
check("rage is not mana", enc.actors["0xPal"].valueMana, 59)

local view = Wrekkit.report:View({ enc }, {})
local row = TH.rowOf(view, "support", "Holyguy")
check("Raid support ranks the paladin", row and Wrekkit.metrics.Get("support").sub(row), "59 mana")
row = TH.rowOf(view, "value", "Curser")
check("Raid value drills into the effects", row and row.valueEffect[17937] ~= nil, true)

-- Credited to providers: the curse's share leaves the bolter for the curser.
local function total(v) local t = 0 for _, r in ipairs(v.rows) do t = t + r.damage end return t end
local plain = Wrekkit.report:View({ enc }, {})
local bolterPlain = TH.rowOf(plain, "damage", "Bolter").damage
Wrekkit.db.valueCredit = true
local moved = Wrekkit.report:View({ enc }, {})
local curser = TH.rowOf(moved, "damage", "Curser")
check("credited: the curser gains what the curse added", curser and curser.damage,
  TH.rowOf(plain, "damage", "Curser").damage + val("0xLock") - enc.actors["0xLock"].valueGot, 0.01)
check("the bolter's is less by what others added", TH.rowOf(moved, "damage", "Bolter").damage,
  bolterPlain - enc.actors["0xLock2"].valueGot + val("0xLock2"), 0.01)
check("the raid's total does not change", total(moved), total(plain), 0.01)
check("the drilldown shows the curse as a line", curser and curser.dmgAbility[17937] ~= nil, true)
check("Judgement of Light's healing moves to its paladin", TH.rowOf(moved, "healing", "Retguy").healing, 61, 0.01)
Wrekkit.db.valueCredit = nil

-- PHYSICAL. Windfury: the swing in the same moment as the proc is the
-- totem's, credited to the shaman in the hitter's group.
defPlayer("0xSham", "Totemguy", "SHAMAN")
Wrekkit.capture.subgroups.Totemguy = 1
Wrekkit.capture.units["0xSham"] = nil
Wrekkit.capture:Unit("0xSham")
fire("SPELL_GO_OTHER", 0, 8512, "0xSham", "0xSham")
fire("SPELL_GO_OTHER", 0, 51368, "0xWar", "0xWar")
fire("AUTO_ATTACK_OTHER", "0xWar", "0xV6", 900, 2, 0, 1, 0, 0, 0)
check("Windfury's extra swing goes to the shaman", eff("0xSham", 51368), 900)
advance(0.2)
fire("AUTO_ATTACK_OTHER", "0xWar", "0xV6", 900, 2, 0, 1, 0, 0, 0)
check("only that swing", eff("0xSham", 51368), 900)

-- Estimates are off until asked for: armor and attack power count nothing.

defNPC("0xV7", "Armored", 1000000)
fire("AURA_CAST_ON_OTHER", 11597, "0xWar", "0xV7")
fire("DEBUFF_ADDED_OTHER", "0xV7", 1, 11597, 5, 60, 5, 0)
fire("AURA_CAST_ON_OTHER", 11717, "0xLock", "0xV7")
fire("DEBUFF_ADDED_OTHER", "0xV7", 2, 11717, 1, 60, 6, 0)
fire("BUFF_ADDED_OTHER", "0xWar", 4, 11551, 1, 60, 4, 0)
for i = 1, 12 do
  advance(2.5)
  fire("AUTO_ATTACK_OTHER", "0xWar", "0xV7", 1000, 2, 0, 1, 0, 0, 0)
end
check("estimates off: Sunder counts nothing", eff("0xWar", -11597), 0)

-- On: armor 3731 less 5 x 450 Sunder and 640 Recklessness.
Wrekkit.db.raidValueEstimates = true
advance(2.5)
fire("AUTO_ATTACK_OTHER", "0xWar", "0xV7", 1000, 2, 0, 1, 0, 0, 0)
local keepBase = 1 - 3731 / (3731 + 5500)
local keepNow = 1 - 841 / (841 + 5500)
local armorExtra = 1000 - 1000 * keepBase / keepNow
local apExtra = 185 / 14 * 2.5 * keepNow
local scale = (armorExtra + apExtra) > 750 and 750 / (armorExtra + apExtra) or 1
check("Sunder's estimate, by armor it took off", eff("0xWar", -11597), armorExtra * 2250 / 2890 * scale, 0.5)
check("Recklessness's, to its warlock", eff("0xLock", -11717), armorExtra * 640 / 2890 * scale, 0.5)
check("Battle Shout: 185 AP over the 2.5s swings", eff("0xWar", -11551), apExtra * scale, 0.5)
local sunderRow = enc.actors["0xWar"].valueEffect[-11597]
check("an estimate says so", sunderRow and sunderRow.name, "Sunder Armor (est.)")
Wrekkit.db.raidValueEstimates = nil

-- Two warriors building one Sunder share it by applications.
defPlayer("0xWar2", "Second", "WARRIOR", 6000)
Wrekkit.capture.subgroups.Second = 1
Wrekkit.capture.units["0xWar2"] = nil
Wrekkit.capture:Unit("0xWar2")
defNPC("0xV8", "Shared", 1000000)
fire("AURA_CAST_ON_OTHER", 11597, "0xWar", "0xV8")
fire("DEBUFF_ADDED_OTHER", "0xV8", 1, 11597, 1, 60, 5, 0)
fire("AURA_CAST_ON_OTHER", 11597, "0xWar2", "0xV8")
fire("DEBUFF_ADDED_OTHER", "0xV8", 1, 11597, 2, 60, 5, 0)
Wrekkit.db.raidValueEstimates = true
local w1, w2 = eff("0xWar", -11597), eff("0xWar2", -11597)
fire("SPELL_DAMAGE_EVENT_OTHER", "0xV8", "0xHoly", 11267, 1000, "0,0,0", 0, 0)
check("a shared Sunder is split between its warriors", eff("0xWar", -11597) - w1, eff("0xWar2", -11597) - w2, 0.01)
check("and both get some", eff("0xWar2", -11597) - w2 > 0, true)
Wrekkit.db.raidValueEstimates = nil

-- Announced by effect: combined names nobody, individual names each.
local actx = { metric = "value", encounters = { enc }, label = "Test" }
local lines = Wrekkit.announce:Lines(actx, 15)
local function find(ls, pat)
  for _, l in ipairs(ls) do if string.find(l, pat, 1, true) then return l end end
  return nil
end
local sunderLine = find(lines, "Sunder Armor (est.)")
check("combined: Sunder's total and how many built it", sunderLine and string.find(sunderLine, "(2 players)", 1, true) ~= nil, true)
check("combined names no one", sunderLine and string.find(sunderLine, "Tanky", 1, true), nil)
check("estimates are flagged", find(lines, "(est.) = estimated") ~= nil, true)
Wrekkit.db.valueAnnounce = "individual"
lines = Wrekkit.announce:Lines(actx, 15)
sunderLine = find(lines, "Sunder Armor (est.)")
check("individual: each warrior's share", sunderLine and string.find(sunderLine, "Tanky", 1, true) ~= nil
  and string.find(sunderLine, "Second", 1, true) ~= nil, true)
Wrekkit.db.valueAnnounce = nil
lines = Wrekkit.announce:Lines({ metric = "support", encounters = { enc }, label = "Test" }, 15)
check("support is announced in mana and healing", find(lines, "mana") ~= nil, true)

-- Nightfall filed under the mob's BUFFS still counts, and a player's
-- buff of the same id is not mistaken for it.
defNPC("0xV10", "Buffed debuff", 1000000)
fire("AUTO_ATTACK_OTHER", "0xWar", "0xV10", 500, 2, 0, 1, 0, 0, 0)
fire("BUFF_ADDED_OTHER", "0xV10", 3, 23605, 1, 60, 9, 0)
local nfBefore = eff("0xWar", 23605)
hit("0xV10", "0xLock2", 11661, 1100, 5)
check("a debuff filed as a mob's buff counts", eff("0xWar", 23605) - nfBefore, 100, 0.01)
fire("BUFF_REMOVED_OTHER", "0xV10", 3, 23605, 0, 0, 9, 1)
check("and ends with it", Wrekkit.value.mob["0xV10"], nil)
fire("BUFF_ADDED_OTHER", "0xMage", 9, 23605, 1, 60, 9, 0)
check("the same id on a player is not a mob debuff", Wrekkit.value.mob["0xMage"], nil)

-- Armor read off the mob itself, and remembered by name.
local realField = GetUnitField
GetUnitField = function(guid, f)
  if guid == "0xV9" and f == "resistances" then return { 2000, 0, 0, 0, 0, 0, 0 } end
  return ""
end
defNPC("0xV9", "Softie", 1000000)
check("a mob's own armor, when the client gives it", Wrekkit.value:MobArmor("0xV9", 0), 2000)
check("is learned by name", Wrekkit.db.mobArmor and Wrekkit.db.mobArmor.Softie, 2000)
GetUnitField = realField
Wrekkit.value.armorOf = {}
check("and used when it cannot be read", Wrekkit.value:MobArmor("0xV9", 0), 2000)
check("a mob never read is a raid boss", Wrekkit.value:MobArmor("0xV8", 0), 3731)
Wrekkit.db.mobArmor = nil

-- The game's own armor readings make armor debuffs EXACT: no estimates
-- switch needed, no "(est.)", and the real drop is what counts.
ARMOR_NOW = {}
GetUnitField = function(guid, f)
  if f == "resistances" and ARMOR_NOW[guid] then return { ARMOR_NOW[guid], 0, 0, 0, 0, 0, 0 } end
  return ""
end
Wrekkit.value.armorOf, Wrekkit.value.liveArmor = {}, {}
defNPC("0xV11", "Plated", 1000000)
ARMOR_NOW["0xV11"] = 3000
fire("AUTO_ATTACK_OTHER", "0xWar2", "0xV11", 800, 2, 0, 1, 0, 0, 0)
check("a clean reading is where the mob started", Wrekkit.value.armorOf["0xV11"], 3000)
check("and is learned by name", Wrekkit.db.mobArmor and Wrekkit.db.mobArmor.Plated, 3000)
for i = 1, 5 do
  fire("AURA_CAST_ON_OTHER", 11597, "0xWar2", "0xV11")
  fire("DEBUFF_ADDED_OTHER", "0xV11", 1, 11597, i, 60, 5, 0)
end
ARMOR_NOW["0xV11"] = 750
advance(1)
local exBefore = eff("0xWar2", 11597)
fire("AUTO_ATTACK_OTHER", "0xWar2", "0xV11", 1000, 2, 0, 1, 0, 0, 0)
local kb, kn = 1 - 3000 / 8500, 1 - 750 / 6250
check("live armor: Sunder is exact with estimates off", eff("0xWar2", 11597) - exBefore, 1000 - 1000 * kb / kn, 0.01)
local srow = enc.actors["0xWar2"].valueEffect[11597]
check("and says nothing of estimates", srow and srow.name, "Sunder Armor")

-- A 3-point Expose Armor: nominal 1700, the reading says 1020.
defPlayer("0xRog", "Stabby", "ROGUE")
Wrekkit.capture.subgroups.Stabby = 1
Wrekkit.capture.units["0xRog"] = nil
Wrekkit.capture:Unit("0xRog")
defNPC("0xV12", "Exposed", 1000000)
ARMOR_NOW["0xV12"] = 3000
fire("AUTO_ATTACK_OTHER", "0xRog", "0xV12", 500, 2, 0, 1, 0, 0, 0)
fire("AURA_CAST_ON_OTHER", 11198, "0xRog", "0xV12")
fire("DEBUFF_ADDED_OTHER", "0xV12", 1, 11198, 1, 60, 5, 0)
ARMOR_NOW["0xV12"] = 1980
advance(1)
fire("AUTO_ATTACK_OTHER", "0xRog", "0xV12", 1000, 2, 0, 1, 0, 0, 0)
check("Expose Armor counts what it really took off", eff("0xRog", 11198), 1000 - 1000 * kb / (1 - 1980 / 7480), 0.01)

-- A reading that never dropped is no reading: estimates only.
defNPC("0xV13", "Stubborn", 1000000)
ARMOR_NOW["0xV13"] = 3000
fire("AUTO_ATTACK_OTHER", "0xRog", "0xV13", 500, 2, 0, 1, 0, 0, 0)
fire("AURA_CAST_ON_OTHER", 11198, "0xRog", "0xV13")
fire("DEBUFF_ADDED_OTHER", "0xV13", 1, 11198, 1, 60, 5, 0)
advance(1)
local exRog = eff("0xRog", 11198)
fire("AUTO_ATTACK_OTHER", "0xRog", "0xV13", 1000, 2, 0, 1, 0, 0, 0)
check("an armor reading that did not drop counts nothing exact", eff("0xRog", 11198), exRog, 0.01)
-- A mob the client no longer has is never handed to nampower: that read
-- crashed the client (ERROR #132, 10/20-10/24).
local asked = 0
GetUnitField = function(guid, f) asked = asked + 1 return { 2000, 0, 0, 0, 0, 0, 0 } end
Wrekkit.value.liveArmor = {}
check("a mob the client does not have is not asked about", Wrekkit.value:LiveArmor("0xGone"), nil)
check("  nampower is never called for it", asked, 0)
check("one it has still is", Wrekkit.value:LiveArmor("0xV11"), 2000)

ARMOR_NOW = nil
GetUnitField = function() return "" end
Wrekkit.db.mobArmor = nil

-- By effect, for the report's Raid Contrib tab: biggest first, each with
-- who added how much, biggest first too.
local byEffect = Wrekkit.report:Effects(Wrekkit.report:View({ enc }, {}), "value")
check("effects come biggest first", byEffect[1] and byEffect[2] and byEffect[1].total >= byEffect[2].total, true)
local sunderE
for _, e in ipairs(byEffect) do if e.name == "Sunder Armor (est.)" then sunderE = e end end
check("a shared effect lists both its builders", sunderE and table.getn(sunderE.players), 2)
check("its biggest builder first", sunderE and sunderE.players[1].amount >= sunderE.players[2].amount, true)
check("support is its own list", table.getn(Wrekkit.report:Effects(Wrekkit.report:View({ enc }, {}), "support")) > 0, true)

-- Announced from the Raid Contrib tab: either way, whatever the setting,
-- support included; and drilled in, one effect's builders.
;(function()
  local function has(ls, pat)
    for _, l in ipairs(ls) do if string.find(l, pat, 1, true) then return l end end
    return nil
  end
  local ctx = { metric = "value", metrics = { "value" }, encounters = { enc }, label = "Test",
                contrib = true, valueMode = "combined" }
  local lines = Wrekkit.announce:Lines(ctx, 15)
  local sl = has(lines, "Sunder Armor (est.)")
  check("contrib, totals: Sunder's builders counted", sl and string.find(sl, "(2 players)", 1, true) ~= nil, true)
  check("contrib, totals: and not named", sl and string.find(sl, "Tanky", 1, true), nil)
  check("contrib includes what judgements give back", has(lines, "Judgement of Wisdom") ~= nil, true)
  ctx.valueMode = "individual"
  lines = Wrekkit.announce:Lines(ctx, 15)
  sl = has(lines, "Sunder Armor (est.)")
  check("contrib, individual: each builder named", sl and string.find(sl, "Tanky", 1, true) ~= nil
    and string.find(sl, "Second", 1, true) ~= nil, true)
  ctx.contribEffect = "Sunder Armor (est.)"
  lines = Wrekkit.announce:Lines(ctx, 15)
  check("one effect: its total in the header", string.find(lines[1], "Sunder Armor (est.)", 1, true) ~= nil
    and string.find(lines[1], "from 2 players", 1, true) ~= nil, true)
  check("one effect: a line per builder", lines[2] and lines[3] and string.find(lines[2], "%%") ~= nil, true)
end)()

-- Switched off, nothing more is counted.
Wrekkit.db.raidValue = nil
local total = val("0xLock")
hit("0xV1", "0xLock2", 11661, 1100, 5)
check("off: hits add nothing", val("0xLock"), total, 0.01)

IN_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
SpellInfo = realInfo
TH.clearRaid()
Wrekkit.capture.buffs = {}
Wrekkit.ResetData("all")
end)()

;(function()
  -- Friendly fire (Living Bomb going off on the rogue, hitting the priest)
  -- is the priest's damage taken, not the rogue's damage done.
  local E = Wrekkit.encounter
  local realLive, realIn = E.live, E.inCombat
  E.live, E.inCombat = nil, false
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP1", 11267, 700, "0,0,0", 0, 0)
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xP2", "0xP1", 20476, 1500, "0,0,0", 0, 2)
  local fuffA, priestA
  for _, a in pairs(E.live.actors) do
    if a.name == "Fuff" then fuffA = a end
    if a.name == "Elfpriest" then priestA = a end
  end
  check("friendly fire is not damage done", fuffA and fuffA.damage, 700)
  check("nor in the raid's damage", E.live.totals.damage, 700)
  check("but it is damage taken", priestA and priestA.taken, 1500)
  E.live, E.inCombat = realLive, realIn
end)()

;(function()
  -- A line-of-sight pull: the tank's opener, then nothing while the mob
  -- runs back. Too short a pull of its own, it is held, and the fight
  -- that follows goes on in it -- opener and all.
  local E = Wrekkit.encounter
  local realLive, realIn = E.live, E.inCombat
  E.live, E.inCombat, E.heldPull = nil, false, nil
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP3", 11267, 640, "0,0,0", 0, 0)
  local opener = E.live
  E:CombatEnd()
  advance(6)
  E:Finish()
  check("an opener on its own is held, not kept or dropped", E.heldPull, opener)
  advance(8)
  E:CombatStart()
  check("the fight that follows goes on in it", E.live, opener)
  local hunter
  for _, a in pairs(E.live.actors) do if a.name == "Moorhunt" then hunter = a end end
  check("  with the opener's damage", hunter and hunter.damage, 640)
  -- Nothing follows: it is dropped, as before.
  E.live, E.inCombat, E.heldPull = nil, false, nil
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP3", 11267, 640, "0,0,0", 0, 0)
  local lone = E.live
  E:CombatEnd()
  advance(6)
  E:Finish()
  advance(40)
  E:CombatStart()
  check("but not past the hold", E.live ~= lone, true)
  -- A quick kill while you drank, with nothing after it: kept, not lost.
  E.live, E.inCombat, E.heldPull = nil, false, nil
  local before = table.getn(Wrekkit.db.encounters)
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP3", 11267, 900, "0,0,0", 0, 0)
  local quick = E.live
  E:CombatEnd()
  advance(4)
  E:Finish()
  advance(31)
  E:ExpireHeld(quick)
  check("a short fight that did real damage is kept", table.getn(Wrekkit.db.encounters), before + 1)
  -- A flicker that hurt nothing: dropped.
  E.live, E.inCombat, E.heldPull = nil, false, nil
  E:CombatStart()
  local flicker = E.live
  E:CombatEnd()
  advance(2)
  E:Finish()
  advance(31)
  E:ExpireHeld(flicker)
  check("a combat that hurt nothing is dropped", table.getn(Wrekkit.db.encounters), before + 1)
  E.live, E.inCombat, E.heldPull = realLive, realIn, nil
end)()

;(function()
  -- A split pull (10/25): the tank pulls, the mob runs back, the fight goes
  -- quiet for 6 s, then the raid engages. The mob is alive, so the pull is
  -- held and the fight goes on in it.
  local E = Wrekkit.encounter
  local realLive, realIn = E.live, E.inCombat
  E.live, E.inCombat, E.heldPull = nil, false, nil
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP3", 11267, 500, "0,0,0", 0, 0)
  local first = E.live
  advance(7)
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP3", 11267, 500, "0,0,0", 0, 0)
  E:CombatEnd()
  advance(6)
  E:Finish(nil, true)
  check("a pull whose mob lives is held, not stored", E.heldPull, first)
  advance(6)
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP1", 11267, 800, "0,0,0", 0, 0)
  check("the fight on its mob goes on in it", E.live, first)
  -- Held, then a fight on another mob: its own pull, the held one stored.
  E:CombatEnd()
  advance(6)
  E:Finish(nil, true)
  local before = table.getn(Wrekkit.db.encounters)
  advance(3)
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xAdd", "0xP1", 11267, 300, "0,0,0", 0, 0)
  check("a fight on other mobs is a pull of its own", E.live ~= first, true)
  check("  and the held one is stored", table.getn(Wrekkit.db.encounters), before + 1)
  -- An explicit end (a zone change, a logout) stores it straight away.
  E.live, E.inCombat, E.heldPull = nil, false, nil
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP3", 11267, 500, "0,0,0", 0, 0)
  advance(8)
  fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xP3", 11267, 500, "0,0,0", 0, 0)
  E:CombatEnd()
  local n0 = table.getn(Wrekkit.db.encounters)
  E:Finish()
  check("an explicit end stores it, mob alive or not", table.getn(Wrekkit.db.encounters), n0 + 1)
  E.live, E.inCombat, E.heldPull = realLive, realIn, nil
end)()

----------------------------------------------------------------------
print("\n-- saved settings --")
----------------------------------------------------------------------
do
-- A default nothing ever read: each window keeps its own geometry. Every
-- saved file up to 0.4.1 carries a copy of it.
local saved = WrekkitDB
WrekkitDB = { window = { point = "CENTER", x = 0, y = 0, w = 900, h = 620 },
              encounters = {} }
Wrekkit.InitDB()
check("the unused window default leaves old files", WrekkitDB.window, nil)
check("and is no longer a default", Wrekkit.defaults.window, nil)
WrekkitDB = saved
Wrekkit.db = saved
end

print(string.format("\n%d passed, %d failed\n", pass, fail))

if fail > 0 then os.exit(1) end

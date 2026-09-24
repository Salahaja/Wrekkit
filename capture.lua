--[[ Wrekkit :: capture

Taps the structured combat events nampower delivers straight to Lua and
normalises them into a single stream the aggregator consumes. This is the
layer that replaces the website's log parser: the events below carry GUIDs,
spell ids, crit and periodic flags and mitigation breakdowns already, so
there is no string scraping anywhere in this addon.

Event payloads (nampower EVENTS.md). Note the argument order is NOT
consistent between families -- swings are source-first, spell damage and
heals are target-first. Getting this backwards silently swaps your meters,
so each handler below restates the order it is relying on.

  AUTO_ATTACK_SELF/OTHER   (attacker, target, damage, hitInfo, victimState,
                            subDamageCount, blocked, absorbed, resisted)
  SPELL_DAMAGE_EVENT_*     (target, caster, spellId, amount, mitigationStr,
                            hitInfo, school, effectAuraStr)
  SPELL_HEAL_BY_*/ON_SELF  (target, caster, spellId, amount, crit, periodic)
  SPELL_MISS_*             (caster, target, spellId, missInfo)
  SPELL_DISPEL_BY_*        (caster, target, spellId)
  DAMAGE_SHIELD_*          (shieldOwner, attacker, damage, school)
  ENVIRONMENTAL_DMG_*      (unit, damageType, damage, absorb, resist)
  UNIT_DIED                (guid)

Unit metadata comes from SuperWoW, which accepts a GUID anywhere a unit
token is expected, and exposes "<guid>owner" for pet attribution.
]]

local W = Wrekkit
W.capture = {}
local C = W.capture

local NULL_GUID = "0x0000000000000000"

--[[ Critical-strike detection. The two event families do NOT agree on how
     they report it, and assuming they do is silently wrong rather than
     obviously wrong.

     Auto attacks carry the raw HitInfo bitfield straight from the
     attacker-state update, where the critical flag is 0x200:

       0x0002  AFFECTS_VICTIM   set on essentially every landed swing
       0x0010  MISS
       0x0020  FULL_ABSORB
       0x0200  CRITICALHIT      <- the one that matters
       0x4000  GLANCING
       0x8000  CRUSHING

     Spell damage instead carries a small normalised code where 2 means crit.
     Testing 0x02 against a swing therefore matches AFFECTS_VICTIM and reports
     every white hit as a critical -- a 100% crit rate on melee. ]]
local HITINFO_CRIT = 512        -- 0x200, auto attacks
local SPELL_HIT_CRIT = 2        -- normalised code, spell damage

--- Is `bit` set in `value`? Lua 5.0 has no bitwise operators.
local function hasBit(value, bit)
  return math.mod(math.floor(value / bit), 2) == 1
end

C.events = {
  "AUTO_ATTACK_SELF", "AUTO_ATTACK_OTHER",
  "SPELL_DAMAGE_EVENT_SELF", "SPELL_DAMAGE_EVENT_OTHER",
  "SPELL_HEAL_BY_SELF", "SPELL_HEAL_BY_OTHER", "SPELL_HEAL_ON_SELF",
  "SPELL_MISS_SELF", "SPELL_MISS_OTHER",
  "SPELL_DISPEL_BY_SELF", "SPELL_DISPEL_BY_OTHER",
  "DAMAGE_SHIELD_SELF", "DAMAGE_SHIELD_OTHER",
  "ENVIRONMENTAL_DMG_SELF", "ENVIRONMENTAL_DMG_OTHER",
  "SPELL_GO_SELF", "SPELL_GO_OTHER",
  "UNIT_DIED",

  -- Buffs. Edge-triggered by nampower: these fire when something is gained
  -- or lost, never on a timer, so uptime costs nothing to follow. Debuffs
  -- are not followed: nothing in the addon shows them, and recording data
  -- no view reads is storage spent for nothing.
  "BUFF_ADDED_SELF", "BUFF_REMOVED_SELF",
  "BUFF_ADDED_OTHER", "BUFF_REMOVED_OTHER",
}

-- CVars nampower gates the richer events behind. Enabling them is cheap and
-- idempotent; without them the addon sees swings but no heals.
C.cvars = {
  "NP_EnableAutoAttackEvents",
  "NP_EnableSpellHealEvents",
  "NP_EnableSpellEnergizeEvents",
  "NP_EnableSpellGoEvents",     -- carries the itemId behind a cast
  -- Not NP_EnableAuraCastEvents: that gates AURA_CAST_ON_*, a different
  -- family. BUFF_ADDED/REMOVED need no CVar at all.
}

----------------------------------------------------------------------
-- unit registry
----------------------------------------------------------------------

-- guid -> { name, class, isPlayer, owner, ownerName, maxHealth, health, rank }
C.units = {}

-- Event tallies, so "nothing is recording" can be distinguished from
-- "nothing is arriving" without guesswork. Read by /wrek status.
C.seen = {}
C.seenTotal = 0
C.lastEventAt = nil

-- Vanilla's UnitClass does not reliably return the English token, so keep a
-- localised map and fall back to the roster, which does carry fileName.
local CLASS_TOKEN = {
  ["Warrior"] = "WARRIOR", ["Paladin"] = "PALADIN", ["Hunter"] = "HUNTER",
  ["Rogue"] = "ROGUE", ["Priest"] = "PRIEST", ["Shaman"] = "SHAMAN",
  ["Mage"] = "MAGE", ["Warlock"] = "WARLOCK", ["Druid"] = "DRUID",
}

--- Names harvested from the raid/party roster, which is authoritative and
--- works even for members who are out of visual range. Never cleared: a
--- class does not change, and remembering it keeps colours stable for people
--- who have since left the group.
C.rosterClass = {}

--- Who is in the group RIGHT NOW. Rebuilt from scratch on every scan --
--- unlike rosterClass this has to forget people, or the "ignore outsiders"
--- filter would keep counting someone long after they left the raid.
C.groupMembers = {}

function C:ScanRoster()
  local fresh = {}

  local me = UnitName("player")
  local _, myToken = UnitClass("player")
  if me then
    self.rosterClass[me] = myToken or CLASS_TOKEN[UnitClass("player")] or self.rosterClass[me]
    fresh[me] = true
  end

  local n = GetNumRaidMembers()
  if n and n > 0 then
    for i = 1, n do
      local name, _, _, _, _, fileName = GetRaidRosterInfo(i)
      if name then
        if fileName then self.rosterClass[name] = fileName end
        fresh[name] = true
      end
    end
  else
    n = GetNumPartyMembers()
    for i = 1, (n or 0) do
      local unit = "party" .. i
      local name = UnitName(unit)
      local _, token = UnitClass(unit)
      if name then
        self.rosterClass[name] = token or CLASS_TOKEN[UnitClass(unit)] or self.rosterClass[name]
        fresh[name] = true
      end
    end
  end

  self.groupMembers = fresh
  self:PruneBuffs()
end

--- Is this player in the current party or raid? Solo, only you are.
function C:InGroup(name)
  if not name then return false end
  return self.groupMembers[name] == true
end

--[[ Is this an actual name, or the client's placeholder?

     Vanilla returns the localised "Unknown" for a unit it has not loaded
     yet. That is normal for a few seconds after a zone change, a relog or
     a crash, while the rest of the group is still out of range.

     It is a placeholder, not a name, and caching it is how an entire group
     disappears from the report. The entry keeps "Unknown" for the rest of
     the session; "Unknown" is not in the roster, so InGroup is false and
     the ignore-outsiders filter drops every one of them. Worse, several
     players collapse into one row, because they now share a name. ]]
function C:IsRealName(name)
  if not name or name == "" then return false end
  if name == "Unknown" then return false end
  -- UNKNOWN is FrameXML's localised copy of the same placeholder.
  if UNKNOWN and name == UNKNOWN then return false end
  return true
end

--- Everything we need, or is a lookup still outstanding?
local function fullyResolved(u)
  if u.class == "UNKNOWN" then return false end
  if not u.name then return false end
  -- A pet with no owner yet still has a lookup pending.
  if u.class == "PET" and not u.ownerName then return false end
  return true
end

-- How long to wait before retrying a unit that would not resolve, so a
-- genuinely unresolvable one cannot cost a lookup on every single event.
local RESOLVE_RETRY = 0.5

--- Resolve (and cache) everything we know about a GUID. Safe to call on
--- every event: the hot path is a single table lookup once a unit is known.
function C:Unit(guid)
  if not guid or guid == "" or guid == NULL_GUID then return nil end

  local u = self.units[guid]
  --[[ Keep retrying until the NAME resolves too, not just the class.

       This guard used to test the class alone. A unit whose class resolved
       but whose name came back as the placeholder was then considered done
       and never looked at again -- so one bad moment, typically the seconds
       right after a crash or a zone, froze it as "Unknown" for the whole
       session. ]]
  if u and fullyResolved(u) then return u end

  if not u then
    u = { guid = guid, name = nil, class = "UNKNOWN", isPlayer = false }
    self.units[guid] = u
  end

  -- Do not re-probe an unresolvable unit on every event.
  local now = (GetTime and GetTime()) or 0
  if u.nextTry and now < u.nextTry then return u end
  u.nextTry = now + RESOLVE_RETRY

  -- GetUnitData is nampower's existence probe; without it UnitName on an
  -- out-of-range GUID can return a stale or empty string.
  local ok = GetUnitData and GetUnitData(guid)
  local name = UnitName(guid)
  if not self:IsRealName(name) then
    -- Never commit the placeholder: leave the name unset so the next pass
    -- tries again once the unit is actually loaded.
    name = nil
    if not ok then return u end
  end
  u.name = name or u.name

  --[[ Roster before unit API.

       Anyone in your party or raid is a player, whatever UnitIsPlayer says
       about a unit the client cannot currently resolve. Checking the roster
       first is also what makes cross-faction groups work: the roster carries
       them, while the faction-aware unit calls may not. ]]
  local rosterToken = u.name and self.rosterClass[u.name]

  if rosterToken or (UnitIsPlayer and UnitIsPlayer(guid) == 1) then
    u.isPlayer = true
    local localized, token = UnitClass(guid)
    u.class = token
        or rosterToken
        or CLASS_TOKEN[localized or ""]
        or "UNKNOWN"
  else
    -- Pet or NPC. "<guid>owner" is SuperWoW's owner token.
    local owner = GetUnitGUID and GetUnitGUID(guid .. "owner")
    if owner and owner ~= "" and owner ~= NULL_GUID then
      u.owner = owner
      u.class = "PET"
      -- The owner may not have resolved yet either. Leaving ownerName unset
      -- keeps the pet in the retry path, rather than pinning it to a pet
      -- belonging to "Unknown" for the rest of the night.
      local ow = self.units[owner]
      local ownerName = (ow and ow.name) or UnitName(owner)
      if not self:IsRealName(ownerName) then ownerName = nil end
      u.ownerName = ownerName or u.ownerName
    elseif ok then
      u.class = "ENEMY"
    else
      --[[ Do NOT commit to "enemy" on a unit we could not resolve.
           Classification is cached, and E:Actor only re-resolves while the
           class is still UNKNOWN -- so guessing here would lock an
           out-of-range player in as an enemy for the rest of the encounter.
           Leaving it unknown costs one more lookup and gets it right. ]]
      return u
    end
  end

  u.maxHealth = (UnitHealthMax and UnitHealthMax(guid)) or u.maxHealth

  --[[ "worldboss", "rareelite", "elite", "rare" or "normal". Asked once and
       kept, because it is the one thing the client will tell us outright
       about whether a fight was a boss -- health alone cannot separate a
       raid boss from a dungeon boss without a threshold that is wrong for
       one of them.

       Guarded rather than assumed: this takes a GUID only because SuperWoW
       accepts one anywhere a unit token goes, and if that ever stops being
       true the answer is "no idea", not an error twice a second. ]]
  if u.rank == nil and UnitClassification then
    local ok, rank = pcall(UnitClassification, guid)
    if ok and type(rank) == "string" and rank ~= "" then u.rank = rank end
  end

  return u
end

--- Display name, with the owner in parentheses for pets so the tables read
--- like the site's ("Raptor (Moorhunt)").
function C:Label(u)
  if not u then return "?" end
  if u.class == "PET" and u.ownerName then
    return (u.name or "Pet") .. " (" .. u.ownerName .. ")"
  end
  return u.name or "?"
end

----------------------------------------------------------------------
-- health tracking (for overhealing)
----------------------------------------------------------------------

--[[ Heal events carry the raw amount, never the effective amount -- the same
     limitation the website works under. Effective healing is therefore
     derived from the target's health deficit at the moment the heal landed:

         effective = min(amount, maxHealth - healthBefore)
         overheal  = amount - effective

     The subtle part is healthBefore. Reading UnitHealth at event time gives
     health AFTER the heal, and backing the heal out of it (after - amount)
     is exactly wrong in the overheal case: a 900 heal into a 200 deficit
     leaves health at max, so "after - amount" claims a 900 deficit and
     reports zero overheal. That is circular -- the thing being solved for
     is the thing being assumed.

     So health is tracked forward instead: damage subtracts, effective
     healing adds, and a throttled sweep of the raid re-reads UnitHealth to
     correct the drift that regen and out-of-range events cause. A resync
     landing between a heal applying server-side and its event arriving can
     still under-count that one heal; that race is inherent to vanilla and
     is what every 1.12 healing meter lives with. ]]

local RESYNC_INTERVAL = 0.4
local lastResync = 0

--- Pull authoritative health for everyone we can see. Cheap: at most 40
--- UnitHealth calls, several frames apart.
function C:ResyncHealth()
  local now = GetTime()
  if (now - lastResync) < RESYNC_INTERVAL then return end
  lastResync = now

  local n = GetNumRaidMembers()
  local prefix, count = "raid", n
  if not n or n == 0 then
    prefix, count = "party", (GetNumPartyMembers() or 0)
  end

  for i = 0, count do
    local unit = (i == 0) and "player" or (prefix .. i)
    local exists, guid = UnitExists(unit)
    if exists and guid then
      local u = self.units[guid]
      if u then
        local hp = UnitHealth(unit)
        if hp and hp > 0 then
          u.health = hp
          u.maxHealth = UnitHealthMax(unit) or u.maxHealth
        end
      end
    end
  end
end

--- Current best estimate of a unit's health, seeding from the client the
--- first time we see it.
function C:Health(guid, u)
  if u.health then return u.health end
  local hp = UnitHealth and UnitHealth(guid)
  if hp and hp > 0 then
    u.health = hp
  else
    u.health = u.maxHealth
  end
  return u.health
end

function C:MaxHealth(guid, u)
  local maxHP = u.maxHealth
  if not maxHP or maxHP <= 0 then
    maxHP = (UnitHealthMax and UnitHealthMax(guid)) or 0
    u.maxHealth = maxHP
  end
  return maxHP
end

--- Apply damage to the tracked health pool.
function C:TakeDamage(guid, amount)
  -- Resolve rather than look up: a unit's first event is often the very
  -- damage that introduces it.
  local u = self:Unit(guid)
  if not u then return end
  local hp = self:Health(guid, u)
  if not hp then return end
  hp = hp - amount
  if hp < 0 then hp = 0 end
  u.health = hp
end

function C:SplitHeal(guid, amount)
  local u = self:Unit(guid)
  if not u then return amount, 0 end

  local maxHP = self:MaxHealth(guid, u)
  -- Without a max we cannot tell effective from overheal; counting it all as
  -- effective is the honest default and self-corrects once the unit is seen.
  if maxHP <= 0 then return amount, 0 end

  local before = self:Health(guid, u) or maxHP
  local deficit = maxHP - before
  if deficit < 0 then deficit = 0 end

  local effective = amount
  if effective > deficit then effective = deficit end

  local after = before + effective
  if after > maxHP then after = maxHP end
  u.health = after

  return effective, amount - effective
end

----------------------------------------------------------------------
-- spell names
----------------------------------------------------------------------

local spellCache = {}

--- SuperWoW's SpellInfo resolves an arbitrary spell id to name and icon,
--- which the stock 1.12 API cannot do (GetSpellTexture is spellbook-indexed).
function C:Spell(spellId)
  if not spellId or spellId == 0 then return "Melee", nil end
  local hit = spellCache[spellId]
  if hit then return hit[1], hit[2] end

  local name, rank, texture
  if SpellInfo then
    -- name, RANK, texture. The rank used to be discarded, which made every
    -- rank of a spell read identically even though they are tracked as
    -- separate rows -- and they are separate rows for a reason: different
    -- ranks are different spells with different coefficients and costs.
    name, rank, texture = SpellInfo(spellId)
  end

  --[[ Without SuperWoW there is no SpellInfo, and every spell reads as its
       raw id. Names learned from the player's own casts fill in what they
       can; see LearnSpellName. ]]
  if not name or name == "" then
    name = W.db and W.db.spellNames and W.db.spellNames[spellId]
  end

  if name and name ~= "" then
    if rank and rank ~= "" then name = name .. " (" .. rank .. ")" end
  else
    name = "Spell " .. tostring(spellId)
  end

  spellCache[spellId] = { name, texture }
  return name, texture
end

--[[ Learn a spell's name without SuperWoW.

     SPELLCAST_START is a stock 1.12 event and its first argument is the
     spell's NAME -- the one thing the nampower events never carry, since
     they deal in ids. SPELL_GO_SELF fires for the same cast with the ID.
     Pairing the two teaches us one spell per cast, and the answer is kept
     in SavedVariables so it accumulates instead of being relearned.

     Only cast-time spells announce themselves this way; instants never fire
     SPELLCAST_START, so they keep their id. Partial, but it turns the
     player's own spellbook from numbers into names over a night. ]]
function C:LearnSpellName(spellId)
  if not spellId or spellId == 0 then return end
  if SpellInfo then return end          -- SuperWoW already answers this
  if not self.pendingCastName then return end
  if (GetTime() - (self.pendingCastAt or 0)) > 1.0 then return end

  if not W.db then return end
  if not W.db.spellNames then W.db.spellNames = {} end
  if W.db.spellNames[spellId] then return end

  W.db.spellNames[spellId] = self.pendingCastName
  -- Drop the cached "Spell 1234" so the next lookup picks up the name.
  spellCache[spellId] = nil
end

----------------------------------------------------------------------
-- items
----------------------------------------------------------------------

local itemCache = {}

--[[ Name the item behind a cast.

     GetItemInfo only answers for items already in the client's cache, which
     for someone else's potion it usually is not. The spell the item cast is
     the fallback, and for consumables it is nearly always descriptive
     ("Greater Fire Protection") because the spell IS the effect.

     Only a real item name is cached. Caching the fallback would freeze the
     worse answer in place even after the client learns the item. ]]
function C:Item(itemId, spellId)
  if not itemId or itemId == 0 then return nil end

  local hit = itemCache[itemId]
  if hit then return hit end

  local name
  if GetItemInfo then name = GetItemInfo(itemId) end
  if name and name ~= "" then
    itemCache[itemId] = name
    return name
  end

  local spellName = self:Spell(spellId)
  if spellName and spellName ~= "Melee" then return spellName end
  return "Item " .. tostring(itemId)
end

----------------------------------------------------------------------
-- event handlers
----------------------------------------------------------------------

local function num(v) return tonumber(v) or 0 end

--- mitigationStr is "absorb,block,resist"; pull the absorbed portion so it
--- can be reported separately from landed damage.
local function mitigation(str)
  if not str or str == "" then return 0, 0, 0 end
  local a, b, r = 0, 0, 0
  local i = 0
  for piece in string.gfind(str, "[^,]+") do
    i = i + 1
    if i == 1 then a = num(piece)
    elseif i == 2 then b = num(piece)
    elseif i == 3 then r = num(piece) end
  end
  return a, b, r
end

function C:AUTO_ATTACK(attacker, target, damage, hitInfo, victimState, _, blocked, absorbed, resisted)
  damage = num(damage)
  if damage <= 0 then return end
  self:TakeDamage(target, damage)
  W.encounter:Damage(attacker, target, 0, damage, {
    crit = hasBit(num(hitInfo), HITINFO_CRIT),
    absorbed = num(absorbed),
    blocked = num(blocked),
    resisted = num(resisted),
  })
end

function C:SPELL_DAMAGE(target, caster, spellId, amount, mitigationStr, hitInfo, school)
  amount = num(amount)
  local absorbed, blocked, resisted = mitigation(mitigationStr)
  if amount <= 0 and absorbed <= 0 then return end
  self:TakeDamage(target, amount)
  W.encounter:Damage(caster, target, num(spellId), amount, {
    crit = hasBit(num(hitInfo), SPELL_HIT_CRIT),
    absorbed = absorbed,
    blocked = blocked,
    resisted = resisted,
    school = num(school),
  })
end

function C:SPELL_HEAL(target, caster, spellId, amount, critical, periodic)
  amount = num(amount)
  if amount <= 0 then return end
  local effective, over = self:SplitHeal(target, amount)
  W.encounter:Heal(caster, target, num(spellId), effective, over, {
    crit = num(critical) == 1,
    periodic = num(periodic) == 1,
  })
end

----------------------------------------------------------------------
-- buffs
----------------------------------------------------------------------

--[[ Which buffs are up on the group -- all the time, not only in combat.

     Uptime has to know what was ALREADY up when a pull began. A flask is
     drunk before the pull, not during it, so an encounter that only
     listened while it was running would never hear about the one buff
     anybody asks about. The state therefore lives here, independent of any
     encounter, and an encounter reads it when a player first appears.

     Only the group and their pets. Every unit inside the combat log range
     raises these events, and at 200 yards that is a great many units no
     view shows -- keeping them would grow without bound for nothing.

     Per spell, the set of aura SLOTS holding it rather than a flag. Two
     priests' Renews are two slots of one spell, and the first expiring
     must not end the uptime of the second. ]]
C.buffs = {}   -- guid -> spellId -> { slots = { [slot] = true }, since, scanned }

--- The player, someone in the group, or one of their pets?
function C:IsGroupUnit(guid)
  if not guid then return false end
  local u = self.units[guid] or self:Unit(guid)
  if not u then return false end
  if u.isPlayer then return self:InGroup(u.name) end
  if u.class == "PET" then return self:InGroup(u.ownerName) end
  return false
end

--- Buffs a unit has RIGHT NOW, by spell id, asked of the client directly.
--- SuperWoW extends UnitBuff with the spell id as its third return; without
--- it the id is absent and this finds nothing, which is the honest answer.
function C:ScanBuffs(guid)
  if not UnitBuff or not guid then return nil end
  local found, any = {}, false
  local ok = pcall(function()
    for i = 1, 32 do
      local tex, _, spellId = UnitBuff(guid, i)
      if not tex then break end
      local id = tonumber(spellId)
      if id and id > 0 then
        found[id] = true
        any = true
      end
    end
  end)
  if ok and any then return found end
  return nil
end

--[[ Fill in buffs that were up before we could have heard about them.

     The events only describe changes. Anything gained before a /reload, or
     while the unit was out of range, never produced one we saw -- which is
     exactly how a flask drunk before a reload would read as never drunk.

     Add-only. A unit too far away to inspect returns nothing, and taking
     that as "no buffs" would erase state the events got right. ]]
function C:SeedBuffs(guid)
  local found = self:ScanBuffs(guid)
  if not found then return end
  local set = self.buffs[guid]
  if not set then
    set = {}
    self.buffs[guid] = set
  end
  local now = GetTime()
  for id in pairs(found) do
    if not set[id] then
      -- When it came up is unknown; `scanned` says so, and the encounter
      -- takes it as up since the pull began rather than inventing a time.
      set[id] = { slots = { scan = true }, since = now, scanned = true }
    end
  end
end

--- Take one instance of a buff off. An instance we never saw arrive -- it
--- predates us, or came from a scan -- has no known slot, so a removal we
--- cannot match consumes that rather than a real slot someone else holds.
local function dropInstance(b, slot)
  if slot and b.slots[slot] then
    b.slots[slot] = nil
    return
  end
  -- Searched for rather than taken from next(): next() returns whichever
  -- key it likes, and a real slot that another caster holds must survive.
  for k in pairs(b.slots) do
    if slot == nil or type(k) ~= "number" then
      b.slots[k] = nil
      return
    end
  end
end

--[[ A buff changed on a unit.

     state is nampower's own account of what happened:
       0  newly added              1  removed
       2  a stack moved up or down on an aura that STAYS on
     State 2 matters. Spending a charge fires a removal with state 2 while
     the buff remains, so taking every removal as "gone" stopped charge
     buffs such as Flurry at their first charge. A refresh fires neither:
     it arrives as BUFF_UPDATE_DURATION, which is not a change of state.

     Only a spell going from down to up, or up to down, is passed on --
     that edge is all uptime needs. ]]
function C:Buff(guid, slot, spellId, gained, state)
  spellId = tonumber(spellId)
  if not spellId or spellId == 0 or not guid then return end
  if W.db and W.db.trackAuras == false then return end
  state = tonumber(state)

  slot = tonumber(slot)

  local set = self.buffs[guid]
  local b = set and set[spellId]
  local now = GetTime()

  if not gained then
    -- Nothing to take off, or a stack spent on a buff that stays on.
    -- Checked before anything else: removals for units nobody tracks are
    -- most of the traffic, and they should cost a table lookup, no more.
    if not b or state == 2 then return end
    dropInstance(b, slot)
    if next(b.slots) == nil then
      set[spellId] = nil
      if next(set) == nil then self.buffs[guid] = nil end
      W.encounter:BuffEdge(guid, spellId, false, now)
    end
    return
  end

  -- A stack added to something already known changes nothing. A stack on
  -- something NOT known still says it is on, so it is taken as an arrival.
  if b then
    if state ~= 2 then b.slots[slot or "anon"] = true end
    return
  end
  if not self:IsGroupUnit(guid) then return end

  if not set then
    set = {}
    self.buffs[guid] = set
  end
  b = { slots = {}, since = now }
  b.slots[slot or "anon"] = true
  set[spellId] = b
  W.encounter:BuffEdge(guid, spellId, true, now)
end

--- A unit died: every buff it had is gone, whether or not the removals
--- arrive. Some do not, and a dead player still "holding" a flask would
--- read as full uptime.
function C:ClearBuffs(guid)
  if guid then self.buffs[guid] = nil end
end

--- Forget units that have left the group, so this stays the size of the
--- group rather than the size of the night.
function C:PruneBuffs()
  for guid in pairs(self.buffs) do
    if not self:IsGroupUnit(guid) then self.buffs[guid] = nil end
  end
end

function C:SPELL_MISS(caster, target, spellId, missInfo)
  W.encounter:Miss(caster, target, num(spellId), missInfo)
end

function C:SPELL_DISPEL(caster, target, spellId)
  W.encounter:Dispel(caster, target, num(spellId))
end

function C:DAMAGE_SHIELD(shieldOwner, attacker, damage, school)
  damage = num(damage)
  if damage <= 0 then return end
  -- The shield's owner is the source; the attacker who triggered it takes it.
  self:TakeDamage(attacker, damage)
  W.encounter:Damage(shieldOwner, attacker, 0, damage, { school = num(school), shield = true })
end

function C:ENVIRONMENTAL(unit, damageType, damage, absorb, resist)
  damage = num(damage)
  if damage <= 0 then return end
  self:TakeDamage(unit, damage)
  W.encounter:Environmental(unit, damageType, damage, num(absorb), num(resist))
end

--[[ SPELL_GO fires for every cast, and its FIRST argument is the item that
     triggered it -- zero for an ordinary spell, non-zero for a potion,
     elixir, flask, scroll, bandage or food.

     That single field is the whole consumable tracker. A spell-id whitelist
     would need constant maintenance and would miss anything this server added
     itself; "did a cast come from an item" is true by construction. ]]
function C:SPELL_GO(itemId, spellId, casterGuid, targetGuid)
  itemId = num(itemId)
  if itemId == 0 then return end
  W.encounter:Consumable(casterGuid, itemId, num(spellId))
end

----------------------------------------------------------------------
-- dispatch
----------------------------------------------------------------------

local dispatch = {}

dispatch.AUTO_ATTACK_SELF = function(a1, a2, a3, a4, a5, a6, a7, a8, a9)
  C:AUTO_ATTACK(a1, a2, a3, a4, a5, a6, a7, a8, a9)
end
dispatch.AUTO_ATTACK_OTHER = dispatch.AUTO_ATTACK_SELF

dispatch.SPELL_DAMAGE_EVENT_SELF = function(a1, a2, a3, a4, a5, a6, a7)
  C:SPELL_DAMAGE(a1, a2, a3, a4, a5, a6, a7)
end
dispatch.SPELL_DAMAGE_EVENT_OTHER = dispatch.SPELL_DAMAGE_EVENT_SELF

dispatch.SPELL_HEAL_BY_SELF = function(a1, a2, a3, a4, a5, a6)
  C:SPELL_HEAL(a1, a2, a3, a4, a5, a6)
end
dispatch.SPELL_HEAL_BY_OTHER = dispatch.SPELL_HEAL_BY_SELF
-- HEAL_ON_SELF can duplicate HEAL_BY_SELF when you heal yourself; the
-- aggregator de-dupes on (caster, target, spell, amount) within a tick.
dispatch.SPELL_HEAL_ON_SELF = dispatch.SPELL_HEAL_BY_SELF

-- BUFF_ADDED/REMOVED_*(guid, luaSlot, spellId, stackCount, auraLevel,
-- auraSlot, state), as ChronicleCompanion documents them. luaSlot follows
-- UnitBuff ordering and shifts as other buffs come and go; auraSlot is the
-- raw slot and stays put for as long as the aura does, so instances are
-- keyed by that.
local function buffOn(a1, a2, a3, a4, a5, a6, a7)
  C:Buff(a1, a6, a3, true, a7)
end
local function buffOff(a1, a2, a3, a4, a5, a6, a7)
  C:Buff(a1, a6, a3, false, a7)
end

dispatch.BUFF_ADDED_SELF = buffOn
dispatch.BUFF_ADDED_OTHER = buffOn
dispatch.BUFF_REMOVED_SELF = buffOff
dispatch.BUFF_REMOVED_OTHER = buffOff

dispatch.SPELL_MISS_SELF = function(a1, a2, a3, a4) C:SPELL_MISS(a1, a2, a3, a4) end
dispatch.SPELL_MISS_OTHER = dispatch.SPELL_MISS_SELF

dispatch.SPELL_DISPEL_BY_SELF = function(a1, a2, a3) C:SPELL_DISPEL(a1, a2, a3) end
dispatch.SPELL_DISPEL_BY_OTHER = dispatch.SPELL_DISPEL_BY_SELF

dispatch.DAMAGE_SHIELD_SELF = function(a1, a2, a3, a4) C:DAMAGE_SHIELD(a1, a2, a3, a4) end
dispatch.DAMAGE_SHIELD_OTHER = dispatch.DAMAGE_SHIELD_SELF

dispatch.ENVIRONMENTAL_DMG_SELF = function(a1, a2, a3, a4, a5)
  C:ENVIRONMENTAL(a1, a2, a3, a4, a5)
end
dispatch.ENVIRONMENTAL_DMG_OTHER = dispatch.ENVIRONMENTAL_DMG_SELF

--- SPELLCAST_START(spellName, duration). Stock 1.12, and the only place
--- a spell name is handed to us when SuperWoW is not installed.
dispatch.SPELLCAST_START = function(a1)
  if a1 and a1 ~= "" then
    C.pendingCastName = a1
    C.pendingCastAt = GetTime()
  end
end

dispatch.SPELL_GO_SELF = function(a1, a2, a3, a4)
  -- a2 is the spell id for the cast that just started, so this is where the
  -- name from SPELLCAST_START gets bound to an id.
  C:LearnSpellName(num(a2))
  C:SPELL_GO(a1, a2, a3, a4)
end
dispatch.SPELL_GO_OTHER = dispatch.SPELL_GO_SELF

dispatch.UNIT_DIED = function(a1)
  W.encounter:Death(a1)
  C:ClearBuffs(a1)
end

C.dispatch = dispatch

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

--- Reports which required pieces are missing so the addon can say so up
--- front rather than silently recording nothing.
--[[ What is missing, and what each absence costs.

     Nampower is checked FIRST and described as fatal, because it is: the
     combat events are the data, and without them the addon loads perfectly,
     opens both windows, and records absolutely nothing. An earlier version
     of this function checked only for SuperWoW, so exactly the one
     configuration that cannot work was the one that produced no warning.

     NAMPOWER_VERSION is Nampower's own marker; the file API is the fallback
     signal in case a build ever ships without setting it. ]]
function C:CheckEnvironment()
  local missing = {}

  local hasNampower = (NAMPOWER_VERSION ~= nil)
      or (WriteCustomFile ~= nil and ReadCustomFile ~= nil)
  if not hasNampower then
    table.insert(missing, "Nampower - NOTHING will be recorded without it. " ..
      "OctoLauncher installs it: Mods -> Nampower (it is not on by default)")
  elseif not (WriteCustomFile and ReadCustomFile) then
    table.insert(missing, "Nampower file API - no crash journal")
  end

  if not SpellInfo then
    table.insert(missing, "SuperWoW (SpellInfo) - abilities show as spell ids. " ..
      "OctoLauncher: Mods -> SuperWoW")
  end
  if not GetUnitGUID then
    table.insert(missing, "SuperWoW (GetUnitGUID) - no names, classes or pet owners. " ..
      "OctoLauncher: Mods -> SuperWoW")
  end
  if not SetCVar then
    table.insert(missing, "SetCVar - cannot enable the extended events")
  end

  return missing
end

--[[ The definitive check, which no load-time probe can make: combat has
     happened and not one event arrived. Said once, because the cause is a
     missing client mod and repeating it every pull would be nagging. ]]
function C:WarnIfSilent()
  if self.seenTotal > 0 then return end
  if self.warnedSilent then return end
  self.warnedSilent = true
  W.Print("|cffd44f53you just fought and no combat events arrived.|r " ..
    "Nothing is being recorded.")
  W.Print("This needs Nampower. In OctoLauncher it is |cffe0a22cMods -> Nampower|r, " ..
    "which is not enabled by default. Run |cffe0a22c/wrek status|r for details.")
end

--[[ How far away the client will tell us about combat.

     The default is 30 yards on this client, which is well inside a raid.
     Anyone further than that generates no events at all, so they are not
     merely inaccurate in the meter -- they are absent from it. This is the
     most common complaint about every combat-log meter on 1.12, and
     DPSMate's own documentation tells people to raise exactly these.

     Raised to 200, the same figure DPSMate recommends, which covers any
     raid instance. Every one is listed because the client gates each
     category separately: missing PartyPet alone loses every hunter and
     warlock pet in the raid. ]]
C.rangeCvars = {
  "CombatLogRangeCreature",
  "CombatLogRangeParty",
  "CombatLogRangePartyPet",
  "CombatLogRangeFriendlyPlayers",
  "CombatLogRangeFriendlyPlayersPets",
  "CombatLogRangeHostilePlayers",
  "CombatLogRangeHostilePlayersPets",
}

C.RANGE_DEFAULT = 200

--- What the client currently admits to, for /wrek status and the settings.
function C:CombatLogRange()
  if not GetCVar then return nil end
  local v = GetCVar("CombatLogRangeCreature")
  return tonumber(v)
end

--[[ Raise the range, unless the user asked us not to.

     Opt-out rather than opt-in: a meter that silently under-reports half
     the raid is worse than one that changed a setting, and the setting only
     affects how much the client tells this client. It does not touch what
     anyone else sees. ]]
function C:ApplyCombatLogRange()
  if not SetCVar then return end
  if W.db and W.db.combatLogRange == false then return end

  local want = (W.db and W.db.combatLogRangeYards) or self.RANGE_DEFAULT

  --[[ Remember what the client had before we first changed it, so turning
       this off puts it back instead of leaving the raised range in place.

       A value already at our target is not recorded: it was almost
       certainly set by an earlier Wrekkit that remembered nothing, and
       "restoring" it would restore nothing. ]]
  if W.db and not W.db.combatLogRangeSaved and GetCVar then
    local saved = {}
    for _, cv in ipairs(self.rangeCvars) do
      local ok, v = pcall(GetCVar, cv)
      if ok and v and tonumber(v) ~= tonumber(want) then saved[cv] = v end
    end
    W.db.combatLogRangeSaved = saved
  end

  for _, cv in ipairs(self.rangeCvars) do
    pcall(SetCVar, cv, want)
  end
end

--- Put the range back the way it was. Returns how many values were
--- restored and how many could not be, because none was ever recorded.
function C:RestoreCombatLogRange()
  if not SetCVar or not W.db then return 0, 0 end
  local saved = W.db.combatLogRangeSaved or {}
  local restored, unknown = 0, 0
  for _, cv in ipairs(self.rangeCvars) do
    if saved[cv] then
      if pcall(SetCVar, cv, saved[cv]) then restored = restored + 1 end
    else
      unknown = unknown + 1
    end
  end
  W.db.combatLogRangeSaved = nil
  return restored, unknown
end

function C:EnableCVars()
  if not SetCVar then return end
  for _, cv in ipairs(self.cvars) do
    SetCVar(cv, 1)
  end
  self:ApplyCombatLogRange()
end

function C:Start()
  if self.frame then return end
  self:EnableCVars()

  local f = CreateFrame("Frame", "WrekkitCaptureFrame")
  self.frame = f

  -- Correct tracked health drift. ResyncHealth throttles itself, so this is
  -- a single comparison on most frames.
  f:SetScript("OnUpdate", function()
    C:ResyncHealth()
    W.encounter:HealStuckCombat()
  end)

  f:SetScript("OnEvent", function()
    local handler = dispatch[event]
    if handler then
      -- Counted so "nothing is recording" can be told apart from "nothing is
      -- arriving" without guessing. See W.Status / "/wrek status".
      C.seen[event] = (C.seen[event] or 0) + 1
      C.seenTotal = C.seenTotal + 1
      C.lastEventAt = GetTime()
      handler(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
      return
    end
    if event == "PLAYER_REGEN_DISABLED" then
      W.encounter:CombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
      W.encounter:CombatEnd()
      -- Leaving combat is the moment we can tell whether anything works.
      C:WarnIfSilent()
    elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED"
        or event == "PLAYER_ENTERING_WORLD" then
      C:ScanRoster()
    end
  end)

  for _, e in ipairs(self.events) do f:RegisterEvent(e) end
  f:RegisterEvent("PLAYER_REGEN_DISABLED")
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
  f:RegisterEvent("RAID_ROSTER_UPDATE")
  f:RegisterEvent("PARTY_MEMBERS_CHANGED")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  -- Stock 1.12 event whose arg1 is the spell NAME. Only useful when
  -- SuperWoW is absent, but registering it always keeps the path exercised.
  f:RegisterEvent("SPELLCAST_START")

  self:ScanRoster()
end

--- Units churn constantly in a raid (every whelp is a new GUID). Drop the
--- registry between encounters so it cannot grow without bound across a
--- night; anything still relevant is re-resolved on its next event.
function C:TrimUnits()
  local keep = {}
  for guid, u in pairs(self.units) do
    if u.isPlayer or u.class == "PET" then keep[guid] = u end
  end
  self.units = keep
end

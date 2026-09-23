--[[ Wrekkit :: encounter

Segmentation and aggregation. Turns the normalised event stream into the
same shape the website's report renders from:

  session    one night in one zone; holds many encounters
  encounter  one pull, from entering combat to leaving it
  actor      a player, a pet or an NPC inside an encounter
  bucket     one second of the timeline, four series wide

Everything is summed as events arrive -- there is no stored raw event log.
A 25-man Onyxia night is ~57k events; keeping them would cost far more
memory than the client can spare and buy nothing the rollups don't already
answer. The one thing rollups cannot do is re-filter after the fact, which
is the single feature the website keeps.
]]

local W = Wrekkit
W.encounter = {}
local E = W.encounter

-- Two pulls closer together than this are treated as one encounter, so a
-- half-second drop out of combat between waves doesn't shard the report.
local MERGE_GAP = 5

-- Interrupt effects, by spell id family. Vanilla has no interrupt event, so
-- these are counted when the spell lands on a casting enemy.
E.interruptSpells = {
  [1766] = true, [1767] = true, [1768] = true, [1769] = true,    -- Kick
  [6552] = true, [6554] = true,                                   -- Pummel
  [72]   = true, [1671] = true, [1672] = true,                    -- Shield Bash
  [8042] = true, [8044] = true, [8045] = true, [8046] = true,     -- Earth Shock
  [10412] = true, [10413] = true, [10414] = true,
  [2139] = true,                                                  -- Counterspell
}

E.live = nil          -- encounter currently being recorded
E.session = nil       -- session the live encounter belongs to
E.inCombat = false
E.lastCombatEnd = nil

----------------------------------------------------------------------
-- construction
----------------------------------------------------------------------

local function newActor(guid, u)
  return {
    guid = guid,
    name = u and u.name or "?",
    class = u and u.class or "UNKNOWN",
    isPlayer = u and u.isPlayer or false,
    owner = u and u.owner or nil,
    ownerName = u and u.ownerName or nil,
    maxHealth = u and u.maxHealth or 0,
    rank = u and u.rank or nil,

    damage = 0, taken = 0, healing = 0, overheal = 0,
    absorbed = 0, deaths = 0, dispels = 0, interrupts = 0,
    hits = 0, crits = 0, misses = 0, consumes = 0,

    -- Seconds this actor actually did something. Recount divides by
    -- this; Skada divides by the whole fight. The two disagree and
    -- people argue about it, so Wrekkit can answer either way.
    active = 0, lastActiveSec = nil,

    -- spellId -> { name, up (seconds), since (nil when down), applied }
    auras = {},
    dmgAbility = {},    -- spellId -> { name, amount, hits, crits, max, misses }
    healAbility = {},   -- spellId -> { name, amount, over, hits, crits }
    takenAbility = {},  -- spellId -> { name, amount, hits, max }
    consumeItem = {},   -- itemId  -> { name, amount = times used }
  }
end

local function newEncounter(session, now)
  return {
    id = session.nextId,
    sessionId = session.id,
    zone = session.zone,
    instanceId = session.instanceId or 0,
    name = "Trash",
    startTime = time(),
    startT = now,
    stopT = now,
    -- Position on the session timeline, in WALL-CLOCK seconds rather than
    -- GetTime seconds. GetTime resets to zero every time the client starts,
    -- so a GetTime-based offset would place post-crash encounters back at
    -- the beginning of the night's timeline. time() survives the restart.
    offset = time() - session.startTime,
    combat = 0,
    kill = false,
    actors = {},
    order = {},
    enemies = {},
    deaths = {},
    bucket = {},
    maxBucket = 0,
    totals = { damage = 0, healing = 0, overheal = 0, taken = 0, enemy = 0 },
  }
end

--[[ Identify where we are, precisely enough to recognise the same raid.

     The zone name alone is too weak. It cannot tell last week's Molten Core
     from this week's, and it changes the moment someone releases, because
     most instance graveyards sit in a different zone -- which is how a wipe
     with a long corpse run used to shard one night into several reports.

     A saved instance id is the real identity: the server issues one per
     lockout and keeps it for the whole reset. Two raids sharing an id ARE
     the same raid, however many days apart, so a raid picked up on Thursday
     appends to Tuesday's log instead of starting over.

     Dungeons have no lockout and so no id; they fall back to the zone with
     a longer grace period, which is what a corpse run needs. ]]
function E:Where()
  local zone = (GetRealZoneText and GetRealZoneText()) or "Unknown"

  local instanceType
  if IsInInstance then
    local inInstance, kind = IsInInstance()
    if inInstance then instanceType = kind end
  end

  local id = 0
  if GetNumSavedInstances and GetSavedInstanceInfo then
    local want = string.lower(zone)
    for i = 1, (GetNumSavedInstances() or 0) do
      local name, savedId = GetSavedInstanceInfo(i)
      if name and string.lower(name) == want then
        id = tonumber(savedId) or 0
        break
      end
    end
  end

  return zone, instanceType, id
end

local function newSession(now, zone, instanceType, instanceId)
  return {
    id = time(),
    zone = zone or GetRealZoneText() or "Unknown",
    instanceType = instanceType,
    instanceId = instanceId or 0,
    startTime = time(),
    startT = now,
    nextId = 1,
    encounters = {},
  }
end

--[[ Describe the session the encounter history ended in.

     The saved pointer is the fast path, but it lives in SavedVariables --
     which a crash destroys, since those are only written at a clean logout.
     The journal can restore the encounters themselves, and the newest of
     those describes its session just as well. Deriving from the history is
     therefore the reliable path and the pointer is only an optimisation. ]]
function E:SessionFromHistory()
  local list = (W.db and W.db.encounters) or {}
  local best = nil

  for _, e in ipairs(list) do
    -- Encounters someone shared with us describe THEIR night, not ours.
    if not e.sharedBy then
      local endsAt = (e.startTime or 0) + math.floor(e.duration or 0)
      if not best or endsAt > best.lastActivity then
        best = {
          id = e.sessionId,
          zone = e.zone,
          instanceId = e.instanceId or 0,
          startTime = (e.startTime or 0) - (e.offset or 0),
          nextId = (e.id or 0) + 1,
          lastActivity = endsAt,
        }
      end
    end
  end

  -- Ids must clear every encounter already in that session, not just the
  -- most recent one, or a resumed session can reuse an id.
  if best then
    for _, e in ipairs(list) do
      if e.sessionId == best.id and (e.id or 0) >= best.nextId then
        best.nextId = e.id + 1
      end
    end
  end

  return best
end

--[[ Rejoin the previous session instead of starting a new one.

     A raid night gets interrupted constantly -- a disconnect, a crash, a
     server restart, a /reload to fix some other addon. Each of those wipes
     the in-memory session, and without this every interruption would shard
     the night into separate reports that can never be compared or merged.

     Resuming needs two things to hold: same zone, and last activity recent
     enough that this is plainly a continuation rather than a new raid. The
     encounter id counter continues too, so ids stay unique within a session.

     Resolved at combat start rather than at load, because the zone is not
     reliably known yet while the client is still coming up. ]]
function E:ResumeOrNew(zone, now, instanceType, instanceId)
  local window = (W.db and W.db.resumeWindow) or 1200
  local saved = W.db and W.db.session

  instanceId = instanceId or 0

  --[[ Inside an instance the clock runs differently. A wipe, a release, the
       run back and re-forming can eat half an hour without anyone leaving,
       and that is one attempt, not two nights. Dungeons get an hour before
       we call it a separate visit; a saved raid does not need a clock at
       all, because the lockout id already says whether it is the same raid. ]]
  if instanceType then
    local instanceWindow = 3600
    if window > instanceWindow then instanceWindow = window end
    window = instanceWindow
  end

  if not (saved and saved.id and saved.startTime) then
    saved = self:SessionFromHistory()
  end

  --[[ A manual reset draws a line: everything on the far side of it is a
       closed book, however recent it is. Without this the resume logic would
       cheerfully rejoin the exact session the user just asked to leave --
       the two features would cancel each other out. ]]
  local barrier = (W.db and W.db.sessionBarrier) or 0

  if saved and saved.id and saved.startTime
      and (saved.lastActivity or 0) > barrier then
    local idle = time() - (saved.lastActivity or 0)

    --[[ Same lockout is the same raid, full stop. No time test: that is the
         whole point of the id, and it is what lets a raid paused on Tuesday
         be finished on Thursday and land in one report. The id changes when
         the instance resets, which ends the session on its own. ]]
    local sameLockout = instanceId > 0
        and (saved.instanceId or 0) == instanceId
        and saved.zone == zone

    --[[ When both sides carry a lockout id, the id decides and the clock
         does not get a vote. Two different ids are two different raids even
         ten minutes apart -- which is exactly what a reset looks like from
         in here, and resuming across one would merge this week's kill into
         last week's report. ]]
    local differentLockout = instanceId > 0
        and (saved.instanceId or 0) > 0
        and (saved.instanceId or 0) ~= instanceId

    local sameZoneRecently = not differentLockout
        and saved.zone == zone and idle >= 0 and idle <= window

    if sameLockout or sameZoneRecently then
      if sameLockout and idle > window then
        W.Print(string.format(
          "continuing this lockout's log from %s ago.", W.Duration(idle)))
      else
        W.Print(string.format("continuing the session from %s ago.",
          W.Duration(idle)))
      end
      return {
        id = saved.id,
        zone = zone,
        instanceType = instanceType,
        -- Keep the id we matched on, so the next resume can match it too.
        instanceId = (instanceId > 0) and instanceId or (saved.instanceId or 0),
        startTime = saved.startTime,
        startT = now,
        nextId = saved.nextId or 1,
        encounters = {},
        resumed = true,
      }
    end
  end

  return newSession(now, zone, instanceType, instanceId)
end

--[[ Close the current session and start logging fresh.

     Stored encounters are kept -- they are still browsable in the report's
     session list -- but nothing recorded from here on joins them. The
     barrier is what makes that stick: clearing the saved pointer alone would
     not, because ResumeOrNew falls back to deriving the session from the
     encounter history, which would resurrect exactly what was just closed. ]]
function E:StartNewSession()
  self.live = nil
  self.session = nil
  self.inCombat = false
  self.combatMark = nil
  self.lastCombatEnd = nil

  if W.db then
    W.db.session = nil
    W.db.sessionBarrier = time()
  end

  -- Make the journal emit a fresh session header on the next encounter.
  if W.store then W.store.journalSession = nil end

  W.capture:TrimUnits()
end

--- Remember where the session got to, so the next login can rejoin it.
function E:RememberSession(session, enc)
  if not W.db then return end
  W.db.session = {
    id = session.id,
    zone = session.zone,
    -- Without these a reload forgets which lockout this was, and the next
    -- pull opens a fresh session instead of rejoining the raid.
    instanceType = session.instanceType,
    instanceId = session.instanceId or 0,
    startTime = session.startTime,
    nextId = session.nextId,
    -- End of the encounter, not "now": Finish can run well after combat
    -- actually stopped, and at logout it runs arbitrarily later.
    lastActivity = (enc and enc.startTime and enc.duration)
        and (enc.startTime + math.floor(enc.duration))
        or time(),
  }
end

----------------------------------------------------------------------
-- actor access
----------------------------------------------------------------------

function E:Actor(guid)
  local enc = self.live
  if not enc or not guid then return nil end

  local a = enc.actors[guid]
  if a then
    --[[ Late-resolving names: a unit seen before it was in range starts as
         "?", and the client may hand back its "Unknown" placeholder for a
         while after that. Both mean "ask again", so neither can be allowed
         to settle. A pet whose owner has not resolved is also still
         pending. ]]
    if a.name == "?" or a.class == "UNKNOWN"
       or not W.capture:IsRealName(a.name)
       or (a.class == "PET" and not W.capture:IsRealName(a.ownerName)) then
      local u = W.capture:Unit(guid)
      if u and u.name then
        a.name = u.name
        a.class = u.class
        a.isPlayer = u.isPlayer
        a.owner = u.owner
        a.ownerName = u.ownerName
      end
    end
    return a
  end

  local u = W.capture:Unit(guid)
  a = newActor(guid, u)
  enc.actors[guid] = a
  table.insert(enc.order, guid)

  if not a.isPlayer and a.class ~= "PET" then
    enc.enemies[guid] = a
  end
  return a
end

----------------------------------------------------------------------
-- timeline
----------------------------------------------------------------------

--- Count a second in which this actor did something. O(1): only the
--- second index is compared, so a busy second costs one comparison.
local function noteActive(a, enc, now)
  if not a then return end
  local sec = math.floor(now - enc.startT)
  if a.lastActiveSec ~= sec then
    a.lastActiveSec = sec
    a.active = (a.active or 0) + 1
  end
end

--- How many hits before a death the recap keeps.
local RECAP_HITS = 8

--- Remember the last few hits this actor took, oldest overwritten first.
--- A fixed ring rather than a growing list: this runs on every hit taken by
--- every player in the raid, and only the tail is ever read.
local function noteRecent(a, enc, now, srcName, spell, amount, overkill)
  if not a.recent then a.recent = {} a.recentAt = 0 end
  a.recentAt = math.mod(a.recentAt or 0, RECAP_HITS) + 1
  a.recent[a.recentAt] = {
    t = now - enc.startT,
    src = srcName,
    spell = spell,
    a = amount,
    hp = a.health,
  }
end

--- The ring read out oldest-first, which is the order a recap is read in.
local function recentInOrder(a)
  if not a.recent then return {} end
  local out = {}
  local n = RECAP_HITS
  local at = a.recentAt or 0
  for i = 1, n do
    local idx = math.mod(at + i - 1, n) + 1
    local e = a.recent[idx]
    if e then table.insert(out, e) end
  end
  table.sort(out, function(x, y) return (x.t or 0) < (y.t or 0) end)
  return out
end

local function bucketFor(enc, now)
  local i = math.floor(now - enc.startT)
  if i < 0 then i = 0 end
  local b = enc.bucket[i]
  if not b then
    b = { dd = 0, dt = 0, hl = 0, eh = 0 }
    enc.bucket[i] = b
    if i > enc.maxBucket then enc.maxBucket = i end
  end
  return b
end

--[[ Who did what to whom, in this second.

     The four bucket totals say a spike happened but never say what it was.
     This keeps the contributions behind them, merged by source, spell AND
     target -- the target matters, because "who was attacking whom" is half
     of reading a pull.

     Bounded twice on purpose. Distinct triples in one second of a 40-man
     could run into the hundreds, and this is per second of every encounter
     we keep:

       BUCKET_KEYS  stops a single second growing without limit. Once it is
                    reached, existing entries still accumulate -- so the big
                    contributors, which are the ones already present, stay
                    accurate. Only a new small one is turned away.
       TOP_KEPT     is how many survive into storage, chosen at persist time
                    by size, so what is kept is what the click is asking
                    about.

     No sorting happens per event; that would be per-event work for a
     once-per-encounter need. ]]

local BUCKET_KEYS = 24
local TOP_KEPT = 4

local function contribute(b, kind, srcGuid, tgtGuid, spellId, amount)
  if not amount or amount <= 0 then return end
  if W.db and W.db.timelineDetail == false then return end
  if not srcGuid then return end

  local top = b.top
  if not top then
    top = {}
    b.top = top
    b.topKeys = 0
  end

  local key = kind .. (srcGuid or "") .. "\1" .. tostring(spellId or 0)
      .. "\1" .. (tgtGuid or "")
  local row = top[key]
  if row then
    row.a = row.a + amount
    row.n = row.n + 1
    return
  end

  if (b.topKeys or 0) >= BUCKET_KEYS then return end
  b.topKeys = (b.topKeys or 0) + 1
  top[key] = { k = kind, s = srcGuid, t = tgtGuid, id = spellId,
               a = amount, n = 1 }
end

----------------------------------------------------------------------
-- ingest
----------------------------------------------------------------------

--[[ One ability's running tally.

     `critAmount` is tracked separately so the detail view can report average
     normal and average crit rather than one blended average that describes
     neither. `min` starts at nil rather than 0 so the first landed hit sets
     it -- seeded at zero it would never move. ]]
local function abilityRow(tbl, spellId, name)
  local row = tbl[spellId]
  if not row then
    row = { id = spellId, name = name, amount = 0, over = 0,
            hits = 0, crits = 0, misses = 0,
            max = 0, min = nil, critAmount = 0,
            -- Partial resists. `resisted` is the damage the school ate, so
            -- amount + resisted is what the spell would have hit for.
            resisted = 0, resistHits = 0,
            r25 = 0, r50 = 0, r75 = 0,
            -- missBy is created on demand in E:Miss -- assigning nil in a
            -- constructor stores nothing, so declaring it here would only
            -- look like it did something.
            -- Why the ones that did not land failed, keyed by the client's
            -- miss code. A resist and a dodge are both "a miss" to the
            -- counter above, and they mean completely different things.
          }
    tbl[spellId] = row
  end
  return row
end

--[[ Vanilla resists a spell in quarters. The event gives an absolute amount,
     so the tier has to come back out of the ratio -- and it is worth having
     as a tier, because "half my Shadow Bolts are landing at 75% resist" is a
     gear problem and "a few at 25%" is just variance.

     Rounded to the nearest quarter rather than floored: the server's number
     is the damage actually removed, which does not divide perfectly once
     the spell's own rounding has happened. ]]
local function noteResist(row, landed, resisted)
  if not resisted or resisted <= 0 then return end

  row.resisted = (row.resisted or 0) + resisted
  row.resistHits = (row.resistHits or 0) + 1

  local potential = landed + resisted
  if potential <= 0 then return end

  local quarter = math.floor((resisted / potential) * 4 + 0.5)
  if quarter <= 1 then row.r25 = (row.r25 or 0) + 1
  elseif quarter == 2 then row.r50 = (row.r50 or 0) + 1
  else row.r75 = (row.r75 or 0) + 1 end
end

--- Fold one landed amount into an ability's spread.
local function noteAmount(row, amount, isCrit)
  if amount > row.max then row.max = amount end
  if not row.min or amount < row.min then row.min = amount end
  if isCrit then row.critAmount = (row.critAmount or 0) + amount end
end

function E:Damage(sourceGuid, targetGuid, spellId, amount, info)
  if not self.live then self:CombatStart() end
  local enc = self.live
  if not enc then return end
  info = info or {}

  local src = self:Actor(sourceGuid)
  local dst = self:Actor(targetGuid)
  if not src and not dst then return end

  local now = GetTime()
  local b = bucketFor(enc, now)
  local spellName = W.capture:Spell(spellId)

  if src then
    src.damage = src.damage + amount
    src.absorbed = src.absorbed + (info.absorbed or 0)
    src.hits = src.hits + 1
    if info.crit then src.crits = src.crits + 1 end

    noteActive(src, enc, now)
    local row = abilityRow(src.dmgAbility, spellId, spellName)
    row.amount = row.amount + amount
    row.hits = row.hits + 1
    if info.crit then row.crits = row.crits + 1 end
    --[[ First hit decides, because a spell has exactly one school. Melee
         carries none at all and arrives as spell id 0, which W.SchoolName
         reads as Physical rather than as unknown. ]]
    if row.school == nil then row.school = info.school end
    noteAmount(row, amount, info.crit)
    -- A PARTIAL resist: the spell landed, the school ate part of it. A FULL
    -- resist never reaches this function at all -- it arrives as a miss.
    noteResist(row, amount, info.resisted)

    if src.isPlayer or src.class == "PET" then
      enc.totals.damage = enc.totals.damage + amount
      b.dd = b.dd + amount
      contribute(b, "d", sourceGuid, targetGuid, spellId, amount)
    else
      enc.totals.enemy = enc.totals.enemy + amount
    end

    if spellId ~= 0 and self.interruptSpells[spellId] and dst and not dst.isPlayer then
      src.interrupts = src.interrupts + 1
    end
  end

  if dst then
    dst.taken = dst.taken + amount
    local row = abilityRow(dst.takenAbility, spellId, spellName)
    row.amount = row.amount + amount
    row.hits = row.hits + 1
    -- What school is actually hurting you is the whole point of this table.
    if row.school == nil then row.school = info.school end
    noteAmount(row, amount, info.crit)

    if dst.isPlayer or dst.class == "PET" then
      enc.totals.taken = enc.totals.taken + amount
      b.dt = b.dt + amount
      -- Recorded from the victim's side: the source is whatever hit them,
      -- which is how the readout can say who was attacking whom.
      contribute(b, "t", sourceGuid, targetGuid, spellId, amount)
      -- Remember the hit itself, so a death can be explained afterwards.
      local su = W.capture.units[sourceGuid]
      noteRecent(dst, enc, now, (su and su.name) or "?", spellName, amount)
    end

    -- Track the biggest thing we fought so the encounter can be named.
    local e = enc.enemies[targetGuid]
    if e then
      local u = W.capture:Unit(targetGuid)
      if u and u.maxHealth and u.maxHealth > (e.maxHealth or 0) then
        e.maxHealth = u.maxHealth
      end
    end
  end
end

-- Guards against SPELL_HEAL_ON_SELF duplicating SPELL_HEAL_BY_SELF when you
-- heal yourself: the same caster/target/spell/amount inside one frame is a
-- restatement of one heal, never two.
local lastHealKey, lastHealAt = nil, 0

function E:Heal(casterGuid, targetGuid, spellId, effective, over, info)
  if not self.live then self:CombatStart() end
  local enc = self.live
  if not enc then return end
  info = info or {}

  local now = GetTime()
  local key = tostring(casterGuid) .. tostring(targetGuid) .. tostring(spellId)
      .. tostring(effective) .. tostring(over)
  if key == lastHealKey and (now - lastHealAt) < 0.05 then return end
  lastHealKey, lastHealAt = key, now

  local src = self:Actor(casterGuid)
  if not src then return end

  src.healing = src.healing + effective
  src.overheal = src.overheal + over
  if info.crit then src.crits = src.crits + 1 end

  local spellName = W.capture:Spell(spellId)
  local row = abilityRow(src.healAbility, spellId, spellName)
  row.amount = row.amount + effective
  row.over = row.over + over
  row.hits = row.hits + 1
  if info.crit then row.crits = row.crits + 1 end
  noteAmount(row, effective + over, info.crit)

  if src.isPlayer or src.class == "PET" then
    noteActive(src, enc, now)
    enc.totals.healing = enc.totals.healing + effective
    enc.totals.overheal = enc.totals.overheal + over
    local b = bucketFor(enc, now)
    b.hl = b.hl + effective + over
    b.eh = b.eh + effective
    contribute(b, "h", casterGuid, targetGuid, spellId, effective)
  end
end

--[[ missInfo is the client's numeric reason, not a string:

       0 none   1 miss    2 RESIST   3 dodge   4 parry   5 block
       6 evade  7 immune  8 immune   9 deflect 10 absorb 11 reflect

     Code 2 is a FULL resist -- the spell was resisted outright and did no
     damage. It is a completely different thing from a partial resist, which
     lands and is recorded on the damage path, and lumping them together as
     "misses" hides both: a caster cannot tell bad luck on hit chance from
     being under-geared against a school. ]]
function E:Miss(casterGuid, targetGuid, spellId, missInfo)
  if not self.live then return end
  local src = self:Actor(casterGuid)
  if not src then return end
  src.misses = src.misses + 1
  local row = abilityRow(src.dmgAbility, spellId, W.capture:Spell(spellId))
  row.misses = row.misses + 1

  local code = tonumber(missInfo) or 0
  if not row.missBy then row.missBy = {} end
  row.missBy[code] = (row.missBy[code] or 0) + 1
end

function E:Dispel(casterGuid, targetGuid, spellId)
  if not self.live then return end
  local src = self:Actor(casterGuid)
  if src then src.dispels = src.dispels + 1 end
end

function E:Environmental(guid, damageType, damage, absorb, resist)
  if not self.live then self:CombatStart() end
  local dst = self:Actor(guid)
  if not dst then return end
  local enc = self.live

  dst.taken = dst.taken + damage
  local label = "Environment (" .. tostring(damageType or "?") .. ")"
  local row = abilityRow(dst.takenAbility, -1, label)
  row.amount = row.amount + damage
  row.hits = row.hits + 1

  if dst.isPlayer or dst.class == "PET" then
    enc.totals.taken = enc.totals.taken + damage
    bucketFor(enc, GetTime()).dt = bucketFor(enc, GetTime()).dt + damage
  end
end

--- Someone used a potion, elixir, flask, scroll, bandage or food.
--- Counted per item rather than lumped together, because "who is parsing on
--- consumables" is really "what did they burn" -- five Invulnerability
--- Potions and five Mana Potions are not the same story.
function E:Consumable(guid, itemId, spellId)
  if not self.live then return end
  local a = self:Actor(guid)
  if not a then return end

  a.consumes = a.consumes + 1

  local name = W.capture:Item(itemId, spellId) or ("Item " .. tostring(itemId))
  local row = abilityRow(a.consumeItem, itemId, name)
  row.amount = row.amount + 1
  row.hits = row.hits + 1
  -- A better name may arrive once the client caches the item.
  row.name = name
end

-- An aura went on or came off. Intervals, not edges: the edges are what
-- arrives, but "how long was the flask up" is the question anyone actually
-- asks, and keeping every edge would be a per-second cost for a
-- once-per-encounter answer.
--
-- Re-applying something already up is NOT counted as a second application
-- here, because the client sends an add without a matching remove when a
-- buff is refreshed; counting it would inflate the count and, worse, reset
-- the interval and lose the uptime accrued so far.
function E:Aura(guid, spellId, gained)
  local enc = self.live
  if not enc then return end
  if W.db and W.db.trackAuras == false then return end

  local a = self:Actor(guid)
  if not a then return end
  if not a.auras then a.auras = {} end

  local row = a.auras[spellId]
  if not row then
    row = { id = spellId, name = W.capture:Spell(spellId), up = 0,
            since = nil, applied = 0 }
    a.auras[spellId] = row
  end

  local now = GetTime()
  if gained then
    if not row.since then
      row.since = now
      row.applied = row.applied + 1
    end
  else
    if row.since then
      row.up = row.up + (now - row.since)
      row.since = nil
    end
  end
end

--- Close every aura still running, so uptime is not lost at the end of a
--- fight just because nothing removed it.
function E:CloseAuras(enc)
  local stop = enc.stopT or GetTime()
  for _, a in pairs(enc.actors or {}) do
    for _, row in pairs(a.auras or {}) do
      if row.since then
        row.up = row.up + (stop - row.since)
        row.since = nil
      end
    end
  end
end

function E:Death(guid)
  local enc = self.live
  if not enc then return end
  local a = self:Actor(guid)
  if not a then return end

  a.deaths = a.deaths + 1
  if a.isPlayer then
    --[[ Snapshot what killed them WHILE it is still known.

         The ring keeps being overwritten as the fight goes on, so reading
         it later would describe whatever happened next rather than what
         happened last. Copied, not referenced, for the same reason. ]]
    local recap = {}
    for _, e in ipairs(recentInOrder(a)) do
      table.insert(recap, { t = e.t, src = e.src, spell = e.spell,
                            a = e.a, hp = e.hp })
    end

    table.insert(enc.deaths, {
      t = GetTime() - enc.startT,
      guid = guid,
      name = a.name,
      class = a.class,
      recap = recap,
    })
  else
    -- An enemy dying is how we learn the pull was a kill.
    local e = enc.enemies[guid]
    if e then e.dead = true end
  end
end

----------------------------------------------------------------------
-- segmentation
----------------------------------------------------------------------

--- Open-world combat is mostly questing and world PvP, which would bury the
--- raid history under hundreds of six-second pulls. Off by default.
function E:ShouldRecord()
  if W.db and W.db.trackOpenWorld then return true end
  if not IsInInstance then return true end
  local inInstance, kind = IsInInstance()
  return inInstance and kind ~= "pvp"
end

--[[ Elapsed and combat time for an encounter, live or finished.

     Both are only stamped onto the record when combat ends -- `combat`
     accumulates in CombatEnd, `stopT` moves there too. Reading those fields
     directly on a pull that is still running therefore yields zero, which
     silently turns every per-second metric into 0/0. The live window has to
     extrapolate from the clock instead, so the meter ticks up as you fight
     rather than sitting at zero until the pull ends. ]]

function E:Elapsed(enc)
  if not enc then return 0 end
  if enc.duration then return enc.duration end
  return GetTime() - (enc.startT or GetTime())
end

--- Is the player genuinely in combat right now?
--- `inCombat` is our own flag, set on PLAYER_REGEN_DISABLED. If that event's
--- partner is ever missed -- it can be, around zoning, death and reconnects --
--- the flag sticks. Ask the client instead wherever the answer matters.
function E:ReallyInCombat()
  if UnitAffectingCombat then
    return UnitAffectingCombat("player") and true or false
  end
  return self.inCombat
end

function E:CombatTime(enc)
  if not enc then return 0 end
  local c = enc.combat or 0

  --[[ Add the segment in progress, which has not been banked yet -- but only
       while combat is actually happening. Trusting the flag alone meant a
       missed REGEN_ENABLED left this extrapolating from combatMark forever,
       so the meter sat in a city counting combat time upward. ]]
  if self.live == enc and self.inCombat and self.combatMark
      and self:ReallyInCombat() then
    c = c + (GetTime() - self.combatMark)
  end
  return c
end

--- Close a combat segment the client says has ended but we never saw end.
--- Called from the capture ticker; cheap, and it stops a stuck flag from
--- inflating every per-second figure for the rest of the session.
function E:HealStuckCombat()
  if not self.inCombat then return end
  if self:ReallyInCombat() then return end
  W.Debug("combat flag was stuck; closing the segment")
  self:CombatEnd()
end

function E:CombatStart()
  if not self:ShouldRecord() then
    -- Say so once per zone. Silently recording nothing is the single most
    -- confusing way for this addon to behave.
    local zone = GetRealZoneText() or "?"
    if self.warnedZone ~= zone then
      self.warnedZone = zone
      W.Print("not recording here - open-world combat is off. " ..
        "|cffe0a22c/wrek world|r to enable it, |cffe0a22c/wrek status|r for details.")
    end
    return
  end

  local now = GetTime()
  local zone, instanceType, instanceId = self:Where()

  --[[ Re-resolve when the zone changes, but NOT when we are merely back in
       the same lockout -- stepping out to the graveyard and back is one
       raid, and re-resolving on the way in is what used to split it. ]]
  local sameLockout = instanceId > 0 and self.session
      and (self.session.instanceId or 0) == instanceId

  if not self.session or (self.session.zone ~= zone and not sameLockout) then
    self.session = self:ResumeOrNew(zone, now, instanceType, instanceId)
  end

  -- Resume the previous encounter if we only briefly dropped combat.
  if self.live and self.lastCombatEnd and (now - self.lastCombatEnd) <= MERGE_GAP then
    self.inCombat = true
    self.combatMark = now
    return
  end

  if self.live then self:Finish() end

  self.live = newEncounter(self.session, now)
  self.inCombat = true
  self.combatMark = now
end

function E:CombatEnd()
  if not self.inCombat then return end
  local now = GetTime()
  self.inCombat = false
  self.lastCombatEnd = now
  if self.live then
    self.live.stopT = now
    self.live.combat = self.live.combat + (now - (self.combatMark or now))
  end
  -- Hold the encounter open for MERGE_GAP in case the next wave lands.
  W.ScheduleFinish(MERGE_GAP + 0.5)
end

--- Name the encounter after the beefiest enemy present, which is what makes
--- a boss pull read as "Onyxia" and trash read as "Onyxian Warder".
local function deriveName(enc)
  local best, bestHP, bestDmg = nil, -1, -1
  local anyDead = false
  for _, e in pairs(enc.enemies) do
    if e.dead then anyDead = true end
    local hp = e.maxHealth or 0
    local dmg = e.taken or 0
    if hp > bestHP or (hp == bestHP and dmg > bestDmg) then
      best, bestHP, bestDmg = e, hp, dmg
    end
  end
  return (best and best.name) or "Trash", anyDead, best
end

--[[ Was this a boss pull?

     Asked of the biggest thing in the fight -- the same enemy the encounter
     is named after, so the answer always agrees with the name on the row.

     The client's own classification is trusted first, because it is the only
     source that actually knows. Health is the fallback, and it is a fallback
     rather than the rule for a reason: no single number separates a raid boss
     from a dungeon boss from a beefy trash pack across all content, so the
     threshold is a setting and the answer is always correctable by hand.

     A wrong guess here is visible -- the row is marked in the sidebar -- and
     one click fixes it. That is the whole design: guess, show the guess, and
     make it cheap to overrule. ]]
local function looksLikeBoss(primary)
  if not primary then return false end

  --[[ Asked of the unit cache as well as the actor, because an actor copies
       its metadata the first time it is seen -- which is the instant the
       fight starts, when the client may not have resolved the thing yet.
       Whatever the actor recorded then is frozen; the cache has had the
       whole pull to catch up, and this runs at the end of it. ]]
  local u = primary.guid and W.capture:Unit(primary.guid)
  local rank = (u and u.rank) or primary.rank
  if rank == "worldboss" then return true end

  local hp = primary.maxHealth or 0
  local cached = (u and u.maxHealth) or 0
  if cached > hp then hp = cached end

  local floor = (W.db and W.db.bossHealth) or 40000
  return hp >= floor
end

--- Mark or unmark a pull by hand. Sticks: an override is never re-guessed.
function W.SetBoss(enc, isBoss)
  if not enc then return false end
  enc.boss = isBoss and true or false
  enc.bossBy = "you"
  --[[ History is a separate copy, so changing the live encounter alone would
       last until the next reload and then quietly revert. ]]
  for _, rec in ipairs((W.db and W.db.encounters) or {}) do
    if rec.id == enc.id and rec.sessionId == enc.sessionId then
      rec.boss = enc.boss
      rec.bossBy = "you"
    end
  end
  return enc.boss
end

function W.IsBoss(enc)
  return enc and enc.boss == true
end

function E:Finish()
  local enc = self.live
  self.live = nil
  if not enc then return end

  if self.inCombat then
    enc.combat = enc.combat + (GetTime() - (self.combatMark or GetTime()))
    self.inCombat = false
  end
  enc.duration = enc.stopT - enc.startT
  if enc.duration < (W.db and W.db.minTrashDuration or 6) then
    W.Debug("dropped a " .. string.format("%.1f", enc.duration) .. "s combat")
    W.capture:TrimUnits()
    return
  end

  -- Anything still up when the pull ended was up until the pull ended.
  -- Without this, a flask that was never removed reads as zero uptime --
  -- the exact opposite of the truth.
  self:CloseAuras(enc)

  local name, anyDead, primary = deriveName(enc)
  enc.name = name
  enc.kill = anyDead
  --[[ Decided here, at the end of the pull, and then left alone. Judging it
       later would mean re-judging it every time the report is drawn, and a
       pull that changed its mind about being a boss between two refreshes
       would be worse than one that guessed wrong once. ]]
  enc.boss = looksLikeBoss(primary)
  enc.bossBy = "guess"

  local session = self.session
  enc.id = session.nextId
  session.nextId = session.nextId + 1
  table.insert(session.encounters, enc)

  self:Persist(enc)
  self:RememberSession(session, enc)

  --[[ Append to the on-disk journal immediately.

       This is the part that actually survives a crash. SavedVariables are
       only written at a clean logout, so a client crash loses the entire
       night's recording no matter how carefully it was aggregated. Nampower's
       file API writes now, so each encounter is on disk the moment it ends
       and "/wrek load" can recover the night. ]]
  if W.db.autoSave and W.store and W.store:Available() then
    W.Guard("autosave", function() W.store:AppendEncounter(enc, session) end)
  end

  W.capture:TrimUnits()

  W.Debug(string.format("encounter %s  %s  %s dmg",
    enc.name, W.Duration(enc.duration), W.Short(enc.totals.damage)))

  if W.ui and W.ui.OnEncounterFinished then W.ui:OnEncounterFinished(enc) end
end

----------------------------------------------------------------------
-- persistence
----------------------------------------------------------------------

--[[ SavedVariables are written as Lua source at logout, so everything stored
     here is paid for twice: once in write time, once in load time. Persist
     the rollups and the timeline, cap ability rows per actor, and drop the
     per-ability detail for trash mobs -- which is 90% of the rows and the
     part nobody reads. ]]

-- Auras worth storing: anything that was actually up. Sorted by uptime so
-- a capped list keeps what mattered rather than whatever hashed first.
local function topAuras(tbl, limit)
  local rows = {}
  for id, r in pairs(tbl or {}) do
    if (r.up or 0) > 0.5 then
      table.insert(rows, { id = id, name = r.name, up = r.up,
                           applied = r.applied })
    end
  end
  table.sort(rows, function(x, y) return (x.up or 0) > (y.up or 0) end)
  while table.getn(rows) > (limit or 24) do table.remove(rows) end
  return rows
end

local function topAbilities(tbl, limit)
  local rows = {}
  for id, r in pairs(tbl) do
    table.insert(rows, { id = id, name = r.name, amount = r.amount, over = r.over,
                         hits = r.hits, crits = r.crits, misses = r.misses,
                         max = r.max, min = r.min, critAmount = r.critAmount,
                         resisted = r.resisted, resistHits = r.resistHits,
                         r25 = r.r25, r50 = r.r50, r75 = r.r75,
                         missBy = r.missBy, school = r.school })
  end
  table.sort(rows, W.ByField("amount"))
  while table.getn(rows) > limit do table.remove(rows) end
  return rows
end

function E:Persist(enc)
  if not W.db then return end
  local limit = W.db.maxAbilities or 24

  local rec = {
    id = enc.id,
    sessionId = enc.sessionId,
    name = enc.name,
    zone = enc.zone,
    -- Kept per encounter so a session can be rebuilt from history alone,
    -- which is the only path left after a crash eats SavedVariables.
    instanceId = enc.instanceId or 0,
    startTime = enc.startTime,
    offset = enc.offset,
    duration = enc.duration,
    combat = enc.combat,
    kill = enc.kill,
    -- The report reads sessions back out of history, so a flag that only
    -- exists on the live encounter is a flag the report never sees.
    boss = enc.boss,
    bossBy = enc.bossBy,
    totals = enc.totals,
    deaths = enc.deaths,
    actors = {},
    bucket = {},
    maxBucket = enc.maxBucket,
  }

  --[[ Persist the four totals, plus the largest few contributions behind
       them. Sorting happens HERE, once per encounter, rather than on every
       event -- the ordering is only needed at the point of storage.

       Names are resolved now rather than stored as guids. A guid is
       meaningless after a relog, and the actor it pointed at may not be in
       the encounter at all (the mob that hit you is not in the damage-done
       table), so keeping the guid would leave the readout unable to say who
       anything was. ]]
  --[[ Detail is capped per ENCOUNTER as well as per second.

       Four rows every second sounds small until it is a five-minute boss:
       1200 rows, about 100KB of SavedVariables, for one pull. SavedVariables
       are rewritten whole at logout and parsed whole at login, so that is
       paid twice a session.

       So keep the busiest seconds and drop the quiet ones. A quiet second is
       not what anyone clicks -- the question is always about a spike, or
       about the moment somebody died. ]]
  local detailSeconds = {}
  do
    local ranked = {}
    for i = 0, enc.maxBucket do
      local b = enc.bucket[i]
      if b and b.top then
        table.insert(ranked, { i = i, v = (b.dd or 0) + (b.dt or 0) + (b.hl or 0) })
      end
    end
    table.sort(ranked, function(x, y) return x.v > y.v end)

    -- Deaths are always worth explaining, however quiet the second was.
    for _, d in ipairs(enc.deaths or {}) do
      detailSeconds[math.floor(d.t or 0)] = true
    end

    local budget = (W.db and W.db.timelineDetailSeconds) or 60
    for k = 1, budget do
      local r = ranked[k]
      if not r then break end
      detailSeconds[r.i] = true
    end
  end

  rec.top = {}
  for i = 0, enc.maxBucket do
    local b = enc.bucket[i]
    if b then
      rec.bucket[i] = { b.dd, b.dt, b.hl, b.eh }

      if b.top and detailSeconds[i] then
        local rows = {}
        for _, r in pairs(b.top) do table.insert(rows, r) end
        table.sort(rows, function(x, y) return (x.a or 0) > (y.a or 0) end)

        local kept = {}
        for k = 1, TOP_KEPT do
          local r = rows[k]
          if not r then break end
          local su = W.capture.units[r.s]
          local tu = r.t and W.capture.units[r.t]
          table.insert(kept, {
            k = r.k,
            src = (su and su.name) or "?",
            dst = (tu and tu.name) or nil,
            spell = W.capture:Spell(r.id),
            a = r.a,
            n = r.n,
          })
        end
        if table.getn(kept) > 0 then rec.top[i] = kept end
      end
    end
  end

  for guid, a in pairs(enc.actors) do
    --[[ Enemies keep their detail too, which they did not used to.

         Dropping it made "what is this thing hitting us with, and with what
         school" unanswerable the moment a pull ended: the totals survived and
         the abilities behind them did not, so the enemy drilldown was empty
         for every fight except the one still in progress. That is the half
         you actually want to read afterwards.

         topAbilities already caps each actor at maxAbilities, and a mob
         typically has two or three attacks, so the cost is a handful of rows
         per mob rather than another copy of the raid. ]]
    local keepDetail = true
    rec.actors[guid] = {
      name = a.name, class = a.class, isPlayer = a.isPlayer,
      owner = a.owner, ownerName = a.ownerName,
      damage = a.damage, taken = a.taken, healing = a.healing,
      overheal = a.overheal, absorbed = a.absorbed, deaths = a.deaths,
      dispels = a.dispels, interrupts = a.interrupts,
      hits = a.hits, crits = a.crits, misses = a.misses,
      consumes = a.consumes,
      active = a.active,
      -- Uptime as an array, same shape as the ability tables: the live one
      -- is keyed by spell id, the stored one is a list.
      auras = topAuras(a.auras),
      dmgAbility = keepDetail and topAbilities(a.dmgAbility, limit) or nil,
      healAbility = keepDetail and topAbilities(a.healAbility, limit) or nil,
      takenAbility = keepDetail and topAbilities(a.takenAbility, limit) or nil,
      consumeItem = keepDetail and topAbilities(a.consumeItem, limit) or nil,
    }
  end

  table.insert(W.db.encounters, rec)

  --[[ Ring buffer, but locked encounters are never the ones evicted.

       Dropping the oldest outright would quietly delete the pull someone
       deliberately kept. Instead find the oldest UNLOCKED one; if every
       stored encounter is locked there is nothing to give up, so the buffer
       is allowed to exceed its cap rather than break the promise the lock
       makes. ]]
  local maxKeep = W.db.maxEncounters or 60
  local evicted = 0
  while table.getn(W.db.encounters) > maxKeep do
    local victim = nil
    for i = 1, table.getn(W.db.encounters) do
      if not W.db.encounters[i].locked then victim = i break end
    end
    if not victim then break end
    table.remove(W.db.encounters, victim)
    evicted = evicted + 1
  end

  --[[ Say so the first time the buffer starts eating history.

       Silently dropping the oldest pull is the correct behaviour for a ring
       buffer and the wrong behaviour for a log: someone who has been
       raiding all week has no way to know their Tuesday is being deleted to
       make room for Thursday. Said ONCE per session, because the buffer
       evicts on every pull once it is full and a message each time would be
       nagging rather than informing. ]]
  if evicted > 0 and not self.warnedEviction then
    self.warnedEviction = true
    W.Print(string.format(
      "history is full at %d pulls, so the oldest are being dropped.", maxKeep))
    W.Print("raise it in settings, or lock the ones worth keeping.")
  end
end

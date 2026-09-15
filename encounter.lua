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

    damage = 0, taken = 0, healing = 0, overheal = 0,
    absorbed = 0, deaths = 0, dispels = 0, interrupts = 0,
    hits = 0, crits = 0, misses = 0, consumes = 0,

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

local function newSession(now, zone)
  return {
    id = time(),
    zone = zone or GetRealZoneText() or "Unknown",
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
function E:ResumeOrNew(zone, now)
  local window = (W.db and W.db.resumeWindow) or 1200
  local saved = W.db and W.db.session

  if not (saved and saved.id and saved.startTime) then
    saved = self:SessionFromHistory()
  end

  --[[ A manual reset draws a line: everything on the far side of it is a
       closed book, however recent it is. Without this the resume logic would
       cheerfully rejoin the exact session the user just asked to leave --
       the two features would cancel each other out. ]]
  local barrier = (W.db and W.db.sessionBarrier) or 0

  if saved and saved.zone == zone and saved.id and saved.startTime
      and (saved.lastActivity or 0) > barrier then
    local idle = time() - (saved.lastActivity or 0)
    if idle >= 0 and idle <= window then
      W.Print(string.format("continuing the session from %s ago.",
        W.Duration(idle)))
      return {
        id = saved.id,
        zone = zone,
        startTime = saved.startTime,
        startT = now,
        nextId = saved.nextId or 1,
        encounters = {},
        resumed = true,
      }
    end
  end

  return newSession(now, zone)
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
    -- Late-resolving names: a mob seen before it was in range starts as "?"
    if a.name == "?" or a.class == "UNKNOWN" then
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
            max = 0, min = nil, critAmount = 0 }
    tbl[spellId] = row
  end
  return row
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

    local row = abilityRow(src.dmgAbility, spellId, spellName)
    row.amount = row.amount + amount
    row.hits = row.hits + 1
    if info.crit then row.crits = row.crits + 1 end
    noteAmount(row, amount, info.crit)

    if src.isPlayer or src.class == "PET" then
      enc.totals.damage = enc.totals.damage + amount
      b.dd = b.dd + amount
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
    noteAmount(row, amount, info.crit)

    if dst.isPlayer or dst.class == "PET" then
      enc.totals.taken = enc.totals.taken + amount
      b.dt = b.dt + amount
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
    enc.totals.healing = enc.totals.healing + effective
    enc.totals.overheal = enc.totals.overheal + over
    local b = bucketFor(enc, now)
    b.hl = b.hl + effective + over
    b.eh = b.eh + effective
  end
end

function E:Miss(casterGuid, targetGuid, spellId, missInfo)
  if not self.live then return end
  local src = self:Actor(casterGuid)
  if not src then return end
  src.misses = src.misses + 1
  local row = abilityRow(src.dmgAbility, spellId, W.capture:Spell(spellId))
  row.misses = row.misses + 1
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

function E:Death(guid)
  local enc = self.live
  if not enc then return end
  local a = self:Actor(guid)
  if not a then return end

  a.deaths = a.deaths + 1
  if a.isPlayer then
    table.insert(enc.deaths, {
      t = GetTime() - enc.startT,
      guid = guid,
      name = a.name,
      class = a.class,
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
  local zone = GetRealZoneText() or "Unknown"

  if not self.session or self.session.zone ~= zone then
    self.session = self:ResumeOrNew(zone, now)
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
  return (best and best.name) or "Trash", anyDead
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

  local name, anyDead = deriveName(enc)
  enc.name = name
  enc.kill = anyDead

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

local function topAbilities(tbl, limit)
  local rows = {}
  for id, r in pairs(tbl) do
    table.insert(rows, { id = id, name = r.name, amount = r.amount, over = r.over,
                         hits = r.hits, crits = r.crits, misses = r.misses,
                         max = r.max, min = r.min, critAmount = r.critAmount })
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
    startTime = enc.startTime,
    offset = enc.offset,
    duration = enc.duration,
    combat = enc.combat,
    kill = enc.kill,
    totals = enc.totals,
    deaths = enc.deaths,
    actors = {},
    bucket = {},
    maxBucket = enc.maxBucket,
  }

  for i = 0, enc.maxBucket do
    local b = enc.bucket[i]
    if b then rec.bucket[i] = { b.dd, b.dt, b.hl, b.eh } end
  end

  for guid, a in pairs(enc.actors) do
    local keepDetail = a.isPlayer or a.class == "PET"
    rec.actors[guid] = {
      name = a.name, class = a.class, isPlayer = a.isPlayer,
      owner = a.owner, ownerName = a.ownerName,
      damage = a.damage, taken = a.taken, healing = a.healing,
      overheal = a.overheal, absorbed = a.absorbed, deaths = a.deaths,
      dispels = a.dispels, interrupts = a.interrupts,
      hits = a.hits, crits = a.crits, misses = a.misses,
      consumes = a.consumes,
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
  while table.getn(W.db.encounters) > maxKeep do
    local victim = nil
    for i = 1, table.getn(W.db.encounters) do
      if not W.db.encounters[i].locked then victim = i break end
    end
    if not victim then break end
    table.remove(W.db.encounters, victim)
  end
end

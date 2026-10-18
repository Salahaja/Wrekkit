--[[ Wrekkit :: raidvalue

"Raid value": what the buffs and debuffs a player provides add to everyone
else's damage -- the paladin's Sanctity Aura, the warlocks' curses, the
Nightfall wielder's procs -- so a comp, a gear choice or a group shuffle can
be weighed in damage rather than argued about. "Raid support" is the same
for what comes back as mana or health: Judgement of Wisdom and of Light.

Off unless switched on (W.db.raidValue): it watches every spell hit.

ONLY WHAT IS EXACT. Most effects here make damage of some schools (1 +
bonus) times bigger while they are up, so a share of a hit is hit x bonus /
(1 + bonus). Several on one hit multiply; their joint extra is split between
them by the size of each one's own multiplier (log(1 + bonus)). Judgement
of the Crusader adds a flat amount instead. Damage shields are whole damage,
credited to whoever provides them. Stat buffs and armour reduction are not
here: their worth can only be estimated.

CHECKED PER UNIT, AT EACH HIT -- never assumed raid-wide:
  on the target   that mob's own debuffs (DEBUFF_ADDED/REMOVED_OTHER), and
                  only the ones this file values, so a raid's worth of
                  mobs costs a few entries; dropped when the mob dies
  on the attacker that player's own buffs (W.capture.buffs, the uptime
                  tracking), so Sanctity only counts for the paladin's
                  party and only while they have it

WHO IS CREDITED -- the provider, never the hitter:
  aura        whoever cast it (AURA_CAST_ON_OTHER, NP_EnableAuraCastEvents)
  buffcaster  the same, for a buff on a player: Power Infusion, Thorns
  judgement   the paladin whose Judgement just landed on that mob
  shadowcrit  Improved Shadow Bolt: the warlock whose Shadow Bolt just crit
              that mob
  lasthit     Shadow Weaving, Fire Vulnerability: the priest's shadow spell
              or the mage's fire spell that just hit that mob
  melee       Nightfall: a melee proc. The hitters on that mob just before
              each proc are noted; the wielder is the one who is there every
              time, so the one seen most often among them is credited
  party       Sanctity and Retribution Aura: the paladin in the attacker's
              own group (raid subgroup, or the party) who has it up

Checked against the Chronicle logs of 10/10 and 10/17 by an offline script
(chronicle2wcl/debuffvalue.py) before it was built: e.g. Curse of Shadow
+4.6% of the raid's spell damage on 10/10 Molten Core. ]]

local W = Wrekkit
W.value = {}
local V = W.value

local HOLY, FIRE, NATURE, FROST, SHADOW, ARCANE = 1, 2, 3, 4, 5, 6
local SPELLS = { [HOLY] = true, [FIRE] = true, [NATURE] = true, [FROST] = true,
                 [SHADOW] = true, [ARCANE] = true }
local HOLY_ONLY = { [HOLY] = true }
local NONE = {}

--[[ spellId -> { name, on, schools, credit, and one of:
       bonus      (1 + bonus) times the damage
       perStack   (1 + perStack x stacks) times: Shadow Weaving, Fire Vulnerability
       flat       that much more damage per hit: Judgement of the Crusader
       support    "mana" or "heal": the debuff gives hitters something back,
                  valued by what the restore events carry (V:Restore) }
     The figures are the client's own (Spell.dbc base points + 1). ]]
V.EFFECTS = {
  [20218] = { name = "Sanctity Aura", on = "attacker", bonus = 0.10, schools = HOLY_ONLY, credit = "party" },
  [10060] = { name = "Power Infusion", on = "attacker", bonus = 0.20, schools = SPELLS, credit = "buffcaster" },
  [23605] = { name = "Spell Vulnerability (Nightfall)", on = "target", bonus = 0.10, schools = SPELLS, credit = "melee" },
  [17794] = { name = "Shadow Vulnerability", on = "target", bonus = 0.20, schools = { [SHADOW] = true }, credit = "shadowcrit" },
  [15258] = { name = "Shadow Weaving", on = "target", perStack = 0.03, schools = { [SHADOW] = true },
              credit = "lasthit", class = "PRIEST", school = SHADOW },
  [22959] = { name = "Fire Vulnerability", on = "target", perStack = 0.03, schools = { [FIRE] = true },
              credit = "lasthit", class = "MAGE", school = FIRE },
  [1490]  = { name = "Curse of the Elements", on = "target", bonus = 0.06, schools = { [FIRE] = true, [FROST] = true }, credit = "aura" },
  [11721] = { name = "Curse of the Elements", on = "target", bonus = 0.08, schools = { [FIRE] = true, [FROST] = true }, credit = "aura" },
  [11722] = { name = "Curse of the Elements", on = "target", bonus = 0.10, schools = { [FIRE] = true, [FROST] = true }, credit = "aura" },
  [17862] = { name = "Curse of Shadow", on = "target", bonus = 0.08, schools = { [SHADOW] = true, [ARCANE] = true }, credit = "aura" },
  [17937] = { name = "Curse of Shadow", on = "target", bonus = 0.10, schools = { [SHADOW] = true, [ARCANE] = true }, credit = "aura" },
}

-- The paladin's judgements: the debuff is put on by the Judgement cast.
local JOTC = { [21183] = 20, [20188] = 30, [20300] = 50, [20301] = 80, [20302] = 110, [20303] = 140 }
for id, flat in pairs(JOTC) do
  V.EFFECTS[id] = { name = "Judgement of the Crusader", on = "target", flat = flat, schools = HOLY_ONLY, credit = "judgement" }
end
for _, id in ipairs({ 20186, 20354, 20355, 51751, 51752 }) do
  V.EFFECTS[id] = { name = "Judgement of Wisdom", on = "target", support = "mana", schools = NONE, credit = "judgement" }
end
for _, id in ipairs({ 20185, 20344, 20345, 20346 }) do
  V.EFFECTS[id] = { name = "Judgement of Light", on = "target", support = "heal", schools = NONE, credit = "judgement" }
end

--[[ Damage shields: Retribution Aura and Thorns hurt whatever hits the
     player wearing them, and the combat log calls that the WEARER's damage.
     It is the provider's: the paladin whose aura it is (in the wearer's
     group), the druid who cast the Thorns. Credited whole, and only when
     worn by someone else -- on the provider it is already their damage.
     DAMAGE_SHIELD names no spell, so the school says which shield it was. ]]
V.SHIELDS = {
  [HOLY] = { name = "Retribution Aura", credit = "party",
             ids = { 7294, 10298, 10299, 10300, 10301, 19998 } },
  [NATURE] = { name = "Thorns", credit = "buffcaster",
               ids = { 467, 782, 1075, 8914, 9756, 9910 } },
}
V.shieldIds = {}
for _, s in pairs(V.SHIELDS) do
  for _, id in ipairs(s.ids) do V.shieldIds[id] = true end
end

local CAST_WINDOW = 2.0     -- an aura or Judgement cast this recent put this debuff on
local CRIT_WINDOW = 1.5     -- a crit or hit this recent gave its debuff (ISB, Weaving, Scorch)
local MELEE_WINDOW = 0.5    -- hitters this recent are candidates for a melee proc
local TARGET_WINDOW = 2.0   -- a restore this soon after a hit came from that mob's judgement

-- class .. school -> true: the hits "lasthit" effects are credited from.
local LASTHIT = {}
for _, e in pairs(V.EFFECTS) do
  if e.credit == "lasthit" then LASTHIT[e.class .. e.school] = true end
end

V.mob = {}            -- mob guid -> spellId -> { slots = {}, by = provider guid, stacks }
V.lastCast = {}       -- target guid -> spellId -> { by, at }
V.buffBy = {}         -- player guid -> spellId -> who cast that buff on them
V.lastShadowCrit = {} -- mob guid -> { by, at }
V.lastHit = {}        -- mob guid -> class .. school -> { by, at }
V.lastJudge = {}      -- mob guid -> { by, at }
V.lastTarget = {}     -- player guid -> { mob, at }: what they last hit
V.recentMelee = {}    -- mob guid -> { guid -> at }
V.procScore = {}      -- spellId -> provider guid -> times seen among the candidates
V.partyCache = {}     -- attacker guid -> { by, at }
V.lastRestore = {}    -- the last restore credited, to drop its duplicate

function V:Enabled()
  return W.db and W.db.raidValue == true
end

--- Switch the extra nampower events on when it is wanted.
function V:Apply()
  if self:Enabled() and SetCVar then pcall(SetCVar, "NP_EnableAuraCastEvents", 1) end
end

local function isPlayer(guid)
  local u = guid and (W.capture.units[guid] or W.capture:Unit(guid))
  return u and u.isPlayer and u or nil
end

local names = {}   -- spellId -> name, looked up once
local function spellName(id)
  local n = names[id]
  if n == nil then
    -- The capture's name carries the rank ("Shadow Bolt (Rank 10)").
    n = W.capture:Spell(id)
    n = n and (string.gsub(n, " %(.*%)$", "")) or false
    names[id] = n
  end
  return n
end

----------------------------------------------------------------------
-- debuffs on mobs, and who put them there
----------------------------------------------------------------------

--- An aura was cast: remembered for the debuff it is about to put on, and
--- for a buff (Power Infusion, Thorns), who it came from.
function V:AuraCast(spellId, caster, target)
  if not self:Enabled() or not target then return end
  local e = self.EFFECTS[spellId]
  if not e and not self.shieldIds[spellId] then return end
  if self.shieldIds[spellId] or e.on == "attacker" then
    local b = self.buffBy[target]
    if not b then
      b = {}
      self.buffBy[target] = b
    end
    b[spellId] = caster
    return
  end
  local t = self.lastCast[target]
  if not t then
    t = {}
    self.lastCast[target] = t
  end
  t[spellId] = { by = caster, at = GetTime() }
  -- Recast on a debuff already up (a curse refreshed): the new caster.
  local d = self.mob[target] and self.mob[target][spellId]
  if d then d.by = caster end
end

--- A cast went off: a Judgement is about to put its debuff on the target.
function V:SpellGo(spellId, caster, target)
  if not self:Enabled() or not target or spellName(spellId) ~= "Judgement" then return end
  self.lastJudge[target] = { by = caster, at = GetTime() }
end

function V:Provider(target, spellId, effect)
  local now = GetTime()
  if effect.credit == "aura" then
    local c = self.lastCast[target] and self.lastCast[target][spellId]
    if c and now - c.at <= CAST_WINDOW then return c.by end
  elseif effect.credit == "judgement" then
    local c = self.lastJudge[target]
    if c and now - c.at <= CAST_WINDOW then return c.by end
  elseif effect.credit == "shadowcrit" then
    local c = self.lastShadowCrit[target]
    if c and now - c.at <= CRIT_WINDOW then return c.by end
  elseif effect.credit == "lasthit" then
    local c = self.lastHit[target] and self.lastHit[target][effect.class .. effect.school]
    if c and now - c.at <= CRIT_WINDOW then return c.by end
  elseif effect.credit == "melee" then
    -- Everyone who just hit it is a candidate; the wielder is the one
    -- among them every time, so the most-seen candidate is credited.
    local score = self.procScore[spellId]
    if not score then
      score = {}
      self.procScore[spellId] = score
    end
    local best, bestScore, bestAt
    for guid, at in pairs(self.recentMelee[target] or {}) do
      if now - at <= MELEE_WINDOW then
        score[guid] = (score[guid] or 0) + 1
        local s = score[guid]
        if not best or s > bestScore or (s == bestScore and at > bestAt) then
          best, bestScore, bestAt = guid, s, at
        end
      end
    end
    return best
  end
  return nil
end

--- A debuff landed on a mob, or a stacking one changed its count.
function V:DebuffOn(guid, spellId, slot, stacks)
  if not self:Enabled() then return end
  local effect = self.EFFECTS[spellId]
  if not effect or effect.on ~= "target" then return end
  local set = self.mob[guid]
  if not set then
    set = {}
    self.mob[guid] = set
  end
  local d = set[spellId]
  if not d then
    d = { slots = {} }
    set[spellId] = d
  end
  d.slots[slot or "anon"] = true
  stacks = tonumber(stacks)
  if stacks and stacks > 0 then d.stacks = stacks end
  d.by = self:Provider(guid, spellId, effect) or d.by
end

function V:DebuffOff(guid, spellId, slot, state)
  local set = self.mob[guid]
  local d = set and set[spellId]
  if not d or tonumber(state) == 2 then return end
  if slot and d.slots[slot] then d.slots[slot] = nil else d.slots = {} end
  if next(d.slots) == nil then
    set[spellId] = nil
    if next(set) == nil then self.mob[guid] = nil end
  end
end

function V:Died(guid)
  self.mob[guid] = nil
  self.lastCast[guid] = nil
  self.lastShadowCrit[guid] = nil
  self.lastHit[guid] = nil
  self.lastJudge[guid] = nil
  self.recentMelee[guid] = nil
end

----------------------------------------------------------------------
-- the paladin's auras, and buffs cast on players
----------------------------------------------------------------------

--- The paladin in an attacker's own group with this aura up, or nil.
function V:PartyProvider(attacker, spellId)
  local now = GetTime()
  local c = self.partyCache[attacker]
  if c and c.spell == spellId and now - c.at < 5 then return c.by end
  local me = W.capture.units[attacker]
  local group = me and W.capture:Subgroup(me.name)
  local by
  for guid, buffs in pairs(W.capture.buffs) do
    local u = W.capture.units[guid]
    if buffs[spellId] and u and u.isPlayer and u.class == "PALADIN" then
      if guid == attacker or (group and W.capture:Subgroup(u.name) == group) then
        by = guid
        if guid == attacker then break end
      end
    end
  end
  self.partyCache[attacker] = { by = by, at = now, spell = spellId }
  return by
end

local function buffProvider(self, effect, guid, spellId)
  if effect.credit == "party" then return self:PartyProvider(guid, spellId) end
  return self.buffBy[guid] and self.buffBy[guid][spellId]
end

----------------------------------------------------------------------
-- the hits
----------------------------------------------------------------------

local function noteTarget(self, attacker, target)
  local t = self.lastTarget[attacker]
  if not t then
    t = {}
    self.lastTarget[attacker] = t
  end
  t.mob, t.at = target, GetTime()
end

--- A melee swing landed: a candidate for a melee proc on that mob.
function V:Swing(attacker, target)
  if not self:Enabled() or not isPlayer(attacker) then return end
  local r = self.recentMelee[target]
  if not r then
    r = {}
    self.recentMelee[target] = r
  end
  r[attacker] = GetTime()
  noteTarget(self, attacker, target)
end

local mults = {}        -- reused: { id, size = bonus, by } x n
local flats = {}        -- reused: { id, size = flat, by } x n

local function push(list, n, id, size, by)
  n = n + 1
  local m = list[n]
  if not m then
    m = {}
    list[n] = m
  end
  m.id, m.size, m.by = id, size, by
  return n
end

--- A spell hit: note what it says about procs, then credit what boosted it.
function V:SpellHit(caster, target, spellId, amount, school, crit)
  if not self:Enabled() or not caster or not target then return end
  local u = isPlayer(caster)
  if not u then return end
  school = tonumber(school) or 0
  if school == 0 then
    self:Swing(caster, target)     -- a melee ability: a proc candidate too
    return
  end
  noteTarget(self, caster, target)
  local now = GetTime()
  if crit and school == SHADOW and spellName(spellId) == "Shadow Bolt" then
    self.lastShadowCrit[target] = { by = caster, at = now }
  end
  local key = (u.class or "") .. school
  if LASTHIT[key] then
    local h = self.lastHit[target]
    if not h then
      h = {}
      self.lastHit[target] = h
    end
    h[key] = { by = caster, at = now }
  end
  if amount <= 0 then return end

  local n, nf = 0, 0
  local mobSet = self.mob[target]
  if mobSet then
    for id, d in pairs(mobSet) do
      local e = self.EFFECTS[id]
      if e and e.schools[school] then
        if e.flat then
          nf = push(flats, nf, id, e.flat, d.by)
        else
          n = push(mults, n, id, e.bonus or e.perStack * (d.stacks or 1), d.by)
        end
      end
    end
  end
  local buffs = W.capture.buffs[caster]
  if buffs then
    for id, e in pairs(self.EFFECTS) do
      if e.on == "attacker" and buffs[id] and e.schools[school] then
        n = push(mults, n, id, e.bonus, buffProvider(self, e, caster, id))
      end
    end
  end
  if n == 0 and nf == 0 then return end

  local product, logs = 1, 0
  for i = 1, n do
    product = product * (1 + mults[i].size)
    logs = logs + math.log(1 + mults[i].size)
  end
  local extra = amount - amount / product
  for i = 1, n do
    local m = mults[i]
    W.encounter:Value(m.by, m.id, self.EFFECTS[m.id].name, extra * math.log(1 + m.size) / logs, caster)
  end
  -- A flat bonus comes before the multipliers, and is no more than what the
  -- hit had left once they are taken out.
  local left = amount / product
  for i = 1, nf do
    local f = flats[i]
    local share = f.size < left and f.size or left
    left = left - share
    W.encounter:Value(f.by, f.id, self.EFFECTS[f.id].name, share, caster)
  end
end

--- A damage shield (Retribution Aura, Thorns) hurt an attacker.
function V:Shield(owner, damage, school)
  if not self:Enabled() or not owner or not damage or damage <= 0 then return end
  local s = self.SHIELDS[tonumber(school) or -1]
  local buffs = s and W.capture.buffs[owner]
  if not buffs then return end
  for _, id in ipairs(s.ids) do
    if buffs[id] then
      local by = buffProvider(self, s, owner, id)
      if by and by ~= owner then W.encounter:Value(by, id, s.name, damage, owner) end
      return
    end
  end
end

local RESTORE = { ["Judgement of Wisdom"] = "mana", ["Judgement of Light"] = "heal" }

--[[ A hitter got mana or health back from a judgement on what they hit. The
     restore names only the hitter, so the mob is the one they hit last; its
     judgement of that kind says which paladin it was. ]]
function V:Restore(target, spellId, amount, kind)
  if not self:Enabled() or not target or not amount or amount <= 0 then return end
  local name = spellName(spellId)
  if not name or RESTORE[name] ~= kind then return end
  local now = GetTime()
  -- Healing yourself raises both SPELL_HEAL_BY_SELF and _ON_SELF.
  local last = self.lastRestore
  if last.target == target and last.spell == spellId and last.amount == amount and last.at == now then return end
  last.target, last.spell, last.amount, last.at = target, spellId, amount, now
  local t = self.lastTarget[target]
  if not t or now - t.at > TARGET_WINDOW then return end
  for id, d in pairs(self.mob[t.mob] or {}) do
    if self.EFFECTS[id].support == kind then
      W.encounter:Support(d.by, id, name, amount, kind, target)
      return
    end
  end
end

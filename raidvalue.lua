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
              credit = "lasthit", class = "PRIEST", school = SHADOW, stacking = true },
  [22959] = { name = "Fire Vulnerability", on = "target", perStack = 0.03, schools = { [FIRE] = true },
              credit = "lasthit", class = "MAGE", school = FIRE, stacking = true },
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

--[[ PHYSICAL. Windfury and Expose Weakness are exact and always counted.
     The rest need a number the log never gives -- a mob's armor, a
     player's attack power or weapon -- so they are ESTIMATES, counted only
     with "Estimated effects" on (W.db.raidValueEstimates) and named
     "(est.)" wherever they show:
       armor     armor taken off per stack, from the mob's own armor:
                 read live, learned, or a raid boss's (V:MobArmor)
       ap        attack power added: AP / 14 x weapon speed per hit, the
                 speed read from that player's own swing gaps (a dual
                 wielder reads short, so it errs low), after armor
       rangedAp  the same, for ranged attacks only (Hunter's Mark)
       crit      crit chance added: that share of a non-crit's size
     Expose Armor's figure is its five-combo-point one. ]]
local PHYS = { [0] = true }
local function physical(ids, base)
  for id, v in pairs(ids) do
    local e = {}
    for k, x in pairs(base) do e[k] = x end
    e[base.field] = v
    e.field = nil
    e.schools = PHYS
    V.EFFECTS[id] = e
  end
end
physical({ [7386] = 90, [7405] = 180, [8380] = 270, [11596] = 360, [11597] = 450, [47383] = 600 },
  { field = "armor", name = "Sunder Armor", on = "target", credit = "aura", estimate = true, stacking = true })
physical({ [770] = 175, [778] = 285, [9749] = 395, [9907] = 505,
           [16857] = 175, [17390] = 285, [17391] = 395, [17392] = 505 },
  { field = "armor", name = "Faerie Fire", on = "target", credit = "aura", estimate = true })
physical({ [704] = 140, [7658] = 290, [7659] = 465, [11717] = 640 },
  { field = "armor", name = "Curse of Recklessness", on = "target", credit = "aura", estimate = true })
physical({ [8647] = 400, [8648] = 400, [8649] = 725, [8651] = 725, [8650] = 1050, [8652] = 1050,
           [11197] = 1375, [11199] = 1375, [11198] = 1700, [11200] = 1700 },
  { field = "armor", name = "Expose Armor", on = "target", credit = "aura", estimate = true })
physical({ [16928] = 100 },
  { field = "armor", name = "Annihilator", on = "target", credit = "melee", estimate = true, stacking = true })
physical({ [1130] = 20, [14323] = 45, [14324] = 75, [14325] = 110 },
  { field = "rangedAp", name = "Hunter's Mark", on = "target", credit = "aura", estimate = true })
physical({ [6673] = 15, [5242] = 35, [6192] = 55, [11549] = 85, [11550] = 130, [11551] = 185,
           [25289] = 232, [24438] = 200, [27578] = 185 },
  { field = "ap", name = "Battle Shout", on = "attacker", credit = "party", class = "WARRIOR", estimate = true })
physical({ [19740] = 20, [19834] = 35, [19835] = 55, [19836] = 85, [19837] = 115, [19838] = 155,
           [25291] = 185, [25782] = 155, [25916] = 185 },
  { field = "ap", name = "Blessing of Might", on = "attacker", credit = "buffcaster", estimate = true })
-- Trueshot is 3% of attack power plus 30; only the 30 is known.
physical({ [19506] = 30 },
  { field = "ap", name = "Trueshot Aura", on = "attacker", credit = "party", class = "HUNTER",
    ranged = true, estimate = true })
physical({ [24932] = 0.03 },
  { field = "crit", name = "Leader of the Pack", on = "attacker", credit = "party", class = "DRUID",
    ranged = true, estimate = true })
physical({ [7140] = 5 },
  { field = "flat", name = "Expose Weakness", on = "target", credit = "aura" })

V.WINDFURY = 51368          -- the proc: cast on the player, the extra swing that same moment
V.WINDFURY_TOTEMS = { [8512] = true, [10613] = true, [10614] = true }
local BOSS_ARMOR = 3731     -- a level 63 raid boss
local ARMOR_K = 400 + 85 * 60
local RANGED = { ["Auto Shot"] = true, ["Aimed Shot"] = true, ["Multi-Shot"] = true }

-- Buffs on the attacker, as a list: walked on every hit.
V.attackerIds = {}
for id, e in pairs(V.EFFECTS) do
  if e.on == "attacker" then table.insert(V.attackerIds, id) end
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
V.lastCaster = {}     -- spellId -> who cast that buff last (Greater Blessings)
V.wfAt = {}           -- player guid -> when Windfury just procced on them
V.lastTotem = {}      -- shaman guid -> when they last dropped Windfury Totem
V.speed = {}          -- player guid (.. "r" for ranged) -> seconds between swings
V.lastSwingAt = {}    -- the same keys -> their last swing

function V:Enabled()
  return W.db and W.db.raidValue == true
end

--- The estimated effects too: armor, attack power, crit (experimental).
function V:Estimates()
  return W.db and W.db.raidValueEstimates == true
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
    self.lastCaster[spellId] = caster
    return
  end
  local t = self.lastCast[target]
  if not t then
    t = {}
    self.lastCast[target] = t
  end
  t[spellId] = { by = caster, at = GetTime() }
  -- Recast on a debuff already up: a curse refreshed is the new caster's;
  -- one more Sunder is one more share for whoever put it on.
  local d = self.mob[target] and self.mob[target][spellId]
  if d then
    d.by = caster
    if e.stacking then
      d.appliers = d.appliers or {}
      d.appliers[caster] = (d.appliers[caster] or 0) + 1
    end
  end
end

--- A cast went off: a Judgement is about to put its debuff on the target;
--- Windfury procced on a player; a shaman dropped Windfury Totem.
function V:SpellGo(spellId, caster, target)
  if not self:Enabled() or not caster then return end
  if spellId == self.WINDFURY then
    self.wfAt[caster] = GetTime()
  elseif self.WINDFURY_TOTEMS[spellId] then
    self.lastTotem[caster] = GetTime()
  elseif target and spellName(spellId) == "Judgement" then
    self.lastJudge[target] = { by = caster, at = GetTime() }
  end
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
  local fresh = not d
  if fresh then
    d = { slots = {} }
    set[spellId] = d
  end
  d.slots[slot or "anon"] = true
  stacks = tonumber(stacks)
  if stacks and stacks > 0 then d.stacks = stacks end
  local by = self:Provider(guid, spellId, effect)
  d.by = by or d.by
  --[[ A stacking debuff (Sunder, Shadow Weaving) is several players' work:
       each application or refresh is a share. An aura-cast one counts its
       later casts in AuraCast, so only the first is counted here. ]]
  if effect.stacking and by and (fresh or effect.credit ~= "aura") then
    d.appliers = d.appliers or {}
    d.appliers[by] = (d.appliers[by] or 0) + 1
  end
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
  self.armorOf[guid] = nil
  self.armorOf[guid .. "?"] = nil
  self.lastCast[guid] = nil
  self.lastShadowCrit[guid] = nil
  self.lastHit[guid] = nil
  self.lastJudge[guid] = nil
  self.recentMelee[guid] = nil
end

----------------------------------------------------------------------
-- the paladin's auras, and buffs cast on players
----------------------------------------------------------------------

--- The player of `class` (the paladin by default) in an attacker's own
--- group with this aura up, or nil. Remembered a few seconds per spell.
function V:PartyProvider(attacker, spellId, class)
  class = class or "PALADIN"
  local now = GetTime()
  local cache = self.partyCache[attacker]
  if not cache then
    cache = {}
    self.partyCache[attacker] = cache
  end
  local c = cache[spellId]
  if c and now - c.at < 5 then return c.by end
  local me = W.capture.units[attacker]
  local group = me and W.capture:Subgroup(me.name)
  local by
  for guid, buffs in pairs(W.capture.buffs) do
    local u = W.capture.units[guid]
    if buffs[spellId] and u and u.isPlayer and u.class == class then
      if guid == attacker or (group and W.capture:Subgroup(u.name) == group) then
        by = guid
        if guid == attacker then break end
      end
    end
  end
  cache[spellId] = { by = by, at = now }
  return by
end

--- The shaman behind a Windfury swing: one in the attacker's group, the
--- one who dropped the totem latest if there are several.
function V:WindfuryProvider(attacker)
  local me = W.capture.units[attacker]
  local group = me and W.capture:Subgroup(me.name)
  if not group then return nil end
  local by, at
  for guid, u in pairs(W.capture.units) do
    if u.isPlayer and u.class == "SHAMAN" and W.capture:Subgroup(u.name) == group then
      local t = self.lastTotem[guid] or 0
      if not by or t > at then by, at = guid, t end
    end
  end
  return by
end

local function buffProvider(self, effect, guid, spellId)
  if effect.credit == "party" then return self:PartyProvider(guid, spellId, effect.class) end
  -- A Greater Blessing is cast on one player and lands on their whole class.
  return (self.buffBy[guid] and self.buffBy[guid][spellId]) or self.lastCaster[spellId]
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

local mults = {}        -- reused: { id, size = bonus, by } x n
local flats = {}        -- reused: { id, size = flat, by } x n

local function push(list, n, id, size, by, d)
  n = n + 1
  local m = list[n]
  if not m then
    m = {}
    list[n] = m
  end
  m.id, m.size, m.by, m.d = id, size, by, d
  return n
end

--- Credit `amount` of an effect: to its provider, or for a stacking debuff
--- split between everyone who applied it, by how often each did.
local function credit(id, name, amount, by, d, from)
  local ap = d and d.appliers
  if ap and next(ap) ~= nil then
    local total = 0
    for _, c in pairs(ap) do total = total + c end
    for g, c in pairs(ap) do W.encounter:Value(g, id, name, amount * c / total, from) end
    return
  end
  W.encounter:Value(by, id, name, amount, from)
end

local function noteSpeed(self, key, now)
  local last = self.lastSwingAt[key]
  self.lastSwingAt[key] = now
  local gap = last and now - last
  if not gap or gap <= 0.3 or gap > 5 then return end
  local s = self.speed[key]
  self.speed[key] = s and (s * 0.9 + gap * 0.1) or gap
end

local shares = {}       -- reused: { id, size = damage, by } x n

--[[ A physical hit: Windfury's extra swing whole, then -- with estimates
     on -- what armor taken off, attack power and crit added to it. ]]
function V:Physical(attacker, target, amount, crit, ranged, swing)
  if not amount or amount <= 0 then return end
  local now = GetTime()
  if swing then
    local wf = self.wfAt[attacker]
    if wf and now - wf <= 0.05 then
      self.wfAt[attacker] = nil
      W.encounter:Value(self:WindfuryProvider(attacker), self.WINDFURY, "Windfury Totem", amount, attacker)
      return
    end
  end
  local estimates = self:Estimates()
  local mobSet = self.mob[target]
  local n = 0

  -- Armor: what was taken off, and by whom.
  local removed = 0
  if estimates and mobSet then
    for id, d in pairs(mobSet) do
      local e = self.EFFECTS[id]
      if e.armor then removed = removed + e.armor * (d.stacks or 1) end
    end
  end
  local base = estimates and self:MobArmor(target, removed) or BOSS_ARMOR
  local keepNow = 1 - base / (base + ARMOR_K)
  if estimates and mobSet then
    if removed > 0 then
      local keepBase = keepNow
      local left = base - removed
      if left < 0 then left = 0 end
      keepNow = 1 - left / (left + ARMOR_K)
      local extra = amount - amount * keepBase / keepNow
      for id, d in pairs(mobSet) do
        local e = self.EFFECTS[id]
        if e.armor then n = push(shares, n, id, extra * e.armor * (d.stacks or 1) / removed, d.by, d) end
      end
    end
  end

  if mobSet then
    for id, d in pairs(mobSet) do
      local e = self.EFFECTS[id]
      if e.flat and e.schools[0] then
        n = push(shares, n, id, e.flat < amount and e.flat or amount, d.by, d)
      elseif estimates and e.rangedAp and ranged then
        local sp = self.speed[attacker .. "r"]
        if sp then n = push(shares, n, id, e.rangedAp / 14 * sp * keepNow * (crit and 2 or 1), d.by, d) end
      end
    end
  end

  local buffs = estimates and W.capture.buffs[attacker]
  if buffs then
    local sp = self.speed[ranged and (attacker .. "r") or attacker]
    for _, id in ipairs(self.attackerIds) do
      local e = self.EFFECTS[id]
      if buffs[id] and e.schools[0] and (e.ranged or not ranged) then
        local size
        if e.ap and sp then
          size = e.ap / 14 * sp * keepNow * (crit and 2 or 1)
        elseif e.crit then
          size = e.crit * (crit and amount / 2 or amount)
        end
        if size then n = push(shares, n, id, size, buffProvider(self, e, attacker, id), nil) end
      end
    end
  end
  if n == 0 then return end

  -- Estimates never claim most of a hit.
  local total = 0
  for i = 1, n do total = total + shares[i].size end
  local scale = total > amount * 0.75 and amount * 0.75 / total or 1
  for i = 1, n do
    local s = shares[i]
    local e = self.EFFECTS[s.id]
    credit(s.id, e.estimate and (e.name .. " (est.)") or e.name, s.size * scale, s.by, s.d, attacker)
  end
end

--[[ A mob's armor before anyone's debuffs, best source first:
       live    the client's own unit field (GetUnitField "resistances",
               armor first), which already has the debuffs taken off --
               so the base is what it reads plus what they removed
       learned what a live read gave for a mob of that name before, kept
               in W.db.mobArmor so the table grows as you raid
       default a raid boss's, BOSS_ARMOR
     Read once per mob: the debuffs are followed here, so the live number
     only has to say where the mob started. ]]
V.armorOf = {}   -- mob guid -> its base armor, once known

function V:MobArmor(guid, removed)
  local known = self.armorOf[guid]
  if known then return known end
  local u = W.capture.units[guid] or W.capture:Unit(guid)
  local name = u and u.name
  if GetUnitField and not self.armorOf[guid .. "?"] then
    self.armorOf[guid .. "?"] = true    -- asked once, answer or not
    local ok, r = pcall(GetUnitField, guid, "resistances")
    local live = ok and type(r) == "table" and tonumber(r[1])
    -- 0 is what a hidden field reads: no answer, not "no armor".
    if live and live > 0 then
      local b = live + (removed or 0)
      self.armorOf[guid] = b
      if name and W.db then
        W.db.mobArmor = W.db.mobArmor or {}
        -- Learned only from a clean read: nothing of ours on it yet.
        if (removed or 0) == 0 then W.db.mobArmor[name] = b end
      end
      return b
    end
  end
  local learned = name and W.db and W.db.mobArmor and W.db.mobArmor[name]
  if learned then
    self.armorOf[guid] = learned
    return learned
  end
  return BOSS_ARMOR
end

--- A melee swing landed: a candidate for a melee proc on that mob.
function V:Swing(attacker, target, amount, crit)
  if not self:Enabled() or not isPlayer(attacker) then return end
  local r = self.recentMelee[target]
  if not r then
    r = {}
    self.recentMelee[target] = r
  end
  local now = GetTime()
  r[attacker] = now
  noteTarget(self, attacker, target)
  if amount then
    noteSpeed(self, attacker, now)
    self:Physical(attacker, target, amount, crit, false, true)
  end
end

--- A spell hit: note what it says about procs, then credit what boosted it.
function V:SpellHit(caster, target, spellId, amount, school, crit)
  if not self:Enabled() or not caster or not target then return end
  local u = isPlayer(caster)
  if not u then return end
  school = tonumber(school) or 0
  if school == 0 then
    -- Physical: a melee ability is a proc candidate too; an Auto Shot
    -- times the ranged weapon.
    local name = spellName(spellId)
    local ranged = name and RANGED[name]
    if ranged then
      noteTarget(self, caster, target)
      if name == "Auto Shot" then noteSpeed(self, caster .. "r", GetTime()) end
    else
      self:Swing(caster, target)
    end
    self:Physical(caster, target, amount, crit, ranged, false)
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
          nf = push(flats, nf, id, e.flat, d.by, d)
        else
          n = push(mults, n, id, e.bonus or e.perStack * (d.stacks or 1), d.by, d)
        end
      end
    end
  end
  local buffs = W.capture.buffs[caster]
  if buffs then
    for _, id in ipairs(self.attackerIds) do
      local e = self.EFFECTS[id]
      if buffs[id] and e.schools[school] then
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
    credit(m.id, self.EFFECTS[m.id].name, extra * math.log(1 + m.size) / logs, m.by, m.d, caster)
  end
  -- A flat bonus comes before the multipliers, and is no more than what the
  -- hit had left once they are taken out.
  local left = amount / product
  for i = 1, nf do
    local f = flats[i]
    local share = f.size < left and f.size or left
    left = left - share
    credit(f.id, self.EFFECTS[f.id].name, share, f.by, f.d, caster)
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

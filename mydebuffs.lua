--[[ Wrekkit :: mydebuffs

Your own debuffs on each mob, for the mob frames (Settings > Mob frames,
"My debuffs on each mob"): Serpent Sting, the curses, Corruption -- yours,
never another player's copy of the same spell.

  Which are on a mob   DEBUFF_ADDED/REMOVED_OTHER, by the aura's slot.
  Which are yours      it lands on the mob just after you cast it there
                       (SPELL_GO_SELF), or the client names you as its
                       caster (AURA_CAST_ON_OTHER, with the aura-cast CVar
                       on). Another player's Serpent Sting lands in a slot
                       of its own, and stays out.
  How long they last   the client does not say, so it is learned: the
                       longest any of yours ran before wearing off, per
                       spell (W.db.debuffDurations). A countdown shows from
                       the second one on; an early dispel never shortens it.

A recast on one already there refreshes it: no new aura arrives for that,
so your cast restarts its clock.
]]

local W = Wrekkit
W.myDebuffs = {}
local D = W.myDebuffs

local CLAIM = 1.5        -- seconds a cast of yours claims the debuff it lands
local MAX_SPAN = 600     -- a "duration" longer than this was not one
local MIN_SPAN = 2       -- nor shorter than this (a resist, a dispel at once)

D.on = {}                -- mob guid -> aura slot -> { id, at, stacks }
D.pending = {}           -- mob guid -> spellId -> when you cast it there

function D:Enabled()
  local s = W.threat and W.threat:Settings()
  return s and s.mobDebuffs == true or false
end

--- On: ask the client to name the casters of auras (procs you never cast).
function D:Apply()
  if self:Enabled() and SetCVar then pcall(SetCVar, "NP_EnableAuraCastEvents", 1) end
end

local function myGuid()
  if UnitExists then
    local _, guid = UnitExists("player")
    if guid and guid ~= "player" then return guid end
  end
  return nil
end

--- A cast of yours at a mob (SPELL_GO_SELF), or an aura the client says
--- you cast (AuraCast).
function D:Cast(spellId, target)
  if not self:Enabled() or not target or not spellId or spellId == 0 then return end
  local now = GetTime()
  local p = self.pending[target]
  if not p then
    p = {}
    self.pending[target] = p
  end
  for id, at in pairs(p) do
    if now - at > CLAIM then p[id] = nil end
  end
  p[spellId] = now
  -- One of yours already on it: the recast restarts its clock.
  local slots = self.on[target]
  if slots then
    for _, d in pairs(slots) do
      if d.id == spellId then d.at = now end
    end
  end
end

function D:AuraCast(spellId, caster, target)
  if caster and caster == myGuid() then self:Cast(spellId, target) end
end

function D:Added(guid, spellId, slot, stacks)
  if not self:Enabled() or not guid or not slot then return end
  local slots = self.on[guid]
  local p = self.pending[guid]
  local when = p and p[spellId]
  if when and GetTime() - when <= CLAIM then
    if not slots then
      slots = {}
      self.on[guid] = slots
    end
    local d = slots[slot]
    if not d then
      d = {}
      slots[slot] = d
    end
    d.id, d.at, d.stacks = spellId, GetTime(), tonumber(stacks) or 1
    p[spellId] = nil
    return
  end
  local d = slots and slots[slot]
  if not d then return end
  if d.id == spellId then
    d.stacks = tonumber(stacks) or d.stacks       -- a stack of yours moved
  else
    slots[slot] = nil                              -- someone else's now
  end
end

function D:Removed(guid, spellId, slot)
  local slots = self.on[guid]
  local d = slots and slots[slot]
  if not d or d.id ~= spellId then return end
  slots[slot] = nil
  if not next(slots) then self.on[guid] = nil end
  local ran = GetTime() - d.at
  if ran >= MIN_SPAN and ran <= MAX_SPAN and W.db then
    W.db.debuffDurations = W.db.debuffDurations or {}
    local had = W.db.debuffDurations[spellId]
    if not had or ran > had then W.db.debuffDurations[spellId] = math.floor(ran * 10 + 0.5) / 10 end
  end
end

--- The mob died: its debuffs went with it, and say nothing of a duration.
function D:Died(guid)
  self.on[guid] = nil
  self.pending[guid] = nil
end

--[[ Your debuffs on a mob, the first to run out first: a list of
     { id, icon, left, stacks }, `left` the seconds to go where the duration
     is known, else nil. Filled into `out`, which the caller keeps. ]]
function D:On(guid, out)
  out = out or {}
  local n = 0
  local slots = guid and self.on[guid]
  if slots then
    local known = W.db and W.db.debuffDurations
    local now = GetTime()
    for _, d in pairs(slots) do
      n = n + 1
      local e = out[n]
      if not e then
        e = {}
        out[n] = e
      end
      local _, icon = W.capture:Spell(d.id)
      local span = known and known[d.id]
      e.id, e.icon, e.stacks = d.id, icon, d.stacks
      e.left = span and math.max(0, span - (now - d.at)) or nil
    end
  end
  for i = n + 1, table.getn(out) do out[i] = nil end
  table.sort(out, function(a, b) return (a.left or 9999) < (b.left or 9999) end)
  return out
end

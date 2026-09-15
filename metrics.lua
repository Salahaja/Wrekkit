--[[ Wrekkit :: metrics

Every way the report and the live meter can rank people. A metric knows how
to pull its number off an aggregated row, how to label it, and what its
secondary (right-hand) column says -- which is almost always the per-second
rate or a percentage of the raid total.

Adding a metric here makes it appear in both the meter's mode menu and the
report's sort options; nothing else needs touching.
]]

local W = Wrekkit
W.metrics = {}
local M = W.metrics

local function rate(value, duration)
  if not duration or duration <= 0 then return 0 end
  return value / duration
end

--[[ Each entry:
     key      stable id, stored in saved settings
     label    menu and header text
     short    column header when space is tight
     side     "player" ranks the raid, "enemy" ranks what you fought
     value    (row, ctx) -> number ranked on
     sub      (row, ctx) -> string for the secondary column
     color    bar tint; nil means use the actor's class colour
     detail   which per-ability table the drilldown should open
]]

M.list = {
  {
    key = "damage", label = "Damage Done", short = "DMG", side = "player",
    value = function(r) return r.damage end,
    sub = function(r, ctx) return W.Short(rate(r.damage, ctx.duration)) .. " dps" end,
    detail = "dmgAbility",
  },
  {
    key = "dps", label = "DPS", short = "DPS", side = "player",
    value = function(r, ctx) return rate(r.damage, ctx.duration) end,
    sub = function(r) return W.Short(r.damage) end,
    detail = "dmgAbility",
  },
  {
    key = "healing", label = "Healing (effective)", short = "HEAL", side = "player",
    value = function(r) return r.healing end,
    sub = function(r, ctx) return W.Short(rate(r.healing, ctx.duration)) .. " hps" end,
    color = W.color.healing,
    detail = "healAbility",
  },
  {
    key = "hps", label = "HPS", short = "HPS", side = "player",
    value = function(r, ctx) return rate(r.healing, ctx.duration) end,
    sub = function(r) return W.Short(r.healing) end,
    color = W.color.healing,
    detail = "healAbility",
  },
  {
    key = "healingTotal", label = "Healing (raw)", short = "RAW", side = "player",
    value = function(r) return r.healing + r.overheal end,
    sub = function(r)
      local total = r.healing + r.overheal
      if total <= 0 then return "0%" end
      return string.format("%.0f%% over", r.overheal / total * 100)
    end,
    color = W.color.healing,
    detail = "healAbility",
  },
  {
    key = "overheal", label = "Overhealing", short = "OVER", side = "player",
    value = function(r) return r.overheal end,
    sub = function(r)
      local total = r.healing + r.overheal
      if total <= 0 then return "0%" end
      return string.format("%.0f%%", r.overheal / total * 100)
    end,
    color = W.color.overheal,
    detail = "healAbility",
  },
  {
    key = "taken", label = "Damage Taken", short = "TAKEN", side = "player",
    value = function(r) return r.taken end,
    sub = function(r, ctx) return W.Short(rate(r.taken, ctx.duration)) .. " dtps" end,
    color = W.color.taken,
    detail = "takenAbility",
  },
  {
    key = "absorbed", label = "Absorbed", short = "ABS", side = "player",
    value = function(r) return r.absorbed end,
    sub = function(r) return W.Short(r.absorbed) end,
    color = W.color.taken,
  },
  {
    key = "deaths", label = "Deaths", short = "DIED", side = "player",
    value = function(r) return r.deaths end,
    sub = function(r) return r.deaths > 0 and (r.deaths .. "x") or "-" end,
    color = W.color.death,
    integer = true,
  },
  {
    key = "dispels", label = "Dispels", short = "DISP", side = "player",
    value = function(r) return r.dispels end,
    sub = function(r) return tostring(r.dispels) end,
    integer = true,
  },
  {
    key = "interrupts", label = "Interrupts", short = "KICK", side = "player",
    value = function(r) return r.interrupts end,
    sub = function(r) return tostring(r.interrupts) end,
    integer = true,
  },
  {
    -- Who is burning consumables. Ranked by count rather than by any notion
    -- of value, because the client cannot price them and a raid leader is
    -- really asking "is that parse bought or played".
    key = "consumes", label = "Consumables", short = "CONS", side = "player",
    value = function(r) return r.consumes or 0 end,
    sub = function(r)
      local n = r.consumes or 0
      return n > 0 and (n .. " used") or "-"
    end,
    color = W.color.accent,
    detail = "consumeItem",
    integer = true,
  },
  {
    key = "crit", label = "Crit %", short = "CRIT", side = "player",
    value = function(r)
      if (r.hits or 0) <= 0 then return 0 end
      return r.crits / r.hits * 100
    end,
    sub = function(r) return (r.crits or 0) .. "/" .. (r.hits or 0) end,
    percent = true,
  },
  {
    key = "enemy", label = "Enemy Damage", short = "DMG", side = "enemy",
    value = function(r) return r.damage end,
    sub = function(r, ctx) return W.Short(rate(r.damage, ctx.duration)) .. " dps" end,
    color = W.color.taken,
    detail = "dmgAbility",
  },
  {
    key = "enemyTaken", label = "Enemy Damage Taken", short = "TAKEN", side = "enemy",
    value = function(r) return r.taken end,
    sub = function(r, ctx) return W.Short(rate(r.taken, ctx.duration)) .. " dps" end,
    detail = "takenAbility",
  },
}

M.byKey = {}
for _, m in ipairs(M.list) do M.byKey[m.key] = m end

function M.Get(key)
  return M.byKey[key] or M.byKey.damage
end

--- Format a metric's primary number for display.
function M.Format(metric, value)
  if metric.percent then return string.format("%.1f%%", value) end
  if metric.integer then return string.format("%d", math.floor(value)) end
  return W.Short(value)
end

--- Ordered keys, for cycling with the meter's next/prev mode buttons.
M.order = {}
for i, m in ipairs(M.list) do M.order[i] = m.key end

function M.Next(key, step)
  local idx = 1
  for i, k in ipairs(M.order) do
    if k == key then idx = i break end
  end
  idx = idx + (step or 1)
  local n = table.getn(M.order)
  while idx > n do idx = idx - n end
  while idx < 1 do idx = idx + n end
  return M.order[idx]
end

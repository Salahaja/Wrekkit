--[[ Wrekkit :: report

The query layer. Both the live meter and the full report window ask this
module the same question -- "given these encounters, this metric and this
filter, what are the rows?" -- so the two views can never disagree.

Encounters arrive from two places with slightly different shapes: the live
one holds ability tables keyed by spell id, while persisted ones hold them
as pre-sorted arrays (see encounter.lua's Persist). Everything here reads
through helpers that accept both.
]]

local W = Wrekkit
W.report = {}
local R = W.report

----------------------------------------------------------------------
-- source selection
----------------------------------------------------------------------

--- All stored encounters newest-first, grouped into sessions. A session is
--- a run of encounters sharing a sessionId, which encounter.lua starts fresh
--- whenever the zone changes.
function R:Sessions()
  local out, index = {}, {}

  local function place(rec, isLive)
    local sid = rec.sessionId or 0
    local s = index[sid]
    if not s then
      s = { id = sid, zone = rec.zone, startTime = rec.startTime, encounters = {} }
      index[sid] = s
      table.insert(out, s)
    end
    if rec.startTime < s.startTime then s.startTime = rec.startTime end
    table.insert(s.encounters, rec)
    if isLive then s.hasLive = true end
  end

  local stored = (W.db and W.db.encounters) or {}
  for _, rec in ipairs(stored) do place(rec, false) end

  local live = W.encounter.live
  if live and live.totals and (live.totals.damage > 0 or live.totals.healing > 0) then
    place(live, true)
  end

  table.sort(out, function(a, b) return a.startTime > b.startTime end)
  for _, s in ipairs(out) do
    table.sort(s.encounters, function(a, b) return (a.offset or 0) < (b.offset or 0) end)
  end
  return out
end

function R:MostRecentSession()
  local s = self:Sessions()
  return s[1]
end

--[[ The session being logged right now, or nil if logging just restarted.

     Different question from MostRecentSession: after "start a new log" the
     most recent stored session is the one that was just closed, and the live
     meter showing it would make the reset look like it did nothing. Anything
     that finished at or before the barrier is treated as closed, so the
     meter reads empty until the next pull lands.

     The report deliberately does NOT use this -- browsing old sessions is
     the whole point of that window. ]]
function R:CurrentSession()
  local live = W.encounter.session
  local sessions = self:Sessions()

  if live then
    for _, s in ipairs(sessions) do
      if s.id == live.id then return s end
    end
    -- Session opened but nothing stored in it yet.
    return { id = live.id, zone = live.zone,
             startTime = live.startTime, encounters = {} }
  end

  local s = sessions[1]
  if not s then return nil end

  local barrier = (W.db and W.db.sessionBarrier) or 0
  if barrier > 0 then
    local newest = 0
    for _, e in ipairs(s.encounters) do
      local endsAt = (e.startTime or 0) + math.floor(e.duration or 0)
      if endsAt > newest then newest = endsAt end
    end
    if newest <= barrier then return nil end
  end

  return s
end

----------------------------------------------------------------------
-- ability iteration (hash form or array form)
----------------------------------------------------------------------

local function eachAbility(tbl, fn)
  if not tbl then return end
  -- Array form (persisted): integer keys, rows carry their own id.
  if tbl[1] ~= nil then
    for _, row in ipairs(tbl) do fn(row.id, row) end
    return
  end
  for id, row in pairs(tbl) do fn(id, row) end
end

R.eachAbility = eachAbility

----------------------------------------------------------------------
-- merging
----------------------------------------------------------------------

local function blankRow(a, key)
  return {
    key = key,
    name = a.name or "?",
    class = a.class or "UNKNOWN",
    isPlayer = a.isPlayer or false,
    owner = a.owner,
    ownerName = a.ownerName,
    damage = 0, taken = 0, healing = 0, overheal = 0, absorbed = 0,
    deaths = 0, dispels = 0, interrupts = 0,
    hits = 0, crits = 0, misses = 0, consumes = 0, active = 0,
    auras = {},
    dmgAbility = {}, healAbility = {}, takenAbility = {}, consumeItem = {},
  }
end

local function addAbilities(dst, src)
  eachAbility(src, function(id, row)
    local d = dst[id]
    if not d then
      d = { id = id, name = row.name, amount = 0, over = 0,
            hits = 0, crits = 0, misses = 0,
            max = 0, min = nil, critAmount = 0 }
      dst[id] = d
    end
    --[[ Carried, not summed. This is the third place an ability is rebuilt
         from a named list of fields, and the third place a field that is not
         named here silently stops existing -- which is how the resist
         statistics were recorded, persisted and tested correctly while never
         appearing on screen. ]]
    if d.school == nil then d.school = row.school end
    d.amount = d.amount + (row.amount or 0)
    d.over = d.over + (row.over or 0)
    d.hits = d.hits + (row.hits or 0)
    d.crits = d.crits + (row.crits or 0)
    d.misses = d.misses + (row.misses or 0)
    d.critAmount = d.critAmount + (row.critAmount or 0)

    -- Partial resists, and the reasons the rest never landed.
    d.resisted = (d.resisted or 0) + (row.resisted or 0)
    d.resistHits = (d.resistHits or 0) + (row.resistHits or 0)
    d.r25 = (d.r25 or 0) + (row.r25 or 0)
    d.r50 = (d.r50 or 0) + (row.r50 or 0)
    d.r75 = (d.r75 or 0) + (row.r75 or 0)
    if row.missBy then
      if not d.missBy then d.missBy = {} end
      for code, n in pairs(row.missBy) do
        d.missBy[code] = (d.missBy[code] or 0) + n
      end
    end
    if (row.max or 0) > d.max then d.max = row.max end
    -- min is nil until something lands, so merge it as "smallest seen"
    -- rather than letting an absent value win as zero.
    if row.min and (not d.min or row.min < d.min) then d.min = row.min end
  end)
end

--- Build one merged view over a set of encounter records.
--- opts.petMode  "merge" folds pets into their owner (the site's default),
---               "separate" keeps them as their own rows.
--- opts.enemyBy  "name" merges every Onyxian Whelp into one row,
---               "unit" keeps each spawn separate.
function R:View(encounters, opts)
  opts = opts or {}
  local petMode = opts.petMode or "merge"
  local enemyBy = opts.enemyBy or "name"

  local view = {
    rows = {}, index = {},
    duration = 0, combat = 0, elapsed = 0,
    totals = { damage = 0, healing = 0, overheal = 0, taken = 0, enemy = 0 },
    deaths = {},
    encounters = encounters,
    count = table.getn(encounters),
  }

  local minStart, maxStop = nil, nil

  for _, enc in ipairs(encounters) do
    -- Ask the encounter rather than reading its fields: a pull still in
    -- progress has not banked its combat time or end stamp yet, and reading
    -- those raw would make every per-second metric divide into zero until
    -- the fight ended.
    view.combat = view.combat + W.encounter:CombatTime(enc)
    local encDur = W.encounter:Elapsed(enc)
    view.duration = view.duration + encDur

    local off = enc.offset or 0
    if not minStart or off < minStart then minStart = off end
    if not maxStop or (off + encDur) > maxStop then maxStop = off + encDur end

    local t = enc.totals or {}
    view.totals.damage = view.totals.damage + (t.damage or 0)
    view.totals.healing = view.totals.healing + (t.healing or 0)
    view.totals.overheal = view.totals.overheal + (t.overheal or 0)
    view.totals.taken = view.totals.taken + (t.taken or 0)
    view.totals.enemy = view.totals.enemy + (t.enemy or 0)

    for _, d in ipairs(enc.deaths or {}) do
      table.insert(view.deaths, {
        t = (d.t or 0) + off, name = d.name, class = d.class, encounter = enc.name,
        -- Carried through, or clicking a death in the report finds nothing
        -- to show: the window reads the view, not the encounter behind it.
        recap = d.recap,
      })
    end

    for guid, a in pairs(enc.actors or {}) do
      -- Decide the merge key and which row this actor's numbers land on.
      local key, target = nil, a
      if a.isPlayer then
        key = "p:" .. (a.name or guid)
      elseif a.class == "PET" then
        if petMode == "merge" and a.ownerName then
          key = "p:" .. a.ownerName
        else
          key = "t:" .. (a.name or "Pet") .. ":" .. (a.ownerName or guid)
        end
      else
        key = (enemyBy == "unit") and ("e:" .. guid) or ("e:" .. (a.name or guid))
      end

      local row = view.index[key]
      if not row then
        row = blankRow(a, key)
        if a.class == "PET" and petMode == "merge" and a.ownerName then
          -- Folded into the owner: present as the player, not the pet.
          row.name = a.ownerName
          row.class = W.capture.rosterClass[a.ownerName] or "UNKNOWN"
          row.isPlayer = true
        elseif a.class == "PET" then
          row.name = (a.name or "Pet") .. " (" .. (a.ownerName or "?") .. ")"
        end
        view.index[key] = row
        table.insert(view.rows, row)
      end

      row.damage = row.damage + (a.damage or 0)
      row.taken = row.taken + (a.taken or 0)
      row.healing = row.healing + (a.healing or 0)
      row.overheal = row.overheal + (a.overheal or 0)
      row.absorbed = row.absorbed + (a.absorbed or 0)
      row.deaths = row.deaths + (a.deaths or 0)
      row.dispels = row.dispels + (a.dispels or 0)
      row.interrupts = row.interrupts + (a.interrupts or 0)
      row.hits = row.hits + (a.hits or 0)
      row.crits = row.crits + (a.crits or 0)
      row.misses = row.misses + (a.misses or 0)
      row.consumes = row.consumes + (a.consumes or 0)
      -- Summed across encounters, like every other total. Merging a pet
      -- into its owner adds the pet's seconds, which is right: the owner
      -- was contributing through it.
      row.active = (row.active or 0) + (a.active or 0)

      -- Uptime sums across pulls the same way damage does, so "flask up for
      -- 92% of the night" is answerable rather than only per pull.
      if not row.auras then row.auras = {} end
      W.report.eachAbility(a.auras, function(id, au)
        local d = row.auras[id]
        if not d then
          d = { id = id, name = au.name, up = 0, applied = 0 }
          row.auras[id] = d
        end
        d.up = d.up + (au.up or 0)
        d.applied = d.applied + (au.applied or 0)
      end)

      addAbilities(row.dmgAbility, a.dmgAbility)
      addAbilities(row.healAbility, a.healAbility)
      addAbilities(row.takenAbility, a.takenAbility)
      addAbilities(row.consumeItem, a.consumeItem)

      -- A player row that was created by a pet first has no class yet.
      if row.class == "UNKNOWN" and a.isPlayer and a.class ~= "UNKNOWN" then
        row.class = a.class
      end
    end

    --[[ Fill gaps from what other players reported about themselves.

         Strictly a gap-filler. A number measured here always wins, because
         it was observed rather than asserted, and a raider sitting inside
         our combat log range needs no help. Where we saw LESS than they
         report -- the usual case for someone at the far end of a room --
         their figure is used and the row is marked, so a report is never
         mistaken for a measurement.

         Taking the larger rather than summing matters: both numbers
         describe the same damage, so adding them would double it. ]]
    for name, rem in pairs(enc.remote or {}) do
      local key = "p:" .. name
      local row = view.index[key]
      if not row then
        row = blankRow({ name = name, class = rem.class, isPlayer = true }, key)
        view.index[key] = row
        table.insert(view.rows, row)
      end

      local filled = false
      if (rem.damage or 0) > (row.damage or 0) then
        row.damage = rem.damage filled = true
      end
      if (rem.healing or 0) > (row.healing or 0) then
        row.healing = rem.healing filled = true
      end
      if (rem.taken or 0) > (row.taken or 0) then
        row.taken = rem.taken filled = true
      end
      if (rem.active or 0) > (row.active or 0) then
        row.active = rem.active
      end
      if filled then
        row.remote = true
        if row.class == "UNKNOWN" and rem.class ~= "UNKNOWN" then
          row.class = rem.class
        end
      end
    end
  end

  view.elapsed = (maxStop or 0) - (minStart or 0)
  if view.elapsed < view.duration then view.elapsed = view.duration end
  -- Rates are quoted against combat time, matching the site's "combat" clock.
  view.rateBase = view.combat > 0 and view.combat or view.duration
  return view
end

----------------------------------------------------------------------
-- ranking
----------------------------------------------------------------------

local function matches(row, filter)
  if not filter then return true end

  if filter.search and filter.search ~= "" then
    local hay = string.lower(row.name or "")
    if not string.find(hay, string.lower(filter.search), 1, true) then return false end
  end

  if filter.classes then
    local any = false
    for _ in pairs(filter.classes) do any = true break end
    if any and not filter.classes[row.class] then return false end
  end

  if filter.hidePets and not row.isPlayer and row.class == "PET" then return false end
  if filter.minValue and (row._v or 0) < filter.minValue then return false end

  --[[ Ignore players who are not in your party or raid.

       Applies to players and their pets only -- enemies are never "in the
       group", and filtering them here would empty the Enemies tab. Group
       membership is read live rather than stored on the encounter, so a
       report from a night when someone was in the raid still shows them if
       they are in it now; the alternative is stamping membership at capture
       time, which would then be wrong for anyone who joined mid-raid. ]]
  if filter.groupOnly then
    local who = row.ownerName or row.name
    if (row.isPlayer or row.class == "PET") and not W.capture:InGroup(who) then
      return false
    end
  end

  return true
end

--- Produce the ranked, filtered rows for a metric.
--- Each returned row carries _v (the ranked number), _rank, _pct (share of
--- the visible total) and _frac (bar length, 0..1 against the leader).
function R:Rank(view, metricKey, filter)
  local metric = W.metrics.Get(metricKey)
  local ctx = { duration = view.rateBase, view = view }

  local out = {}
  for _, row in ipairs(view.rows) do
    local wantEnemy = (metric.side == "enemy")
    local isEnemy = (not row.isPlayer) and row.class ~= "PET"
    if wantEnemy == isEnemy then
      row._v = metric.value(row, ctx) or 0
      if row._v > 0 and matches(row, filter) then
        table.insert(out, row)
      end
    end
  end

  table.sort(out, function(a, b)
    if a._v == b._v then return (a.name or "") < (b.name or "") end
    return a._v > b._v
  end)

  local total, top = 0, 0
  for _, row in ipairs(out) do
    total = total + row._v
    if row._v > top then top = row._v end
  end

  for i, row in ipairs(out) do
    row._rank = i
    row._pct = total > 0 and (row._v / total * 100) or 0
    row._frac = top > 0 and (row._v / top) or 0
    row._text = W.metrics.Format(metric, row._v)
    row._sub = metric.sub and metric.sub(row, ctx) or ""
  end

  return out, metric, total, ctx
end

----------------------------------------------------------------------
-- ability drilldown
----------------------------------------------------------------------

--- Rows for one actor's ability breakdown under the given metric.
function R:Abilities(row, metricKey, ctx)
  local metric = W.metrics.Get(metricKey)
  local source = row[metric.detail or "dmgAbility"]
  if not source then return {} end

  local out = {}
  eachAbility(source, function(id, a)
    --[[ The school is decoration on a SEPARATE field, never on the name.

         `name` is what everything else matches an ability by, so folding the
         school into it turns a lookup key into a display string -- the tests
         caught that immediately, and in the addon it would have shown up as
         an ability quietly failing to be found.

         So `label` is what lists print and `name` is what code compares.
         Nothing was recorded before this existed, so older encounters show
         no school rather than a wrong one. ]]
    local name = a.name or ("Spell " .. tostring(id))
    local school = W.SchoolName(a.school, id)

    table.insert(out, {
      id = id, name = name, school = a.school,
      label = school and (name .. " (" .. school .. ")") or name,
      amount = a.amount or 0, over = a.over or 0,
      hits = a.hits or 0, crits = a.crits or 0,
      misses = a.misses or 0, max = a.max or 0,
      min = a.min, critAmount = a.critAmount or 0,
      --[[ Carried through explicitly, and easy to forget: this rebuilds the
           row rather than passing it on, so anything not named here is
           invisible to AbilityStats and therefore to the drilldown. That is
           how the resist statistics existed, persisted and tested correctly
           while never once appearing on screen. ]]
      resisted = a.resisted or 0, resistHits = a.resistHits or 0,
      r25 = a.r25 or 0, r50 = a.r50 or 0, r75 = a.r75 or 0,
      missBy = a.missBy,
    })
  end)
  table.sort(out, W.ByField("amount"))

  local top = out[1] and out[1].amount or 0
  local total = 0
  for _, a in ipairs(out) do total = total + a.amount end
  for _, a in ipairs(out) do
    a._frac = top > 0 and (a.amount / top) or 0
    a._pct = total > 0 and (a.amount / total * 100) or 0
    a._avg = a.hits > 0 and (a.amount / a.hits) or 0
    a._critPct = a.hits > 0 and (a.crits / a.hits * 100) or 0
  end
  return out, total
end

--[[ Stat lines for a single ability -- the second level of drilldown.

     Averages are split into normal and crit rather than reported as one
     blended figure, because a blended average describes neither: a spell
     that hits for 800 and crits for 1600 has a "1,040 average" that it never
     once dealt. `critAmount` is tracked at capture time to make this
     possible after the fact.

     For healing, the spread is measured on raw output (effective plus
     overheal), which is what the spell actually did; effective healing is
     reported separately above it. ]]
--[[ What killed someone, as lines.

     The question after a wipe is never "who died" -- the raid watched that
     happen. It is what the last few seconds looked like, which is why every
     meter people rate has a version of this, and why it is the feature they
     name first when asked what they use.

     Oldest first, so it reads as a sequence rather than a list. ]]
function R:DeathRecap(death)
  local rows = {}
  if not death then return rows end

  local last = death.t or 0
  for _, e in ipairs(death.recap or {}) do
    local ago = last - (e.t or 0)
    local who = e.src or "?"
    if e.spell and e.spell ~= "" and e.spell ~= "Melee" then
      who = who .. "  " .. e.spell
    end
    table.insert(rows, {
      label = string.format("-%.1fs  %s", ago, who),
      value = W.Comma(e.a or 0),
      note = e.hp and ("hp " .. W.Short(e.hp)) or nil,
    })
  end

  if table.getn(rows) == 0 then
    table.insert(rows, {
      label = "nothing was recorded in the seconds before this",
      value = "",
    })
  end
  return rows
end

function R:AbilityStats(a, metricKey)
  if not a then return {} end
  local metric = W.metrics.Get(metricKey)
  local isHeal = (metric.detail == "healAbility")

  local rows = {}
  local function add(label, value, note)
    table.insert(rows, { label = label, value = value, note = note })
  end

  local hits = a.hits or 0
  local crits = a.crits or 0
  local misses = a.misses or 0
  local normals = hits - crits
  local attempts = hits + misses
  local critAmount = a.critAmount or 0

  -- The pool the spread statistics were measured against.
  local total = isHeal and ((a.amount or 0) + (a.over or 0)) or (a.amount or 0)

  if isHeal then
    add("Effective healing", W.Comma(a.amount))
    if (a.over or 0) > 0 then
      add("Overhealing", W.Comma(a.over),
        total > 0 and string.format("%.1f%%", a.over / total * 100) or nil)
    end
    add("Raw healing", W.Comma(total))
  else
    add("Total", W.Comma(total))
  end

  add("Landed", W.Comma(hits))
  if misses > 0 then
    add("Missed", W.Comma(misses),
      attempts > 0 and string.format("%.1f%% of %d", misses / attempts * 100, attempts) or nil)
  end
  if crits > 0 or hits > 0 then
    add("Crits", W.Comma(crits),
      hits > 0 and string.format("%.1f%%", crits / hits * 100) or nil)
  end

  if hits > 0 then
    add("Average", W.Comma(total / hits))
    if normals > 0 and crits > 0 then
      add("Average normal", W.Comma((total - critAmount) / normals))
      add("Average crit", W.Comma(critAmount / crits))
    end
    add("Largest", W.Comma(a.max or 0))
    if a.min then add("Smallest", W.Comma(a.min)) end
  end

  --[[ Resists, kept as the two separate things they are.

       A FULL resist is a cast that did nothing; it arrives as a miss with
       reason 2 and is counted in `misses` above. A PARTIAL resist LANDED --
       it is in `hits` and in the total, with some of its damage eaten by
       the target's resistance to that school.

       Reporting them together would hide both. Full resists are a hit-table
       problem, partials are a gear problem, and the fix for each is
       different. ]]

  local fullResists = a.missBy and a.missBy[2] or 0
  local partials = a.resistHits or 0

  if fullResists > 0 or partials > 0 then
    if fullResists > 0 then
      add("Fully resisted", W.Comma(fullResists),
        attempts > 0
          and string.format("%.1f%% of %d casts", fullResists / attempts * 100, attempts)
          or nil)
    end

    if partials > 0 then
      add("Partially resisted", W.Comma(partials),
        hits > 0 and string.format("%.1f%% of what landed", partials / hits * 100) or nil)

      local lost = a.resisted or 0
      if lost > 0 then
        local potential = total + lost
        add("Lost to resists", W.Comma(lost),
          potential > 0
            and string.format("%.1f%% of %s potential", lost / potential * 100,
                              W.Short(potential))
            or nil)
        add("Average bite", W.Comma(lost / partials))
      end

      -- Vanilla resists in quarters, and which quarter is the useful part:
      -- a run of 75%s is a different story from a scattering of 25%s.
      local tiers = {}
      if (a.r25 or 0) > 0 then table.insert(tiers, a.r25 .. " at 25%") end
      if (a.r50 or 0) > 0 then table.insert(tiers, a.r50 .. " at 50%") end
      if (a.r75 or 0) > 0 then table.insert(tiers, a.r75 .. " at 75%") end
      if table.getn(tiers) > 0 then
        add("Resist tiers", table.concat(tiers, ", "))
      end
    end
  end

  --[[ Why the rest did not land. "Missed" alone cannot tell a caster whose
       spells are being resisted from one whose are being dodged. ]]
  if a.missBy then
    local MISS_NAME = {
      [1] = "Missed", [2] = "Resisted", [3] = "Dodged", [4] = "Parried",
      [5] = "Blocked", [6] = "Evaded", [7] = "Immune", [8] = "Immune",
      [9] = "Deflected", [10] = "Absorbed", [11] = "Reflected",
    }
    local seen = {}
    for code, n in pairs(a.missBy) do
      -- Full resists already have a line of their own above.
      if code ~= 2 and n > 0 then
        local name = MISS_NAME[code] or ("Reason " .. tostring(code))
        seen[name] = (seen[name] or 0) + n
      end
    end
    for name, n in pairs(seen) do
      add(name, W.Comma(n),
        attempts > 0 and string.format("%.1f%%", n / attempts * 100) or nil)
    end
  end

  return rows
end

--[[ Why a drilldown came back empty.

     Shared and imported encounters carry actor totals only -- sync sends
     rollups to stay inside the addon-message budget, and the disk journal
     stores rollups to stay a sensible size. Opening a player from one of
     those therefore has nothing to list, and a blank panel reads as a broken
     addon rather than a stated limitation. Say which it is. ]]
function R:EmptyDetailNote(view)
  local shared, imported = false, false
  for _, enc in ipairs((view and view.encounters) or {}) do
    if enc.sharedBy then shared = true end
    if enc.imported then imported = true end
  end
  if shared then
    return "No ability detail - shared reports carry totals only."
  end
  if imported then
    return "No ability detail - restored from disk, which stores totals only."
  end
  return "Nothing recorded for this selection."
end

----------------------------------------------------------------------
-- timeline
----------------------------------------------------------------------

--- Merge the per-second buckets of several encounters onto one axis, then
--- smooth with a trailing window (the site calls this RollingAverages).
--- Returns series tables plus the peak, which the chart scales against.
function R:Series(encounters, windowSec)
  windowSec = windowSec or 3
  local axis = {}
  local detail = {}
  local maxT = 0

  for _, enc in ipairs(encounters) do
    local off = math.floor(enc.offset or 0)
    local buckets = enc.bucket or {}
    for i = 0, (enc.maxBucket or 0) do
      local b = buckets[i]
      if b then
        local t = off + i
        local slot = axis[t]
        if not slot then slot = { 0, 0, 0, 0 } axis[t] = slot end
        -- Persisted buckets are arrays; live ones are named fields.
        if b.dd then
          slot[1] = slot[1] + b.dd; slot[2] = slot[2] + b.dt
          slot[3] = slot[3] + b.hl; slot[4] = slot[4] + b.eh
        else
          slot[1] = slot[1] + (b[1] or 0); slot[2] = slot[2] + (b[2] or 0)
          slot[3] = slot[3] + (b[3] or 0); slot[4] = slot[4] + (b[4] or 0)
        end
        --[[ Carry the contributions onto the same axis as the totals.

             A live encounter still holds them keyed by guid, because it is
             mid-fight and Persist has not resolved anything yet; a stored
             one already has names. Resolve the live case here so the
             readout does not have to know the difference. ]]
        local contribs = (enc.top and enc.top[i]) or nil
        if not contribs and b.top then
          contribs = {}
          for _, r in pairs(b.top) do
            local su = W.capture.units[r.s]
            local tu = r.t and W.capture.units[r.t]
            table.insert(contribs, {
              k = r.k,
              src = (su and su.name) or "?",
              dst = tu and tu.name or nil,
              spell = W.capture:Spell(r.id),
              a = r.a, n = r.n,
            })
          end
        end
        if contribs then
          local into = detail[t]
          if not into then into = {} detail[t] = into end
          for _, r in ipairs(contribs) do table.insert(into, r) end
        end

        if t > maxT then maxT = t end
      end
    end
  end

  local series = { dd = {}, dt = {}, hl = {}, eh = {} }
  local peak = 0
  local runDD, runDT, runHL, runEH = 0, 0, 0, 0

  for t = 0, maxT do
    local cur = axis[t]
    runDD = runDD + ((cur and cur[1]) or 0)
    runDT = runDT + ((cur and cur[2]) or 0)
    runHL = runHL + ((cur and cur[3]) or 0)
    runEH = runEH + ((cur and cur[4]) or 0)

    local drop = axis[t - windowSec]
    if drop then
      runDD = runDD - drop[1]; runDT = runDT - drop[2]
      runHL = runHL - drop[3]; runEH = runEH - drop[4]
    end

    local n = windowSec
    local i = t + 1
    series.dd[i] = runDD / n
    series.dt[i] = runDT / n
    series.hl[i] = runHL / n
    series.eh[i] = runEH / n

    if series.dd[i] > peak then peak = series.dd[i] end
    if series.dt[i] > peak then peak = series.dt[i] end
    if series.hl[i] > peak then peak = series.hl[i] end
  end

  return series, maxT + 1, peak, detail
end

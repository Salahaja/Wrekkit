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
    if rec.archived then s.archive = rec.archived end
    table.insert(s.encounters, rec)
    if isLive then s.hasLive = true end
  end

  local stored = (W.db and W.db.encounters) or {}
  local have = {}
  for _, rec in ipairs(stored) do
    place(rec, false)
    have[tostring(rec.sessionId) .. ":" .. tostring(rec.id)] = true
  end

  -- An older raid read in from its own file (archive.lua). Pulls still in
  -- SavedVariables are the same pulls; those copies win.
  local loaded = W.archive and W.archive.loaded
  if loaded then
    for _, rec in ipairs(loaded.list) do
      if not have[tostring(rec.sessionId) .. ":" .. tostring(rec.id)] then place(rec, false) end
    end
  end

  local live = W.encounter.live
  if live and live.totals and (live.totals.damage > 0 or live.totals.healing > 0) then
    place(live, true)
  end
  -- Held a moment for the rest of its fight (E:Finish): not stored yet, but
  -- it is part of the session.
  local held = W.encounter.heldPull
  if held and held ~= live and held.totals and (held.totals.damage > 0 or held.totals.healing > 0) then
    place(held, true)
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

local lazyDetail = {}

local function blankRow(a, key)
  return setmetatable({
    key = key,
    name = a.name or "?",
    class = a.class or "UNKNOWN",
    isPlayer = a.isPlayer or false,
    owner = a.owner,
    ownerName = a.ownerName,
    damage = 0, taken = 0, healing = 0, overheal = 0, absorbed = 0,
    deaths = 0, dispels = 0, interrupts = 0,
    hits = 0, crits = 0, misses = 0, consumes = 0, active = 0,
    critHits = 0, healHits = 0, healCrits = 0, valueAdded = 0,
    valueMana = 0, valueHeal = 0,
    -- auras and the four ability tables are built on first use; see
    -- lazyDetail below.
  }, lazyDetail)
end

--[[ "Credit raid value to providers" (W.db.valueCredit): the damage and
     healing someone's buffs and debuffs added to other people's hits is
     moved off the hitter and onto the provider, so a Curse of Shadow
     warlock's damage includes what the curse added to every other warlock.
     The raid's total does not change. Shown in the provider's drilldown as
     one line per effect. ]]
local function valueCredit()
  return W.db and W.db.valueCredit == true
end

local function creditedDamage(a)
  local d = a.damage or 0
  if valueCredit() then d = d + (a.valueAdded or 0) - (a.valueGot or 0) end
  return d
end

local function creditedHealing(a)
  local h = a.healing or 0
  if valueCredit() then h = h + (a.valueHeal or 0) - (a.valueHealGot or 0) end
  return h
end

--[[ `pet`: a pet folded into its owner's row. Its abilities stay lines of
     their own, named for it ("Raptor: Melee"), rather than vanishing into
     the owner's -- melee is spell 0 for everyone, so the pet's swings used
     to land in the hunter's own "Melee". The key is a string, so it never
     meets an id of the owner's; baseId keeps the real spell. ]]
local function addAbilities(dst, src, pet)
  eachAbility(src, function(id, row)
    local key = pet and ("pet:" .. pet .. ":" .. tostring(id)) or id
    local d = dst[key]
    if not d then
      d = { id = key, name = pet and (pet .. ": " .. (row.name or ("Spell " .. tostring(id)))) or row.name,
            amount = 0, over = 0,
            hits = 0, crits = 0, misses = 0,
            max = 0, min = nil, critAmount = 0 }
      if pet then d.baseId = id end
      dst[key] = d
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

--- Add what a report claims beyond what this client measured, if anything.
local function fillGap(view, row, field, claimed, measured)
  local gap = (claimed or 0) - (measured or 0)
  if gap <= 0 then return false end
  row[field] = (row[field] or 0) + gap
  view.totals[field] = (view.totals[field] or 0) + gap
  return true
end

--- Fold one pull's buff rows into a view row. The live pull keeps a buff
--- still running open-ended, so it is measured to the pull's own "now";
--- a stored pull has already closed every one.
---
--- Three shapes arrive here: the live pull's rows keyed by spell id, the
--- list of rows 0.4.0 and 0.4.1 stored, and since 0.4.2 one packed string
--- per actor with the names kept once per pull (see packAuras).
local function addAuras(row, auras, enc)
  if not auras then return end
  if not row.auras then row.auras = {} end
  local function add(id, name, up, applied)
    local d = row.auras[id]
    if not d then
      d = { id = id, name = name, up = 0, applied = 0 }
      row.auras[id] = d
    end
    if not d.name then d.name = name end
    d.up = d.up + up
    d.applied = d.applied + (applied or 0)
  end
  if type(auras) == "string" then
    local names = (enc and enc.auraNames) or {}
    for id, tenths, applied in string.gfind(auras, "(%d+):(%d+):(%d+)") do
      local spellId = tonumber(id)
      add(spellId, names[spellId], tonumber(tenths) / 10, tonumber(applied))
    end
  elseif auras[1] ~= nil then
    for _, au in ipairs(auras) do
      add(au.id, au.name, W.encounter:AuraSeconds(enc, au), au.applied)
    end
  else
    for id, au in pairs(auras) do
      add(id, au.name, W.encounter:AuraSeconds(enc, au), au.applied)
    end
  end
end

-- The provider's side of valueCredit, in the drilldowns: each effect's
-- worth as its own line, so the total still adds up.
local function addCredited(row, a)
  if not valueCredit() then return end
  if (a.valueAdded or 0) > 0 then addAbilities(row.dmgAbility, a.valueEffect) end
  if (a.valueHeal or 0) > 0 then
    local heals = {}
    eachAbility(a.valueSupport, function(id, r)
      if r.name == "Judgement of Light" then heals[id] = r end
    end)
    addAbilities(row.healAbility, heals)
  end
end

--[[ A row's detail -- its buffs and its per-ability tables -- is built
     the first time something asks for it, not with the row.

     Building it means copying every ability of every actor, and the meter
     rebuilds the view of a pull in progress twice a second. Over a raid
     fight that was over a megabyte of throwaway tables a second, nearly
     all of it detail that only a drilldown or the uptime metric ever reads,
     and 1.12 pays for garbage with stop-the-world collections. The row
     keeps the actors it was summed from (_src, actor and pull in pairs)
     and fills the tables in from them on first touch. ]]
local DETAIL = { auras = true, dmgAbility = true, healAbility = true,
                 takenAbility = true, consumeItem = true, dispelAbility = true,
                 valueEffect = true, valueSupport = true }

--- The pet's name when `a` is a pet folded into another's row, else nil.
local function foldedPet(row, a)
  if a.class == "PET" and a.name and row.name ~= a.name then return a.name end
  return nil
end

lazyDetail.__index = function(row, k)
  if not DETAIL[k] then return nil end
  local src = rawget(row, "_src") or {}
  setmetatable(row, nil)
  row._src = nil
  row.auras = {}
  row.dmgAbility, row.healAbility, row.takenAbility, row.consumeItem = {}, {}, {}, {}
  row.dispelAbility = {}
  row.valueEffect = {}
  row.valueSupport = {}
  for i = 1, table.getn(src), 2 do
    local a, enc = src[i], src[i + 1]
    addAuras(row, a.auras, enc)
    local pet = foldedPet(row, a)
    addAbilities(row.dmgAbility, a.dmgAbility, pet)
    addAbilities(row.healAbility, a.healAbility, pet)
    addAbilities(row.takenAbility, a.takenAbility, pet)
    addAbilities(row.consumeItem, a.consumeItem)
    addAbilities(row.dispelAbility, a.dispelAbility)
    addAbilities(row.valueEffect, a.valueEffect)
    addAbilities(row.valueSupport, a.valueSupport)
    addCredited(row, a)
  end
  return row[k]
end

local function addDetail(row, a, enc)
  local src = rawget(row, "_src")
  if not src then
    if getmetatable(row) ~= lazyDetail then
      -- Detail already built (a remote-only row touched early): add now.
      addAuras(row, a.auras, enc)
      local pet = foldedPet(row, a)
      addAbilities(row.dmgAbility, a.dmgAbility, pet)
      addAbilities(row.healAbility, a.healAbility, pet)
      addAbilities(row.takenAbility, a.takenAbility, pet)
      addAbilities(row.consumeItem, a.consumeItem)
      addAbilities(row.dispelAbility, a.dispelAbility)
      addAbilities(row.valueEffect, a.valueEffect)
      addAbilities(row.valueSupport, a.valueSupport)
      addCredited(row, a)
      return
    end
    src = {}
    row._src = src
  end
  local n = table.getn(src)
  src[n + 1] = a
  src[n + 2] = enc
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
        hpMax = d.hpMax,
        -- The death time within its own pull. t above is shifted onto the
        -- session timeline, which is right for the chart and wrong for
        -- measuring the recap lines against.
        encT = d.t,
        -- Restored and shared logs carry totals only, so no recap either;
        -- the recap should say that rather than claim nothing happened.
        noRecap = enc.imported or enc.sharedBy,
      })
    end

    -- Per pull: what THIS client measured for each row, before anyone
    -- else's report is considered. Active time and the remote fill are both
    -- settled against these once every actor is in.
    local encActive, encLocal = {}, {}

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

      row.damage = row.damage + creditedDamage(a)
      row.taken = row.taken + (a.taken or 0)
      row.healing = row.healing + creditedHealing(a)
      row.overheal = row.overheal + (a.overheal or 0)
      row.absorbed = row.absorbed + (a.absorbed or 0)
      row.deaths = row.deaths + (a.deaths or 0)
      row.dispels = row.dispels + (a.dispels or 0)
      row.interrupts = row.interrupts + (a.interrupts or 0)
      row.hits = row.hits + (a.hits or 0)
      row.crits = row.crits + (a.crits or 0)
      -- A pull saved before critHits existed counted every hit as one.
      row.critHits = row.critHits + (a.critHits or a.hits or 0)
      row.healHits = row.healHits + (a.healHits or 0)
      row.healCrits = row.healCrits + (a.healCrits or 0)
      row.misses = row.misses + (a.misses or 0)
      row.consumes = row.consumes + (a.consumes or 0)
      row.valueAdded = row.valueAdded + (a.valueAdded or 0)
      row.valueMana = row.valueMana + (a.valueMana or 0)
      row.valueHeal = row.valueHeal + (a.valueHeal or 0)
      -- In your group during this pull? (A pull from before this was kept
      -- cannot say: those fall back to the group as it is now.)
      local member = a.isPlayer and a.name or a.ownerName
      if enc.inGroup and member and enc.inGroup[member] then row.wasInGroup = true end

      --[[ Active time is NOT summed here. Two actors on one row -- an owner
           and their pet, or two whelps of one name -- acting at the same
           moment would count that moment twice, and a hunter whose pet
           never stops would read as busier than the fight was long. The
           largest single one is kept here as the fallback, and the proper
           union is applied once the pull's actors are all in. ]]
      local act = W.encounter:ActiveSeconds(enc, a)
      if act > (encActive[key] or 0) then encActive[key] = act end

      local mine = encLocal[key]
      if not mine then
        mine = { damage = 0, healing = 0, taken = 0 }
        encLocal[key] = mine
      end
      mine.damage = mine.damage + creditedDamage(a)
      mine.healing = mine.healing + creditedHealing(a)
      mine.taken = mine.taken + (a.taken or 0)

      -- Buff uptime sums across pulls the same way damage does, so "flask
      -- up for 92% of the night" is answerable rather than only per pull.
      addDetail(row, a, enc)

      -- A player row that was created by a pet first has no class yet.
      if row.class == "UNKNOWN" and a.isPlayer and a.class ~= "UNKNOWN" then
        row.class = a.class
      end
    end

    --[[ Active time, settled once per pull. Merged, a player's row takes
         the union of them and their pets that the pull recorded; separated,
         each row is a single actor anyway. Pulls stored before the union
         existed fall back to the largest single actor, which can undercount
         slightly but never counts a moment twice. ]]
    local activeAdded = {}
    for key, act in pairs(encActive) do
      if petMode == "merge" and string.sub(key, 1, 2) == "p:" then
        local g = enc.activeGroup and enc.activeGroup[string.sub(key, 3)]
        if type(g) == "table" then
          act = W.encounter:ActiveSeconds(enc, g)
        elseif type(g) == "number" then
          act = g
        end
      end
      local row = view.index[key]
      row.active = (row.active or 0) + act
      activeAdded[key] = act
    end

    --[[ Fill gaps from what other players reported about themselves.

         Strictly a gap-filler. A number measured here always wins, because
         it was observed rather than asserted, and a raider inside our combat
         log range needs no help. Where we saw LESS than they report -- the
         usual case for someone at the far end of a room -- the difference
         is added and the row is marked, so a report is never mistaken for a
         measurement.

         Per pull, never against the row. The row is the running total of
         every pull in the view; comparing one pull's report with that both
         wiped out earlier pulls (a larger report REPLACED the total) and
         missed real gaps (a smaller one was skipped). ]]
    for name, who in pairs(enc.remote or {}) do
      local rep = { damage = 0, petDamage = 0, healing = 0, taken = 0,
                    petTaken = 0, active = 0, activeOwn = 0 }
      for _, p in pairs(who.parts or {}) do
        for k in pairs(rep) do rep[k] = rep[k] + (p[k] or 0) end
      end

      -- Merged, the row holds the pets too; separated, only the player.
      local merged = (petMode == "merge")
      local key = "p:" .. name
      local mine = encLocal[key] or { damage = 0, healing = 0, taken = 0 }
      local row = view.index[key]
      if not row then
        row = blankRow({ name = name, class = who.class, isPlayer = true }, key)
        view.index[key] = row
        table.insert(view.rows, row)
      end

      local d = fillGap(view, row, "damage",
        merged and (rep.damage + rep.petDamage) or rep.damage, mine.damage)
      local h = fillGap(view, row, "healing", rep.healing, mine.healing)
      local t = fillGap(view, row, "taken",
        merged and (rep.taken + rep.petTaken) or rep.taken, mine.taken)

      local claimActive = merged and rep.active or rep.activeOwn
      local gapActive = claimActive - (activeAdded[key] or 0)
      if gapActive > 0 then row.active = (row.active or 0) + gapActive end

      if d or h or t then
        row.remote = true
        if row.class == "UNKNOWN" and who.class then row.class = who.class end
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

--[[ Picked players: the characters someone chose to follow.

     One list, shared by the meter and the report and kept across sessions:
     "the people I care about" is the same question in both windows and on
     the next raid night. Whether a window shows ONLY them is that window's
     own switch, the way group-only is. ]]
function R:Picked()
  if not W.db.picked then W.db.picked = {} end
  return W.db.picked
end

function R:IsPicked(name)
  return name ~= nil and self:Picked()[name] == true
end

function R:AnyPicked()
  return next(self:Picked()) ~= nil
end

function R:TogglePick(name)
  if not name or name == "" or name == "?" then return end
  local picked = self:Picked()
  if picked[name] then picked[name] = nil else picked[name] = true end
end

function R:ClearPicks()
  W.db.picked = {}
end

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
       group", and filtering them here would empty the Enemies tab.

       In your group during the pulls shown, OR in it now. Read only live,
       two healers who left after Molten Core (10/20) vanished from every
       pull they had healed; read only from the pulls, someone invited
       since would. Each pull keeps who was in the group while they took
       part (inGroup); a pull from before that was kept uses the live group
       alone, as it always did. ]]
  if filter.groupOnly then
    local who = row.ownerName or row.name
    if (row.isPlayer or row.class == "PET") and not row.wasInGroup and not W.capture:InGroup(who) then
      return false
    end
  end

  --[[ Only the players someone picked. The same reach as group-only:
       players and their pets, never enemies, since picking characters is a
       choice about your own side and applying it to enemies would empty the
       Enemies tab. A pet follows its owner. An empty list filters nothing:
       a filter that hides everyone is never what was meant. ]]
  if filter.only and next(filter.only) ~= nil then
    local who = row.ownerName or row.name
    if (row.isPlayer or row.class == "PET") and not filter.only[who] then
      return false
    end
  end

  return true
end

--- Produce the ranked, filtered rows for a metric.
--- Each returned row carries _v (the ranked number), _rank, _pct (share of
--- the visible total) and _frac (bar length, 0..1 against the leader).
--[[ Raid value by EFFECT rather than by player: each effect's total over
     the view, and who added how much of it, biggest first. key is "value"
     (damage) or "support" (mana and healing). Used by the report's Raid
     Contrib tab and by announcing raid value. ]]
function R:Effects(view, key, filter)
  local rows = self:Rank(view, key, filter)
  local detail = (key == "support") and "valueSupport" or "valueEffect"
  local byName, order = {}, {}
  for _, r in ipairs(rows) do
    local who, class = r.name or "?", r.class
    eachAbility(r[detail], function(id, a)
      local amount = a.amount or 0
      if amount > 0 and a.name then
        local e = byName[a.name]
        if not e then
          e = { name = a.name, total = 0, players = {}, kind = key }
          byName[a.name] = e
          table.insert(order, e)
        end
        e.total = e.total + amount
        table.insert(e.players, { name = who, class = class, amount = amount })
      end
    end)
  end
  local byAmount = function(x, y) return x.amount > y.amount end
  for _, e in ipairs(order) do table.sort(e.players, byAmount) end
  table.sort(order, function(x, y) return x.total > y.total end)
  return order
end

--[[ The Raid Contrib list -- the report's tab, the meter's view and their
     announcements: the damage effects (Raid value), then what the
     judgements give back (Raid support). ]]
function R:ContribEffects(view, filter)
  local out = {}
  for _, e in ipairs(self:Effects(view, "value", filter)) do table.insert(out, e) end
  for _, e in ipairs(self:Effects(view, "support", filter)) do table.insert(out, e) end
  return out
end

--- Every player in the view the filter lets through, by name: the
--- consumables export lists the ones who used nothing too.
function R:Players(view, filter)
  local out = {}
  for _, row in ipairs(view.rows or {}) do
    if row.isPlayer and matches(row, filter) then table.insert(out, row) end
  end
  table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
  return out
end

--- What a support effect's number counts: mana for Wisdom, else healing.
function R.EffectUnit(e)
  if not e or e.kind ~= "support" then return "" end
  return e.name == "Judgement of Wisdom" and " mana" or " heal"
end

--- The view's deaths in the order they happened: the report's Deaths tab,
--- the meter's Death log and their announcements.
function R:DeathList(view)
  local out = {}
  for _, d in ipairs(view.deaths or {}) do table.insert(out, d) end
  table.sort(out, function(a, b) return (a.t or 0) < (b.t or 0) end)
  return out
end

--- A recap row's value, coloured for the windows (never for chat): hits
--- red, heals green, avoided grey, the summary in the accent.
local RECAP_HUE = { d = "ff6b6b", h = "5fd36a", m = "9d9d9d", sum = "e0a22c" }
function R.RecapValue(st)
  local hue = st and RECAP_HUE[st.kind or ""]
  if not hue or not st.value or st.value == "" then return st and st.value or "" end
  return "|cff" .. hue .. st.value .. "|r"
end

--- One death, by a key that survives the view being rebuilt.
function R.DeathKey(d)
  return tostring(d.name) .. ":" .. tostring(d.t)
end

function R:Rank(view, metricKey, filter)
  local metric = W.metrics.Get(metricKey)
  local ctx = { duration = view.rateBase, view = view }

  local out = {}
  for _, row in ipairs(view.rows) do
    local wantEnemy = (metric.side == "enemy")
    local isEnemy = (not row.isPlayer) and row.class ~= "PET"
    if wantEnemy == isEnemy then
      row._v = metric.value(row, ctx) or 0
      -- Zero rows are normally noise, but not always: when ranking one
      -- buff, the players WITHOUT it are the answer to the question.
      local keep = row._v > 0 or (metric.keepZero and metric.keepZero(row, ctx))
      if keep and matches(row, filter) then
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
    -- Kept on the row so a drilldown asked for later, with only the row in
    -- hand, still measures against the same view.
    row._ctx = ctx
  end

  return out, metric, total, ctx
end

----------------------------------------------------------------------
-- ability drilldown
----------------------------------------------------------------------

--[[ A player's buffs, shaped like ability rows so the same lists can show
     them -- but with the value written out, because seconds are not what
     anyone wants to read. The share of the fight is. ]]
function R:Auras(row, ctx)
  local base = (ctx and ctx.view and ctx.view.duration) or 0
  local out = {}
  for id, au in pairs(row.auras or {}) do
    local up = au.up or 0
    if up > 0 then
      local pct = base > 0 and (up / base * 100) or 0
      if pct > 100 then pct = 100 end
      local applied = au.applied or 0
      table.insert(out, {
        id = id, name = au.name or ("Spell " .. tostring(id)),
        label = au.name or ("Spell " .. tostring(id)),
        amount = up, up = up, applied = applied,
        hits = 0, crits = 0, _critPct = 0,
        _pct = pct,
        _value = string.format("%.0f%%", pct),
        _note = W.Duration(up) .. (applied > 1 and ("  " .. applied .. "x") or ""),
        -- Clicking one ranks everybody by it; see W.metrics.SelectBuff.
        _select = true,
        _selected = (W.db and W.db.uptimeSpell == id) or false,
      })
    end
  end
  table.sort(out, W.ByField("amount"))
  local top = out[1] and out[1].amount or 0
  local total = 0
  for _, a in ipairs(out) do
    total = total + a.amount
    a._frac = top > 0 and (a.amount / top) or 0
  end
  return out, total
end

--- Rows for one actor's ability breakdown under the given metric.
function R:Abilities(row, metricKey, ctx)
  local metric = W.metrics.Get(metricKey)
  if metric.detail == "auras" then return self:Auras(row, ctx or row._ctx) end
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
    local school = W.SchoolName(a.school, a.baseId or id)

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

  --[[ Priced (Consumes (gold)): each item by what it cost, "3 x 1g 20s"
       beside it, the dearest first. The bar is the cost too, so one flask
       outweighs a stack of cheap food the way it does in the bank. ]]
  if metric.priced and W.prices then
    local costTotal, costTop = 0, 0
    for _, a in ipairs(out) do
      local each = W.prices:Value(a.id)
      a._cost = each and (each * a.amount) or 0
      a._value = each and W.Money(a._cost) or "no price"
      a._note = a.amount .. " x " .. (each and W.Money(each) or "?")
      costTotal = costTotal + a._cost
      if a._cost > costTop then costTop = a._cost end
    end
    table.sort(out, function(x, y)
      if x._cost ~= y._cost then return x._cost > y._cost end
      return x.amount > y.amount
    end)
    for _, a in ipairs(out) do
      a._frac = costTop > 0 and (a._cost / costTop) or 0
      a._pct = costTotal > 0 and (a._cost / costTotal * 100) or 0
    end
    return out, costTotal
  end
  return out, total
end

--[[ What killed someone, as lines.

     The question after a wipe is never "who died" -- the raid watched that
     happen. It is what the last few seconds looked like, which is why every
     meter people rate has a version of this, and why it is the feature they
     name first when asked what they use.

     Oldest first, so it reads as a sequence rather than a list. ]]
local function sharesText(by, order, total)
  table.sort(order, function(x, y) return by[x] > by[y] end)
  local parts = {}
  for i = 1, 3 do
    local who = order[i]
    if not who then break end
    table.insert(parts, who .. " " .. W.Short(by[who]))
  end
  if table.getn(order) > 3 then table.insert(parts, "+" .. (table.getn(order) - 3) .. " more") end
  return table.concat(parts, ", ")
end

--[[ Rows open with what the seconds add up to (kind "sum"): what killed
     them, the damage they took and from whom, the healing that reached
     them and from whom -- "how did they die" in three lines, before the
     sequence that shows it. Then every event (kind "d" a hit, "h" a heal,
     "m" a hit they avoided), each with their health after it. Recaps saved
     before heals were kept read as hits, which is all they held. ]]
function R:DeathRecap(death)
  local rows = {}
  if not death then return rows end

  -- Each line carries its distance from the death. Recaps from before that
  -- only carry their time within the pull, and are measured against the
  -- death's time in that same pull -- never its session timeline time,
  -- which is off by however far into the night the pull was.
  local last = death.encT or death.t or 0
  local recap = death.recap or {}
  local function hpText(hp)
    if not hp then return nil end
    local max = death.hpMax
    if max and max > 0 then return string.format("hp %s (%d%%)", W.Short(hp), math.floor(hp / max * 100 + 0.5)) end
    return "hp " .. W.Short(hp)
  end

  local killer
  local took, healed, span = 0, 0, 0
  local dmgBy, dmgOrder, healBy, healOrder = {}, {}, {}, {}
  for _, e in ipairs(recap) do
    local kind = e.k or "d"
    local who = e.src or "?"
    local ago = e.ago or (last - (e.t or 0))
    if ago > span then span = ago end
    if kind == "d" then
      killer = e
      took = took + (e.a or 0)
      if not dmgBy[who] then dmgBy[who] = 0 table.insert(dmgOrder, who) end
      dmgBy[who] = dmgBy[who] + (e.a or 0)
    elseif kind == "h" and (e.a or 0) > 0 then
      healed = healed + e.a
      if not healBy[who] then healBy[who] = 0 table.insert(healOrder, who) end
      healBy[who] = healBy[who] + e.a
    end
  end
  local secs = string.format("%.0fs", math.ceil(span))
  if killer then
    local what = killer.src or "?"
    if killer.spell and killer.spell ~= "" then what = what .. " (" .. killer.spell .. ")" end
    table.insert(rows, { kind = "sum", label = "Killed by " .. what, value = W.Comma(killer.a or 0) })
    table.insert(rows, { kind = "sum", label = "Took in the last " .. secs .. ": " .. sharesText(dmgBy, dmgOrder),
                         value = W.Short(took) })
    if healed > 0 then
      table.insert(rows, { kind = "sum", label = "Healed in the last " .. secs .. ": " .. sharesText(healBy, healOrder),
                           value = W.Short(healed) })
    else
      table.insert(rows, { kind = "sum", label = "No healing reached them in the last " .. secs, value = "0" })
    end
  end

  for _, e in ipairs(recap) do
    local kind = e.k or "d"
    local ago = e.ago or (last - (e.t or 0))
    local who = e.src or "?"
    if e.spell and e.spell ~= "" and e.spell ~= "Melee" then
      who = who .. "  " .. e.spell
    end
    local value
    if kind == "h" then
      value = "+" .. W.Comma(e.a or 0)
      if (e.x or 0) > 0 then value = value .. " (" .. W.Short(e.x) .. " over)" end
    elseif kind == "m" then
      value = e.x or "missed"
    else
      value = "-" .. W.Comma(e.a or 0)
    end
    if e.crit then value = value .. " crit" end
    table.insert(rows, {
      kind = kind,
      label = string.format("-%.1fs  %s", ago, who),
      value = value,
      note = hpText(e.hp),
    })
  end

  if table.getn(rows) == 0 then
    local why = "nothing was recorded in the seconds before this"
    if death.noRecap then why = "restored and shared logs keep totals, not recaps" end
    table.insert(rows, {
      label = why,
      value = "",
    })
  end
  return rows
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
function R:AbilityStats(a, metricKey)
  if not a then return {} end
  local metric = W.metrics.Get(metricKey)
  if metric.detail == "auras" then
    return {
      { label = "Uptime", value = a._value or "" },
      { label = "Time up", value = W.Duration(a.up or 0) },
      { label = "Applied", value = tostring(a.applied or 0) .. "x" },
    }
  end
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

  --[[ The axis starts where the first chosen pull starts, not where the
       night did. One pull picked out of a long session used to sit at the
       far right of an axis hours wide, squeezed to a sliver; now it fills
       the chart and second 0 is its pull. Several pulls keep their places
       relative to each other. The shift is returned so whatever is drawn
       alongside (deaths) can be moved by the same amount. ]]
  local base
  for _, enc in ipairs(encounters) do
    local o = math.floor(enc.offset or 0)
    if not base or o < base then base = o end
  end
  base = base or 0

  for _, enc in ipairs(encounters) do
    local off = math.floor(enc.offset or 0) - base
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

  return series, maxT + 1, peak, detail, base
end

----------------------------------------------------------------------
-- caching
----------------------------------------------------------------------

--[[ View and Series over a set of finished pulls give the same answer
     every time they are asked, and asking is expensive: over a long
     session it is tens of milliseconds and megabytes of throwaway tables,
     and Lua 5.0 pays for that garbage with a stop-the-world collection.
     Opening the report, switching a tab or clicking a pull all asked
     again, so a busy evening made the window hitch harder each time.

     A cache remembers the last answer per question, keyed by a fingerprint
     of the pulls: the list itself (compared entry by entry), each pull's
     totals, and `rev`, which the paths that change a stored pull without
     touching its totals bump. A pull still being recorded is never cached.
     Anything the fingerprint cannot see calls R:Invalidate.

     Each window keeps its own cache. Rank writes its scratch fields onto
     the rows it ranks, so two windows sharing one view would repaint each
     other's numbers. ]]
R.gen = 0

--- Drop every cached answer, for changes the fingerprint cannot see.
function R:Invalidate()
  self.gen = self.gen + 1
end

local Cache = {}
Cache.__index = Cache

--- A new, empty cache. One per window.
function R:NewCache()
  return setmetatable({ slots = {} }, Cache)
end

-- The fingerprint's running sum, or nil if a pull is still live.
local function fingerprint(encounters)
  local live = W.encounter and W.encounter.live
  local held = W.encounter and W.encounter.heldPull
  local sum = 0
  for i = 1, table.getn(encounters) do
    local e = encounters[i]
    if e == live or e == held then return nil end
    local t = e.totals
    sum = sum + (e.rev or 0)
    if t then sum = sum + (t.damage or 0) + (t.healing or 0) + (t.taken or 0) end
  end
  return sum
end

local function sameList(a, b)
  local n = table.getn(a)
  if n ~= table.getn(b) then return false end
  for i = 1, n do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- Answer from slot `slot` (asked with options `optsKey`), or
-- build it with `make` and remember it.
function Cache:Get(slot, optsKey, encounters, make)
  local sum = fingerprint(encounters)
  if not sum then
    self.slots[slot] = nil
    return make()
  end
  local basis = ((W.db and W.db.dpsBasis) or "combat") .. (valueCredit() and "+credit" or "")
  local c = self.slots[slot]
  if c and c.gen == R.gen and c.sum == sum and c.opts == optsKey
     and c.basis == basis and sameList(c.list, encounters) then
    return unpack(c.result)
  end
  -- Copy the list: callers may reuse and refill theirs.
  local list = {}
  for i = 1, table.getn(encounters) do list[i] = encounters[i] end
  local result = { make() }
  self.slots[slot] = { gen = R.gen, sum = sum, opts = optsKey, basis = basis,
    list = list, result = result }
  return unpack(result)
end

--- R:View through the cache.
function Cache:View(encounters, opts)
  local key = ((opts and opts.petMode) or "merge") .. "/" .. ((opts and opts.enemyBy) or "name")
  return self:Get("view", key, encounters, function() return R:View(encounters, opts) end)
end

--- R:Series through the cache.
function Cache:Series(encounters, windowSec)
  return self:Get("series", tostring(windowSec or 3), encounters,
    function() return R:Series(encounters, windowSec) end)
end

--- Forget everything in this cache.
function Cache:Clear()
  self.slots = {}
end

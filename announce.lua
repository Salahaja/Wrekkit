--[[ Wrekkit :: announce

Posting a summary to chat. Three rules shape this module:

  1. It reports what is ON SCREEN. The metric, the encounter selection and
     the active filters all come from whichever window asked, so what people
     read in chat is what you were looking at -- never a different query that
     happens to share a name.

  2. Nothing is sent without confirmation. Chat is irreversible and public;
     a mis-aimed raid post cannot be taken back. Every path builds the exact
     lines first, shows them next to the destination, and only sends on an
     explicit yes.

  3. Filters are disclosed. A top-5 that silently excluded half the raid is
     worse than no post at all, so an active filter is stated in the header.

Sending is paced through the same kind of queue as addon sync: the client
throttles outgoing chat, and dumping ten lines in one frame risks being
dropped or disconnected.
]]

local W = Wrekkit
W.announce = {}
local A = W.announce

local SEND_INTERVAL = 0.4   -- seconds between chat lines

--[[ The server's flood guard: about ten messages, each sent soon after the
     one before, and it flags you as spamming (10/28: a top 10 -- twelve
     messages, SEND_INTERVAL apart -- set it off; ShaguDPS's report, nine
     messages at once, never has). So a post goes out BURST messages at a
     time, and the rest wait for BURST_PAUSE of quiet, by which time the
     guard has let go. Joined into fewer messages (A:Pack), a post rarely
     needs the pause. ]]
A.BURST = 8
A.BURST_PAUSE = 6
local MAX_LINES = 15        -- hard ceiling regardless of what is asked for

----------------------------------------------------------------------
-- channels
----------------------------------------------------------------------

--- Availability is checked so the menu can grey out what cannot work --
--- posting to RAID while solo is an error, not a no-op.
A.channels = {
  { key = "SAY", label = "Say",
    available = function() return true end },
  { key = "PARTY", label = "Party",
    available = function()
      return (GetNumPartyMembers() or 0) > 0 or (GetNumRaidMembers() or 0) > 0
    end },
  { key = "RAID", label = "Raid",
    available = function() return (GetNumRaidMembers() or 0) > 0 end },
  { key = "GUILD", label = "Guild",
    available = function() return IsInGuild and IsInGuild() end },
  { key = "WHISPER", label = "Whisper...", needsTarget = true,
    available = function() return true end },
}

function A:Channel(key)
  for _, c in ipairs(self.channels) do
    if c.key == key then return c end
  end
  return nil
end

function A:Available(key)
  local c = self:Channel(key)
  return c and c.available() and true or false
end

----------------------------------------------------------------------
-- building the message
----------------------------------------------------------------------

--[[ ctx describes the view being announced:
       metrics    array of metric keys (the report's Summary sends two)
       encounters the records to merge
       label      what to call them ("Onyxia", "All Session", ...)
       filter     { search, groupOnly } as passed to Rank
       petMode    "merge" or "separate"
]]

local function filterNote(ctx)
  local bits = {}
  local f = ctx.filter or {}
  if f.groupOnly then table.insert(bits, "group only") end
  if f.only and next(f.only) ~= nil then table.insert(bits, "picked players") end
  if f.search and f.search ~= "" then
    table.insert(bits, "name: " .. f.search)
  end
  if (ctx.petMode or "merge") ~= "merge" then
    table.insert(bits, "pets split")
  end
  if table.getn(bits) == 0 then return "" end
  return "  [" .. table.concat(bits, ", ") .. "]"
end

--- Build the lines exactly as they will be sent.
--[[ The two drilled-in views, rendered exactly as the window shows them.

     Level one is which abilities made up one player's number; level two is
     the spread for a single ability -- hits, crits, misses, averages and
     range. Returns nil when the drill target no longer exists, so the
     caller falls back to the ranking rather than announcing nothing. ]]
function A:DrillLines(ctx, view, count)
  local metricKey = ctx.metric or (ctx.metrics and ctx.metrics[1]) or "damage"
  local rows, metric = W.report:Rank(view, metricKey, ctx.filter)

  local target
  for _, r in ipairs(rows) do
    if r.key == ctx.drill then target = r end
  end
  if not target then return nil end

  local abilities = W.report:Abilities(target, metricKey)

  -- Level two: one ability's spread.
  if ctx.drillAbility then
    local ability
    for _, a in ipairs(abilities) do
      if a.id == ctx.drillAbility then ability = a end
    end
    if ability then
      local out = {
        string.format("Wrekkit  %s - %s, %s (%s)%s",
          target.name or "?", ability.name or "?", W.metrics.Label(metric),
          W.Duration(view.rateBase), filterNote(ctx)),
      }
      for _, st in ipairs(W.report:AbilityStats(ability, metricKey)) do
        local note = st.note
        if note and note ~= "" then note = "  (" .. note .. ")" else note = "" end
        table.insert(out, string.format("  %s  %s%s", st.label, st.value, note))
      end
      return out
    end
  end

  -- Level one: the abilities behind that player's number.
  local out = {
    string.format("Wrekkit  %s - %s (%s)%s",
      target.name or "?", W.metrics.Label(metric), W.Duration(view.rateBase),
      filterNote(ctx)),
  }
  if table.getn(abilities) == 0 then
    table.insert(out, "  " .. W.report:EmptyDetailNote(view))
    return out
  end

  for i = 1, count do
    local a = abilities[i]
    if not a then break end
    table.insert(out, string.format("%d. %s  %s", i, a.name,
      W.Short(a.amount or 0)))
  end
  local extra = table.getn(abilities) - count
  if extra > 0 then
    table.insert(out, string.format("  ...and %d more", extra))
  end
  return out
end

--[[ Raid value and Raid support, announced by EFFECT rather than by player:
     what Sunder, the curses, Windfury... added over the pulls on show.

     Several players often build one effect -- warriors stacking Sunder,
     priests stacking Shadow Weaving, warlocks taking turns on a curse -- so
     W.db.valueAnnounce picks how it is told:
       combined     (the default) each effect's total and how many players
                    built it, no names: nobody is singled out for an effect
                    the raid made together
       individual   each effect's total, then who added how much of it
     Estimates say so, as they do on screen. ]]
local NAMES_PER_LINE = 4

local function supportUnit(name)
  if name == "Judgement of Wisdom" then return " mana" end
  return " healing"
end

--[[ What an effect's number is, in words: "22.8k" on its own in chat left
     people asking. Raid value is the damage an effect added to everyone's
     hits; support is the mana or healing a judgement gave back. ]]
local function effectUnit(e)
  if e.kind == "support" then return supportUnit(e.name) end
  return " damage"
end

--- Every effect, damage then support, as the report's Raid Contrib tab
--- lists them.
local function allEffects(view, filter)
  return W.report:ContribEffects(view, filter)
end

--[[ How raid value is told: ctx.valueMode when the announcement picked one
     (the Raid Contrib tab offers both), else the "Announce raid value"
     setting. "individual" names who added each effect; "combined" only
     says how many players built it. ]]
local function individualMode(ctx)
  local mode = ctx.valueMode or (W.db and W.db.valueAnnounce)
  return mode == "individual"
end

--- One effect, everyone who built it -- the Raid Contrib tab drilled in.
function A:EffectLines(ctx, view, count, name)
  local target
  for _, e in ipairs(allEffects(view, ctx.filter)) do
    if e.name == name then target = e end
  end
  if not target then return nil end
  local unit = effectUnit(target)
  local n = table.getn(target.players)
  local out = {
    string.format("Wrekkit  %s - %s (%s): added %s%s, from %d player%s%s", target.name, ctx.label or "?",
      W.Duration(view.rateBase), W.Short(target.total), unit, n, n == 1 and "" or "s", filterNote(ctx)),
  }
  for i = 1, count do
    local p = target.players[i]
    if not p then break end
    local pct = target.total > 0 and p.amount / target.total * 100 or 0
    table.insert(out, string.format("%d. %s  +%s%s (%.1f%%)", i, p.name, W.Short(p.amount), unit, pct))
  end
  if n > count then table.insert(out, string.format("  ...and %d more", n - count)) end
  if string.find(target.name, "(est.)", 1, true) then table.insert(out, "  (est.) = estimated") end
  return out
end

--[[ The Raid Contrib tab's list, fitted to `count` lines: the damage
     effects, but with room kept at the end for what the judgements give
     back -- otherwise a long list never reaches them. Returns the lines'
     effects and how many effects there were in all. ]]
local function contribOrder(view, filter, count)
  local dmg = W.report:Effects(view, "value", filter)
  local sup = W.report:Effects(view, "support", filter)
  local keep = table.getn(sup)
  if keep > 2 then keep = 2 end
  if keep > count - 1 then keep = count - 1 end
  if keep < 0 then keep = 0 end
  local out = {}
  for i = 1, count - keep do
    if not dmg[i] then break end
    table.insert(out, dmg[i])
  end
  for i = 1, count - table.getn(out) do
    if not sup[i] then break end
    table.insert(out, sup[i])
  end
  return out, table.getn(dmg) + table.getn(sup)
end

function A:ValueLines(ctx, view, count, key)
  local metric = W.metrics.Get(key)
  local order, all
  if ctx.contrib then
    order, all = contribOrder(view, ctx.filter, count)
  else
    order = W.report:Effects(view, key, ctx.filter)
    all = table.getn(order)
  end

  local individual = individualMode(ctx)
  local what = (ctx.contrib and "what each buff, debuff and judgement added")
    or (key == "support" and "the mana and healing judgements gave back")
    or "the extra damage each buff and debuff added"
  local out = {
    string.format("Wrekkit  %s - %s (%s): %s%s", ctx.contrib and "Raid contribution" or W.metrics.Label(metric),
      ctx.label or "?", W.Duration(view.rateBase), what, filterNote(ctx)),
  }
  if table.getn(order) == 0 then
    table.insert(out, "  nothing recorded")
    return out
  end

  local estimated = false
  for i = 1, count do
    local e = order[i]
    if not e then break end
    if string.find(e.name, "(est.)", 1, true) then estimated = true end
    local unit = effectUnit(e)
    local n = table.getn(e.players)
    if individual then
      local who = {}
      for j = 1, NAMES_PER_LINE do
        local pl = e.players[j]
        if not pl then break end
        table.insert(who, pl.name .. " " .. W.Short(pl.amount))
      end
      if n > NAMES_PER_LINE then table.insert(who, "+" .. (n - NAMES_PER_LINE) .. " more") end
      table.insert(out, string.format("%d. %s  +%s%s: %s", i, e.name, W.Short(e.total), unit,
        table.concat(who, ", ")))
    else
      table.insert(out, string.format("%d. %s  +%s%s  (%d player%s)", i, e.name, W.Short(e.total),
        unit, n, n == 1 and "" or "s"))
    end
  end
  local shown = table.getn(order) < count and table.getn(order) or count
  local extra = all - shown
  if extra > 0 then
    table.insert(out, string.format("  ...and %d more", extra))
  end
  if estimated then table.insert(out, "  (est.) = estimated") end
  return out
end

--[[ The death log, as the report's Deaths tab and the meter's Death log
     show it: who died, when, in which pull. Opened on one death
     (ctx.deathDrill), the blows before it, the killing one last -- the
     last `count` of them. ]]
function A:DeathLines(ctx, view, count)
  local deaths = W.report:DeathList(view)
  if ctx.deathDrill then
    local target
    for _, d in ipairs(deaths) do
      if W.report.DeathKey(d) == ctx.deathDrill then target = d end
    end
    if target then
      local out = {
        string.format("Wrekkit  %s died at %s - %s", target.name or "?", W.Clock(target.t or 0),
          target.encounter or ctx.label or "?"),
      }
      local recap = W.report:DeathRecap(target)
      local events = {}
      for _, st in ipairs(recap) do
        local note = (st.note and st.note ~= "") and ("  (" .. st.note .. ")") or ""
        local value = (st.value and st.value ~= "") and ("  " .. st.value) or ""
        local line = "  " .. st.label .. value .. note
        -- The summary always goes; of the events, the last `count`.
        if st.kind == "sum" then table.insert(out, line) else table.insert(events, line) end
      end
      local first = table.getn(events) - count + 1
      if first < 1 then first = 1 end
      for i = first, table.getn(events) do table.insert(out, events[i]) end
      return out
    end
  end

  local n = table.getn(deaths)
  local out = {
    string.format("Wrekkit  Deaths - %s: %d", ctx.label or "?", n),
  }
  if n == 0 then
    table.insert(out, "  nobody died")
    return out
  end
  for i = 1, count do
    local d = deaths[i]
    if not d then break end
    table.insert(out, string.format("%d. %s  %s  (%s)", i, d.name or "?", W.Clock(d.t or 0),
      d.encounter or "?"))
  end
  if n > count then table.insert(out, string.format("  ...and %d more", n - count)) end
  return out
end

--- `cap` raises the MAX_LINES ceiling, for an export: a file is not chat.
function A:Lines(ctx, count, cap)
  count = count or (W.db and W.db.announceCount) or 5
  if count > (cap or MAX_LINES) then count = cap or MAX_LINES end
  if count < 1 then count = 1 end

  local encounters = ctx.encounters or {}
  local view = W.report:View(encounters, { petMode = ctx.petMode or "merge" })
  local metrics = ctx.metrics
  if not metrics then metrics = { ctx.metric or "damage" } end

  --[[ Rule 1 of this module is that it reports what is ON SCREEN, and a
       drilldown is on screen. Announcing the ranking behind it while the
       user is looking at one player's abilities would post something they
       are not reading, which is the exact failure the rule exists to stop.

       A drill is a single view by definition, so the metric selection does
       not apply to it. ]]
  if ctx.drill then
    local drilled = self:DrillLines(ctx, view, count)
    if drilled then return drilled end
  end

  -- The Deaths tab and the meter's Death log: the list, or one death.
  if ctx.deaths then
    return self:DeathLines(ctx, view, count)
  end

  -- The Raid Contrib tab drilled into one effect: who built it.
  if ctx.contribEffect then
    local lines = self:EffectLines(ctx, view, count, ctx.contribEffect)
    if lines then return lines end
  end
  -- Raid value and support say what each effect added, not who ranked.
  if table.getn(metrics) == 1 and (metrics[1] == "value" or metrics[1] == "support") then
    return self:ValueLines(ctx, view, count, metrics[1])
  end

  local out = {}

  for _, key in ipairs(metrics) do
    local rows, metric, total = W.report:Rank(view, key, ctx.filter)

    table.insert(out, string.format("Wrekkit  %s - %s (%s)%s",
      W.metrics.Label(metric), ctx.label or "?", W.Duration(view.rateBase), filterNote(ctx)))

    if table.getn(rows) == 0 then
      table.insert(out, "  nothing recorded")
    else
      for i = 1, count do
        local r = rows[i]
        if not r then break end
        local sub = r._sub
        if sub and sub ~= "" then sub = "  (" .. sub .. ")" else sub = "" end
        table.insert(out, string.format("%d. %s  %s%s", i, r.name, r._text, sub))
      end

      -- Say what was left out, so a top-5 never reads as the whole list.
      local extra = table.getn(rows) - count
      if extra > 0 then
        table.insert(out, string.format("  ...and %d more", extra))
      end
    end
  end

  return out
end

--[[ 1.12 chat has no line break: each line is a message of its own, and
     each one waits its turn through the chat throttle. Packed (the
     announcement's "Fewer messages", W.db.announcePack), a post's lines
     are joined with " / " as many to a message as fit its 255 characters,
     each heading starting a new one -- a top 5 in one message, not six. ]]
A.MAX_MSG = 255
local PACK_SEP = " / "

function A:Pack(lines)
  local out, cur = {}, nil
  for _, l in ipairs(lines or {}) do
    local text = string.gsub(l, "^%s+", "")
    local heading = string.find(text, "^Wrekkit  ")
    if cur and (heading or string.len(cur) + string.len(PACK_SEP) + string.len(text) > A.MAX_MSG) then
      table.insert(out, cur)
      cur = nil
    end
    cur = cur and (cur .. PACK_SEP .. text) or text
  end
  if cur then table.insert(out, cur) end
  return out
end

--- One-line description of where this is going, for the confirmation.
function A:Destination(channel, target)
  if channel == "WHISPER" then
    return "whisper to " .. (target and target ~= "" and target or "?")
  end
  local c = self:Channel(channel)
  return (c and string.lower(c.label) or string.lower(channel or "?")) .. " chat"
end

----------------------------------------------------------------------
-- sending
----------------------------------------------------------------------

A.queue = {}

--- Seconds until the next chat line may go out: 0 for now, or the rest of
--- the pause once BURST have gone out together.
function A:SendWait(now)
  if now - (self.lastSentAt or -1000) >= A.BURST_PAUSE then self.burst = 0 end
  if (self.burst or 0) < A.BURST then return 0 end
  return self.lastSentAt + A.BURST_PAUSE - now
end

function A:Pump()
  if self.pumping then return end
  self.pumping = true

  local function step()
    if not self.queue[1] then
      self.pumping = false
      return
    end
    local wait = self:SendWait(GetTime())
    if wait > 0 then
      W.After(wait + 0.05, step, "announcePump")
      return
    end
    local job = table.remove(self.queue, 1)
    if SendChatMessage then
      -- Guarded: a bad channel (left the raid mid-send) must not take the
      -- rest of the queue down with it.
      W.Guard("announce send", function()
        SendChatMessage(job.msg, job.channel, nil, job.target)
      end)
    end
    self.burst = (self.burst or 0) + 1
    self.lastSentAt = GetTime()
    W.After(SEND_INTERVAL, step, "announcePump")
  end

  step()
end

--- Queue pre-built lines. Callers must have confirmed first.
function A:Send(lines, channel, target)
  if not lines or table.getn(lines) == 0 then return 0 end
  if channel == "WHISPER" and (not target or target == "") then
    W.Print("whisper needs a name.")
    return 0
  end

  for _, msg in ipairs(lines) do
    table.insert(self.queue, { msg = msg, channel = channel, target = target })
  end
  self:Pump()
  return table.getn(lines)
end

----------------------------------------------------------------------
-- the confirmed flow
----------------------------------------------------------------------

--[[ Ask, then send. This is the ONLY entry point the UI uses -- there is no
     "just send it" path to reach by accident, which is the whole point. ]]
function A:Request(ctx, channel, target, count)
  local lines = self:Lines(ctx, count)
  if table.getn(lines) == 0 then
    W.Print("nothing to announce.")
    return
  end

  if not self:Available(channel) then
    W.Print("you are not in a " .. string.lower(channel or "?") .. " to post to.")
    return
  end

  -- No dialog, no send. If the confirmation UI is missing for any reason,
  -- that must fail closed rather than quietly posting to chat unasked.
  if not (W.ui and W.ui.ConfirmAnnounce) then
    W.Print("the confirmation dialog is unavailable, so nothing was sent.")
    return
  end

  -- The dialog can change what is posted, so it hands back the final
  -- lines rather than us closing over the ones we built.
  ctx.count = count
  W.ui.ConfirmAnnounce(lines, channel, target, function(finalTarget, finalLines)
    local n = A:Send(finalLines or lines, channel, finalTarget)
    W.Print("sent " .. n .. " message" .. (n == 1 and "" or "s") .. " to " ..
      A:Destination(channel, finalTarget) .. ".")
  end, ctx)
end

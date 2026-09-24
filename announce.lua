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

function A:Lines(ctx, count)
  count = count or (W.db and W.db.announceCount) or 5
  if count > MAX_LINES then count = MAX_LINES end
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

function A:Pump()
  if self.pumping then return end
  self.pumping = true

  local function step()
    local job = table.remove(self.queue, 1)
    if not job then
      self.pumping = false
      return
    end
    if SendChatMessage then
      -- Guarded: a bad channel (left the raid mid-send) must not take the
      -- rest of the queue down with it.
      W.Guard("announce send", function()
        SendChatMessage(job.msg, job.channel, nil, job.target)
      end)
    end
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
    W.Print("sent " .. n .. " line" .. (n == 1 and "" or "s") .. " to " ..
      A:Destination(channel, finalTarget) .. ".")
  end, ctx)
end

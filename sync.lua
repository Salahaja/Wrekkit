--[[ Wrekkit :: sync

Peer-to-peer log sharing over the addon channel. Two directions:

  push   "/wrek share" throws the last pull at everyone in a channel
  pull   the peer browser: see who is running Wrekkit, look at what they
         have, and take only the logs you ask for

The pull direction is the useful one. Pushing a whole night at a raid is
noise; asking one person for the two pulls you missed is not.

Wire format. Every message is one addon message under the 255-byte cap, and
everything goes through one throttled queue so sharing can never contribute
to a disconnect:

  V~to~version~logCount        presence: "I run Wrekkit and have N logs"
  P~*                          discovery: "everyone announce yourselves"
  L~to                         "send me your log index"
  G~to~key~key~...             "send me these specific encounters"

  H~to~xfer~chunks~kind~meta   opens a chunked transfer (kind: enc | idx)
  D~to~xfer~seq~payload        one chunk
  E~to~xfer                    commits it

  M~*~name~class~dmg~petDmg~heal~taken~petTaken~active~activeOwn~ago~dur~pid~foe
                               live report: the sender's OWN totals for the
                               pull they are in (see S:BroadcastMine)

Every message carries an addressee as its first field -- "*" for everyone,
or a player name. That is not decoration: THIS CLIENT'S SendAddonMessage
REJECTS "WHISPER" OUTRIGHT ("Unknown addon chat type"), and passing it does
not raise a Lua error, it crashes the process with ERROR #132. There is no
directed addon channel in 1.12, so a directed message is a broadcast with a
name on it, and receivers drop anything not addressed to them.

Guildmates who are not the addressee discard the message the same way they
discard any prefix they do not recognise, so the cost is bandwidth on a
channel the user chose, not noise anyone sees.

Sharing is off until the user turns it on, and the channel is theirs to
choose: this broadcasts your name and what you have recorded, which is not
something to switch on for people.

Bodies carry actor rollups only -- no per-ability detail, no timeline. That
keeps a 25-man pull to a handful of messages; the full detail stays with
whoever recorded it, which is also the only copy that can be trusted.
]]

local W = Wrekkit
W.sync = {}
local S = W.sync

local PREFIX = "WREKKIT"
local CHUNK = 180          -- payload bytes per message, well under the cap
local SEND_INTERVAL = 0.35 -- seconds between messages
local XFER_TIMEOUT = 30    -- drop a half-received transfer after this
local PEER_TIMEOUT = 900   -- forget a peer unheard-from this long

S.queue = {}
S.incoming = {}            -- "sender:id" -> { chunks, parts, meta, at, kind }
S.peers = {}               -- name -> { name, version, logs, lastSeen, index }
S.nextId = 1

local REC, FLD = "~", ","

local function esc(s)
  return W.WireText(s)
end

local function int(n)
  return string.format("%d", math.floor(tonumber(n) or 0))
end

local function dec(n)
  return string.format("%.1f", tonumber(n) or 0)
end

-- Seconds between live reports. Thirty is what DPSMate settled on, and the
-- pacing matters for more than bandwidth: chatty addon traffic has been
-- treated as suspicious by servers before, and at least one vanilla meter
-- had to slow its sync down after players were disconnected over it.
local LIVE_INTERVAL = 30

--[[ Live totals, for the players the client will not talk about.

     The client only reports combat within CombatLogRange, so a raider on
     the far side of a room generates no events here at all. Raising the
     range fixes most of that; the rest is distance, and the only other
     source for those numbers is the player themselves.

     Each client reports ONLY ITS OWN totals, which is the whole design:

       It cannot double-count. If everyone broadcast everything they saw,
       two people watching the same hit would both report it and a merge
       would have no way to tell those apart.

       It is the authoritative copy. A player's own client sees every one of
       their own events with no range to worry about.

       It is small -- one short message per player per interval, rather than
       a roster's worth of rows.

     What arrives is a gap-filler and never an override: a locally observed
     number always wins, because it was measured here rather than asserted
     by somebody else. ]]
function S:BroadcastMine(enc)
  if not self:Enabled() then return end
  if not (W.db and W.db.liveSync) then return end

  enc = enc or W.encounter.live
  if not enc then return end

  local me = UnitName("player")
  if not me then return end

  --[[ Our own numbers and our pets' kept apart. A merged view compares a
       report against owner and pets together, a separated one against the
       owner alone; one lump sum could only ever be right for one of them. ]]
  local damage, petDamage, healing, taken, petTaken = 0, 0, 0, 0, 0
  local activeOwn = 0
  local foe, foeTaken = nil, 0
  for _, a in pairs(enc.actors or {}) do
    if a.isPlayer and a.name == me then
      damage = damage + (a.damage or 0)
      healing = healing + (a.healing or 0)
      taken = taken + (a.taken or 0)
      activeOwn = W.encounter:ActiveSeconds(enc, a)
    elseif a.class == "PET" and a.ownerName == me then
      petDamage = petDamage + (a.damage or 0)
      petTaken = petTaken + (a.taken or 0)
    elseif not a.isPlayer and a.class ~= "PET" then
      -- What this pull was about, as we saw it: the enemy that took the
      -- most. Lets a receiver tell our pull apart from someone else's.
      if (a.taken or 0) > foeTaken then foe, foeTaken = a.name, a.taken end
    end
  end
  if damage + petDamage + healing + taken <= 0 then return end

  local g = enc.activeGroup and enc.activeGroup[me]
  local active = g and W.encounter:ActiveSeconds(enc, g) or activeOwn

  --[[ When, as spans rather than times of day. "Began this long ago and
       ran this long" means the same thing on every client, where two
       clocks almost never agree. The pull id only has to tell our own
       pulls apart, so our own clock is fine for that. ]]
  local ago = GetTime() - (enc.startT or GetTime())
  local dur = W.encounter:Elapsed(enc)
  local _, class = UnitClass("player")

  self:SendLatest(table.concat({
    "M", esc(me), esc(class or "UNKNOWN"),
    int(damage), int(petDamage), int(healing), int(taken), int(petTaken),
    dec(active), dec(activeOwn), dec(ago), dec(dur),
    int((enc.startT or 0) * 10), esc(foe or ""),
  }, REC))
end

--- Report on a timer while a pull runs. Stopped when combat ends; the
--- pull's final numbers then go out from E:Finish.
function S:StartLive()
  if not (W.db and W.db.liveSync) or not self:Enabled() then return end

  local function tick()
    if not (W.db and W.db.liveSync) then return end
    if not W.encounter.inCombat then return end
    W.Guard("live sync", function() S:BroadcastMine() end)
    W.After(W.db.liveSyncInterval or LIVE_INTERVAL, tick, "liveSync")
  end

  W.After(W.db.liveSyncInterval or LIVE_INTERVAL, tick, "liveSync")
end

function S:StopLive()
  W.Cancel("liveSync")
end

--- Stable identity for one encounter; what the index lists and pulls ask for.
function S:Key(enc)
  return tostring(enc.sessionId) .. ":" .. tostring(enc.id)
end

----------------------------------------------------------------------
-- settings
----------------------------------------------------------------------

function S:Enabled()
  return W.db and W.db.shareEnabled == true
end

function S:Channel()
  local c = W.db and W.db.shareChannel
  if c == "RAID" or c == "PARTY" or c == "GUILD" then return c end
  return "AUTO"
end

--- Resolve AUTO, and refuse a channel we are not actually in -- addressing
--- RAID while solo is an error, not a no-op.
function S:ActiveChannel()
  local want = self:Channel()
  local inRaid = (GetNumRaidMembers() or 0) > 0
  local inParty = (GetNumPartyMembers() or 0) > 0
  local inGuild = IsInGuild and IsInGuild()

  if want == "RAID" then return inRaid and "RAID" or nil end
  if want == "PARTY" then return (inParty or inRaid) and "PARTY" or nil end
  if want == "GUILD" then return inGuild and "GUILD" or nil end

  if inRaid then return "RAID" end
  if inParty then return "PARTY" end
  if inGuild then return "GUILD" end
  return nil
end

----------------------------------------------------------------------
-- serialisation
----------------------------------------------------------------------

--- Flatten an encounter's actors. Players and pets only: enemies are
--- reconstructable from the receiver's own log and would double the payload.
function S:Encode(enc)
  local parts = {}
  for guid, a in pairs(enc.actors or {}) do
    if a.isPlayer or a.class == "PET" then
      table.insert(parts, table.concat({
        esc(a.name), esc(a.class),
        int(a.damage), int(a.taken), int(a.healing), int(a.overheal),
        int(a.deaths), int(a.dispels), int(a.interrupts),
        esc(a.ownerName or ""), int(a.consumes),
      }, FLD))
    end
  end
  return table.concat(parts, REC)
end

function S:Decode(body, meta, sender)
  local actors = {}
  for record in string.gfind(body, "[^" .. REC .. "]+") do
    local f = {}
    for field in string.gfind(record .. FLD, "([^" .. FLD .. "]*)" .. FLD) do
      table.insert(f, field)
    end
    if table.getn(f) >= 9 and f[1] ~= "" then
      actors["sync:" .. f[1]] = {
        name = f[1], class = f[2],
        isPlayer = (f[2] ~= "PET"),
        ownerName = (f[10] ~= "" and f[10]) or nil,
        damage = tonumber(f[3]) or 0,
        taken = tonumber(f[4]) or 0,
        healing = tonumber(f[5]) or 0,
        overheal = tonumber(f[6]) or 0,
        deaths = tonumber(f[7]) or 0,
        dispels = tonumber(f[8]) or 0,
        interrupts = tonumber(f[9]) or 0,
        consumes = tonumber(f[11]) or 0,
        absorbed = 0, hits = 0, crits = 0, misses = 0,
      }
    end
  end

  local totals = { damage = 0, healing = 0, overheal = 0, taken = 0, enemy = 0 }
  for _, a in pairs(actors) do
    totals.damage = totals.damage + a.damage
    totals.healing = totals.healing + a.healing
    totals.overheal = totals.overheal + a.overheal
    totals.taken = totals.taken + a.taken
  end

  return {
    id = meta.id,
    -- Filed under the sender's own session so a received log can never be
    -- merged into, or confused with, what this client recorded itself.
    sessionId = "sync:" .. sender,
    name = meta.name,
    zone = meta.zone,
    startTime = (meta.startTime and meta.startTime > 0) and meta.startTime or time(),
    offset = 0,
    duration = meta.duration,
    combat = meta.combat,
    kill = meta.kill,
    totals = totals,
    deaths = {},
    actors = actors,
    bucket = {},
    maxBucket = 0,
    sharedBy = sender,
  }
end

--- One line per encounter: what the browser lists before anything is pulled.
function S:EncodeIndex()
  local parts = {}
  for _, enc in ipairs((W.db and W.db.encounters) or {}) do
    -- Never offer someone else's log back to the network.
    if not enc.sharedBy then
      table.insert(parts, table.concat({
        esc(self:Key(enc)), esc(enc.name), esc(enc.zone),
        int(enc.startTime), int(enc.duration), int(enc.combat),
        enc.kill and "1" or "0",
        int((enc.totals and enc.totals.damage) or 0),
      }, FLD))
    end
  end
  return table.concat(parts, REC)
end

function S:DecodeIndex(body)
  local out = {}
  for record in string.gfind(body, "[^" .. REC .. "]+") do
    local f = {}
    for field in string.gfind(record .. FLD, "([^" .. FLD .. "]*)" .. FLD) do
      table.insert(f, field)
    end
    if f[1] and f[1] ~= "" then
      table.insert(out, {
        key = f[1], name = f[2], zone = f[3],
        startTime = tonumber(f[4]) or 0,
        duration = tonumber(f[5]) or 0,
        combat = tonumber(f[6]) or 0,
        kill = (f[7] == "1"),
        damage = tonumber(f[8]) or 0,
      })
    end
  end
  return out
end

----------------------------------------------------------------------
-- sending
----------------------------------------------------------------------

--- Queue one message. `to` is a player name or "*" for everyone; it is
--- written into the message, never into the chat type, because 1.12 has no
--- directed addon channel.
function S:Send(to, body, channel)
  channel = channel or self:ActiveChannel()
  if not channel then return false end
  table.insert(self.queue, {
    msg = string.sub(body, 1, 1) .. REC .. esc(to or "*") .. string.sub(body, 2),
    channel = channel,
  })
  self:StartPump()
  return true
end

--[[ Queue a live report ahead of everything else, replacing any report not
     yet sent. Its timings are measured when it is built, so it must not sit
     behind a log transfer going stale; and a report superseded before it
     left is only noise. ]]
function S:SendLatest(body, channel)
  channel = channel or self:ActiveChannel()
  if not channel then return false end
  for i = table.getn(self.queue), 1, -1 do
    if self.queue[i].latest then table.remove(self.queue, i) end
  end
  table.insert(self.queue, 1, {
    msg = string.sub(body, 1, 1) .. REC .. "*" .. string.sub(body, 2),
    channel = channel,
    latest = true,
  })
  self:StartPump()
  return true
end

function S:StartPump()
  if self.pumping then return end
  self.pumping = true
  local function pump()
    local job = table.remove(self.queue, 1)
    if not job then
      self.pumping = false
      return
    end
    if SendAddonMessage then
      -- No target argument: the addressee lives in the message. Passing a
      -- chat type this client does not know is fatal, not an error.
      SendAddonMessage(PREFIX, job.msg, job.channel)
    end
    W.After(SEND_INTERVAL, pump, "syncPump")
  end
  pump()
end

--- Break a body into a chunked transfer. `meta` becomes the header fields.
function S:SendTransfer(kind, body, meta, to, channel)
  if not body or body == "" then return 0 end

  local id = self.nextId
  self.nextId = self.nextId + 1

  local chunks = math.ceil(string.len(body) / CHUNK)
  local header = { "H", id, chunks, kind }
  for _, m in ipairs(meta or {}) do table.insert(header, m) end
  if not self:Send(to, table.concat(header, REC), channel) then return 0 end

  for i = 1, chunks do
    local piece = string.sub(body, (i - 1) * CHUNK + 1, i * CHUNK)
    self:Send(to, "D" .. REC .. id .. REC .. i .. REC .. piece, channel)
  end

  self:Send(to, "E" .. REC .. id, channel)
  return chunks + 2
end

--- Push one encounter (the "/wrek share" direction).
function S:Share(enc, to, channel)
  if not enc then return 0 end
  if not (channel or self:ActiveChannel()) then
    W.Print("you are not in a raid, party or guild to share on.")
    return 0
  end

  local body = self:Encode(enc)
  if body == "" then
    W.Print("Nothing to share from that encounter.")
    return 0
  end

  return self:SendTransfer("enc", body, {
    esc(enc.name), esc(enc.zone), int(enc.duration), int(enc.combat),
    enc.kill and "1" or "0", int(enc.startTime),
  }, to or "*", channel)
end

function S:ShareLatest(channel)
  local session = W.report:MostRecentSession()
  if not session then
    W.Print("No encounters recorded yet.")
    return
  end
  local list = session.encounters
  local enc = list[table.getn(list)]
  local n = self:Share(enc, "*", channel)
  if n > 0 then
    W.Print("Sharing |cffe0a22c" .. (enc.name or "?") .. "|r (" .. n .. " messages).")
  end
end

--- Send specific encounters to one person, by key. The pull direction.
function S:SendEncounters(keys, target)
  if not self:Enabled() then return 0 end
  local wanted = {}
  for _, k in ipairs(keys) do wanted[k] = true end

  local sent = 0
  for _, enc in ipairs((W.db and W.db.encounters) or {}) do
    if not enc.sharedBy and wanted[self:Key(enc)] then
      sent = sent + self:Share(enc, target)
    end
  end
  return sent
end

----------------------------------------------------------------------
-- presence and browsing
----------------------------------------------------------------------

--- Say we are here. Only when sharing is on: this broadcasts your name.
function S:Announce(to, channel)
  if not self:Enabled() then return end

  local count = 0
  for _, e in ipairs((W.db and W.db.encounters) or {}) do
    if not e.sharedBy then count = count + 1 end
  end
  self:Send(to or "*", "V" .. REC .. esc(W.version) .. REC .. int(count), channel)
end

--- Ask who else is out there. Answers arrive as V messages.
function S:Discover(channel)
  channel = channel or self:ActiveChannel()
  if not channel then
    W.Print("you are not in a raid, party or guild to look in.")
    return false
  end
  self.peers = {}
  self:Send("*", "P" .. REC, channel)
  -- Announce ourselves at the same time so the exchange is symmetric.
  self:Announce("*", channel)
  return true
end

--- Ask one peer for their log list.
function S:RequestIndex(name)
  self:Send(name, "L" .. REC)
end

--- Ask one peer for specific logs, batched to stay inside one message.
function S:RequestLogs(name, keys)
  if not keys or table.getn(keys) == 0 then return 0 end

  local batch, sent = {}, 0
  local function flush()
    if table.getn(batch) == 0 then return end
    self:Send(name, "G" .. REC .. table.concat(batch, REC))
    sent = sent + table.getn(batch)
    batch = {}
  end

  for _, k in ipairs(keys) do
    table.insert(batch, k)
    if string.len(table.concat(batch, REC)) > 200 then flush() end
  end
  flush()
  return sent
end

function S:Peer(name)
  local p = self.peers[name]
  if not p then
    p = { name = name, logs = 0, index = nil }
    self.peers[name] = p
  end
  p.lastSeen = GetTime()
  return p
end

--- Peers heard from recently, by name.
function S:PeerList()
  local out = {}
  local now = GetTime()
  for _, p in pairs(self.peers) do
    if (now - (p.lastSeen or 0)) < PEER_TIMEOUT then table.insert(out, p) end
  end
  table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
  return out
end

----------------------------------------------------------------------
-- receiving
----------------------------------------------------------------------

local function split(msg)
  local out = {}
  for piece in string.gfind(msg .. REC, "([^" .. REC .. "]*)" .. REC) do
    table.insert(out, piece)
  end
  return out
end

--- Everything after the Nth separator, verbatim. Chunk payloads may contain
--- separators themselves, so they cannot be recovered by splitting.
local function payloadAfter(msg, fields)
  local pattern = "^%a"
  for _ = 1, fields do
    pattern = pattern .. REC .. "[^" .. REC .. "]*"
  end
  local _, _, rest = string.find(msg, pattern .. REC .. "(.*)$")
  return rest or ""
end

function S:OnMessage(prefix, msg, channel, sender)
  if prefix ~= PREFIX then return end
  if not sender or sender == UnitName("player") then return end
  if not W.db then return end

  local kind = string.sub(msg, 1, 1)
  local f = split(msg)

  -- Field 2 is who the message is for. Everything rides a broadcast channel
  -- because 1.12 has no directed addon channel, so this filter is the only
  -- thing that makes a "directed" message directed.
  local to = f[2]
  if to and to ~= "*" and to ~= UnitName("player") then return end

  ------------------------------------------------------------------
  -- live totals
  ------------------------------------------------------------------
  -- M~to~name~class~dmg~petDmg~heal~taken~petTaken~active~activeOwn~ago~dur~pid~foe
  -- Taken only while we are willing to, and never for ourselves: our own
  -- numbers are measured here and do not need telling.
  if kind == "M" then
    if not (W.db and W.db.liveSync) then return end
    -- The same switch as shared logs. This once read a different key than
    -- the checkbox writes, so switching it off did not stop these.
    if W.db.acceptShares == false then return end
    -- Short means a different version of the format; guessing which field
    -- is which would fill rows with the wrong numbers.
    if table.getn(f) < 15 then return end

    local name = f[3]
    if not name or name == "" then return end
    if name == UnitName("player") then return end
    -- The sender must be the person they are describing. Anything else is
    -- one player reporting a third party, which is exactly the
    -- double-counting this design exists to avoid.
    if sender and sender ~= name then return end

    W.encounter:RemoteReport({
      name = name, class = f[4],
      damage = tonumber(f[5]) or 0, petDamage = tonumber(f[6]) or 0,
      healing = tonumber(f[7]) or 0, taken = tonumber(f[8]) or 0,
      petTaken = tonumber(f[9]) or 0,
      active = tonumber(f[10]) or 0, activeOwn = tonumber(f[11]) or 0,
      ago = tonumber(f[12]) or 0, dur = tonumber(f[13]) or 0,
      pid = f[14], foe = f[15],
    })
    return
  end

  ------------------------------------------------------------------
  -- presence
  ------------------------------------------------------------------
  if kind == "V" then
    local p = self:Peer(sender)
    p.version = f[3]
    p.logs = tonumber(f[4]) or 0
    if W.ui and W.ui.peers then W.ui.peers:Refresh() end
    return
  end

  if kind == "P" then
    -- Someone is looking. Address the answer to them so everyone else on the
    -- channel drops it rather than listing a peer they did not ask about.
    self:Announce(sender)
    return
  end

  ------------------------------------------------------------------
  -- requests aimed at us
  ------------------------------------------------------------------
  if kind == "L" then
    if not self:Enabled() then return end
    local body = self:EncodeIndex()
    if body == "" then return end
    self:SendTransfer("idx", body, {}, sender)
    return
  end

  if kind == "G" then
    if not self:Enabled() then return end
    local keys = {}
    for i = 3, table.getn(f) do
      if f[i] and f[i] ~= "" then table.insert(keys, f[i]) end
    end
    local n = self:SendEncounters(keys, sender)
    if n > 0 then
      W.Print(sender .. " pulled " .. table.getn(keys) .. " log" ..
        (table.getn(keys) == 1 and "" or "s") .. " from you.")
    end
    return
  end

  ------------------------------------------------------------------
  -- transfers
  ------------------------------------------------------------------
  if kind == "H" then
    local id = f[3]
    self.incoming[sender .. ":" .. id] = {
      chunks = tonumber(f[4]) or 0,
      kind = f[5] or "enc",
      parts = {},
      at = GetTime(),
      meta = {
        id = tonumber(id) or 0,
        name = f[6], zone = f[7],
        duration = tonumber(f[8]) or 0,
        combat = tonumber(f[9]) or 0,
        kill = (f[10] == "1"),
        startTime = tonumber(f[11]) or 0,
      },
    }
    return
  end

  if kind == "D" then
    local xfer = self.incoming[sender .. ":" .. f[3]]
    if not xfer then return end
    local seq = tonumber(f[4])
    if seq then
      -- Three fields precede the payload now (to, xfer, seq), and the
      -- payload itself may contain separators, so it cannot be split.
      xfer.parts[seq] = payloadAfter(msg, 3)
      xfer.at = GetTime()
    end
    return
  end

  if kind == "E" then
    local key = sender .. ":" .. f[3]
    local xfer = self.incoming[key]
    if not xfer then return end
    self.incoming[key] = nil

    local body = {}
    for i = 1, xfer.chunks do
      if not xfer.parts[i] then
        W.Debug("dropped transfer from " .. sender .. ": missing chunk " .. i)
        return
      end
      body[i] = xfer.parts[i]
    end
    body = table.concat(body)

    if xfer.kind == "idx" then
      local p = self:Peer(sender)
      p.index = self:DecodeIndex(body)
      if W.ui and W.ui.peers then W.ui.peers:Refresh() end
      return
    end

    -- An encounter. Taking one is the receiver's choice.
    if W.db.acceptShares == false then return end

    local rec = self:Decode(body, xfer.meta, sender)

    --[[ Replace rather than duplicate. Pulling the same log twice -- easy to
         do from a browser -- must not leave two copies that then both show
         up in the report. ]]
    local replaced = false
    for i, e in ipairs(W.db.encounters) do
      if e.sharedBy == sender and e.name == rec.name
          and e.duration == rec.duration and e.startTime == rec.startTime then
        W.db.encounters[i] = rec
        replaced = true
        break
      end
    end
    if not replaced then table.insert(W.db.encounters, rec) end

    while table.getn(W.db.encounters) > (W.db.maxEncounters or 60) do
      local victim
      for i = 1, table.getn(W.db.encounters) do
        if not W.db.encounters[i].locked then victim = i break end
      end
      if not victim then break end
      table.remove(W.db.encounters, victim)
    end

    W.Print("Got |cffe0a22c" .. (rec.name or "?") .. "|r from " .. sender .. ".")
    if W.ui and W.ui.report and W.ui.report.frame then W.ui.report:Refresh() end
    if W.ui and W.ui.peers then W.ui.peers:Refresh() end
  end
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function S:Start()
  if self.frame then return end
  local f = CreateFrame("Frame", "WrekkitSyncFrame")
  self.frame = f
  f:RegisterEvent("CHAT_MSG_ADDON")
  f:SetScript("OnEvent", function()
    S:OnMessage(arg1, arg2, arg3, arg4)
  end)

  -- Sweep abandoned transfers so a sender who zoned mid-share cannot leak.
  local function sweep()
    local now = GetTime()
    for key, xfer in pairs(S.incoming) do
      if (now - xfer.at) > XFER_TIMEOUT then S.incoming[key] = nil end
    end
    W.After(XFER_TIMEOUT, sweep, "syncSweep")
  end
  W.After(XFER_TIMEOUT, sweep, "syncSweep")
end

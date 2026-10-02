--[[ Wrekkit :: threat

Live threat, from the server rather than guessed from the combat log.

1.12 has no threat API, and every vanilla threat meter before this one had to
reconstruct threat from damage, heals and a table of per-spell modifiers --
which is only ever as right as that table, and silently wrong for anything
the server changed. OctoWoW (like Turtle WoW) answers the question directly:

  request   SendAddonMessage("TWT_UDTSv4", "limit=<n>", "PARTY" | "RAID")
            the server intercepts it; nobody else in the group sees it
  reply     CHAT_MSG_ADDON whose text contains
              TWTv4=<name>:<tank>:<threat>:<perc>:<melee>;<name>:...
            for the mob YOU have targeted, where
              tank   1 for whoever currently has aggro
              threat raw threat
              perc   threat as a percentage of the tank's (tank = 100)
              melee  1 if that player is in melee range of the mob
  tank mode request "TWT_UDTSv4_TM" instead, and the reply carries a second
            section after '#':
              TMTv1=<creature>:<lowGuid>:<name>:<perc>;...
            one entry per mob in the fight, so a tank can watch the mobs
            they are not targeting.

That is the same protocol TWThreat uses, so the two can run side by side:
each reply is for the requester's own target, and either addon's replies
are equally good data for the other.

Aggro changes hands at 110% of the tank's threat in melee range and 130%
outside it. Every percentage the warnings act on is measured against that
line, not against the tank -- "90%" should mean "90% of the way to pulling",
which a tank-relative number does not (a caster at 100% of the tank is still
30 points away). Both are kept, and the setting picks which one is shown.
]]

local W = Wrekkit
W.threat = {}
local T = W.threat

T.UDTS = "TWT_UDTSv4"
T.API = "TWTv4="
T.TM_API = "TMTv1="

-- Aggro moves at these multiples of the tank's threat.
T.PULL_MELEE = 110
T.PULL_RANGED = 130

-- How long TPS looks back.
local TPS_WINDOW = 10
-- A reading older than this is not shown as current.
local STALE = 3

T.defaults = {
  enabled = true,
  interval = 0.5,          -- seconds between requests
  eliteOnly = true,        -- the server only reports elites and bosses
  tankMode = false,        -- ask for every mob in the fight, not just the target
  basis = "pull",          -- "pull": % of the aggro line; "tank": % of the tank
  warnAt = 75,
  dangerAt = 90,

  -- where it is shown
  display = "window",      -- "window" | "docked" | "meter" | "off"
  autoMeter = false,       -- meter shows threat while fighting, then goes back
  rows = 8,
  showThreat = true,
  showTPS = true,
  showPullLine = true,
  locked = false,
  opacity = 1.0,
  window = { point = "CENTER", x = -320, y = -180, w = 240, h = 170 },

  -- warnings
  warnText = true,
  warnFlash = true,
  warnSound = true,
  warnLostAggro = true,    -- when you held aggro and lost it
  textSize = 26,

  -- target frame
  frame = true,
  framePercent = true,
  frameGlow = true,
  frameAnchor = "TOP",     -- TOP | BOTTOM | LEFT | RIGHT
  frameScale = 1.0,
  frameName = "",          -- empty: find TargetFrame or pfUI's own

  -- nameplates
  plates = true,
  platePercent = true,
  plateColor = "text",     -- "text" | "bar" | "none"
  plateAnchor = "RIGHT",   -- RIGHT | LEFT | TOP | BOTTOM
  plateMemory = 10,        -- seconds a mob you stopped targeting stays shown
  plateSize = 11,
}

function T:Settings()
  if not W.db then return self.defaults end
  if type(W.db.threat) ~= "table" then W.db.threat = {} end
  local s = W.db.threat
  for k, v in pairs(self.defaults) do
    if s[k] == nil then
      if type(v) == "table" then
        s[k] = {}
        for k2, v2 in pairs(v) do s[k][k2] = v2 end
      else
        s[k] = v
      end
    end
  end
  return s
end

----------------------------------------------------------------------
-- state
----------------------------------------------------------------------

--[[ current: the table for the mob you have targeted, as last reported.
       { key, guid, name, at, rows = { row... }, me = row, tank = row }
     row: { name, class, tank, threat, perc, melee, pull, tps, isMe }

     memory: the last reading for each mob, by guid (or by "name:<name>"
     without SuperWoW), so a nameplate can keep showing a mob you have just
     tabbed off. Only your own standing is kept -- that is all a plate shows.

     tankMobs: tank mode's per-mob entries, by the low 16 bits of the guid,
     which is all the server sends. ]]
T.current = nil
T.memory = {}
T.tankMobs = {}
T.history = {}
T.packets = 0

local function myName() return UnitName and UnitName("player") end

--- A stable key for the target: its guid when SuperWoW can give one.
function T:TargetKey()
  if not UnitExists then return nil end
  local exists, guid = UnitExists("target")
  if not exists then return nil end
  if type(guid) == "string" and guid ~= "" and guid ~= "target" then
    return guid, guid
  end
  local name = UnitName("target")
  if not name then return nil end
  return "name:" .. name, nil
end

--- Which channel the request goes out on, or nil when there is no group.
--- SendAddonMessage to PARTY outside a party has nowhere to go.
function T:Channel()
  if (GetNumRaidMembers() or 0) > 0 then return "RAID" end
  if (GetNumPartyMembers() or 0) > 0 then return "PARTY" end
  return nil
end

--- Is the target something the server will report on? Returns false and a
--- reason, so the window can say why it is empty instead of looking broken.
function T:TargetEligible()
  if not UnitExists or not UnitExists("target") then return false, "no target" end
  if UnitIsPlayer and UnitIsPlayer("target") == 1 then return false, "target is a player" end
  if UnitIsDead and UnitIsDead("target") then return false, "target is dead" end
  if UnitCanAttack and not UnitCanAttack("player", "target") then
    return false, "target is friendly"
  end
  if self:Settings().eliteOnly and UnitClassification then
    local c = UnitClassification("target")
    if c ~= "elite" and c ~= "worldboss" and c ~= "rareelite" then
      return false, "not an elite"
    end
  end
  if UnitAffectingCombat and not UnitAffectingCombat("target") then
    return false, "target is not in combat"
  end
  return true
end

----------------------------------------------------------------------
-- requesting
----------------------------------------------------------------------

--- One request, if one is due and would be answered.
function T:Poll()
  local s = self:Settings()
  if not s.enabled then return end
  if self.demoUntil then
    if GetTime() < self.demoUntil then return end
    self:StopDemo()
  end

  local channel = self:Channel()
  if not channel then
    self.why = "join a party or raid"
    return
  end

  local ok, why = self:TargetEligible()
  if not ok then
    self.why = why
    return
  end
  self.why = nil

  local key, guid = self:TargetKey()
  if key ~= self.reqKey then
    -- New mob: what was on screen belonged to the last one.
    self:SetCurrent(nil)
  end
  self.reqKey, self.reqGuid = key, guid
  self.reqName = UnitName("target")

  local limit = math.max(1, math.floor(s.rows or 8))
  local prefix = s.tankMode and (self.UDTS .. "_TM") or self.UDTS
  pcall(SendAddonMessage, prefix, "limit=" .. limit, channel)
  self.lastRequest = GetTime()
end

----------------------------------------------------------------------
-- parsing
----------------------------------------------------------------------

local function split(str, sep)
  local out = {}
  for piece in string.gfind(str, "[^" .. sep .. "]+") do
    table.insert(out, piece)
  end
  return out
end

--- Class for a name, from the roster capture already keeps.
local function classOf(name)
  local c = W.capture and W.capture.rosterClass and W.capture.rosterClass[name]
  return c or "UNKNOWN"
end

--- Threat per second over the last few seconds, from the readings so far.
function T:TPS(name, threat, now)
  local h = self.history[name]
  if not h then
    h = {}
    self.history[name] = h
  end
  table.insert(h, { t = now, v = threat })
  while table.getn(h) > 1 and (now - h[1].t) > TPS_WINDOW do
    table.remove(h, 1)
  end
  local first = h[1]
  local dt = now - first.t
  if dt <= 0 then return 0 end
  local tps = (threat - first.v) / dt
  if tps < 0 then tps = 0 end
  return tps
end

--- How far toward pulling aggro a row is, 0-100+ (100 = it moves now).
function T.PullPercent(row)
  if not row then return 0 end
  if row.tank then return 100 end
  local line = row.melee and T.PULL_MELEE or T.PULL_RANGED
  return (row.perc or 0) / line * 100
end

--- The percentage a setting asked to see, for one row.
function T:Shown(row)
  if not row then return 0 end
  if self:Settings().basis == "tank" then return row.perc or 0 end
  return row.pull or T.PullPercent(row)
end

--- Parse "TWTv4=..." into rows. Returns nil for anything malformed.
function T:ParseThreat(text, now)
  local start = string.find(text, self.API, 1, true)
  if not start then return nil end
  local body = string.sub(text, start + string.len(self.API))
  local me = myName()

  local rows = {}
  for _, entry in ipairs(split(body, ";")) do
    local f = split(entry, ":")
    if f[1] and f[2] and f[3] and f[4] and f[5] then
      local row = {
        name = f[1],
        tank = f[2] == "1",
        threat = tonumber(f[3]) or 0,
        perc = tonumber(f[4]) or 0,
        melee = f[5] == "1",
        class = classOf(f[1]),
      }
      row.isMe = (row.name == me)
      row.pull = T.PullPercent(row)
      row.tps = self:TPS(row.name, row.threat, now)
      table.insert(rows, row)
    end
  end
  table.sort(rows, function(a, b)
    if a.threat == b.threat then return a.name < b.name end
    return a.threat > b.threat
  end)
  return rows
end

--- Parse tank mode's "TMTv1=creature:lowGuid:name:perc;..."
function T:ParseTankMode(text, now)
  local start = string.find(text, self.TM_API, 1, true)
  if not start then return end
  local body = string.sub(text, start + string.len(self.TM_API))
  local fresh = {}
  for _, entry in ipairs(split(body, ";")) do
    local f = split(entry, ":")
    local low = tonumber(f[2] or "")
    if f[1] and low and f[3] and f[4] then
      fresh[low] = { creature = f[1], name = f[3], perc = tonumber(f[4]) or 0, at = now }
    end
  end
  self.tankMobs = fresh
end

--- The low 16 bits of a guid, which is how tank mode names a mob.
function T.LowGuid(guid)
  if type(guid) ~= "string" or string.len(guid) < 4 then return nil end
  return tonumber(string.sub(guid, -4), 16)
end

--- A server reply arrived.
function T:OnMessage(text)
  if type(text) ~= "string" then return end
  if not string.find(text, self.API, 1, true) then return end
  if not self:Settings().enabled then return end
  -- A demo is on screen: real data would fight it for the same frames.
  if self.demoUntil then return end

  local now = GetTime()
  self.packets = self.packets + 1
  self.lastPacket = now

  local threatPart = text
  local hash = string.find(text, "#", 1, true)
  if hash and string.find(text, self.TM_API, 1, true) then
    threatPart = string.sub(text, 1, hash - 1)
    self:ParseTankMode(string.sub(text, hash + 1), now)
  end

  --[[ The reply is for whatever was targeted when it was asked for. If the
       target has changed since, it describes the wrong mob, and putting it
       on the new one's frame would be confidently wrong. ]]
  local key, guid = self:TargetKey()
  if not key or (self.reqKey and key ~= self.reqKey) then return end

  local rows = self:ParseThreat(threatPart, now)
  if not rows then return end

  local cur = { key = key, guid = guid, name = UnitName("target"), at = now, rows = rows }
  for _, r in ipairs(rows) do
    if r.isMe then cur.me = r end
    if r.tank then cur.tank = r end
  end
  self:SetCurrent(cur)
end

--- Replace the current table, remember it for the plates, and raise or
--- clear warnings.
function T:SetCurrent(cur)
  local prev = self.current
  self.current = cur
  if cur then
    self.memory[cur.key] = {
      shown = cur.me and self:Shown(cur.me) or 0,
      tank = cur.me and cur.me.tank or false,
      at = cur.at,
      name = cur.name,
    }
    self:CheckWarnings(prev, cur)
  else
    self.history = {}
  end
  self:Changed()
end

--- Everything that draws threat, told to redraw.
function T:Changed()
  local UI = W.ui
  if not UI then return end
  if UI.threat and UI.threat.Refresh then UI.threat:Refresh() end
  if UI.threatFrames and UI.threatFrames.Update then UI.threatFrames:Update() end
  if UI.meter and UI.meter.frame and UI.meter:Settings().metric == "threat" then
    UI.meter:Refresh()
  end
end

----------------------------------------------------------------------
-- warning levels
----------------------------------------------------------------------

--- "safe" | "warn" | "danger" for a shown percentage.
function T:Level(pct)
  local s = self:Settings()
  if (pct or 0) >= (s.dangerAt or 90) then return "danger" end
  if (pct or 0) >= (s.warnAt or 75) then return "warn" end
  return "safe"
end

local GREEN  = { 0.30, 0.80, 0.35 }
local YELLOW = { 0.95, 0.85, 0.20 }
local ORANGE = { 1.00, 0.55, 0.10 }
local RED    = { 0.95, 0.20, 0.20 }
T.TANK_COLOR = { 0.35, 0.60, 1.00 }

--- Colour for a percentage: green easing to yellow while safe, orange once
--- it warns, red once it is dangerous.
function T:Color(pct)
  pct = pct or 0
  local level = self:Level(pct)
  if level == "danger" then return RED end
  if level == "warn" then return ORANGE end
  local warnAt = self:Settings().warnAt or 75
  local f = (warnAt > 0) and (pct / warnAt) or 0
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  return {
    GREEN[1] + (YELLOW[1] - GREEN[1]) * f,
    GREEN[2] + (YELLOW[2] - GREEN[2]) * f,
    GREEN[3] + (YELLOW[3] - GREEN[3]) * f,
  }
end

--- The highest-threat player who is not the tank.
function T:Runner(cur)
  cur = cur or self.current
  if not cur then return nil end
  for _, r in ipairs(cur.rows) do
    if not r.tank then return r end
  end
  return nil
end

--[[ Warnings fire on the way UP into a level, never repeatedly while
     sitting in it. A warning that nags every half second gets turned off,
     and then it is not there for the pull where it mattered. ]]
function T:CheckWarnings(prev, cur)
  local me = cur and cur.me
  if not me then return end
  local s = self:Settings()

  local samePull = prev and prev.key == cur.key
  local wasTank = samePull and prev.me and prev.me.tank

  if me.tank then
    self.lastLevel = nil
    return
  end

  if wasTank and s.warnLostAggro then
    local holder = cur.tank and cur.tank.name or "someone"
    self:Alert("LOST AGGRO to " .. holder, "danger")
    self.lastLevel = "danger"
    return
  end

  local level = self:Level(self:Shown(me))
  local before = samePull and self.lastLevel or "safe"
  local rank = { safe = 0, warn = 1, danger = 2 }
  if rank[level] > rank[before or "safe"] then
    self:Alert(string.format("THREAT %d%%", math.floor(self:Shown(me) + 0.5)), level)
  end
  self.lastLevel = level
end

--- Raise a warning through whichever channels are switched on.
function T:Alert(text, level)
  local s = self:Settings()
  local UI = W.ui
  if UI and UI.threatFrames then
    if s.warnText then UI.threatFrames:Message(text, level) end
    if s.warnFlash then UI.threatFrames:Flash(level) end
  end
  if s.warnSound and PlaySound then
    local now = GetTime()
    if not self.lastSound or now - self.lastSound > 3 then
      self.lastSound = now
      pcall(PlaySound, level == "danger" and "RaidWarning" or "igQuestFailed")
    end
  end
end

----------------------------------------------------------------------
-- reading
----------------------------------------------------------------------

--- The current table if it is fresh enough to show.
function T:Live()
  local cur = self.current
  if not cur then return nil end
  if self.demoUntil then return cur end
  if GetTime() - (cur.at or 0) > STALE then return nil end
  local key = self:TargetKey()
  if key ~= cur.key then return nil end
  return cur
end

--[[ Your standing on one mob, for a nameplate: the live table if it is
     that mob, then what you last saw on it, then tank mode's figure.
     Returns pct, color, fresh(bool), text. ]]
function T:ForMob(key, guid)
  local s = self:Settings()
  local now = GetTime()
  local live = self:Live()
  if live and live.key == key and live.me then
    return self:Display(live)
  end
  if guid and s.tankMode then
    local low = T.LowGuid(guid)
    local tm = low and self.tankMobs[low]
    if tm and now - tm.at <= STALE then
      if tm.name == myName() then
        return 100, T.TANK_COLOR, true, "tank"
      end
      return tm.perc, self:Color(tm.perc), true, string.format("%d%%", math.floor(tm.perc + 0.5))
    end
  end
  local m = key and self.memory[key]
  if m and now - m.at <= (s.plateMemory or 10) then
    if m.tank then return 100, T.TANK_COLOR, false, "tank" end
    return m.shown, self:Color(m.shown), false, string.format("%d%%", math.floor(m.shown + 0.5))
  end
  return nil
end

--[[ What a frame should say about a table: your own percentage, coloured
     by level. Holding aggro yourself, it says so -- coloured by how close
     the runner-up is to taking it, which is the number a tank wants. ]]
function T:Display(cur)
  local me = cur and cur.me
  if not me then return nil end
  if me.tank then
    local runner = self:Runner(cur)
    local pct = runner and runner.pull or 0
    local c = (runner and self:Level(pct) ~= "safe") and self:Color(pct) or T.TANK_COLOR
    return 100, c, true, "tank"
  end
  local pct = self:Shown(me)
  return pct, self:Color(pct), true, string.format("%d%%", math.floor(pct + 0.5))
end

----------------------------------------------------------------------
-- demo
----------------------------------------------------------------------

--[[ Fake data on screen for a few seconds, so the frames, the plates and
     the warnings can be placed and sized out of combat. Uses the real
     drawing paths -- a preview that drew differently would be a preview of
     something else. ]]
function T:Demo(seconds)
  local now = GetTime()
  local me = myName() or "You"
  local key = self:TargetKey() or "demo"
  local _, guid = self:TargetKey()
  local myClass = classOf(me)
  local rows = {
    { name = "Tanky", class = "WARRIOR", tank = true, threat = 48200, perc = 100, melee = true },
    { name = me, class = myClass, tank = false, threat = 51100, perc = 106, melee = false, isMe = true },
    { name = "Stabbs", class = "ROGUE", tank = false, threat = 40400, perc = 84, melee = true },
    { name = "Frosty", class = "MAGE", tank = false, threat = 33600, perc = 70, melee = false },
    { name = "Dotsworth", class = "WARLOCK", tank = false, threat = 21000, perc = 44, melee = false },
    { name = "Mendy", class = "PRIEST", tank = false, threat = 9800, perc = 20, melee = false },
  }
  for i, r in ipairs(rows) do
    r.pull = T.PullPercent(r)
    r.tps = 900 - i * 110
  end
  table.sort(rows, function(a, b) return a.threat > b.threat end)
  local cur = { key = key, guid = guid, name = UnitName("target") or "Training Dummy",
                at = now, rows = rows }
  for _, r in ipairs(rows) do
    if r.isMe then cur.me = r end
    if r.tank then cur.tank = r end
  end
  self.demoUntil = nil
  self.lastLevel = "safe"
  self:SetCurrent(cur)
  self.demoUntil = now + (seconds or 15)
end

function T:StopDemo()
  self.demoUntil = nil
  self.current = nil
  self:Changed()
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function T:OnTargetChanged()
  if self.demoUntil then return end
  local key = self:TargetKey()
  if self.current and self.current.key ~= key then
    self.current = nil
    self.history = {}
    self.lastLevel = nil
    self:Changed()
  end
  -- Ask straight away rather than up to an interval later: the first
  -- thing anyone does on a new target is look at its threat.
  self.nextPoll = 0
end

--- Forget what is no longer worth remembering.
function T:Prune()
  local now = GetTime()
  local keep = (self:Settings().plateMemory or 10) + 5
  for k, m in pairs(self.memory) do
    if now - m.at > keep then self.memory[k] = nil end
  end
end

function T:OnCombatEnd()
  self.lastLevel = nil
  self.tankMobs = {}
  if not self.demoUntil then
    self.current = nil
    self.history = {}
  end
  self:Changed()
end

local function tick()
  local now = GetTime()
  if now < (T.nextPoll or 0) then return end
  T.nextPoll = now + math.max(0.2, T:Settings().interval or 0.5)
  T:Poll()
  T:Prune()
  -- Readings age out even when nothing new arrives; redraw so a stale
  -- figure disappears instead of hanging on the frame.
  if T.current and not T.demoUntil and now - (T.current.at or 0) > STALE then
    T.current = nil
    T:Changed()
  end
end

function T:Start()
  if self.frame or not CreateFrame then return end
  local f = CreateFrame("Frame", "WrekkitThreatFrame")
  self.frame = f
  f:SetScript("OnEvent", function()
    if event == "CHAT_MSG_ADDON" then
      W.Guard("threat packet", function() T:OnMessage(arg2) end)
    elseif event == "PLAYER_TARGET_CHANGED" then
      W.Guard("threat target", function() T:OnTargetChanged() end)
    elseif event == "PLAYER_REGEN_ENABLED" then
      W.Guard("threat combat end", function() T:OnCombatEnd() end)
    end
  end)
  f:SetScript("OnUpdate", function() W.Guard("threat poll", tick) end)
  f:RegisterEvent("CHAT_MSG_ADDON")
  f:RegisterEvent("PLAYER_TARGET_CHANGED")
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
end

--- One line for /wrek status.
function T:StatusLine()
  local s = self:Settings()
  if not s.enabled then return "threat: off" end
  local age = self.lastPacket and string.format("%.0fs ago", GetTime() - self.lastPacket) or "never"
  return string.format("threat: %d server replies, last %s%s", self.packets, age,
    self.why and ("; idle: " .. self.why) or "")
end

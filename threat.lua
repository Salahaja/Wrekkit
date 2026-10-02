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
            one entry per mob YOU ARE TANKING, naming the player closest to
            pulling it off you and their threat as a % of yours. That is the
            whole of a tank's job in one line per mob.

That is the same protocol TWThreat uses, so the two can run side by side:
each reply is for the requester's own target, and either addon's replies
are equally good data for the other.

Aggro changes hands at 110% of the tank's threat in melee range and 130%
outside it. Every percentage the warnings act on is measured against that
line, not against the tank -- "90%" should mean "90% of the way to pulling",
which a tank-relative number does not (a caster at 100% of the tank is still
30 points away). Both are kept, and the setting picks which one is shown.

Two roles, because the same event means opposite things to them:

  damage / healing   warned as YOU approach the line, and told loudly if
                     you cross it and a mob turns on you
  tank               warned as someone ELSE approaches the line on any mob
                     you hold, and told which mob you lost when one turns

The role is a setting -- on, off, or auto, which reads Defensive Stance,
Bear Form and Righteous Fury -- so a druid who shifts out to heal stops
getting tank alerts without touching anything.

This file runs ten times a second during a fight and handles a packet twice
a second, so it is written not to make garbage: replies are parsed with
pattern captures rather than split into tables, row tables are pooled per
player, and colours and labels come from caches.
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

local TPS_WINDOW = 10     -- seconds threat-per-second looks back
local TPS_SLOTS = 24      -- readings kept per player for it
local STALE = 3           -- a reading older than this is not current
local LOST_SHOW = 4       -- seconds a lost mob's plate says so
local REARM = 5           -- points below a line before it can warn again

T.defaults = {
  enabled = true,
  interval = 0.5,          -- seconds between requests
  eliteOnly = true,        -- the server only reports elites and bosses
  tankMode = "auto",       -- "auto" | "on" | "off": am I the tank?
  basis = "pull",          -- "pull": % of the aggro line; "tank": % of the tank
  warnAt = 75,
  dangerAt = 90,

  -- where it is shown
  -- Docked by default: one block under the damage meter, placed and moved
  -- with it, rather than a second window to find a spot for.
  display = "docked",      -- "window" | "docked" | "meter" | "off"
  lastWindow = "docked",   -- where "/wrek threat" brings it back to
  show = "group",          -- window shown "always" | "group" | "combat"
  rows = 8,
  showThreat = true,
  showTPS = true,
  showPullLine = true,
  locked = false,
  opacity = 1.0,
  window = { point = "CENTER", x = -320, y = -180, w = 240, h = 170 },

  -- warnings, damage dealers and healers
  warnText = true,
  warnFlash = true,
  warnSound = true,
  warnPulled = true,       -- you took aggro off the tank
  textSize = 26,

  -- warnings, tanks
  tankAlerts = true,       -- someone is closing in on a mob you hold
  tankWarnAt = 85,         -- ... at this % of the way to pulling it
  warnLostAggro = true,    -- a mob you held turned to someone else

  -- target frame
  frame = true,
  frameStyle = "clean",    -- "clean" (number + bar) | "number" | "badge"
  frameGlow = true,        -- soft glow behind the number
  frameScale = 1.0,
  -- frameX / frameY: where it was dragged, from the target frame's centre.
  -- Unset until it is dragged, which puts it just above the frame.
  frameName = "",          -- empty: find pfUI's or the stock one

  -- nameplates
  plates = true,
  plateStyle = "auto",     -- "auto" | "shagu" (ShaguPlates/pfUI) | "stock"
  platePercent = true,
  plateColor = "text",     -- "text" | "bar" | "none"
  plateAnchor = "RIGHT",   -- RIGHT | LEFT | TOP | BOTTOM
  plateMemory = 10,        -- seconds a mob you stopped targeting stays shown
  plateSize = 11,
}

----------------------------------------------------------------------
-- settings
----------------------------------------------------------------------

local function oneOf(v, allowed, default)
  for _, a in ipairs(allowed) do
    if v == a then return v end
  end
  return default
end

local function clamp(v, lo, hi, default)
  v = tonumber(v)
  if not v then return default end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--[[ Put every saved value back inside what the controls can produce.

     A saved file can hold anything: a value from an older build with
     different meanings (tank mode was once true/false), a hand edit, or a
     number from a control whose range has since changed. Each one left
     alone is a setting that quietly does nothing, or a window sized to
     zero. Run once at load, so nothing else has to second-guess them. ]]
function T:Sanitize(s)
  local d = self.defaults
  if s.tankMode == true then s.tankMode = "on" elseif s.tankMode == false then s.tankMode = "auto" end
  s.tankMode = oneOf(s.tankMode, { "auto", "on", "off" }, d.tankMode)
  s.basis = oneOf(s.basis, { "pull", "tank" }, d.basis)
  s.display = oneOf(s.display, { "window", "docked", "meter", "off" }, d.display)
  s.show = oneOf(s.show, { "always", "group", "combat" }, d.show)
  s.frameStyle = oneOf(s.frameStyle, { "clean", "number", "badge" }, d.frameStyle)
  s.frameAnchor, s.framePercent = nil, nil    -- replaced by dragging and Style
  if s.frameX ~= nil or s.frameY ~= nil then
    s.frameX, s.frameY = tonumber(s.frameX), tonumber(s.frameY)
    if not (s.frameX and s.frameY) then s.frameX, s.frameY = nil, nil end
  end
  s.plateAnchor = oneOf(s.plateAnchor, { "TOP", "BOTTOM", "LEFT", "RIGHT" }, d.plateAnchor)
  s.plateColor = oneOf(s.plateColor, { "text", "bar", "none" }, d.plateColor)
  s.plateStyle = oneOf(s.plateStyle, { "auto", "shagu", "stock" }, d.plateStyle)
  s.interval = clamp(s.interval, 0.25, 2, d.interval)
  s.rows = math.floor(clamp(s.rows, 3, 20, d.rows))
  s.warnAt = clamp(s.warnAt, 10, 150, d.warnAt)
  s.dangerAt = clamp(s.dangerAt, 10, 150, d.dangerAt)
  -- A danger line below the warning line would skip the warning entirely.
  if s.dangerAt < s.warnAt then s.dangerAt = s.warnAt end
  s.tankWarnAt = clamp(s.tankWarnAt, 30, 120, d.tankWarnAt)
  s.textSize = math.floor(clamp(s.textSize, 14, 48, d.textSize))
  s.frameScale = clamp(s.frameScale, 0.6, 2.5, d.frameScale)
  s.plateMemory = clamp(s.plateMemory, 0, 30, d.plateMemory)
  s.plateSize = math.floor(clamp(s.plateSize, 7, 20, d.plateSize))
  s.opacity = clamp(s.opacity, 0.2, 1, d.opacity)
  if type(s.frameName) ~= "string" then s.frameName = "" end
  s.lastWindow = oneOf(s.lastWindow, { "window", "docked" }, "docked")
  if type(s.window) ~= "table" then s.window = {} end
  local w = s.window
  w.w = clamp(w.w, 180, 2000, d.window.w)
  w.h = clamp(w.h, 80, 2000, d.window.h)
  if type(w.point) ~= "string" then w.point = d.window.point end
  w.x = tonumber(w.x) or d.window.x
  w.y = tonumber(w.y) or d.window.y
  return s
end

function T:Settings()
  if not W.db then return self.defaults end
  local s = W.db.threat
  if type(s) == "table" and s._ok then return s end
  if type(s) ~= "table" then
    s = {}
    W.db.threat = s
  end
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
  self:Sanitize(s)
  -- Not saved as a promise about the file: cleared on every load below,
  -- so a value edited between sessions is checked again.
  s._ok = true
  return s
end

--- Back to defaults, keeping where the window is.
function T:ResetSettings()
  local old = W.db and W.db.threat
  local window = old and old.window
  if W.db then W.db.threat = nil end
  local s = self:Settings()
  if type(window) == "table" then s.window = window end
  self:InvalidateCaches()
  return s
end

----------------------------------------------------------------------
-- state
----------------------------------------------------------------------

--[[ current: the table for the mob you have targeted, as last reported.
       { key, guid, low, name, at, rows = { row... }, me = row, tank = row }
     row: { name, class, tank, threat, perc, melee, pull, tps, isMe }

     memory: your last reading on each mob, by guid (or by "name:<name>"
     without SuperWoW), so its nameplate can keep showing a mob you have
     just tabbed off.

     tankMobs: tank mode's entries -- the mobs you hold -- by the low 16
     bits of their guid, which is all the server sends. ]]
T.current = nil
T.memory = {}
T.tankMobs = {}
T.lost = {}          -- low guid or key -> time a mob you held turned away
T.died = {}          -- low guid -> time a mob died (so dying is not "lost")
T.fired = {}         -- warning edges, see edge()
T.packets = 0

local rowPool = {}   -- name -> row, reused from reply to reply

local function myName() return UnitName and UnitName("player") end

--- A stable key for the target: its guid when SuperWoW can give one.
function T:TargetKey()
  if not UnitExists then return nil end
  local exists, guid = UnitExists("target")
  if not exists then return nil end
  if type(guid) == "string" and string.sub(guid, 1, 2) == "0x" then
    return guid, guid
  end
  local name = UnitName("target")
  if not name then return nil end
  return "name:" .. name, nil
end

--- The low 16 bits of a guid, which is how tank mode names a mob.
function T.LowGuid(guid)
  if type(guid) ~= "string" or string.len(guid) < 6 then return nil end
  return tonumber(string.sub(guid, -4), 16)
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
      return false, "not an elite (see settings)"
    end
  end
  if UnitAffectingCombat and not UnitAffectingCombat("target") then
    return false, "target is not in combat"
  end
  return true
end

----------------------------------------------------------------------
-- role
----------------------------------------------------------------------

--[[ Is the player tanking right now? "on" and "off" say so outright;
     "auto" reads the stance, form or aura a tank fights in:

       warrior  Defensive Stance          druid    Bear / Dire Bear Form
       paladin  Righteous Fury

     By icon rather than name, so it works in every client language. Asked
     at most once a second -- a stance does not change faster than that. ]]
local TANK_ICONS = { "DefensiveStance", "BearForm" }
local FURY_ICON = "SealOfFury"

function T:DetectTank()
  local _, class = UnitClass("player")
  if class == "WARRIOR" or class == "DRUID" then
    if not GetNumShapeshiftForms or not GetShapeshiftFormInfo then return false end
    for i = 1, (GetNumShapeshiftForms() or 0) do
      local icon, _, active = GetShapeshiftFormInfo(i)
      if active and icon then
        for _, want in ipairs(TANK_ICONS) do
          if string.find(icon, want, 1, true) then return true end
        end
      end
    end
    return false
  elseif class == "PALADIN" and UnitBuff then
    for i = 1, 32 do
      local icon = UnitBuff("player", i)
      if not icon then break end
      if string.find(icon, FURY_ICON, 1, true) then return true end
    end
  end
  return false
end

function T:IsTank()
  local mode = self:Settings().tankMode
  if mode == "on" then return true end
  if mode == "off" then return false end
  local now = GetTime()
  if not self.roleAt or now - self.roleAt > 1 then
    self.roleAt = now
    local ok, isTank = pcall(self.DetectTank, self)
    self.role = ok and isTank or false
  end
  return self.role
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
    self:ResetHistory()
    if self.current then
      self.current = nil
      self:Changed()
    end
  end
  self.reqKey, self.reqGuid = key, guid

  local prefix = self:IsTank() and (self.UDTS .. "_TM") or self.UDTS
  pcall(SendAddonMessage, prefix, "limit=" .. s.rows, channel)
  self.lastRequest = GetTime()
end

----------------------------------------------------------------------
-- parsing
----------------------------------------------------------------------

local ROW = "([^:;#]+):(%d):(%-?[%d%.]+):(%-?[%d%.]+):(%d)"
local TM_ROW = "([^:;#]+):(%d+):([^:;#]+):(%-?[%d%.]+)"

--- Class for a name, from the roster capture already keeps.
local function classOf(name)
  local c = W.capture and W.capture.rosterClass and W.capture.rosterClass[name]
  return c or "UNKNOWN"
end

--- Forget every player's threat history: it belonged to another mob.
function T:ResetHistory()
  for _, r in pairs(rowPool) do r.hn = 0 end
end

--[[ Threat per second over the last few seconds.

     Each player keeps a fixed ring of readings, written in place, so a
     raid's worth of players costs no new tables per reply. ]]
local function tps(r, threat, now)
  local ts, vs = r.ts, r.vs
  if not ts then
    ts, vs = {}, {}
    r.ts, r.vs, r.hi, r.hn = ts, vs, 0, 0
  end
  r.hi = math.mod(r.hi or 0, TPS_SLOTS) + 1
  ts[r.hi], vs[r.hi] = now, threat
  if (r.hn or 0) < TPS_SLOTS then r.hn = (r.hn or 0) + 1 end

  local oldest
  for k = 1, r.hn do
    local t = ts[k]
    if now - t <= TPS_WINDOW and (not oldest or t < ts[oldest]) then oldest = k end
  end
  if not oldest then return 0 end
  local dt = now - ts[oldest]
  if dt <= 0 then return 0 end
  local v = (threat - vs[oldest]) / dt
  if v < 0 then v = 0 end
  return v
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

--- Parse "TWTv4=..." into rows, newest values written into pooled tables.
function T:ParseThreat(text, now)
  local start = string.find(text, self.API, 1, true)
  if not start then return nil end
  local stop = string.find(text, "#", start, true)
  local body = string.sub(text, start + string.len(self.API), stop and (stop - 1) or nil)
  local me = myName()

  local rows = {}
  for name, tank, threat, perc, melee in string.gfind(body, ROW) do
    local r = rowPool[name]
    if not r then
      r = { name = name }
      rowPool[name] = r
    end
    r.class = classOf(name)
    r.tank = (tank == "1")
    r.threat = tonumber(threat) or 0
    r.perc = tonumber(perc) or 0
    r.melee = (melee == "1")
    r.isMe = (name == me)
    r.pull = T.PullPercent(r)
    r.tps = tps(r, r.threat, now)
    table.insert(rows, r)
  end
  if table.getn(rows) == 0 then return nil end
  table.sort(rows, function(a, b)
    if a.threat == b.threat then return a.name < b.name end
    return a.threat > b.threat
  end)
  return rows
end

--- Parse tank mode's "TMTv1=creature:lowGuid:runnerUp:perc;..." into the
--- set of mobs you hold, entries updated in place.
function T:ParseTankMode(text, now)
  local start = string.find(text, self.TM_API, 1, true)
  if not start then return nil end
  local body = string.sub(text, start + string.len(self.TM_API))
  local seen = {}
  for creature, low, name, perc in string.gfind(body, TM_ROW) do
    low = tonumber(low)
    if low then
      local m = self.tankMobs[low]
      if not m then
        m = {}
        self.tankMobs[low] = m
      end
      m.creature, m.name, m.perc, m.at = creature, name, tonumber(perc) or 0, now
      -- The server gives the runner-up's share of YOUR threat, not whether
      -- they are in melee range. Melee is the closer line, so it is the one
      -- assumed: a warning a little early beats one a little late.
      m.pull = m.perc / T.PULL_MELEE * 100
      seen[low] = true
    end
  end
  return seen
end

----------------------------------------------------------------------
-- a reply arrives
----------------------------------------------------------------------

function T:OnMessage(text)
  if type(text) ~= "string" then return end
  if not string.find(text, self.API, 1, true) then return end
  if not self:Settings().enabled then return end
  -- A preview is on screen: real data would fight it for the same frames.
  if self.demoUntil then return end

  local now = GetTime()
  self.packets = self.packets + 1
  self.lastPacket = now

  if string.find(text, self.TM_API, 1, true) then
    self:TankModeReply(self:ParseTankMode(text, now), now)
  end

  --[[ The reply is for whatever was targeted when it was asked for. If the
       target has changed since, it describes the wrong mob, and putting it
       on the new one's frame would be confidently wrong. ]]
  local key, guid = self:TargetKey()
  if not key or (self.reqKey and key ~= self.reqKey) then return end

  local rows = self:ParseThreat(text, now)
  if not rows then return end

  local cur = { key = key, guid = guid, low = T.LowGuid(guid),
                name = UnitName("target"), at = now, rows = rows }
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
  -- Read before anything is overwritten: rows are pooled, so prev's rows
  -- ARE cur's rows by now, and prev.me.tank would report the new value.
  local wasTank = prev and cur and prev.key == cur.key and self.heldKey == cur.key
  self.current = cur
  if cur then
    local m = self.memory[cur.key]
    if not m then
      m = {}
      self.memory[cur.key] = m
    end
    local pct, color, _, text = self:Display(cur)
    m.pct, m.color, m.text, m.at, m.name = pct, color, text, cur.at, cur.name
    self:CheckWarnings(cur, wasTank)
    self.heldKey = (cur.me and cur.me.tank) and cur.key or nil
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
-- levels and colours
----------------------------------------------------------------------

--- "safe" | "warn" | "danger" for a shown percentage.
function T:Level(pct)
  local s = self:Settings()
  if (pct or 0) >= s.dangerAt then return "danger" end
  if (pct or 0) >= s.warnAt then return "warn" end
  return "safe"
end

local GREEN  = { 0.30, 0.80, 0.35 }
local YELLOW = { 0.95, 0.85, 0.20 }
local ORANGE = { 1.00, 0.55, 0.10 }
local RED    = { 0.95, 0.20, 0.20 }
T.TANK_COLOR = { 0.35, 0.60, 1.00 }
T.RED = RED

--[[ Colours and labels are asked for on every plate ten times a second.
     Both are cached by whole percent, so that costs a table lookup rather
     than a new table or string each time. The colour cache depends on the
     warning lines, so changing them clears it. ]]
local colorCache, textCache = {}, {}
local cacheWarn, cacheDanger

function T:InvalidateCaches()
  colorCache = {}
  cacheWarn, cacheDanger = nil, nil
end

--- Colour for a percentage: green easing to yellow while safe, orange once
--- it warns, red once it is dangerous. The table is shared: do not change it.
function T:Color(pct)
  local s = self:Settings()
  if cacheWarn ~= s.warnAt or cacheDanger ~= s.dangerAt then
    colorCache = {}
    cacheWarn, cacheDanger = s.warnAt, s.dangerAt
  end
  local n = math.floor((pct or 0) + 0.5)
  if n < 0 then n = 0 elseif n > 250 then n = 250 end
  local c = colorCache[n]
  if c then return c end
  local level = self:Level(n)
  if level == "danger" then c = RED
  elseif level == "warn" then c = ORANGE
  else
    local f = (s.warnAt > 0) and (n / s.warnAt) or 0
    if f > 1 then f = 1 end
    c = {
      GREEN[1] + (YELLOW[1] - GREEN[1]) * f,
      GREEN[2] + (YELLOW[2] - GREEN[2]) * f,
      GREEN[3] + (YELLOW[3] - GREEN[3]) * f,
    }
  end
  colorCache[n] = c
  return c
end

--- "87%", cached.
function T.PctText(pct)
  local n = math.floor((pct or 0) + 0.5)
  local t = textCache[n]
  if not t then
    t = n .. "%"
    textCache[n] = t
  end
  return t
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

--- Colour for a mob a tank holds, by how close the runner-up is.
function T:TankColor(runnerPull)
  local s = self:Settings()
  if (runnerPull or 0) >= s.tankWarnAt then return RED end
  if (runnerPull or 0) >= s.tankWarnAt - 15 then return ORANGE end
  return T.TANK_COLOR
end

--[[ What a frame should say about a table, as pct, colour, fresh, text.

     Damage dealers and healers see their own percentage. Whoever holds
     aggro sees something else: a tank sees how close the runner-up is,
     in the tank's blue until it gets close; anyone else holding it sees
     AGGRO in red, because a mob on a non-tank is never good news. ]]
function T:Display(cur)
  local me = cur and cur.me
  if not me then return nil end
  if me.tank then
    if self:IsTank() then
      local runner = self:Runner(cur)
      local pull = runner and runner.pull or 0
      return pull, self:TankColor(pull), true, T.PctText(pull)
    end
    return 100, RED, true, "AGGRO"
  end
  local pct = self:Shown(me)
  return pct, self:Color(pct), true, T.PctText(pct)
end

----------------------------------------------------------------------
-- warnings
----------------------------------------------------------------------

--[[ Has a reading just crossed a line upward? Returns "warn", "danger" or
     nil. A line that fired re-arms only once the reading falls clearly
     below it -- REARM points -- so a value hovering on the line cannot
     fire it again with every reply. ]]
local function edge(state, key, pct, warnAt, dangerAt)
  local fired = state[key] or 0
  local now = (pct >= dangerAt and 2) or (pct >= warnAt and 1) or 0
  if now > fired then
    state[key] = now
    return (now == 2) and "danger" or "warn"
  end
  if fired == 2 and pct < dangerAt - REARM then
    fired = (pct >= warnAt - REARM) and 1 or 0
  elseif fired == 1 and pct < warnAt - REARM then
    fired = 0
  end
  state[key] = fired
  return nil
end
T.edge = edge

--- The tank-mode key for a mob: its low guid when known, so the target's
--- table and tank mode's entry for the same mob share one warning.
local function mobKey(cur)
  return cur.low or cur.key
end

function T:CheckWarnings(cur, wasTank)
  local me = cur and cur.me
  if not me then return end
  local s = self:Settings()
  local tank = self:IsTank()
  local key = mobKey(cur)

  if me.tank then
    if tank then
      -- Holding it, as a tank should: watch the runner-up.
      local runner = self:Runner(cur)
      if runner and s.tankAlerts then
        local hit = edge(self.fired, "tank:" .. tostring(key), runner.pull, s.tankWarnAt, 1000)
        if hit then
          self:Alert(string.format("%s at %d%% on %s", runner.name,
            math.floor(runner.pull + 0.5), cur.name or "your target"), "warn")
        end
      end
    elseif not wasTank and s.warnPulled then
      -- Not a tank, and it just turned on you.
      self:Alert("AGGRO! " .. (cur.name or "Your target") .. " is on you", "danger")
    end
    self.fired["me:" .. tostring(key)] = nil
    return
  end

  if wasTank and tank and s.warnLostAggro then
    self:LostAggro(key, cur.name, cur.tank and cur.tank.name, GetTime())
    return
  end

  if not tank then
    local pct = self:Shown(me)
    local hit = edge(self.fired, "me:" .. tostring(key), pct, s.warnAt, s.dangerAt)
    if hit then
      self:Alert("THREAT " .. T.PctText(pct), hit)
    end
  end
end

--- A mob a tank held has turned away. Said once, and marked on its plate.
function T:LostAggro(key, mobName, toName, now)
  local last = self.lost[key]
  if last and now - last < LOST_SHOW then return end
  self.lost[key] = now
  self.fired["tank:" .. tostring(key)] = nil
  if not self:Settings().warnLostAggro then return end
  local text = "LOST AGGRO: " .. (mobName or "a mob")
  if toName then text = text .. " -> " .. toName end
  self:Alert(text, "danger")
end

--[[ Tank mode's list of mobs you hold, compared with the last one.

     A mob in the last list that is missing from this one has turned to
     someone else -- unless it died, which UNIT_DIED tells us, or the fight
     is over. Only lists a moment apart are compared: after a gap, a
     missing mob says nothing about aggro. ]]
function T:TankModeReply(seen, now)
  if not seen then return end
  local s = self:Settings()
  local gap = self.lastTM and (now - self.lastTM) or nil
  self.lastTM = now

  for low, m in pairs(self.tankMobs) do
    if not seen[low] then
      local died = self.died[low]
      local fighting = UnitAffectingCombat and UnitAffectingCombat("player")
      if gap and gap <= STALE and fighting and self:IsTank()
         and not (died and now - died < STALE) then
        self:LostAggro(low, m.creature, nil, now)
      end
      self.tankMobs[low] = nil
    elseif s.tankAlerts and self:IsTank() then
      local hit = edge(self.fired, "tank:" .. tostring(low), m.pull, s.tankWarnAt, 1000)
      if hit then
        self:Alert(string.format("%s at %d%% on %s", m.name, math.floor(m.pull + 0.5),
          m.creature), "warn")
      end
    end
  end
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

--[[ Your standing on one mob, for a nameplate. In order: a mob you just
     lost, the live table if it is that mob, tank mode's entry for it, and
     what you last saw on it. Returns pct, colour, fresh, text. ]]
function T:ForMob(key, guid)
  local s = self:Settings()
  local now = GetTime()
  local low = guid and T.LowGuid(guid)

  local lostAt = (low and self.lost[low]) or (key and self.lost[key])
  if lostAt and now - lostAt <= LOST_SHOW then
    return 100, RED, true, "LOST"
  end

  local live = self:Live()
  if live and live.key == key and live.me then
    return self:Display(live)
  end

  local tm = low and self.tankMobs[low]
  if tm and now - tm.at <= STALE then
    return tm.pull, self:TankColor(tm.pull), true, T.PctText(tm.pull)
  end

  local m = key and self.memory[key]
  if m and m.pct and now - m.at <= s.plateMemory then
    return m.pct, m.color, false, m.text
  end
  return nil
end

--- Anything a nameplate could show? Lets the plate pass skip its work.
function T:AnythingForPlates()
  return self.current ~= nil or next(self.memory) ~= nil
      or next(self.tankMobs) ~= nil or next(self.lost) ~= nil
end

----------------------------------------------------------------------
-- preview
----------------------------------------------------------------------

--[[ Test data on screen for a few seconds, so the frames, the plates and
     the warnings can be placed and sized out of combat. Uses the real
     drawing paths -- a preview that drew differently would be a preview of
     something else. In tank mode it previews what a tank sees. ]]
function T:Demo(seconds)
  local now = GetTime()
  local me = myName() or "You"
  local key, guid = self:TargetKey()
  key = key or "demo"
  local tank = self:IsTank()
  local function row(name, class, isTank, threat, perc, melee)
    local r = { name = name, class = class, tank = isTank, threat = threat,
                perc = perc, melee = melee, isMe = (name == me) }
    r.pull = T.PullPercent(r)
    r.tps = threat / 30
    return r
  end
  local rows
  if tank then
    rows = {
      row(me, classOf(me), true, 48200, 100, true),
      row("Stabbs", "ROGUE", false, 45100, 94, true),
      row("Frosty", "MAGE", false, 33600, 70, false),
      row("Dotsworth", "WARLOCK", false, 21000, 44, false),
      row("Mendy", "PRIEST", false, 9800, 20, false),
    }
  else
    rows = {
      row(me, classOf(me), false, 51100, 106, false),
      row("Tanky", "WARRIOR", true, 48200, 100, true),
      row("Stabbs", "ROGUE", false, 40400, 84, true),
      row("Frosty", "MAGE", false, 33600, 70, false),
      row("Mendy", "PRIEST", false, 9800, 20, false),
    }
  end
  table.sort(rows, function(a, b) return a.threat > b.threat end)
  local cur = { key = key, guid = guid, low = T.LowGuid(guid),
                name = UnitName("target") or "Training Dummy", at = now, rows = rows }
  for _, r in ipairs(rows) do
    if r.isMe then cur.me = r end
    if r.tank then cur.tank = r end
  end
  if tank then
    self.tankMobs = {
      [1] = { creature = "Whelp", name = "Frosty", perc = 62, pull = 62 / 1.1, at = now },
      [2] = { creature = "Whelp", name = "Stabbs", perc = 98, pull = 98 / 1.1, at = now },
    }
  end
  self.demoUntil = nil
  self.fired = {}
  self:SetCurrent(cur)
  self.demoUntil = now + (seconds or 15)
end

function T:StopDemo()
  self.demoUntil = nil
  self.current = nil
  self.tankMobs = {}
  self.heldKey = nil
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
    self:ResetHistory()
    self:Changed()
  end
  -- Ask straight away rather than up to an interval later: the first
  -- thing anyone does on a new target is look at its threat.
  self.nextPoll = 0
end

--- A unit died. Kept by low guid, so a mob leaving tank mode's list because
--- it died is not mistaken for one that turned to someone else.
function T:OnUnitDied(guid)
  local low = T.LowGuid(guid)
  if low then self.died[low] = GetTime() end
end

--- Forget what is no longer worth remembering. Runs once a second.
function T:Prune()
  local now = GetTime()
  local keep = self:Settings().plateMemory + 5
  for k, m in pairs(self.memory) do
    if now - (m.at or 0) > keep then self.memory[k] = nil end
  end
  for k, t in pairs(self.lost) do
    if now - t > LOST_SHOW then self.lost[k] = nil end
  end
  for k, t in pairs(self.died) do
    if now - t > STALE then self.died[k] = nil end
  end
  if not self.demoUntil then
    for low, m in pairs(self.tankMobs) do
      if now - m.at > STALE then self.tankMobs[low] = nil end
    end
  end
end

--[[ The fight is over: drop everything that belonged to it, including the
     pooled rows, so a night of pulls with different raiders does not keep
     every name it ever saw. ]]
function T:OnCombatEnd()
  self.fired = {}
  self.heldKey = nil
  self.lastTM = nil
  if not self.demoUntil then
    self.tankMobs = {}
    self.current = nil
    rowPool = {}
  end
  self:Changed()
end

local function tick()
  local now = GetTime()
  if now < (T.nextPoll or 0) then return end
  local s = T:Settings()
  T.nextPoll = now + s.interval
  T:Poll()
  if now - (T.lastPrune or 0) >= 1 then
    T.lastPrune = now
    T:Prune()
  end
  -- Readings age out even when nothing new arrives; redraw so a stale
  -- figure disappears instead of hanging on the frame.
  if T.current and not T.demoUntil and now - (T.current.at or 0) > STALE then
    T.current = nil
    T:Changed()
  end
end

function T:Start()
  if self.frame or not CreateFrame then return end
  -- Saved values are checked again every session.
  if W.db and type(W.db.threat) == "table" then W.db.threat._ok = nil end
  local f = CreateFrame("Frame", "WrekkitThreatFrame")
  self.frame = f
  f:SetScript("OnEvent", function()
    if event == "CHAT_MSG_ADDON" then
      -- Cheap test first: every addon's traffic comes through here.
      if arg2 and string.find(arg2, "TWTv4=", 1, true) then
        W.Guard("threat packet", function() T:OnMessage(arg2) end)
      end
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
  return string.format("threat: %d server replies, last %s; role %s%s", self.packets, age,
    self:IsTank() and "tank" or "damage/heal",
    self.why and ("; idle: " .. self.why) or "")
end

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

  -- flashing: keeps going for as long as the danger lasts, unlike the
  -- warnings above, which say it once
  flash = true,
  flashAt = 85,            -- you, at this % to pull (or a mob on you)
  tankFlashAt = 90,        -- tanking: the runner-up on any mob you hold
  flashFrame = true,       -- blink the target-frame %
  flashScreen = false,     -- pulse the screen edges as well
  flashSpeed = 3,          -- blinks a second

  -- mobs you are not targeting, watched through their nameplates
  watchMobs = true,        -- read each mob's own target (needs SuperWoW)
  mobSummary = true,       -- "4 held - 1 slipping - 1 loose" under the %
  coTanks = "",            -- names whose mobs are not loose, comma-separated

  -- taunting
  tauntPopup = true,       -- a button to click when a mob gets away
  tauntSpell = "",         -- empty: the class's own (T.TAUNT_DEFAULTS);
                           -- else names, comma-separated, best first
  tauntAoE = false,        -- also fall back to Challenging Shout / Roar
  tauntKeepTarget = true,  -- cast at the mob without changing target
  -- tauntX / tauntY: where the popup was dragged, from screen centre

  -- mob frames: a small frame per mob in the fight, with who it is on
  mobFrames = true,
  mobFramesFor = "tank",   -- "tank" | "everyone"
  mobFramesMin = 2,        -- shown from this many mobs
  mobFramesMax = 8,        -- at most this many rows
  -- Collapsed, mobs that are fine share one line ("All 10 on you") and
  -- only the ones in trouble get a row.
  mobFramesCollapse = "auto",  -- "auto" | "always" | "never"
  mobFramesCollapseAt = 4,     -- auto: collapse above this many mobs
  mobFramesExpandAt = 80,      -- collapsed, a mob comes back out when the
                               -- runner-up has this % of your threat

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
  s.flashAt = clamp(s.flashAt, 30, 150, d.flashAt)
  s.tankFlashAt = clamp(s.tankFlashAt, 30, 150, d.tankFlashAt)
  s.flashSpeed = clamp(s.flashSpeed, 1, 6, d.flashSpeed)
  s.textSize = math.floor(clamp(s.textSize, 14, 48, d.textSize))
  s.frameScale = clamp(s.frameScale, 0.6, 2.5, d.frameScale)
  s.plateMemory = clamp(s.plateMemory, 0, 30, d.plateMemory)
  s.plateSize = math.floor(clamp(s.plateSize, 7, 20, d.plateSize))
  s.opacity = clamp(s.opacity, 0.2, 1, d.opacity)
  if type(s.frameName) ~= "string" then s.frameName = "" end
  if type(s.coTanks) ~= "string" then s.coTanks = "" end
  if type(s.tauntSpell) ~= "string" then s.tauntSpell = "" end
  s.tauntX, s.tauntY = tonumber(s.tauntX), tonumber(s.tauntY)
  s.mobsX, s.mobsY = tonumber(s.mobsX), tonumber(s.mobsY)
  s.mobFramesFor = oneOf(s.mobFramesFor, { "tank", "everyone" }, d.mobFramesFor)
  s.mobFramesMin = math.floor(clamp(s.mobFramesMin, 1, 10, d.mobFramesMin))
  s.mobFramesMax = math.floor(clamp(s.mobFramesMax, 2, 15, d.mobFramesMax))
  s.mobFramesCollapse = oneOf(s.mobFramesCollapse, { "auto", "always", "never" }, d.mobFramesCollapse)
  s.mobFramesCollapseAt = math.floor(clamp(s.mobFramesCollapseAt, 1, 15, d.mobFramesCollapseAt))
  s.mobFramesExpandAt = math.floor(clamp(s.mobFramesExpandAt, 30, 130, d.mobFramesExpandAt))
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
local TANK_ICONS = { "defensivestance", "bearform" }
local FURY_ICON = "sealoffury"
-- Righteous Fury by spell id, for SuperWoW's UnitBuff (its third return).
local FURY_IDS = { [25780] = true, [25781] = true }
local FURY_NAME = "righteous fury"

--- Every buff on the player, as { icon, id, name } -- read three ways so
--- one client's quirk cannot hide a buff: UnitBuff (SuperWoW adds the
--- spell id), and the player-only GetPlayerBuff API as a second source.
function T:PlayerBuffs()
  local out = {}
  if UnitBuff then
    for i = 1, 32 do
      local icon, _, id = UnitBuff("player", i)
      if not icon then break end
      id = tonumber(id)
      local name = (id and SpellInfo) and SpellInfo(id) or nil
      table.insert(out, { icon = icon, id = id, name = name })
    end
  end
  if GetPlayerBuff and GetPlayerBuffTexture then
    for i = 0, 31 do
      local index = GetPlayerBuff(i, "HELPFUL")
      if not index or index < 0 then break end
      local icon = GetPlayerBuffTexture(index)
      if icon then table.insert(out, { icon = icon }) end
    end
  end
  return out
end

--- Is this buff Righteous Fury? By icon, by id, or by name -- any one will do.
local function isFury(b)
  if b.icon and string.find(string.lower(b.icon), FURY_ICON, 1, true) then return true end
  if b.id and FURY_IDS[b.id] then return true end
  if b.name and string.lower(b.name) == FURY_NAME then return true end
  return false
end

function T:DetectTank()
  local _, class = UnitClass("player")
  class = class and string.upper(class) or ""
  if class == "WARRIOR" or class == "DRUID" then
    if not GetNumShapeshiftForms or not GetShapeshiftFormInfo then return false end
    for i = 1, (GetNumShapeshiftForms() or 0) do
      local icon, _, active = GetShapeshiftFormInfo(i)
      if active and icon then
        local lower = string.lower(icon)
        for _, want in ipairs(TANK_ICONS) do
          if string.find(lower, want, 1, true) then return true end
        end
      end
    end
    return false
  elseif class == "PALADIN" then
    for _, b in ipairs(self:PlayerBuffs()) do
      if isFury(b) then return true end
    end
  end
  return false
end

--- What the role check sees, for /wrek threat role.
function T:ExplainRole()
  self.tauntCache = nil
  local _, class = UnitClass("player")
  local s = self:Settings()
  self.roleAt = nil
  W.Print(string.format("I'm the tank: setting %s, class %s, detected %s.",
    s.tankMode, tostring(class), self:DetectTank() and "TANK" or "not tank"))
  if s.tankMode ~= "auto" then
    W.Print("  (the setting overrides detection; set it to auto to use it)")
  end
  local wants, custom = self:TauntWants()
  local names, have = {}, {}
  for _, w in ipairs(wants) do table.insert(names, w.name) end
  for _, sp in ipairs(self:TauntSpells()) do table.insert(have, sp.name) end
  W.Print("  taunts " .. (custom and "(yours)" or "(class default)") .. ": " ..
    (table.getn(names) > 0 and table.concat(names, ", ") or "none for this class") ..
    "; in your spellbook: " .. (table.getn(have) > 0 and table.concat(have, ", ") or "none"))
  local up = string.upper(class or "")
  if up == "WARRIOR" or up == "DRUID" then
    for i = 1, (GetNumShapeshiftForms and GetNumShapeshiftForms() or 0) do
      local icon, name, active = GetShapeshiftFormInfo(i)
      W.Print(string.format("  form %d: %s %s%s", i, tostring(name), tostring(icon),
        active and "  <- active" or ""))
    end
  else
    local buffs = self:PlayerBuffs()
    if table.getn(buffs) == 0 then W.Print("  no buffs found") end
    for _, b in ipairs(buffs) do
      W.Print(string.format("  buff: %s  id %s  %s%s", tostring(b.icon), tostring(b.id),
        tostring(b.name or ""), isFury(b) and "  <- Righteous Fury" or ""))
    end
  end
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
  if cur.low then self.guidByLow[cur.low] = guid end
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
    self:LostAggro(key, cur.name, cur.tank and cur.tank.name, GetTime(), cur.guid)
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
function T:LostAggro(key, mobName, toName, now, guid)
  local last = self.lost[key]
  if last and now - last < LOST_SHOW then return end
  self.lost[key] = now
  self.fired["tank:" .. tostring(key)] = nil
  guid = guid or (type(key) == "number" and self.guidByLow[key]) or nil
  self:QueueTaunt(guid, mobName, toName, "lost")
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

  -- A mob on someone it should not be on beats any percentage.
  local w = guid and self.watch[guid]
  if w and w.confirmed and now - w.at <= STALE then
    if w.state == "loose" then return 100, RED, true, "LOOSE" end
    if w.state == "onme" then return 100, RED, true, "AGGRO" end
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

--[[ Should things be flashing right now? Returns the percentage and colour
     to flash with, or nil.

     Not tanking: you are at flashAt or more of the way to pulling, or a
     mob is already on you. Tanking: whoever is closest to pulling the
     target, or any other mob you hold, is at tankFlashAt or more. Checked
     on every pass rather than fired once, so it flashes exactly as long
     as the danger lasts and stops on its own when it passes. ]]
function T:Alarm()
  local s = self:Settings()
  if not s.enabled or not s.flash then return nil end
  local cur = self:Live()
  local me = cur and cur.me
  if self:IsTank() then
    local worst
    if me and me.tank then
      local runner = self:Runner(cur)
      worst = runner and runner.pull
    end
    local now = GetTime()
    for _, m in pairs(self.tankMobs) do
      if now - m.at <= STALE and (not worst or m.pull > worst) then worst = m.pull end
    end
    if worst and worst >= s.tankFlashAt then return worst, RED end
    if self:CountWatch("loose") > 0 then return 100, RED end
    return nil
  end
  if self:CountWatch("onme") > 0 then return 100, RED end
  if not me then return nil end
  if me.tank then return 100, RED end
  -- Always the distance to pulling, whatever the display shows: that is
  -- what the limit is set in.
  local pull = me.pull or T.PullPercent(me)
  if pull >= s.flashAt then return pull, self:Color(self:Shown(me)) end
  return nil
end

--- Anything a nameplate could show? Lets the plate pass skip its work.
function T:AnythingForPlates()
  if self.current ~= nil or next(self.memory) ~= nil
     or next(self.tankMobs) ~= nil or next(self.lost) ~= nil then
    return true
  end
  -- In a fight the plates are where loose mobs are found, data or not.
  local s = self:Settings()
  return s.watchMobs and UnitAffectingCombat and UnitAffectingCombat("player") and true or false
end

----------------------------------------------------------------------
-- mobs you are not targeting
----------------------------------------------------------------------

--[[ The server tells a tank about the mobs they HOLD. A mob that has
     already gone to a healer is not one of them, so it never appears --
     and that is the one a tank most needs to see. SuperWoW lets a guid
     stand for a unit, and "<guid>target" for what that unit is targeting,
     which answers the question directly for every mob with a nameplate.

     A mob is
       loose   tanking, it is on a player in your group who is not you
               (or one of the co-tanks named in settings)
       onme    not tanking, it is on you
     and only counts once it has stayed that way for LOOSE_CONFIRM: mobs
     flick their target to whoever they cast at, and a fireball at a
     priest is not a loose mob. ]]
local LOOSE_CONFIRM = 1.0
T.watch = {}         -- guid -> { state, who, name, since, at, confirmed }
T.guidByLow = {}     -- low 16 bits -> full guid, for every mob seen

local coTankList, coTankFor = {}, nil
local function isCoTank(name)
  local raw = T:Settings().coTanks
  if raw ~= coTankFor then
    coTankFor = raw
    coTankList = {}
    for n in string.gfind(raw, "[^,%s]+") do coTankList[string.lower(n)] = true end
  end
  return name and coTankList[string.lower(name)] or false
end

--- Look at one mob, by guid, and return "loose" / "onme" once confirmed.
--[[ id is the mob's guid, or -- without SuperWoW -- a key from the group
     scan (see ScanGroup). unit is how to ask the client about it: the guid
     itself, or a unit token such as "raid7target"; tunit is what that unit
     is targeting ("raid7targettarget"), passed in so no string is built. ]]
function T:WatchMob(id, mobName, unit, tunit)
  local s = self:Settings()
  if not s.enabled or not s.watchMobs or not id then return nil end
  local guid = (type(id) == "string" and string.sub(id, 1, 2) == "0x") and id or nil
  unit = unit or guid
  if not unit then return nil end
  local now = GetTime()
  local state, who

  local inFight = UnitAffectingCombat and UnitAffectingCombat(unit)
  local hostile = not UnitCanAttack or UnitCanAttack("player", unit)
  if inFight and hostile then
    local tok = tunit or (unit .. "target")
    if UnitExists(tok) then
      if UnitIsUnit(tok, "player") then
        if not self:IsTank() then state = "onme" end
      elseif self:IsTank() and UnitIsPlayer(tok) == 1 then
        who = UnitName(tok)
        if who and not isCoTank(who) and W.capture:InGroup(who) then state = "loose" end
      end
    end
  end

  -- Remembered so tank mode's low guids can be turned back into a mob.
  local low = guid and T.LowGuid(guid)
  if low then self.guidByLow[low] = guid end

  local w = self.watch[id]
  if not state then
    if w then self.watch[id] = nil end
    return nil
  end
  if not w or w.state ~= state or w.who ~= who then
    w = { state = state, who = who, since = now }
    self.watch[id] = w
  end
  w.at, w.name = now, mobName or w.name
  -- Without a guid, the token is how the taunt bar reaches it later.
  if not guid then w.unit = unit end
  if not w.confirmed and now - w.since >= LOOSE_CONFIRM then
    w.confirmed = true
    if state == "loose" then self:QueueTaunt(guid, w.name, who, "loose", w.unit) end
    if state == "loose" and s.warnLostAggro then
      self:Alert("LOOSE: " .. (w.name or "a mob") .. " on " .. (who or "?"), "danger")
    elseif state == "onme" and s.warnPulled and not (self.current and self.current.guid == guid) then
      -- Your target says so through its own table; this is for the rest.
      self:Alert("AGGRO! " .. (w.name or "a mob") .. " is on you", "danger")
    end
  end
  return w.confirmed and state or nil
end

----------------------------------------------------------------------
-- the group scan: mobs found through what the group is targeting
----------------------------------------------------------------------

--[[ Every client, SuperWoW or not, can ask what each member of the group
     is targeting ("raid7target") and what THAT is targeting
     ("raid7targettarget") -- the trick vanilla threat addons were built
     on. So every mob anyone in the group has targeted is known, with its
     health and who it is hitting.

     With SuperWoW each one also gives its guid, and joins the nameplate
     mobs by it. Without SuperWoW it is the only way to see any mob but
     your own target, and a mob is told apart from others of the same
     name by its health. A mob nobody has targeted stays unseen -- the
     price of no SuperWoW, and why it is still worth having.

     The tokens are built once; a pass makes no strings. ]]
local SCAN_EVERY = 0.25
local TOKENS
local function buildTokens()
  TOKENS = {}
  local function add(u) table.insert(TOKENS, { u = u, t = u .. "target" }) end
  add("target")
  add("pettarget")
  for i = 1, 4 do add("party" .. i .. "target") add("partypet" .. i .. "target") end
  for i = 1, 40 do add("raid" .. i .. "target") add("raidpet" .. i .. "target") end
end

T.groupMobs = {}     -- key -> { key, guid, unit, tunit, name, hp, max, who, ... }
local found = {}     -- this pass's entries, reused
local nextKey = 0

--- A living hostile in the fight, by unit token.
local function fightingUnit(u)
  if UnitIsDead and UnitIsDead(u) then return false end
  if UnitCanAttack and not UnitCanAttack("player", u) then return false end
  if UnitIsPlayer and UnitIsPlayer(u) == 1 then return false end
  if UnitAffectingCombat and not UnitAffectingCombat(u) then return false end
  return true
end

local function hpPercent(u)
  local hp, max = UnitHealth(u) or 0, UnitHealthMax(u) or 0
  if max <= 0 then return 100 end
  return hp / max * 100
end

--[[ Which entry from the last pass is this mob? By guid when there is
     one; otherwise the same name and the nearest health -- mobs lose
     health, they do not trade it -- or a new entry. ]]
local function match(guid, name, hp, taken)
  if guid then return T.groupMobs[guid] end
  local best, bestDiff
  for _, e in pairs(T.groupMobs) do
    if not e.guid and e.name == name and not taken[e] then
      local d = math.abs((e.hpPct or 0) - hp)
      if d <= 25 and (not best or d < bestDiff) then best, bestDiff = e, d end
    end
  end
  return best
end

function T:ScanGroup()
  local s = self:Settings()
  if not s.enabled or not (s.watchMobs or s.mobFrames) then return end
  local now = GetTime()
  if now - (self.lastScan or 0) < SCAN_EVERY then return end
  self.lastScan = now
  if not TOKENS then buildTokens() end

  local n = 0
  local taken = {}
  local fresh = {}
  for i = 1, table.getn(TOKENS) do
    local tk = TOKENS[i]
    local u = tk.u
    local exists, guid = UnitExists(u)
    if exists and fightingUnit(u) then
      if type(guid) ~= "string" or string.sub(guid, 1, 2) ~= "0x" then guid = nil end
      -- The same mob through another member's target?
      local dup = false
      for j = 1, n do
        local f = found[j]
        if (guid and f.guid == guid) or (not guid and not f.guid and UnitIsUnit(u, f.unit)) then
          dup = true
          break
        end
      end
      if not dup then
        local name = UnitName(u) or "?"
        local hp = hpPercent(u)
        local e = match(guid, name, hp, taken)
        if not e then
          nextKey = nextKey + 1
          e = { key = guid or ("mob" .. nextKey), guid = guid, first = now }
        end
        taken[e] = true
        e.unit, e.tunit, e.name, e.hpPct = u, tk.t, name, hp
        e.hp, e.max = UnitHealth(u) or 0, UnitHealthMax(u) or 0
        e.isTarget = (u == "target") or UnitIsUnit(u, "target") and true or false
        e.who, e.whoClass, e.onMe = nil, nil, false
        if UnitExists(tk.t) then
          e.onMe = UnitIsUnit(tk.t, "player") and true or false
          e.who = UnitName(tk.t)
          local _, class = UnitClass(tk.t)
          e.whoClass = class
        end
        e.seen = now
        e.state = self:WatchMob(e.key, name, u, tk.t)
        n = n + 1
        found[n] = e
        fresh[e.key] = e
      end
    end
  end
  for j = n + 1, table.getn(found) do found[j] = nil end
  -- Mobs nobody is targeting now are kept a moment: targets flick.
  for key, e in pairs(self.groupMobs) do
    if not fresh[key] and now - (e.seen or 0) <= 2 then fresh[key] = e end
  end
  self.groupMobs = fresh
end

--- How many confirmed mobs are in a state right now.
function T:CountWatch(state)
  local n, now = 0, GetTime()
  for _, w in pairs(self.watch) do
    if w.confirmed and w.state == state and now - w.at <= STALE then n = n + 1 end
  end
  return n
end

--[[ The tank's picture in one line: how many mobs are held, how many of
     those someone is closing in on, how many are loose. Returns the text
     and its colour, or nil when there is only the one mob -- the % says
     everything then. ]]
function T:MobSummary()
  local s = self:Settings()
  if not s.enabled or not s.mobSummary or not self:IsTank() then return nil end
  local now = GetTime()
  local held, slipping = 0, 0
  for _, m in pairs(self.tankMobs) do
    if now - m.at <= STALE then
      held = held + 1
      if m.pull >= s.tankWarnAt then slipping = slipping + 1 end
    end
  end
  local loose = self:CountWatch("loose")
  if held + loose <= 1 then return nil end
  local parts = { held .. " held" }
  if slipping > 0 then table.insert(parts, "|cffff8c1a" .. slipping .. " slipping|r") end
  if loose > 0 then table.insert(parts, "|cfff23333" .. loose .. " loose|r") end
  local color = (loose > 0 and RED) or (slipping > 0 and ORANGE) or T.TANK_COLOR
  return table.concat(parts, "  "), color
end

--- Confirmed loose mobs, for the window: { name, who }.
function T:LooseMobs()
  local out, now = {}, GetTime()
  for _, w in pairs(self.watch) do
    if w.confirmed and w.state == "loose" and now - w.at <= STALE then
      table.insert(out, { name = w.name or "?", who = w.who or "?" })
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
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
      row("Stabbs", "ROGUE", false, 48200, 100, true),
      row("Frosty", "MAGE", false, 33600, 70, false),
      row("Dotsworth", "WARLOCK", false, 21000, 44, false),
      row("Mendy", "PRIEST", false, 9800, 20, false),
    }
  else
    rows = {
      row(me, classOf(me), false, 55400, 115, false),
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
-- taunting
----------------------------------------------------------------------

--[[ A mob got away: offer to taunt it back.

     Each one is queued with what is needed to reach it -- its guid when
     known, otherwise its name -- and leaves the queue when it is back on
     you, dies, or TAUNT_KEEP seconds pass. The popup shows the queue; a
     keybinding and /wrek taunt take the newest. ]]
local TAUNT_KEEP = 10
T.taunts = {}

function T:QueueTaunt(guid, name, who, reason, unit)
  if not self:IsTank() then return end
  local now = GetTime()
  for _, t in ipairs(self.taunts) do
    if (guid and t.guid == guid) or (not guid and not t.guid and t.name == name) then
      t.at, t.who, t.reason = now, who or t.who, reason
      t.unit = unit or t.unit
      return t
    end
  end
  local t = { guid = guid, name = name or "a mob", who = who, reason = reason, at = now,
              unit = unit }
  table.insert(self.taunts, 1, t)
  while table.getn(self.taunts) > 3 do table.remove(self.taunts) end
  return t
end

--- The queue, without anything that is settled: back on you, dead, old.
function T:Taunts()
  local now = GetTime()
  for i = table.getn(self.taunts), 1, -1 do
    local t = self.taunts[i]
    local low = t.guid and T.LowGuid(t.guid)
    local back = low and self.tankMobs[low] and now - self.tankMobs[low].at < 1 and now - t.at > 1
    local dead = (low and self.died[low]) or (t.guid and UnitIsDead and UnitIsDead(t.guid))
    if back or dead or now - t.at > TAUNT_KEEP then table.remove(self.taunts, i) end
  end
  return self.taunts
end

function T:DismissTaunt(t)
  for i, x in ipairs(self.taunts) do
    if x == t then table.remove(self.taunts, i) return end
  end
end

--[[ The taunts this character knows, from the spellbook, best first. Found
     by icon rather than name so every client language works; a name typed
     in settings (a server's own taunt, say) wins over all of them. ]]
--[[ Each tank class's taunts, best first. Matched in the spellbook by icon
     where the icon is certain (any client language), and by English name
     as well, which is the only way to recognise a server's own additions.
     AoE taunts are only used if "Use AoE taunts" is on: they are long
     cooldowns, and spending one on a single loose whelp is a mistake. ]]
T.TAUNT_DEFAULTS = {
  WARRIOR = {
    { name = "Taunt", icon = "spell_nature_reincarnation" },
    { name = "Mocking Blow", icon = "ability_warrior_punishingblow" },
    { name = "Challenging Shout", icon = "ability_bullrush", aoe = true },
  },
  DRUID = {
    { name = "Growl", icon = "ability_physical_taunt" },
    { name = "Challenging Roar", icon = "ability_druid_challangingroar", aoe = true },
  },
  PALADIN = {
    { name = "Hand of Reckoning" },
    { name = "Righteous Defense" },
  },
  SHAMAN = {
    { name = "Earthshaker Slam" },
  },
}

--- The taunt list in force: the names typed in settings (comma-separated,
--- in that order), else the class's defaults.
function T:TauntWants()
  local custom = self:Settings().tauntSpell or ""
  local wants = {}
  for name in string.gfind(custom, "[^,]+") do
    name = string.gsub(string.gsub(name, "^%s+", ""), "%s+$", "")
    if name ~= "" then table.insert(wants, { name = name }) end
  end
  if table.getn(wants) > 0 then return wants, true end
  local _, class = UnitClass("player")
  local aoe = self:Settings().tauntAoE
  for _, w in ipairs(self.TAUNT_DEFAULTS[string.upper(class or "")] or {}) do
    if aoe or not w.aoe then table.insert(wants, w) end
  end
  return wants, false
end

--[[ The taunts this character knows, from the spellbook, in the order of
     TauntWants. Later spellbook entries are higher ranks of the same spell,
     so they replace earlier ones. Cached for ten seconds. ]]
function T:TauntSpells()
  local now = GetTime()
  if self.tauntCache and now - self.tauntCacheAt < 10 then return self.tauntCache end
  local wants = self:TauntWants()
  local found = {}
  if GetSpellName then
    local i = 1
    while true do
      local name = GetSpellName(i, "spell")
      if not name then break end
      local icon = string.lower((GetSpellTexture and GetSpellTexture(i, "spell")) or "")
      local lname = string.lower(name)
      for r, w in ipairs(wants) do
        if lname == string.lower(w.name)
           or (w.icon and string.find(icon, w.icon, 1, true)) then
          found[r] = { index = i, name = name, icon = GetSpellTexture and GetSpellTexture(i, "spell") }
          break
        end
      end
      i = i + 1
    end
  end
  local list = {}
  for r = 1, table.getn(wants) do
    if found[r] then table.insert(list, found[r]) end
  end
  self.tauntCache, self.tauntCacheAt = list, now
  return list
end

--- Seconds until a spellbook spell is ready; 0 when it is.
function T.SpellCooldown(index)
  if not GetSpellCooldown then return 0 end
  local start, duration = GetSpellCooldown(index, "spell")
  if not start or start == 0 or not duration then return 0 end
  local left = start + duration - GetTime()
  if left < 0 then left = 0 end
  return left
end

--- The first taunt that is ready, or nil and how long the soonest takes.
function T:ReadyTaunt()
  local soonest
  for _, sp in ipairs(self:TauntSpells()) do
    local cd = T.SpellCooldown(sp.index)
    if cd <= 0 then return sp end
    if not soonest or cd < soonest then soonest = cd end
  end
  return nil, soonest
end

--[[ Taunt one queued mob. Must run from a click or a key: 1.12 casts only
     in answer to a hardware event, which both of those are.

     With SuperWoW the spell goes straight at the mob's guid and your
     target stays where it was. Without it, or with "keep my target" off,
     the mob is targeted first -- by guid if known, else by name. ]]
function T:Taunt(t)
  t = t or self:Taunts()[1]
  if not t then
    W.Print("nothing to taunt.")
    return false
  end
  local spell, wait = self:ReadyTaunt()
  if not spell then
    if wait then
      W.Print(string.format("taunt is on cooldown: %.1fs.", wait))
    else
      W.Print("no taunt found in your spellbook. Name yours under Threat -> Taunt spells.")
    end
    return false
  end

  local s = self:Settings()
  local cast = false
  if t.guid and s.tauntKeepTarget and SpellInfo and CastSpellByName then
    cast = pcall(CastSpellByName, spell.name, t.guid)
  end
  if not cast then
    --[[ Reach the mob: its guid with SuperWoW; without, the unit token the
         group scan found it through (someone's target), if that token still
         names this mob; failing both, by name. ]]
    if t.guid and TargetUnit then
      pcall(TargetUnit, t.guid)
    elseif t.unit and TargetUnit and UnitExists(t.unit) and UnitName(t.unit) == t.name then
      pcall(TargetUnit, t.unit)
    elseif t.name and TargetByName then
      pcall(TargetByName, t.name, true)
    end
    if CastSpell then cast = pcall(CastSpell, spell.index, "spell") end
  end
  if cast then
    t.tauntedAt = GetTime()
    self:DismissTaunt(t)
  end
  return cast
end

--- For the keybinding and /wrek taunt.
function T:TauntNext()
  return self:Taunt(self:Taunts()[1])
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
  for g, w in pairs(self.watch) do
    if now - w.at > STALE then self.watch[g] = nil end
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
  self.watch = {}
  self.groupMobs = {}
  self.guidByLow = {}
  self.taunts = {}
  if W.ui and W.ui.mobs then W.ui.mobs:Reset() end
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

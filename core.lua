--[[ Wrekkit :: core

Namespace, palette, formatting and the small utility layer everything else
sits on. Vanilla 1.12 runs Lua 5.0, so throughout this addon:

  table.getn(t)   not  #t
  math.mod(a, b)  not  a % b
  string.gfind    not  string.gmatch
  arg             not  ...
  local f = function() end   -- closures are fine, 5.0 has upvalues

Anything that reaches for 5.1+ syntax will silently fail to compile the
whole file, so tools/vanilla_lint.lua guards the release.
]]

Wrekkit = {}

--[[ Read from the .toc instead of repeating it here. This was a second copy of
     the version, and a second copy is one that goes stale: it still said 0.1.0
     after the .toc went to 0.1.1, so /wrek status -- the one thing asked for
     when reporting a bug -- named a build that was not running, and the peers
     sync told everyone else the same wrong number. ]]
Wrekkit.version = (GetAddOnMetadata and GetAddOnMetadata("Wrekkit", "Version"))
                  or "unknown"

local W = Wrekkit

----------------------------------------------------------------------
-- palette
----------------------------------------------------------------------

-- Deliberately low-chroma surfaces so class colours and the amber accent
-- are the only saturated things on screen.
W.color = {
  bg        = { 0.055, 0.058, 0.066 },
  panel     = { 0.086, 0.090, 0.101 },
  panelHi   = { 0.118, 0.125, 0.141 },
  border    = { 0.180, 0.190, 0.212 },
  borderHi  = { 0.290, 0.305, 0.337 },
  text      = { 0.898, 0.906, 0.925 },
  textDim   = { 0.549, 0.569, 0.612 },
  textFaint = { 0.357, 0.373, 0.412 },
  accent    = { 0.878, 0.635, 0.173 },
  accentHi  = { 1.000, 0.816, 0.400 },
  damage    = { 0.310, 0.600, 0.902 },
  taken     = { 0.851, 0.310, 0.325 },
  healing   = { 0.400, 0.780, 0.463 },
  overheal  = { 0.400, 0.780, 0.463 },
  --[[ Deliberately NOT red. Death markers are drawn as full-height
       vertical lines over the chart, and this used to be {0.902,0.294,0.353}
       against a "Damage Taken" series of {0.851,0.310,0.325} -- the same red
       to any eye. The legend showed red as damage taken and said nothing
       about deaths, so the tallest, loudest marks on the chart read as a
       damage spike. Violet belongs to no series. ]]
  death     = { 0.82, 0.52, 0.98 },
}

-- 1.12 has no RAID_CLASS_COLORS on every client build, so carry our own.
W.classColor = {
  WARRIOR = { 0.78, 0.61, 0.43 },
  PALADIN = { 0.96, 0.55, 0.73 },
  HUNTER  = { 0.67, 0.83, 0.45 },
  ROGUE   = { 1.00, 0.96, 0.41 },
  PRIEST  = { 1.00, 1.00, 1.00 },
  SHAMAN  = { 0.00, 0.44, 0.87 },
  MAGE    = { 0.41, 0.80, 0.94 },
  WARLOCK = { 0.58, 0.51, 0.79 },
  DRUID   = { 1.00, 0.49, 0.04 },
  PET     = { 0.62, 0.62, 0.62 },
  ENEMY   = { 0.72, 0.44, 0.44 },
  UNKNOWN = { 0.65, 0.65, 0.65 },
}


--[[ Damage schools.

     The numbers are the client's own SPELL_SCHOOL order, which is what the
     1.12 combat log uses and what nampower passes through: 0 Physical, then
     Holy, Fire, Nature, Frost, Shadow, Arcane.

     Melee carries no school at all -- it arrives as spell id 0 -- so that is
     read as Physical rather than as unknown.

     Anything outside that range is reported as its raw number instead of
     being given a name. If this client encodes schools as a bitmask rather
     than an index, that is how it will show, which is a great deal better
     than confidently labelling Frost damage as Holy. ]]
local SCHOOL = { [0] = "Physical", "Holy", "Fire", "Nature", "Frost",
                 "Shadow", "Arcane" }

function W.SchoolName(school, spellId)
  if school == nil then
    if spellId == 0 then return "Physical" end
    return nil
  end
  local n = tonumber(school)
  if not n then return nil end
  if SCHOOL[n] then return SCHOOL[n] end
  return "School " .. n
end

function W.ClassColor(class)
  return W.classColor[class or "UNKNOWN"] or W.classColor.UNKNOWN
end

----------------------------------------------------------------------
-- formatting
----------------------------------------------------------------------

--- 1234567 -> "1.23M". Keeps three significant figures so columns of
--- numbers stay the same width and stay scannable.
function W.Short(n)
  if not n then return "0" end
  local neg = n < 0
  if neg then n = -n end
  local s
  if n >= 1000000 then
    s = string.format("%.2fM", n / 1000000)
  elseif n >= 100000 then
    s = string.format("%.0fk", n / 1000)
  elseif n >= 10000 then
    s = string.format("%.1fk", n / 1000)
  elseif n >= 1000 then
    s = string.format("%.2fk", n / 1000)
  else
    -- Floor before %d: rates are floats, and 5.0 silently truncates where
    -- newer Lua raises, so do it explicitly and get the same answer in both.
    s = string.format("%d", math.floor(n))
  end
  if neg then return "-" .. s end
  return s
end

--- 1234567 -> "1,234,567" for the detail rows where exactness matters.
function W.Comma(n)
  if not n then return "0" end
  local s = string.format("%d", math.floor(n))
  local out = ""
  local len = string.len(s)
  local i = len
  local c = 0
  while i >= 1 do
    out = string.sub(s, i, i) .. out
    c = c + 1
    if math.mod(c, 3) == 0 and i > 1 then out = "," .. out end
    i = i - 1
  end
  return out
end

--- 977 -> "16m 17s". Matches how the site labels durations.
function W.Duration(sec)
  if not sec or sec < 0 then sec = 0 end
  sec = math.floor(sec)
  local m = math.floor(sec / 60)
  local s = sec - m * 60
  if m >= 60 then
    local h = math.floor(m / 60)
    return string.format("%dh %02dm", h, m - h * 60)
  end
  if m > 0 then return string.format("%dm %02ds", m, s) end
  return string.format("%ds", s)
end

--- Axis labels on the timeline: compact, no leading zeros.
function W.Clock(sec)
  sec = math.floor(sec or 0)
  local m = math.floor(sec / 60)
  return string.format("%d:%02d", m, sec - m * 60)
end

function W.Pct(part, whole)
  if not whole or whole <= 0 then return "0.00%" end
  return string.format("%.2f%%", part / whole * 100)
end

----------------------------------------------------------------------
-- misc helpers
----------------------------------------------------------------------

function W.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffe0a22cWrekkit|r  " .. tostring(msg))
end

function W.Debug(msg)
  if W.db and W.db.debug then
    DEFAULT_CHAT_FRAME:AddMessage("|cff6b7280Wrekkit dbg|r  " .. tostring(msg))
  end
end

--- Shallow count of a hash table (table.getn only works on arrays).
function W.Count(t)
  local n = 0
  if t then for _ in pairs(t) do n = n + 1 end end
  return n
end

--- Sort helper: descending by a named numeric field, name as tiebreak so
--- equal rows don't shuffle between refreshes.
function W.ByField(field)
  return function(a, b)
    local av, bv = a[field] or 0, b[field] or 0
    if av == bv then return (a.name or "") < (b.name or "") end
    return av > bv
  end
end

----------------------------------------------------------------------
-- saved variables
----------------------------------------------------------------------

W.defaults = {
  debug = false,
  maxEncounters = 60,      -- ring buffer of stored encounters
  maxAbilities = 24,       -- per-actor ability rows persisted
  minTrashDuration = 6,    -- seconds; shorter combats are dropped
  trackOpenWorld = false,  -- only record inside instances by default
  -- Sharing is OFF until asked for: it broadcasts your name and what you
  -- have recorded to whichever channel you pick.
  shareEnabled = false,
  shareChannel = "AUTO",   -- AUTO | RAID | PARTY | GUILD
  acceptShares = true,     -- take encounters other Wrekkit users send
  fontScale = 1.0,         -- global text size multiplier
  resumeWindow = 1200,     -- seconds; rejoin the previous session within this
  sessionBarrier = 0,      -- sessions ending at or before this never resume
  autoSave = true,         -- append each encounter to disk as it finishes
  minimap = { show = true, angle = 214 },
  window = { point = "CENTER", x = 0, y = 0, w = 900, h = 620 },
}

local function applyDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      applyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

function W.InitDB()
  if type(WrekkitDB) ~= "table" then WrekkitDB = {} end
  applyDefaults(WrekkitDB, W.defaults)
  if type(WrekkitDB.encounters) ~= "table" then WrekkitDB.encounters = {} end
  W.db = WrekkitDB
end

----------------------------------------------------------------------
-- timers
----------------------------------------------------------------------

--[[ 1.12 has no C_Timer, so deferred work rides on a single OnUpdate frame.
     One frame for the whole addon keeps the per-frame cost to a single
     closure call rather than one per pending job. ]]

local pending = {}
local ticker

local function ensureTicker()
  if ticker or not CreateFrame then return end
  ticker = CreateFrame("Frame", "WrekkitTicker")
  ticker:SetScript("OnUpdate", function()
    local now = GetTime()
    local i = 1
    while i <= table.getn(pending) do
      local job = pending[i]
      if now >= job.at then
        table.remove(pending, i)
        job.fn()
      else
        i = i + 1
      end
    end
  end)
end

--- Run fn after delay seconds. Passing a key replaces any pending job with
--- that key, so repeated scheduling debounces instead of stacking.
function W.After(delay, fn, key)
  ensureTicker()
  if key then
    for i = table.getn(pending), 1, -1 do
      if pending[i].key == key then table.remove(pending, i) end
    end
  end
  table.insert(pending, { at = GetTime() + delay, fn = fn, key = key })
end

--- Close out the live encounter once combat has stayed dropped long enough
--- that the next pull is clearly a separate one.
function W.ScheduleFinish(delay)
  W.After(delay, function()
    local E = W.encounter
    if E.live and not E.inCombat then E:Finish() end
  end, "finish")
end

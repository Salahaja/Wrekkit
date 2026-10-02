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
  -- tidy: nil (on) or false -- free memory once out of combat after a fight
  minimap = { show = true, angle = 214 },
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

local function clampSetting(t, key, lo, hi, default)
  local v = tonumber(t[key])
  if not v then t[key] = default return end
  if v < lo then v = lo elseif v > hi then v = hi end
  t[key] = v
end

local function oneOf(t, key, allowed, default)
  for _, a in ipairs(allowed) do
    if t[key] == a then return end
  end
  t[key] = default
end

--[[ Put every saved setting back inside what its control can produce.

     SavedVariables outlive the code that wrote them. A value from an older
     build, a hand edit, or a range that has since narrowed would otherwise
     sit there doing something no control can show -- a row height of zero
     is an empty meter, a text scale of zero is invisible text -- and the
     settings window would display a value it cannot have set. Checked once
     at load, so nothing downstream has to guard against them. ]]
function W.SanitizeDB(db)
  clampSetting(db, "fontScale", 0.7, 1.8, 1.0)
  clampSetting(db, "maxEncounters", 1, 1000, 60)
  clampSetting(db, "maxAbilities", 4, 100, 24)
  clampSetting(db, "minTrashDuration", 1, 60, 6)
  clampSetting(db, "resumeWindow", 60, 7200, 1200)
  oneOf(db, "shareChannel", { "AUTO", "RAID", "PARTY", "GUILD" }, "AUTO")
  if db.combatLogRangeYards ~= nil then
    clampSetting(db, "combatLogRangeYards", 30, 200, 200)
  end
  if db.liveSyncInterval ~= nil then
    clampSetting(db, "liveSyncInterval", 10, 120, 30)
  end
  if db.dpsBasis ~= nil and db.dpsBasis ~= "active" then db.dpsBasis = nil end
  if db.reportOpacity ~= nil then clampSetting(db, "reportOpacity", 0.2, 1, 1) end

  local m = db.meter
  if type(m) == "table" then
    clampSetting(m, "rowHeight", 10, 32, 18)
    clampSetting(m, "opacity", 0.2, 1, 1)
    oneOf(m, "combat", { "show", "fade", "hide" }, "show")
    oneOf(m, "petMode", { "merge", "separate" }, "merge")
    oneOf(m, "segment", { "current", "last", "back2", "back3", "back4", "back5", "overall" },
      "current")
    -- A metric that no longer exists would fall back to damage while the
    -- menu ticked nothing; name it outright instead.
    if m.metric ~= "threat" and not (W.metrics and W.metrics.byKey and W.metrics.byKey[m.metric]) then
      m.metric = "damage"
    end
    if type(m.search) ~= "string" then m.search = "" end
    if type(m.window) == "table" then
      clampSetting(m.window, "w", 260, 2000, 260)
      clampSetting(m.window, "h", 110, 2000, 200)
    end
  end
end

function W.InitDB()
  if type(WrekkitDB) ~= "table" then WrekkitDB = {} end
  -- A default nothing ever read: each window keeps its own geometry. Every
  -- saved file up to 0.4.1 carries a copy of it.
  WrekkitDB.window = nil
  applyDefaults(WrekkitDB, W.defaults)
  if type(WrekkitDB.encounters) ~= "table" then WrekkitDB.encounters = {} end
  W.SanitizeDB(WrekkitDB)
  -- The threat settings are checked again on first use (W.threat:Settings).
  if type(WrekkitDB.threat) == "table" then WrekkitDB.threat._ok = nil end
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

--- Drop a keyed job scheduled with W.After, if one is pending.
function W.Cancel(key)
  for i = table.getn(pending), 1, -1 do
    if pending[i].key == key then table.remove(pending, i) end
  end
end

--- Text as it can travel inside an addon message: the sync format splits on
--- "~" and ",", so those cannot appear in a field. One function, used by
--- both ends, so a name cleaned for sending compares equal on arrival.
function W.WireText(s)
  return (string.gsub(tostring(s or ""), "[~,]", ""))
end

----------------------------------------------------------------------
-- memory
----------------------------------------------------------------------

--[[ Hand memory back once a fight is over.

     Lua 5.0 collects garbage only when allocation crosses a threshold that
     doubles after each collection, so the memory a long pull churned
     through sits there until some later moment the client picks -- often
     mid-pull, as a hitch. Collecting once things have gone quiet moves
     that cost to when nobody is pressing buttons.

     Never in combat, and only when there is something worth collecting:
     a full collection costs time in proportion to everything every addon
     holds, so it is skipped unless memory has grown by TIDY_GROWTH since
     the last one. Off with "Free memory after fights" in settings. ]]
W.TIDY_DELAY = 5          -- seconds out of combat before tidying
W.TIDY_GROWTH = 2048      -- KB of growth that makes a collection worth it

local function luaKB()
  if gcinfo then return gcinfo() end
  if collectgarbage then
    local ok, kb = pcall(collectgarbage, "count")
    if ok and type(kb) == "number" then return kb end
  end
  return nil
end
W.MemoryKB = luaKB

function W.ScheduleTidy()
  if W.db and W.db.tidy == false then return end
  W.After(W.TIDY_DELAY, function() W.Tidy() end, "tidy")
end

function W.Tidy(force)
  local E = W.encounter
  if E and (E.live or (E.ReallyInCombat and E:ReallyInCombat())) then return false end
  local before = luaKB()
  local floor = W.tidyFloor or 0
  if not force and before and before - floor < W.TIDY_GROWTH then return false end
  if collectgarbage then collectgarbage() end
  local after = luaKB()
  W.tidyFloor = after or 0
  W.lastTidy = { before = before, after = after }
  return true
end

--- Close out the live encounter once combat has stayed dropped long enough
--- that the next pull is clearly a separate one.
function W.ScheduleFinish(delay)
  W.After(delay, function()
    local E = W.encounter
    if E.live and not E.inCombat then E:Finish() end
  end, "finish")
end

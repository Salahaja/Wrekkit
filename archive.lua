--[[ Wrekkit :: archive

One file per raid ID, and one per dungeon run, under CustomData.

SavedVariables used to hold the whole history: every pull of the week in
one file, parsed at login, rewritten at logout, and sitting in the game's
Lua memory all night, where every garbage collection has to walk it.
Deleting one raid or keeping one meant reaching into that one big file.

Now each pull is also written, the moment it ends, to the file of the
lockout it belongs to:

  raid      the client's raid ID (GetSavedInstanceInfo), so two nights on
            the same Molten Core lockout share a file
  dungeon   5-man dungeons and the open world have no lockout ID, so each
            run -- one session -- is its own file

SavedVariables keep only the last few hours (the night in progress), plus
anything locked. Older raids are listed in the report's session menu and
read from their file when picked; only one is held in memory at a time.
Keeping a raid past the history length, or deleting one, is one action on
one file.

Files are plain text: a header line, then one line per pull,
"R~" followed by the pull as a Lua table literal. A line is a whole pull
or it is skipped, so a write torn by a crash costs that pull and nothing
else. Needs Nampower's file API; without it nothing here runs and the
history stays in SavedVariables as before.
]]

local W = Wrekkit
W.archive = {}
local A = W.archive

local HEADER = "WREKKITARCHIVE1"

-- How long a pull stays in SavedVariables once its file has it: the night
-- in progress, so the meter and the report open on it without a read.
A.HOLD = 12 * 3600

-- The one archive read in from disk, if any: { key = ..., list = {...} }.
A.loaded = nil

----------------------------------------------------------------------
-- writing a pull as text
----------------------------------------------------------------------

local function num(n)
  if n ~= n or n == math.huge or n == -math.huge then return "0" end
  if n == math.floor(n) and n > -1e15 and n < 1e15 then
    return string.format("%.0f", n)   -- the client's %d is 32-bit
  end
  return string.format("%.10g", n)
end

-- A string literal that stays on one line: quotes, backslashes and every
-- control character as a three-digit escape, which reads back the same in
-- every Lua.
local function str(s)
  return '"' .. string.gsub(s, '[%c"\\]', function(c)
    return string.format("\\%03d", string.byte(c))
  end) .. '"'
end

local MAXDEPTH = 24

-- A scalar, or "nil" for anything else (a table past MAXDEPTH included).
local function scalar(v, out)
  local t = type(v)
  if t == "number" then
    table.insert(out, num(v))
  elseif t == "string" then
    table.insert(out, str(v))
  elseif t == "boolean" then
    table.insert(out, v and "true" or "false")
  else
    table.insert(out, "nil")
  end
end

local function keep(k, x)
  local kt, xt = type(k), type(x)
  return (kt == "number" or kt == "string")
    and (xt == "number" or xt == "string" or xt == "boolean" or xt == "table")
    -- Scratch fields some views write onto what they read.
    and not (kt == "string" and string.sub(k, 1, 1) == "_")
end

--[[ A table as text, in pieces that can stop and pick up again.

     The 1.12 client has no coroutine library (it came with 2.0), so the
     walk keeps its own stack instead of recursing. Each table's keys are
     taken when it is opened: next() over a table that gains a key between
     frames is undefined, and views do write scratch fields onto a pull. ]]
local function open(w, t, depth)
  table.insert(w.out, "{")
  local keys = {}
  for k, x in pairs(t) do
    if keep(k, x) then table.insert(keys, k) end
  end
  table.insert(w.stack, { t = t, keys = keys, i = 0, depth = depth })
end

local function writer(v)
  local w = { out = {}, stack = {} }
  if type(v) == "table" then open(w, v, 0) else scalar(v, w.out) end
  return w
end

-- Write up to `budget` entries (all of them when nil). True once done.
local function advance(w, budget)
  local out, stack = w.out, w.stack
  while true do
    local n = table.getn(stack)
    local f = stack[n]
    if not f then return true end
    f.i = f.i + 1
    local k = f.keys[f.i]
    if k == nil then
      table.insert(out, "}")
      table.remove(stack)
      if n > 1 then table.insert(out, ",") end
    else
      local x = f.t[k]
      if keep(k, x) then
        table.insert(out, "[")
        if type(k) == "number" then table.insert(out, num(k)) else table.insert(out, str(k)) end
        table.insert(out, "]=")
        if type(x) == "table" and f.depth + 1 < MAXDEPTH then
          open(w, x, f.depth + 1)
        else
          scalar(x, out)
          table.insert(out, ",")
        end
        if budget then
          budget = budget - 1
          if budget <= 0 then return false end
        end
      end
    end
  end
end

function A.Serialize(rec)
  local w = writer(rec)
  advance(w)
  return table.concat(w.out)
end

-- Text back into a table, in an empty environment: the file holds data,
-- and nothing in it can reach a global.
local function compile(src)
  if setfenv and loadstring then
    local f = loadstring(src)
    if f then setfenv(f, {}) end
    return f
  end
  if load then return load(src, "=archive", "t", {}) end
  return nil
end

function A.Deserialize(text)
  local f = compile("return " .. text)
  if not f then return nil end
  local ok, rec = pcall(f)
  if ok and type(rec) == "table" then return rec end
  return nil
end

----------------------------------------------------------------------
-- which file a pull belongs to
----------------------------------------------------------------------

function A:Available()
  return (WriteCustomFile ~= nil) and (ReadCustomFile ~= nil)
end

--- On unless turned off in settings, and only with the file API.
function A:Active()
  return self:Available() and not (W.db and W.db.archiveFiles == false)
end

local function clean(s)
  return (string.gsub(tostring(s or ""), "[^%w]", ""))
end

local function idOf(rec)
  return tostring(rec.sessionId) .. ":" .. tostring(rec.id)
end

--- The archive a pull belongs to: its raid ID, or else its run.
function A:KeyFor(rec)
  local zone = rec.zone or "Unknown"
  if (rec.instanceId or 0) > 0 then
    return "raid:" .. zone .. ":" .. tostring(rec.instanceId)
  end
  return "run:" .. zone .. ":" .. tostring(rec.sessionId or 0)
end

local function fileFor(rec)
  local who = clean((UnitName and UnitName("player")) or "Unknown")
  local tag
  if (rec.instanceId or 0) > 0 then
    tag = tostring(rec.instanceId)
  else
    local start = (rec.startTime or 0) - (rec.offset or 0)
    tag = (date and date("%Y%m%d_%H%M", start)) or tostring(rec.sessionId or 0)
  end
  return "Wrekkit_" .. who .. "_" .. clean(rec.zone or "Unknown") .. "_" .. tag .. ".txt"
end

local function backupOf(file)
  return (string.gsub(file, "%.txt$", "_backup.txt"))
end

----------------------------------------------------------------------
-- the index
----------------------------------------------------------------------

--[[ What archives exist. The client cannot list a folder, so the index is
     how Wrekkit knows which files are its own. Kept in SavedVariables, and
     mirrored to a small file of its own so a lost SavedVariables does not
     orphan every raid on disk. ]]
function A:Index()
  if not W.db then return {} end
  if type(W.db.archives) ~= "table" then W.db.archives = {} end
  return W.db.archives
end

local function indexFile()
  local who = clean((UnitName and UnitName("player")) or "Unknown")
  return "Wrekkit_" .. who .. "_archives.txt"
end

function A:SaveIndex()
  if not self:Active() then return end
  pcall(WriteCustomFile, indexFile(), HEADER .. "\nX~" .. A.Serialize(self:Index()) .. "\n", "w")
end

--- After a lost SavedVariables, take the index back from its mirror.
function A:RestoreIndex()
  if not self:Active() then return 0 end
  local idx = self:Index()
  if next(idx) ~= nil then return 0 end
  local ok, text = pcall(ReadCustomFile, indexFile())
  if not ok or type(text) ~= "string" then return 0 end
  local n = 0
  for line in string.gfind(text, "[^\n]+") do
    if string.sub(line, 1, 2) == "X~" then
      local t = A.Deserialize(string.sub(line, 3))
      if t then
        for k, e in pairs(t) do
          if type(e) == "table" and e.file then idx[k] = e n = n + 1 end
        end
      end
    end
  end
  return n
end

-- The index entry for a pull's archive, made if it is new.
local function entryFor(rec)
  local key = A:KeyFor(rec)
  local idx = A:Index()
  local e = idx[key]
  if not e then
    e = {
      key = key, file = fileFor(rec), zone = rec.zone or "Unknown",
      instanceId = rec.instanceId or 0, raid = (rec.instanceId or 0) > 0,
      first = rec.startTime, last = rec.startTime,
      pulls = 0, bosses = 0, ids = {},
    }
    idx[key] = e
  end
  if not e.ids then e.ids = {} end
  return key, e
end

----------------------------------------------------------------------
-- writing
----------------------------------------------------------------------

-- Write an already-serialized pull to its file and record it.
local function commit(rec, body)
  local key, e = entryFor(rec)
  local id = idOf(rec)
  if e.ids[id] then rec.archived = key return true end
  local text = "\nR~" .. body .. "\n"
  if not e.started then text = HEADER .. text end
  local ok = pcall(WriteCustomFile, e.file, text, "a")
  if not ok then return false end

  e.started = true
  e.ids[id] = true
  e.pulls = (e.pulls or 0) + 1
  if rec.boss then e.bosses = (e.bosses or 0) + 1 end
  if (rec.startTime or 0) < (e.first or rec.startTime or 0) then e.first = rec.startTime end
  if (rec.startTime or 0) > (e.last or 0) then e.last = rec.startTime end
  rec.archived = key

  -- Seen at once if that raid is the one open in the report.
  if A.loaded and A.loaded.key == key then
    table.insert(A.loaded.list, rec)
    if W.report and W.report.Invalidate then W.report:Invalidate() end
  end
  A:SaveIndex()
  return true
end

-- Already in its file (or a copy of one that is: a pull brought back from
-- the crash journal is a copy of one the archive took whole when it ended).
local function already(rec)
  if rec.archived then return true end
  local key, e = entryFor(rec)
  if e.ids[idOf(rec)] then rec.archived = key return true end
  return false
end

--- Write a pull to its file now, in this frame. Returns whether it is on disk.
function A:AppendNow(rec)
  if not self:Active() or type(rec) ~= "table" then return false end
  if already(rec) then return true end
  return commit(rec, A.Serialize(rec))
end

--[[ Add a finished pull to its file, a little each frame.

     Turning a forty-player pull into text is tens of milliseconds in one
     go -- a hitch at the end of every fight. So the writer above does a
     slice per frame, and the file is written when it is done.
     Until then the pull is simply still in SavedVariables (unmarked), which
     is also what happens if the session ends first: the next login writes
     it. ]]
A.queue = {}
local SLICE = 800      -- table entries per frame
-- Each slice is scheduled a moment ahead, not at 0: the timer runs every
-- job that is due in the frame it is looking at, so a job queued for "now"
-- from inside a job runs in that same frame, and the slicing would be undone.

function A:Append(rec)
  if not self:Active() or type(rec) ~= "table" then return false end
  if already(rec) then return true end
  for _, q in ipairs(self.queue) do if q == rec then return true end end
  table.insert(self.queue, rec)
  self:Pump()
  return true
end

local function step()
  local job = A.job
  if not job then
    local rec = table.remove(A.queue, 1)
    if not rec then A.pumping = nil return end
    if already(rec) then
      W.After(0.01, function() W.Guard("archive", step) end, "archivePump")
      return
    end
    job = { rec = rec, w = writer(rec) }
    A.job = job
  end
  local ok, done = pcall(advance, job.w, SLICE)
  if not ok then
    A.job = nil                       -- leave it unmarked: the next login retries
  elseif done then
    A.job = nil
    if A:Active() then commit(job.rec, table.concat(job.w.out)) end
  end
  if A.job or table.getn(A.queue) > 0 then
    W.After(0.01, function() W.Guard("archive", step) end, "archivePump")
  else
    A.pumping = nil
  end
end

function A:Pump()
  if self.pumping then return end
  self.pumping = true
  W.After(0.01, function() W.Guard("archive", step) end, "archivePump")
end

--- Drop queued writes for pulls no longer in the history (deleted, reset):
--- written later, they would bring back what was just removed.
function A:DropQueued(keep)
  local still = {}
  for _, r in ipairs((W.db and W.db.encounters) or {}) do still[r] = true end
  local q = {}
  for _, r in ipairs(self.queue) do
    if still[r] and (not keep or keep(r)) then table.insert(q, r) end
  end
  self.queue = q
  if self.job and not (still[self.job.rec] and (not keep or keep(self.job.rec))) then
    self.job = nil
  end
end

--- Finish every queued write now (logout, tests).
function A:Flush()
  if self.job then
    local job = self.job
    self.job = nil
    if not already(job.rec) then self:AppendNow(job.rec) end
  end
  while table.getn(self.queue) > 0 do
    self:AppendNow(table.remove(self.queue, 1))
  end
  self.pumping = nil
  W.Cancel("archivePump")
end

--- Write an archive whole, from `list`: the backup first, then the file,
--- so a crash in either write leaves one of them complete.
function A:Rewrite(key, list)
  local e = self:Index()[key]
  if not e or not self:Active() then return false end
  local out = { HEADER }
  local ids, pulls, bosses = {}, 0, 0
  for _, rec in ipairs(list) do
    table.insert(out, "R~" .. A.Serialize(rec))
    ids[idOf(rec)] = true
    pulls = pulls + 1
    if rec.boss then bosses = bosses + 1 end
  end
  local text = table.concat(out, "\n") .. "\n"
  pcall(WriteCustomFile, backupOf(e.file), text, "w")
  local ok = pcall(WriteCustomFile, e.file, text, "w")
  if ok then
    e.ids, e.pulls, e.bosses, e.started = ids, pulls, bosses, true
    self:SaveIndex()
  end
  return ok == true
end

----------------------------------------------------------------------
-- reading
----------------------------------------------------------------------

local function parse(text)
  local list, seen = {}, {}
  if type(text) ~= "string" then return list end
  for line in string.gfind(text, "[^\n]+") do
    if string.sub(line, 1, 2) == "R~" then
      local rec = A.Deserialize(string.sub(line, 3))
      if rec and rec.id ~= nil then
        local id = idOf(rec)
        -- A later line for the same pull replaces the earlier one.
        if seen[id] then list[seen[id]] = rec
        else table.insert(list, rec) seen[id] = table.getn(list) end
      end
    end
  end
  return list
end

--- The pulls in an archive, read from disk. Not kept.
function A:Read(key)
  local e = self:Index()[key]
  if not e or not self:Available() then return {} end
  local ok, text = pcall(ReadCustomFile, e.file)
  local list = parse(ok and text or nil)
  if table.getn(list) == 0 then
    local okB, textB = pcall(ReadCustomFile, backupOf(e.file))
    list = parse(okB and textB or nil)
  end
  for _, rec in ipairs(list) do rec.archived = key end
  return list
end

--- Read an archive in for the report. One at a time: opening another
--- lets go of the last.
function A:Load(key)
  if self.loaded and self.loaded.key == key then return self.loaded.list end
  local list = self:Read(key)
  self.loaded = { key = key, list = list }
  if W.report and W.report.Invalidate then W.report:Invalidate() end
  return list
end

function A:Unload()
  if self.loaded then
    self.loaded = nil
    if W.report and W.report.Invalidate then W.report:Invalidate() end
  end
end

--- A pull changed after it was written (marked a boss, locked): put the
--- change in its file too, or it would be undone the next time it is read.
function A:Touch(rec)
  local key = rec and rec.archived
  if not key or not self:Active() or not self:Index()[key] then return end
  local list = (self.loaded and self.loaded.key == key) and self.loaded.list or self:Read(key)
  local id, found = idOf(rec), false
  for i, r in ipairs(list) do
    if idOf(r) == id then list[i] = rec found = true end
  end
  if not found then table.insert(list, rec) end
  self:Rewrite(key, list)
end

----------------------------------------------------------------------
-- keeping and deleting
----------------------------------------------------------------------

--- Keep an archive past the history length, or let it go again.
function A:SetKept(key, on)
  local e = self:Index()[key]
  if not e then return false end
  e.kept = on and true or nil
  self:SaveIndex()
  return e.kept == true
end

--[[ Delete an archive: its file, its backup, its index entry, and its pulls
     still in SavedVariables (a locked one excepted). The client has no call to remove a file, so
     the file is emptied instead; an empty file is nothing to anyone. The
     crash journal is rewritten too, or the next recovery would bring the
     pulls back. ]]
function A:Delete(key)
  local idx = self:Index()
  local e = idx[key]
  if not e then return false end
  if self:Available() then
    pcall(WriteCustomFile, e.file, "", "w")
    pcall(WriteCustomFile, backupOf(e.file), "", "w")
  end
  idx[key] = nil
  if self.loaded and self.loaded.key == key then self.loaded = nil end

  local list = (W.db and W.db.encounters) or {}
  local removed = 0
  local i = 1
  while i <= table.getn(list) do
    local r = list[i]
    -- A locked pull was promised that nothing deletes it; it stays.
    if not r.locked and (r.archived == key or (not r.archived and A:KeyFor(r) == key)) then
      table.remove(list, i)
      removed = removed + 1
    else
      i = i + 1
    end
  end
  self:DropQueued(function(r) return r.locked or A:KeyFor(r) ~= key end)
  if removed > 0 and W.store and W.store.Rewrite then W.store:Rewrite() end
  if W.report and W.report.Invalidate then W.report:Invalidate() end
  self:SaveIndex()
  return true
end

--- Archives past the history length go, unless kept. Returns how many.
function A:Cleanup()
  if not self:Active() or not time then return 0 end
  local days = (W.db and W.db.keepDays) or 7
  if days <= 0 then return 0 end
  local cutoff = time() - days * 86400
  local doomed = {}
  for key, e in pairs(self:Index()) do
    if not e.kept and (e.last or 0) > 0 and e.last < cutoff then
      table.insert(doomed, key)
    end
  end
  for _, key in ipairs(doomed) do self:Delete(key) end
  return table.getn(doomed)
end

--- The archives, newest first, for menus and /wrek raids.
function A:List()
  local out = {}
  for _, e in pairs(self:Index()) do table.insert(out, e) end
  table.sort(out, function(a, b) return (a.last or 0) > (b.last or 0) end)
  return out
end

--- One line describing an archive.
function A:Describe(e)
  local when = (date and e.first) and date("%m/%d", e.first) or "?"
  local what = e.raid and "raid" or "run"
  return string.format("%s  %s  (%s, %d pull%s, %d boss%s)%s",
    e.zone or "?", when, what, e.pulls or 0, (e.pulls == 1) and "" or "s",
    e.bosses or 0, (e.bosses == 1) and "" or "es", e.kept and "  [kept]" or "")
end

----------------------------------------------------------------------
-- moving existing history into files
----------------------------------------------------------------------

--[[ Pulls already in SavedVariables when this arrives -- a week of them,
     possibly -- are written out a few at a time, not all in one frame:
     a week in one go would be one long freeze at login. ]]
function A:Pending()
  local out = {}
  for _, rec in ipairs((W.db and W.db.encounters) or {}) do
    if not rec.archived then table.insert(out, rec) end
  end
  return out
end

function A:MigrateNow()
  local n = 0
  for _, rec in ipairs(self:Pending()) do
    if self:AppendNow(rec) then n = n + 1 end
  end
  return n
end

function A:Start()
  if not self:Active() then return end
  self:RestoreIndex()
  local pending = self:Pending()
  local total = table.getn(pending)
  for _, rec in ipairs(pending) do self:Append(rec) end

  -- Report once the queue has drained, then tidy what has expired.
  local function settle()
    if self.pumping then
      W.After(1, function() W.Guard("archive", settle) end, "archiveSettle")
      return
    end
    if total > 0 then
      W.Print("saved " .. total .. " earlier pull(s) to per-raid files. " ..
        "Older raids are in the report's session menu.")
      W.TrimHistory()
    end
    local gone = self:Cleanup()
    if gone > 0 then
      W.Print(gone .. " raid file(s) past the history length were removed.")
    end
  end
  settle()
end

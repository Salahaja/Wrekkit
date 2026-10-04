--[[ Wrekkit :: store

Reset, and saving history to a real file on disk.

SavedVariables already persist encounters between sessions, but they are
opaque, they are rewritten wholesale at logout, and a crash loses whatever
was not flushed. Nampower exposes WriteCustomFile/ReadCustomFile, so the
history can also be written out as plain text under CustomData/ -- readable
outside the game, safe from a SavedVariables reset, and importable back into
any character on this account.

File format (line-oriented, one concern per line):

  WREKKIT1                                       magic + version
  S~sessionId~zone~startTime                     opens a session
  E~id~name~duration~combat~kill~offset~dd~hl~oh~dt~locked
  A~name,class,dmg,taken,heal,over,deaths,disp,int,owner,consumes
  D~time,name,class                              a death
  B~second,dd,dt,hl,eh                           one timeline bucket
  Z~id                                           the encounter is complete

Anything unrecognised is skipped, so a newer file degrades rather than
breaking an older addon.

Surviving a crash while writing, which is the one moment the journal itself
is at risk:

  torn append    every encounter ends with Z. One without it, in a file
                 that uses Z, was cut off mid-write and is dropped rather
                 than imported with half its players missing. The next
                 append starts on a fresh line, so a torn tail can never
                 run into the encounter written after it.
  torn rewrite   a full rewrite (prune, lock, compaction) goes to a backup
                 file FIRST, then to the journal. A crash during the second
                 write leaves a complete backup, which the next read merges
                 back in and repairs the journal from.
  growth         the journal is rewritten from the history once it passes
                 a megabyte, so login never parses a whole season of pulls.
]]

local W = Wrekkit
W.store = {}
local St = W.store

local MAGIC = "WREKKIT1"
-- Second line of every file this build starts: each encounter in it ends
-- with Z, so one without is torn. Older readers skip it as unrecognised.
local FORMAT = "V~2"
local REC, FLD = "~", ","

-- Past this the journal is compacted back down to the history.
St.COMPACT_AT = 1024 * 1024

local function esc(s)
  return (string.gsub(tostring(s or ""), "[~,\n\r]", ""))
end

local function int(n)
  return string.format("%d", math.floor(tonumber(n) or 0))
end

function St:Filename()
  local name = UnitName("player") or "Unknown"
  return "Wrekkit_" .. name .. ".txt"
end

--- Where a full rewrite lands first. See the note at the top.
function St:BackupName()
  local name = UnitName("player") or "Unknown"
  return "Wrekkit_" .. name .. "_backup.txt"
end

function St:Available()
  return (WriteCustomFile ~= nil) and (ReadCustomFile ~= nil)
end

----------------------------------------------------------------------
-- export
----------------------------------------------------------------------

--- The lines for one encounter, optionally preceded by its session header.
--- Shared by the full snapshot and the append-as-you-go journal so the two
--- can never drift into producing different files.
function St:SerializeEncounter(enc, withSessionHeader)
  local out = {}

  if withSessionHeader then
    table.insert(out, table.concat({
      "S", esc(enc.sessionId), esc(enc.zone), int(enc.startTime - (enc.offset or 0)),
      -- Appended, not inserted: a reader that predates this field takes the
      -- first three and ignores the rest, so older files stay readable and
      -- older builds can still read new ones.
      int(enc.instanceId or 0),
    }, REC))
  end

  local t = enc.totals or {}
  table.insert(out, table.concat({
    "E", int(enc.id), esc(enc.name), int(enc.duration), int(enc.combat),
    enc.kill and "1" or "0", int(enc.offset),
    int(t.damage), int(t.healing), int(t.overheal), int(t.taken),
    enc.locked and "1" or "0",
  }, REC))

  for guid, a in pairs(enc.actors or {}) do
    if a.isPlayer or a.class == "PET" then
      table.insert(out, "A" .. REC .. table.concat({
        esc(a.name), esc(a.class),
        int(a.damage), int(a.taken), int(a.healing), int(a.overheal),
        int(a.deaths), int(a.dispels), int(a.interrupts),
        esc(a.ownerName or ""), int(a.consumes),
      }, FLD))
    end
  end

  for _, d in ipairs(enc.deaths or {}) do
    table.insert(out, "D" .. REC .. table.concat({
      int(d.t), esc(d.name), esc(d.class),
    }, FLD))
  end

  for i = 0, (enc.maxBucket or 0) do
    local b = enc.bucket and enc.bucket[i]
    if b then
      local dd, dt, hl, eh
      if b.dd then dd, dt, hl, eh = b.dd, b.dt, b.hl, b.eh
      else dd, dt, hl, eh = b[1], b[2], b[3], b[4] end
      -- Skip empty seconds: most of a night is idle and they compress the
      -- file by more than half.
      if (dd or 0) + (dt or 0) + (hl or 0) > 0 then
        table.insert(out, "B" .. REC .. table.concat({
          int(i), int(dd), int(dt), int(hl), int(eh),
        }, FLD))
      end
    end
  end

  -- Written last: its presence is what says every line above it landed.
  table.insert(out, "Z" .. REC .. int(enc.id))

  return table.concat(out, "\n") .. "\n"
end

--- Full snapshot of every stored encounter, replacing the file.
function St:Serialize(encounters)
  local out = { MAGIC .. "\n" .. FORMAT .. "\n" }
  local currentSession = nil

  for _, enc in ipairs(encounters) do
    local newSession = (enc.sessionId ~= currentSession)
    currentSession = enc.sessionId
    table.insert(out, self:SerializeEncounter(enc, newSession))
  end

  return table.concat(out)
end

----------------------------------------------------------------------
-- journal (crash safety)
----------------------------------------------------------------------

--[[ SavedVariables are written only at a clean logout. A crash, a hard
     disconnect or a client kill therefore loses the entire night, however
     carefully it was aggregated in memory. Appending each encounter to disk
     the moment it ends is the only way to survive that on this client, and
     Nampower's file API makes it cheap -- a finished pull is a few KB.

     Appending rather than rewriting also means a crash mid-write can lose at
     most the last encounter instead of corrupting the whole history. ]]

function St:AppendEncounter(enc, session)
  if not self:Available() then return false end

  local filename = self:Filename()
  local prefix = ""

  -- Start the file with the magic line if it does not exist yet. Known
  -- after the first look: without CustomFileExists, looking means reading
  -- the whole file, which is not something to do at the end of every pull.
  if not self.journalExists or not self.journalBytes then
    self.journalExists = self:FileExists(filename)
  end
  if not self.journalExists then
    prefix = MAGIC .. "\n" .. FORMAT .. "\n"
    self.journalSession = nil
  elseif self.needNewline then
    -- The file ends mid-line: a crash tore the last write. Start clean,
    -- or the first line of this encounter would be glued onto that one.
    prefix = "\n"
  end

  -- Re-emit the session header whenever the session changes, and on the
  -- first write after a login -- a resumed session repeats its own header,
  -- which the reader folds back together by id.
  local needHeader = (self.journalSession ~= enc.sessionId)

  local text = prefix .. self:SerializeEncounter(enc, needHeader)
  local ok, err = pcall(WriteCustomFile, filename, text, "a")
  if not ok then
    W.Debug("journal append failed: " .. tostring(err))
    self.journalBytes = nil     -- part of it may have landed: length unknown
    return false
  end

  self.journalSession = enc.sessionId
  self.needNewline = nil
  -- Keep count of the file's length. The clean-save mark records it, so the
  -- next login can tell without parsing whether anything was added since.
  if not self.journalExists then
    self.journalBytes = string.len(text)
  elseif self.journalBytes then
    self.journalBytes = self.journalBytes + string.len(text)
  end
  self.journalExists = true
  return true
end

--[[ Replace the journal with `text`, crash-safely: the backup first, then
     the journal. Whichever write a crash interrupts, one of the two files
     is whole. Returns whether the journal itself was written. ]]
function St:WriteFull(text)
  pcall(WriteCustomFile, self:BackupName(), text, "w")
  local ok = pcall(WriteCustomFile, self:Filename(), text, "w")
  self.journalSession = nil
  self.needNewline = nil
  self.journalExists = ok or self.journalExists
  self.journalBytes = ok and string.len(text) or nil
  return ok == true
end

--[[ Rewrite the journal from what is currently in memory.

     Deleting history has to reach the disk too: the journal outlives
     SavedVariables by design, so leaving it intact would mean the next login
     helpfully restored everything the user just asked to delete. An empty
     history writes just the magic line, which is why there is no separate
     "clear" -- that was a second way to do this and drifted out of use. ]]
--- Called after anything that deletes encounters, so the file on disk can
--- never disagree with the history -- otherwise the next login's recovery
--- would restore what was just pruned.
function St:Rewrite()
  if not self:Available() then return false end
  local encounters = (W.db and W.db.encounters) or {}
  local text = (table.getn(encounters) == 0)
      and (MAGIC .. "\n" .. FORMAT .. "\n")
      or self:Serialize(encounters)
  return self:WriteFull(text)
end

--[[ How far the journal had got at a clean save. PLAYER_LOGOUT fires just
     before SavedVariables are written, at a logout and at a /reload alike,
     so this mark is saved together with the history it describes. After a
     crash it still describes the last CLEAN save, which is the question the
     next login asks: what did the journal get that the saved history never
     did? Kept per journal file, since the history is shared by the account
     and each character has a journal of its own. ]]
function St:MarkSaved()
  if not W.db or not self:Available() then return end
  W.db.journalMarks = W.db.journalMarks or {}
  W.db.journalMarks[self:Filename()] = { saved = time(), bytes = self.journalBytes }
end

----------------------------------------------------------------------
-- keeping and pruning
----------------------------------------------------------------------

--[[ A locked encounter is one the user asked to keep. Nothing deletes it:
     not the ring buffer, not pruning, not "reset all". That is the whole
     value of the flag -- a lock that a later cleanup silently overrides is
     worse than no lock, because it invites people to trust it. Unlock it
     first if you really want it gone. ]]

function W.SetLocked(enc, locked)
  if not enc then return end
  enc.locked = locked and true or nil
  W.store:Rewrite()
  if W.archive then W.archive:Touch(enc) end
  if W.ui and W.ui.report and W.ui.report.frame then W.ui.report:Refresh() end
end

function W.ToggleLocked(enc)
  if not enc then return false end
  W.SetLocked(enc, not enc.locked)
  return enc.locked == true
end

function W.CountLocked()
  local n = 0
  for _, e in ipairs((W.db and W.db.encounters) or {}) do
    if e.locked then n = n + 1 end
  end
  return n
end

--[[ How much history is kept: a raid week, however many pulls that is.

     It used to be the newest 60 pulls, which a full Molten Core clear with
     its trash runs past before the last bosses -- the first ones of the
     night were gone by the end of it. Now a pull is kept for keepDays
     (seven by default, one lockout) and the count is unlimited. A count
     cap is still there for anyone who wants one (maxEncounters, 0 = none).
     A locked pull is never removed by either. ]]
function W.TrimHistory(list)
  list = list or (W.db and W.db.encounters)
  if not list then return 0 end
  local removed = 0
  --[[ A pull its raid's file already holds stays in SavedVariables only
       for the night in progress (W.archive.HOLD); after that the report
       reads it from the file. See archive.lua. ]]
  if W.archive and W.archive:Active() and time then
    local cutoff = time() - W.archive.HOLD
    local i = 1
    while i <= table.getn(list) do
      local e = list[i]
      if e.archived and not e.locked and (e.startTime or 0) > 0 and e.startTime < cutoff then
        table.remove(list, i)
        removed = removed + 1
      else
        i = i + 1
      end
    end
  end
  local days = (W.db and W.db.keepDays) or 7
  if days > 0 and time then
    local cutoff = time() - days * 86400
    local i = 1
    while i <= table.getn(list) do
      local e = list[i]
      if not e.locked and (e.startTime or 0) > 0 and e.startTime < cutoff then
        table.remove(list, i)
        removed = removed + 1
      else
        i = i + 1
      end
    end
  end
  local cap = (W.db and W.db.maxEncounters) or 0
  if cap > 0 then
    while table.getn(list) > cap do
      local victim
      for i = 1, table.getn(list) do
        if not list[i].locked then victim = i break end
      end
      if not victim then break end
      table.remove(list, victim)
      removed = removed + 1
    end
  end
  return removed
end

--- Delete unlocked encounters. `days` nil or 0 means every unlocked one.
--- Returns removed, kept, lockedSpared.
function W.PruneEncounters(days)
  local cutoff = nil
  if days and days > 0 then cutoff = time() - days * 86400 end

  local kept, removed, spared = {}, 0, 0
  for _, e in ipairs((W.db and W.db.encounters) or {}) do
    local old = (not cutoff) or ((e.startTime or 0) < cutoff)
    if e.locked then
      table.insert(kept, e)
      if old then spared = spared + 1 end
    elseif old then
      removed = removed + 1
    else
      table.insert(kept, e)
    end
  end

  W.db.encounters = kept
  W.store:Rewrite()
  if W.ui and W.ui.meter and W.ui.meter.InvalidateView then W.ui.meter:InvalidateView() end

  if W.ui and W.ui.report and W.ui.report.frame then
    W.ui.report.state.selected = {}
    W.ui.report.state.drill = nil
    W.ui.report:Refresh()
  end
  if W.ui and W.ui.meter and W.ui.meter.frame then W.ui.meter:Refresh() end

  return removed, table.getn(kept), spared
end

function St:FileExists(name)
  if CustomFileExists then
    local ok, result = pcall(CustomFileExists, name)
    if ok then return result == true end
  end
  local ok, text = pcall(ReadCustomFile, name)
  return ok and text ~= nil and text ~= ""
end

function St:Save()
  if not self:Available() then
    W.Print("Saving to disk needs Nampower's file API (WriteCustomFile).")
    return false
  end

  local encounters = (W.db and W.db.encounters) or {}
  if table.getn(encounters) == 0 then
    W.Print("Nothing recorded yet.")
    return false
  end

  local text = self:Serialize(encounters)
  if not self:WriteFull(text) then
    W.Print("Save failed: the client would not write CustomData\\" .. self:Filename())
    return false
  end

  W.Print(string.format("Saved %d encounters to CustomData\\%s (%.0f KB).",
    table.getn(encounters), self:Filename(), string.len(text) / 1024))
  return true
end

----------------------------------------------------------------------
-- import
----------------------------------------------------------------------

local function fields(str, sep)
  local out = {}
  for piece in string.gfind(str .. sep, "([^" .. sep .. "]*)" .. sep) do
    table.insert(out, piece)
  end
  return out
end

--[[ Parse a file. Returns the encounters, how many were dropped as torn
     (see the note at the top), and whether the file declares the current
     format. Files from before the Z marker are read exactly as before. ]]
function St:Deserialize(text)
  local encounters = {}
  local session, enc = nil, nil
  local strict = false

  for line in string.gfind(text, "[^\n\r]+") do
    local kind = string.sub(line, 1, 1)
    local rest = string.sub(line, 3)

    if line == MAGIC then
      -- header, nothing to do
    elseif line == FORMAT then
      strict = true
    elseif kind == "Z" then
      if enc and tonumber(rest) == enc.id then enc.complete = true end
    elseif kind == "S" then
      local f = fields(rest, REC)
      -- Session ids are numeric when this client made them. Restore the
      -- number: a string "17000" and a number 17000 are different table
      -- keys, which would split one night into two sessions in the report.
      session = {
        id = tonumber(f[1]) or f[1],
        zone = f[2],
        startTime = tonumber(f[3]) or 0,
        -- Absent in files written before lockout ids existed.
        instanceId = tonumber(f[4]) or 0,
      }
    elseif kind == "E" then
      local f = fields(rest, REC)
      local offset = tonumber(f[6]) or 0
      enc = {
        id = tonumber(f[1]) or 0,
        sessionId = session and session.id or "import",
        name = f[2],
        zone = session and session.zone or "Unknown",
        instanceId = (session and session.instanceId) or 0,
        -- Reconstruct the encounter's own wall-clock start from the session
        -- start plus its offset, rather than inheriting the session's.
        startTime = (session and session.startTime or 0) + offset,
        duration = tonumber(f[3]) or 0,
        combat = tonumber(f[4]) or 0,
        kill = (f[5] == "1"),
        offset = offset,
        locked = (f[11] == "1"),
        totals = {
          damage = tonumber(f[7]) or 0,
          healing = tonumber(f[8]) or 0,
          overheal = tonumber(f[9]) or 0,
          taken = tonumber(f[10]) or 0,
          enemy = 0,
        },
        actors = {}, deaths = {}, bucket = {}, maxBucket = 0,
        imported = true,
      }
      table.insert(encounters, enc)
    elseif kind == "A" and enc then
      local f = fields(rest, FLD)
      if f[1] and f[1] ~= "" then
        enc.actors["import:" .. f[1]] = {
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
    elseif kind == "D" and enc then
      local f = fields(rest, FLD)
      table.insert(enc.deaths, {
        t = tonumber(f[1]) or 0, name = f[2], class = f[3],
      })
    elseif kind == "B" and enc then
      local f = fields(rest, FLD)
      local i = tonumber(f[1]) or 0
      enc.bucket[i] = {
        tonumber(f[2]) or 0, tonumber(f[3]) or 0,
        tonumber(f[4]) or 0, tonumber(f[5]) or 0,
      }
      if i > enc.maxBucket then enc.maxBucket = i end
    end
  end

  --[[ Which encounters were torn:
       - in a file that declares the format, any without Z
       - in an older file appended to by this build, any without Z after
         the first that has one (everything from there on is this build's)
       - in any file, the last one if the file stops partway through a line ]]
  local n = table.getn(encounters)
  local tornTail = text ~= "" and string.sub(text, -1) ~= "\n"
  local kept, dropped, marked = {}, 0, strict
  for i, e in ipairs(encounters) do
    if e.complete then marked = true end
    local torn = (marked and not e.complete) or (tornTail and i == n and not e.complete)
    if torn then
      dropped = dropped + 1
    else
      e.complete = nil
      table.insert(kept, e)
    end
  end
  return kept, dropped, strict
end

--- An encounter's identity, the same in memory and in the file.
local function keyOf(e)
  return tostring(e.sessionId) .. ":" .. tostring(e.id)
end

local function byStart(a, b)
  local at, bt = a.startTime or 0, b.startTime or 0
  if at == bt then return (a.id or 0) < (b.id or 0) end
  return at < bt
end

--[[ Read the journal, and repair from the backup if it was damaged.

     Damaged means a torn encounter was dropped, or the file ends partway
     through a line. Either way the backup -- written whole before every
     rewrite -- may hold what the journal lost, so the two are merged by
     identity, the journal winning a tie. Returns the raw text, the
     encounters, and whether a repair is worth writing back. ]]
function St:ReadJournal(text)
  if type(text) ~= "string" then
    local ok, read = pcall(ReadCustomFile, self:Filename())
    text = (ok and type(read) == "string") and read or ""
  end
  local encounters, dropped, strict = self:Deserialize(text)

  local torn = text ~= "" and string.sub(text, -1) ~= "\n"
  self.needNewline = torn or nil
  -- An older-format journal is not damaged, but it is rewritten once in
  -- this format, so the next crash can be judged by the strict rule.
  if dropped == 0 and not torn then
    return text, encounters, (text ~= "" and not strict)
  end

  local okB, backup = pcall(ReadCustomFile, self:BackupName())
  if okB and type(backup) == "string" and backup ~= "" then
    local have = {}
    for _, e in ipairs(encounters) do have[keyOf(e)] = true end
    for _, e in ipairs((self:Deserialize(backup))) do
      if not have[keyOf(e)] then
        have[keyOf(e)] = true
        table.insert(encounters, e)
      end
    end
    table.sort(encounters, byStart)
  end
  return text, encounters, true
end

function St:Load()
  if not self:Available() then
    W.Print("Loading from disk needs Nampower's file API (ReadCustomFile).")
    return false
  end

  local text, encounters = self:ReadJournal()
  if text == "" and table.getn(encounters) == 0 then
    W.Print("No saved file found at CustomData\\" .. self:Filename())
    return false
  end

  if table.getn(encounters) == 0 then
    W.Print("That file held no encounters.")
    return false
  end

  --[[ Merge by identity, not by appending.

       With the journal running, most of what is in the file is already in
       memory, so a blind append would double every number. Encounters are
       identified by session and id, and the in-memory copy wins on a tie --
       it carries per-ability detail the file does not. That also makes
       loading idempotent: running it twice changes nothing. ]]

  -- A copy loaded from the file before is replaced by the file's own, fresh
  -- one: counted as already there, not as recovered all over again.
  local seen, kept, had = {}, {}, {}
  for _, e in ipairs(W.db.encounters) do
    if e.imported then
      had[keyOf(e)] = true
    else
      seen[keyOf(e)] = true
      table.insert(kept, e)
    end
  end

  local added, skipped = 0, 0
  for _, e in ipairs(encounters) do
    local k = keyOf(e)
    if seen[k] then
      skipped = skipped + 1
    else
      seen[k] = true
      table.insert(kept, e)
      if had[k] then skipped = skipped + 1 else added = added + 1 end
    end
  end

  table.sort(kept, byStart)
  W.db.encounters = kept

  if skipped > 0 then
    W.Print("Recovered " .. added .. " encounters from disk (" ..
      skipped .. " already in memory).")
  else
    W.Print("Recovered " .. added .. " encounters from disk.")
  end
  if W.ui and W.ui.report and W.ui.report.frame then W.ui.report:Refresh() end
  return true
end

--[[ Crash recovery, once a login.

     SavedVariables are written only at a clean logout or /reload, so after a
     crash they hold the last CLEAN save -- not nothing -- and every pull
     since exists only in the journal. Those are what this restores: pulls
     that started after the last clean save (see St:MarkSaved) and are not in
     the history.

     Not everything the journal has and the history lacks. The journal keeps
     every pull ever recorded; the history keeps the newest 60 and drops the
     rest as it goes, and restoring those would undo the cap at every login.
     A journal that has not grown since the clean save is not even parsed. ]]
function St:Recover()
  if not W.db or not self:Available() then return false end

  local name = self:Filename()
  local mark = W.db.journalMarks and W.db.journalMarks[name]

  --[[ The cheap path first: the journal is exactly as long as at the last
       clean save, so nothing was added and nothing is parsed. Its length
       is all that is needed, and it is only known by reading it. ]]
  local ok, raw = pcall(ReadCustomFile, name)
  if not ok or type(raw) ~= "string" then raw = "" end
  self.journalBytes = string.len(raw)
  self.journalExists = raw ~= ""
  self.needNewline = (raw ~= "" and string.sub(raw, -1) ~= "\n") or nil
  if raw == "" or (mark and mark.bytes == self.journalBytes) then
    self:Compact(false)
    return true
  end
  local text, parsed, damaged = self:ReadJournal(raw)
  raw = nil
  self.journalBytes = string.len(text)

  -- No mark yet (the first login on this version, or a wiped history): the
  -- newest pull the history kept stands in for the last clean save.
  local since = mark and mark.saved
  if not since then
    since = 0
    for _, e in ipairs(W.db.encounters) do
      if not e.sharedBy and (e.startTime or 0) > since then since = e.startTime end
    end
  end

  local list = W.db.encounters
  local wasEmpty = table.getn(list) == 0
  local have, back = {}, {}
  for _, e in ipairs(list) do have[keyOf(e)] = true end
  for _, e in ipairs(parsed) do
    local k = keyOf(e)
    if not have[k] and (e.startTime or 0) > since then
      have[k] = true
      back[e] = true
      table.insert(list, e)
    end
  end
  if next(back) == nil then
    self:Compact(damaged)
    return true
  end

  -- The saved session pointer predates these pulls: resuming from it would
  -- give the next pull an id one of them already has. Without it the session
  -- comes from the history (E:SessionFromHistory), restored pulls included.
  W.db.session = nil

  -- The history's own limits (W.TrimHistory): a lost session leaves
  -- exactly what a clean logout would have.
  table.sort(list, byStart)
  W.TrimHistory(list)

  local n = 0
  for _, e in ipairs(list) do
    if back[e] then n = n + 1 end
  end
  self:Compact(damaged)
  if n == 0 then return true end
  if wasEmpty then
    W.Print("the saved history was empty - restored " .. n ..
      " fight(s) from the journal on disk.")
  else
    W.Print("recovered " .. n .. " fight(s) the last session did not save - it " ..
      "ended without a clean logout (a crash, or the client closing).")
  end
  if W.ui and W.ui.report and W.ui.report.frame then W.ui.report:Refresh() end
  return true
end

--[[ Rewrite the journal from the history when it was damaged (to repair
     it) or has grown past COMPACT_AT. Pulls the history no longer holds --
     older than its cap, or deleted -- leave the file with it; the journal
     is the crash net under the history, not a second archive beside it. ]]
function St:Compact(force)
  if not self:Available() then return false end
  if not force and (self.journalBytes or 0) <= self.COMPACT_AT then return false end
  -- An empty history over a non-empty journal is the one case where the
  -- journal is all there is. Never compact that away.
  if table.getn((W.db and W.db.encounters) or {}) == 0 then return false end
  local ok = self:Rewrite()
  if ok then W.Debug("journal compacted to " .. tostring(self.journalBytes) .. " bytes") end
  return ok
end

----------------------------------------------------------------------
-- reset
----------------------------------------------------------------------

--[[ Confirmation for the destructive reset.

     Clearing the current pull is cheap and reversible by just fighting again.
     Clearing the history is not, so it goes through the client's own
     confirmation dialog rather than happening on a stray right-click. ]]
if type(StaticPopupDialogs) == "table" then
  StaticPopupDialogs["WREKKIT_RESET_ALL"] = {
    text = "Delete every recorded encounter?\nThis cannot be undone.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function() W.ResetData("all") end,
    timeout = 30,
    whileDead = 1,
    hideOnEscape = 1,
  }
end

--[[ scope "new" (the default) starts a fresh log: the pull in progress is
     dropped and the session is closed, so everything recorded from here is
     separate from what came before. Previous encounters are kept and stay
     browsable in the report -- this is "start a new log", not "delete".

     scope "all" deletes the history outright. ]]
function W.ResetData(scope)
  scope = scope or "new"

  if scope == "all" then
    -- Locked encounters survive even this. See the note on W.SetLocked.
    local removed, kept, spared = W.PruneEncounters(nil)
    -- Raid files go too, except the ones kept on purpose, and so do
    -- writes still queued for pulls that were just removed.
    if W.archive then
      W.archive:DropQueued()
      for _, e in ipairs(W.archive:List()) do
        if not e.kept then W.archive:Delete(e.key) end
      end
    end
    W.encounter:StartNewSession()
    W.capture.units = {}
    if kept > 0 then
      W.Print("Cleared " .. removed .. " encounters. Kept " .. kept ..
        " locked one" .. (kept == 1 and "" or "s") ..
        " - unlock them first to remove them.")
    else
      W.Print("Cleared all recorded encounters, on disk as well.")
    end
  else
    W.encounter:StartNewSession()
    W.Print("Started a new log. Earlier pulls are still in the report.")
  end

  -- The UI may not exist: the windows are built lazily, and the engine runs
  -- perfectly well without them (the offline harness loads no UI at all).
  local ui = W.ui
  if not ui then return end

  if ui.meter and ui.meter.frame then
    ui.meter.drill = nil
    ui.meter.drillAbility = nil
    ui.meter:Refresh()
  end
  if ui.report and ui.report.frame then
    ui.report.state.selected = {}
    ui.report.state.drill = nil
    ui.report.state.drillAbility = nil
    ui.report:Refresh()
  end
end

--[[ Wrekkit :: diagnostics

"It isn't recording anything" has too many possible causes to guess at from
chat: the client may not expose the events, the CVars may be off, the events
may be arriving and then discarded by the open-world filter, or a pull may
be recorded but too short to keep. /wrek status answers all of those at once.

Also holds the error trap the two windows refresh through. A window repaints
on a 0.5s ticker, so an unguarded error in a refresh does not fail once -- it
fails twice a second forever, which buries the original message. Trapping it
reports each distinct failure once and keeps the rest of the addon alive.
]]

local W = Wrekkit

----------------------------------------------------------------------
-- error trap
----------------------------------------------------------------------

local reported = {}

--- Run fn, and if it errors report the message once and carry on.
--- Returns true when fn completed.
function W.Guard(label, fn)
  local ok, err = pcall(fn)
  if ok then return true end

  err = tostring(err)
  local key = label .. "|" .. err
  if not reported[key] then
    reported[key] = true
    W.Print("|cffd44f53error in " .. label .. ":|r " .. err)
    W.Print("Run |cffe0a22c/wrek status|r and send that output along with this.")
  end
  W.lastError = { label = label, err = err, at = time() }
  return false
end

function W.ClearErrors()
  reported = {}
  W.lastError = nil
end

----------------------------------------------------------------------
-- status
----------------------------------------------------------------------

local function yn(v)
  if v then return "|cff63c776yes|r" end
  return "|cffd44f53NO|r"
end

local function line(msg)
  DEFAULT_CHAT_FRAME:AddMessage("  " .. msg)
end

function W.Status()
  W.Print("status  (v" .. W.version .. ")")

  ------------------------------------------------------------------
  -- client capabilities
  ------------------------------------------------------------------
  line("SuperWoW    SpellInfo " .. yn(SpellInfo) ..
       "   GetUnitGUID " .. yn(GetUnitGUID) ..
       "   GetUnitData " .. yn(GetUnitData))
  line("Nampower    file API " .. yn(WriteCustomFile and ReadCustomFile))

  if GetCVar then
    local parts = {}
    for _, cv in ipairs(W.capture.cvars) do
      local v = GetCVar(cv)
      table.insert(parts, string.gsub(cv, "NP_Enable", "") .. "=" ..
        tostring(v or "nil"))
    end
    line("CVars       " .. table.concat(parts, "  "))
  end

  ------------------------------------------------------------------
  -- are events actually arriving?
  ------------------------------------------------------------------
  local C = W.capture
  if C.seenTotal == 0 then
    line("Events      |cffd44f53none seen since load|r")
    line("            Deal or take damage once, then re-check. If this stays")
    line("            at zero, the nampower events are not reaching Lua.")
  else
    local ago = C.lastEventAt and (GetTime() - C.lastEventAt) or nil
    line("Events      " .. C.seenTotal .. " seen" ..
      (ago and string.format(", last %.0fs ago", ago) or ""))

    -- Break out the families that matter most; a zero here is diagnostic.
    local dmg = (C.seen.SPELL_DAMAGE_EVENT_SELF or 0) + (C.seen.SPELL_DAMAGE_EVENT_OTHER or 0)
    local swing = (C.seen.AUTO_ATTACK_SELF or 0) + (C.seen.AUTO_ATTACK_OTHER or 0)
    local heal = (C.seen.SPELL_HEAL_BY_SELF or 0) + (C.seen.SPELL_HEAL_BY_OTHER or 0)
        + (C.seen.SPELL_HEAL_ON_SELF or 0)
    line("            spell dmg " .. dmg .. "   swings " .. swing ..
         "   heals " .. heal .. "   deaths " .. (C.seen.UNIT_DIED or 0))
    if swing == 0 then
      line("            |cffd44f53swings are 0|r - NP_EnableAutoAttackEvents may be off")
    end
    if heal == 0 then
      line("            |cffd44f53heals are 0|r - NP_EnableSpellHealEvents may be off")
    end
  end

  ------------------------------------------------------------------
  -- is it allowed to record right now?
  ------------------------------------------------------------------
  local recording = W.encounter:ShouldRecord()
  if recording then
    line("Recording   " .. yn(true) .. " here")
  else
    local _, kind = IsInInstance and IsInInstance()
    line("Recording   |cffd44f53no|r - not in an instance" ..
      (kind and (" (" .. tostring(kind) .. ")") or ""))
    line("            Open-world combat is off by default. |cffe0a22c/wrek world|r")
    line("            turns it on, which is what you want for testing.")
  end

  ------------------------------------------------------------------
  -- what's in memory
  ------------------------------------------------------------------
  local live = W.encounter.live
  if live then
    line("Live pull   " .. (live.name or "in progress") .. "   " ..
      W.Duration(GetTime() - live.startT) .. "   " ..
      W.Short(live.totals.damage) .. " dmg   " ..
      W.Count(live.actors) .. " actors")
  else
    line("Live pull   none in progress")
  end

  local stored = (W.db and W.db.encounters) or {}
  local n = table.getn(stored)
  line("Stored      " .. n .. " encounter" .. (n == 1 and "" or "s") ..
    "   (kept: " .. (W.db.maxEncounters or 60) .. ")")

  ------------------------------------------------------------------
  -- continuity
  ------------------------------------------------------------------
  local sess = W.encounter.session
  if sess then
    line("Session     " .. tostring(sess.zone) ..
      (sess.resumed and "  |cff63c776(resumed)|r" or "  (new)") ..
      "   " .. table.getn(sess.encounters) .. " pull" ..
      (table.getn(sess.encounters) == 1 and "" or "s") .. " this login")
  else
    local prev = W.encounter:SessionFromHistory()
    if prev then
      local idle = time() - (prev.lastActivity or 0)
      local window = W.db.resumeWindow or 1200
      if idle <= window then
        line("Session     will rejoin " .. tostring(prev.zone) ..
          " (idle " .. W.Duration(idle) .. " of " .. W.Duration(window) .. ")")
      else
        line("Session     previous one is " .. W.Duration(idle) ..
          " old - next pull starts a new one")
      end
    else
      line("Session     none yet")
    end
  end

  line("Journal     " .. (W.db.autoSave and "on" or "|cffd44f53off|r") ..
    "   file " .. (W.store:Available()
      and (W.store:FileExists(W.store:Filename()) and "present" or "not written yet")
      or "|cffd44f53unavailable (needs Nampower)|r"))
  if n == 0 and C.seenTotal > 0 and recording then
    line("            Events are arriving but nothing was kept. Pulls shorter")
    line("            than " .. (W.db.minTrashDuration or 6) ..
         "s are discarded, and an encounter is only")
    line("            stored ~5s after you leave combat.")
  end

  if W.lastError then
    line("Last error  |cffd44f53" .. W.lastError.label .. "|r  " .. W.lastError.err)
  end
end

----------------------------------------------------------------------
-- who
----------------------------------------------------------------------

--[[ Dump what the addon believes about every actor it recorded.

     "Player X isn't showing" has several distinct causes that look identical
     from the meter: no events arrived for them, they were classified as an
     enemy and went to the wrong table, or a filter is hiding them. This
     prints the classification next to the number so the three are told apart
     at a glance -- which matters most for cross-faction groups, where the
     faction-aware unit API is the thing most likely to misreport. ]]
function W.Who()
  local encounters, label = W.ui.meter:Encounters()
  local view = W.report:View(encounters, { petMode = "separate" })

  W.Print("actors in |cffe0a22c" .. tostring(label) .. "|r")

  local rows = {}
  for _, r in ipairs(view.rows) do table.insert(rows, r) end
  table.sort(rows, function(a, b)
    return (a.damage + a.healing) > (b.damage + b.healing)
  end)

  if table.getn(rows) == 0 then
    line("nothing recorded in this segment")
  end

  for i = 1, table.getn(rows) do
    local r = rows[i]
    local kind
    if r.isPlayer then kind = "|cff63c776player|r"
    elseif r.class == "PET" then kind = "pet"
    else kind = "|cffd44f53enemy|r" end

    local inGroup = W.capture:InGroup(r.ownerName or r.name)
        and "|cff63c776group|r" or "|cff6b7280outside|r"

    line(string.format("%-14s %-9s %-16s %-18s  %s",
      string.sub(r.name or "?", 1, 14),
      string.sub(r.class or "?", 1, 9),
      kind, inGroup, W.Short(r.damage + r.healing)))
  end

  ------------------------------------------------------------------
  -- what the roster thinks
  ------------------------------------------------------------------
  local rosterN, groupN = 0, 0
  for _ in pairs(W.capture.rosterClass) do rosterN = rosterN + 1 end
  for _ in pairs(W.capture.groupMembers) do groupN = groupN + 1 end

  line("")
  line("roster knows " .. rosterN .. " name" .. (rosterN == 1 and "" or "s") ..
       ", " .. groupN .. " currently grouped" ..
       "   (raid " .. tostring(GetNumRaidMembers and GetNumRaidMembers() or "?") ..
       ", party " .. tostring(GetNumPartyMembers and GetNumPartyMembers() or "?") .. ")")

  local meterOn = W.ui.meter:Settings().groupOnly
  if meterOn then
    line("|cffd44f53Group-only filter is ON|r - anyone marked 'outside' is hidden.")
  end

  -- Group members we have a roster entry for but never saw an event from.
  local missing = {}
  for name in pairs(W.capture.groupMembers) do
    local seen = false
    for _, r in ipairs(view.rows) do
      if r.name == name then seen = true end
    end
    if not seen then table.insert(missing, name) end
  end
  if table.getn(missing) > 0 then
    line("in your group but no events recorded: " .. table.concat(missing, ", "))
    line("   (out of range, or not fighting)")
  end
end

--[[ Wrekkit :: ui/confirm

The gate in front of chat. Shows the exact lines that will be posted, and
above all WHERE they are going, before anything is sent.

The destination is the loudest thing in the dialog on purpose. The mistake
this exists to prevent is not "sent the wrong numbers", it is "sent them to
the guild instead of the party" -- so the channel gets the headline, the
audience is spelled out in plain language, and public channels are tinted to
read as a warning rather than as decoration.

One dialog is built and reused. 1.12 cannot destroy frames, so rebuilding it
per request would leak a full-screen modal every time someone thought about
posting and changed their mind.
]]

local W = Wrekkit
local UI = W.ui

local DIALOG_W = 420
local ROW_H = 14
local MAX_ROWS = 14

-- The ceiling on "Top N" in the picker. A:Lines clamps to its own MAX_LINES
-- as well, so this only decides how far the stepper will travel.
local MAX_LINES_PICK = 15

--[[ What can be posted. Deliberately a short, curated list rather than every
     metric the report knows: a dialog with fifteen checkboxes is not a
     choice, it is a form. These are the ones people actually link. ]]
local ANNOUNCE_METRICS = {
  { key = "damage",   label = "Damage" },
  { key = "healing",  label = "Healing" },
  { key = "taken",    label = "Taken" },
  { key = "deaths",   label = "Deaths" },
  { key = "consumes", label = "Consumables" },
  { key = "dispels",  label = "Dispels" },
}

local dialog

--[[ What the picker has ticked, and how many lines it will post.

     Module state, not fields on the dialog frame, because the checkbox
     getters below read this every time a tick refreshes -- while the dialog
     is still being built, and again on every open. Keeping it on the frame
     made something the widgets read unconditionally into something two
     separate functions had to have assigned first, and "attempt to index a
     nil value" inside the getter is exactly what that looks like when the
     assumption does not hold in the client. Declared here, it exists from
     the moment the file loads and there is no ordering left to get wrong.

     Emptied in place rather than replaced, so the table the frame and the
     tests hold on to stays the one the widgets are reading. ]]
local picked = {}        -- metric key -> true, which ticks are lit
local topCount = 5       -- what the Top N stepper shows

local function resetPicked()
  for k in pairs(picked) do picked[k] = nil end
end

--[[ The picker's two closures, built here rather than inline in the loop.

     They have to be made by a function so `key` arrives as an ARGUMENT, which
     is per-call in every version of Lua. Written inline they captured the
     for-in variable instead, and in 5.0 that is a single slot shared by the
     whole loop which the iterator sets to nil on its way out: correct while
     the loop is still running -- so every checkbox drew right as it was built
     -- and nil on every refresh afterwards. That is the "confirm.lua:140:
     attempt to index a nil value" in the announce menu, and why the dialog
     then opened with nothing to pick: the throw happened while it was being
     reconfigured, before the step that lays the picker out.

     5.4 gives each turn of the loop its own copy, so the offline harness ran
     it correctly no matter what the client did. tools/vanilla_lint.lua now
     refuses the pattern outright. ]]
local function pickerHandlers(key, frame)
  local get = function() return picked[key] == true end
  local set = function(v)
    picked[key] = v or nil
    if frame.Rebuild then frame:Rebuild() end
  end
  return get, set
end

----------------------------------------------------------------------

--- Plain-language description of who is about to read this.
local function audience(channel, target)
  if channel == "WHISPER" then
    return (target and target ~= "") and ("only " .. target) or "one person"
  end
  if channel == "RAID" then
    local n = GetNumRaidMembers() or 0
    return n .. " people in your raid"
  end
  if channel == "PARTY" then
    local n = (GetNumRaidMembers() or 0) > 0
        and (GetNumRaidMembers() or 0) or ((GetNumPartyMembers() or 0) + 1)
    return n .. " people in your party"
  end
  if channel == "GUILD" then return "everyone online in your guild" end
  if channel == "SAY" then return "everyone nearby, including strangers" end
  return "unknown"
end

--- Channels where a mistake is embarrassing rather than private.
local function isPublic(channel)
  return channel == "SAY" or channel == "GUILD" or channel == "RAID"
end

----------------------------------------------------------------------

local function build()
  if dialog then return dialog end

  local f = UI.Panel(UIParent, W.color.bg, W.color.borderHi, "WrekkitConfirm")
  f:SetWidth(DIALOG_W)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(true)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
  f:Hide()

  -- Dim the world behind it so the dialog reads as modal.
  local shade = CreateFrame("Button", nil, f)
  shade:SetAllPoints(UIParent)
  shade:SetFrameStrata("FULLSCREEN")
  shade:EnableMouse(true)
  local shadeTex = shade:CreateTexture(nil, "BACKGROUND")
  shadeTex:SetTexture(UI.media.white)
  shadeTex:SetVertexColor(0, 0, 0, 0.45)
  shadeTex:SetAllPoints(shade)
  shade:Hide()
  f.shade = shade
  f:SetScript("OnHide", function() shade:Hide() end)

  -- headline: the destination
  local head = CreateFrame("Frame", nil, f)
  head:SetHeight(46)
  head:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  head:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
  UI.Fill(head, W.color.panel)
  f.headFill = head

  f.dest = UI.Text(head, 15, W.color.accent)
  f.dest:SetPoint("TOPLEFT", head, "TOPLEFT", 12, -8)

  f.who = UI.Text(head, 11, W.color.textDim)
  f.who:SetPoint("TOPLEFT", f.dest, "BOTTOMLEFT", 0, -4)

  local rule = UI.Line(f, W.color.border)
  rule:SetPoint("BOTTOMLEFT", head, "BOTTOMLEFT", 0, 0)
  rule:SetPoint("BOTTOMRIGHT", head, "BOTTOMRIGHT", 0, 0)

  -- whisper target
  local targetBox = UI.SearchBox(f, 160, nil, "Character name")
  targetBox:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 12, -8)
  targetBox:Hide()
  f.targetBox = targetBox

  f.targetLabel = UI.Text(f, 10, W.color.textDim)
  f.targetLabel:SetPoint("LEFT", targetBox, "RIGHT", 8, 0)
  f.targetLabel:SetText("who to whisper")
  f.targetLabel:Hide()

  --[[ What to post, decided here rather than before the dialog opened.

       The window's current view sets the defaults, so the common case is
       still "announce what I am looking at" with no fiddling. But the view
       and the post are not the same thing: someone reading Damage may well
       want to post deaths too, and the alternative was closing the dialog,
       changing tab, and starting again.

       Live state is deliberately not stored anywhere: these reset from the
       view every time the dialog opens, so yesterday's choice cannot
       silently decide today's post. ]]
  f.picked = picked   -- the same table, exposed for tests and debugging
  f.metricChecks = {}
  local COLS, COL_W = 3, 128
  for i, m in ipairs(ANNOUNCE_METRICS) do
    local col = math.mod(i - 1, COLS)
    local row = math.floor((i - 1) / COLS)
    local get, set = pickerHandlers(m.key, f)
    local chk = UI.Check(f, m.label, get, set)
    chk:SetWidth(COL_W)
    chk._metricKey = m.key
    chk._col, chk._row = col, row
    f.metricChecks[i] = chk
  end

  f.countStepper = UI.Stepper(f, "Top",
    function() return topCount end,
    function(v)
      topCount = v
      if f.Rebuild then f:Rebuild() end
    end,
    1, MAX_LINES_PICK, 1,
    function(v) return tostring(v) end)

  -- Says what the checkboxes do not: which view this came from.
  f.viewNote = UI.Text(f, 10, W.color.textFaint)

  -- preview
  f.previewLabel = UI.Text(f, 10, W.color.textFaint)
  f.previewLabel:SetText("This will be posted, one line at a time:")

  local box = UI.Panel(f, W.color.panel, W.color.border)
  f.box = box

  f.rows = {}
  f.rowBtns = {}
  for i = 1, MAX_ROWS do
    local t = UI.Text(box, 10, W.color.text)
    t:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -(4 + (i - 1) * ROW_H))
    t:SetPoint("TOPRIGHT", box, "TOPRIGHT", -8, -(4 + (i - 1) * ROW_H))
    t:Hide()
    f.rows[i] = t
    -- Clicking a numbered line leaves it out of the post (or puts it back).
    local b = CreateFrame("Button", nil, box)
    b:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
    b:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 0, 0)
    b:SetHeight(ROW_H)
    b._index = i
    b:Hide()
    f.rowBtns[i] = b
  end

  -- The Raid Contrib tab: totals only, or who added each effect.
  f.contribCheck = UI.Check(f, "Name who added each effect",
    function() return f.valueIndividual == true end,
    function(v)
      f.valueIndividual = v and true or false
      if f.Rebuild then f:Rebuild() end
    end)
  f.contribCheck:SetWidth(260)
  f.contribCheck:Hide()

  --[[ Chat has no line break, so this is the nearest thing: the lines
       joined into as few messages as fit (A:Pack). Kept between posts --
       it is how you like your posts, not part of what one says. ]]
  f.packCheck = UI.Check(f, "Fewer messages: join the lines",
    function() return W.db and W.db.announcePack == true end,
    function(v)
      if W.db then W.db.announcePack = v and true or false end
      if f.Repaint then f:Repaint() end
    end,
    { "Each line is otherwise a message of its own.", "Joined with \" / \", up to 255 characters a",
      "message; each heading starts a new one." })
  f.packCheck:SetWidth(260)

  -- buttons
  local send = UI.Button(f, "Send", 90, 22)
  send:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
  send:SetActive(true)
  f.sendBtn = send

  local cancel = UI.Button(f, "Cancel", 90, 22, function() UI.CloseConfirm() end)
  cancel:SetPoint("RIGHT", send, "LEFT", -6, 0)
  f.cancelBtn = cancel

  f.note = UI.Text(f, 10, W.color.textFaint)
  f.note:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 16)

  dialog = f
  return f
end

function UI.CloseConfirm()
  if dialog then dialog:Hide() end
end

----------------------------------------------------------------------

--- Show the gate. onAccept(target) fires only on an explicit Send.
function UI.ConfirmAnnounce(lines, channel, target, onAccept, ctx)
  local f = build()
  --[[ Hidden while it is reconfigured, shown again only once it is fully
       painted at the bottom of this function. If anything in between fails,
       the dialog stays down rather than sitting on screen still describing
       the PREVIOUS request -- which is the one outcome a confirmation step
       must never produce. ]]
  f:Hide()
  local A = W.announce

  local shown = table.getn(lines)
  local truncated = false
  if shown > MAX_ROWS then shown = MAX_ROWS truncated = true end

  f.dest:SetText("Send to " .. string.upper(channel or "?"))
  f.dest:SetTextColor(isPublic(channel) and 0.90 or 0.88,
                      isPublic(channel) and 0.42 or 0.64,
                      isPublic(channel) and 0.30 or 0.17)
  f.who:SetText(audience(channel, target) .. " will see this.")

  --[[ Seed the picker from what is on screen. Reset every open on
       purpose: a sticky selection would let a choice made for one pull
       quietly decide the next post. ]]
  resetPicked()
  if ctx then
    for _, k in ipairs(ctx.metrics or { ctx.metric or "damage" }) do
      picked[k] = true
    end
  end
  --[[ Lines left out of this post, by what they name (the text after the
       number, up to the two-space gap) -- so a line stays out when the
       preview is rebuilt. Reset every open, like the picker. ]]
  local skip = {}
  f.skip = skip
  local contrib = ctx and ctx.contrib and not ctx.contribEffect
  -- A list of its own (by effect, the deaths): no metrics to pick.
  local listMode = contrib or (ctx and ctx.deaths and not ctx.deathDrill)
  f.valueIndividual = ((ctx and ctx.valueMode) or (W.db and W.db.valueAnnounce)) == "individual"
  topCount = (ctx and ctx.count) or (W.db and W.db.announceCount) or 5


  -- whisper needs a name before Send means anything
  local needsTarget = (channel == "WHISPER")
  if needsTarget then
    f.targetBox:Show()
    f.targetLabel:Show()
    f.targetBox:SetValue(target or "")
    f.previewLabel:SetPoint("TOPLEFT", f.targetBox, "BOTTOMLEFT", -12, -8)
  else
    f.targetBox:Hide()
    f.targetLabel:Hide()
    f.previewLabel:SetPoint("TOPLEFT", f.headFill, "BOTTOMLEFT", 12, -8)
  end

  --[[ Paint the preview from whatever the controls currently say. Kept as
       a closure so a checkbox or the Top stepper can re-run it without
       rebuilding the dialog -- 1.12 cannot destroy frames, so rebuilding
       per keystroke would leak one modal per click. ]]
  local anchorTop = needsTarget and f.targetBox or f.headFill

  --[[ From the top: the metrics to post (a plain view), or the contrib
       choice; then Top N wherever the post is a list of something -- every
       view, a player's abilities, an effect's builders, a death's last
       blows -- but not one ability's spread, which is the lines it has. ]]
  local function layoutControls()
    for _, chk in ipairs(f.metricChecks) do chk:Hide() end
    f.contribCheck:Hide()
    f.countStepper:Hide()
    f.viewNote:Hide()
    local x = needsTarget and -12 or 12
    if not ctx then
      f.previewLabel:ClearAllPoints()
      f.previewLabel:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT", x, -8)
      return 0
    end
    local drilled = ctx.drill or ctx.contribEffect or ctx.deathDrill
    local countable = not (ctx.drill and ctx.drillAbility)
    local y = -8

    if contrib then
      f.contribCheck:ClearAllPoints()
      f.contribCheck:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT", x, y)
      f.contribCheck:Show()
      f.contribCheck:Refresh()
      y = y - 24
    elseif not drilled and not listMode then
      for _, chk in ipairs(f.metricChecks) do
        chk:ClearAllPoints()
        chk:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT", x + chk._col * 128, y - chk._row * 20)
        chk:Show()
        -- Drawn and synced in one place: a control that is placed but still
        -- showing the last request's tick is a confirmation step telling a lie.
        chk:Refresh()
      end
      y = y - math.ceil(table.getn(f.metricChecks) / 3) * 20 - 4
    end

    f.viewNote:SetText(drilled and "the detail you have open; click a line to leave it out"
      or "click a line to leave it out")
    f.viewNote:ClearAllPoints()
    f.previewLabel:ClearAllPoints()
    if countable then
      f.countStepper:ClearAllPoints()
      f.countStepper:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT", x, y)
      f.countStepper:Show()
      f.countStepper:Refresh()
      f.viewNote:SetPoint("LEFT", f.countStepper, "RIGHT", 12, 0)
      f.viewNote:Show()
      f.previewLabel:SetPoint("TOPLEFT", f.countStepper, "BOTTOMLEFT", 0, -10)
      return -y + 20
    end
    f.viewNote:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT", x, y)
    f.viewNote:Show()
    f.previewLabel:SetPoint("TOPLEFT", f.viewNote, "BOTTOMLEFT", 0, -8)
    return -y + 10
  end

  --[[ Which line is which, so one left out stays out when the preview is
       rebuilt (the Top stepper, a tick): a numbered line by what it names
       -- the text after the number, up to the two-space gap -- any other by
       its text, and each under its heading, so leaving a player out of the
       damage post leaves their healing line in. ]]
  local function lineKeys(all)
    local keys, section = {}, ""
    for i, l in ipairs(all) do
      if string.find(l, "^Wrekkit  ") then
        local _, _, head = string.find(l, "^(.-) %- ")
        section = head or l
        keys[i] = "h:" .. section
      else
        local _, _, name = string.find(l, "^%d+%. (.-)  ")
        keys[i] = section .. (name and ("|n:" .. name) or ("|t:" .. l))
      end
    end
    return keys
  end

  -- What is sent: the lines not left out, numbered again 1, 2, 3... under
  -- each heading.
  local function kept(all)
    local keys = lineKeys(all)
    local out, n = {}, 0
    for i, l in ipairs(all) do
      if string.find(l, "^Wrekkit  ") then n = 0 end
      if not skip[keys[i]] then
        if string.find(l, "^%d+%. ") then
          n = n + 1
          l = string.gsub(l, "^%d+%. ", n .. ". ", 1)
        end
        table.insert(out, l)
      end
    end
    return out
  end

  local allLines = lines
  local sending = lines   -- what Send posts: the kept lines, packed if asked
  local function paint(newLines)
    allLines = newLines
    lines = kept(allLines)
    local packed = W.db and W.db.announcePack == true
    sending = packed and A:Pack(lines) or lines
    f.previewLabel:SetText(packed and "This will be posted, lines joined into fewer messages:"
      or "This will be posted, one line at a time:")
    local n = table.getn(lines)
    local vis = table.getn(allLines)
    local cut = false
    if vis > MAX_ROWS then vis = MAX_ROWS cut = true end

    local keys = lineKeys(allLines)
    for i = 1, MAX_ROWS do
      local t = f.rows[i]
      local b = f.rowBtns[i]
      if i <= vis then
        local k = keys[i]
        if skip[k] then
          t:SetText("|cff6f6f6f" .. allLines[i] .. "  (left out)|r")
        else
          t:SetText(allLines[i])
        end
        t:Show()
        b:Show()
        b:SetScript("OnClick", function()
          skip[k] = not skip[k] or nil
          paint(allLines)
        end)
      else
        t:Hide()
        b:Hide()
      end
    end

    local controlH = layoutControls()

    f.box:SetHeight(vis * ROW_H + 8)
    f.box:SetPoint("TOPLEFT", f.previewLabel, "BOTTOMLEFT", 0, -4)
    f.box:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    f.packCheck:ClearAllPoints()
    f.packCheck:SetPoint("TOPLEFT", f.box, "BOTTOMLEFT", 0, -6)
    f.packCheck:Show()
    f.packCheck:Refresh()

    if n == 0 then
      f.note:SetText("|cffd44f53nothing selected to post|r")
    else
      local m = table.getn(sending)
      -- Past the server's flood guard, the rest go after a pause (A.BURST).
      local pause = (m > A.BURST) and ("  (" .. A.BURST .. " now, the rest " .. A.BURST_PAUSE .. "s later)") or ""
      f.note:SetText(n .. " line" .. (n == 1 and "" or "s") ..
        (packed and ("  in " .. m .. " message" .. (m == 1 and "" or "s")) or "") .. pause ..
        (cut and ("  (" .. (table.getn(allLines) - MAX_ROWS) .. " more not previewed)") or ""))
    end
    f.sendBtn:SetActive(n > 0)

    f:SetHeight(46 + (needsTarget and 30 or 0) + controlH + 18
                + (vis * ROW_H + 8) + 26 + 48)
  end
  f.Repaint = function() paint(allLines) end

  --[[ Rebuild from the controls. The checkbox order is the dialog's, not the
       context's, so two people reading the same post see the same order. ]]
  f.Rebuild = function()
    if not ctx then return end
    local probe = {}
    for k, v in pairs(ctx) do probe[k] = v end
    if contrib then
      probe.valueMode = f.valueIndividual and "individual" or "combined"
    else
      local chosen = {}
      for _, m in ipairs(ANNOUNCE_METRICS) do
        if picked[m.key] then table.insert(chosen, m.key) end
      end
      -- A metric the picker has no box for (Raid value) stays as it came.
      local listed = {}
      for _, m in ipairs(ANNOUNCE_METRICS) do listed[m.key] = true end
      for _, k in ipairs(ctx.metrics or { ctx.metric }) do
        if k and not listed[k] then table.insert(chosen, k) end
      end
      probe.metrics = chosen
      probe.metric = chosen[1] or ctx.metric
    end
    paint(W.announce:Lines(probe, topCount))
  end

  paint(lines)

  f.sendBtn:SetScript("OnClick", function()
    local finalTarget = target
    if needsTarget then
      finalTarget = f.targetBox.editBox:GetText()
      if not finalTarget or finalTarget == "" then
        W.Print("enter a name to whisper first.")
        return
      end
    end
    UI.CloseConfirm()
    -- `sending` is reassigned by paint(), so this sends what is on screen.
    W.Guard("announce confirm", function() onAccept(finalTarget, sending) end)
  end)

  f.shade:Show()
  f:Show()
  -- Escape cancels, like every other confirmation in the client.
  UI.CloseOnEscape("WrekkitConfirm")
end

----------------------------------------------------------------------
-- channel picker
----------------------------------------------------------------------

--- Offer the channels, greying out the ones that cannot work from here.
--- Picking one leads to the confirmation, never straight to chat.
function UI.AnnounceMenu(parent, anchor, ctx)
  local items = {}
  local function channels(prefix)
    for _, c in ipairs(W.announce.channels) do
      local ok = c.available()
      table.insert(items, {
        text = ok and c.label or (c.label .. "  (not available)"),
        value = prefix .. c.key,
        disabled = not ok,
      })
    end
  end
  channels("")

  UI.Menu(parent, anchor, items, function(key)
    W.Guard("announce menu", function()
      W.announce:Request(ctx, key, nil, nil)
    end)
  end, 165)
end

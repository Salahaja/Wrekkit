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
    local chk = UI.Check(f, m.label,
      function() return picked[m.key] == true end,
      function(v)
        picked[m.key] = v or nil
        if f.Rebuild then f:Rebuild() end
      end)
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
  for i = 1, MAX_ROWS do
    local t = UI.Text(box, 10, W.color.text)
    t:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -(4 + (i - 1) * ROW_H))
    t:SetPoint("TOPRIGHT", box, "TOPRIGHT", -8, -(4 + (i - 1) * ROW_H))
    t:Hide()
    f.rows[i] = t
  end

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

  --[==[ Seed the picker from what is on screen. Reset every open on
         purpose: a sticky selection would let a choice made for one pull
         quietly decide the next post. ]==]
  resetPicked()
  if ctx then
    for _, k in ipairs(ctx.metrics or { ctx.metric or "damage" }) do
      picked[k] = true
    end
  end
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

  local function layoutControls()
    local drilled = ctx and ctx.drill
    local controlH = 0

    if ctx and not drilled then
      local top = anchorTop
      for _, chk in ipairs(f.metricChecks) do
        chk:ClearAllPoints()
        chk:SetPoint("TOPLEFT", top, needsTarget and "BOTTOMLEFT" or "BOTTOMLEFT",
          (needsTarget and -12 or 12) + chk._col * 128, -8 - chk._row * 20)
        chk:Show()
        -- Drawn and synced in one place: a control that is placed but still
        -- showing the last request's tick is a confirmation step telling a lie.
        chk:Refresh()
      end
      local rows = math.ceil(table.getn(f.metricChecks) / 3)
      controlH = rows * 20 + 8

      f.countStepper:ClearAllPoints()
      f.countStepper:SetPoint("TOPLEFT", top, "BOTTOMLEFT",
        (needsTarget and -12 or 12), -8 - rows * 20 - 4)
      f.countStepper:Show()
      f.countStepper:Refresh()
      controlH = controlH + 24

      f.viewNote:ClearAllPoints()
      f.viewNote:SetPoint("LEFT", f.countStepper, "RIGHT", 12, 0)
      f.viewNote:SetText("defaults from what is on screen")
      f.viewNote:Show()

      f.previewLabel:ClearAllPoints()
      f.previewLabel:SetPoint("TOPLEFT", f.countStepper, "BOTTOMLEFT", 0, -10)
    else
      for _, chk in ipairs(f.metricChecks) do chk:Hide() end
      f.countStepper:Hide()
      if drilled then
        f.viewNote:ClearAllPoints()
        f.viewNote:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT",
          (needsTarget and -12 or 12), -8)
        f.viewNote:SetText("announcing the detail you have open")
        f.viewNote:Show()
        controlH = 18
        f.previewLabel:ClearAllPoints()
        f.previewLabel:SetPoint("TOPLEFT", f.viewNote, "BOTTOMLEFT", 0, -8)
      else
        f.viewNote:Hide()
        f.previewLabel:ClearAllPoints()
        f.previewLabel:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT",
          (needsTarget and -12 or 12), -8)
      end
    end
    return controlH
  end

  local function paint(newLines)
    lines = newLines
    local n = table.getn(lines)
    local vis = n
    local cut = false
    if vis > MAX_ROWS then vis = MAX_ROWS cut = true end

    for i = 1, MAX_ROWS do
      local t = f.rows[i]
      if i <= vis then
        t:SetText(lines[i])
        t:Show()
      else
        t:Hide()
      end
    end

    local controlH = layoutControls()

    f.box:SetHeight(vis * ROW_H + 8)
    f.box:SetPoint("TOPLEFT", f.previewLabel, "BOTTOMLEFT", 0, -4)
    f.box:SetPoint("RIGHT", f, "RIGHT", -12, 0)

    if n == 0 then
      f.note:SetText("|cffd44f53nothing selected to post|r")
    else
      f.note:SetText(n .. " line" .. (n == 1 and "" or "s") ..
        (cut and ("  (" .. (n - MAX_ROWS) .. " more not previewed)") or ""))
    end
    f.sendBtn:SetActive(n > 0)

    f:SetHeight(46 + (needsTarget and 30 or 0) + controlH + 18
                + (vis * ROW_H + 8) + 48)
  end

  --[[ Rebuild from the controls. The checkbox order is the dialog's, not the
       context's, so two people reading the same post see the same order. ]]
  f.Rebuild = function()
    if not ctx then return end
    local chosen = {}
    for _, m in ipairs(ANNOUNCE_METRICS) do
      if picked[m.key] then table.insert(chosen, m.key) end
    end
    local probe = {}
    for k, v in pairs(ctx) do probe[k] = v end
    probe.metrics = chosen
    probe.metric = chosen[1] or ctx.metric
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
    -- `lines` is reassigned by paint(), so this sends what is on screen.
    W.Guard("announce confirm", function() onAccept(finalTarget, lines) end)
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
  for _, c in ipairs(W.announce.channels) do
    local ok = c.available()
    table.insert(items, {
      text = ok and c.label or (c.label .. "  (not available)"),
      value = c.key,
      disabled = not ok,
    })
  end

  UI.Menu(parent, anchor, items, function(key)
    W.Guard("announce menu", function()
      W.announce:Request(ctx, key, nil, nil)
    end)
  end, 165)
end

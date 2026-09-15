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

local dialog

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
function UI.ConfirmAnnounce(lines, channel, target, onAccept)
  local f = build()
  local A = W.announce

  local shown = table.getn(lines)
  local truncated = false
  if shown > MAX_ROWS then shown = MAX_ROWS truncated = true end

  f.dest:SetText("Send to " .. string.upper(channel or "?"))
  f.dest:SetTextColor(isPublic(channel) and 0.90 or 0.88,
                      isPublic(channel) and 0.42 or 0.64,
                      isPublic(channel) and 0.30 or 0.17)
  f.who:SetText(audience(channel, target) .. " will see this.")

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

  for i = 1, MAX_ROWS do
    local t = f.rows[i]
    if i <= shown then
      t:SetText(lines[i])
      t:Show()
    else
      t:Hide()
    end
  end

  f.box:SetHeight(shown * ROW_H + 8)
  f.box:SetPoint("TOPLEFT", f.previewLabel, "BOTTOMLEFT", 0, -4)
  f.box:SetPoint("RIGHT", f, "RIGHT", -12, 0)

  local total = table.getn(lines)
  f.note:SetText(total .. " line" .. (total == 1 and "" or "s") ..
    (truncated and ("  (" .. (total - MAX_ROWS) .. " more not previewed)") or ""))

  -- Height: header + optional target row + label + preview + buttons.
  f:SetHeight(46 + (needsTarget and 30 or 0) + 18 + (shown * ROW_H + 8) + 48)

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
    W.Guard("announce confirm", function() onAccept(finalTarget) end)
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

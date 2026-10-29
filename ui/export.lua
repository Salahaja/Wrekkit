--[[ Wrekkit :: ui/export

The Export menu (the report's Export button, the meter's window menu) and
the box an export opens in to copy from.

The box is one multi-line edit box, built once and reused (1.12 cannot
destroy frames). It opens with all of the text selected, so Ctrl+C is the
whole job; anything typed into it is put back, so it cannot be edited into
something the file does not say.
]]

local W = Wrekkit
local UI = W.ui

local box

local function build()
  if box then return box end
  local f = UI.Window("WrekkitExport", 560, 400, "Export", {
    minW = 360, minH = 220, strata = "DIALOG", skin = "dialog",
  })
  UI.CloseOnEscape("WrekkitExport")

  local hint = UI.Text(f.body, 10, W.color.textDim)
  hint:SetPoint("TOPLEFT", f.body, "TOPLEFT", 10, -8)
  hint:SetPoint("TOPRIGHT", f.body, "TOPRIGHT", -10, -8)
  hint:SetText("Ctrl+C copies it: it opens selected. In Discord, a paste past 2000 characters becomes a file.")
  f.hint = hint

  local scroll = CreateFrame("ScrollFrame", "WrekkitExportScroll", f.body, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f.body, "TOPLEFT", 10, -26)
  scroll:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -30, 38)
  f.scroll = scroll

  local eb = CreateFrame("EditBox", "WrekkitExportText", scroll)
  eb:SetMultiLine(true)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(0)
  eb:SetFont(UI.font, 11)
  eb:SetTextColor(W.color.text[1], W.color.text[2], W.color.text[3], 1)
  eb:SetWidth(500)
  eb:SetHeight(300)
  eb:SetScript("OnEscapePressed", function() f:Hide() end)
  eb:SetScript("OnTextChanged", function()
    -- Read only: typing puts the export back, selected again.
    if f.text and eb:GetText() ~= f.text then
      eb:SetText(f.text)
      eb:HighlightText()
    end
    scroll:UpdateScrollChildRect()
  end)
  scroll:SetScrollChild(eb)
  f.editBox = eb

  local sel = UI.Button(f.body, "Select all", 80, 20, function()
    eb:SetFocus()
    eb:HighlightText()
  end)
  sel:SetPoint("BOTTOMLEFT", f.body, "BOTTOMLEFT", 10, 10)
  local close = UI.Button(f.body, "Close", 80, 20, function() f:Hide() end)
  close:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -10, 10)

  box = f
  return f
end

--- Open the box on `text`, fenced so Discord keeps its columns lined up.
function UI.ExportBox(text, heading)
  local f = build()
  f.text = "```\n" .. (text or "") .. "\n```"
  if f.title then f.title:SetText(heading and ("Export: " .. heading) or "Export") end
  f:Show()
  local w = f.scroll:GetWidth()
  if w and w > 50 then f.editBox:SetWidth(w) end
  f.editBox:SetText(f.text)
  f.editBox:SetFocus()
  f.editBox:HighlightText()
  return f
end

--- The client's screenshot, a moment after the menu that asked has closed.
function UI.TakeShot()
  local shot = TakeScreenshot or Screenshot
  if not shot then
    W.Print("this client has no screenshot call; press Print Screen.")
    return
  end
  W.After(0.2, function() W.Guard("screenshot", shot) end, "wrekkitShot")
end

--[[ What can be exported from a window: what it shows, or the pulls'
     consumables list, to a file or the copy box; or a screenshot. The
     context is the window's announcement context, so an export is of
     exactly what the window shows -- the pulls picked, the filters on. ]]
function UI.ExportMenu(parent, anchor, ctx)
  local live = ctx and ctx.metric == "threat"
  local items = {
    { text = "Save to a file (CustomData)", header = true },
    { text = live and "This view  (threat is live: none)" or "This view", value = "shown:file", disabled = live },
    { text = "Consumables list, priced", value = "consumes:file" },
    { text = "Copy to paste", header = true },
    { text = "This view", value = "shown:copy", disabled = live },
    { text = "Consumables list, priced", value = "consumes:copy" },
    { text = "Picture", header = true },
    { text = "Screenshot", value = "shot" },
  }
  UI.Menu(parent, anchor, items, function(value)
    if not value then return end
    W.Guard("export", function()
      if value == "shot" then return UI.TakeShot() end
      local _, _, which, how = string.find(value, "^(%a+):(%a+)$")
      W.export:Run(ctx, which, how)
    end)
  end, 210)
end

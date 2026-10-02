--[[ Wrekkit :: ui/taunt

A button to click when a mob gets away from the tank.

When a mob you were tanking turns away, or one goes loose on someone in
the group, a small bar appears with a button per mob (newest first, up to
three): your taunt's icon, the mob, who it is on, and the cooldown. Click
to taunt it -- with SuperWoW straight at the mob, without touching your
target -- or right-click to dismiss. A mob that comes back, dies, or is
ten seconds old leaves on its own.

The same thing is on a keybinding (Key Bindings -> Wrekkit) and on
/wrek taunt, for a macro or a bar button. 1.12 only casts in answer to a
click or a key, which all three are.

Drag the bar by its title to move it; the place is saved. It is moved
together with the target-frame % in placement mode (/wrek threat move).
]]

local W = Wrekkit
local UI = W.ui
UI.taunt = {}
local TB = UI.taunt

local T = W.threat

local ROWS = 3
local ROW_H = 26
local WIDTH = 200

local function makeRow(parent, i)
  local pad = TB.pad or 0
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(ROW_H)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", 3 + pad, -(16 + pad + (i - 1) * (ROW_H + 2)))
  b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -3 - pad, -(16 + pad + (i - 1) * (ROW_H + 2)))
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  b.bg = UI.Fill(b, W.color.panelHi, 0.9)
  b.hl = UI.Fill(b, W.color.accent, 0, "BORDER")

  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetWidth(ROW_H - 4) b.icon:SetHeight(ROW_H - 4)
  b.icon:SetPoint("LEFT", b, "LEFT", 2, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  -- A dark sweep over the icon while the taunt cools down.
  b.cd = b:CreateTexture(nil, "OVERLAY")
  b.cd:SetTexture(UI.media.white)
  b.cd:SetVertexColor(0, 0, 0, 0.6)
  b.cd:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMLEFT", 0, 0)
  b.cd:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 0, 0)
  -- With a skin, the action bar's own clock sweep (CooldownFrameTemplate)
  -- replaces the flat shade.
  if UI.skin ~= "modern" and CooldownFrame_SetTimer then
    local ok, sweep = pcall(CreateFrame, "Model", nil, b, "CooldownFrameTemplate")
    if ok and sweep then
      sweep:SetAllPoints(b.icon)
      b.sweep = sweep
    end
  end
  b.cdText = b:CreateFontString(nil, "OVERLAY")
  b.cdText:SetFont(UI.fontNum, 12, "OUTLINE")
  b.cdText:SetPoint("CENTER", b.icon, "CENTER", 0, 0)

  b.label = UI.Text(b, 11, W.color.text)
  b.label:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 6, -1)
  b.label:SetPoint("RIGHT", b, "RIGHT", -4, 0)
  b.sub = UI.Text(b, 10, W.color.textDim)
  b.sub:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 6, 1)
  b.sub:SetPoint("RIGHT", b, "RIGHT", -4, 0)

  -- A red edge on the left that breathes, so the bar is noticed.
  b.edge = b:CreateTexture(nil, "OVERLAY")
  b.edge:SetTexture(UI.media.white)
  b.edge:SetWidth(2)
  b.edge:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b.edge:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
  b.edge:SetVertexColor(0.95, 0.2, 0.2, 1)

  b:SetScript("OnEnter", function() b.hl:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 0.15) end)
  b:SetScript("OnLeave", function() b.hl:SetVertexColor(0, 0, 0, 0) end)
  b:SetScript("OnClick", function()
    W.Guard("taunt click", function()
      local t = b.entry
      if not t or t.sample then return end
      if arg1 == "RightButton" then
        T:DismissTaunt(t)
      else
        T:Taunt(t)
      end
      TB:Update()
    end)
  end)
  b:Hide()
  return b
end

function TB:Create()
  if self.frame then return self.frame end
  local f = CreateFrame("Frame", "WrekkitTaunt", UIParent)
  self.frame = f
  f:SetWidth(WIDTH)
  f:SetHeight(16 + ROW_H + 4)
  f:SetFrameStrata("HIGH")
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:Hide()
  f.bg = UI.Fill(f, W.color.bg, 0.85)
  if UI.Backdrop(f, "window") then f.bg:Hide() end
  local pad = f._skinned and UI.SkinInset("window") or 0
  self.pad = pad

  local title = CreateFrame("Button", nil, f)
  title:SetHeight(14)
  title:SetPoint("TOPLEFT", f, "TOPLEFT", pad, -pad)
  title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad, -pad)
  title:RegisterForDrag("LeftButton")
  title:SetScript("OnDragStart", function() f:StartMoving() end)
  title:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    TB:SavePosition()
  end)
  f.title = UI.Text(title, 10, W.color.accent)
  f.title:SetPoint("LEFT", title, "LEFT", 5, 0)
  f.title:SetText("Taunt")
  f.keyHint = UI.Text(title, 9, W.color.textFaint, "RIGHT")
  f.keyHint:SetPoint("RIGHT", title, "RIGHT", -5, 0)
  f.keyHint:SetText("click  -  right-click: dismiss")

  self.rows = {}
  for i = 1, ROWS do self.rows[i] = makeRow(f, i) end
  self:RestorePosition()
  return f
end

function TB:SavePosition()
  local f = self.frame
  local x, y = f:GetCenter()
  local ux, uy = UIParent:GetCenter()
  if not (x and ux) then return end
  local s = T:Settings()
  s.tauntX = math.floor(x - ux + 0.5)
  s.tauntY = math.floor(y - uy + 0.5)
end

function TB:RestorePosition()
  local f = self.frame
  local s = T:Settings()
  f:ClearAllPoints()
  f:SetPoint("CENTER", UIParent, "CENTER", s.tauntX or 0, s.tauntY or -140)
end

local SAMPLE = { { name = "Onyxian Whelp", who = "Mendy", reason = "loose", sample = true } }

function TB:Update()
  local s = T:Settings()
  local f = self.frame
  local list = (s.enabled and s.tauntPopup and T:IsTank()) and T:Taunts() or {}
  local moving = UI.threatFrames and UI.threatFrames.moving
  if moving then list = SAMPLE end
  if table.getn(list) == 0 then
    if f and f:IsShown() then f:Hide() end
    return
  end
  f = self:Create()

  local spell, wait = T:ReadyTaunt()
  local shown = T:TauntSpells()[1]
  local icon = (spell and spell.icon) or (shown and shown.icon)
      or "Interface\\Icons\\Spell_Nature_Reincarnation"
  local blink = 0.4 + 0.6 * math.abs(math.sin(GetTime() * math.pi * 2))

  local n = 0
  for i = 1, ROWS do
    local b, t = self.rows[i], list[i]
    if t then
      n = i
      b.entry = t
      b.icon:SetTexture(icon)
      b.label:SetText("Taunt " .. (t.name or "?"))
      local why = (t.reason == "loose") and "loose" or "lost"
      b.sub:SetText(t.who and (why .. ", on " .. t.who) or why)
      if spell or not wait then
        b.cd:Hide()
        b.cdText:SetText("")
        b.icon:SetVertexColor(1, 1, 1)
      else
        b.cdText:SetText(string.format("%d", math.ceil(wait)))
        b.icon:SetVertexColor(0.6, 0.6, 0.6)
        if b.sweep and shown and GetSpellCooldown then
          local start, duration = GetSpellCooldown(shown.index, "spell")
          if b.sweepStart ~= start then
            b.sweepStart = start
            pcall(CooldownFrame_SetTimer, b.sweep, start, duration, 1)
          end
          b.cd:Hide()
        else
          b.cd:Show()
          b.cd:SetHeight(math.max(1, (ROW_H - 4) * math.min(1, wait / 10)))
        end
      end
      b.edge:SetAlpha(blink)
      b:Show()
    else
      b.entry = nil
      b:Hide()
    end
  end
  f:SetHeight(16 + n * (ROW_H + 2) + 2 + 2 * (self.pad or 0))
  if not f:IsShown() then f:Show() end
end

--- Key Bindings -> Wrekkit -> Taunt the mob that got away.
function Wrekkit_TauntBinding()
  W.Guard("taunt key", function()
    T:TauntNext()
    TB:Update()
  end)
end

BINDING_HEADER_WREKKIT = "Wrekkit"
BINDING_NAME_WREKKIT_TAUNT = "Taunt the mob that got away"

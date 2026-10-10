--[[ Wrekkit :: ui/widgets

Shared building blocks for both windows. 1.12 has no widget library worth
using, so this is the house style in one place: flat dark panels, a hairline
border, one amber accent, and rows that are textures rather than nine-slice
frames (cheaper, and they scale to any width without seams).

Scrolling is hand-rolled rather than FauxScrollFrame: row recycling with a
fixed pool means a 70-row enemy list costs the same as a 5-row one, and the
mouse wheel behaves the same in both windows.
]]

local W = Wrekkit
W.ui = W.ui or {}
local UI = W.ui

local MEDIA = "Interface\\AddOns\\Wrekkit\\textures\\"
UI.media = {
  white  = MEDIA .. "white",
  bar    = MEDIA .. "bar-fill",
  area   = MEDIA .. "chart-area",
  panel  = MEDIA .. "panel-bg",
  corner = MEDIA .. "corner",
  glow   = MEDIA .. "glow",
  sheen  = MEDIA .. "header-sheen",
  emblem = MEDIA .. "emblem",
  border = MEDIA .. "frame-border",
  globe  = MEDIA .. "globe",
  reset  = MEDIA .. "reset",
  group  = MEDIA .. "group",
  pick   = MEDIA .. "pick",
  lock   = MEDIA .. "lock",
  cog    = MEDIA .. "cog",
}

UI.font = "Fonts\\FRIZQT__.TTF"
-- The bitmap-ish face vanilla uses for numbers; keeps columns aligned.
UI.fontNum = "Fonts\\ARIALN.TTF"

local function unpackColor(c, a)
  return c[1], c[2], c[3], a or c[4] or 1
end

----------------------------------------------------------------------
-- skins
----------------------------------------------------------------------

--[[ How the windows are dressed. Three looks, all built from art the
     game or its UI addons already use, so Wrekkit sits among them rather
     than looking pasted on:

       blizzard  the stock UI's own pieces: tooltip borders on the HUD
                 windows, the parchment dialog border on Settings and the
                 Report, dropdown menus with the gold highlight bar and
                 check mark, the red panel buttons, the stock checkbox,
                 the X close button, the chat-frame size grabber, the
                 target-frame status bar, gold titles
       pfui      pfUI / ShaguPlates: a dark backdrop, a one-pixel border,
                 flat bars. With pfUI loaded its OWN CreateBackdrop, bar
                 texture and font are used, so your pfUI settings carry
                 over exactly
       modern    Wrekkit's flat dark panels

     "auto" (the default) is pfui when pfUI or ShaguPlates is loaded and
     blizzard otherwise. Chosen once at load, before any frame is built:
     a skin is how a frame is made, not a coat over it, so changing it
     asks for a /reload. ]]

UI.skin = "modern"

local BLIZZ_GOLD = { 1.00, 0.82, 0.00 }
local PFUI_ACCENT = { 0.20, 1.00, 0.80 }

function UI.ResolveSkin()
  local want = W.db and W.db.skin or "auto"
  if want == "blizzard" or want == "pfui" or want == "modern" then return want end
  if pfUI or ShaguPlates then return "pfui" end
  return "blizzard"
end

local function setColor(dst, src)
  dst[1], dst[2], dst[3] = src[1], src[2], src[3]
end

--- Pick the skin and set the media and colours it implies. Runs once,
--- after the saved settings load and before any window exists.
function UI.ApplySkin()
  UI.skin = UI.ResolveSkin()
  if UI.skin == "blizzard" then
    UI.media.bar = "Interface\\TargetingFrame\\UI-StatusBar"
    setColor(W.color.accent, BLIZZ_GOLD)
    setColor(W.color.accentHi, { 1, 1, 1 })
    setColor(W.color.text, { 1, 1, 1 })
    setColor(W.color.textDim, { 0.82, 0.82, 0.82 })
  elseif UI.skin == "pfui" then
    local pf = pfUI and pfUI.media
    UI.media.bar = (pf and pf["img:bar"]) or "Interface\\AddOns\\Wrekkit\\textures\\bar-fill"
    if pfUI and pfUI.font_default then UI.font = pfUI.font_default end
    setColor(W.color.accent, PFUI_ACCENT)
    setColor(W.color.accentHi, { 1, 1, 1 })
  end
  UI.skinBar = UI.media.bar
  local chosen = UI.BarTexturePath(W.db and W.db.barTexture)
  if chosen then UI.media.bar = chosen end
  UI.ApplyColorTheme(W.db and W.db.colorTheme)
  UI.skinFont = UI.font
  local face = UI.FontPath(W.db and W.db.font)
  if face then UI.font = face end
end

--[[ The text's font, apart from the look. The client's four, and pfUI's
     own and three of the fonts it ships, offered only with pfUI installed
     (they live in its folder). "skin" keeps the look's: pfUI's font with
     the pfUI look and pfUI loaded, the client's otherwise. Numbers keep
     their narrow face (UI.fontNum) whatever is chosen, so columns line up. ]]
local PFUI_FONTS = "Interface\\AddOns\\pfUI\\fonts\\"
local FONTS = {
  { value = "skin", label = "skin" },
  { value = "friz", label = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
  { value = "arial", label = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
  { value = "skurri", label = "Skurri", path = "Fonts\\skurri.ttf" },
  { value = "morpheus", label = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
  { value = "pfui", label = "pfUI's font", pfui = true },
  { value = "myriad", label = "Myriad Pro", path = PFUI_FONTS .. "Myriad-Pro.ttf", pfui = true },
  { value = "expressway", label = "Expressway", path = PFUI_FONTS .. "Expressway.ttf", pfui = true },
  { value = "ptsans", label = "PT Sans Narrow", path = PFUI_FONTS .. "PT-Sans-Narrow-Regular.ttf", pfui = true },
}

--- The fonts to offer: pfUI's only where pfUI is.
function UI.FontChoices()
  local out = {}
  for _, f in ipairs(FONTS) do
    if not f.pfui or pfUI then table.insert(out, f) end
  end
  return out
end

--- The file for a font choice, or nil for "use the look's".
function UI.FontPath(key)
  for _, f in ipairs(FONTS) do
    if f.value == key then
      if f.pfui and not pfUI then return nil end
      if f.value == "pfui" then return pfUI and pfUI.font_default or nil end
      return f.path
    end
  end
  return nil
end

--- Change the font everywhere it is the default face, at once, and
--- remember the choice. Text set in another face (the numbers) is left --
--- marked when it was made, not matched by file: Arial Narrow is both a
--- choice and the numbers' face, and matching by file changed both.
function UI.SetFont(key)
  if W.db then W.db.font = key end
  local old = UI.font
  UI.font = UI.FontPath(key) or UI.skinFont or UI.font
  if UI.font == old then return end
  local scale = UI.FontScale()
  for _, entry in ipairs(UI.fontObjects) do
    if entry.default then
      entry.face = UI.font
      UI.ApplyFontEntry(entry, scale)
    end
  end
end

--[[ Colours, apart from the look: Blizzard's gold, pfUI's teal, or the
     modern amber, with any chrome. Each theme is the accent and the text a
     look would set; everything else (panels, bars, class colours) is
     shared. "skin" (or nothing) keeps what the look chose. The modern
     values are the ones W.color starts with, kept before any look runs. ]]
local MODERN = {
  accent = { W.color.accent[1], W.color.accent[2], W.color.accent[3] },
  accentHi = { W.color.accentHi[1], W.color.accentHi[2], W.color.accentHi[3] },
  text = { W.color.text[1], W.color.text[2], W.color.text[3] },
  textDim = { W.color.textDim[1], W.color.textDim[2], W.color.textDim[3] },
}
local THEMES = {
  modern = MODERN,
  blizzard = { accent = BLIZZ_GOLD, accentHi = { 1, 1, 1 }, text = { 1, 1, 1 },
               textDim = { 0.82, 0.82, 0.82 } },
  pfui = { accent = PFUI_ACCENT, accentHi = { 1, 1, 1 }, text = MODERN.text,
           textDim = MODERN.textDim },
}
UI.COLOR_THEMES = {
  { value = "skin", label = "skin" },
  { value = "blizzard", label = "Blizzard" },
  { value = "pfui", label = "pfUI" },
  { value = "modern", label = "modern" },
}

function UI.ApplyColorTheme(key)
  local t = THEMES[key or ""]
  if not t then return end
  for name, c in pairs(t) do setColor(W.color[name], c) end
end

--- How strongly bars are drawn, 0.2-1. The looks all use 0.55; higher is
--- the solid, flat-colour bar of the pfUI style.
function UI.BarAlpha()
  local a = W.db and tonumber(W.db.barAlpha)
  if not a then return 0.55 end
  if a < 0.2 then a = 0.2 elseif a > 1 then a = 1 end
  return a
end

--[[ The bars' texture, apart from the skin: the flat colour of the pfUI and
     modern looks with the Blizzard chrome, or the other way round. "skin"
     (or nothing) keeps whatever the skin uses. ]]
UI.BAR_TEXTURES = {
  { value = "skin", label = "skin" },
  { value = "flat", label = "flat" },
  { value = "smooth", label = "smooth" },
  { value = "blizzard", label = "Blizzard" },
}

--- The file for a bar style, or nil for "use the skin's".
function UI.BarTexturePath(key)
  if key == "flat" then return UI.media.white end
  if key == "smooth" then return MEDIA .. "bar-fill" end
  if key == "blizzard" then return "Interface\\TargetingFrame\\UI-StatusBar" end
  return nil
end

--[[ Every bar texture, so a new style shows at once rather than after a
     /reload. Weak keys: a pooled row is never freed in 1.12 anyway, but the
     registry should not be what keeps anything alive. ]]
local bars = setmetatable({}, { __mode = "k" })

function UI.RegisterBar(tex)
  if tex then bars[tex] = true end
  return tex
end

--- Change the bar style everywhere, and remember it.
function UI.SetBarTexture(key)
  if W.db then W.db.barTexture = key end
  UI.media.bar = UI.BarTexturePath(key) or UI.skinBar or UI.media.bar
  for tex in pairs(bars) do tex:SetTexture(UI.media.bar) end
end

local BLIZZ_TOOLTIP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local BLIZZ_DIALOG = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
}
local BLIZZ_SMALL = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 8, edgeSize = 10,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
local PFUI_FLAT = {
  bgFile = "Interface\\AddOns\\Wrekkit\\textures\\white",
  edgeFile = "Interface\\AddOns\\Wrekkit\\textures\\white",
  tile = false, edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

--- How far a skinned frame's content must sit inside its edge.
function UI.SkinInset(kind)
  if UI.skin == "blizzard" then
    if kind == "dialog" then return 11 end
    if kind == "small" then return 3 end
    return 4
  end
  if UI.skin == "pfui" then return 1 end
  return 1
end

--[[ Dress a frame in the skin's backdrop. kind:
       window  a HUD window: meter, threat, mob frames, taunt bar, menus
       dialog  Settings, the Report, confirmations
       small   inputs and inner panes
     Returns true when a backdrop was applied (modern draws its own). The
     alpha is the window-opacity setting, applied to the backdrop only. ]]
function UI.Backdrop(f, kind, alpha)
  if UI.skin == "modern" or not f.SetBackdrop then return false end
  alpha = alpha or 1
  f._skinKind = kind or "window"
  if UI.skin == "pfui" then
    if pfUI and pfUI.api and pfUI.api.CreateBackdrop and not f._pfDone then
      -- pfUI's own: its border size, colours and shadow, as configured.
      local ok = pcall(pfUI.api.CreateBackdrop, f, nil, nil, 0.85)
      if ok then
        f._pfDone = true
        f._skinned = true
        return true
      end
    end
    f:SetBackdrop(PFUI_FLAT)
    f:SetBackdropColor(0, 0, 0, 0.75 * alpha)
    f:SetBackdropBorderColor(0.18, 0.18, 0.18, alpha)
  else
    if kind == "dialog" then
      f:SetBackdrop(BLIZZ_DIALOG)
      f:SetBackdropColor(1, 1, 1, alpha)
    elseif kind == "small" then
      f:SetBackdrop(BLIZZ_SMALL)
      f:SetBackdropColor(0.05, 0.05, 0.07, 0.9 * alpha)
    else
      f:SetBackdrop(BLIZZ_TOOLTIP)
      f:SetBackdropColor(0.05, 0.05, 0.08, 0.92 * alpha)
    end
    f:SetBackdropBorderColor(0.80, 0.80, 0.80, alpha)
  end
  f._skinned = true
  return true
end

--- Re-apply a skinned frame's backdrop at a new opacity.
function UI.BackdropAlpha(f, alpha)
  if not f._skinned or f._pfDone then
    if f._pfDone and f.backdrop and f.backdrop.SetAlpha then f.backdrop:SetAlpha(alpha) end
    return
  end
  local kind = f._skinKind
  if UI.skin == "pfui" then
    f:SetBackdropColor(0, 0, 0, 0.75 * alpha)
    f:SetBackdropBorderColor(0.18, 0.18, 0.18, alpha)
  else
    if kind == "dialog" then f:SetBackdropColor(1, 1, 1, alpha)
    elseif kind == "small" then f:SetBackdropColor(0.05, 0.05, 0.07, 0.9 * alpha)
    else f:SetBackdropColor(0.05, 0.05, 0.08, 0.92 * alpha) end
    f:SetBackdropBorderColor(0.80, 0.80, 0.80, alpha)
  end
end

----------------------------------------------------------------------
-- primitives
----------------------------------------------------------------------

--- Flat colour fill. Every surface in the addon is one of these.
function UI.Fill(parent, color, alpha, layer)
  local t = parent:CreateTexture(nil, layer or "BACKGROUND")
  t:SetTexture(UI.media.white)
  t:SetVertexColor(unpackColor(color, alpha))
  t:SetAllPoints(parent)
  -- Remembered so the alpha can be changed later without losing the colour:
  -- SetVertexColor takes all four at once, so re-applying alpha alone is not
  -- possible without knowing the other three.
  t._color = color
  return t
end

--- Hairline rule. Vanilla can't stroke, so a 1px filled texture stands in.
function UI.Line(parent, color, alpha)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetTexture(UI.media.white)
  t:SetVertexColor(unpackColor(color, alpha or 1))
  t:SetHeight(1)
  return t
end

--- A panel: filled background plus a 1px outline drawn as four edges. Four
--- textures beats SetBackdrop here because backdrop edge files tile visibly
--- at non-power-of-two sizes.
function UI.Panel(parent, color, borderColor, name, skinKind)
  local f = CreateFrame("Frame", name, parent)
  f.bg = UI.Fill(f, color or W.color.panel)

  local bc = borderColor or W.color.border
  local edges = {}
  for i = 1, 4 do
    local t = f:CreateTexture(nil, "BORDER")
    t:SetTexture(UI.media.white)
    t:SetVertexColor(unpackColor(bc))
    edges[i] = t
  end
  edges[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  edges[1]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  edges[1]:SetHeight(1)
  edges[2]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  edges[2]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  edges[2]:SetHeight(1)
  edges[3]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  edges[3]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  edges[3]:SetWidth(1)
  edges[4]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  edges[4]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  edges[4]:SetWidth(1)
  f.edges = edges

  f.SetBorderColor = function(self, c, a)
    self._borderColor = c
    self._borderAlpha = a
    if self._skinned then
      -- A skinned border stays the skin's grey; a highlight shows as a tint.
      if not self._pfDone and c ~= W.color.border then
        self:SetBackdropBorderColor(unpackColor(c, a))
      elseif not self._pfDone then
        UI.BackdropAlpha(self, self._opacity or 1)
      end
      return
    end
    for _, e in ipairs(self.edges) do e:SetVertexColor(unpackColor(c, a)) end
  end
  f._borderColor = bc

  -- Skinned, the backdrop replaces the flat fill and the hairlines.
  if skinKind ~= "none" and UI.Backdrop(f, skinKind or "small") then
    f.bg:Hide()
    for _, e in ipairs(edges) do e:Hide() end
  end
  return f
end

--[[ Text size is a setting, but SetFont only applies at the moment it is
     called -- there is no font scale on a 1.12 FontString. So every string
     the addon makes is remembered along with the size it was authored at,
     and changing the scale re-applies all of them.

     The registry only ever grows, which is fine: frames cannot be destroyed
     in this client either, so anything in it is still alive. ]]
UI.fontObjects = {}

function UI.FontScale()
  local s = (W.db and W.db.fontScale) or 1
  if s < 0.7 then s = 0.7 elseif s > 1.8 then s = 1.8 end
  return s
end

--- Track any object with SetFont so it follows the scale. Returns it.
--- `default`: set in the default face (UI.font), so a font choice moves it.
function UI.RegisterFont(obj, size, face, default)
  table.insert(UI.fontObjects, { obj = obj, size = size, face = face, default = default })
  return obj
end

local function applyFont(entry, scale)
  local px = entry.size * scale
  -- The client refuses absurd sizes outright and leaves the string blank.
  if px < 6 then px = 6 elseif px > 32 then px = 32 end
  entry.obj:SetFont(entry.face, px)
end
UI.ApplyFontEntry = applyFont

function UI.ApplyFontScale()
  local scale = UI.FontScale()
  for _, entry in ipairs(UI.fontObjects) do
    applyFont(entry, scale)
  end
end

function UI.Text(parent, size, color, justify, face)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  size = size or 12
  local default = (face == nil)
  face = face or UI.font
  applyFont({ obj = fs, size = size, face = face }, UI.FontScale())
  UI.RegisterFont(fs, size, face, default)
  fs:SetTextColor(unpackColor(color or W.color.text))
  fs:SetJustifyH(justify or "LEFT")
  fs:SetShadowColor(0, 0, 0, 0.9)
  fs:SetShadowOffset(1, -1)
  return fs
end

----------------------------------------------------------------------
-- buttons
----------------------------------------------------------------------

--- Text button with a hover wash. Used for tabs, menu entries and the
--- window controls; `active` gives it the amber underline.
function UI.Button(parent, label, width, height, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(width or 70)
  b:SetHeight(height or 20)

  b.bg = UI.Fill(b, W.color.panelHi, 0)
  b.label = UI.Text(b, 11, W.color.textDim, "CENTER")
  b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.label:SetText(label or "")

  b.underline = b:CreateTexture(nil, "OVERLAY")
  b.underline:SetTexture(UI.media.white)
  b.underline:SetVertexColor(unpackColor(W.color.accent))
  b.underline:SetHeight(2)
  b.underline:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
  b.underline:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
  b.underline:Hide()

  b.SetActive = function(self, on)
    self._active = on
    if on then
      self.underline:Show()
      self.label:SetTextColor(unpackColor(W.color.text))
      self.bg:SetVertexColor(unpackColor(W.color.panelHi, 1))
    else
      self.underline:Hide()
      self.label:SetTextColor(unpackColor(W.color.textDim))
      self.bg:SetVertexColor(unpackColor(W.color.panelHi, 0))
    end
  end

  b:SetScript("OnEnter", function()
    if not b._active then
      b.bg:SetVertexColor(unpackColor(W.color.panelHi, 0.7))
      b.label:SetTextColor(unpackColor(W.color.text))
    end
  end)
  b:SetScript("OnLeave", function()
    if not b._active then
      b.bg:SetVertexColor(unpackColor(W.color.panelHi, 0))
      b.label:SetTextColor(unpackColor(W.color.textDim))
    end
  end)
  if onClick then b:SetScript("OnClick", onClick) end

  if UI.skin == "blizzard" then UI.SkinBlizzardButton(b)
  elseif UI.skin == "pfui" then UI.SkinPfuiButton(b) end

  b:SetActive(false)
  return b
end

--[[ The stock red panel button (UIPanelButtonTemplate), in three slices
     so it never stretches its end caps, with the gold label that goes
     white under the mouse. A tab that is selected sits pressed in. ]]
local PANEL_UP = "Interface\\Buttons\\UI-Panel-Button-Up"
local PANEL_DOWN = "Interface\\Buttons\\UI-Panel-Button-Down"
local PANEL_HL = "Interface\\Buttons\\UI-Panel-Button-Highlight"

local function threeSlice(b, layer, file)
  local l = b:CreateTexture(nil, layer)
  l:SetTexture(file)
  l:SetTexCoord(0, 0.09375, 0, 0.6875)
  l:SetWidth(12)
  l:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  l:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
  local r = b:CreateTexture(nil, layer)
  r:SetTexture(file)
  r:SetTexCoord(0.53125, 0.625, 0, 0.6875)
  r:SetWidth(12)
  r:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
  r:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
  local m = b:CreateTexture(nil, layer)
  m:SetTexture(file)
  m:SetTexCoord(0.09375, 0.53125, 0, 0.6875)
  m:SetPoint("TOPLEFT", l, "TOPRIGHT", 0, 0)
  m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", 0, 0)
  return { l, m, r }
end

local function setSlices(slices, file)
  for _, t in ipairs(slices) do t:SetTexture(file) end
end

function UI.SkinBlizzardButton(b)
  b.bg:Hide()
  b.underline:Hide()
  b.slices = threeSlice(b, "BACKGROUND", PANEL_UP)
  b.glow = threeSlice(b, "HIGHLIGHT", PANEL_HL)
  for _, t in ipairs(b.glow) do t:SetBlendMode("ADD") t:SetAlpha(0) end
  b.label:SetTextColor(unpackColor(BLIZZ_GOLD))

  b.SetActive = function(self, on)
    self._active = on
    setSlices(self.slices, on and PANEL_DOWN or PANEL_UP)
    self.label:SetTextColor(unpackColor(on and { 1, 1, 1 } or BLIZZ_GOLD))
  end
  b:SetScript("OnMouseDown", function() setSlices(b.slices, PANEL_DOWN) end)
  b:SetScript("OnMouseUp", function() if not b._active then setSlices(b.slices, PANEL_UP) end end)
  b:SetScript("OnEnter", function()
    for _, t in ipairs(b.glow) do t:SetAlpha(1) end
    b.label:SetTextColor(1, 1, 1, 1)
  end)
  b:SetScript("OnLeave", function()
    for _, t in ipairs(b.glow) do t:SetAlpha(0) end
    if not b._active then b.label:SetTextColor(unpackColor(BLIZZ_GOLD)) end
  end)
end

--- pfUI's button: the dark backdrop with a one-pixel edge that lights in
--- the accent colour under the mouse or when selected.
function UI.SkinPfuiButton(b)
  b.bg:Hide()
  UI.Backdrop(b, "small")
  b.underline:SetHeight(1)
  b.SetActive = function(self, on)
    self._active = on
    if on then self.underline:Show() else self.underline:Hide() end
    self.label:SetTextColor(unpackColor(on and W.color.text or W.color.textDim))
  end
  b:SetScript("OnEnter", function()
    if not b._pfDone then b:SetBackdropBorderColor(unpackColor(W.color.accent)) end
    b.label:SetTextColor(unpackColor(W.color.text))
  end)
  b:SetScript("OnLeave", function()
    if not b._pfDone then b:SetBackdropBorderColor(0.18, 0.18, 0.18, 1) end
    if not b._active then b.label:SetTextColor(unpackColor(W.color.textDim)) end
  end)
end

--[[ Small square icon button with a lit/unlit state.

     The icons are authored white, so "lit" is a tint to the accent colour
     and "unlit" is a dim grey -- one texture, two states, no second asset to
     keep in sync. Used for toggles where the button itself should show what
     it is currently doing. ]]
function UI.IconButton(parent, texture, size, onClick, tip)
  size = size or 18
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(size)
  b:SetHeight(size)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  b.bg = UI.Fill(b, W.color.panelHi, 0)

  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetTexture(texture)
  b.icon:SetWidth(size - 5)
  b.icon:SetHeight(size - 5)
  b.icon:SetPoint("CENTER", b, "CENTER", 0, 0)

  b.SetLit = function(self, on)
    self._lit = on
    if on then
      self.icon:SetVertexColor(unpackColor(W.color.accent))
      self.icon:SetAlpha(1)
      self.bg:SetVertexColor(unpackColor(W.color.accent, 0.12))
    else
      self.icon:SetVertexColor(unpackColor(W.color.textFaint))
      -- dimAlpha lets a caller make the unlit state nearly invisible, for
      -- icons that repeat on every row and would otherwise be clutter.
      self.icon:SetAlpha(self.dimAlpha or 0.8)
      self.bg:SetVertexColor(unpackColor(W.color.panelHi, 0))
    end
  end

  b:SetScript("OnEnter", function()
    if not b._lit then
      b.icon:SetVertexColor(unpackColor(W.color.text))
      b.bg:SetVertexColor(unpackColor(W.color.panelHi, 0.8))
    end
    if tip and GameTooltip then
      GameTooltip:SetOwner(b, "ANCHOR_TOPLEFT")
      GameTooltip:AddLine(tip.title or "")
      for _, l in ipairs(tip.lines or {}) do
        GameTooltip:AddLine(l, 0.72, 0.75, 0.8)
      end
      GameTooltip:Show()
    end
  end)

  b:SetScript("OnLeave", function()
    b:SetLit(b._lit)
    if GameTooltip then GameTooltip:Hide() end
  end)

  if onClick then b:SetScript("OnClick", onClick) end
  b:SetLit(false)
  return b
end

----------------------------------------------------------------------
-- dropdown menu
----------------------------------------------------------------------

--[[ UIDropDownMenu exists in 1.12 but drags in a lot of taint-prone global
     state for what is a list of buttons. This is that list of buttons.

     One menu frame and one click-catcher are built on first use and reused
     forever after. 1.12 has no way to destroy a frame, so building a fresh
     menu per open would leak a frame and a full-screen button every time
     someone browsed the metric list -- invisible, permanent, and it adds up
     over a raid night. Rows are pooled the same way. ]]

local menuFrame, menuCatcher
local menuRows = {}

function UI.CloseMenu()
  if menuFrame then menuFrame:Hide() end
  if menuCatcher then menuCatcher:Hide() end
end

local ROW_H = 18
local MENU_PAD = 4
-- Room inside a skinned border; read when the menu is first built.
local function menuPad() return (UI.skin == "blizzard") and 9 or MENU_PAD end

local function ensureMenu()
  if menuFrame then return menuFrame end

  menuCatcher = CreateFrame("Button", "WrekkitMenuCatcher", UIParent)
  menuCatcher:SetAllPoints(UIParent)
  menuCatcher:SetFrameStrata("FULLSCREEN")
  menuCatcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  menuCatcher:SetScript("OnClick", function() UI.CloseMenu() end)
  menuCatcher:Hide()

  menuFrame = UI.Panel(UIParent, W.color.panel, W.color.borderHi, nil, "window")
  menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
  menuFrame:EnableMouse(true)
  menuFrame:Hide()
  menuFrame:SetScript("OnHide", function()
    if menuCatcher then menuCatcher:Hide() end
  end)

  return menuFrame
end

local function menuRow(index)
  local existing = menuRows[index]
  if existing then return existing end

  local pad = menuPad()
  local b = CreateFrame("Button", nil, menuFrame)
  b:SetHeight(ROW_H)
  b:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", pad,
    -(pad + (index - 1) * ROW_H))
  b:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -pad,
    -(pad + (index - 1) * ROW_H))

  b.label = UI.Text(b, 11, W.color.text)
  b.label:SetPoint("LEFT", b, "LEFT", 16, 0)

  if UI.skin == "blizzard" then
    -- A dropdown list as the stock UI draws one: the gold bar under the
    -- mouse and the check mark beside the chosen entry.
    b.hl = b:CreateTexture(nil, "BACKGROUND")
    b.hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    b.hl:SetBlendMode("ADD")
    b.hl:SetAllPoints(b)
    b.hl:SetAlpha(0)
    b.tick = b:CreateTexture(nil, "OVERLAY")
    b.tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    b.tick:SetWidth(16) b.tick:SetHeight(16)
    b.tick:SetPoint("LEFT", b, "LEFT", -1, 0)
    b.hl.SetVertexColor = function(self, r, g, bb, a) self:SetAlpha(a or 0) end
  else
    b.hl = UI.Fill(b, W.color.accent, 0, "BACKGROUND")
    b.tick = b:CreateTexture(nil, "OVERLAY")
    b.tick:SetTexture(UI.media.white)
    b.tick:SetVertexColor(unpackColor(W.color.accent))
    b.tick:SetWidth(3) b.tick:SetHeight(ROW_H - 8)
    b.tick:SetPoint("LEFT", b, "LEFT", 5, 0)
  end

  b:SetScript("OnEnter", function()
    if not b._disabled then
      b.hl:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3],
        (UI.skin == "blizzard") and 1 or 0.16)
    end
  end)
  b:SetScript("OnLeave", function()
    b.hl:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 0)
  end)

  menuRows[index] = b
  return b
end

--[[ items: array of { text, value, checked, disabled, header }
     onPick(value, item) fires on selection.

     A `header` item is a section title: amber, flush left, not clickable.
     Long menus read as groups rather than as one undifferentiated column,
     which is most of what makes a menu feel designed. ]]
function UI.Menu(parent, anchorTo, items, onPick, width)
  local f = ensureMenu()
  UI.CloseMenu()

  local n = table.getn(items)
  f:SetWidth(width or 150)
  f:SetHeight(n * ROW_H + menuPad() * 2)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -2)
  -- A long menu opened low on the screen would run off the bottom.
  f:SetClampedToScreen(true)

  for i = 1, n do
    local item = items[i]
    local b = menuRow(i)
    b._disabled = item.disabled or item.header
    b.label:SetText(item.text)
    b.label:ClearAllPoints()
    if item.header then
      b.label:SetPoint("LEFT", b, "LEFT", 4, -2)
      b.label:SetTextColor(unpackColor(W.color.accent))
    else
      b.label:SetPoint("LEFT", b, "LEFT", 16, 0)
      b.label:SetTextColor(unpackColor(item.disabled and W.color.textFaint or W.color.text))
    end
    if item.checked and not item.header then b.tick:Show() else b.tick:Hide() end
    b.hl:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 0)

    if b._disabled then
      b:SetScript("OnClick", nil)
    else
      b:SetScript("OnClick", function()
        UI.CloseMenu()
        if onPick then onPick(item.value, item) end
      end)
    end
    b:Show()
  end

  -- Hide any rows left over from a longer menu.
  for i = n + 1, table.getn(menuRows) do menuRows[i]:Hide() end

  -- Exposed so a test can click an item, as UI.Check exposes its tick.
  f.rows = menuRows

  menuCatcher:Show()
  f:Show()
  return f
end

----------------------------------------------------------------------
-- search box
----------------------------------------------------------------------

function UI.SearchBox(parent, width, onChange, placeholder)
  local f = UI.Panel(parent, W.color.bg, W.color.border)
  f:SetWidth(width or 130)
  f:SetHeight(20)

  local eb = CreateFrame("EditBox", nil, f)
  eb:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -1)
  eb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 1)
  eb:SetFont(UI.font, 11 * UI.FontScale())
  UI.RegisterFont(eb, 11, UI.font, true)
  eb:SetTextColor(unpackColor(W.color.text))
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(24)

  local hint = UI.Text(f, 11, W.color.textFaint)
  hint:SetPoint("LEFT", f, "LEFT", 7, 0)
  hint:SetText(placeholder or "Search")

  local clear = CreateFrame("Button", nil, f)
  clear:SetWidth(14) clear:SetHeight(14)
  clear:SetPoint("RIGHT", f, "RIGHT", -3, 0)
  local x = UI.Text(clear, 12, W.color.textFaint, "CENTER")
  x:SetPoint("CENTER", clear, "CENTER", 0, 0)
  x:SetText("x")
  clear:Hide()

  local function changed()
    local text = eb:GetText() or ""
    if text == "" then hint:Show() clear:Hide() else hint:Hide() clear:Show() end
    if onChange then onChange(text) end
  end

  eb:SetScript("OnTextChanged", changed)
  eb:SetScript("OnEscapePressed", function() eb:SetText("") eb:ClearFocus() end)
  eb:SetScript("OnEnterPressed", function() eb:ClearFocus() end)
  clear:SetScript("OnClick", function() eb:SetText("") eb:ClearFocus() end)
  clear:SetScript("OnEnter", function() x:SetTextColor(unpackColor(W.color.text)) end)
  clear:SetScript("OnLeave", function() x:SetTextColor(unpackColor(W.color.textFaint)) end)

  f.editBox = eb
  f.SetValue = function(self, v) eb:SetText(v or "") end
  return f
end

----------------------------------------------------------------------
-- ranked row
----------------------------------------------------------------------

--[[ One line of a meter or report table: rank, name, a proportional bar
     behind the text, the value, and a secondary column. The bar is a single
     stretched texture -- no segment stacking -- so a full list redraws in
     one pass per row. ]]

-- Below this a name is not a name, it is an initial. The window's minimum
-- width is set so this is never actually reached.
local MIN_NAME_W = 60

--[[ Class icons, from the character-create sheet -- the one TWThreat draws
     its class icons from on this client -- at the coordinates pfUI uses
     for it. 1.12 has no spec API, so a class is as specific as it gets. ]]
local CLASS_SHEET = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local CLASS_COORDS = {
  WARRIOR = { 0, 0.25, 0, 0.25 },
  MAGE    = { 0.25, 0.49609375, 0, 0.25 },
  ROGUE   = { 0.49609375, 0.7421875, 0, 0.25 },
  DRUID   = { 0.7421875, 0.98828125, 0, 0.25 },
  HUNTER  = { 0, 0.25, 0.25, 0.5 },
  SHAMAN  = { 0.25, 0.49609375, 0.25, 0.5 },
  PRIEST  = { 0.49609375, 0.7421875, 0.25, 0.5 },
  WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
  PALADIN = { 0, 0.25, 0.5, 0.75 },
}
UI.CLASS_COORDS = CLASS_COORDS

--- Are class icons on? A setting, off unless asked for.
function UI.ClassIcons()
  return W.db and W.db.classIcons == true
end

function UI.Row(parent, height)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(height or 18)

  r.bg = UI.Fill(r, W.color.panelHi, 0)

  r.bar = r:CreateTexture(nil, "BORDER")
  r.bar:SetTexture(UI.media.bar)
  UI.RegisterBar(r.bar)
  r.bar:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
  r.bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)

  r.rank = UI.Text(r, 10, W.color.textFaint, "RIGHT")
  r.rank:SetPoint("LEFT", r, "LEFT", 0, 0)
  r.rank:SetWidth(20)

  -- A player's class, between the rank and the name, when class icons are
  -- on (see UI.ClassIcons) and the painter named a class (r:SetClass).
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetTexture(CLASS_SHEET)
  r.icon:SetPoint("LEFT", r, "LEFT", 24, 0)
  r.icon:Hide()

  r.name = UI.Text(r, 11, W.color.text, "LEFT")
  r.name:SetPoint("LEFT", r, "LEFT", 26, 0)

  --- Name the class for the next SetData only. Rows are reused, so a row
  --- whose painter does not call this shows no icon, never a stale one.
  r.SetClass = function(self, class) self._nextClass = class end

  r.sub = UI.Text(r, 10, W.color.textDim, "RIGHT")
  r.sub:SetPoint("RIGHT", r, "RIGHT", -6, 0)

  r.value = UI.Text(r, 11, W.color.text, "RIGHT")
  r.value:SetPoint("RIGHT", r.sub, "LEFT", -8, 0)

  r.hl = UI.Fill(r, W.color.text, 0, "OVERLAY")

  --[[ A painter may hang a Tooltip on the row. Called from here rather than
       replacing OnEnter, because a painter that set its own OnEnter would
       silently take the highlight away with it -- and rows are reused, so
       every painter has to set r.tip or clear it, or a row keeps the one
       it was given in a mode you have since left. ]]
  r:SetScript("OnEnter", function()
    r.hl:SetVertexColor(unpackColor(W.color.text, 0.06))
    if r.tip then r:tip() end
  end)
  r:SetScript("OnLeave", function()
    r.hl:SetVertexColor(unpackColor(W.color.text, 0))
    if r.tip and GameTooltip then GameTooltip:Hide() end
  end)

  --- Paint one data row. `frac` is 0..1 of the widest bar in the list.
  r.SetData = function(self, rank, name, value, sub, frac, color, subWidth)
    -- The class icon: shown, sized to the row, and the name moved over for
    -- it -- or gone, and the name back at the gutter.
    local coords = UI.ClassIcons() and CLASS_COORDS[self._nextClass or ""]
    self._nextClass = nil
    local iconW = 0
    if coords then
      local size = (self:GetHeight() or 18) - 4
      if size < 8 then size = 8 end
      self.icon:SetWidth(size)
      self.icon:SetHeight(size)
      self.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
      self.icon:Show()
      iconW = size + 3
    else
      self.icon:Hide()
    end
    if self._iconW ~= iconW then
      self._iconW = iconW
      self.name:ClearAllPoints()
      self.name:SetPoint("LEFT", self, "LEFT", 26 + iconW, 0)
    end
    self.rank:SetText(rank and tostring(rank) .. "." or "")
    self.name:SetText(name or "")
    self.value:SetText(value or "")
    self.sub:SetText(sub or "")
    --[[ Callers give the secondary column its width at a text scale of 1.
         Scale it here so raising the text size widens the column with the
         digits instead of clipping them, and lowering it hands the space
         back to the name. ]]
    local scale = (W.db and W.db.fontScale) or 1
    local subW = math.ceil((subWidth or 64) * scale)
    self.sub:SetWidth(subW)

    --[[ The row's width, from its list when it has one. A list re-anchors
         its rows when the row height changes -- which the stretched row
         modes do as they fill the window -- and paints them straight after,
         when the client can still report a row's OLD width: the top bar,
         meant to span the row, stopped short and left the rest undrawn.
         The list itself is not re-anchored then, so its width is current;
         a row spans it less the scrollbar's inset (EnsureRows). ]]
    local w
    local list = self._list
    if list then
      w = (list:GetWidth() or 0) - (list._anchorW or 0)
    end
    if not w or w <= 0 then w = self:GetWidth() end
    if not w or w <= 0 then w = 200 end
    local barW = w * (frac or 0)
    if barW < 1 then barW = 1 end
    self.bar:SetWidth(barW)
    self.bar:SetVertexColor(color[1], color[2], color[3], UI.BarAlpha())

    --[[ Give the name every pixel the numbers do not need.

         This used to subtract a flat 74 for the value column while the
         value itself is right-anchored with no width, so it auto-sizes to
         its text. A short number like "862" left roughly forty pixels of
         dead space between the name and the figure -- space the name had
         already been charged for. At a larger text size the constant was
         wrong the other way, and names lost characters to a gap.

         The value is unconstrained, so GetStringWidth is its true width.
         Rounding up to a step keeps the name from reflowing every refresh
         as a live number ticks between widths. ]]
    local STEP = 12
    local valueW = self.value:GetStringWidth() or 0
    valueW = math.ceil(valueW / STEP) * STEP
    if valueW < STEP then valueW = STEP end

    -- 26 is the rank gutter; 14 covers the gaps either side of the value.
    local nameW = w - 26 - iconW - subW - valueW - 14
    --[[ Too narrow for everything -- a meter split into columns, at a small
         text size. The secondary column (per second, a percentage) goes
         first, and the value moves up to the edge. If the name still does
         not fit it is cut short. It used to be held at MIN_NAME_W regardless,
         which drew it straight over the value. ]]
    if nameW < MIN_NAME_W and subW > 0 then
      self.sub:SetText("")
      subW = 1
      self.sub:SetWidth(subW)
      nameW = w - 26 - iconW - subW - valueW - 14
    end
    if nameW < 1 then nameW = 1 end
    self.name:SetWidth(nameW)
    self:Show()
  end

  return r
end

----------------------------------------------------------------------
-- scrolling list
----------------------------------------------------------------------

--[[ Fixed pool of rows + an offset. `Render(fn)` calls fn(row, item, index)
     for each visible slot. Rows outside the data range are hidden rather
     than destroyed, so scrolling never allocates. ]]

function UI.ScrollList(parent, rowHeight, makeRow)
  local list = CreateFrame("Frame", nil, parent)
  list.rowHeight = rowHeight or 18
  list.offset = 0
  list.rows = {}
  list.data = {}
  list.makeRow = makeRow or UI.Row

  local track = UI.Panel(list, W.color.bg, W.color.bg, nil, "none")
  track:SetWidth(4)
  track:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
  track:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
  track:Hide()

  local thumb = UI.Fill(track, W.color.borderHi, 1, "ARTWORK")
  thumb:ClearAllPoints()
  thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
  thumb:SetPoint("TOPRIGHT", track, "TOPRIGHT", 0, 0)
  thumb:SetHeight(20)

  list.track, list.thumb = track, thumb

  function list:VisibleCount()
    local h = self:GetHeight()
    if not h or h <= 0 then return 0 end
    --[[ A zero row height would make this h/0, and EnsureRows would then
         loop creating frames until the client died -- 1.12 cannot destroy a
         frame, so there is no recovering from it either. The settings
         stepper clamps to 10-32 so this is not reachable today, but the
         constructor takes the value raw and `0 or 18` is 0 in Lua, so the
         one thing standing between a bad saved value and a hang is this
         line. ]]
    local rh = self.rowHeight
    if not rh or rh < 1 then rh = 18 end
    return math.floor(h / rh)
  end

  function list:MaxOffset()
    local n = table.getn(self.data)
    local vis = self:VisibleCount()
    local m = n - vis
    if m < 0 then m = 0 end
    return m
  end

  function list:EnsureRows(n)
    local scrollW = (self:MaxOffset() > 0) and 8 or 0
    local have = table.getn(self.rows)
    for i = have + 1, n do
      self.rows[i] = self.makeRow(self, self.rowHeight)
      -- Placed by this list, so it spans it (see the row's SetData).
      self.rows[i]._list = self
    end
    -- Re-anchor when the layout changed: the scrollbar appearing or
    -- vanishing moves the right inset, and the row height is a live
    -- setting. Not on every repaint -- SetPoint on every row twice a
    -- second, or every frame of a resize drag, is layout work for nothing.
    if have == table.getn(self.rows) and self._anchorW == scrollW
       and self._anchorH == self.rowHeight then
      return
    end
    self._anchorW, self._anchorH = scrollW, self.rowHeight
    for i = 1, table.getn(self.rows) do
      local row = self.rows[i]
      local y = -(i - 1) * self.rowHeight
      row:SetHeight(self.rowHeight)
      row:SetPoint("TOPLEFT", self, "TOPLEFT", 0, y)
      row:SetPoint("TOPRIGHT", self, "TOPRIGHT", -scrollW, y)
    end
  end

  --- Change row density at runtime. Pooled rows are re-anchored on the next
  --- render, so this only has to record the new height.
  function list:SetRowHeight(h)
    if not h or h < 8 then h = 8 end
    if h == self.rowHeight then return end
    self.rowHeight = h
    if self._paint then self:Render(self._paint) end
  end

  --- paint(row, item, absoluteIndex) fills one row from one datum.
  function list:Render(paint)
    local vis = self:VisibleCount()
    self:EnsureRows(vis)

    local maxOff = self:MaxOffset()
    if self.offset > maxOff then self.offset = maxOff end
    if self.offset < 0 then self.offset = 0 end

    for i = 1, table.getn(self.rows) do
      local row = self.rows[i]
      if i <= vis then
        local idx = i + self.offset
        local item = self.data[idx]
        if item then
          paint(row, item, idx)
          row:Show()
        else
          row:Hide()
        end
      else
        row:Hide()
      end
    end

    if maxOff > 0 then
      track:Show()
      local frac = self.offset / maxOff
      local trackH = self:GetHeight() or 1
      local thumbH = math.max(16, trackH * (vis / table.getn(self.data)))
      thumb:SetHeight(thumbH)
      thumb:ClearAllPoints()
      thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, -frac * (trackH - thumbH))
      thumb:SetPoint("TOPRIGHT", track, "TOPRIGHT", 0, -frac * (trackH - thumbH))
    else
      track:Hide()
    end
  end

  function list:SetData(data, paint)
    self.data = data or {}
    self._paint = paint or self._paint
    if self._paint then self:Render(self._paint) end
  end

  function list:Scroll(delta)
    self.offset = self.offset - delta * 3
    if self._paint then self:Render(self._paint) end
  end

  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function() list:Scroll(arg1) end)

  return list
end

----------------------------------------------------------------------
-- window chrome
----------------------------------------------------------------------

--- Movable, resizable window with a title bar. Returns the frame; the
--- caller fills `frame.body`.
function UI.Window(name, width, height, title, opts)
  opts = opts or {}
  -- The global name matters: UISpecialFrames closes frames by name, so a
  -- nameless window can never be dismissed with Escape.
  local kind = opts.skin or "window"
  local f = UI.Panel(UIParent, W.color.bg, W.color.border, name, kind)
  local inset = f._skinned and UI.SkinInset(kind) or 1
  -- Kept: what is inside the border is the window less this on each side,
  -- and a layout sized to the whole window spills out of a thick one.
  f.inset = inset
  f:SetWidth(width) f:SetHeight(height)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

  --[[ Know when the window is being dragged, by anyone.

       Re-anchoring or resizing a frame the client is moving takes the
       process down -- ERROR #132, an access violation, no Lua error to
       catch. The fit and the part-row trim do both, twice a second, so
       they have to hold off for the length of a drag; this flag is how
       they know. Set here, around the client's own calls, so every way a
       window is moved (its title, the docked threat window dragging the
       meter) is covered without each remembering to. ]]
  local startMoving, stopMoving = f.StartMoving, f.StopMovingOrSizing
  f.StartMoving = function(self)
    self._moving = true
    return startMoving(self)
  end
  f.StopMovingOrSizing = function(self)
    local r = stopMoving(self)
    self._moving = nil
    return r
  end

  -- Strata decides which window wins when they overlap. The report has to
  -- sit above the meter, or the meter's bars draw straight through it.
  f:SetFrameStrata(opts.strata or "MEDIUM")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetResizable(true)
  f:SetClampedToScreen(true)
  if f.SetMinResize then f:SetMinResize(opts.minW or 260, opts.minH or 120) end
  f:Hide()

  -- title bar
  local bar = CreateFrame("Frame", nil, f)
  bar:SetHeight(opts.barHeight or 26)
  bar:SetPoint("TOPLEFT", f, "TOPLEFT", inset, -inset)
  bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -inset, -inset)
  f.barBg = UI.Fill(bar, W.color.panel)

  local sheen = bar:CreateTexture(nil, "ARTWORK")
  sheen:SetTexture(UI.media.sheen)
  sheen:SetAllPoints(bar)
  sheen:SetAlpha(0.5)

  local rule = UI.Line(f, W.color.border)
  rule:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
  rule:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)

  local mark = bar:CreateTexture(nil, "OVERLAY")
  mark:SetTexture(UI.media.emblem)
  mark:SetWidth(14) mark:SetHeight(14)
  mark:SetPoint("LEFT", bar, "LEFT", 7, 0)

  f.title = UI.Text(bar, 12, W.color.text)
  f.title:SetPoint("LEFT", mark, "RIGHT", 6, 0)
  f.title:SetText(title or "Wrekkit")

  f.subtitle = UI.Text(bar, 10, W.color.textDim)
  f.subtitle:SetPoint("LEFT", f.title, "RIGHT", 8, 0)

  --[[ Skinned chrome. The flat title-bar fill and its sheen go; Blizzard
       titles are gold, and a dialog wears the parchment header plate the
       stock options windows carry, with its title set into it. ]]
  if UI.skin ~= "modern" then
    sheen:Hide()
    f.barBg:SetVertexColor(0, 0, 0, (UI.skin == "pfui") and 0.35 or 0)
    rule:SetVertexColor(1, 1, 1, (UI.skin == "pfui") and 0.08 or 0.12)
  end
  if UI.skin == "blizzard" then
    f.title:SetTextColor(unpackColor(BLIZZ_GOLD))
    if kind == "dialog" then
      local header = f:CreateTexture(nil, "ARTWORK")
      header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
      header:SetWidth(300) header:SetHeight(64)
      header:SetPoint("TOP", f, "TOP", 0, 12)
      f.header = header
      f.title:ClearAllPoints()
      f.title:SetPoint("TOP", header, "TOP", 0, -14)
      f.title:SetJustifyH("CENTER")
      f.subtitle:ClearAllPoints()
      f.subtitle:SetPoint("LEFT", bar, "LEFT", 8, -2)
      mark:Hide()
    end
  end

  -- drag
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() f:StartMoving() end)
  bar:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    if f.SavePosition then f:SavePosition() end
  end)

  -- close
  local close = CreateFrame("Button", nil, bar)
  close:SetWidth(20) close:SetHeight(20)
  close:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
  if UI.skin == "blizzard" then
    -- The stock red X, as on every Blizzard window.
    local sz = (kind == "dialog") and 28 or 22
    close:SetWidth(sz) close:SetHeight(sz)
    close:ClearAllPoints()
    close:SetPoint("RIGHT", bar, "RIGHT", 2, 0)
    close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
  else
    local cx = UI.Text(close, 13, W.color.textDim, "CENTER")
    cx:SetPoint("CENTER", close, "CENTER", 0, 0)
    cx:SetText("x")
    close:SetScript("OnEnter", function() cx:SetTextColor(unpackColor(W.color.accent)) end)
    close:SetScript("OnLeave", function() cx:SetTextColor(unpackColor(W.color.textDim)) end)
  end
  close:SetScript("OnClick", function() f:Hide() end)
  f.closeButton = close

  -- resize grip
  local grip = CreateFrame("Button", nil, f)
  grip:SetWidth(14) grip:SetHeight(14)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset - 1, inset + 1)
  if UI.skin == "blizzard" then
    -- The chat window's size grabber.
    grip:SetWidth(16) grip:SetHeight(16)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  else
    -- three stacked diagonal pips in the corner
    for i = 1, 3 do
      local p = grip:CreateTexture(nil, "OVERLAY")
      p:SetTexture(UI.media.white)
      p:SetVertexColor(unpackColor(W.color.borderHi))
      p:SetWidth(2 + (3 - i) * 3) p:SetHeight(1)
      p:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -1, i * 3 - 2)
    end
  end
  grip:RegisterForDrag("LeftButton")
  grip:SetScript("OnDragStart", function()
    f._sizing = true
    f:StartSizing("BOTTOMRIGHT")
  end)
  grip:SetScript("OnDragStop", function()
    f._sizing = nil
    f:StopMovingOrSizing()
    -- Fitted to its rows: what was just dragged is the new most it may grow to.
    if f._maxH then f._maxH = f:GetHeight() end
    if f.SavePosition then f:SavePosition() end
    if f.OnResize then f:OnResize() end
    -- Done resizing: a window may tidy its size now (the meter snaps to
    -- whole rows), which it must not do while the grip is held.
    if f.OnResizeEnd then f:OnResizeEnd() end
    --[[ And again a moment later. Right after the grip is let go the client
         can still report a child's old height, and a fit or a trim worked
         out from it is wrong until something redraws -- which, with nothing
         changing, was the next click on a setting. ]]
    if f.OnResize then
      W.After(0.1, function() if not f._sizing then f:OnResize() end end, f._resizeKey .. ":settle1")
      W.After(0.3, function() if not f._sizing then f:OnResize() end end, f._resizeKey .. ":settle2")
    end
  end)
  f.grip = grip

  -- body
  local body = CreateFrame("Frame", nil, f)
  body:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -1)
  body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset, inset)
  f.body = body
  f.bar = bar

  --[[ Relayout AFTER the size change, never inside it.

       OnSizeChanged is the client's own layout callback. Running the full
       relayout from inside it means calling SetPoint and SetWidth on child
       regions while the layout pass that triggered us is still unwinding --
       re-entering the very machinery that called us. In 1.12 that is a
       documented way to take the process down rather than raise a Lua
       error, and a drag-resize fires this every single frame, so a long
       drag is thousands of chances to land on it.

       Deferring by a tick also collapses a whole drag into one relayout
       instead of one per frame, which matters because Refresh re-sorts and
       repaints every row. The key makes W.After replace any pending
       relayout for this window rather than queue another. ]]
  --[[ Let the window see through to the game behind it.

       Deliberately NOT frame:SetAlpha. That fades the frame and everything
       inside it -- the names, the numbers, the bars -- so at the setting
       people actually want, a meter thin enough to see a boss through is
       also too thin to read. Only the chrome fades here: the panel fill,
       the title bar and the border. Text and bars keep their own alpha and
       stay crisp at any setting.

       The sheen over the title bar is left alone too; it is a highlight on
       the bar, so it tracks the bar rather than the world behind it. ]]
  f.SetOpacity = function(self, alpha)
    if alpha == nil then alpha = 1 end
    if alpha < 0 then alpha = 0 end
    if alpha > 1 then alpha = 1 end
    self._opacity = alpha

    -- Skinned: the backdrop carries the opacity, edge and all.
    if self._skinned then
      UI.BackdropAlpha(self, alpha)
      if self.barBg and self.barBg._color and UI.skin == "pfui" then
        self.barBg:SetVertexColor(0, 0, 0, 0.35 * alpha)
      end
      return
    end

    if self.bg and self.bg._color then
      self.bg:SetVertexColor(unpackColor(self.bg._color, alpha))
    end
    if self.barBg and self.barBg._color then
      self.barBg:SetVertexColor(unpackColor(self.barBg._color, alpha))
    end
    for _, e in ipairs(self.edges or {}) do
      e:SetVertexColor(unpackColor(self._borderColor or W.color.border, alpha))
    end
  end

  --[[ During a drag the size changes every frame, and a relayout every
       frame was what made dragging a window bigger stutter: each one
       ranks, repaints and re-anchors every row. While the grip is held
       the relayout runs at most ten times a second -- a pending one is
       left alone rather than pushed back, so the bars still follow the
       mouse -- and letting go does one final pass (OnDragStop). ]]
  f._resizeKey = "resize:" .. tostring(name or f)
  local function relayout()
    f._resizePending = nil
    if f.OnResize then f:OnResize() end
  end
  f:SetScript("OnSizeChanged", function()
    if not f.OnResize then return end
    if f._sizing then
      if f._resizePending then return end
      f._resizePending = true
      W.After(0.1, relayout, f._resizeKey)
    else
      W.After(0, relayout, f._resizeKey)
    end
  end)

  return f
end

--- Let Escape dismiss a window, the way Blizzard's own panels behave.
--- Deliberately not applied to the meter: that is a HUD element meant to sit
--- on screen, and having it vanish when you press Escape to clear a target
--- would be a surprise, not a convenience.
function UI.CloseOnEscape(frameName)
  if type(UISpecialFrames) ~= "table" then return end
  for _, existing in ipairs(UISpecialFrames) do
    if existing == frameName then return end
  end
  table.insert(UISpecialFrames, frameName)
end

--- Persist and restore a window's geometry into a saved-variables table.
function UI.BindGeometry(frame, store)
  frame.SavePosition = function(self)
    local point, _, _, x, y = self:GetPoint()
    store.point = point
    store.x = x
    store.y = y
    store.w = self:GetWidth()
    -- Fitted to its rows (UI.FitHeight), the height on screen is the fit;
    -- the one to keep is the height the window was sized to.
    store.h = self._maxH or self:GetHeight()
    -- Saved after every move and resize, and after either the client has
    -- re-anchored the window itself: hold it by its top again before the
    -- next fit or trim changes its height, or the title bar moves instead.
    self._topAnchored = nil
  end
  frame.RestorePosition = function(self)
    self:ClearAllPoints()
    self:SetPoint(store.point or "CENTER", UIParent, store.point or "CENTER",
      store.x or 0, store.y or 0)
    if store.w then self:SetWidth(store.w) end
    if store.h then self:SetHeight(store.h) end
  end
  frame:RestorePosition()
end

--[[ Fit a window's height to the rows it is showing (#15: five players in
     a window sized for eight left a block of empty space under them).

     The height the window was sized to becomes the most it grows to
     (frame._maxH): it shrinks to the rows, and grows back as more arrive.
     The window is anchored by its top-left first, so the title bar stays
     put and only the bottom edge moves. Nothing happens while the grip is
     held -- the drag is the user's. `n` is the rows wanted; `list` is the
     ScrollList they go in, everything else in the window being chrome. ]]
function UI.FitHeight(f, list, n)
  -- Never mid-drag: see the note on _moving in UI.Window.
  if not f or not list or f._sizing or f._moving then return end
  if not f._maxH then f._maxH = f:GetHeight() end
  UI.AnchorTop(f)
  local rowH = list.rowHeight or 18
  local chrome = (f:GetHeight() or 0) - (list:GetHeight() or 0)
  local want = chrome + (n > 1 and n or 1) * rowH + 2
  if want > f._maxH then want = f._maxH end
  if math.abs((f:GetHeight() or 0) - want) >= 1 then f:SetHeight(want) end
end

--- Hold a window by its top-left, so a change of height moves only its
--- bottom edge. Done once until the window is next moved or resized.
function UI.AnchorTop(f)
  if f._topAnchored or f._moving or f._sizing then return end
  local left, top = f:GetLeft(), f:GetTop()
  local ptop = UIParent and UIParent:GetTop()
  if left and top and ptop then
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top - ptop)
    f._topAnchored = true
  end
end

--- Back to the height the window was sized to, fitting switched off.
function UI.UnfitHeight(f)
  if not f or not f._maxH or f._moving or f._sizing then return end
  f:SetHeight(f._maxH)
  f._maxH = nil
end

----------------------------------------------------------------------
-- settings controls
----------------------------------------------------------------------

--[[ A checkbox. get()/set(v) rather than a stored value, so the control is
     always showing the live setting -- no separate copy to fall out of sync
     when something else changes the same option. ]]
function UI.Check(parent, label, get, set, tip)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(18)

  local box, tick
  if UI.skin == "blizzard" then
    -- The stock checkbox, as every Blizzard options panel draws it.
    box = CreateFrame("Frame", nil, b)
    box:SetWidth(20) box:SetHeight(20)
    box:SetPoint("LEFT", b, "LEFT", -3, 0)
    local up = box:CreateTexture(nil, "ARTWORK")
    up:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    up:SetAllPoints(box)
    local hl = box:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
    hl:SetBlendMode("ADD")
    hl:SetAllPoints(box)
    hl:SetAlpha(0)
    tick = box:CreateTexture(nil, "OVERLAY")
    tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    tick:SetAllPoints(box)
    box.SetBorderColor = function(self, c)
      hl:SetAlpha((c == W.color.accent) and 1 or 0)
    end
  else
    box = UI.Panel(b, W.color.bg, W.color.border, nil, "none")
    box:SetWidth(13)
    box:SetHeight(13)
    box:SetPoint("LEFT", b, "LEFT", 0, 0)
    if UI.skin == "pfui" then
      box.bg:SetVertexColor(0, 0, 0, 0.75)
      box:SetBorderColor({ 0.18, 0.18, 0.18 })
    end
    tick = box:CreateTexture(nil, "OVERLAY")
    tick:SetTexture(UI.media.white)
    tick:SetVertexColor(unpackColor(W.color.accent))
    tick:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
    tick:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)
  end

  local text = UI.Text(b, 11, (UI.skin == "blizzard") and BLIZZ_GOLD or W.color.text)
  text:SetPoint("LEFT", box, "RIGHT", (UI.skin == "blizzard") and 3 or 7, 0)
  text:SetText(label or "")

  -- Exposed so a test can assert on what is DRAWN rather than on the state
  -- behind it: the two disagreeing is the whole failure mode here, the same
  -- reason Stepper exposes its minus and plus.
  b.tick = tick

  b.Refresh = function(self)
    if get() then tick:Show() else tick:Hide() end
  end

  b:SetScript("OnClick", function()
    W.Guard("setting: " .. tostring(label), function()
      set(not get())
      b:Refresh()
    end)
  end)
  b:SetScript("OnEnter", function()
    box:SetBorderColor(W.color.accent)
    if tip and GameTooltip then
      GameTooltip:SetOwner(b, "ANCHOR_TOPLEFT")
      GameTooltip:AddLine(label or "")
      for _, l in ipairs(tip) do GameTooltip:AddLine(l, 0.72, 0.75, 0.8) end
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function()
    box:SetBorderColor((UI.skin == "pfui") and { 0.18, 0.18, 0.18 } or W.color.border)
    if GameTooltip then GameTooltip:Hide() end
  end)

  b:Refresh()
  return b
end

--[[ A dragged bar: label, track, value.

     For settings you want to FEEL rather than name a number for. Opacity is
     the case that earned it -- nobody knows they want 45%, they want to drag
     until the boss is visible through the meter, and a stepper makes that
     sixteen clicks.

     Built on the client's own Slider frame rather than a texture and mouse
     maths, so dragging, clicking the track and the step quantisation are the
     same as every other slider in the game.

     Live-updating on purpose: `set` fires as the thumb moves, so the thing
     being adjusted changes under the cursor. That is the entire point of
     reaching for a bar instead of a number. ]]
function UI.Slider(parent, label, get, set, min, max, step, format)
  step = step or 1
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(30)
  f.label = label

  local text = UI.Text(f, 11, W.color.text)
  text:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  text:SetText(label or "")

  local value = UI.Text(f, 11, W.color.accent, "RIGHT")
  value:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)

  local slider = CreateFrame("Slider", nil, f)
  slider:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  slider:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  slider:SetHeight(12)
  slider:SetOrientation("HORIZONTAL")
  slider:SetMinMaxValues(min, max)
  slider:SetValueStep(step)

  -- The groove the thumb runs in.
  local groove = UI.Fill(slider, W.color.bg)
  groove:ClearAllPoints()
  groove:SetPoint("LEFT", slider, "LEFT", 0, 0)
  groove:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
  groove:SetHeight(4)

  local filled = slider:CreateTexture(nil, "BORDER")
  filled:SetTexture(UI.media.white)
  filled:SetVertexColor(unpackColor(W.color.accent, 0.55))
  filled:SetPoint("LEFT", groove, "LEFT", 0, 0)
  filled:SetHeight(4)

  local thumb = slider:CreateTexture(nil, "OVERLAY")
  thumb:SetTexture(UI.media.white)
  thumb:SetVertexColor(unpackColor(W.color.accent))
  thumb:SetWidth(6)
  thumb:SetHeight(12)
  slider:SetThumbTexture(thumb)

  --[[ Guards re-entry. SetValue fires OnValueChanged, so refreshing the
       control from the setting would call set() again -- and set() is what
       triggered the refresh. Harmless for opacity, not for anything that
       writes to disk. ]]
  local applying = false

  local function paintFill(v)
    local span = max - min
    local frac = (span > 0) and ((v - min) / span) or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local w = (slider:GetWidth() or 0) * frac
    if w < 1 then w = 1 end
    filled:SetWidth(w)
  end

  local function show()
    local v = get()
    applying = true
    slider:SetValue(v)
    applying = false
    value:SetText(format and format(v) or tostring(v))
    paintFill(v)
  end

  slider:SetScript("OnValueChanged", function()
    if applying then return end
    W.Guard("setting: " .. tostring(label), function()
      local v = slider:GetValue()
      set(v)
      value:SetText(format and format(v) or tostring(v))
      paintFill(v)
    end)
  end)

  -- Exposed so a test can drive the bar without synthesising mouse drags.
  f.slider = slider
  f.Refresh = show
  show()
  return f
end

--[[ A numeric stepper: - value + .

     Used where the exact number matters and dragging to it would be fiddly
     at 1.12's frame sizes -- row height, how many rows, how many days. Where
     the feel matters more than the figure, UI.Slider is the better control. ]]
function UI.Stepper(parent, label, get, set, min, max, step, format)
  step = step or 1
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(18)

  local text = UI.Text(f, 11, W.color.text)
  text:SetPoint("LEFT", f, "LEFT", 0, 0)
  text:SetText(label or "")

  local value = UI.Text(f, 11, W.color.accent, "RIGHT")
  value:SetWidth(58)
  value:SetPoint("RIGHT", f, "RIGHT", -46, 0)

  local function show()
    local v = get()
    value:SetText(format and format(v) or tostring(v))
  end

  local function nudge(dir)
    W.Guard("setting: " .. tostring(label), function()
      local v = get() + dir * step
      -- Clamp rather than wrap: wrapping from the maximum back to the
      -- minimum on a stray click is a nasty surprise on a size control.
      if v < min then v = min elseif v > max then v = max end
      set(v)
      show()
    end)
  end

  local minus = UI.Button(f, "-", 20, 16, function() nudge(-1) end)
  minus:SetPoint("RIGHT", f, "RIGHT", -22, 0)
  local plus = UI.Button(f, "+", 20, 16, function() nudge(1) end)
  plus:SetPoint("RIGHT", f, "RIGHT", 0, 0)

  -- Exposed so the audit can drive them; the stepper is otherwise opaque.
  f.minus, f.plus = minus, plus
  f.Refresh = show
  show()
  return f
end

--- Section heading inside the settings window.
function UI.Heading(parent, label)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(20)
  local t = UI.Text(f, 11, W.color.accent)
  t:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 4)
  t:SetText(string.upper(label or ""))
  local rule = UI.Line(f, W.color.border)
  rule:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  rule:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  return f
end

--[[ A cycling choice: label on the left, current value on the right, click
     to advance. Deliberately not a dropdown -- these are two-to-four-option
     settings where a menu is more clicks than the thing it replaces. ]]
function UI.Choice(parent, label, options, get, set, tip)
  local f = CreateFrame("Button", nil, parent)
  f:SetHeight(18)

  local text = UI.Text(f, 11, W.color.text)
  text:SetPoint("LEFT", f, "LEFT", 0, 0)
  text:SetText(label or "")

  local value = UI.Text(f, 11, W.color.accent, "RIGHT")
  value:SetPoint("RIGHT", f, "RIGHT", 0, 0)
  -- Exposed for the same reason UI.Check exposes its tick: so a test can
  -- assert on what is DRAWN, not only on the setting behind it.
  f.valueText = value
  f.labelText = label

  local function labelFor(v)
    for _, o in ipairs(options) do
      if o.value == v then return o.label end
    end
    return tostring(v)
  end

  f.Refresh = function() value:SetText(labelFor(get())) end

  f:SetScript("OnClick", function()
    W.Guard("setting: " .. tostring(label), function()
      local current = get()
      local idx = 1
      for i, o in ipairs(options) do
        if o.value == current then idx = i break end
      end
      idx = idx + 1
      if idx > table.getn(options) then idx = 1 end
      set(options[idx].value)
      f.Refresh()
    end)
  end)

  f:SetScript("OnEnter", function()
    value:SetTextColor(unpackColor(W.color.accentHi))
    if tip and GameTooltip then
      GameTooltip:SetOwner(f, "ANCHOR_TOPLEFT")
      GameTooltip:AddLine(label or "")
      for _, l in ipairs(tip) do GameTooltip:AddLine(l, 0.72, 0.75, 0.8) end
      GameTooltip:Show()
    end
  end)
  f:SetScript("OnLeave", function()
    value:SetTextColor(unpackColor(W.color.accent))
    if GameTooltip then GameTooltip:Hide() end
  end)

  f.Refresh()
  return f
end

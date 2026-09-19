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
-- primitives
----------------------------------------------------------------------

--- Flat colour fill. Every surface in the addon is one of these.
function UI.Fill(parent, color, alpha, layer)
  local t = parent:CreateTexture(nil, layer or "BACKGROUND")
  t:SetTexture(UI.media.white)
  t:SetVertexColor(unpackColor(color, alpha))
  t:SetAllPoints(parent)
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
function UI.Panel(parent, color, borderColor, name)
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
    for _, e in ipairs(self.edges) do e:SetVertexColor(unpackColor(c, a)) end
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
function UI.RegisterFont(obj, size, face)
  table.insert(UI.fontObjects, { obj = obj, size = size, face = face })
  return obj
end

local function applyFont(entry, scale)
  local px = entry.size * scale
  -- The client refuses absurd sizes outright and leaves the string blank.
  if px < 6 then px = 6 elseif px > 32 then px = 32 end
  entry.obj:SetFont(entry.face, px)
end

function UI.ApplyFontScale()
  local scale = UI.FontScale()
  for _, entry in ipairs(UI.fontObjects) do
    applyFont(entry, scale)
  end
end

function UI.Text(parent, size, color, justify, face)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  size = size or 12
  face = face or UI.font
  applyFont({ obj = fs, size = size, face = face }, UI.FontScale())
  UI.RegisterFont(fs, size, face)
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

  b:SetActive(false)
  return b
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

local function ensureMenu()
  if menuFrame then return menuFrame end

  menuCatcher = CreateFrame("Button", "WrekkitMenuCatcher", UIParent)
  menuCatcher:SetAllPoints(UIParent)
  menuCatcher:SetFrameStrata("FULLSCREEN")
  menuCatcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  menuCatcher:SetScript("OnClick", function() UI.CloseMenu() end)
  menuCatcher:Hide()

  menuFrame = UI.Panel(UIParent, W.color.panel, W.color.borderHi)
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

  local b = CreateFrame("Button", nil, menuFrame)
  b:SetHeight(ROW_H)
  b:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", MENU_PAD,
    -(MENU_PAD + (index - 1) * ROW_H))
  b:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -MENU_PAD,
    -(MENU_PAD + (index - 1) * ROW_H))

  b.hl = UI.Fill(b, W.color.accent, 0, "BACKGROUND")
  b.label = UI.Text(b, 11, W.color.text)
  b.label:SetPoint("LEFT", b, "LEFT", 16, 0)

  b.tick = b:CreateTexture(nil, "OVERLAY")
  b.tick:SetTexture(UI.media.white)
  b.tick:SetVertexColor(unpackColor(W.color.accent))
  b.tick:SetWidth(3) b.tick:SetHeight(ROW_H - 8)
  b.tick:SetPoint("LEFT", b, "LEFT", 5, 0)

  b:SetScript("OnEnter", function()
    if not b._disabled then
      b.hl:SetVertexColor(unpackColor(W.color.accent, 0.16))
    end
  end)
  b:SetScript("OnLeave", function()
    b.hl:SetVertexColor(unpackColor(W.color.accent, 0))
  end)

  menuRows[index] = b
  return b
end

--- items: array of { text, value, checked, disabled }
--- onPick(value, item) fires on selection.
function UI.Menu(parent, anchorTo, items, onPick, width)
  local f = ensureMenu()
  UI.CloseMenu()

  local n = table.getn(items)
  f:SetWidth(width or 150)
  f:SetHeight(n * ROW_H + MENU_PAD * 2)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -2)

  for i = 1, n do
    local item = items[i]
    local b = menuRow(i)
    b._disabled = item.disabled
    b.label:SetText(item.text)
    b.label:SetTextColor(unpackColor(item.disabled and W.color.textFaint or W.color.text))
    if item.checked then b.tick:Show() else b.tick:Hide() end
    b.hl:SetVertexColor(unpackColor(W.color.accent, 0))

    if item.disabled then
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
  UI.RegisterFont(eb, 11, UI.font)
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

function UI.Row(parent, height)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(height or 18)

  r.bg = UI.Fill(r, W.color.panelHi, 0)

  r.bar = r:CreateTexture(nil, "BORDER")
  r.bar:SetTexture(UI.media.bar)
  r.bar:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
  r.bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)

  r.rank = UI.Text(r, 10, W.color.textFaint, "RIGHT")
  r.rank:SetPoint("LEFT", r, "LEFT", 0, 0)
  r.rank:SetWidth(20)

  r.name = UI.Text(r, 11, W.color.text, "LEFT")
  r.name:SetPoint("LEFT", r, "LEFT", 26, 0)

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

    local w = self:GetWidth()
    if not w or w <= 0 then w = 200 end
    local barW = w * (frac or 0)
    if barW < 1 then barW = 1 end
    self.bar:SetWidth(barW)
    self.bar:SetVertexColor(color[1], color[2], color[3], 0.55)

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
    local nameW = w - 26 - subW - valueW - 14
    if nameW < MIN_NAME_W then nameW = MIN_NAME_W end
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

  local track = UI.Panel(list, W.color.bg, W.color.bg)
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
    for i = table.getn(self.rows) + 1, n do
      self.rows[i] = self.makeRow(self, self.rowHeight)
    end
    -- Re-anchor every row each pass: the scrollbar appearing or vanishing
    -- changes the right inset, and the row height is a live setting.
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
  local f = UI.Panel(UIParent, W.color.bg, W.color.border, name)
  f:SetWidth(width) f:SetHeight(height)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
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
  bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
  UI.Fill(bar, W.color.panel)

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
  local cx = UI.Text(close, 13, W.color.textDim, "CENTER")
  cx:SetPoint("CENTER", close, "CENTER", 0, 0)
  cx:SetText("x")
  close:SetScript("OnEnter", function() cx:SetTextColor(unpackColor(W.color.accent)) end)
  close:SetScript("OnLeave", function() cx:SetTextColor(unpackColor(W.color.textDim)) end)
  close:SetScript("OnClick", function() f:Hide() end)
  f.closeButton = close

  -- resize grip: three stacked diagonal pips in the corner
  local grip = CreateFrame("Button", nil, f)
  grip:SetWidth(14) grip:SetHeight(14)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  for i = 1, 3 do
    local p = grip:CreateTexture(nil, "OVERLAY")
    p:SetTexture(UI.media.white)
    p:SetVertexColor(unpackColor(W.color.borderHi))
    p:SetWidth(2 + (3 - i) * 3) p:SetHeight(1)
    p:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -1, i * 3 - 2)
  end
  grip:RegisterForDrag("LeftButton")
  grip:SetScript("OnDragStart", function() f:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    if f.SavePosition then f:SavePosition() end
    if f.OnResize then f:OnResize() end
  end)
  f.grip = grip

  -- body
  local body = CreateFrame("Frame", nil, f)
  body:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -1)
  body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
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
  f._resizeKey = "resize:" .. tostring(name or f)
  f:SetScript("OnSizeChanged", function()
    if not f.OnResize then return end
    W.After(0, function()
      if f.OnResize then f:OnResize() end
    end, f._resizeKey)
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
    store.h = self:GetHeight()
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

----------------------------------------------------------------------
-- settings controls
----------------------------------------------------------------------

--[[ A checkbox. get()/set(v) rather than a stored value, so the control is
     always showing the live setting -- no separate copy to fall out of sync
     when something else changes the same option. ]]
function UI.Check(parent, label, get, set, tip)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(18)

  local box = UI.Panel(b, W.color.bg, W.color.border)
  box:SetWidth(13)
  box:SetHeight(13)
  box:SetPoint("LEFT", b, "LEFT", 0, 0)

  local tick = box:CreateTexture(nil, "OVERLAY")
  tick:SetTexture(UI.media.white)
  tick:SetVertexColor(unpackColor(W.color.accent))
  tick:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
  tick:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)

  local text = UI.Text(b, 11, W.color.text)
  text:SetPoint("LEFT", box, "RIGHT", 7, 0)
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
    box:SetBorderColor(W.color.border)
    if GameTooltip then GameTooltip:Hide() end
  end)

  b:Refresh()
  return b
end

--[[ A numeric stepper: - value + .

     Deliberately not a slider. Every one of these settings is a small,
     meaningful integer (row height, how many rows, how many days) where the
     exact number matters and dragging to it is fiddly at 1.12's frame sizes. ]]
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

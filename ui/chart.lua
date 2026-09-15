--[[ Wrekkit :: ui/chart

The timeline panel -- the site's RollingAverages chart, rebuilt out of the
only drawing primitive 1.12 gives an addon: a rectangle.

There is no canvas, no line API, and no texture rotation in this client, so
a "line" here is a column of 1px caps and the area beneath it is a second
column stretched to the same height. Columns are pooled and reused, so
repainting is assignment into existing textures rather than allocation.

Resolution is fixed at COLUMNS samples regardless of how long the fight was;
a 30-minute night and a 40-second pull both downsample onto the same pool,
which keeps the texture count constant and bounded.
]]

local W = Wrekkit
local UI = W.ui

local COLUMNS = 150      -- horizontal resolution of the plot
local PAD_L = 38         -- room for y-axis labels
local PAD_B = 16         -- room for x-axis labels
local PAD_T = 8
local PAD_R = 6

-- Draw order matters: filled areas first, then the brighter caps on top.
local SERIES = {
  { key = "dd", label = "Damage Done", color = W.color.damage, fill = true },
  { key = "dt", label = "Damage Taken", color = W.color.taken },
  { key = "eh", label = "Healing", color = W.color.healing },
}

----------------------------------------------------------------------

function UI.Chart(parent)
  local c = CreateFrame("Frame", nil, parent)
  c.columns = {}
  c.gridLines = {}
  c.yLabels = {}
  c.xLabels = {}
  c.markers = {}
  c.enabled = { dd = true, dt = true, eh = true }

  local plot = CreateFrame("Frame", nil, c)
  plot:SetPoint("TOPLEFT", c, "TOPLEFT", PAD_L, -PAD_T)
  plot:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -PAD_R, PAD_B)
  c.plot = plot

  -- horizontal grid
  for i = 1, 5 do
    local line = UI.Line(plot, W.color.border, 0.5)
    line:SetPoint("LEFT", plot, "LEFT", 0, 0)
    line:SetPoint("RIGHT", plot, "RIGHT", 0, 0)
    c.gridLines[i] = line

    local lbl = UI.Text(c, 9, W.color.textFaint, "RIGHT")
    lbl:SetWidth(PAD_L - 6)
    c.yLabels[i] = lbl
  end

  for i = 1, 7 do
    c.xLabels[i] = UI.Text(c, 9, W.color.textFaint, "CENTER")
  end

  ------------------------------------------------------------------
  -- column pool
  ------------------------------------------------------------------

  --- One column per series per x-position: a stretched area fill and a cap
  --- that reads as the line itself.
  local function column(seriesIndex, i)
    local pool = c.columns[seriesIndex]
    if not pool then pool = {} c.columns[seriesIndex] = pool end
    local col = pool[i]
    if col then return col end

    local def = SERIES[seriesIndex]
    col = {}

    if def.fill then
      col.area = plot:CreateTexture(nil, "BACKGROUND")
      col.area:SetTexture(UI.media.area)
      col.area:SetVertexColor(def.color[1], def.color[2], def.color[3], 0.5)
    end

    col.cap = plot:CreateTexture(nil, "ARTWORK")
    col.cap:SetTexture(UI.media.white)
    col.cap:SetVertexColor(def.color[1], def.color[2], def.color[3], 0.95)
    col.cap:SetHeight(2)

    pool[i] = col
    return col
  end

  local function hideFrom(seriesIndex, from)
    local pool = c.columns[seriesIndex]
    if not pool then return end
    for i = from, table.getn(pool) do
      local col = pool[i]
      if col then
        col.cap:Hide()
        if col.area then col.area:Hide() end
      end
    end
  end

  ------------------------------------------------------------------
  -- painting
  ------------------------------------------------------------------

  --- series: { dd = {}, dt = {}, eh = {}, hl = {} } indexed from 1
  --- n: sample count; peak: max value across series; deaths: { {t=...} }
  function c:SetSeries(series, n, peak, deaths)
    local w = plot:GetWidth() or 0
    local h = plot:GetHeight() or 0
    if w <= 0 or h <= 0 then return end

    if not series or n < 2 or peak <= 0 then
      for si = 1, table.getn(SERIES) do hideFrom(si, 1) end
      for i = 1, 5 do self.yLabels[i]:SetText("") end
      for i = 1, 7 do self.xLabels[i]:SetText("") end
      for _, m in ipairs(self.markers) do m:Hide() end
      if self.empty then self.empty:Show() end
      return
    end
    if self.empty then self.empty:Hide() end

    -- Round the axis top to something legible rather than the raw peak.
    local top = peak
    local mag = 1
    while top / mag >= 10 do mag = mag * 10 end
    top = math.ceil(top / mag * 2) / 2 * mag

    local colW = w / COLUMNS
    if colW < 1 then colW = 1 end

    for si, def in ipairs(SERIES) do
      local data = series[def.key]
      if not data or not self.enabled[def.key] then
        hideFrom(si, 1)
      else
        for i = 1, COLUMNS do
          -- Downsample: each column takes the max of the samples it spans,
          -- so a one-second spike survives being squeezed into 150 columns.
          local lo = math.floor((i - 1) / COLUMNS * n) + 1
          local hi = math.floor(i / COLUMNS * n)
          if hi < lo then hi = lo end

          local v = 0
          for k = lo, hi do
            local s = data[k]
            if s and s > v then v = s end
          end

          local col = column(si, i)
          local frac = v / top
          if frac > 1 then frac = 1 end
          local barH = frac * h
          local x = (i - 1) * colW

          if barH < 1 then
            col.cap:Hide()
            if col.area then col.area:Hide() end
          else
            col.cap:ClearAllPoints()
            col.cap:SetWidth(colW + 0.5)
            col.cap:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, barH)
            col.cap:Show()

            if col.area then
              col.area:ClearAllPoints()
              col.area:SetWidth(colW + 0.5)
              col.area:SetHeight(barH)
              col.area:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, 0)
              col.area:Show()
            end
          end
        end
        hideFrom(si, COLUMNS + 1)
      end
    end

    -- axes
    for i = 1, 5 do
      local frac = (i - 1) / 4
      local y = frac * h
      self.gridLines[i]:ClearAllPoints()
      self.gridLines[i]:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, y)
      self.gridLines[i]:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, y)
      self.yLabels[i]:ClearAllPoints()
      self.yLabels[i]:SetPoint("RIGHT", plot, "BOTTOMLEFT", -4, y)
      self.yLabels[i]:SetText(W.Short(top * frac))
    end

    for i = 1, 7 do
      local frac = (i - 1) / 6
      self.xLabels[i]:ClearAllPoints()
      self.xLabels[i]:SetPoint("TOP", plot, "BOTTOMLEFT", frac * w, -3)
      self.xLabels[i]:SetText(W.Clock(frac * n))
    end

    -- death markers
    for _, m in ipairs(self.markers) do m:Hide() end
    for i, d in ipairs(deaths or {}) do
      local m = self.markers[i]
      if not m then
        m = plot:CreateTexture(nil, "OVERLAY")
        m:SetTexture(UI.media.white)
        m:SetWidth(1)
        m:SetVertexColor(W.color.death[1], W.color.death[2], W.color.death[3], 0.55)
        self.markers[i] = m
      end
      local x = (d.t / n) * w
      if x >= 0 and x <= w then
        m:ClearAllPoints()
        m:SetPoint("BOTTOM", plot, "BOTTOMLEFT", x, 0)
        m:SetHeight(h)
        m:Show()
      end
    end
  end

  function c:Toggle(key)
    self.enabled[key] = not self.enabled[key]
  end

  ------------------------------------------------------------------
  -- legend
  ------------------------------------------------------------------

  local legend = CreateFrame("Frame", nil, c)
  legend:SetHeight(12)
  legend:SetPoint("TOPRIGHT", c, "TOPRIGHT", -PAD_R, -2)
  legend:SetWidth(280)
  c.legend = legend

  local xoff = 0
  c.legendButtons = {}
  for si, def in ipairs(SERIES) do
    local b = CreateFrame("Button", nil, legend)
    b:SetHeight(12)
    b:SetWidth(string.len(def.label) * 5 + 16)
    b:SetPoint("RIGHT", legend, "RIGHT", -xoff, 0)

    local swatch = b:CreateTexture(nil, "ARTWORK")
    swatch:SetTexture(UI.media.white)
    swatch:SetVertexColor(def.color[1], def.color[2], def.color[3], 1)
    swatch:SetWidth(7) swatch:SetHeight(7)
    swatch:SetPoint("LEFT", b, "LEFT", 0, 0)

    local txt = UI.Text(b, 9, W.color.textDim)
    txt:SetPoint("LEFT", swatch, "RIGHT", 4, 0)
    txt:SetText(def.label)

    b:SetScript("OnClick", function()
      c:Toggle(def.key)
      local on = c.enabled[def.key]
      swatch:SetAlpha(on and 1 or 0.25)
      txt:SetTextColor(on and W.color.textDim[1] or W.color.textFaint[1],
        on and W.color.textDim[2] or W.color.textFaint[2],
        on and W.color.textDim[3] or W.color.textFaint[3])
      if c.onToggle then c.onToggle() end
    end)

    xoff = xoff + b:GetWidth() + 10
    c.legendButtons[si] = b
  end

  c.empty = UI.Text(c, 11, W.color.textFaint, "CENTER")
  c.empty:SetPoint("CENTER", plot, "CENTER", 0, 0)
  c.empty:SetText("No timeline for this selection")
  c.empty:Hide()

  return c
end

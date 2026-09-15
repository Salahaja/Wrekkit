--[[ Wrekkit :: minimap

A draggable button on the minimap ring. No LibDBIcon -- it is one button and
a bit of trigonometry, and pulling in an embed library for that costs more
than it saves.
]]

local W = Wrekkit
W.minimap = {}
local MB = W.minimap

local RADIUS = 80   -- minimap ring radius in pixels

function MB:Create()
  if self.button then return self.button end

  local b = CreateFrame("Button", "WrekkitMinimapButton", Minimap)
  self.button = b
  b:SetWidth(31) b:SetHeight(31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetMovable(true)

  -- The icon sits inside the standard tracking-border ring so it matches
  -- every other minimap button rather than floating loose.
  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture(W.ui.media.emblem)
  icon:SetWidth(19) icon:SetHeight(19)
  icon:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.icon = icon

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetWidth(53) border:SetHeight(53)
  border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

  b:SetScript("OnClick", function()
    if arg1 == "RightButton" then
      W.ui.report:Toggle()
    else
      W.ui.meter:Toggle()
    end
  end)

  b:SetScript("OnEnter", function()
    GameTooltip:SetOwner(b, "ANCHOR_LEFT")
    GameTooltip:AddLine("Wrekkit")
    GameTooltip:AddLine("Left-click: live meter", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: full report", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move this button", 0.55, 0.55, 0.55)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Dragging follows the cursor around the ring by angle.
  b:SetScript("OnDragStart", function()
    b.dragging = true
    b:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = UIParent:GetEffectiveScale()
      cx, cy = cx / scale, cy / scale
      local angle = math.deg(math.atan2(cy - my, cx - mx))
      W.db.minimap.angle = angle
      MB:Position()
    end)
  end)
  b:SetScript("OnDragStop", function()
    b.dragging = false
    b:SetScript("OnUpdate", nil)
  end)

  self:Position()
  return b
end

function MB:Position()
  local b = self.button
  if not b then return end
  local angle = math.rad(W.db.minimap.angle or 214)
  b:ClearAllPoints()
  b:SetPoint("CENTER", Minimap, "CENTER",
    math.cos(angle) * RADIUS, math.sin(angle) * RADIUS)
end

function MB:Update()
  local b = self:Create()
  if W.db.minimap.show then b:Show() else b:Hide() end
  self:Position()
end

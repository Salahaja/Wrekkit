--[[ Wrekkit :: ui/peers

The log browser. Two panes: who is sharing on the left, what they have on
the right. Tick the logs you want and pull them.

Nothing is fetched until it is asked for. Discovery gets a name and a count;
clicking a name asks that one person for their index; ticking rows and
pressing Sync asks for those specific logs. That keeps a raid-wide browse to
one broadcast and a handful of whispers, instead of everyone pushing their
whole night at everyone else.

Pulling FROM someone requires that they have sharing switched on. Browsing
does not require you to have it on -- you can look without being listed,
which is the polite default for a feature that broadcasts your name.
]]

local W = Wrekkit
local UI = W.ui
UI.peers = {}
local P = UI.peers

local SIDEBAR = 150
local HEADER_H = 40

P.selected = nil     -- peer name being inspected
P.picked = {}        -- key -> true, the logs ticked for pulling

----------------------------------------------------------------------

function P:Create()
  if self.frame then return self.frame end
  if not W.db.peerWindow then
    W.db.peerWindow = { point = "CENTER", x = 0, y = -40, w = 560, h = 380 }
  end

  --[[ The report is also HIGH. Two frames on the same strata fall back to
       frame level for draw order, which is creation order here, so the
       browser opened from the report was drawn UNDER it. DIALOG puts it
       above, the way settings already sits above both. ]]
  local f = UI.Window("WrekkitPeers", W.db.peerWindow.w, W.db.peerWindow.h,
    "Shared Logs", { minW = 440, minH = 260, strata = "DIALOG" })
  self.frame = f
  UI.BindGeometry(f, W.db.peerWindow)
  UI.CloseOnEscape("WrekkitPeers")

  ------------------------------------------------------------------
  -- header
  ------------------------------------------------------------------

  local header = CreateFrame("Frame", nil, f.body)
  header:SetHeight(HEADER_H)
  header:SetPoint("TOPLEFT", f.body, "TOPLEFT", 0, 0)
  header:SetPoint("TOPRIGHT", f.body, "TOPRIGHT", 0, 0)
  UI.Fill(header, W.color.panel, 0.35)

  self.status = UI.Text(header, 11, W.color.textDim)
  self.status:SetPoint("LEFT", header, "LEFT", 12, 0)

  local lookBtn = UI.Button(header, "Look for players", 106, 20, function()
    W.Guard("peer discover", function() P:Discover() end)
  end)
  lookBtn:SetPoint("RIGHT", header, "RIGHT", -10, 0)
  self.lookBtn = lookBtn

  -- Your own visibility, right where it matters.
  local shareBtn = UI.Button(header, "Sharing", 72, 20, function()
    W.db.shareEnabled = not W.db.shareEnabled
    if W.ui.settings then W.ui.settings:Refresh() end
    P:Refresh()
    W.Print("log sharing " .. (W.db.shareEnabled and "on." or "off."))
  end)
  shareBtn:SetPoint("RIGHT", lookBtn, "LEFT", -6, 0)
  self.shareBtn = shareBtn

  ------------------------------------------------------------------
  -- peer list
  ------------------------------------------------------------------

  local side = CreateFrame("Frame", nil, f.body)
  side:SetWidth(SIDEBAR)
  side:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -1)
  side:SetPoint("BOTTOMLEFT", f.body, "BOTTOMLEFT", 0, 0)
  UI.Fill(side, W.color.panel, 0.5)
  local edge = side:CreateTexture(nil, "BORDER")
  edge:SetTexture(UI.media.white)
  edge:SetVertexColor(W.color.border[1], W.color.border[2], W.color.border[3], 1)
  edge:SetWidth(1)
  edge:SetPoint("TOPRIGHT", side, "TOPRIGHT", 0, 0)
  edge:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", 0, 0)

  local peerList = UI.ScrollList(side, 26, function(parent, height)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(height)
    row.bg = UI.Fill(row, W.color.accent, 0)
    row.tick = row:CreateTexture(nil, "ARTWORK")
    row.tick:SetTexture(UI.media.white)
    row.tick:SetWidth(2)
    row.tick:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    row.tick:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
    row.name = UI.Text(row, 11, W.color.text)
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -3)
    row.meta = UI.Text(row, 9, W.color.textFaint)
    row.meta:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 3)
    row.hl = UI.Fill(row, W.color.text, 0, "OVERLAY")
    row:SetScript("OnEnter", function() row.hl:SetVertexColor(1, 1, 1, 0.05) end)
    row:SetScript("OnLeave", function() row.hl:SetVertexColor(1, 1, 1, 0) end)
    return row
  end)
  peerList:SetPoint("TOPLEFT", side, "TOPLEFT", 4, -4)
  peerList:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", -4, 4)
  self.peerList = peerList

  ------------------------------------------------------------------
  -- their logs
  ------------------------------------------------------------------

  local right = CreateFrame("Frame", nil, f.body)
  right:SetPoint("TOPLEFT", side, "TOPRIGHT", 1, 0)
  right:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", 0, 0)

  self.whose = UI.Text(right, 12, W.color.text)
  self.whose:SetPoint("TOPLEFT", right, "TOPLEFT", 10, -8)

  local footer = CreateFrame("Frame", nil, right)
  footer:SetHeight(26)
  footer:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 0, 0)
  footer:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)

  local syncBtn = UI.Button(footer, "Sync selected", 96, 20, function()
    W.Guard("peer sync", function() P:SyncSelected() end)
  end)
  syncBtn:SetPoint("RIGHT", footer, "RIGHT", -10, 0)
  syncBtn:SetActive(true)
  self.syncBtn = syncBtn

  local allBtn = UI.Button(footer, "All / none", 70, 20, function()
    W.Guard("peer select all", function() P:ToggleAll() end)
  end)
  allBtn:SetPoint("RIGHT", syncBtn, "LEFT", -6, 0)

  self.pickCount = UI.Text(footer, 10, W.color.textDim)
  self.pickCount:SetPoint("LEFT", footer, "LEFT", 10, 0)

  local logList = UI.ScrollList(right, 24, function(parent, height)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(height)
    row.bg = UI.Fill(row, W.color.accent, 0)

    row.box = UI.Panel(row, W.color.bg, W.color.border)
    row.box:SetWidth(12)
    row.box:SetHeight(12)
    row.box:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.check = row.box:CreateTexture(nil, "OVERLAY")
    row.check:SetTexture(UI.media.white)
    row.check:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 1)
    row.check:SetPoint("TOPLEFT", row.box, "TOPLEFT", 3, -3)
    row.check:SetPoint("BOTTOMRIGHT", row.box, "BOTTOMRIGHT", -3, 3)

    row.name = UI.Text(row, 11, W.color.text)
    row.name:SetPoint("LEFT", row.box, "RIGHT", 8, 0)
    row.meta = UI.Text(row, 10, W.color.textDim, "RIGHT")
    row.meta:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.have = UI.Text(row, 9, W.color.textFaint, "RIGHT")
    row.have:SetPoint("RIGHT", row.meta, "LEFT", -8, 0)

    row.hl = UI.Fill(row, W.color.text, 0, "OVERLAY")
    row:SetScript("OnEnter", function() row.hl:SetVertexColor(1, 1, 1, 0.05) end)
    row:SetScript("OnLeave", function() row.hl:SetVertexColor(1, 1, 1, 0) end)
    return row
  end)
  logList:SetPoint("TOPLEFT", right, "TOPLEFT", 6, -26)
  logList:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -6, 28)
  self.logList = logList

  self.empty = UI.Text(right, 11, W.color.textFaint, "CENTER")
  self.empty:SetPoint("CENTER", right, "CENTER", 0, 0)

  return f
end

----------------------------------------------------------------------
-- actions
----------------------------------------------------------------------

function P:Discover()
  self.selected = nil
  self.picked = {}
  if W.sync:Discover() then
    self.status:SetText("looking...")
    -- Answers arrive over the next second or two; repaint when they land
    -- and once more after, so a quiet channel still stops saying "looking".
    W.After(3, function() P:Refresh() end, "peerLook")
  end
  self:Refresh()
end

function P:Select(name)
  self.selected = name
  self.picked = {}
  local peer = W.sync.peers[name]
  if peer and not peer.index then
    W.sync:RequestIndex(name)
    W.After(4, function() P:Refresh() end, "peerIndex")
  end
  self:Refresh()
end

--- Do we already hold this log from this person?
function P:AlreadyHave(name, entry)
  for _, e in ipairs(W.db.encounters or {}) do
    if e.sharedBy == name and e.name == entry.name
        and math.floor(e.duration or 0) == math.floor(entry.duration or 0) then
      return true
    end
  end
  return false
end

function P:ToggleAll()
  local peer = self.selected and W.sync.peers[self.selected]
  if not peer or not peer.index then return end

  local anyPicked = false
  for _ in pairs(self.picked) do anyPicked = true break end

  self.picked = {}
  if not anyPicked then
    for _, entry in ipairs(peer.index) do self.picked[entry.key] = true end
  end
  self:Refresh()
end

function P:SyncSelected()
  if not self.selected then
    W.Print("pick someone first.")
    return
  end
  local keys = {}
  for key in pairs(self.picked) do table.insert(keys, key) end
  if table.getn(keys) == 0 then
    W.Print("tick the logs you want first.")
    return
  end

  W.sync:RequestLogs(self.selected, keys)
  W.Print("asked " .. self.selected .. " for " .. table.getn(keys) ..
    " log" .. (table.getn(keys) == 1 and "" or "s") .. ".")
  -- They arrive as transfers; repaint once they have had time to land.
  W.After(5, function() P:Refresh() end, "peerPull")
end

----------------------------------------------------------------------
-- painting
----------------------------------------------------------------------

function P:Refresh()
  W.Guard("peer browser", function() P:RefreshInner() end)
end

function P:RefreshInner()
  local f = self.frame
  if not f or not f:IsShown() then return end

  ------------------------------------------------------------------
  -- your own visibility
  ------------------------------------------------------------------
  local on = (W.db.shareEnabled == true)
  self.shareBtn:SetActive(on)
  self.shareBtn.label:SetText(on and "Sharing: on" or "Sharing: off")

  local chan = W.sync:ActiveChannel()
  if on then
    self.status:SetText(chan
      and ("others can see you on " .. string.lower(chan))
      or "sharing is on, but you are not in a raid, party or guild")
  else
    self.status:SetText("you are not listed - others cannot pull your logs")
  end

  ------------------------------------------------------------------
  -- peers
  ------------------------------------------------------------------
  local peers = W.sync:PeerList()
  self.peerList:SetData(peers, function(row, peer)
    row.name:SetText(peer.name or "?")
    row.meta:SetText((peer.logs or 0) .. " log" ..
      ((peer.logs == 1) and "" or "s"))

    local chosen = (self.selected == peer.name)
    if chosen then
      row.bg:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 0.10)
      row.tick:SetVertexColor(W.color.accent[1], W.color.accent[2], W.color.accent[3], 1)
      row.name:SetTextColor(W.color.text[1], W.color.text[2], W.color.text[3], 1)
    else
      row.bg:SetVertexColor(0, 0, 0, 0)
      row.tick:SetVertexColor(0, 0, 0, 0)
      row.name:SetTextColor(W.color.textDim[1], W.color.textDim[2], W.color.textDim[3], 1)
    end

    row:SetScript("OnClick", function()
      W.Guard("peer click", function() P:Select(peer.name) end)
    end)
  end)

  ------------------------------------------------------------------
  -- their logs
  ------------------------------------------------------------------
  local peer = self.selected and W.sync.peers[self.selected]

  if table.getn(peers) == 0 then
    self.whose:SetText("")
    self.empty:SetText("Nobody found yet.\nPress \"Look for players\".")
    self.empty:Show()
    self.logList:SetData({}, function() end)
    self.pickCount:SetText("")
    return
  end

  if not peer then
    self.whose:SetText("")
    self.empty:SetText("Pick someone on the left.")
    self.empty:Show()
    self.logList:SetData({}, function() end)
    self.pickCount:SetText("")
    return
  end

  self.whose:SetText(peer.name .. "'s logs")

  if not peer.index then
    self.empty:SetText("Asking " .. peer.name .. " for their log list...")
    self.empty:Show()
    self.logList:SetData({}, function() end)
    self.pickCount:SetText("")
    return
  end

  if table.getn(peer.index) == 0 then
    self.empty:SetText(peer.name .. " has no logs to share.")
    self.empty:Show()
    self.logList:SetData({}, function() end)
    self.pickCount:SetText("")
    return
  end

  self.empty:Hide()

  local picked = 0
  for _ in pairs(self.picked) do picked = picked + 1 end
  self.pickCount:SetText(picked .. " of " .. table.getn(peer.index) .. " selected")

  self.logList:SetData(peer.index, function(row, entry)
    row.name:SetText((entry.name or "?") .. (entry.kill and "  (kill)" or ""))
    row.meta:SetText(W.Duration(entry.combat or 0) .. "   " ..
      W.Short(entry.damage or 0))

    local have = self:AlreadyHave(peer.name, entry)
    row.have:SetText(have and "have" or "")

    if self.picked[entry.key] then row.check:Show() else row.check:Hide() end
    row.bg:SetVertexColor(0, 0, 0, self.picked[entry.key] and 0.08 or 0)

    row:SetScript("OnClick", function()
      W.Guard("peer log click", function()
        if P.picked[entry.key] then
          P.picked[entry.key] = nil
        else
          P.picked[entry.key] = true
        end
        P:Refresh()
      end)
    end)
  end)
end

----------------------------------------------------------------------

function P:Toggle()
  local f = self:Create()
  if f:IsShown() then
    f:Hide()
  else
    f:Show()
    if f.Raise then f:Raise() end
    -- Look as soon as it opens: an empty browser you have to prompt is a
    -- browser people assume is broken.
    self:Discover()
  end
end

function P:Show()
  local f = self:Create()
  f:Show()
  -- Strata decides which window wins; Raise decides it among equals.
  if f.Raise then f:Raise() end
  self:Refresh()
end

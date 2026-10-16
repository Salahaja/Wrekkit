--[[ Wrekkit :: ahscan

"Scan consumes": look up every consumable that matters at the auction house
and note the lowest buyout for each, for the Consumes (gold) prices.

The 1.12 client only answers auction queries while the auction house window
is open, so this is a button on it (and /wrek scan) rather than something that
runs in the background. It never starts by itself: a scan fights any search
of your own for the same query slot, so it runs when asked.

What it scans: every consumable used in your recorded pulls, plus the items
other prices are derived from (the Small Dream Shard behind the tea and
Dreamtonic) -- a few dozen items, not the whole table. With no pulls recorded
yet it falls back to every consumable it knows.

Each item is searched by name, every page read (up to MAX_PAGES), and only
listings that are that exact item counted, per unit (buyout / stack size).
An item with no listings keeps the price it had: out of stock is not free.
Results go to W.prices (newest sighting wins) and, at the end, to the guild.
]]

local W = Wrekkit
W.ahscan = {}
local A = W.ahscan

local MAX_PAGES = 5         -- 250 listings of one consumable is plenty
local QUERY_TIMEOUT = 8     -- seconds before an unanswered query is skipped
local TICK = 0.2

A.queue, A.running = {}, false

--- itemId -> name for everything in the consumables table.
local function tableNames()
  local names = {}
  for _, entry in pairs(W.consumesDB or {}) do
    for i = 1, table.getn(entry), 2 do names[entry[i]] = entry[i + 1] end
  end
  return names
end

--- The items to scan, as { id, name } -- see the top of the file.
function A:Targets()
  local names = tableNames()
  local want = {}
  for _, enc in ipairs((W.db and W.db.encounters) or {}) do
    for _, a in pairs(enc.actors or {}) do
      W.report.eachAbility(a.consumeItem, function(id) want[tonumber(id) or 0] = true end)
    end
  end
  -- The source of a derived price, by name: it is not a consumable, so the
  -- table does not know it and the client may not have it cached.
  for _, d in pairs(W.prices.DERIVED) do
    want[d.from] = true
    if d.fromName then names[d.from] = names[d.from] or d.fromName end
  end
  -- Derived items are priced from their source, never searched themselves.
  for id in pairs(W.prices.DERIVED) do want[id] = nil end

  local any = false
  for id in pairs(want) do if id > 0 then any = true break end end
  if not any then
    for id in pairs(names) do want[id] = true end
  end

  local out = {}
  for id in pairs(want) do
    local name = names[id] or (GetItemInfo and GetItemInfo(id))
    -- Conjured food and water are never on the auction house.
    if id > 0 and name and not string.find(name, "^Conjured") then
      table.insert(out, { id = id, name = name })
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function A:Start()
  if self.running then return end
  if not (AuctionFrame and AuctionFrame:IsVisible()) and not self.ahOpen then
    W.Print("open the auction house first -- the client only answers there.")
    return
  end
  self.queue = self:Targets()
  self.total = table.getn(self.queue)
  self.done, self.priced = 0, 0
  self.running = true
  self:Next()
  self:Paint()
  W.Print("scanning " .. self.total .. " consumables at the auction house...")
  local function tick()
    if not A.running then return end
    W.Guard("auction scan", function() A:Tick() end)
    W.After(TICK, tick, "ahscanTick")
  end
  tick()
end

function A:Stop(why)
  if not self.running then return end
  self.running = false
  self.cur = nil
  W.Cancel("ahscanTick")
  self:Paint()
  W.Print("consumables scan: " .. self.priced .. " of " .. self.done .. " priced" ..
    (why and (" (" .. why .. ")") or "") .. ".")
  if self.priced > 0 and W.prices then
    local n = W.prices:Share()
    if n > 0 then W.Print("shared " .. n .. " prices with your guild's Wrekkit.") end
  end
end

--- Move on to the next item, or finish.
function A:Next()
  self.cur = table.remove(self.queue, 1)
  if not self.cur then
    self:Stop()
    return
  end
  self.cur.page, self.cur.best, self.sent, self.got = 0, nil, nil, false
end

function A:Tick()
  local cur = self.cur
  if not cur then return end
  if self.sent then
    if self.got then
      self:Read()
    elseif GetTime() - self.sent > QUERY_TIMEOUT then
      self:Finish()
    end
    return
  end
  if CanSendAuctionQuery and CanSendAuctionQuery() then
    self.got = false
    self.sent = GetTime()
    QueryAuctionItems(cur.name, "", "", nil, nil, nil, cur.page, nil, nil)
  end
end

--- One page of results: the cheapest unit price of exactly this item.
function A:Read()
  local cur = self.cur
  local shown, total = GetNumAuctionItems("list")
  for i = 1, shown or 0 do
    local link = GetAuctionItemLink and GetAuctionItemLink("list", i)
    local _, _, id = string.find(link or "", "item:(%d+)")
    if tonumber(id) == cur.id then
      local _, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
      count, buyout = tonumber(count) or 1, tonumber(buyout) or 0
      if buyout > 0 and count > 0 then
        local each = buyout / count
        if not cur.best or each < cur.best then cur.best = each end
      end
    end
  end
  self.sent = nil
  if (cur.page + 1) * 50 < (total or 0) and cur.page + 1 < MAX_PAGES then
    cur.page = cur.page + 1
  else
    self:Finish()
  end
end

function A:Finish()
  local cur = self.cur
  self.done = self.done + 1
  if cur and cur.best and W.prices then
    W.prices:Record(cur.id, math.floor(cur.best + 0.5), time and time() or 0, UnitName("player"))
    self.priced = self.priced + 1
  end
  self.sent = nil
  self:Next()
  self:Paint()
end

----------------------------------------------------------------------
-- the button
----------------------------------------------------------------------

--- On whichever auction window is up: aux's, or the stock one.
function A:Place()
  local b = self.button
  if not b then return end
  b:ClearAllPoints()
  local aux = getglobal and getglobal("aux_frame")
  if aux and aux:IsVisible() then
    b:SetPoint("BOTTOMRIGHT", aux, "TOPRIGHT", 0, 2)
  elseif AuctionFrame and AuctionFrame:IsVisible() then
    b:SetPoint("TOPRIGHT", AuctionFrame, "TOPRIGHT", -40, -14)
  else
    b:SetPoint("TOP", UIParent, "TOP", 0, -80)
  end
end

function A:Paint()
  local b = self.button
  if not b then return end
  if self.running then
    b.label:SetText(string.format("Scanning %.0f/%.0f", self.done or 0, self.total or 0))
  else
    b.label:SetText("Scan consumes")
  end
end

function A:Button()
  if self.button or not CreateFrame then return self.button end
  local b = W.ui.Button(UIParent, "Scan consumes", 120, 20, function()
    if A.running then A:Stop("stopped") else A:Start() end
  end)
  b:SetFrameStrata("DIALOG")
  -- The button's own hover look, then the tooltip.
  local hoverIn, hoverOut = b:GetScript("OnEnter"), b:GetScript("OnLeave")
  b:SetScript("OnEnter", function()
    if hoverIn then hoverIn() end
    if not GameTooltip then return end
    GameTooltip:SetOwner(b, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Scan consumes")
    GameTooltip:AddLine("Look up the consumables your raid uses and", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("note the lowest price of each, for Consumes", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("(gold). Shared with your guild's Wrekkit.", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("Click again to stop.", 0.55, 0.58, 0.64)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function()
    if hoverOut then hoverOut() end
    if GameTooltip then GameTooltip:Hide() end
  end)
  b:Hide()
  self.button = b
  return b
end

function A:StartEvents()
  if self.frame or not CreateFrame then return end
  local f = CreateFrame("Frame", "WrekkitAHScanFrame")
  self.frame = f
  f:RegisterEvent("AUCTION_HOUSE_SHOW")
  f:RegisterEvent("AUCTION_HOUSE_CLOSED")
  f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
  f:SetScript("OnEvent", function()
    if event == "AUCTION_ITEM_LIST_UPDATE" then
      if A.running and A.sent then A.got = true end
    elseif event == "AUCTION_HOUSE_SHOW" then
      A.ahOpen = true
      W.Guard("auction scan button", function()
        local b = A:Button()
        A:Paint()
        b:Show()
        -- aux replaces the stock window a moment after the event.
        W.After(0.3, function() A:Place() end, "ahscanPlace")
        A:Place()
      end)
    else
      A.ahOpen = false
      A:Stop("auction house closed")
      if A.button then A.button:Hide() end
    end
  end)
end

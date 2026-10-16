--[[ Wrekkit :: ahscan

"Scan consumes": look up every consumable that matters at the auction house
and note the lowest buyout for each, for the Consumes (gold) prices.

The 1.12 client only answers auction queries while the auction house window
is open, so this is a button on it (and /wrek scan) rather than something that
runs in the background. It never starts by itself: a scan fights any search
of your own for the same query slot, so it runs when asked.

What it scans: every consumable it knows (W.consumesDB), plus the items other
prices are derived from (the Small Dream Shard behind the tea and
Dreamtonic) -- on any character, raided or not, so a bank alt standing at
the auction house can price the lot. Conjured food and water are skipped;
they are never listed. With AuctionQueryThrottle.dll in the client a search
is answered in about a second, so the ~380 items take a few minutes.

It never spins silently. The auction house stops answering when its session
ends -- the window closed, or the stock AuctionFrame hidden, which closes the
server session while QueryAuctionItems goes on accepting calls and doing
nothing -- so a search the client will not let go out for GATE_GIVE_UP, or
TIMEOUTS_GIVE_UP searches in a row with no answer, end the scan with a
reason. /wrek scan status says where a running scan is.

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
local GATE_GIVE_UP = 20     -- seconds the client may refuse to send before we stop
local TIMEOUTS_GIVE_UP = 3  -- unanswered searches in a row before we stop
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
  for id in pairs(names) do want[id] = true end
  -- The source of a derived price, by name: it is not a consumable, so the
  -- table does not know it and the client may not have it cached.
  for _, d in pairs(W.prices.DERIVED) do
    want[d.from] = true
    if d.fromName then names[d.from] = names[d.from] or d.fromName end
  end
  -- Derived items are priced from their source, never searched themselves.
  for id in pairs(W.prices.DERIVED) do want[id] = nil end

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
  self.timeouts, self.gateSince = 0, nil
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
  local now = GetTime()
  if self.sent then
    if self.got then
      self.timeouts = 0
      self:Read()
    elseif now - self.sent > QUERY_TIMEOUT then
      -- No answer. Once is a dropped packet; several in a row is an auction
      -- house that has stopped listening (its session ended).
      self.timeouts = (self.timeouts or 0) + 1
      if self.timeouts >= TIMEOUTS_GIVE_UP then
        self:Stop("the auction house stopped answering -- close and reopen it, then scan again")
        return
      end
      self:Finish()
    end
    return
  end
  if CanSendAuctionQuery and CanSendAuctionQuery() then
    self.gateSince = nil
    self.got = false
    self.sent = now
    self.lastQuery = cur.name .. " p" .. cur.page
    QueryAuctionItems(cur.name, "", "", nil, nil, nil, cur.page, nil, nil)
  else
    -- The client is holding the search back. Normal for a moment between
    -- searches; for long, it will not let one go at all.
    self.gateSince = self.gateSince or now
    if now - self.gateSince > GATE_GIVE_UP then
      self:Stop("the auction house would not take a search for " .. GATE_GIVE_UP ..
        "s -- close and reopen it, then scan again")
    end
  end
end

--- /wrek scan status: where a scan is, and what the client says.
function A:Status()
  local can = CanSendAuctionQuery and CanSendAuctionQuery()
  local aux = getglobal and getglobal("aux_frame")
  W.Print("auction scan: " .. (self.running and "running" or "not running") ..
    (self.running and string.format(" -- %.0f of %.0f done, %.0f priced", self.done or 0,
      self.total or 0, self.priced or 0) or ""))
  if self.cur then
    W.Print("  on: " .. self.cur.name .. " (page " .. self.cur.page .. ")" ..
      (self.sent and string.format(", searched %.1fs ago, answer %s", GetTime() - self.sent,
        self.got and "in" or "not yet") or ", waiting to search"))
  end
  W.Print("  client allows a search now: " .. (can and "yes" or "no") ..
    (self.gateSince and string.format(" (held back %.0fs)", GetTime() - self.gateSince) or ""))
  W.Print("  auction house open: " .. (self.ahOpen and "yes" or "no") ..
    "; stock window " .. ((AuctionFrame and AuctionFrame:IsVisible()) and "shown" or "hidden") ..
    "; aux " .. ((aux and aux:IsVisible()) and "shown" or "hidden"))
  if self.lastQuery then W.Print("  last search: " .. self.lastQuery) end
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

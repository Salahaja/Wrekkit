--[[ Wrekkit :: ahscan

"Scan consumes": the lowest buyout of every consumable on the auction house,
for the Consumes (gold) prices -- and aux's own scans taken in as well.

The 1.12 client only answers auction queries while the auction house window
is open, so this is a button on it (and /wrek scan), never something running
in the background, and it only starts when asked.

HOW IT SCANS -- the way aux does, by pages, not item by item. Searching ~380
consumables one name at a time made the server search the whole auction
house 380 times (aux pages through all of it in that time), and wasted
searches on things that are never listed: healthstones, mana gems, conjured
food. So:
  1. the Consumable category, page by page (50 listings a page), noting the
     cheapest unit buyout of every consumable it meets;
  2. then a name search for the few that are filed elsewhere -- weapon oils,
     stones, explosives, runes and dummies (Trade Goods), jujus and holy
     water (Quest) -- see ELSEWHERE.
Each answer is read the moment it lands and the next search sent at once
(AuctionQueryThrottle.dll opens the client's gate before the answer is
announced), so a scan runs at the server's pace.

AUX'S SCANS. When the auction house closes, today's lowest buyout aux holds
for every consumable is taken as a sighting of ours (W.prices:ImportAux) and
shared with the guild -- so a full aux scan prices everything by itself.

NEVER IN AUX'S WAY. Answers to anybody else's search are not ours: if one
lands mid-scan (aux scanning, you browsing), the scan stops and says so
rather than reading their page and firing a search into the middle of
theirs -- which is how the first version broke aux's full scan. Nor does it
spin silently: a search the client will not send for GATE_GIVE_UP, or
TIMEOUTS_GIVE_UP in a row unanswered (the AH session ended), stop it with a
reason. /wrek scan status says where it is.
]]

local W = Wrekkit
W.ahscan = {}
local A = W.ahscan

local CLASS_PAGES = 1000    -- a ceiling, not a target: the category is a few hundred
local NAME_PAGES = 5        -- 250 listings of one item is plenty
local QUERY_TIMEOUT = 8     -- seconds before an unanswered query is skipped
local GATE_GIVE_UP = 20     -- seconds the client may refuse to send before we stop
local TIMEOUTS_GIVE_UP = 3  -- unanswered searches in a row before we stop
local ECHO = 1.5            -- a repeat of our own page's update (owner names
                            -- arriving) within this is not someone else's
local TICK = 0.2

-- Consumables the auction house files outside the Consumable category.
local ELSEWHERE = { "Oil$", "Sharpening Stone", "Weightstone", "Sapper", "Grenade",
  "Dynamite", "Bomb", "Seaforium", "Explosive Sheep", " Rune$", "Target Dummy",
  "^Juju ", "Holy Water" }

A.queue, A.running = {}, false

--- itemId -> name: everything worth pricing -- every consumable in the table
--- and the sources of derived prices (the Small Dream Shard), but not the
--- derived items themselves nor conjured food and water.
function A:Wanted()
  local want = {}
  for _, entry in pairs(W.consumesDB or {}) do
    for i = 1, table.getn(entry), 2 do want[entry[i]] = entry[i + 1] end
  end
  for _, d in pairs(W.prices.DERIVED) do want[d.from] = want[d.from] or d.fromName end
  for id in pairs(W.prices.DERIVED) do want[id] = nil end
  for id, name in pairs(want) do
    if not name or string.find(name, "^Conjured") then want[id] = nil end
  end
  return want
end

--- The Consumable category's index, from the client's own list.
function A:ConsumableClass()
  if not GetAuctionItemClasses then return nil end
  local classes = { GetAuctionItemClasses() }
  for i, name in ipairs(classes) do
    if name == "Consumable" then return i end
  end
  return nil
end

--- The searches a scan makes, in order.
function A:Jobs(want)
  local jobs = {}
  local class = self:ConsumableClass()
  if class then table.insert(jobs, { kind = "class", class = class, page = 0 }) end
  local names = {}
  for id, name in pairs(want) do
    local elsewhere = not class
    for _, pat in ipairs(ELSEWHERE) do
      if string.find(name, pat) then elsewhere = true end
    end
    if elsewhere then table.insert(names, { kind = "name", id = id, name = name, page = 0 }) end
  end
  table.sort(names, function(a, b) return a.name < b.name end)
  for _, j in ipairs(names) do table.insert(jobs, j) end
  return jobs, table.getn(names)
end

function A:Start()
  if self.running then return end
  if not (AuctionFrame and AuctionFrame:IsVisible()) and not self.ahOpen then
    W.Print("open the auction house first -- the client only answers there.")
    return
  end
  self.want = self:Wanted()
  self.queue, self.nameTotal = self:Jobs(self.want)
  self.best, self.namesDone, self.pages = {}, 0, 0
  self.timeouts, self.gateSince, self.lastRead = 0, nil, nil
  self.running = true
  self:Next()
  self:Paint()
  W.Print("scanning the auction house for consumables...")
  local function tick()
    if not A.running then return end
    W.Guard("auction scan", function() A:Tick() end)
    W.After(TICK, tick, "ahscanTick")
  end
  tick()
end

--- End a scan: record what it found. `quiet` leaves the sharing to the
--- caller (closing the AH shares once, with aux's prices taken in too).
function A:Stop(why, quiet)
  if not self.running then return 0 end
  self.running = false
  self.cur = nil
  W.Cancel("ahscanTick")
  local me, now, priced = UnitName("player"), time and time() or 0, 0
  for id, copper in pairs(self.best or {}) do
    if W.prices:Record(id, math.floor(copper + 0.5), now, me) then priced = priced + 1 end
  end
  self.priced = priced
  self:Paint()
  W.Print(string.format("consumables scan: %.0f priced from %.0f pages", priced, self.pages or 0) ..
    (why and (" (" .. why .. ")") or "") .. ".")
  if priced > 0 and not quiet then
    local n = W.prices:Share()
    if n > 0 then W.Print("shared " .. n .. " prices with your guild's Wrekkit.") end
  end
  return priced
end

--- Move on to the next search, or finish.
function A:Next()
  self.cur = table.remove(self.queue, 1)
  self.sent, self.got = nil, false
  if not self.cur then self:Stop() end
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
      self:Done()
    end
    return
  end
  if CanSendAuctionQuery and CanSendAuctionQuery() then
    self.gateSince = nil
    self.got = false
    self.sent = now
    if cur.kind == "class" then
      self.lastQuery = "Consumable page " .. cur.page
      QueryAuctionItems("", "", "", nil, cur.class, nil, cur.page, nil, nil)
    else
      self.lastQuery = cur.name .. " p" .. cur.page
      QueryAuctionItems(cur.name, "", "", nil, nil, nil, cur.page, nil, nil)
    end
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

--- One page: the cheapest unit buyout of every wanted item on it.
function A:Read()
  local cur = self.cur
  local shown, total = GetNumAuctionItems("list")
  for i = 1, shown or 0 do
    local link = GetAuctionItemLink and GetAuctionItemLink("list", i)
    local _, _, id = string.find(link or "", "item:(%d+)")
    id = tonumber(id)
    if id and self.want[id] then
      local _, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
      count, buyout = tonumber(count) or 1, tonumber(buyout) or 0
      if buyout > 0 and count > 0 then
        local each = buyout / count
        if not self.best[id] or each < self.best[id] then self.best[id] = each end
      end
    end
  end
  self.sent = nil
  self.lastRead = GetTime()
  self.pages = self.pages + 1
  cur.total = total or 0
  local cap = (cur.kind == "class") and CLASS_PAGES or NAME_PAGES
  if (cur.page + 1) * 50 < cur.total and cur.page + 1 < cap then
    cur.page = cur.page + 1
    self:Paint()
  else
    self:Done()
  end
end

function A:Done()
  if self.cur and self.cur.kind == "name" then self.namesDone = self.namesDone + 1 end
  self.sent = nil
  self:Next()
  self:Paint()
end

--- /wrek scan status: where a scan is, and what the client says.
function A:Status()
  local can = CanSendAuctionQuery and CanSendAuctionQuery()
  local aux = getglobal and getglobal("aux_frame")
  W.Print("auction scan: " .. (self.running and "running" or "not running") ..
    (self.running and string.format(" -- %.0f pages read", self.pages or 0) or ""))
  if self.cur then
    local what = (self.cur.kind == "class") and "the Consumable category" or self.cur.name
    W.Print("  on: " .. what .. " (page " .. self.cur.page .. ")" ..
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
  local cur = self.cur
  if not self.running then
    b.label:SetText("Scan consumes")
  elseif cur and cur.kind == "class" then
    local pages = (cur.total and cur.total > 0) and math.ceil(cur.total / 50) or 0
    b.label:SetText(string.format("Page %.0f/%.0f", cur.page + 1, pages))
  else
    b.label:SetText(string.format("Others %.0f/%.0f", self.namesDone or 0, self.nameTotal or 0))
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
    GameTooltip:AddLine("Pages through the Consumable category, then", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("oils, stones, explosives and jujus, noting the", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("lowest price of each for Consumes (gold).", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("aux scans count too: today's aux prices are", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("taken in when you close the auction house.", 0.72, 0.75, 0.8)
    GameTooltip:AddLine("Shared with your guild's Wrekkit. Click again to stop.", 0.55, 0.58, 0.64)
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

--- The auction house closed: end any scan, take in aux's prices, share once.
function A:Closed()
  self.ahOpen = false
  local priced = self:Stop("auction house closed", true) or 0
  local imported = W.prices:ImportAux()
  if imported > 0 then
    W.Print(string.format("took in %.0f consumable prices from today's aux scans.", imported))
  end
  if priced + imported > 0 then
    local n = W.prices:Share()
    if n > 0 then W.Print("shared " .. n .. " prices with your guild's Wrekkit.") end
  end
  if self.button then self.button:Hide() end
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
      if not A.running then return end
      if A.sent then
        -- Ours: read it and send the next search in the same breath.
        A.got = true
        W.Guard("auction scan", function()
          A:Tick()                                         -- read this page
          if A.running and not A.sent then A:Tick() end    -- and ask for the next
        end)
      elseif not (A.lastRead and GetTime() - A.lastRead < ECHO) then
        -- Someone else's search (aux, or you browsing). Never read theirs nor
        -- search into the middle of it: stop, keeping what was found.
        W.Guard("auction scan", function()
          A:Stop("another search ran -- scan again once it is done")
        end)
      end
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
      W.Guard("auction house closed", function() A:Closed() end)
    end
  end)
end

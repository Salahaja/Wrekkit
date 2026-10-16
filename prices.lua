--[[ Wrekkit :: prices

What a consumable costs on the auction house, for the Consumes (gold)
metric.

The client knows no prices. aux does: every scan it runs, and every scan
another account shares through VendorTruth (merged into aux's own history at
login), goes into one history per item -- the day's lowest buyout, and one
data point per earlier day, newest first.

The price used is the LATEST seen: today's lowest buyout when the item was
scanned today, else the lowest from the most recent day it was scanned. Not
aux's "Value", which is a weighted median over every day it has kept and so
lags a market that has moved.

Read from aux's saved table, read-only -- never through aux's functions.
Those are not read-only: looking an item up rolls its day over and writes
the record back, and hands out aux's own recycled temporary tables. Called
from here every repaint, in the middle of an aux scan, they had aux's full
scan going wrong. The table is plain: aux.faction["Realm|Faction"].history
["id:0"] = "next_push#today's lowest#price@day;price@day;..." newest first.

Prices are cached for a minute: the meter repaints twice a second and a
raid's worth of players times their consumables is a lot of lookups for a
number that changes once a day. ]]

local W = Wrekkit
W.prices = {}
local P = W.prices

local CACHE = 60            -- seconds a looked-up price is kept
P.cache = {}                -- itemId -> { value = copper or false, at }

--- aux's price history for this character's market, or nil: its saved
--- variable `aux`, keyed the way aux keys it (Nordanaar's market is one).
function P:AuxHistory()
  local saved = aux
  if type(saved) ~= "table" or type(saved.faction) ~= "table" then return nil end
  local realm = (GetCVar and GetCVar("realmName")) or (GetRealmName and GetRealmName()) or ""
  local key = realm .. "|" .. ((UnitFactionGroup and UnitFactionGroup("player")) or "")
  if realm == "Nordanaar" then key = realm .. "|Horde" end
  local f = saved.faction[key]
  return f and type(f.history) == "table" and f.history or nil
end

--[[ Items priced from another item rather than from their own auctions:
     itemId -> { item it is valued by, how many of it one is worth }.
     What it costs to come by, whatever its own listings say:
       Nordanaar Herbal Tea   1/5 of a Small Dream Shard
       Dreamtonic             1 Small Dream Shard ]]
P.DERIVED = {
  [61675] = { from = 61198, fromName = "Small Dream Shard", share = 1 / 5 },   -- Nordanaar Herbal Tea
  [61423] = { from = 61198, fromName = "Small Dream Shard", share = 1 },       -- Dreamtonic
}

--[[ Wrekkit's own record of prices, beside aux's: what its consumables scan
     at the auction house found (AH Scan), and what guildmates' Wrekkits
     shared. W.db.prices[itemId] = { p = copper each, t = when seen (unix
     seconds), by = who saw it }. ]]
function P:Store()
  if not W.db then return {} end
  W.db.prices = W.db.prices or {}
  return W.db.prices
end

--- Note a price seen at time `t`. Kept only if newer than what is held, so
--- an old observation arriving late never replaces a fresh one.
function P:Record(itemId, copper, t, by)
  itemId, copper, t = tonumber(itemId), tonumber(copper), tonumber(t)
  if not itemId or not copper or copper <= 0 or not t then return false end
  local store = self:Store()
  local held = store[itemId]
  if held and held.t and held.t >= t then return false end
  store[itemId] = { p = copper, t = t, by = by }
  self.cache[itemId] = nil
  return true
end

--[[ aux's latest for an item: copper, when, and whether it is today's.
     A record is "next_push#lowest#price@day;..." -- `lowest` is the lowest
     buyout of the day that ends at next_push, not yet folded into the day
     list. So it is the newest sighting there is: today's while next_push
     is still ahead, an earlier day's (aux folds it in on its next look)
     once past. Otherwise the newest day in the list. A day is stamped by
     its start, so a scan of our own later that day wins over it. ]]
function P:AuxLatest(itemId)
  local history = self:AuxHistory()
  local rec = history and history[itemId .. ":0"]
  if type(rec) ~= "string" then return nil end
  local _, _, nextPush, lowest, points = string.find(rec, "^([^#]*)#([^#]*)#?(.*)$")
  nextPush, lowest = tonumber(nextPush), tonumber(lowest)
  local now = time and time() or 0
  if lowest and lowest > 0 and nextPush then
    return lowest, nextPush - 86400, nextPush > now
  end
  local _, _, value, day = string.find(points or "", "^(%d+)@(%d+)")
  value, day = tonumber(value), tonumber(day)
  if value and value > 0 then return value, (day or 0) - 86400, false end
  return nil
end

--[[ aux's scans, taken in: today's lowest buyout for every consumable aux
     has seen today, recorded as our own sighting so it is shared with the
     guild like one. Run when the auction house closes -- after an aux scan,
     that prices the lot with no scan of ours needed. ]]
function P:ImportAux()
  local history = self:AuxHistory()
  if not history then return 0 end
  local ids = {}
  for _, entry in pairs(W.consumesDB or {}) do
    for i = 1, table.getn(entry), 2 do ids[entry[i]] = true end
  end
  for _, d in pairs(self.DERIVED) do ids[d.from] = true end
  local me, now, n = UnitName("player"), time and time() or 0, 0
  for id in pairs(ids) do
    local value, _, today = self:AuxLatest(id)
    -- Only today's: an older day is aux's history, not a sighting of ours.
    if today and self:Record(id, value, now, me) then n = n + 1 end
  end
  return n
end

--- What one of an item costs, in copper, or nil when nothing knows. The
--- newest sighting wins: aux's, your own scan's, or a guildmate's.
function P:Value(itemId)
  itemId = tonumber(itemId)
  if not itemId or itemId <= 0 then return nil end
  local derived = self.DERIVED[itemId]
  if derived then
    local base = self:Value(derived.from)
    return base and base * derived.share or nil
  end
  local now = GetTime()
  local c = self.cache[itemId]
  if c and now - c.at < CACHE then return c.value or nil end

  local value, at = self:AuxLatest(itemId)
  local own = self:Store()[itemId]
  if own and own.p and (not value or (own.t or 0) > (at or 0)) then value = own.p end
  self.cache[itemId] = { value = value or false, at = now }
  return value
end

----------------------------------------------------------------------
-- sharing with the guild
----------------------------------------------------------------------

--[[ Prices you scanned yourself go to guildmates running Wrekkit, after a
     scan and once at login; theirs come back the same way. Only your OWN
     sightings are sent, never ones you were told -- so a price is passed on
     by the one person who saw it, and nobody re-broadcasts the guild's.

       Q~*~id:copper:time,id:copper:time,...

     W.db.priceShare (default on) switches both directions. Guild only:
     the auction house is the guild's market too, and that is where the
     people who would use these prices are. ]]
local SHARE_DAYS = 7
local PER_MSG = 160          -- payload characters per message

function P:Sharing()
  return W.db and W.db.priceShare ~= false
end

--- Send your own scanned prices from the last week to the guild.
function P:Share()
  if not self:Sharing() or not W.sync or not (IsInGuild and IsInGuild()) then return 0 end
  local me = UnitName("player")
  local since = (time and time() or 0) - SHARE_DAYS * 86400
  local parts, msg, sent = {}, "", 0
  for id, e in pairs(self:Store()) do
    if e.by == me and (e.t or 0) >= since then
      local entry = string.format("%.0f:%.0f:%.0f", id, e.p, e.t)
      if string.len(msg) + string.len(entry) + 1 > PER_MSG then
        table.insert(parts, msg)
        msg = ""
      end
      msg = (msg == "") and entry or (msg .. "," .. entry)
      sent = sent + 1
    end
  end
  if msg ~= "" then table.insert(parts, msg) end
  for _, body in ipairs(parts) do
    W.sync:Send("*", "Q~" .. body, "GUILD")
  end
  return sent
end

--- A guildmate's prices. Each kept only if newer than what is held.
function P:OnShared(payload, sender)
  if not self:Sharing() or type(payload) ~= "string" then return 0 end
  local taken = 0
  for id, copper, t in string.gfind(payload, "(%d+):(%d+):(%d+)") do
    if self:Record(id, copper, t, sender) then taken = taken + 1 end
  end
  return taken
end

--- Where prices come from, for a footer or /wrek status.
function P:Source()
  if self:AuxHistory() then return "aux" end
  return nil
end

--- "12g 30s", "45s 10c", "8c". Whole copper; nil and 0 read as "-".
function W.Money(copper)
  copper = math.floor((copper or 0) + 0.5)
  if copper <= 0 then return "-" end
  local g = math.floor(copper / 10000)
  local s = math.floor(math.mod(copper, 10000) / 100)
  local c = math.mod(copper, 100)
  if g >= 100 then return string.format("%.0fg", g) end
  if g > 0 then return string.format("%.0fg %.0fs", g, s) end
  if s > 0 then return string.format("%.0fs %.0fc", s, c) end
  return string.format("%.0fc", c)
end

--- A player's consumables, priced: total copper, and how many uses had no
--- price to go on.
function P:Cost(items)
  local total, unpriced = 0, 0
  -- Live tables are keyed by item id; saved ones are lists whose rows carry
  -- it. W.report.eachAbility reads both.
  W.report.eachAbility(items, function(id, row)
    local n = (type(row) == "table" and row.amount) or 0
    local each = self:Value(id)
    if each then total = total + each * n else unpriced = unpriced + n end
  end)
  return total, unpriced
end

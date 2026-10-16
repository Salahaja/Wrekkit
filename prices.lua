--[[ Wrekkit :: prices

What a consumable costs on the auction house, for the Consumes (gold)
metric.

The client knows no prices. aux does: every scan it runs, and every scan
another account shares through VendorTruth (merged into aux's own history at
login), goes into one history per item. This asks aux for its "Value" -- a
weighted median of the daily lowest buyouts, the figure its tooltips show --
and falls back to today's lowest buyout for an item seen only today.

Read through aux's own module, never its saved table: the format is aux's
business, and its value function already handles the daily roll-over. aux's
loader is a global `require`, so this checks aux is actually loaded first --
another addon could define a `require` of its own.

Prices are cached for a minute: the meter repaints twice a second and a
raid's worth of players times their consumables is a lot of lookups for a
number that changes once a day. ]]

local W = Wrekkit
W.prices = {}
local P = W.prices

local CACHE = 60            -- seconds a looked-up price is kept
P.cache = {}                -- itemId -> { value = copper or false, at }

--- aux's history module, or nil when aux is not there to ask.
function P:Aux()
  if self.aux ~= nil then return self.aux or nil end
  if not (IsAddOnLoaded and IsAddOnLoaded("aux-addon")) or type(require) ~= "function" then
    return nil   -- not cached: aux may be loaded on demand later
  end
  local ok, history = pcall(require, "aux.core.history")
  if ok and history and type(history.value) == "function" then
    self.aux = history
  else
    self.aux = false
  end
  return self.aux or nil
end

--[[ Items priced from another item rather than from their own auctions:
     itemId -> { item it is valued by, how many of it one is worth }.
       Nordanaar Herbal Tea   1/5 of a Small Dream Shard -- what it costs
                              to come by, whatever its own listings say. ]]
P.DERIVED = {
  [61675] = { from = 61198, share = 1 / 5 },
}

--- What one of an item costs, in copper, or nil when nothing knows.
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

  local value
  local history = self:Aux()
  if history then
    -- aux keys items by "id:suffix"; consumables have no suffix.
    local key = itemId .. ":0"
    local ok, v = pcall(history.value, key)
    if ok and type(v) == "number" and v > 0 then value = v end
    if not value and type(history.market_value) == "function" then
      ok, v = pcall(history.market_value, key)
      if ok and type(v) == "number" and v > 0 then value = v end
    end
  end
  self.cache[itemId] = { value = value or false, at = now }
  return value
end

--- Where prices come from, for a footer or /wrek status.
function P:Source()
  if self:Aux() then return "aux" end
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

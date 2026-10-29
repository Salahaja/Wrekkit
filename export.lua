--[[ Wrekkit :: export

Saving what is on screen -- and the consumables an officer wants to see --
as a plain text file to post to Discord.

The client cannot write files, but Nampower can: WriteCustomFile puts them
under CustomData\ in the client folder, where the raid history already goes
(store.lua). The same text also opens in a box to copy from (ui/export.lua)
-- the way out without Nampower, and the quick one for a short post, since
Discord turns a paste past 2000 characters into a file of its own.

Two texts:
  X:Shown(ctx)     what a window shows, worded as its announcement is
                   (A:Lines, from the same context) but the whole list,
                   not a chat-sized top 15
  X:Consumes(ctx)  each player: what they used, how many, what it cost at
                   your prices, and their deaths -- players who used
                   nothing included, which is half the point for an
                   officer; then each consumable and who used it; then the
                   raid's total
]]

local W = Wrekkit
W.export = {}
local X = W.export

local SHOWN_LINES = 40       -- the whole list, within reason
local NAME_W = 32            -- item column, in characters

--- The pulls the context covers, for a heading: "12 pulls, 1h 05m in
--- combat, 25/10/26".
local function coverage(ctx, view)
  local encs = ctx.encounters or {}
  local n = table.getn(encs)
  local first = encs[1] and encs[1].startTime
  local when = first and date("%d/%m/%y", first) or "?"
  return string.format("%d pull%s, %s in combat, %s", n, n == 1 and "" or "s",
    W.Duration(view.combat or 0), when)
end

local function viewOf(ctx)
  return W.report:View(ctx.encounters or {}, { petMode = ctx.petMode or "merge" })
end

--- The window's view as text, a line per row.
function X:Shown(ctx)
  local lines = W.announce:Lines(ctx, SHOWN_LINES, SHOWN_LINES)
  local out = {}
  for _, l in ipairs(lines) do table.insert(out, l) end
  table.insert(out, "")
  table.insert(out, "Exported " .. date("%d/%m/%y %H:%M") .. " by Wrekkit")
  return table.concat(out, "\n"), lines[1]
end

local function pad(s, w)
  s = s or ""
  if string.len(s) >= w then return s end
  return s .. string.rep(" ", w - string.len(s))
end

local function lpad(s, w)
  s = s or ""
  if string.len(s) >= w then return s end
  return string.rep(" ", w - string.len(s)) .. s
end

--[[ One player's consumables, priced: { name, n, each, cost } rows sorted
     by what they cost, then how many; the total copper; uses with no
     price. Drink and Food (capture.lua's generic ids) have none. ]]
local function priced(row)
  local items, total, unpriced, uses = {}, 0, 0, 0
  W.report.eachAbility(row.consumeItem, function(id, r)
    local n = (type(r) == "table" and r.amount) or 0
    if n > 0 then
      local each = W.prices and W.prices:Value(id)
      local cost = each and each * n or nil
      if cost then total = total + cost else unpriced = unpriced + n end
      uses = uses + n
      table.insert(items, { id = id, name = r.name or ("Item " .. tostring(id)), n = n,
                            each = each, cost = cost })
    end
  end)
  table.sort(items, function(a, b)
    if (a.cost or 0) ~= (b.cost or 0) then return (a.cost or 0) > (b.cost or 0) end
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
  end)
  return items, total, unpriced, uses
end

--- The officer's list. Returns the text and its heading.
function X:Consumes(ctx)
  local view = viewOf(ctx)
  local players = W.report:Players(view, ctx.filter)
  local head = "Wrekkit consumables - " .. (ctx.label or "?") .. " (" .. coverage(ctx, view) .. ")"
  local out = { head, "Gold at your prices now (aux scans, guild shares); - = no price known.", "" }

  local rows = {}
  for _, p in ipairs(players) do
    local items, total, unpriced, uses = priced(p)
    table.insert(rows, { p = p, items = items, total = total, unpriced = unpriced, uses = uses })
  end
  table.sort(rows, function(a, b)
    if a.total ~= b.total then return a.total > b.total end
    if a.uses ~= b.uses then return a.uses > b.uses end
    return (a.p.name or "") < (b.p.name or "")
  end)

  local raidCost, raidUses, raidUnpriced = 0, 0, 0
  local byItem, itemOrder = {}, {}
  for _, r in ipairs(rows) do
    local p = r.p
    local deaths = p.deaths or 0
    table.insert(out, string.format("%s (%d death%s): %d use%s, %s", p.name or "?", deaths,
      deaths == 1 and "" or "s", r.uses, r.uses == 1 and "" or "s", W.Money(r.total)))
    if table.getn(r.items) == 0 then
      table.insert(out, "    nothing recorded")
    end
    for _, it in ipairs(r.items) do
      table.insert(out, "  " .. lpad(tostring(it.n), 4) .. "  " .. pad(it.name, NAME_W) ..
        lpad(it.cost and W.Money(it.cost) or "-", 10))
      local b = byItem[it.name]
      if not b then
        b = { name = it.name, n = 0, cost = 0, each = it.each, who = {} }
        byItem[it.name] = b
        table.insert(itemOrder, b)
      end
      b.n = b.n + it.n
      b.cost = b.cost + (it.cost or 0)
      table.insert(b.who, it.n > 1 and (p.name .. " x" .. it.n) or p.name)
    end
    table.insert(out, "")
    raidCost, raidUses, raidUnpriced = raidCost + r.total, raidUses + r.uses, raidUnpriced + r.unpriced
  end

  if table.getn(itemOrder) > 0 then
    table.sort(itemOrder, function(a, b)
      if a.cost ~= b.cost then return a.cost > b.cost end
      if a.n ~= b.n then return a.n > b.n end
      return a.name < b.name
    end)
    table.insert(out, "By consumable (count, each, total, who):")
    for _, b in ipairs(itemOrder) do
      table.insert(out, "  " .. lpad(tostring(b.n), 4) .. "  " .. pad(b.name, NAME_W) ..
        lpad(b.each and W.Money(b.each) or "-", 10) .. lpad(b.cost > 0 and W.Money(b.cost) or "-", 10) ..
        "  " .. table.concat(b.who, ", "))
    end
    table.insert(out, "")
  end

  table.insert(out, string.format("Raid: %d players, %d uses, %s spent%s", table.getn(rows), raidUses,
    W.Money(raidCost), raidUnpriced > 0 and string.format(" (%d use%s with no price)", raidUnpriced,
      raidUnpriced == 1 and "" or "s") or ""))
  table.insert(out, "Exported " .. date("%d/%m/%y %H:%M") .. " by Wrekkit")
  return table.concat(out, "\n"), head
end

--- A file name from what it holds and when: letters, digits and _ only.
function X:Filename(kind)
  local safe = string.gsub(kind or "Export", "[^%w]+", "_")
  safe = string.gsub(safe, "^_+", "")
  safe = string.gsub(safe, "_+$", "")
  if safe == "" then safe = "Export" end
  local stamp = string.gsub(date("%Y-%m-%d_%H%M") or "", "[^%w%-]", "_")
  return "Wrekkit_" .. safe .. "_" .. stamp .. ".txt"
end

--- Write the text under CustomData\. Returns the file name, or nil and why.
function X:Save(text, kind)
  if not WriteCustomFile then return nil, "Saving a file needs Nampower (WriteCustomFile)." end
  local name = self:Filename(kind)
  local ok, err = pcall(WriteCustomFile, name, text, "w")
  if not ok or err == false then
    return nil, "The client would not write CustomData\\" .. name .. "."
  end
  return name
end

--[[ What each export is called, for its file name: the view's heading
     without "Wrekkit" and its pull label -- "Damage_Done", "Deaths",
     "Raid_contribution" -- or "Consumes". ]]
local function kindOf(heading)
  local _, _, what = string.find(heading or "", "^Wrekkit%s+(.-) %- ")
  return what or "Export"
end

--[[ The menu's and /wrek export's way in. `which` is "shown" or "consumes";
     `how` is "file" (falling back to the copy box without Nampower) or
     "copy". ]]
function X:Run(ctx, which, how)
  if not ctx then return end
  local text, heading
  if which == "consumes" then
    text, heading = self:Consumes(ctx)
  else
    text, heading = self:Shown(ctx)
  end
  local kind = (which == "consumes") and "Consumes" or kindOf(heading)
  if how ~= "copy" then
    local name, why = self:Save(text, kind)
    if name then
      W.Print("saved to CustomData\\" .. name .. " in your client folder -- drag it into Discord.")
      return name
    end
    W.Print(why .. " Opening it to copy instead.")
  end
  if W.ui and W.ui.ExportBox then W.ui.ExportBox(text, heading) end
end

--[[ Build consumes_db.lua: which spell each consumable casts.

  lua tools/make_consumes.lua "<WoW>\WDB\itemcache.wdb" [more itemcache.wdb ...]

Other players' potions, flasks and food reach this client as a cast with NO
item behind it (SPELL_GO's itemId is only filled in for your own), so the
only way to know someone drank a Major Healing Potion is that they cast
17534, the spell it casts. This writes that spell -> item table from the
client's own item cache, which holds every item the client has ever been
told about and, per item, its class and its on-use spell.

Kept: class 0 (Consumable) and 7 (Trade Goods) items whose spell triggers on
use (0), plus a short hand list (EXTRA). Not kept:
weapon and armour procs, on-equip spells, the hearthstone -- which is what
the cast-with-an-item rule used to count. A spell more than one consumable
casts (Drink, Food) maps to all of them; the addon then names it by the
spell and leaves it unpriced unless your own use says which item it was.

Record layout (1.12 item query response, as the cache stores it): class,
subclass, four C-string names, then 65 uint32 of fixed fields, then five
spell blocks of {spellId, trigger, charges, cooldown, category, catCooldown}. ]]

local out_path = "consumes_db.lua"
local items = {}      -- itemId -> { name, spells = { spellId, ... } }

--[[ Item classes kept: 0 Consumable (potions, elixirs, flasks, food,
     bandages, scrolls) and 7 Trade Goods, which is where 1.12 files weapon
     oils, sharpening and weight stones, explosives (sappers, grenades,
     dynamite) and Dark/Demonic Runes. ]]
local CLASSES = { [0] = true, [7] = true }

--[[ Trade goods is broad, so from class 7 only: subclass 0 (parts: oils,
     stones, runes) and 2 (explosives), less what is not used up in a fight
     -- gear attachments and enchanting reagents -- and from subclass 3
     (devices, nearly all reusable gadgets: dragonlings, mortars, jumper
     cables) only the target dummies, which are. ]]
local NOT_CONSUMED = { "Belt Buckle", "Shield Spike", "Spurs", "Essence", "Counterweight",
                       "Weapon Chain", "Broken Blade", "Deviate Fish" }
local function keepTradeGood(sub, name)
  if sub == 3 then return string.find(name, "Target Dummy", 1, true) ~= nil end
  if sub ~= 0 and sub ~= 2 then return false end
  for _, word in ipairs(NOT_CONSUMED) do
    if string.find(name, word, 1, true) then return false end
  end
  return true
end

--[[ Consumables the item cache cannot supply: filed as quest items (class
     12) or with no use spell recorded (the jujus), or never seen by the
     client at all. Each spell id checked against Spell.dbc's name and seen
     cast by players in the Chronicle logs; the item ids are the items
     themselves (summarize_consumes prices jujus by their E'ko, not this). ]]
local EXTRA = {
  { 12450, "Juju Flurry", 16322 },
  { 12451, "Juju Power", 16323 },
  { 12455, "Juju Ember", 16326 },
  { 12457, "Juju Chill", 16325 },
  { 12458, "Juju Guile", 16327 },
  { 12459, "Juju Escape", 16321 },
  { 12460, "Juju Might", 16329 },
  { 13180, "Stratholme Holy Water", 17291 },
  { 13810, "Blessed Sunfruit", 18124 },
  { 13813, "Blessed Sunfruit Juice", 18140 },
  { 19183, "Hourglass Sand", 23645 },
  { 18284, "Kreeg's Stout Beatdown", 22790 },
  { 18269, "Gordok Green Grog", 22789 },
  { 21215, "Graccu's Mince Meat Fruitcake", 25990 },
  -- A second spell some uses of these report (same name in Spell.dbc, seen
  -- cast by players, never in the same second as the first -- so a
  -- different version of the item, not a double count).
  { 14530, "Heavy Runecloth Bandage", 18630 },
  { 13457, "Greater Fire Protection Potion", 17574 },
  { 13452, "Elixir of the Mongoose", 17571 },
  { 12404, "Dense Sharpening Stone", 16641 },
}

local function read_cache(path)
  local f = assert(io.open(path, "rb"))
  local b = f:read("a")
  f:close()
  assert(b:sub(1, 4) == "BDIW", path .. " is not an item cache")
  local pos = 21
  local n = 0
  while pos + 8 <= #b do
    local id, size = string.unpack("<I4I4", b, pos)
    pos = pos + 8
    if id == 0 and size == 0 then break end
    local rec = b:sub(pos, pos + size - 1)
    pos = pos + size
    if #rec > 8 then
      local class, sub = string.unpack("<I4I4", rec, 1)
      local p = 9
      local name
      for k = 1, 4 do
        local e = rec:find("\0", p, true)
        if not e then break end
        if k == 1 then name = rec:sub(p, e - 1) end
        p = e + 1
      end
      local spellsAt = p + 65 * 4
      if CLASSES[class] and name and spellsAt + 30 * 4 <= #rec + 1
         and (class ~= 7 or keepTradeGood(sub, name))
         and not string.find(name, "Belt Buckle", 1, true) then
        local spells = {}
        for s = 0, 4 do
          local spellId, trigger = string.unpack("<I4I4", rec, spellsAt + s * 24)
          if spellId > 0 and trigger == 0 then table.insert(spells, spellId) end
        end
        if #spells > 0 then
          items[id] = { name = name, spells = spells }
          n = n + 1
        end
      end
    end
  end
  return n
end

assert(arg[1], "usage: lua tools/make_consumes.lua <itemcache.wdb> [...]")
for i = 1, #arg do
  print(string.format("%s: %d consumables with a use spell", arg[i], read_cache(arg[i])))
end
local added = 0
for _, e in ipairs(EXTRA) do
  local it = items[e[1]]
  if not it then
    items[e[1]] = { name = e[2], spells = { e[3] } }
    added = added + 1
  else
    local has = false
    for _, s in ipairs(it.spells) do if s == e[3] then has = true end end
    if not has then
      table.insert(it.spells, e[3])
      added = added + 1
    end
  end
end
print(string.format("hand list: %d added", added))

-- spell -> items casting it
local bySpell = {}
for id, it in pairs(items) do
  for _, s in ipairs(it.spells) do
    bySpell[s] = bySpell[s] or {}
    table.insert(bySpell[s], id)
  end
end
local spells = {}
for s, list in pairs(bySpell) do
  table.sort(list)
  table.insert(spells, s)
end
table.sort(spells)

local function q(s) return string.format("%q", s) end
local lines = {
  "-- Generated by tools/make_consumes.lua from the client's item cache. Do not edit.",
  "-- spellId -> { itemId, \"Item name\" } for each consumable that casts it.",
  "Wrekkit = Wrekkit or {}",
  "Wrekkit.consumesDB = {",
}
local shared = 0
for _, s in ipairs(spells) do
  local parts = {}
  for _, id in ipairs(bySpell[s]) do
    table.insert(parts, string.format("%d, %s", id, q(items[id].name)))
  end
  if #bySpell[s] > 1 then shared = shared + 1 end
  table.insert(lines, string.format("  [%d] = { %s },", s, table.concat(parts, ", ")))
end
table.insert(lines, "}")
local f = assert(io.open(out_path, "wb"))
f:write(table.concat(lines, "\r\n") .. "\r\n")
f:close()
print(string.format("wrote %s: %d spells (%d cast by more than one item)", out_path, #spells, shared))

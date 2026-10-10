--[[ Wrekkit :: talents

Who is specced what: Holy, Protection, Retribution.

1.12 has no API for another player's talents, but this server does. Sent
on the TW_CHAT_MSG_WHISPER addon channel (it reaches one named player),
"INSTalentShow" makes the server answer for that player -- addon or not --
with one line per tree and then the end:

  INSTalentTabInfo;tree;tabName;numTalents;pointsSpent
  INSTalentInfo;tree;idx;name;tier;col;currRank;maxRank;...   (per talent)
  INSTalentEND

each as an addon message from the inspected player under the prefix
TW_CHAT_MSG_WHISPER, its text led by a tab. Only the tree totals are kept:
that is the spec.

ChronicleCompanion already inspects the raid every fifteen minutes, out of
combat. Its answers arrive on this client like any other addon message, so
they are read here and nothing more is sent. Only without it does Wrekkit
ask, the same way: one player at a time, never in combat, each again after
fifteen minutes.

The player's own spec comes straight from GetTalentTabInfo.

Anyone not inspected -- out of range, offline, or before the first round --
is guessed from what they cast: abilities only a deep talent gives, like
Holy Shock or Mortal Strike. A guess is marked as one and gives way to an
inspection. ]]

local W = Wrekkit
W.talents = {}
local TL = W.talents

local CHANNEL = "TW_CHAT_MSG_WHISPER"
local REFRESH = 900        -- seconds before a player is asked again
local TIMEOUT = 10         -- seconds before an unanswered ask is dropped
local STEP = 1.5           -- seconds between looks at the queue

TL.specs = {}              -- name -> { trees = { {name, points} x3 }, at, guess }
TL.pending = {}            -- name -> trees being received
TL.queue = {}              -- names waiting to be asked
TL.asking = nil            -- name asked, waiting on INSTalentEND
TL.askedAt = 0

----------------------------------------------------------------------
-- the spec
----------------------------------------------------------------------

--- A player's spec: the tree with the most points, its name, the points
--- in all three, and whether it was only guessed. Nil when unknown.
function TL:Spec(name)
  local s = name and self.specs[name]
  if not s then return nil end
  if s.guess then
    return { tree = s.guess, points = nil, guessed = true, from = s.from }
  end
  local best, bestPts, pts = nil, -1, {}
  for i = 1, 3 do
    local t = s.trees[i]
    local p = t and tonumber(t.points) or 0
    pts[i] = p
    if t and p > bestPts then best, bestPts = t.name, p end
  end
  if not best or bestPts <= 0 then return nil end
  return { tree = best, points = pts, guessed = false }
end

--- "Retribution (5/11/35)", or "Retribution (guessed: Repentance)".
function TL:Describe(name)
  local sp = self:Spec(name)
  if not sp then return nil end
  if sp.guessed then
    return sp.tree .. " (guessed" .. (sp.from and (": " .. sp.from) or "") .. ")"
  end
  return string.format("%s (%d/%d/%d)", sp.tree, sp.points[1], sp.points[2], sp.points[3])
end

--[[ The talent tree icons, by tree name, as the talent frame shows them.
     The server's answer names a tree but sends no icon. ]]
local TREE_ICONS = {
  ["Arms"] = "Ability_Rogue_Eviscerate",
  ["Fury"] = "Ability_Warrior_InnerRage",
  ["Holy"] = "Spell_Holy_HolyBolt",
  ["Retribution"] = "Spell_Holy_AuraOfLight",
  ["Assassination"] = "Ability_Rogue_Eviscerate",
  ["Combat"] = "Ability_BackStab",
  ["Subtlety"] = "Ability_Stealth",
  ["Arcane"] = "Spell_Holy_MagicalSentry",
  ["Fire"] = "Spell_Fire_FireBolt02",
  ["Frost"] = "Spell_Frost_FrostBolt02",
  ["Discipline"] = "Spell_Holy_WordFortitude",
  ["Shadow"] = "Spell_Shadow_ShadowWordPain",
  ["Balance"] = "Spell_Nature_StarFall",
  ["Feral Combat"] = "Ability_Racial_BearForm",
  ["Beast Mastery"] = "Ability_Hunter_BeastTaming",
  ["Marksmanship"] = "Ability_Marksmanship",
  ["Survival"] = "Ability_Hunter_SwiftStrike",
  ["Affliction"] = "Spell_Shadow_DeathCoil",
  ["Demonology"] = "Spell_Shadow_Metamorphosis",
  ["Destruction"] = "Spell_Shadow_RainOfFire",
  ["Elemental"] = "Spell_Nature_Lightning",
  ["Enhancement"] = "Spell_Nature_LightningShield",
}
-- Trees that share a name across classes.
local CLASS_TREE_ICONS = {
  PALADIN = { ["Protection"] = "Spell_Holy_DevotionAura" },
  WARRIOR = { ["Protection"] = "INV_Shield_06" },
  PRIEST = { ["Holy"] = "Spell_Holy_GuardianSpirit" },
  SHAMAN = { ["Restoration"] = "Spell_Nature_MagicImmunity" },
  DRUID = { ["Restoration"] = "Spell_Nature_HealingTouch" },
}

--- The icon for a player's spec, or nil when it is not known.
function TL:Icon(name, class)
  local sp = self:Spec(name)
  if not sp then return nil end
  local by = class and CLASS_TREE_ICONS[string.upper(class)]
  local icon = (by and by[sp.tree]) or TREE_ICONS[sp.tree]
  return icon and ("Interface\\Icons\\" .. icon) or nil
end

----------------------------------------------------------------------
-- inspections
----------------------------------------------------------------------

--- An answer line, from whoever asked for it.
function TL:OnMessage(prefix, msg, sender)
  if prefix ~= CHANNEL or type(msg) ~= "string" or not sender then return end
  msg = string.gsub(msg, "^%s+", "")
  if string.sub(msg, 1, 9) ~= "INSTalent" then return end

  if string.find(msg, "^INSTalentEND") then
    local trees = self.pending[sender]
    self.pending[sender] = nil
    if trees and (trees[1] or trees[2] or trees[3]) then
      self.specs[sender] = { trees = trees, at = GetTime() }
    end
    if self.asking == sender then self.asking = nil end
    return
  end

  -- INSTalentTabInfo;tree;tabName;numTalents;pointsSpent
  local _, _, tree, tabName, points = string.find(msg, "^INSTalentTabInfo;(%d);([^;]*);[^;]*;(%d+)")
  tree = tonumber(tree)
  if tree and tree >= 1 and tree <= 3 then
    local t = self.pending[sender]
    if not t then
      t = {}
      self.pending[sender] = t
    end
    t[tree] = { name = tabName, points = tonumber(points) or 0 }
  end
end

--- The player's own spec, from the talent API.
function TL:ReadOwn()
  if not GetTalentTabInfo then return end
  local me = UnitName("player")
  if not me then return end
  local trees = {}
  for i = 1, 3 do
    local tabName, _, points = GetTalentTabInfo(i)
    if tabName then trees[i] = { name = tabName, points = tonumber(points) or 0 } end
  end
  if trees[1] or trees[2] or trees[3] then
    self.specs[me] = { trees = trees, at = GetTime() }
  end
end

--- Is ChronicleCompanion asking already? Then its answers are enough.
function TL:OthersAsk()
  return ChronicleLog ~= nil and type(ChronicleLog.QueueTalentInspection) == "function"
end

--- Queue the group's players who have not been inspected lately.
function TL:QueueGroup()
  local now = GetTime()
  local queued = {}
  for _, n in ipairs(self.queue) do queued[n] = true end
  local n = GetNumRaidMembers and GetNumRaidMembers() or 0
  local unit = "raid"
  if n == 0 then
    n = GetNumPartyMembers and GetNumPartyMembers() or 0
    unit = "party"
  end
  local me = UnitName("player")
  for i = 1, n do
    local u = unit .. i
    local name = UnitName(u)
    local s = name and self.specs[name]
    local fresh = s and not s.guess and now - (s.at or 0) < REFRESH
    if name and name ~= me and not fresh and not queued[name]
       and (not UnitIsConnected or UnitIsConnected(u)) then
      table.insert(self.queue, name)
      queued[name] = true
    end
  end
end

--- Ask the next player, when nothing is waiting and nobody is fighting.
function TL:Step()
  if self:OthersAsk() then return end
  local now = GetTime()
  if self.asking and now - self.askedAt > TIMEOUT then
    self.pending[self.asking] = nil
    self.asking = nil
  end
  if self.asking then return end
  if UnitAffectingCombat and UnitAffectingCombat("player") then return end
  if table.getn(self.queue) == 0 then self:QueueGroup() end
  local name = table.remove(self.queue, 1)
  if not name or not SendAddonMessage then return end
  self.asking, self.askedAt = name, now
  self.pending[name] = nil
  -- The addressee is in the prefix: this channel reaches that one player.
  -- No ">" may appear in the text, and none does.
  pcall(SendAddonMessage, CHANNEL .. "<" .. name .. ">", "INSTalentShow", "GUILD")
end

----------------------------------------------------------------------
-- the guess, from what they cast
----------------------------------------------------------------------

--[[ Abilities only a deep talent gives, so casting one says the tree.
     By name (rank stripped), so every rank and client language that keeps
     English names matches; a name not here says nothing. Conservative on
     purpose: a shallow talent (Seal of Command at 11 points) is often taken
     by players specced elsewhere. ]]
local SPEC_SPELLS = {
  ["Holy Shock"] = "Holy", ["Holy Shield"] = "Protection", ["Repentance"] = "Retribution",
  ["Mortal Strike"] = "Arms", ["Bloodthirst"] = "Fury", ["Shield Slam"] = "Protection",
  ["Cold Blood"] = "Assassination", ["Adrenaline Rush"] = "Combat", ["Blade Flurry"] = "Combat",
  ["Preparation"] = "Subtlety", ["Premeditation"] = "Subtlety", ["Hemorrhage"] = "Subtlety",
  ["Arcane Power"] = "Arcane", ["Presence of Mind"] = "Arcane",
  ["Combustion"] = "Fire", ["Blast Wave"] = "Fire",
  ["Ice Barrier"] = "Frost", ["Cold Snap"] = "Frost", ["Ice Block"] = "Frost",
  ["Shadowform"] = "Shadow", ["Vampiric Embrace"] = "Shadow",
  ["Power Infusion"] = "Discipline", ["Lightwell"] = "Holy",
  ["Moonkin Form"] = "Balance", ["Swiftmend"] = "Restoration",
  ["Bestial Wrath"] = "Beast Mastery", ["Trueshot Aura"] = "Marksmanship",
  ["Wyvern Sting"] = "Survival", ["Counterattack"] = "Survival",
  ["Shadowburn"] = "Destruction", ["Conflagrate"] = "Destruction",
  ["Soul Link"] = "Demonology", ["Demonic Sacrifice"] = "Demonology",
  ["Siphon Life"] = "Affliction", ["Dark Pact"] = "Affliction",
  ["Elemental Mastery"] = "Elemental", ["Stormstrike"] = "Enhancement",
  ["Mana Tide Totem"] = "Restoration",
}
TL.SPEC_SPELLS = SPEC_SPELLS

-- spellId -> { tree, name } when it says a tree, false when it does not.
-- Every cast in range passes through here, so each id is looked up once.
local spellSpec = {}

--- A group player cast something: if only one tree gives it, guess that
--- tree -- unless an inspection has already said.
function TL:OnCast(casterGuid, spellId)
  spellId = tonumber(spellId)
  if not spellId or spellId == 0 or not casterGuid then return end
  local entry = spellSpec[spellId]
  if entry == nil then
    local name = W.capture and W.capture:Spell(spellId)
    if name then name = (string.gsub(name, "%s*%(.*%)$", "")) end
    local tree = name and SPEC_SPELLS[name]
    entry = tree and { tree = tree, name = name } or false
    spellSpec[spellId] = entry
  end
  if not entry then return end
  local u = W.capture.units[casterGuid] or W.capture:Unit(casterGuid)
  if not u or not u.isPlayer or not u.name then return end
  if not W.capture:InGroup(u.name) then return end
  local s = self.specs[u.name]
  if s and not s.guess then return end
  self.specs[u.name] = { guess = entry.tree, from = entry.name, at = GetTime() }
end

--- /wrek specs: every spec known, and how it is known.
function TL:Report()
  local names = {}
  for name in pairs(self.specs) do table.insert(names, name) end
  table.sort(names)
  if table.getn(names) == 0 then
    W.Print("no specs known yet. They come from the server's talent inspect, which " ..
      (self:OthersAsk() and "ChronicleCompanion" or "Wrekkit") ..
      " runs out of combat, a player at a time.")
    return
  end
  W.Print(table.getn(names) .. " specs known" ..
    (self:OthersAsk() and " (inspected by ChronicleCompanion):" or ":"))
  for _, name in ipairs(names) do
    W.Print("  " .. name .. ": " .. (self:Describe(name) or "?"))
  end
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function TL:Start()
  if self.frame or not CreateFrame then return end
  local f = CreateFrame("Frame", "WrekkitTalentsFrame")
  self.frame = f
  f:RegisterEvent("CHAT_MSG_ADDON")
  f:RegisterEvent("CHARACTER_POINTS_CHANGED")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:SetScript("OnEvent", function()
    if event == "CHAT_MSG_ADDON" then
      if arg1 == CHANNEL then
        W.Guard("talents", function() TL:OnMessage(arg1, arg2, arg4) end)
      end
    else
      W.Guard("own talents", function() TL:ReadOwn() end)
    end
  end)
  local function step()
    W.Guard("talents queue", function() TL:Step() end)
    W.After(STEP, step, "talentsStep")
  end
  W.After(STEP, step, "talentsStep")
end

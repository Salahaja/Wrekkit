--[[ Wrekkit :: autoshot

A hunter right-clicking a mob in the world gets the client's melee swing,
which at range does nothing. With "Hunters: right-click shoots" on
(W.db.hunterAutoShot), Wrekkit turns that into Auto Shot:

  the swing starts (PLAYER_ENTER_COMBAT) -- or the target changes while it
  is going -- and the target is past Auto Shot's dead zone (nampower's
  IsSpellInRange says Auto Shot can fire, or failing that it is beyond
  the ~10 yd duel range): cast Auto Shot, which takes over from the swing.

Closer than that the swing stays: a mob on top of you is a melee mob.
Never casts Auto Shot while it is already repeating (that would switch it
off), and only for hunters.

Whether the client lets an addon start Auto Shot from an event rather
than a click is not something the test harness can know, so the first
time it does not start, Wrekkit says so once instead of failing quietly. ]]

local W = Wrekkit
W.autoshot = {}
local A = W.autoshot

local AUTO_SHOT = 75
local CHECK_AFTER = 0.5     -- seconds to wait for START_AUTOREPEAT_SPELL

A.swinging = false
A.shooting = false

function A:Enabled()
  if not (W.db and W.db.hunterAutoShot == true) then return false end
  local _, class = UnitClass("player")
  return class == "HUNTER"
end

--- Is the target where Auto Shot belongs: in its range, past the dead zone?
function A:AtRange()
  if not UnitExists or not UnitExists("target") then return false end
  if UnitCanAttack and not UnitCanAttack("player", "target") then return false end
  if UnitIsDead and UnitIsDead("target") then return false end
  if IsSpellInRange then
    local ok, r = pcall(IsSpellInRange, AUTO_SHOT, "target")
    if ok and r == 1 then return true end
    if ok and r == 0 then
      -- Out of its range: too close (melee) or too far. Too far, shooting
      -- is still the attack you want once you step in.
      return not (CheckInteractDistance and CheckInteractDistance("target", 3))
    end
  end
  return not (CheckInteractDistance and CheckInteractDistance("target", 3))
end

--- The swing is going at range: shoot instead.
function A:Check()
  if not self:Enabled() or self.shooting or not self.swinging then return end
  if not self:AtRange() or not CastSpellByName then return end
  pcall(CastSpellByName, "Auto Shot")
  if self.warned then return end
  W.After(CHECK_AFTER, function()
    if A.shooting or A.warned then return end
    A.warned = true
    W.Print("Auto Shot did not start from a right-click -- the client may not allow it here.")
  end, "autoshotCheck")
end

function A:OnEvent(ev)
  if ev == "PLAYER_ENTER_COMBAT" then
    self.swinging = true
    self:Check()
  elseif ev == "PLAYER_LEAVE_COMBAT" then
    self.swinging = false
  elseif ev == "START_AUTOREPEAT_SPELL" then
    self.shooting = true
  elseif ev == "STOP_AUTOREPEAT_SPELL" then
    self.shooting = false
  elseif ev == "PLAYER_TARGET_CHANGED" then
    -- The swing follows a new target without a new ENTER_COMBAT.
    self:Check()
  end
end

if CreateFrame then
  local f = CreateFrame("Frame", "WrekkitAutoShotFrame")
  f:RegisterEvent("PLAYER_ENTER_COMBAT")
  f:RegisterEvent("PLAYER_LEAVE_COMBAT")
  f:RegisterEvent("START_AUTOREPEAT_SPELL")
  f:RegisterEvent("STOP_AUTOREPEAT_SPELL")
  f:RegisterEvent("PLAYER_TARGET_CHANGED")
  f:SetScript("OnEvent", function()
    W.Guard("auto shot", function() A:OnEvent(event) end)
  end)
  A.frame = f
end

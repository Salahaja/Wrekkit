--[[ test_ui.lua - constructs and drives Wrekkit's windows offline

    lua tools/test_ui.lua              (from the addon root)

The UI is the part that cannot be checked by reading it: a misspelled widget
method or a SetPoint against a frame that does not exist yet is a runtime
error that only fires when that exact path runs in-game, which usually means
mid-raid. So this stubs enough of the 1.12 widget API to actually build both
windows, then clicks through every tab, metric, drilldown and menu.

It does not verify that anything LOOKS right -- that still needs the client.
It verifies that every path runs without erroring, which is the expensive
half to find by hand.
]]

package.path = "./?.lua;" .. package.path

math.mod = math.mod or math.fmod
string.gfind = string.gfind or string.gmatch
-- 1.12 has no coroutine library; a call to it must fail here as it does in-game.
coroutine = nil
-- Nor math.huge (5.1); another addon may polyfill it in-game, but not reliably.
math.huge = nil
table.getn = table.getn or function(t) return #t end
table.setn = table.setn or function() end
unpack = unpack or table.unpack

-- The client's %d is a 32-bit int; see the same block in test_engine.lua.
do
  local realFormat = string.format
  string.format = function(fmt, ...)
    local args = table.pack(...)
    if type(fmt) == "string" then
      local i = 0
      for spec in string.gmatch(fmt, "%%[-+ #0]*%d*%.?%d*[%a%%]") do
        if spec ~= "%%" then
          i = i + 1
          local conv = string.sub(spec, -1)
          local v = args[i]
          if (conv == "d" or conv == "i") and type(v) == "number"
             and (v >= 2147483648 or v < -2147483648) then
            args[i] = -2147483648
          end
        end
      end
    end
    return realFormat(fmt, table.unpack(args, 1, args.n))
  end
end

local NOW = 1000.0
GetTime = function() return NOW end
time = function() return 1700000000 + math.floor(NOW) end
date = function(fmt, t) return "09/13 15:00" end

----------------------------------------------------------------------
-- widget stubs
----------------------------------------------------------------------

local strict = true       -- error on an unknown method rather than ignoring it
local calls = 0

local function region(kind)
  local r = { _kind = kind, _w = 0, _h = 0, _shown = true, _points = {} }

  local methods = {
    SetPoint = function(self, ...) table.insert(self._points, { ... }) end,
    SetAllPoints = function() end,
    ClearAllPoints = function(self) self._points = {} end,
    GetPoint = function(self)
      local p = self._points[1]
      if not p then return "CENTER", nil, "CENTER", 0, 0 end
      return p[1], p[2], p[3], p[4] or 0, p[5] or 0
    end,
    SetWidth = function(self, v) self._w = v or 0 end,
    SetHeight = function(self, v) self._h = v or 0 end,
    GetWidth = function(self) return self._w end,
    GetHeight = function(self) return self._h end,
    Show = function(self) self._shown = true end,
    Hide = function(self) self._shown = false end,
    IsShown = function(self) return self._shown end,
    IsVisible = function(self) return self._shown end,
    -- Round-tripped, not discarded. A stub whose GetAlpha is always 1 cannot
    -- tell "fades only the background" from "fades the whole frame, text
    -- included", which is the entire point of the opacity design.
    --[==[ Slider. Modelled on the real thing rather than no-ops: the client
           clamps, quantises to the step, and FIRES OnValueChanged from
           SetValue. That last part matters -- it is what makes a control
           that refreshes itself from its own setter re-enter, so a stub
           that stayed silent would hide the bug the guard exists for. ]==]
    SetOrientation = function() end,
    SetMinMaxValues = function(self, lo, hi) self._min, self._max = lo, hi end,
    GetMinMaxValues = function(self) return self._min or 0, self._max or 1 end,
    SetValueStep = function(self, st) self._step = st end,
    SetThumbTexture = function(self, t) self._thumb = t end,
    GetThumbTexture = function(self) return self._thumb end,
    SetValue = function(self, v)
      local lo, hi = self._min or 0, self._max or 1
      if v < lo then v = lo elseif v > hi then v = hi end
      local st = self._step
      if st and st > 0 then v = lo + math.floor((v - lo) / st + 0.5) * st end
      self._value = v
      local fn = self._scripts and self._scripts.OnValueChanged
      if fn then fn() end
    end,
    GetValue = function(self) return self._value or self._min or 0 end,
    SetAlpha = function(self, a) self._alpha = a end,
    GetAlpha = function(self) return self._alpha or 1 end,
    SetTexture = function(self, t) self._texture = t end,
    GetTexture = function(self) return self._texture end,
    -- Recorded, not discarded: opacity is expressed through the alpha
    -- channel here, so a stub that throws it away cannot tell a working
    -- opacity setting from one that does nothing.
    SetVertexColor = function(self, r, g, b, a)
      self._r, self._g, self._b, self._a = r, g, b, a
    end,
    SetTexCoord = function() end,
    SetGradientAlpha = function() end,
    SetBlendMode = function() end,
    SetDrawLayer = function() end,
    SetFont = function(self, face, size) self._face, self._size = face, size return true end,
    GetFont = function(self) return self._face, self._size end,
    SetText = function(self, t) self._text = t end,
    GetText = function(self) return self._text or "" end,
    SetTextColor = function() end,
    SetJustifyH = function() end,
    SetJustifyV = function() end,
    SetShadowColor = function() end,
    SetShadowOffset = function() end,
    SetAutoFocus = function() end,
    SetMaxLetters = function() end,
    ClearFocus = function() end,
    SetFocus = function() end,
    --[[ A constant here made every layout test vacuous: column widths
         are computed from measured text, so a stub that reports the same
         width for "Gah" and "Shieldbarbie" cannot tell a working layout
         from a broken one. Roughly 6px a character at the default size. ]]
    GetStringWidth = function(self)
      return string.len(self._text or "") * 6
    end,
  }

  return setmetatable(r, {
    __index = function(t, k)
      local m = methods[k]
      if m then return m end
      -- Every WoW widget method is PascalCase, so anything else is one of
      -- the addon's own optional data fields (dimAlpha, _lit, abilityId).
      -- Reading one that has not been set yet must return nil, not explode --
      -- otherwise the stub rejects perfectly ordinary Lua.
      if not string.find(k, "^%u") then return nil end
      if strict then
        error("unstubbed " .. kind .. " method: " .. tostring(k), 2)
      end
      return function() end
    end,
  })
end

local allFrames = {}

CreateFrame = function(kind, name, parent)
  calls = calls + 1
  local f = {
    _kind = kind, _name = name, _parent = parent,
    _w = 100, _h = 100, _shown = false,
    _scripts = {}, _events = {}, _points = {}, _children = {},
  }

  local methods = {
    CreateTexture = function() return region("Texture") end,
    CreateFontString = function() return region("FontString") end,
    SetScript = function(self, k, fn) self._scripts[k] = fn end,
    GetScript = function(self, k) return self._scripts[k] end,
    HasScript = function() return true end,
    RegisterEvent = function(self, e) self._events[e] = true end,
    UnregisterEvent = function(self, e) self._events[e] = nil end,
    RegisterForClicks = function() end,
    RegisterForDrag = function() end,
    EnableMouse = function() end,
    EnableMouseWheel = function() end,
    EnableKeyboard = function() end,
    SetMovable = function() end,
    SetResizable = function() end,
    SetClampedToScreen = function() end,
    -- recorded, so a test can check the minimum actually leaves room
    SetMinResize = function(self, w, h) self._minW, self._minH = w, h end,
    SetMaxResize = function() end,
    StartMoving = function() end,
    StartSizing = function() end,
    StopMovingOrSizing = function() end,
    SetFrameStrata = function(self, s) self._strata = s end,
    SetFrameLevel = function() end,
    GetFrameLevel = function() return 1 end,
    SetToplevel = function() end,
    SetBackdrop = function() end,
    -- Recorded: a skinned window shows its opacity through these.
    SetBackdropColor = function(self, r, g, b, a) self._bdA = a end,
    SetBackdropBorderColor = function(self, r, g, b, a) self._bdBorderA = a end,
    GetCenter = function() return 400, 300 end,
    GetLeft = function() return 300 end,
    GetTop = function() return 600 end,
    GetEffectiveScale = function() return 1 end,
    SetScale = function() end,
    Raise = function() end,
    SetHitRectInsets = function() end,
    SetNormalTexture = function() end,
    SetHighlightTexture = function() end,
    SetPushedTexture = function() end,
    GetParent = function(self) return self._parent end,
    SetParent = function() end,
    SetID = function() end,
    GetID = function() return 0 end,
    SetSequence = function() end,
  }

  -- Frames share the region methods (SetPoint, sizing, visibility).
  local base = region("Frame")

  local mt = {
    __index = function(t, k)
      local m = methods[k]
      if m then return m end
      local rm = rawget(base, k)
      if rm then return rm end
      -- fall through to the region metatable
      local ok, v = pcall(function() return base[k] end)
      if ok and v then return v end
      -- See the note in region(): non-PascalCase keys are the addon's data.
      if not string.find(k, "^%u") then return nil end
      if strict then
        error("unstubbed Frame method: " .. tostring(k), 2)
      end
      return function() end
    end,
  }

  setmetatable(f, mt)
  table.insert(allFrames, f)
  if name then _G[name] = f end
  return f
end

----------------------------------------------------------------------
-- globals the UI touches
----------------------------------------------------------------------

_G = _G or getfenv(0)

UIParent = CreateFrame("Frame", "UIParent")
UIParent:SetWidth(1024) UIParent:SetHeight(768)
Minimap = CreateFrame("Frame", "Minimap")
Minimap:SetWidth(140) Minimap:SetHeight(140)

--[[ Records what it was told, so a test can assert on what a tooltip SAYS.
     A stub that swallows the lines can only prove the code ran. ]]
GameTooltip = {
  lines = {}, owner = nil, shown = false,
  SetOwner = function(self, owner)
    self.owner = owner
    self.lines = {}
    self.shown = false
  end,
  AddLine = function(self, text) table.insert(self.lines, tostring(text)) end,
  AddDoubleLine = function(self, left, right)
    table.insert(self.lines, tostring(left) .. "	" .. tostring(right))
  end,
  IsOwned = function(self, frame) return self.owner == frame and self.shown end,
  Show = function(self) self.shown = true end,
  Hide = function(self) self.shown = false end,
}

function GameTooltipText(pattern)
  for _, l in ipairs(GameTooltip.lines) do
    if string.find(l, pattern, 1, true) then return l end
  end
  return nil
end

SlashCmdList = {}
StaticPopupDialogs = {}
StaticPopup_Show = function(k) return StaticPopupDialogs[k] ~= nil end
UISpecialFrames = {}
GetCursorPosition = function() return 400, 300 end

DEFAULT_CHAT_FRAME = { AddMessage = function() end }

-- engine-side stubs (same as test_engine)
local WORLD = {}
GetUnitData = function(g) return WORLD[g] and true or nil end
UnitName = function(u) local d = WORLD[u] return d and d.name or "Player" end
UnitIsPlayer = function(u) local d = WORLD[u] return (d and d.isPlayer) and 1 or 0 end
UnitClass = function(u) local d = WORLD[u] return d and d.class, d and d.class end
UnitLevel = function() return 60 end
UnitHealth = function(u) local d = WORLD[u] return d and d.health or 0 end
UnitHealthMax = function(u) local d = WORLD[u] return d and d.maxHealth or 0 end
UnitIsUnit = function(a, b) return a == b end
UnitCanCooperate = function() return 1 end
UnitExists = function(u) return WORLD[u] ~= nil, u end
GetUnitGUID = function(tok)
  local base = string.gsub(tok, "owner$", "")
  if base == tok then return nil end
  local d = WORLD[base]
  return d and d.owner or nil
end
SpellInfo = function(id) return "Spell " .. tostring(id), nil, "icon" end
IN_COMBAT = true
UnitAffectingCombat = function(unit) return IN_COMBAT end
GetItemInfo = function(id)
  local items = { [13446] = "Major Healing Potion", [20520] = "Dark Rune" }
  return items[id]
end
GetRealZoneText = function() return "Onyxia's Lair" end
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end
SetCVar = function() end
GetCVar = function() return "1" end
IsInInstance = function() return 1, "raid" end
GetAddOnMetadata = function() return "test" end
GetBuildInfo = function() return "1.12.1", "5875", "2006" end
WriteCustomFile = function() return true end
ReadCustomFile = function() return nil end
--[==[ SendAddonMessage in 1.12 accepts only these chat types. "WHISPER" is
       NOT among them -- this client rejects it with "Unknown addon chat
       type" and then dies with ERROR #132, so the stub has to be as strict
       as the client or the crash is invisible here. ]==]
local ADDON_CHANNELS = {
  PARTY = true, RAID = true, GUILD = true, BATTLEGROUND = true,
}
local function checkAddonChannel(channel, target)
  if not ADDON_CHANNELS[tostring(channel)] then
    error("SendAddonMessage: '" .. tostring(channel) ..
      "' is not a valid 1.12 addon chat type (PARTY/RAID/GUILD/BATTLEGROUND)", 3)
  end
  if target ~= nil then
    error("SendAddonMessage: 1.12 takes no target argument; " ..
      "address the message in its payload instead", 3)
  end
end
SendAddonMessage = function(prefix, msg, channel, target)
  checkAddonChannel(channel, target)
end
CHAT = {}
SendChatMessage = function(msg, chan, _, target)
  table.insert(CHAT, { msg = msg, chan = chan, target = target })
end
IsInGuild = function() return true end
-- Reads the real .toc, so "what version is this" can be asserted against what
-- actually ships rather than against a second copy written down in Lua.
GetAddOnMetadata = function(addon, field)
  if addon ~= "Wrekkit" or field ~= "Version" then return nil end
  local fh = io.open("Wrekkit.toc", "r")
  if not fh then return nil end
  local found
  for line in fh:lines() do
    local v = string.match(line, "^##%s*Version:%s*(%S+)")
    if v then found = v end
  end
  fh:close()
  return found
end

----------------------------------------------------------------------
-- load everything
----------------------------------------------------------------------

dofile("core.lua")
dofile("capture.lua")
dofile("encounter.lua")
dofile("metrics.lua")
dofile("report.lua")
dofile("diagnostics.lua")
dofile("store.lua")
dofile("archive.lua")
dofile("sync.lua")
dofile("announce.lua")
dofile("threat.lua")
dofile("ui/widgets.lua")
dofile("ui/chart.lua")
dofile("ui/meter.lua")
dofile("ui/report.lua")
dofile("ui/confirm.lua")
dofile("ui/settings.lua")
dofile("ui/peers.lua")
dofile("ui/threat.lua")
dofile("ui/threatframes.lua")
dofile("ui/taunt.lua")
dofile("ui/mobs.lua")
dofile("minimap.lua")
dofile("commands.lua")

WrekkitDB = nil
Wrekkit.InitDB()
-- WREKKIT_SKIN=blizzard|pfui|modern runs every step under that skin.
if (os.getenv("WREKKIT_SKIN") or "") ~= "" then
  Wrekkit.db.skin = os.getenv("WREKKIT_SKIN")
  CooldownFrame_SetTimer = function() end
  Wrekkit.ui.ApplySkin()
  print("  skin: " .. Wrekkit.ui.skin)
end
Wrekkit.capture:Start()

----------------------------------------------------------------------
-- give it something to render
----------------------------------------------------------------------

local function defP(g, n, c, hp) WORLD[g] = { name = n, class = c, isPlayer = true, maxHealth = hp, health = hp } end
local function defN(g, n, hp) WORLD[g] = { name = n, isPlayer = false, maxHealth = hp, health = hp } end
local function defPet(g, n, o) WORLD[g] = { name = n, isPlayer = false, owner = o, maxHealth = 900, health = 900 } end

defP("0xA", "Fuff", "ROGUE", 3000)
defP("0xB", "Elfpriest", "PRIEST", 2600)
defP("0xC", "Moorhunt", "HUNTER", 3400)
defPet("0xP", "Raptor", "0xC")
defN("0xBoss", "Onyxia", 1200000)

local D = Wrekkit.capture.dispatch
local function fire(e, ...) local h = D[e] if h then h(...) end end

-- two encounters so the sidebar and merging have something to chew on
for pull = 1, 2 do
  Wrekkit.encounter:CombatStart()
  for i = 1, 30 do
    fire("AUTO_ATTACK_SELF", "0xA", "0xBoss", 200 + i * 7, (i == 5) and 2 or 0, 0, 1, 0, 0, 0)
    fire("SPELL_DAMAGE_EVENT_OTHER", "0xBoss", "0xC", 100 + i, 300, "0,0,0", 0, 0)
    fire("AUTO_ATTACK_OTHER", "0xP", "0xBoss", 90, 0, 0, 1, 0, 0, 0)
    fire("SPELL_DAMAGE_EVENT_OTHER", "0xA", "0xBoss", 200, 400 + i, "20,0,0", 0, 0)
    fire("SPELL_HEAL_BY_OTHER", "0xA", "0xB", 500, 350, 0, 0)
    NOW = NOW + 1
  end
  fire("UNIT_DIED", "0xA")
  -- Leave combat through the real path. Setting inCombat directly leaves
  -- stopT where it started, so the encounter measures zero seconds and the
  -- minimum-duration filter silently discards it -- which is exactly how
  -- this harness ended up rendering empty windows while reporting success.
  Wrekkit.encounter:CombatEnd()
  Wrekkit.encounter:Finish()
  NOW = NOW + 20
end

if table.getn(Wrekkit.db.encounters) == 0 then
  error("setup recorded nothing -- the UI tests below would all be vacuous")
end

----------------------------------------------------------------------
-- drive the UI
----------------------------------------------------------------------

local pass, fail = 0, 0
local function step(label, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
    print(string.format("  ok    %s", label))
  else
    fail = fail + 1
    print(string.format("  FAIL  %s\n        %s", label, tostring(err)))
  end
end

print("\nWrekkit UI smoke test\n")

local UI = Wrekkit.ui

step("meter builds", function() UI.meter:Create() end)
step("meter shows", function() UI.meter:Show() end)
step("meter refreshes", function() UI.meter:Refresh() end)

--[[ The report and the meter ask for the same aggregate again and again;
     over finished pulls the answer must come from the cache, and anything
     that changes those pulls must make it ask again. ]]

step("finished pulls are aggregated once, not on every refresh", function()
  local list = {}
  for _, e in ipairs(Wrekkit.db.encounters) do
    if e ~= Wrekkit.encounter.live then table.insert(list, e) end
  end
  if table.getn(list) == 0 then error("no finished pulls to test with") end
  local cache = Wrekkit.report:NewCache()
  local built = 0
  local real = Wrekkit.report.View
  Wrekkit.report.View = function(self, x, y) built = built + 1 return real(self, x, y) end

  local a = cache:View(list, { petMode = "merge" })
  local b = cache:View(list, { petMode = "merge" })
  local copy = {} for i, e in ipairs(list) do copy[i] = e end
  local c = cache:View(copy, { petMode = "merge" })
  local once = built
  cache:View(list, { petMode = "separate" })
  local otherMode = built
  local e1 = list[1]
  e1.rev = (e1.rev or 0) + 1
  cache:View(list, { petMode = "separate" })
  local afterRev = built
  Wrekkit.report:Invalidate()
  cache:View(list, { petMode = "separate" })
  local afterInvalidate = built
  local live = Wrekkit.encounter.live
  Wrekkit.encounter.live = e1
  cache:View(list, { petMode = "separate" })
  cache:View(list, { petMode = "separate" })
  local whileLive = built
  Wrekkit.encounter.live = live
  Wrekkit.report.View = real

  if once ~= 1 or a ~= b or b ~= c then error("the same pulls were aggregated " .. once .. " times") end
  if otherMode ~= 2 then error("changing the pet mode reused the old view") end
  if afterRev ~= 3 then error("a pull whose rev moved was served from the cache") end
  if afterInvalidate ~= 4 then error("Invalidate did not drop the cache") end
  if whileLive ~= 6 then error("a pull still being recorded was cached") end
end)

step("a row's ability detail is built on first use and still adds up", function()
  local list = {}
  for _, e in ipairs(Wrekkit.db.encounters) do table.insert(list, e) end
  local view = Wrekkit.report:View(list, { petMode = "merge" })
  local row
  for _, r in ipairs(view.rows) do if r.isPlayer and r.damage > 0 then row = r break end end
  if not row then error("no player row with damage") end
  if rawget(row, "dmgAbility") ~= nil then error("detail was built eagerly") end
  -- Saved pulls keep each actor's top abilities only, so compare with
  -- what the row's own actors hold rather than with the row's total.
  local src = rawget(row, "_src")
  if not src then error("the row kept no sources to build detail from") end
  local want = 0
  for i = 1, table.getn(src), 2 do
    Wrekkit.report.eachAbility(src[i].dmgAbility, function(_, ab) want = want + (ab.amount or 0) end)
  end
  local sum = 0
  for _, a in pairs(row.dmgAbility) do sum = sum + (a.amount or 0) end
  if want <= 0 or math.abs(sum - want) > 0.5 then
    error(string.format("abilities add to %d, the actors hold %d", sum, want))
  end
  if rawget(row, "_src") ~= nil then error("sources kept after the detail was built") end
  if type(row.auras) ~= "table" then error("auras missing after build") end
end)

step("reopening the report does not re-aggregate the session", function()
  UI.report:Show()
  UI.report.state.tab = "summary"
  local built, series = 0, 0
  local realV, realS = Wrekkit.report.View, Wrekkit.report.Series
  Wrekkit.report.View = function(self, x, y) built = built + 1 return realV(self, x, y) end
  Wrekkit.report.Series = function(self, x, y) series = series + 1 return realS(self, x, y) end
  UI.report:Refresh()
  local first, firstS = built, series
  for _ = 1, 5 do UI.report.frame:Hide() UI.report:Show() end
  Wrekkit.report.View, Wrekkit.report.Series = realV, realS
  UI.report.frame:Hide()

  local live = false
  for _, e in ipairs(UI.report:SelectedEncounters()) do
    if e == Wrekkit.encounter.live then live = true end
  end
  if live then return end
  if first > 1 then error("one summary refresh aggregated " .. first .. " times") end
  if built ~= first or series ~= firstS then
    error("five reopens aggregated " .. (built - first) .. " more views and "
      .. (series - firstS) .. " more series")
  end
end)


step("meter renders every metric", function()
  for _, m in ipairs(Wrekkit.metrics.list) do
    UI.meter:SetMetric(m.key)
  end
  UI.meter:SetMetric("damage")
end)

step("meter segments", function()
  for _, seg in ipairs({ "current", "last", "overall" }) do
    UI.meter:Settings().segment = seg
    UI.meter:Refresh()
  end
end)

step("meter drilldown", function()
  local rows = UI.meter.list.data
  local first = rows and rows[1]
  if first then
    UI.meter.drill = first.key
    UI.meter:Refresh()
    UI.meter.drill = nil
    UI.meter:Refresh()
  end
end)

step("meter filter", function()
  UI.meter:Settings().search = "fuf"
  UI.meter:Refresh()
  UI.meter:Settings().search = ""
  UI.meter:Refresh()
end)

step("meter pets split", function()
  UI.meter:Settings().petMode = "separate"
  UI.meter:Refresh()
  UI.meter:Settings().petMode = "merge"
  UI.meter:Refresh()
end)

step("meter toolbar toggles", function()
  UI.meter:Settings().showToolbar = false
  UI.meter:ApplyToolbar()
  UI.meter:Settings().showToolbar = true
  UI.meter:ApplyToolbar()
end)

step("meter scrolls", function() UI.meter.list:Scroll(-1) UI.meter.list:Scroll(1) end)

step("bar style: changes every bar at once, and back to the skin's", function()
  local M = UI.meter
  M:Refresh()
  local row = M.list.rows[1]
  if not row then error("the meter has no rows to look at") end
  local skinBar = UI.skinBar
  UI.SetBarTexture("flat")
  if row.bar:GetTexture() ~= UI.media.white then error("flat did not reach an existing bar: " .. tostring(row.bar:GetTexture())) end
  if Wrekkit.db.barTexture ~= "flat" then error("the bar style was not saved") end
  UI.SetBarTexture("blizzard")
  if row.bar:GetTexture() ~= "Interface\\TargetingFrame\\UI-StatusBar" then error("Blizzard bars did not apply") end
  UI.SetBarTexture("skin")
  if row.bar:GetTexture() ~= skinBar then error("skin did not bring the look's own bar back") end
  -- A row made after the change gets the new style too.
  UI.SetBarTexture("flat")
  local fresh = UI.Row(UIParent, 18)
  if fresh.bar:GetTexture() ~= UI.media.white then error("a new row did not get the chosen style") end
  UI.SetBarTexture("skin")
end)

step("colours apart from the look, and bar opacity", function()
  local C = Wrekkit.color
  local keep = {}
  for _, k in ipairs({ "accent", "accentHi", "text", "textDim" }) do
    keep[k] = { C[k][1], C[k][2], C[k][3] }
  end
  local function near(c, r, g, b) return math.abs(c[1] - r) + math.abs(c[2] - g) + math.abs(c[3] - b) < 0.01 end
  UI.ApplyColorTheme("pfui")
  if not near(C.accent, 0.20, 1.00, 0.80) then error("pfUI colours did not give the teal accent") end
  UI.ApplyColorTheme("blizzard")
  if not near(C.accent, 1.00, 0.82, 0.00) or not near(C.text, 1, 1, 1) then error("Blizzard colours did not apply") end
  UI.ApplyColorTheme("modern")
  if not near(C.accent, 0.878, 0.635, 0.173) then error("modern did not bring the amber back") end
  UI.ApplyColorTheme("skin")   -- a no-op: the look's own stay
  for k, c in pairs(keep) do C[k][1], C[k][2], C[k][3] = c[1], c[2], c[3] end

  -- Bar opacity: live, and held to 20-100%.
  local M = UI.meter
  Wrekkit.db.barAlpha = 0.9
  M:Refresh()
  local row = M.list.rows[1]
  if row and row:IsShown() and math.abs((row.bar._a or 0) - 0.9) > 0.001 then
    error("bar opacity did not reach the bars: " .. tostring(row.bar._a))
  end
  Wrekkit.db.barAlpha = 5
  if UI.BarAlpha() ~= 1 then error("bar opacity is not held to 100%") end
  Wrekkit.db.barAlpha = 0
  if UI.BarAlpha() ~= 0.2 then error("bar opacity is not held to 20%") end
  Wrekkit.db.barAlpha = nil
  if UI.BarAlpha() ~= 0.55 then error("unset, bars are not the looks' 55%") end
  M:Refresh()
end)

step("font: changes text at once, leaves the numbers, offers pfUI's only with pfUI", function()
  local M = UI.meter
  M:Refresh()
  local row = M.list.rows[1]
  local skinFont = UI.skinFont or UI.font
  -- A number set in the narrow face, to see it is left alone.
  local num = UI.Text(UIParent, 10, nil, "RIGHT", UI.fontNum)
  UI.SetFont("arial")
  if row.name:GetFont() ~= "Fonts\\ARIALN.TTF" then error("the font did not reach an existing name: " .. tostring(row.name:GetFont())) end
  if Wrekkit.db.font ~= "arial" then error("the font choice was not saved") end
  UI.SetFont("morpheus")
  if row.name:GetFont() ~= "Fonts\\MORPHEUS.TTF" then error("a second change did not follow") end
  if num:GetFont() ~= UI.fontNum then error("the numbers' face was changed") end
  local fresh = UI.Text(UIParent, 11)
  if fresh:GetFont() ~= "Fonts\\MORPHEUS.TTF" then error("new text did not get the chosen font") end
  UI.SetFont("skin")
  if row.name:GetFont() ~= skinFont then error("skin did not bring the look's font back") end
  -- pfUI's fonts: only with pfUI.
  local hadPf = pfUI
  pfUI = nil
  for _, f in ipairs(UI.FontChoices()) do
    if f.pfui then error("a pfUI font was offered without pfUI: " .. f.label) end
  end
  if UI.FontPath("myriad") then error("a pfUI font resolved without pfUI") end
  pfUI = { font_default = "Interface\\AddOns\\pfUI\\fonts\\Myriad-Pro.ttf" }
  local offered = 0
  for _, f in ipairs(UI.FontChoices()) do if f.pfui then offered = offered + 1 end end
  if offered == 0 then error("pfUI's fonts were not offered with pfUI") end
  if UI.FontPath("pfui") ~= pfUI.font_default then error("pfUI's own font did not resolve") end
  pfUI = hadPf
end)

step("class icons: on player rows when asked for, never stale on a reused row", function()
  local M = UI.meter
  M:Settings().metric, M:Settings().segment = "damage", "overall"
  M.drill, M.drillAbility = nil, nil
  Wrekkit.db.classIcons = true
  M:Refresh()
  local item = M.list.data[1]
  if not item then error("the meter has no rows") end
  local checked = 0
  for i, it in ipairs(M.list.data) do
    local row = M.list.rows[i]
    if row and row:IsShown() and it.isPlayer and UI.CLASS_COORDS[it.class or ""] then
      if not row.icon:IsShown() then error("no class icon on " .. tostring(it.name)) end
      local p = row.name._points[1]
      if not p or p[4] <= 26 then error("the name did not move over for the icon") end
      checked = checked + 1
    end
  end
  if checked == 0 then error("no player row to check a class icon on") end
  -- The same row painted as an ability (no class): no icon left behind.
  M.drill = item.key
  M:Refresh()
  if M.list.rows[1].icon:IsShown() then error("an ability row kept a class icon") end
  M.drill = nil
  -- Off: gone, and the name back at the gutter.
  Wrekkit.db.classIcons = false
  M:Refresh()
  if M.list.rows[1].icon:IsShown() then error("class icons stayed after being switched off") end
  local p = M.list.rows[1].name._points[1]
  if not p or p[4] ~= 26 then error("the name did not go back to the gutter") end
  M:Settings().segment = "current"
  M:Refresh()
end)

step("fit to rows: no empty space under the last row, never taller than sized", function()
  local M = UI.meter
  local f = M.frame
  local s = M:Settings()
  s.segment = "overall"
  M:SetSplit("off")
  f:SetHeight(400)
  f._maxH, f._topAnchored = nil, nil
  -- The stub cannot work a height out from anchors: give the list what the
  -- client would, the window less 60 of chrome.
  local realGetH = M.list.GetHeight
  M.list.GetHeight = function() return f:GetHeight() - 60 end
  s.fitRows = true
  M:Refresh()
  local n = table.getn(M.list.data)
  if n == 0 then error("no rows to fit to") end
  local want = 60 + n * M.list.rowHeight + 2
  if math.abs(f:GetHeight() - want) > 1 then
    error(string.format("fitted to %d, not %d for %d rows", f:GetHeight(), want, n))
  end
  if f._maxH ~= 400 then error("the height it was sized to was not kept: " .. tostring(f._maxH)) end
  local p = f._points[1]
  if not p or p[1] ~= "TOPLEFT" then error("a fitted window is not held by its top") end
  -- Saving keeps the sized height, not the fit.
  f:SavePosition()
  if s.window.h ~= 400 then error("saving kept the fitted height " .. tostring(s.window.h)) end
  -- Never taller than sized: a small window stays small.
  f._maxH = want - 20
  M:Refresh()
  if f:GetHeight() > want - 20 + 0.5 then error("grew past the height it was sized to") end
  -- While the grip is held, the drag is the user's.
  f._sizing = true
  f:SetHeight(500)
  M:Refresh()
  if f:GetHeight() ~= 500 then error("fitted mid-drag") end
  f._sizing = nil
  -- Off: back to the sized height.
  f._maxH = 400
  s.fitRows = false
  M:Refresh()
  -- Back to the sized height, less the part of a row the list cannot use.
  local rowH = M.list.rowHeight
  local expect = 400 - math.mod(400 - 60, rowH)
  if math.abs(f:GetHeight() - expect) > 0.5 or f._maxH then
    error("switching it off left " .. f:GetHeight() .. ", not the sized height snapped to rows (" .. expect .. ")")
  end
  M.list.GetHeight = realGetH
  s.segment = "current"
  M:Refresh()
end)

step("fit after letting go of the grip, though the client reports a stale height first", function()
  local M = UI.meter
  local f = M.frame
  local s = M:Settings()
  M:SetSplit("off")
  s.segment = "overall"
  s.fitRows = true
  f._maxH = nil
  M:Refresh()
  local n = table.getn(M.list.data)
  if n == 0 then error("no rows to fit to") end
  local rowH = M.list.rowHeight
  -- Right after the grip is let go, the list still reports its old height.
  local settled = false
  local oldListH = 120
  local realGetH, realAfter = M.list.GetHeight, Wrekkit.After
  M.list.GetHeight = function() return settled and (f:GetHeight() - 60) or oldListH end
  local queued = {}
  Wrekkit.After = function(_, fn) table.insert(queued, fn) end
  local ok, err = pcall(function()
    f.grip:GetScript("OnDragStart")()
    f:SetHeight(420)
    f.grip:GetScript("OnDragStop")()
    -- The client catches up; the grip's delayed passes run.
    settled = true
    for _, fn in ipairs(queued) do fn() end
  end)
  Wrekkit.After, M.list.GetHeight = realAfter, realGetH
  if not ok then error(err) end
  local want = 60 + n * rowH + 2
  if math.abs(f:GetHeight() - want) > 1 then
    error(string.format("after letting go the meter is %d tall, not fitted to %d rows (%d)", f:GetHeight(), n, want))
  end
  if f._maxH ~= 420 then error("the height dragged to is not the most it may grow to: " .. tostring(f._maxH)) end
  s.fitRows = false
  s.segment = "current"
  M:Refresh()
end)

step("rows: fixed, stretched to fill, or a set number filling the window", function()
  local M = UI.meter
  local s = M:Settings()
  M:SetSplit("off")
  s.fitRows = false
  local base = math.floor((s.rowHeight or 18) * UI.FontScale() + 0.5)
  local listH = base * 5 + base * 0.6        -- five rows and a bit
  local realGetH = M.list.GetHeight
  M.list.GetHeight = function() return listH end
  local ok, err = pcall(function()
    s.rowMode = "fixed"
    M:Refresh()
    if math.abs(M.list.rowHeight - base) > 0.01 then error("fixed rows are not the Row height") end
    -- Stretch: the five that fit, stretched to fill, nothing left over.
    s.rowMode = "stretch"
    M:Refresh()
    if math.abs(M.list.rowHeight * 5 - listH) > 0.01 then
      error(string.format("stretched rows are %.2f; five of them do not fill %.2f", M.list.rowHeight, listH))
    end
    if M.list:VisibleCount() ~= 5 then error("stretched, the list shows " .. M.list:VisibleCount() .. " rows, not 5") end
    -- A set number: three rows fill it.
    s.rowMode, s.rowCount = "count", 3
    M:Refresh()
    if math.abs(M.list.rowHeight * 3 - listH) > 0.01 then error("three set rows do not fill the list") end
    if M.list:VisibleCount() ~= 3 then error("set to 3, the list shows " .. M.list:VisibleCount()) end
    -- Fill with players: the players shown fill the list exactly...
    s.rowMode = "players"
    M:Refresh()
    local n = table.getn(M.list.data)
    if n == 0 then error("no players to fill with") end
    local each = listH / n
    if each <= base * 3 then
      if math.abs(M.list.rowHeight * n - listH) > 0.01 then
        error(string.format("%d players at %.2f do not fill %.2f", n, M.list.rowHeight, listH))
      end
    end
    -- ...but a few players in a tall window stop at three Row heights.
    local tall = base * 3 * n * 4
    M.list.GetHeight = function() return tall end
    M:Refresh()
    if math.abs(M.list.rowHeight - base * 3) > 0.01 then
      error(string.format("few players in a tall window are %.2f tall, not capped at %.2f", M.list.rowHeight, base * 3))
    end
    M.list.GetHeight = function() return listH end
    -- Fitting to rows sizes the window instead: rows keep the Row height.
    s.fitRows = true
    M:Refresh()
    if math.abs(M.list.rowHeight - base) > 0.01 then error("with fit on, rows were still stretched") end
  end)
  M.list.GetHeight = realGetH
  s.rowMode, s.rowCount, s.fitRows = "fixed", 8, false
  M:Refresh()
  if not ok then error(err) end
end)

step("a window being moved is never re-anchored or resized (that crashes 1.12)", function()
  local M = UI.meter
  local f = M.frame
  local s = M:Settings()
  M:SetSplit("off")
  s.fitRows = false
  local rowH = M.list.rowHeight
  f:SetHeight(300)
  f._topAnchored = nil
  local realGetH = M.list.GetHeight
  -- A part-row left over, so the trim would act.
  M.list.GetHeight = function() return f:GetHeight() - 300 + rowH * 3.5 end
  local ok, err = pcall(function()
    f:StartMoving()
    if not f._moving then error("moving the window did not mark it as moving") end
    local points = table.getn(f._points or {})
    local before = f._points[1]
    M:Refresh()
    if f:GetHeight() ~= 300 then error("the window was resized while being moved") end
    if f._points[1] ~= before or table.getn(f._points) ~= points then
      error("the window was re-anchored while being moved")
    end
    -- Let go: now the trim may run.
    f:StopMovingOrSizing()
    if f._moving then error("still marked as moving after letting go") end
    M:Refresh()
    if math.abs(M.list:GetHeight() - rowH * 3) > 0.5 then error("after the move the part-row was not trimmed") end
  end)
  if f._moving then f:StopMovingOrSizing() end
  M.list.GetHeight = realGetH
  M:Refresh()
  if not ok then error(err) end
end)

step("after a resize, the meter loses the part of a row it cannot use", function()
  local M = UI.meter
  local f = M.frame
  local s = M:Settings()
  s.fitRows = false
  M:SetSplit("off")
  local rowH = M.list.rowHeight
  -- A list 3.5 rows tall: half a row of blank above the footer.
  f:SetHeight(300)
  local realGetH, realAfter = M.list.GetHeight, Wrekkit.After
  M.list.GetHeight = function() return f:GetHeight() - 300 + rowH * 3.5 end
  Wrekkit.After = function(_, fn) fn() end   -- the snap waits a moment; not here
  f.OnResizeEnd()
  Wrekkit.After = realAfter
  local left = M.list:GetHeight()
  M.list.GetHeight = realGetH
  if math.abs(left - rowH * 3) > 0.5 then
    error(string.format("the list is %.1f tall, not 3 whole rows (%d)", left, rowH * 3))
  end
  if math.abs((s.window.h or 0) - f:GetHeight()) > 0.5 then error("the snapped height was not saved") end
  -- The footer's text sits low, not centred over a band of space.
  local p = M.footL._points[1]
  if not p or p[1] ~= "BOTTOMLEFT" then error("the footer text is not seated low") end
end)

step("a narrow row never draws its name over its value", function()
  local realScale = Wrekkit.db.fontScale
  Wrekkit.db.fontScale = 0.7
  local list = UI.ScrollList(UIParent, 18)
  local row = UI.Row(list, 18)
  local function check(w)
    row:SetWidth(w)
    row:SetData(1, "Shieldbarbie", "31.0k", "965 dps", 0.5, { 1, 1, 1 }, 58)
    local valueW = row.value:GetStringWidth()
    local subW = row.sub:GetWidth() or 0
    -- Rank gutter, the name, the value, the secondary column and the gaps
    -- must fit in the row: anything over is the name drawn on the value.
    local used = 26 + row.name:GetWidth() + valueW + subW + 14
    if used > w + 12 then
      error(string.format("at %dpx the name runs %dpx into the value", w, used - w))
    end
    return row.sub._text or ""
  end
  if check(320) ~= "965 dps" then error("a wide row lost its per-second column") end
  if check(145) ~= "" then error("a narrow row kept its per-second column instead of the name") end
  check(90)
  Wrekkit.db.fontScale = realScale
end)

step("meter split: two metrics, each with its own drilldown", function()
  local M = UI.meter
  local s = M:Settings()
  s.metric, s.segment = "damage", "overall"
  M:SetSplit("stacked")
  if not M:Split() then error("split did not turn on") end
  if not M.head2:IsShown() or not M.list2:IsShown() then error("the second half is not shown") end
  M:Refresh()
  local label = M.head2.label:GetText() or ""
  if not string.find(label, "Healing", 1, true) then error("the second half reads " .. label) end
  -- Each half ranks its own metric.
  local top, bottom = M.list.data[1], M.list2.data[1]
  if not top or not bottom then error("a half is empty") end
  if top._v == bottom._v and top.key == bottom.key and table.getn(M.list.data) > 1 then
    error("both halves rank the same thing")
  end
  -- Drilling into the lower half leaves the upper alone, and back out.
  M.drill2 = bottom.key
  M:Refresh()
  if M.drill then error("drilling the lower half opened the upper") end
  if M.list2.data[1] and M.list2.data[1]._rank then error("the lower half did not open the player") end
  M.head2:GetScript("OnClick")()            -- arg1 is nil: a left-click opens its menu
  UI.CloseMenu()
  arg1 = "RightButton"
  M.head2:GetScript("OnClick")()
  arg1 = nil
  if M.drill2 then error("right-click on the lower header did not back out") end
  -- The second metric's menu sets the second metric, and has no Threat.
  M:MetricMenu(M.head2, 2)
  UI.CloseMenu()
  s.metric2 = "dispels"
  M:Refresh()
  -- Threat on top still draws the lower half.
  s.metric = "threat"
  M:Refresh()
  s.metric = "damage"
  -- A resize lays both halves out again; compact keeps them.
  M.frame:SetHeight(320)
  M.frame.OnResize()
  s.compact = true
  M:ApplyLayout()
  s.compact = false
  M:ApplyLayout()
  -- The title-bar button goes on to side by side: both columns under a
  -- header each, the window widened to fit them.
  M.frame:SetWidth(260)
  M.splitBtn:GetScript("OnClick")()
  if M:SplitMode() ~= "side" then error("the button went to " .. M:SplitMode() .. ", not side by side") end
  if not M.head1:IsShown() or not M.head2:IsShown() or not M.divider:IsShown() then
    error("side by side is missing a header or the divider")
  end
  if (M.frame:GetWidth() or 0) < M.SIDE_MIN_W then error("the window was not widened for two columns") end
  -- Equal columns by construction: both meet at a line held to the middle
  -- of the area by its TOP and BOTTOM, never at a width measured once.
  local function anchoredTo(frame, point, target)
    for _, p in ipairs(frame._points or {}) do
      if p[1] == point and p[2] == target then return true end
    end
    return false
  end
  if not anchoredTo(M.paneMid, "TOP", M.paneArea) or not anchoredTo(M.paneMid, "BOTTOM", M.paneArea) then
    error("the middle line is not held to the middle of the area")
  end
  if not anchoredTo(M.list, "BOTTOMRIGHT", M.paneMid) then error("the first column does not end at the middle line") end
  if not anchoredTo(M.head2, "TOPLEFT", M.paneMid) then error("the second column does not start at the middle line") end
  M:Refresh()
  if not string.find(M.head1.label:GetText() or "", "Damage", 1, true) then
    error("the first column's header reads " .. tostring(M.head1.label:GetText()))
  end
  -- The first column's header opens its metric menu and backs out of its drilldown.
  M.drill = M.list.data[1] and M.list.data[1].key
  M:Refresh()
  arg1 = "RightButton"
  M.head1:GetScript("OnClick")()
  arg1 = nil
  if M.drill then error("right-click on the first column's header did not back out") end
  M.head1:GetScript("OnClick")()
  UI.CloseMenu()
  M.frame:SetWidth(520)
  M.frame.OnResize()
  -- Then back to one metric.
  M.splitBtn:GetScript("OnClick")()
  if M:Split() or M.head1:IsShown() or M.head2:IsShown() or M.list2:IsShown() or M.divider:IsShown() then
    error("the button did not go back to one metric")
  end
  -- A saved on/off from before the third option reads as over and under.
  s.splitMode, s.split = "off", true
  if M:SplitMode() ~= "stacked" or s.split ~= nil then error("an old split=true was not carried over") end
  M:SetSplit("off")
  -- The window menu offers all three.
  local items
  local realMenu = UI.Menu
  UI.Menu = function(_, _, its) items = its end
  M:WindowMenu(M.frame.bar)
  UI.Menu = realMenu
  local modes = 0
  for _, it in ipairs(items or {}) do
    if it.value and string.sub(it.value, 1, 6) == "split:" then modes = modes + 1 end
  end
  if modes ~= 3 then error("the window menu offers " .. modes .. " layouts, not 3") end
  M.frame:SetWidth(260)
  s.metric2, s.segment = "healing", "current"
  M:ApplyLayout()
end)

step("meter menus open", function()
  UI.meter:MetricMenu(UI.meter.frame.bar)
  UI.CloseMenu()
  UI.meter:SegmentMenu(UI.meter.frame.bar)
  UI.CloseMenu()
  UI.meter:WindowMenu(UI.meter.frame.bar)
  UI.CloseMenu()
end)

step("menus do not leak frames", function()
  -- 1.12 cannot destroy a frame, so a menu that rebuilds itself per open
  -- would grow the frame count forever. Open a lot and check it settles.
  UI.meter:MetricMenu(UI.meter.frame.bar)
  UI.CloseMenu()
  local baseline = calls
  for i = 1, 40 do
    UI.meter:MetricMenu(UI.meter.frame.bar)
    UI.CloseMenu()
    UI.meter:SegmentMenu(UI.meter.frame.bar)
    UI.CloseMenu()
    UI.meter:WindowMenu(UI.meter.frame.bar)
    UI.CloseMenu()
  end
  if calls ~= baseline then
    error(string.format("leaked %d frames over 120 menu opens", calls - baseline))
  end
end)

step("report builds", function() UI.report:Create() end)
step("report shows", function() UI.report:Show() end)

step("report renders every tab", function()
  for _, tab in ipairs(UI.report.tabs) do
    UI.report.state.tab = tab.key
    if tab.metric then UI.report.state.sortKey = tab.metric end
    UI.report:Refresh()
  end
  UI.report.state.tab = "summary"
  UI.report:Refresh()
end)

step("report encounter selection", function()
  local session = UI.report:Session()
  if session and session.encounters[1] then
    local enc = session.encounters[1]
    UI.report.state.selected = { [tostring(enc.sessionId) .. ":" .. tostring(enc.id)] = true }
    UI.report:Refresh()
  end
  UI.report:SelectAll()
end)

step("report drilldown", function()
  local rows = UI.report.sumLeftList.data
  local first = rows and rows[1]
  if first then
    UI.report.state.drill = first.key
    UI.report:Refresh()
    UI.report.state.drill = nil
    UI.report:Refresh()
  end
end)

step("report filter", function()
  UI.report.state.search = "elf"
  UI.report:Refresh()
  UI.report.state.search = ""
  UI.report:Refresh()
end)

step("report session menu", function()
  UI.report:SessionMenu()
  UI.CloseMenu()
end)

step("chart toggles series", function()
  UI.report.chart:Toggle("dd")
  UI.report:RefreshChart()
  UI.report.chart:Toggle("dd")
  UI.report:RefreshChart()
end)

step("chart handles an empty selection", function()
  UI.report.chart:SetSeries(nil, 0, 0, {})
end)

step("report resizes", function()
  UI.report.frame:SetWidth(700) UI.report.frame:SetHeight(450)
  UI.report:Refresh()
  UI.report.frame:SetWidth(1100) UI.report.frame:SetHeight(700)
  UI.report:Refresh()
end)

step("windows render during a LIVE pull", function()
  -- The path a new user actually hits first: install, pull something, open
  -- the windows mid-fight. A live encounter differs from a finished one --
  -- no duration yet, ability tables still keyed by spell id, buckets still
  -- named fields -- so it must be exercised before Finish() normalises it.
  Wrekkit.encounter:CombatStart()
  for i = 1, 10 do
    fire("AUTO_ATTACK_SELF", "0xA", "0xBoss", 250, 0, 0, 1, 0, 0, 0)
    fire("SPELL_HEAL_BY_OTHER", "0xA", "0xB", 500, 300, 0, 0)
    NOW = NOW + 1
  end

  UI.meter:Settings().segment = "current"
  UI.meter:Refresh()

  UI.report.state.tab = "summary"
  UI.report:Refresh()
  for _, tab in ipairs(UI.report.tabs) do
    UI.report.state.tab = tab.key
    UI.report:Refresh()
  end
  UI.report.state.tab = "summary"
end)

step("clicking real handlers (not just setting state)", function()
  -- Driving state directly skips the closures the buttons actually run, so
  -- a nil upvalue inside one would never surface. Fire them for real.
  arg1 = "LeftButton"

  for _, tab in ipairs(UI.report.tabs) do
    local b = UI.report.tabButtons[tab.key]
    local fn = b:GetScript("OnClick")
    if not fn then error("tab " .. tab.key .. " has no OnClick") end
    fn()
  end

  -- sidebar encounter rows
  for _, row in ipairs(UI.report.encList.rows) do
    local fn = row:GetScript("OnClick")
    if fn and row:IsShown() then
      fn()
      arg1 = "RightButton"; fn()
      arg1 = "LeftButton"
    end
  end

  -- report table rows, both buttons
  for _, row in ipairs(UI.report.sumLeftList.rows) do
    local fn = row:GetScript("OnClick")
    if fn and row:IsShown() then
      fn()
      arg1 = "RightButton"; fn()
      arg1 = "LeftButton"
    end
  end

  -- meter rows
  UI.meter:Refresh()
  for _, row in ipairs(UI.meter.list.rows) do
    local fn = row:GetScript("OnClick")
    if fn and row:IsShown() then
      fn()
      arg1 = "RightButton"; fn()
      arg1 = "LeftButton"
    end
  end

  -- chart legend
  for _, b in ipairs(UI.report.chart.legendButtons) do
    local fn = b:GetScript("OnClick")
    if fn then fn() fn() end
  end

  arg1 = nil
end)

step("Escape closes the report", function()
  local found = false
  for _, n in ipairs(UISpecialFrames) do
    if n == "WrekkitReport" then found = true end
  end
  if not found then error("WrekkitReport not registered in UISpecialFrames") end
  if not _G["WrekkitReport"] then error("report frame has no global name") end
  -- and the meter must NOT be, it is a HUD element
  for _, n in ipairs(UISpecialFrames) do
    if n == "WrekkitMeter" then error("meter should not close on Escape") end
  end
end)

step("ability detail drills two levels deep", function()
  -- actor -> abilities -> one ability's spread, in both windows.
  UI.report.state.tab = "damage"
  UI.report.state.drill = nil
  UI.report.state.drillAbility = nil
  UI.report:Refresh()

  local rows = UI.report.mainList.data
  if not rows or not rows[1] then error("no rows to drill into") end
  UI.report.state.drill = rows[1].key
  UI.report:Refresh()

  local abilities = UI.report.mainList.data
  if not abilities or not abilities[1] then error("no abilities in the drilldown") end
  if not abilities[1].id then error("ability row carries no id to drill on") end

  UI.report.state.drillAbility = abilities[1].id
  UI.report:Refresh()

  local stats = UI.report.mainList.data
  if not stats or not stats[1] or not stats[1].label then
    error("ability detail did not produce label/value rows")
  end

  -- and back out
  UI.report.state.drillAbility = nil
  UI.report.state.drill = nil
  UI.report.state.tab = "summary"
  UI.report:Refresh()

  -- same journey on the meter
  UI.meter:Refresh()
  local mrows = UI.meter.list.data
  if mrows and mrows[1] then
    UI.meter.drill = mrows[1].key
    UI.meter:Refresh()
    local mab = UI.meter.list.data
    if mab and mab[1] then
      UI.meter.drillAbility = mab[1].id
      UI.meter:Refresh()
    end
    UI.meter.drillAbility = nil
    UI.meter.drill = nil
    UI.meter:Refresh()
  end
end)

step("HUD toggle buttons work", function()
  arg1 = "LeftButton"
  for _, name in ipairs({ "groupBtn", "worldBtn", "resetBtn" }) do
    local b = UI.meter[name]
    if not b then error("meter is missing " .. name) end
    local fn = b:GetScript("OnClick")
    if not fn then error(name .. " has no OnClick") end
    fn()
    fn()
  end
  -- right-click reset must route through the confirmation, not wipe directly
  arg1 = "RightButton"
  UI.meter.resetBtn:GetScript("OnClick")()
  arg1 = "LeftButton"

  -- the toggles must reflect the state they represent
  UI.meter:Settings().groupOnly = true
  UI.meter:UpdateToggles()
  if not UI.meter.groupBtn._lit then error("group toggle did not light up") end
  UI.meter:Settings().groupOnly = false
  UI.meter:UpdateToggles()
  if UI.meter.groupBtn._lit then error("group toggle stayed lit") end

  -- hover tooltips
  UI.meter.groupBtn:GetScript("OnEnter")()
  UI.meter.groupBtn:GetScript("OnLeave")()
  arg1 = nil
end)

step("report sits above the meter", function()
  if not UI.report.frame._strata then
    error("report window never had its strata set")
  end
  if UI.report.frame._strata ~= "HIGH" then
    error("report strata is " .. tostring(UI.report.frame._strata) .. ", expected HIGH")
  end
  if UI.meter.frame._strata == "HIGH" then
    error("meter is on the same strata as the report; it will draw over it")
  end
end)

step("sidebar padlock keeps an encounter", function()
  UI.report:Refresh()
  local row = UI.report.encList.rows[1]
  if not row then error("no encounter rows in the sidebar") end
  if not row.lock then error("sidebar row has no padlock") end

  local before = Wrekkit.CountLocked()
  local fn = row.lock:GetScript("OnClick")
  if not fn then error("padlock has no OnClick") end

  fn()
  if Wrekkit.CountLocked() ~= before + 1 then
    error("clicking the padlock did not lock anything" ..
      (Wrekkit.lastError and ("; guard caught: " .. Wrekkit.lastError.err) or ""))
  end
  if not row.lock._lit then error("padlock did not light up") end

  fn()
  if Wrekkit.CountLocked() ~= before then
    error("clicking again did not unlock")
  end
end)

step("meter shows by default and remembers being hidden", function()
  -- Default is visible.
  if Wrekkit.ui.meter.defaults.shown ~= true then
    error("meter does not default to shown")
  end

  -- The title-bar X must persist the choice, not just hide the frame --
  -- otherwise it comes back on the next login and looks broken.
  UI.meter:Show()
  local close = UI.meter.frame.closeButton:GetScript("OnClick")
  if not close then error("close button has no handler") end
  close()
  if UI.meter.frame:IsShown() then error("close did not hide the meter") end
  if UI.meter:Settings().shown ~= false then
    error("close did not persist -- the meter would return next login")
  end

  -- A fresh login with shown=false must leave it hidden.
  UI.meter:RestoreVisibility()
  if UI.meter.frame:IsShown() then
    error("restore reopened a meter the user had closed")
  end

  -- ...and with shown=true must bring it back.
  UI.meter:Settings().shown = true
  UI.meter.frame:Hide()
  UI.meter:RestoreVisibility()
  if not UI.meter.frame:IsShown() then error("restore did not reopen the meter") end

  -- Toggle keeps the setting in step with the frame.
  UI.meter:Toggle()
  if UI.meter:Settings().shown ~= false then error("toggle-off did not persist") end
  UI.meter:Toggle()
  if UI.meter:Settings().shown ~= true then error("toggle-on did not persist") end
end)

step("announce goes through confirmation, never straight to chat", function()
  CHAT = {}
  UI.CloseConfirm()

  -- Pretend we are grouped: the availability check correctly refuses PARTY
  -- while solo, which is the behaviour the next step asserts.
  local realParty = GetNumPartyMembers
  GetNumPartyMembers = function() return 4 end

  -- The report announces whatever TAB is open.
  UI.report:Show()
  UI.report.state.tab = "healing"
  UI.report:Refresh()
  local ctx = UI.report:AnnounceContext()
  if ctx.metrics[1] ~= "healing" then
    error("healing tab announced " .. tostring(ctx.metrics[1]))
  end
  UI.report.state.tab = "summary"
  UI.report:Refresh()
  if table.getn(UI.report:AnnounceContext().metrics) ~= 2 then
    error("summary should announce both of its panels")
  end

  -- The meter announces its current metric.
  UI.meter:SetMetric("taken")
  if UI.meter:AnnounceContext().metric ~= "taken" then
    error("meter announced the wrong metric")
  end
  UI.meter:SetMetric("damage")

  -- Opening the picker must not send anything.
  UI.AnnounceMenu(UI.report.frame, UI.report.announceBtn, ctx)
  if table.getn(CHAT) > 0 then error("the channel menu posted to chat") end
  UI.CloseMenu()

  -- Requesting a channel raises the confirmation, still without sending.
  Wrekkit.announce:Request(ctx, "PARTY", nil, 3)
  if table.getn(CHAT) > 0 then
    error("Request posted to chat before the user confirmed")
  end
  if not _G["WrekkitConfirm"]:IsShown() then
    error("no confirmation dialog appeared")
  end

  -- Cancel sends nothing.
  UI.CloseConfirm()
  if table.getn(CHAT) > 0 then error("cancel still posted to chat") end

  -- Only Send does.
  Wrekkit.announce:Request(ctx, "PARTY", nil, 3)
  local dlg = _G["WrekkitConfirm"]
  dlg.sendBtn:GetScript("OnClick")()
  while table.getn(Wrekkit.announce.queue) > 0 do
    local job = table.remove(Wrekkit.announce.queue, 1)
    SendChatMessage(job.msg, job.channel, nil, job.target)
  end
  if table.getn(CHAT) == 0 then error("confirming sent nothing") end
  for _, m in ipairs(CHAT) do
    if m.chan ~= "PARTY" then
      error("sent to " .. tostring(m.chan) .. " instead of PARTY")
    end
  end

  -- A whisper with no name must refuse rather than post somewhere else.
  CHAT = {}
  Wrekkit.announce:Request(ctx, "WHISPER", nil, 2)
  dlg = _G["WrekkitConfirm"]
  dlg.targetBox.editBox:SetText("")
  dlg.sendBtn:GetScript("OnClick")()
  if table.getn(CHAT) > 0 then error("whispered with no target") end
  if not dlg:IsShown() then error("dialog closed despite the missing name") end

  dlg.targetBox.editBox:SetText("Fuff")
  dlg.sendBtn:GetScript("OnClick")()
  while table.getn(Wrekkit.announce.queue) > 0 do
    local job = table.remove(Wrekkit.announce.queue, 1)
    SendChatMessage(job.msg, job.channel, nil, job.target)
  end
  if table.getn(CHAT) == 0 then error("named whisper sent nothing") end
  if CHAT[1].target ~= "Fuff" then
    error("whisper went to " .. tostring(CHAT[1].target))
  end

  UI.CloseConfirm()
  CHAT = {}
  GetNumPartyMembers = realParty
end)

step("unavailable channels are refused", function()
  CHAT = {}
  -- Solo: there is no raid to post to.
  local realRaid = GetNumRaidMembers
  GetNumRaidMembers = function() return 0 end
  Wrekkit.announce:Request(UI.meter:AnnounceContext(), "RAID", nil, 3)
  GetNumRaidMembers = realRaid
  if table.getn(CHAT) > 0 then error("posted to a raid we are not in") end
  if _G["WrekkitConfirm"]:IsShown() then
    error("offered to post to an unavailable channel")
  end
end)

step("every texture path resolves to a real file", function()
  --[[ SetTexture(nil) is silent: in the stub it does nothing, and in the
       client it draws nothing. A missing UI.media key therefore produces an
       invisible icon with no error anywhere -- which is exactly how the
       padlock shipped pointing at nil. Check the table against the disk, and
       check the source against the table. ]]
  local UIm = Wrekkit.ui.media
  for key, path in pairs(UIm) do
    -- The game's own art (a skin's status bar) ships with the client.
    if not string.find(path, "^Interface\\AddOns\\Wrekkit") then path = nil end
    local file = path and string.gsub(path, "^.*\\", "")
    local fh = file and io.open("textures/" .. file .. ".tga", "rb")
    if file and not fh then
      error("UI.media." .. key .. " -> textures/" .. file .. ".tga does not exist")
    end
    if fh then fh:close() end
  end

  -- Every UI.media.<key> mentioned in the source must exist in the table.
  local sources = {
    "ui/widgets.lua", "ui/chart.lua", "ui/meter.lua",
    "ui/report.lua", "ui/confirm.lua", "minimap.lua",
  }
  for _, src in ipairs(sources) do
    local fh = io.open(src, "r")
    if fh then
      local text = fh:read("a")
      fh:close()
      for key in string.gfind(text, "UI%.media%.(%a[%w_]*)") do
        if not UIm[key] then
          error(src .. " uses UI.media." .. key .. ", which is not defined")
        end
      end
    end
  end
end)

step("settings window builds and every control works", function()
  UI.settings:Show()
  local f = UI.settings.frame
  if not f then error("settings window did not build") end
  if table.getn(UI.settings.controls) == 0 then
    error("settings window has no controls to refresh")
  end

  -- Flip every checkbox twice. The first click must CHANGE what is drawn,
  -- and the second must put it back. This loop once flipped without
  -- looking at anything, and three checkboxes that stored false whichever
  -- way they went -- so any click turned the feature off for good -- passed.
  local flipped = 0
  for i, c in ipairs(UI.settings.controls) do
    local fn = c:GetScript("OnClick")
    if fn and c.tick then
      local before = c.tick:IsShown() and true or false
      fn()
      if (c.tick:IsShown() and true or false) == before then
        error("checkbox #" .. i .. " did not change when clicked")
      end
      fn()
      if (c.tick:IsShown() and true or false) ~= before then
        error("checkbox #" .. i .. " did not come back when clicked again")
      end
      flipped = flipped + 1
    elseif fn and c.valueText then
      -- A choice cycles through its options. It must change on the first
      -- click, and clicking on round must bring it back -- which also
      -- leaves every setting as this loop found it.
      local start = c.valueText:GetText()
      fn()
      if c.valueText:GetText() == start then
        error("choice #" .. i .. " (" .. tostring(c.labelText) .. ") did not change when clicked" .. (Wrekkit.lastError and (": " .. Wrekkit.lastError.label .. ": " .. Wrekkit.lastError.err) or ""))
      end
      local clicks = 1
      while c.valueText:GetText() ~= start and clicks < 10 do
        fn()
        clicks = clicks + 1
      end
      if c.valueText:GetText() ~= start then
        error("choice #" .. i .. " never came back round to where it started")
      end
    elseif fn then
      fn() fn()
    end
    -- steppers have no OnClick of their own; nudge their buttons instead
    c:Refresh()
  end
  if flipped < 5 then
    error("expected to flip every checkbox, flipped only " .. flipped)
  end

  UI.settings:Refresh()
  UI.settings:Toggle()
  UI.settings:Toggle()
end)

step("the meter fades or hides itself in combat, if asked", function()
  local m = UI.meter
  local s = m:Settings()
  m:Show()
  local f = m.frame
  local tick = m.watcher and m.watcher:GetScript("OnUpdate")
  if not tick then error("no combat watcher") end

  -- Drive the watcher as the client would, a frame every 50ms. Nothing in
  -- this step fires PLAYER_REGEN_ENABLED: leaving combat is only ever seen
  -- by polling, which is the point -- that event can be missed in-game.
  local function run(seconds)
    for _ = 1, math.floor(seconds / 0.05 + 0.5) do
      NOW = NOW + 0.05
      tick()
    end
  end
  local function near(a, b) return math.abs((a or 0) - b) < 0.001 end
  Wrekkit.lastError = nil

  -- Shown, the default: a fight changes nothing.
  IN_COMBAT = true
  s.combat = "show"
  run(1)
  if not near(f:GetAlpha(), 1) or not f:IsShown() then
    error("the default mode changed the meter in combat")
  end

  -- Faded: dims in a fight, lights up when pointed at, back after.
  s.combat = "fade"
  run(1)
  if not near(f:GetAlpha(), 0.3) then error("fade did not dim the meter: " .. f:GetAlpha()) end
  if not f:IsShown() then error("fade should leave the meter on screen") end
  local hover = false
  MouseIsOver = function(frame) return hover and frame == f end
  hover = true
  run(1)
  if not near(f:GetAlpha(), 1) then error("pointing at the faded meter did not bring it back") end
  hover = false
  run(1)
  if not near(f:GetAlpha(), 0.3) then error("moving away did not fade it again") end
  IN_COMBAT = false
  run(1)
  if not near(f:GetAlpha(), 1) then error("the meter did not come back after the fight") end

  -- Hidden: gone for the fight, back after it, and the saved choice untouched.
  s.combat = "hide"
  IN_COMBAT = true
  run(1)
  if f:IsShown() then error("hide left the meter on screen in combat") end
  if s.shown ~= true then error("hiding for a fight overwrote the saved shown setting") end
  IN_COMBAT = false
  run(1)
  if not f:IsShown() or not near(f:GetAlpha(), 1) then
    error("the meter did not return after the fight")
  end

  -- /wrek in the middle of a fight shows it anyway, until the fight ends.
  IN_COMBAT = true
  run(1)
  m:Toggle()
  run(1)
  if not f:IsShown() or not near(f:GetAlpha(), 1) then
    error("showing it by hand during a fight did not win")
  end
  IN_COMBAT = false
  run(1)
  IN_COMBAT = true
  run(1)
  if f:IsShown() then error("the next fight should hide it again") end

  -- Closed by hand before a fight: stays closed after it.
  IN_COMBAT = false
  run(1)
  m:Hide()
  IN_COMBAT = true
  run(1)
  IN_COMBAT = false
  run(1)
  if f:IsShown() then error("a meter closed by hand came back after a fight") end

  -- Closed by hand WHILE faded: stays closed, and its alpha is put back so
  -- opening it later does not open it faded.
  m:Show()
  s.combat = "fade"
  IN_COMBAT = true
  run(1)
  if not near(f:GetAlpha(), 0.3) then error("expected the meter faded before closing it") end
  m:Hide()
  run(1)
  IN_COMBAT = false
  run(1)
  if f:IsShown() then error("a meter closed mid-fade came back after the fight") end
  if not near(f:GetAlpha(), 1) then error("a meter closed mid-fade was left faded for next time") end

  if Wrekkit.lastError and Wrekkit.lastError.label == "meter combat fade" then
    error("the watcher raised: " .. tostring(Wrekkit.lastError.err))
  end

  s.combat = "show"
  MouseIsOver = nil
  IN_COMBAT = true
  m:Show()
  run(1)
end)

step("compact mode and text size reshape the meter", function()
  local s = UI.meter:Settings()
  UI.meter:Show()

  local normalRows = UI.meter.list.rowHeight
  if not UI.meter.footer:IsShown() then error("footer should be up normally") end

  s.compact = true
  UI.meter:ApplyLayout()
  if UI.meter.footer:IsShown() then error("compact mode should hide the footer") end
  if UI.meter.toolbar:IsShown() then error("compact mode should hide the toolbar") end

  s.compact = false
  UI.meter:ApplyLayout()
  if not UI.meter.footer:IsShown() then error("footer did not come back") end
  if not UI.meter.toolbar:IsShown() then
    error("toolbar preference was lost across compact mode")
  end

  -- Text size has to move the pixel dimensions too, or the letters just clip.
  Wrekkit.db.fontScale = 1.5
  UI.ApplyFontScale()
  UI.meter:ApplyLayout()
  if UI.meter.list.rowHeight <= normalRows then
    error("rows did not grow with the text size")
  end

  Wrekkit.db.fontScale = 0.8
  UI.ApplyFontScale()
  UI.meter:ApplyLayout()
  if UI.meter.list.rowHeight >= normalRows then
    error("rows did not shrink with the text size")
  end

  -- Out-of-range scales must clamp rather than produce blank text.
  Wrekkit.db.fontScale = 99
  if UI.FontScale() > 1.8 then error("font scale did not clamp") end
  Wrekkit.db.fontScale = 0.01
  if UI.FontScale() < 0.7 then error("font scale did not clamp") end

  Wrekkit.db.fontScale = 1.0
  UI.ApplyFontScale()
  UI.meter:ApplyLayout()
end)

step("the segment label is a button", function()
  UI.meter:Show()
  local b = UI.meter.segBtn
  if not b then error("no segment button") end
  UI.meter:Refresh()
  if (b.label:GetText() or "") == "" then
    error("segment button has no label")
  end
  if b:GetWidth() <= 0 then error("segment button was never sized") end

  local fn = b:GetScript("OnClick")
  if not fn then error("segment button has no handler") end
  arg1 = "LeftButton"; fn()
  UI.CloseMenu()
  arg1 = "RightButton"; fn()
  UI.CloseMenu()
  arg1 = nil

  b:GetScript("OnEnter")()
  b:GetScript("OnLeave")()
end)

step("the cog opens settings from both windows", function()
  for _, owner in ipairs({ UI.meter, UI.report }) do
    if not owner.cogBtn then error("a window is missing its cog") end
    local fn = owner.cogBtn:GetScript("OnClick")
    if not fn then error("cog has no handler") end
    fn()
    UI.settings.frame:Hide()
  end
end)

step("minimap button builds", function() Wrekkit.minimap:Update() end)

step("slash commands run", function()
  local run = SlashCmdList["WREKKIT"]
  for _, cmd in ipairs({ "help", "modes", "mode dps", "segment last",
                         "segment overall", "lock", "minimap", "debug",
                         "world", "world", "accept", "accept", "status", "resume", "resume 30",
                         "peers", "sharing on", "sharing off", "channel raid", "channel auto",
                         "group", "group", "who", "keep", "keep", "prune 30", "prune all",
                         "reset", "report", "" }) do
    run(cmd)
  end
  run("debug")
end)


step("reset clears cleanly", function()
  Wrekkit.ResetData("current")
  Wrekkit.ResetData("all")
  UI.meter:Refresh()
  UI.report:Refresh()
end)


--[[ Reported with a screenshot: names truncated to "Sh..." and "Bo..." while
     the damage and per-second columns sat in obvious empty space.

     The name was charged a flat 74px for the value column, but the value is
     right-anchored with no width and auto-sizes to its text, so a short
     figure left the difference as dead space that the name had paid for.
     These measure what the name actually receives. ]]

local function measureRow(width, value, sub, subWidth)
  local parent = CreateFrame("Frame")
  local row = UI.Row(parent, 18)
  row:SetWidth(width)
  row:SetData(1, "Shieldbarbie", value, sub, 0.5, { 1, 1, 1 }, subWidth)
  return row
end

local function assert_(cond, msg)
  if not cond then error(msg, 2) end
end

step("a short value leaves the name more room than a long one", function()
  local short = measureRow(300, "862", "1 dps", 58)
  local long  = measureRow(300, "110.5k", "179 dps", 58)
  assert_(short.name:GetWidth() > long.name:GetWidth(),
    "short=" .. short.name:GetWidth() .. " long=" .. long.name:GetWidth())
end)

step("name gets the bulk of a 300px row", function()
  local r = measureRow(300, "110k", "179 dps", 58)
  assert_(r.name:GetWidth() >= 140, "name got " .. r.name:GetWidth() .. "px")
end)

step("a full name fits at the minimum window width", function()
  -- "Shieldbarbie" is 12 chars, ~72px at the default size in this stub.
  local r = measureRow(260, "110k", "179 dps", 58)
  assert_(r.name:GetWidth() >= 72, "name got " .. r.name:GetWidth() .. "px")
end)

--[[ A row too narrow for everything gives up its per-second column before
     the name, and never holds the name at a floor it has no room for: that
     drew the name over the value, two columns side by side at 70% text. ]]
step("a narrow row makes room for the name, never over the value", function()
  local r = measureRow(120, "110k", "179 dps", 58)
  assert_((r.sub._text or "") == "", "kept the per-second column at 120px")
  assert_(r.name:GetWidth() >= 50, "name got " .. r.name:GetWidth() .. "px")
  local used = 26 + r.name:GetWidth() + r.value:GetStringWidth() + r.sub:GetWidth() + 14
  assert_(used <= 120 + 12, "name runs " .. (used - 120) .. "px into the value")
end)

step("columns fit inside the row without overlapping", function()
  local r = measureRow(300, "110k", "179 dps", 58)
  local used = 26 + r.name:GetWidth() + r.sub:GetWidth()
  assert_(used <= 300, "used " .. used .. "px of 300")
end)

step("the per-second column scales with text size", function()
  local before = measureRow(300, "110k", "179 dps", 58).sub:GetWidth()
  Wrekkit.db.fontScale = 1.5
  local after = measureRow(300, "110k", "179 dps", 58).sub:GetWidth()
  Wrekkit.db.fontScale = 1
  assert_(after > before, "before=" .. before .. " after=" .. after)
end)

--[[ Resizing must not relayout from inside the client's own layout callback.

     OnSizeChanged IS that callback. Doing the relayout inline means calling
     SetPoint and SetWidth on child regions while the layout pass that
     invoked us is still unwinding, and a drag fires it every frame. These
     pin the deferral down so it cannot quietly regress to a direct call. ]]

step("OnSizeChanged does not relayout synchronously", function()
  local win = UI.meter.frame
  local calls = 0
  local realOnResize = win.OnResize
  win.OnResize = function() calls = calls + 1 end

  local handler = win:GetScript("OnSizeChanged")
  if not handler then error("the meter window has no OnSizeChanged") end
  handler()

  local inline = calls
  win.OnResize = realOnResize
  if inline ~= 0 then
    error("OnResize ran inline during OnSizeChanged (" .. inline .. " time(s))")
  end
end)

step("a burst of resizes collapses into a single relayout", function()
  local win = UI.meter.frame
  local calls = 0
  local realOnResize = win.OnResize
  win.OnResize = function() calls = calls + 1 end

  local handler = win:GetScript("OnSizeChanged")
  for _ = 1, 25 do handler() end

  -- Let the deferred work run.
  local ticker = _G["WrekkitTicker"]
  if ticker and ticker:GetScript("OnUpdate") then
    ticker:GetScript("OnUpdate")()
  end

  win.OnResize = realOnResize
  if calls > 1 then
    error("25 size changes produced " .. calls .. " relayouts, expected 1")
  end
end)

--[[ Dragging the grip resizes every frame. Relayouts while it is held are
     rationed to ten a second, and letting go always does a final one. ]]

step("a held resize grip relays out at most ten times a second", function()
  local win = UI.meter.frame
  local calls = 0
  local realOnResize = win.OnResize
  win.OnResize = function() calls = calls + 1 end
  local handler = win:GetScript("OnSizeChanged")
  local ticker = _G["WrekkitTicker"]
  local tick = ticker and ticker:GetScript("OnUpdate")

  win.grip:GetScript("OnDragStart")()
  local t0 = NOW
  -- one simulated second of dragging at 60 frames a second
  for _ = 1, 60 do
    handler()
    NOW = NOW + 1 / 60
    if tick then tick() end
  end
  local during = calls
  win.grip:GetScript("OnDragStop")()
  local after = calls
  win.OnResize = realOnResize

  if during < 2 then error("the window stopped following the drag (" .. during .. " relayouts)") end
  if during > 11 then error(during .. " relayouts in one second of dragging") end
  if after ~= during + 1 then error("letting go of the grip did not relayout") end
  if t0 > NOW then error("clock went backwards") end
end)

--[[ The window's minimum size must leave the list a positive height at every
     text size. It used to be a fixed 260x110 while the title bar, toolbar,
     footer and rows all scale with the text, so at a large setting the
     chrome alone exceeded the minimum and the list frame was handed a
     negative height on every frame of a drag-resize. ]]

step("the minimum height leaves room for the list at any text size", function()
  local win = UI.meter.frame
  for _, scale in ipairs({ 1.0, 1.2, 1.5, 1.8, 2.0 }) do
    for _, compact in ipairs({ false, true }) do
      Wrekkit.db.fontScale = scale
      UI.meter:Settings().compact = compact
      UI.meter:ApplyLayout()

      local minW, minH = win._minW, win._minH
      if not minH then error("SetMinResize was never called") end

      local function px(n) return math.floor(n * scale + 0.5) end
      local chrome = px(compact and 18 or 22)
                   + ((not compact) and px(22) or 0)
                   + (compact and 0 or px(15))
                   + 8
      local listH = minH - chrome
      if listH < 1 then
        error(string.format("scale %.1f compact=%s: list would be %dpx",
          scale, tostring(compact), listH))
      end
    end
  end
  Wrekkit.db.fontScale = 1
  UI.meter:Settings().compact = false
  UI.meter:ApplyLayout()
end)

--[[ The confirmation dialog is one reused frame, so its controls outlive the
     request that configured them. If reseeding the selection does not reach
     the widgets, the dialog shows the PREVIOUS post's ticks while Send does
     something else -- the worst failure available to a confirmation step. ]]

step("the announce dialog reseeds its controls on every open", function()
  local ctxA = { metrics = { "damage" }, encounters = {}, label = "A",
                 filter = {}, petMode = "merge" }
  local ctxB = { metrics = { "healing" }, encounters = {}, label = "B",
                 filter = {}, petMode = "merge" }

  UI.ConfirmAnnounce({ "line" }, "GUILD", nil, function() end, ctxA)
  local dlg
  for _, fr in ipairs(allFrames) do
    if fr._name == "WrekkitConfirm" then dlg = fr end
  end
  if not dlg then error("the dialog was never built") end
  if not dlg.picked.damage then error("damage was not seeded from the view") end

  -- Reopen against a different view.
  UI.CloseConfirm()
  UI.ConfirmAnnounce({ "line" }, "GUILD", nil, function() end, ctxB)

  if dlg.picked.damage then
    error("the previous selection survived into a new request")
  end
  if not dlg.picked.healing then error("healing was not seeded") end

  --[==[ Assert on what is DRAWN. Checking dlg.picked alone passes even
         with the fix reverted, because the state was always reset -- it is
         the widgets that lagged it. ]==]
  for _, chk in ipairs(dlg.metricChecks) do
    local lit = chk.tick and chk.tick:IsShown()
    if chk._metricKey == "damage" and lit then
      error("the damage tick is still lit from the previous request")
    end
    if chk._metricKey == "healing" and not lit then
      error("the healing tick was never lit for this request")
    end
  end
  UI.CloseConfirm()
end)

--[[ The checkboxes were built and reseeded by tests, but never CLICKED - and a
     click is the only thing that runs the getter and setter closures. That is
     the path reported as "error in announce menu ... attempt to index a nil
     value" at confirm.lua:140, which is the getter. ]]
step("clicking a metric checkbox in the announce dialog", function()
  local ctx = { metrics = { "damage" }, encounters = {}, label = "A",
                filter = {}, petMode = "merge" }
  UI.ConfirmAnnounce({ "line" }, "GUILD", nil, function() end, ctx)

  local dlg
  for _, fr in ipairs(allFrames) do
    if fr._name == "WrekkitConfirm" then dlg = fr end
  end
  if not dlg then error("the dialog was never built") end

  local clicked = 0
  for _, chk in ipairs(dlg.metricChecks) do
    local onclick = chk._scripts and chk._scripts.OnClick
    if onclick then
      onclick()
      clicked = clicked + 1
    end
  end
  if clicked == 0 then error("no checkbox had an OnClick to drive") end
  UI.CloseConfirm()
end)

--[[ The version the addon reports has to be the version that shipped.

     /wrek status is the first thing asked for in a bug report, and it named
     0.1.0 for days after the .toc said 0.1.1, because the number was written
     out a second time in core.lua. A wrong version does not just misinform --
     it sends the search after the wrong source. ]]
step("the reported version is the one in the .toc", function()
  local shipped = GetAddOnMetadata("Wrekkit", "Version")
  if not shipped then error("could not read the version out of the .toc") end
  if Wrekkit.version ~= shipped then
    error("the addon reports " .. tostring(Wrekkit.version) ..
          " but the .toc ships " .. shipped)
  end
end)

--[[ The reported crash was "attempt to index a nil value" in the checkbox
     getter, which can only mean the state it reads was not there when a tick
     refreshed. Nothing offline reproduced HOW it went missing, so the state
     moved off the frame and into the module, and this asserts the property
     that makes the how irrelevant: clear the frame's field entirely and the
     picker still refreshes, still takes clicks, and still reseeds.

     Note the lastError check. UI.Check runs its click inside W.Guard, so a
     getter that throws on click does not fail a test that only calls it --
     it prints and carries on. That is how this class of bug hides. ]]
step("the picker does not depend on a field of the dialog frame", function()
  local ctx = { metrics = { "damage" }, encounters = {}, label = "A",
                filter = {}, petMode = "merge" }
  UI.ConfirmAnnounce({ "line" }, "GUILD", nil, function() end, ctx)
  local dlg = _G["WrekkitConfirm"]
  if not dlg then error("the dialog was never built") end

  Wrekkit.ClearErrors()
  dlg.picked = nil
  dlg.count = nil
  for _, chk in ipairs(dlg.metricChecks) do chk:Refresh() end
  for _, chk in ipairs(dlg.metricChecks) do chk:GetScript("OnClick")() end
  if dlg.Rebuild then dlg:Rebuild() end
  if Wrekkit.lastError then
    error("a guarded handler swallowed: " .. tostring(Wrekkit.lastError.err))
  end
  UI.CloseConfirm()

  -- And a fresh request must still seed and draw correctly afterwards.
  UI.ConfirmAnnounce({ "line" }, "GUILD", nil, function() end,
    { metrics = { "healing" }, encounters = {}, label = "B",
      filter = {}, petMode = "merge" })
  for _, chk in ipairs(dlg.metricChecks) do
    local lit = chk.tick and chk.tick:IsShown()
    if chk._metricKey == "healing" and not lit then
      error("healing was not lit once the frame field was gone")
    end
    if chk._metricKey == "damage" and lit then
      error("damage stayed lit once the frame field was gone")
    end
  end
  UI.CloseConfirm()
end)

--[[ Half-configured is worse than closed. If anything between "build" and
     "show" fails, the dialog must not be left on screen describing the
     request BEFORE this one -- a confirmation that states the wrong
     destination or the wrong lines is the exact accident it exists to stop. ]]
step("a failed open leaves the dialog down, not showing the last request", function()
  local ctx = { metrics = { "damage" }, encounters = {}, label = "A",
                filter = {}, petMode = "merge" }
  UI.ConfirmAnnounce({ "line" }, "GUILD", nil, function() end, ctx)
  local dlg = _G["WrekkitConfirm"]
  if not dlg:IsShown() then error("the dialog did not open at all") end

  local realSetText = dlg.who.SetText
  dlg.who.SetText = function() error("broken on purpose") end
  local ok = pcall(UI.ConfirmAnnounce, { "other" }, "SAY", nil, function() end, ctx)
  dlg.who.SetText = realSetText
  if ok then error("the sabotaged open did not fail") end
  if dlg:IsShown() then
    error("the dialog is still up, still describing the previous request")
  end
end)

--[[ The picker is hidden on purpose for a drilldown, and that is the only
     reason it should ever be missing. Assert both halves, because "no option
     to choose what to announce" is indistinguishable, on screen, from the
     dialog failing to lay itself out. ]]
step("the picker shows for a view and hides for a drilldown", function()
  local base = { metrics = { "damage" }, encounters = {}, label = "A",
                 filter = {}, petMode = "merge" }
  UI.ConfirmAnnounce({ "line" }, "GUILD", nil, function() end, base)
  local dlg = _G["WrekkitConfirm"]
  for _, chk in ipairs(dlg.metricChecks) do
    if not chk:IsShown() then error("the picker is missing for a plain view") end
  end
  if not dlg.countStepper:IsShown() then error("Top N is missing for a plain view") end
  UI.CloseConfirm()

  local drilled = { metrics = { "damage" }, encounters = {}, label = "A",
                    filter = {}, petMode = "merge", drill = "Salahaja" }
  UI.ConfirmAnnounce({ "line" }, "GUILD", nil, function() end, drilled)
  for _, chk in ipairs(dlg.metricChecks) do
    if chk:IsShown() then error("the picker is offered for a drilldown") end
  end
  UI.CloseConfirm()
end)

----------------------------------------------------------------------
-- hover details on a meter row
----------------------------------------------------------------------

--[[ The reset step above clears everything, so these make their own pull
     rather than relying on data an earlier test happened to leave behind. ]]
local function makePull(seconds)
  Wrekkit.encounter:CombatStart()
  for i = 1, (seconds or 6) do
    fire("AUTO_ATTACK_SELF", "0xA", "0xBoss", 250, 0, 0, 1, 0, 0, 0)
    fire("SPELL_DAMAGE_EVENT_OTHER", "0xA", "0xBoss", 200, 400, "20,0,0", 0, 0)
    fire("SPELL_DAMAGE_EVENT_OTHER", "0xA", "0xBoss", 100, 150, "0,0,0", 0, 0)
    fire("AUTO_ATTACK_OTHER", "0xP", "0xBoss", 90, 0, 0, 1, 0, 0, 0)
    fire("SPELL_HEAL_BY_OTHER", "0xA", "0xB", 500, 300, 0, 0)
    NOW = NOW + 1
  end
  Wrekkit.encounter:CombatEnd()
  Wrekkit.encounter:Finish()
  -- The pull as the report will see it: read back out of history, which is
  -- a different table from the one just recorded.
  local session = Wrekkit.report:CurrentSession()
  local list = (session and session.encounters) or {}
  return list[table.getn(list)]
end

step("a new session starting does not change the pulls being looked at", function()
  makePull(8)
  local picked = makePull(8)
  if not picked then error("no pull recorded") end
  UI.report:Show()
  UI.report.state.sessionId = nil
  UI.report.state.sessionIndex = 1
  UI.report.state.selected = { [tostring(picked.sessionId) .. ":" .. tostring(picked.id)] = true }
  UI.report:Refresh()
  local before = UI.report:SelectedEncounters()

  -- Somewhere new: the newest session is now a different one.
  NOW = NOW + 4000
  Wrekkit.encounter:StartNewSession()
  makePull(8)
  UI.report:Refresh()

  local after, all = UI.report:SelectedEncounters()
  UI.report.frame:Hide()
  if all then error("the picked pull was dropped for the whole session") end
  if table.getn(after) ~= 1 or after[1].id ~= picked.id or after[1].sessionId ~= picked.sessionId then
    error("the report now shows a different pull")
  end
  if table.getn(before) ~= 1 then error("the pick did not take") end
  UI.report.state.selected = {}
  UI.report.state.sessionId = nil
end)

local function meterRows()
  -- An earlier step may have left the meter hidden, and RefreshInner does
  -- nothing at all for a hidden window.
  UI.meter:Show()
  UI.meter:Refresh()
  local out = {}
  for _, row in ipairs(UI.meter.list.rows or {}) do
    if row:IsShown() and row.name and row.name:GetText() ~= "" then
      table.insert(out, row)
    end
  end
  return out
end

local function hover(row)
  row:GetScript("OnEnter")()
end

step("hovering a meter row breaks the number down by ability", function()
  makePull()
  UI.meter:Settings().segment = "all"
  UI.meter.drill = nil
  UI.meter:SetMetric("damage")
  UI.meter:Refresh()

  local rows = meterRows()
  if table.getn(rows) == 0 then error("the meter has no rows to hover") end
  local row = rows[1]
  local shown = row.name:GetText()

  hover(row)
  if not GameTooltip.shown then error("hovering showed no tooltip") end
  if GameTooltip.owner ~= row then error("the tooltip is not owned by the row") end
  if not GameTooltipText(shown) then
    error("the tooltip does not name who it is about")
  end
  if not GameTooltipText("Details:") then
    error("no ability breakdown: " .. table.concat(GameTooltip.lines, " | "))
  end
end)

--[[ Two ways to total the same row would drift, and the one nobody is looking
     at would be the wrong one. The tooltip must quote the row, not recompute. ]]
step("the tooltip total is the number on the bar", function()
  UI.meter.drill = nil
  UI.meter:SetMetric("damage")
  UI.meter:Refresh()
  local row = meterRows()[1]
  local onBar = row.value:GetText()

  hover(row)
  if not GameTooltipText(onBar) then
    error("the bar says " .. tostring(onBar) .. " and the tooltip does not: " ..
      table.concat(GameTooltip.lines, " | "))
  end
end)

step("each ability line carries its share", function()
  UI.meter.drill = nil
  UI.meter:SetMetric("damage")
  UI.meter:Refresh()
  hover(meterRows()[1])

  local pct = false
  for _, l in ipairs(GameTooltip.lines) do
    if string.find(l, "%%%)") then pct = true end
  end
  if not pct then
    error("no percentages: " .. table.concat(GameTooltip.lines, " | "))
  end
end)

step("hovering still highlights the row", function()
  UI.meter.drill = nil
  UI.meter:Refresh()
  local row = meterRows()[1]
  hover(row)
  if not row.hl then error("the row lost its highlight texture") end
  row:GetScript("OnLeave")()
  if GameTooltip.shown then error("the tooltip stayed up after leaving") end
end)

step("picking players filters the meter and the report", function()
  local m = UI.meter
  local s = m:Settings()
  Wrekkit.report:ClearPicks()
  s.pickedOnly = false
  m.drill = nil
  m:SetMetric("damage")
  local rows = meterRows()
  if table.getn(m.list.data) < 2 then error("need two players on the meter to pick from") end

  local function shiftClick(row)
    IsShiftKeyDown = function() return true end
    arg1 = "LeftButton"
    row:GetScript("OnClick")()
    IsShiftKeyDown = nil
  end
  local function menuRow(menu, text)
    for _, r in ipairs(menu.rows or {}) do
      if r:IsShown() and r.label:GetText() == text then return r end
    end
    return nil
  end

  -- Nobody picked: the toggle refuses to filter to nobody.
  arg1 = "LeftButton"
  m.pickBtn:GetScript("OnClick")()
  if s.pickedOnly then error("the toggle switched on with nobody picked") end

  -- Shift-click picks, and does not open the player.
  local target = m.list.data[1]
  local who = target.ownerName or target.name
  shiftClick(rows[1])
  if not Wrekkit.report:IsPicked(who) then error("shift-click did not pick " .. tostring(who)) end
  if m.drill then error("shift-click opened the player instead of picking them") end
  rows = meterRows()
  if not string.find(rows[1].name:GetText() or "", ">", 1, true) then
    error("a picked player is not marked in the list")
  end

  -- On: only the picked player shows, and the mark goes (every row is one).
  arg1 = "LeftButton"
  m.pickBtn:GetScript("OnClick")()
  if not s.pickedOnly or not m.pickBtn._lit then error("the toggle did not switch on and light") end
  rows = meterRows()
  if table.getn(m.list.data) ~= 1 then
    error("filtering kept " .. table.getn(m.list.data) .. " rows, want 1")
  end
  if string.find(rows[1].name:GetText() or "", ">", 1, true) then
    error("rows are still marked while only picks are shown")
  end

  -- The report shares the picks; its own switch filters its tables.
  UI.report:Show()
  UI.report.state.tab = "damage"
  UI.report.state.drill = nil
  UI.report:Refresh()
  local everyone = table.getn(UI.report.mainList.data)
  arg1 = "LeftButton"
  UI.report.pickBtn:GetScript("OnClick")()
  if not UI.report.state.pickedOnly then error("the report's toggle did not switch on") end
  if table.getn(UI.report.mainList.data) ~= 1 then
    error("the report kept " .. table.getn(UI.report.mainList.data) .. " of " .. everyone .. " rows")
  end

  -- Right-click lists the picks. Unpicking one of two keeps the menu open;
  -- clearing switches both windows' filters off.
  local second = nil
  for _, r in ipairs(UI.report.mainList.data) do second = r end
  Wrekkit.report:TogglePick("Elfpriest")
  UI.PicksChanged()
  arg1 = "RightButton"
  m.pickBtn:GetScript("OnClick")()
  local menu = UI.PickMenu(m.frame, m.pickBtn)
  local elf = menuRow(menu, "Elfpriest")
  if not elf then error("the pick menu does not list a picked player") end
  elf:GetScript("OnClick")()
  if Wrekkit.report:IsPicked("Elfpriest") then error("unpicking from the menu did not unpick") end
  menu = UI.PickMenu(m.frame, m.pickBtn)
  local clear = menuRow(menu, "Clear all picks")
  if not clear then error("the pick menu has no Clear all picks") end
  clear:GetScript("OnClick")()
  if Wrekkit.report:AnyPicked() then error("Clear all picks left someone picked") end
  if s.pickedOnly or UI.report.state.pickedOnly then
    error("with nobody picked, the filters should have switched off")
  end
  if m.pickBtn._lit then error("the toggle stayed lit with nobody picked") end
  meterRows()
  if table.getn(m.list.data) < 2 then error("the meter did not go back to everyone") end

  -- Enemies cannot be picked: shift-click on one is an ordinary click.
  m:SetMetric("enemy")
  rows = meterRows()
  if rows[1] then shiftClick(rows[1]) end
  if Wrekkit.report:AnyPicked() then error("an enemy was picked") end

  m.drill = nil
  m:SetMetric("damage")
  UI.report.state.tab = "summary"
  if UI.report.frame then UI.report.frame:Hide() end
  UI.CloseMenu()
  arg1 = nil
end)

--[[ Rows are reused between modes. A drilled row still carrying the actor
     tooltip would describe someone who is not in the list any more. ]]
step("drilling in clears the actor tooltip from reused rows", function()
  UI.meter.drill = nil
  UI.meter:SetMetric("damage")
  UI.meter:Refresh()
  local row = meterRows()[1]
  if not row.tip then error("an actor row has no tooltip to begin with") end

  row:GetScript("OnClick")()          -- drill into that actor
  UI.meter:Refresh()
  for _, r in ipairs(meterRows()) do
    if r.tip then
      error("an ability row kept the tooltip of the actor it replaced")
    end
  end
  UI.meter.drill = nil
  UI.meter:Refresh()
end)

--[[ The meter repaints twice a second. Frozen numbers under the cursor are
     worst exactly when someone is watching a pull happen. ]]
step("a repaint while hovering rebuilds the tooltip", function()
  UI.meter.drill = nil
  UI.meter:Refresh()
  local row = meterRows()[1]
  hover(row)
  local before = table.getn(GameTooltip.lines)
  if before == 0 then error("nothing in the tooltip to begin with") end

  GameTooltip.lines = {}
  UI.meter:Refresh()
  if table.getn(GameTooltip.lines) == 0 then
    error("the tooltip was not rebuilt and is now showing nothing")
  end
end)

step("a row with no ability detail says so instead of nothing", function()
  UI.meter.drill = nil
  UI.meter:SetMetric("deaths")
  UI.meter:Refresh()
  local rows = meterRows()
  if table.getn(rows) > 0 then
    hover(rows[1])
    if table.getn(GameTooltip.lines) < 2 then
      error("an empty breakdown produced a bare tooltip")
    end
  end
  UI.meter:SetMetric("damage")
  UI.meter:Refresh()
end)

step("every metric can be hovered without erroring", function()
  UI.meter.drill = nil
  for _, m in ipairs(Wrekkit.metrics.list) do
    UI.meter:SetMetric(m.key)
    UI.meter:Refresh()
    for _, row in ipairs(meterRows()) do
      if row.tip then hover(row) end
    end
  end
  UI.meter:SetMetric("damage")
  UI.meter:Refresh()
end)

----------------------------------------------------------------------
-- picking one of the last few pulls
----------------------------------------------------------------------

local function segmentItems()
  local found
  local realMenu = UI.Menu
  UI.Menu = function(parent, anchor, items, onPick, width)
    found = items
    return realMenu(parent, anchor, items, onPick, width)
  end
  UI.meter:SegmentMenu(UI.meter.frame.bar)
  UI.Menu = realMenu
  UI.CloseMenu()
  return found or {}
end

local function itemFor(items, value)
  for _, it in ipairs(items) do
    if it.value == value then return it end
  end
  return nil
end

step("the segment menu offers the last few pulls one at a time", function()
  Wrekkit.ResetData("all")
  for _ = 1, 6 do makePull(8) end

  local items = segmentItems()
  for _, value in ipairs({ "current", "last", "back2", "back3", "back4", "overall" }) do
    if not itemFor(items, value) then
      error("no menu entry for " .. value)
    end
  end
  -- and no further back than it says it goes
  if itemFor(items, "back5") then
    error("offered a pull beyond PAST_PULLS")
  end
end)

--[[ "3rd to last" is only an answer if you remember what the third to last
     pull was, and after a run of wipes on two bosses nobody does. ]]
step("each pull entry says which pull it is", function()
  Wrekkit.ResetData("all")
  for _ = 1, 4 do makePull(8) end

  local items = segmentItems()
  local entry = itemFor(items, "back2")
  local enc = UI.meter:PullBack(2)
  if not enc then error("no second-to-last pull to check against") end
  if not string.find(entry.text, enc.name, 1, true) then
    error("entry reads '" .. entry.text .. "' and names no pull")
  end
end)

step("only pulls that exist are offered", function()
  Wrekkit.ResetData("all")
  makePull(8)
  makePull(8)

  local items = segmentItems()
  if not itemFor(items, "last") then error("no entry for the last pull") end
  if not itemFor(items, "back2") then error("no entry for the one before it") end
  if itemFor(items, "back3") then
    error("offered a third pull back when only two exist")
  end
end)

step("picking a pull shows that pull", function()
  Wrekkit.ResetData("all")
  for _ = 1, 5 do makePull(8) end

  local third = UI.meter:PullBack(3)
  UI.meter:Settings().segment = "back3"
  local encounters, label = UI.meter:Encounters()
  if table.getn(encounters) ~= 1 then
    error("expected one encounter, got " .. table.getn(encounters))
  end
  if encounters[1] ~= third then error("showed the wrong pull") end
  if label ~= third.name then
    error("the title says " .. tostring(label) .. " for " .. tostring(third.name))
  end
  UI.meter:Settings().segment = "current"
end)

--[[ A segment survives in saved settings; the pull it pointed at does not.
     Showing an empty window then reads as the addon being broken. ]]
step("a pull that no longer exists falls back, and the title says so", function()
  Wrekkit.ResetData("all")
  for _ = 1, 4 do makePull(8) end
  UI.meter:Settings().segment = "back4"
  if table.getn(UI.meter:Encounters()) ~= 1 then error("no pull to start with") end

  -- A new log: that pull is gone.
  Wrekkit.ResetData("all")
  makePull(8)
  local encounters, label = UI.meter:Encounters()
  if table.getn(encounters) ~= 1 then
    error("showed nothing rather than falling back")
  end
  if label ~= encounters[1].name then
    error("the title claims " .. tostring(label) .. " while showing " ..
      tostring(encounters[1].name))
  end
  UI.meter:Settings().segment = "current"
end)

step("last still means the newest pull", function()
  Wrekkit.ResetData("all")
  for _ = 1, 3 do makePull(8) end
  UI.meter:Settings().segment = "last"
  local encounters = UI.meter:Encounters()
  local newest = UI.meter:PullBack(1)
  if not newest then error("no pulls were recorded at all") end
  if encounters[1] ~= newest then
    error("'last' is not the most recent pull any more")
  end
  UI.meter:Settings().segment = "current"
end)

step("every segment renders without erroring", function()
  Wrekkit.ResetData("all")
  for _ = 1, 6 do makePull(8) end
  for _, seg in ipairs({ "current", "last", "back2", "back3", "back4",
                         "back5", "overall", "nonsense" }) do
    UI.meter:Settings().segment = seg
    UI.meter:Show()
    UI.meter:Refresh()
  end
  UI.meter:Settings().segment = "current"
  UI.meter:Refresh()
end)

----------------------------------------------------------------------
-- boss pulls in the report
----------------------------------------------------------------------

local function scopeItems()
  local found
  local realMenu = UI.Menu
  UI.Menu = function(parent, anchor, items, onPick, width)
    found = { items = items, pick = onPick }
    return realMenu(parent, anchor, items, onPick, width)
  end
  UI.report:ScopeMenu()
  UI.Menu = realMenu
  UI.CloseMenu()
  return found or { items = {}, pick = function() end }
end

local function pickScope(value)
  local menu = scopeItems()
  menu.pick(value)
end

--[[ A raid night: two attempts at one boss, a second boss, and trash in
     between -- which is the shape the whole feature exists for. ]]
local function raidNight()
  Wrekkit.ResetData("all")
  UI.report.state.selected = {}
  UI.report.state.scope = nil
  UI.report.state.sessionIndex = 1
  UI.report.state.sessionId = nil
  makePull(8)                                   -- trash
  local a = makePull(8)
  local b = makePull(8)
  local c = makePull(8)
  local session = Wrekkit.report:CurrentSession()
  local list = session.encounters
  --[[ Marked by hand, both ways. The harness fights one 100k-health dummy,
       so detection would call every pull a boss; what is under test here is
       selecting them, not spotting them. ]]
  Wrekkit.SetBoss(list[1], false)
  list[2].name = "Ragnaros"  Wrekkit.SetBoss(list[2], true)
  list[3].name = "Ragnaros"  Wrekkit.SetBoss(list[3], true)
  list[4].name = "Majordomo" Wrekkit.SetBoss(list[4], true)
  UI.report:Show()
  UI.report:Refresh()
  return list
end

step("the scope menu lists every boss in the session", function()
  raidNight()
  local items = scopeItems().items
  local seen = {}
  for _, it in ipairs(items) do
    if it.value then seen[it.value] = it.text end
  end
  for _, v in ipairs({ "all", "bosses", "trash", "boss:Ragnaros", "boss:Majordomo" }) do
    if not seen[v] then error("no menu entry for " .. v) end
  end
  -- Two attempts at Ragnaros, one at Majordomo.
  if not string.find(seen["boss:Ragnaros"], "2 pulls", 1, true) then
    error("Ragnaros entry reads '" .. seen["boss:Ragnaros"] .. "'")
  end
end)

step("bosses only selects the bosses and nothing else", function()
  local list = raidNight()
  pickScope("bosses")
  local picked = UI.report:SelectedEncounters()
  if table.getn(picked) ~= 3 then
    error("selected " .. table.getn(picked) .. " pulls, expected 3 bosses")
  end
  for _, enc in ipairs(picked) do
    if not Wrekkit.IsBoss(enc) then error("trash crept into the boss selection") end
  end
end)

step("trash only is the other half", function()
  local list = raidNight()
  pickScope("trash")
  local picked = UI.report:SelectedEncounters()
  if table.getn(picked) ~= 1 then
    error("selected " .. table.getn(picked) .. " pulls, expected 1 trash")
  end
  if Wrekkit.IsBoss(picked[1]) then error("a boss was picked as trash") end
end)

--[[ Singling one boss out means every attempt at it, wipes included: the
     comparison anyone asking about a boss actually wants. ]]
step("one boss means all of its attempts", function()
  raidNight()
  pickScope("boss:Ragnaros")
  local picked = UI.report:SelectedEncounters()
  if table.getn(picked) ~= 2 then
    error("selected " .. table.getn(picked) .. " attempts, expected 2")
  end
  for _, enc in ipairs(picked) do
    if enc.name ~= "Ragnaros" then error("picked up " .. tostring(enc.name)) end
  end
end)

step("all encounters goes back to the whole night", function()
  local list = raidNight()
  pickScope("bosses")
  pickScope("all")
  local picked, isAll = UI.report:SelectedEncounters()
  if not isAll then error("did not return to the whole session") end
  if table.getn(picked) ~= table.getn(list) then
    error("got " .. table.getn(picked) .. " of " .. table.getn(list))
  end
end)

--[[ An empty selection already means "everything" everywhere else, so a scope
     that matches nothing must refuse rather than quietly show the whole night
     under a heading that says Bosses. ]]
step("a scope that matches nothing changes nothing", function()
  Wrekkit.ResetData("all")
  UI.report.state.selected = {}
  local only = makePull(8)
  Wrekkit.SetBoss(only, false)
  UI.report:Show()
  UI.report:Refresh()

  local before = table.getn(UI.report:SelectedEncounters())
  local ok = UI.report:SelectBosses()
  if ok then error("claimed to select bosses when there are none") end
  local after, isAll = UI.report:SelectedEncounters()
  if not isAll or table.getn(after) ~= before then
    error("the selection moved anyway")
  end
end)

step("the button says what is being shown", function()
  raidNight()
  pickScope("bosses")
  if UI.report.allBtn.label:GetText() ~= "Bosses" then
    error("button reads '" .. tostring(UI.report.allBtn.label:GetText()) .. "'")
  end
  pickScope("all")
  if UI.report.allBtn.label:GetText() ~= "All encounters" then
    error("button did not go back: " .. tostring(UI.report.allBtn.label:GetText()))
  end
end)

step("marking from the menu flips the selected pulls", function()
  local list = raidNight()
  pickScope("trash")
  local trash = UI.report:SelectedEncounters()[1]
  if Wrekkit.IsBoss(trash) then error("started out as a boss") end
  pickScope("mark")
  if not Wrekkit.IsBoss(trash) then error("marking did nothing") end
  pickScope("mark")
  if Wrekkit.IsBoss(trash) then error("unmarking did nothing") end
end)

step("the sidebar says which pulls are bosses", function()
  raidNight()
  UI.report:RefreshSidebar()
  local marked = 0
  for _, row in ipairs(UI.report.encList.rows or {}) do
    if row:IsShown() and row.meta and string.find(row.meta:GetText() or "", "BOSS", 1, true) then
      marked = marked + 1
    end
  end
  if marked < 1 then error("no row in the sidebar says BOSS") end
end)

step("every scope renders without erroring", function()
  raidNight()
  for _, v in ipairs({ "all", "bosses", "trash", "boss:Ragnaros",
                       "boss:Majordomo", "boss:Nobody", "mark", "all" }) do
    pickScope(v)
    for _, tab in ipairs(UI.report.tabs) do
      UI.report.state.tab = tab.key
      UI.report:Refresh()
    end
  end
  UI.report.state.tab = "summary"
  pickScope("all")
end)


--- The opacity a window is drawn at: its flat panel's alpha, or under a
--- skin, its backdrop border's (the backdrop carries opacity there).
local function drawnAlpha(f)
  if f._skinned then return f._bdBorderA or 1 end
  return f.bg._a or 1
end

--[[ Opacity fades the CHROME only.

     frame:SetAlpha would have been one line, and wrong: it fades everything
     inside the frame too, so at the setting people actually want -- a meter
     thin enough to see a boss through -- the names and numbers are equally
     thin and the meter stops being readable. These pin that down. ]]

step("window opacity fades the panel, bar and border", function()
  local win = UI.meter.frame
  if not win.SetOpacity then error("UI.Window has no SetOpacity") end

  win:SetOpacity(0.4)
  local function alphaOf(tex, what)
    if not tex then error("no " .. what .. " texture to fade") end
    if tex._a == nil then error(what .. " alpha was never set") end
    return tex._a
  end

  if win._skinned then
    if math.abs(drawnAlpha(win) - 0.4) > 0.001 then
      error("skinned backdrop alpha is " .. tostring(drawnAlpha(win)))
    end
  else
  if math.abs(alphaOf(win.bg, "panel") - 0.4) > 0.001 then
    error("panel alpha is " .. tostring(win.bg._a))
  end
  if math.abs(alphaOf(win.barBg, "title bar") - 0.4) > 0.001 then
    error("title bar alpha is " .. tostring(win.barBg._a))
  end
  end
  -- Skinned, the hairline edges are hidden; the backdrop is the border.
  for _, e in ipairs((not win._skinned) and win.edges or {}) do
    if math.abs((e._a or 1) - 0.4) > 0.001 then
      error("a border edge is at " .. tostring(e._a))
    end
  end
  win:SetOpacity(1)
end)

step("opacity keeps the colour, it only changes alpha", function()
  local win = UI.meter.frame
  win:SetOpacity(0.3)
  local r, g, b = win.bg._r, win.bg._g, win.bg._b
  if r == nil then error("the panel colour was lost") end
  win:SetOpacity(1)
  if win.bg._r ~= r or win.bg._g ~= g or win.bg._b ~= b then
    error("the colour changed when only the alpha should have")
  end
end)

step("opacity never fades the text", function()
  local win = UI.meter.frame
  -- The frame's own alpha must stay untouched: that is what would drag the
  -- names and numbers down with the background.
  local before = win:GetAlpha()
  win:SetOpacity(0.25)
  if win:GetAlpha() ~= before then
    error("SetOpacity changed the frame alpha, which fades the text too")
  end
  win:SetOpacity(1)
end)

step("opacity is clamped and survives a nil", function()
  local win = UI.meter.frame
  win:SetOpacity(5)    if win._opacity ~= 1 then error("not clamped high") end
  win:SetOpacity(-2)   if win._opacity ~= 0 then error("not clamped low") end
  win:SetOpacity(nil)  if win._opacity ~= 1 then error("nil did not mean opaque") end
end)

step("the meter applies its saved opacity on layout", function()
  UI.meter:Settings().opacity = 0.5
  UI.meter:ApplyLayout()
  if math.abs(drawnAlpha(UI.meter.frame) - 0.5) > 0.001 then
    error("ApplyLayout did not apply the setting: " ..
      tostring(drawnAlpha(UI.meter.frame)))
  end
  UI.meter:Settings().opacity = 1
  UI.meter:ApplyLayout()
end)

--[[ The opacity bar. A slider that writes its setting from OnValueChanged,
     and refreshes itself by calling SetValue, will re-enter: SetValue fires
     OnValueChanged, which calls set(), which is what asked for the refresh.
     These check the value reaches the setting and the loop does not form. ]]

step("dragging the opacity bar changes the setting", function()
  UI.settings:Create()
  local bar
  for _, c in ipairs(UI.settings.controls) do
    -- The meter's, by name: other tabs have sliders of their own.
    if c.slider and c.label == "Meter opacity" and not bar then bar = c end
  end
  if not bar then error("no slider was built in the settings window") end

  UI.meter:Settings().opacity = 1
  bar:Refresh()

  bar.slider:SetValue(40)
  local got = UI.meter:Settings().opacity
  if math.abs(got - 0.40) > 0.001 then
    error("opacity is " .. tostring(got) .. ", expected 0.40")
  end
end)

step("the bar refreshes from the setting without writing back", function()
  local bar
  for _, c in ipairs(UI.settings.controls) do
    -- The meter's, by name: other tabs have sliders of their own.
    if c.slider and c.label == "Meter opacity" and not bar then bar = c end
  end

  UI.meter:Settings().opacity = 0.7
  local writes = 0
  local realApply = UI.meter.ApplyLayout
  UI.meter.ApplyLayout = function(self) writes = writes + 1 end

  bar:Refresh()
  UI.meter.ApplyLayout = realApply

  -- Refresh reads the setting. If it wrote back through set(), the value
  -- would have been quantised and re-applied -- a loop waiting to happen.
  if writes > 0 then
    error("Refresh wrote back to the setting " .. writes .. " time(s)")
  end
  if math.abs(UI.meter:Settings().opacity - 0.7) > 0.001 then
    error("Refresh changed the setting it was only meant to read")
  end
end)

step("the bar clamps and quantises like the client", function()
  local bar
  for _, c in ipairs(UI.settings.controls) do
    -- The meter's, by name: other tabs have sliders of their own.
    if c.slider and c.label == "Meter opacity" and not bar then bar = c end
  end
  bar.slider:SetValue(500)
  if UI.meter:Settings().opacity > 1.0 then error("not clamped high") end
  bar.slider:SetValue(-100)
  if UI.meter:Settings().opacity < 0.20 then error("not clamped to the floor") end
  UI.meter:Settings().opacity = 1
  bar:Refresh()
end)

--[[ The settings window must fit the screen at every text size.

     In one column it did not: 478px at the default and 777px at 180%, on a
     768px screen, with the bottom controls unreachable and no way to scroll
     to them. Two columns halve it. This guards the property rather than the
     number, so adding settings later fails here instead of in the game. ]]

step("the settings window fits the screen at any text size", function()
  local realScale = Wrekkit.db.fontScale
  for _, scale in ipairs({ 1.0, 1.2, 1.5, 1.8 }) do
    Wrekkit.db.fontScale = scale
    UI.ApplyFontScale()

    -- Rebuild from scratch: the window sizes itself while stacking.
    UI.settings.frame = nil
    local win = UI.settings:Create()
    local h = win:GetHeight() or 0

    if h <= 0 then error("the settings window has no height at " .. scale .. "x") end
    if h > 700 then
      error(string.format("%.1fx text makes it %dpx tall, past a 768px screen",
        scale, h))
    end
  end
  Wrekkit.db.fontScale = realScale
  UI.ApplyFontScale()
end)

step("every settings tab fits the screen, and shows only its own controls", function()
  local realScale = Wrekkit.db.fontScale
  for _, scale in ipairs({ 1.0, 1.8 }) do
    Wrekkit.db.fontScale = scale
    UI.ApplyFontScale()
    UI.settings.frame = nil
    UI.settings:Create()
    for _, t in ipairs(UI.settings.TABS) do
      local tab = t[1]
      UI.settings:SetTab(tab)
      local h = UI.settings.frame:GetHeight() or 0
      if h <= 0 or h > 700 then
        error(string.format("%s tab is %dpx tall at %.1fx", tab, h, scale))
      end
      local shown = 0
      for _, item in ipairs(UI.settings.items) do
        local want = (item.tab or "meter") == tab
        if want then shown = shown + 1 end
        if (item.control:IsShown() and true or false) ~= want then
          error("a " .. tostring(item.tab) .. " control is " ..
            (want and "hidden" or "shown") .. " on the " .. tab .. " tab")
        end
      end
      if shown == 0 then error("the " .. tab .. " tab is empty") end
    end
  end
  UI.settings:SetTab("meter")
  Wrekkit.db.fontScale = realScale
  UI.ApplyFontScale()
  UI.settings.frame = nil
  UI.settings:Create()
end)

step("each window's opacity reaches its frame", function()
  UI.report:Show()
  UI.SetReportOpacity(0.4)
  if math.abs(drawnAlpha(UI.report.frame) - 0.4) > 0.001 then
    error("report opacity not applied: " .. tostring(drawnAlpha(UI.report.frame)))
  end
  UI.SetReportOpacity(1)
  if Wrekkit.db.reportOpacity ~= nil then error("full opacity should not be stored") end

  UI.threat:SetDisplay("window")
  UI.threat:SetOpacity(0.5)
  if math.abs(drawnAlpha(UI.threat.frame) - 0.5) > 0.001 then
    error("threat window opacity not applied")
  end
  UI.threat:SetDisplay("docked")
  UI.threat:SetOpacity(0.6)
  if math.abs(UI.meter:Settings().opacity - 0.6) > 0.001 then
    error("docked, the threat window's opacity should set the meter's too")
  end
  if math.abs(drawnAlpha(UI.threat.frame) - 0.6) > 0.001 then
    error("docked threat window does not match the meter")
  end
  UI.threat:SetOpacity(1)
  Wrekkit.threat:Settings().opacity = 1
  UI.threat:SetDisplay("window")
end)

step("a finished segment's view is reused until it changes", function()
  UI.meter:Settings().segment = "last"
  UI.meter:SetMetric("damage")
  local live = Wrekkit.encounter.live
  Wrekkit.encounter.live = nil
  UI.meter:Refresh()
  local first = UI.meter.lastView
  UI.meter:Refresh()
  if UI.meter.lastView ~= first then error("an unchanged pull was re-aggregated") end
  local enc = UI.meter:PullBack(1)
  enc.rev = (enc.rev or 0) + 1
  UI.meter:Refresh()
  if UI.meter.lastView == first then error("a changed pull kept its old view") end
  UI.meter:Settings().petMode = "separate"
  local before = UI.meter.lastView
  UI.meter:Refresh()
  if UI.meter.lastView == before then error("changing the pet mode kept the old view") end
  UI.meter:Settings().petMode = "merge"
  Wrekkit.encounter.live = live
  UI.meter:Settings().segment = "current"
  UI.meter:Refresh()
end)

step("threat: docked window hangs under the meter", function()
  local T = Wrekkit.threat
  T:Demo(30)
  UI.threat:SetDisplay("docked")
  local f = UI.threat.frame
  if not f:IsShown() then error("docked threat window is not shown") end
  local p = f._points[1]
  if not p or p[2] ~= UI.meter.frame then error("docked window is not anchored to the meter") end
  if table.getn(UI.threat.list.data) < 3 then error("docked window drew no rows") end
  UI.threat:SetDisplay("window")
  if f._points[1] and f._points[1][2] == UI.meter.frame then
    error("back in its own window it still hangs off the meter")
  end
  T:StopDemo()
end)

step("threat: meter mode switches the meter for the fight and back", function()
  local T = Wrekkit.threat
  local TF = UI.threatFrames
  UI.meter:SetMetric("healing")
  UI.threat:SetDisplay("meter")
  if UI.threat.frame and UI.threat.frame:IsShown() then error("meter mode left the window up") end
  T:Demo(30)
  IN_COMBAT = true
  Wrekkit.encounter:CombatStart()
  TF:UpdateMeterSwitch()
  if UI.meter:Settings().metric ~= "threat" then error("meter did not switch to threat") end
  local drew = 0
  for _, item in ipairs(UI.meter.list.data) do
    if item.row then drew = drew + 1 end
  end
  if drew < 3 then error("the meter did not draw threat rows") end
  IN_COMBAT = false
  Wrekkit.encounter:CombatEnd()
  TF:UpdateMeterSwitch()
  if UI.meter:Settings().metric ~= "healing" then
    error("meter did not go back: " .. tostring(UI.meter:Settings().metric))
  end
  T:StopDemo()
  IN_COMBAT = true
  UI.threat:SetDisplay("window")
  UI.meter:SetMetric("damage")
end)

step("threat: warnings fire once on the way up, not every reading", function()
  local T = Wrekkit.threat
  local TF = UI.threatFrames
  local count = 0
  local real = TF.Message
  TF.Message = function(self, text, level) count = count + 1 end
  T.demoUntil = nil
  T.current = nil
  T.lastLevel = nil
  local me = UnitName("player")
  T:SetCurrent({ key = "k", rows = {}, at = GetTime() })
  local function reading(perc)
    local r = { name = me, perc = perc, melee = false, isMe = true, threat = perc * 10 }
    r.pull = T.PullPercent(r)
    local tank = { name = "Tanky", tank = true, perc = 100, threat = 1000, pull = 100 }
    T:SetCurrent({ key = "k", rows = { r, tank }, me = r, tank = tank, at = GetTime() })
  end
  reading(50)      -- 38%: safe
  reading(104)     -- 80%: warn
  reading(105)     -- still warn: nothing new
  reading(125)     -- 96%: danger
  reading(126)
  TF.Message = real
  T.current = nil
  if count ~= 2 then error("expected 2 warnings (warn, danger), got " .. count) end
end)

step("settings controls are laid out in two columns", function()
  UI.settings.frame = nil
  UI.settings:Create()

  -- Paired controls must sit at two distinct x offsets, or the "columns"
  -- are one column wearing a hat.
  local xs = {}
  for _, c in ipairs(UI.settings.controls) do
    local p = c._points and c._points[1]
    if p and p[4] then xs[p[4]] = (xs[p[4]] or 0) + 1 end
  end

  local distinct = 0
  for _ in pairs(xs) do distinct = distinct + 1 end
  if distinct < 2 then
    error("every control shares one x offset; nothing was paired")
  end
end)

--[[ The window has to get WIDER with the text, not just taller.

     Control heights are fixed literals, so a larger text size never grew the
     window -- it only grew the labels inside a window that stayed 310px. At
     180% the longest label wanted 259px of a column that would not give it,
     and it ran into the value beside it. ]]

step("the settings window widens with the text size", function()
  local real = Wrekkit.db.fontScale

  Wrekkit.db.fontScale = 1
  UI.ApplyFontScale()
  UI.settings.frame = nil
  local narrow = UI.settings:Create():GetWidth()

  Wrekkit.db.fontScale = 1.8
  UI.ApplyFontScale()
  UI.settings:Layout()
  local wide = UI.settings.frame:GetWidth()

  Wrekkit.db.fontScale = real
  UI.ApplyFontScale()
  UI.settings:Layout()

  if not (wide > narrow) then
    error(string.format("1.8x text gave %dpx, same as %dpx at 1.0x",
      wide or 0, narrow or 0))
  end
end)

step("a column stays wide enough for the longest label", function()
  local real = Wrekkit.db.fontScale
  Wrekkit.db.fontScale = 1.8
  UI.ApplyFontScale()
  UI.settings.frame = nil
  UI.settings:Create()

  -- "Record open-world combat" is the longest, ~6px a character at 1.0.
  local needed = string.len("Record open-world combat") * 6 * 1.8
  local widest = 0
  for _, c in ipairs(UI.settings.controls) do
    local w = c:GetWidth() or 0
    if w > widest then widest = w end
  end

  Wrekkit.db.fontScale = real
  UI.ApplyFontScale()
  UI.settings.frame = nil
  UI.settings:Create()

  if widest < needed then
    error(string.format("columns are %dpx but the longest label needs %d",
      widest, needed))
  end
end)

step("re-laying out does not multiply the control list", function()
  UI.settings.frame = nil
  UI.settings:Create()
  local before = table.getn(UI.settings.items)
  UI.settings:Layout()
  UI.settings:Layout()
  local after = table.getn(UI.settings.items)
  if after ~= before then
    error(string.format("items grew from %d to %d across two layouts",
      before, after))
  end
end)

print(string.format("\n%d passed, %d failed  (%d frames created)\n", pass, fail, calls))
if fail > 0 then os.exit(1) end

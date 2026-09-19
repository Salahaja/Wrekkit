--[[ Wrekkit :: commands

Slash interface. Everything the windows can do is reachable from here so the
addon stays usable with the UI closed, or bound to a macro mid-pull.
]]

local W = Wrekkit

local function words(msg)
  local out = {}
  for piece in string.gfind(msg or "", "%S+") do
    table.insert(out, string.lower(piece))
  end
  return out
end

local function channelArg(word)
  if word == "raid" then return "RAID" end
  if word == "party" then return "PARTY" end
  if word == "guild" then return "GUILD" end
  if word == "say" then return "SAY" end
  if word == "whisper" or word == "w" or word == "tell" then return "WHISPER" end
  return nil
end

--- Announce whatever window is in front: the report when it is open, the
--- meter otherwise. Both describe what they are currently displaying.
local function announceContext()
  local ui = W.ui
  if ui.report.frame and ui.report.frame:IsShown() then
    return ui.report:AnnounceContext(), ui.report.frame, ui.report.announceBtn
  end
  if ui.meter.frame and ui.meter.frame:IsShown() then
    return ui.meter:AnnounceContext(), ui.meter.frame, ui.meter.frame.bar
  end
  return ui.meter:AnnounceContext(), nil, nil
end

local HELP = {
  { "/wrek", "toggle the live meter" },
  { "/wrek report", "open the full report" },
  { "/wrek config", "open the settings window" },
  { "/wrek compact", "toggle the small meter layout" },
  { "/wrek status", "diagnose why nothing is being recorded" },
  { "/wrek who", "list every actor and how it was classified" },
  { "/wrek mode <metric>", "set the meter metric (dps, healing, taken, ...)" },
  { "/wrek segment <what>", "current, last, back2..back5 or overall" },
  { "/wrek boss", "mark the selected pull (or the last one) as a boss" },
  { "/wrek modes", "list every metric" },
  { "/wrek save", "write history to CustomData\\Wrekkit_<char>.txt" },
  { "/wrek load", "read that file back in" },
  { "/wrek reset", "start a new log (history is kept)" },
  { "/wrek reset all", "delete every recorded encounter" },
  { "/wrek keep", "lock the last encounter so nothing deletes it" },
  { "/wrek prune [days]", "delete unlocked encounters older than N days" },
  { "/wrek prune all", "delete every unlocked encounter" },
  { "/wrek share [chan]", "send the last pull to other Wrekkit users" },
  { "/wrek peers", "browse who is sharing and pull their logs" },
  { "/wrek sharing on|off", "let others see you and pull your logs" },
  { "/wrek channel <chan>", "auto | raid | party | guild" },
  { "/wrek request", "look for other Wrekkit users" },
  { "/wrek announce [chan]", "post what is on screen to chat (asks first)" },
  { "/wrek lock", "lock the meter in place" },
  { "/wrek minimap", "toggle the minimap button" },
  { "/wrek resume <min>", "how long a break still counts as the same session" },
  { "/wrek group", "only count your party/raid, ignore everyone else" },
  { "/wrek world", "also record open-world combat (off by default)" },
  { "/wrek accept", "toggle accepting shared reports" },
}

local function printHelp()
  W.Print("commands:")
  for _, row in ipairs(HELP) do
    DEFAULT_CHAT_FRAME:AddMessage("   |cffe0a22c" .. row[1] .. "|r  -  " .. row[2])
  end
end

local function handler(msg)
  local a = words(msg)
  local cmd = a[1]

  if not cmd or cmd == "" then
    W.ui.meter:Toggle()
    return
  end

  if cmd == "report" or cmd == "r" then
    W.ui.report:Toggle()

  elseif cmd == "config" or cmd == "options" or cmd == "settings" then
    W.ui.settings:Toggle()

  elseif cmd == "compact" then
    local st = W.ui.meter:Settings()
    st.compact = not st.compact
    W.ui.meter:Show()
    W.ui.meter:ApplyLayout()
    W.Print("compact meter " .. (st.compact and "on." or "off."))

  elseif cmd == "status" or cmd == "diag" then
    W.Status()

  elseif cmd == "who" then
    W.Who()

  elseif cmd == "help" or cmd == "?" then
    printHelp()

  elseif cmd == "modes" then
    W.Print("metrics:")
    for _, m in ipairs(W.metrics.list) do
      DEFAULT_CHAT_FRAME:AddMessage("   |cffe0a22c" .. m.key .. "|r  -  " .. m.label)
    end

  elseif cmd == "mode" or cmd == "m" then
    local key = a[2]
    if not key or not W.metrics.byKey[key] then
      W.Print("unknown metric. /wrek modes lists them.")
      return
    end
    W.ui.meter:Show()
    W.ui.meter:SetMetric(key)
    W.Print("meter showing " .. W.metrics.byKey[key].label .. ".")

  elseif cmd == "segment" or cmd == "seg" then
    local v = a[2]
    -- back2..back5 are the same pulls the segment menu offers by name.
    local ok = (v == "current" or v == "overall") or
               (v and W.ui.meter.BACK and W.ui.meter.BACK[v] ~= nil)
    if not ok then
      W.Print("segment must be current, last, back2..back5 or overall.")
      return
    end
    W.ui.meter:Settings().segment = v
    W.ui.meter:Show()
    W.ui.meter:Refresh()

  elseif cmd == "boss" then
    --[[ Correcting the guess without opening a window. The detector reads
         the client's classification and falls back to a health threshold,
         and neither can be right for every server's content, so overruling
         it has to be one word rather than a setting to go and find. ]]
    local encounters = W.ui.report:SelectedEncounters()
    local open = W.ui.report.frame and W.ui.report.frame:IsShown()
    if open and table.getn(encounters) > 0 then
      W.ui.report:ToggleBossMark()
      return
    end

    local session = W.report:CurrentSession()
    local list = (session and session.encounters) or {}
    local last = list[table.getn(list)]
    if not last then
      W.Print("no pull to mark yet.")
      return
    end
    local now = W.SetBoss(last, not W.IsBoss(last))
    W.Print("|cffe0a22c" .. (last.name or "that pull") .. "|r is " ..
      (now and "a boss pull." or "not a boss pull."))
    if W.ui.report then W.ui.report:Refresh() end

  elseif cmd == "save" then
    W.store:Save()

  elseif cmd == "load" then
    W.store:Load()

  elseif cmd == "reset" then
    W.ResetData(a[2] == "all" and "all" or "new")

  elseif cmd == "keep" then
    local list = W.db.encounters
    local enc = list[table.getn(list)]
    if not enc then
      W.Print("nothing recorded yet.")
      return
    end
    local locked = W.ToggleLocked(enc)
    W.Print((locked and "Keeping " or "Released ") ..
      "|cffe0a22c" .. (enc.name or "?") .. "|r." ..
      (locked and " Nothing will delete it." or "") ..
      "  (" .. W.CountLocked() .. " kept in total)")

  elseif cmd == "prune" then
    local days = tonumber(a[2])
    if a[2] == "all" then days = nil
    elseif not days then days = 7 end

    local removed, kept, spared = W.PruneEncounters(days)
    local scope = days and ("older than " .. days .. " day" .. (days == 1 and "" or "s"))
      or "unlocked"
    W.Print("Pruned " .. removed .. " encounter" .. (removed == 1 and "" or "s") ..
      " " .. scope .. ". " .. kept .. " left" ..
      (spared > 0 and (", " .. spared .. " kept by their lock") or "") .. ".")

  elseif cmd == "share" then
    W.sync:ShareLatest(channelArg(a[2]))

  elseif cmd == "peers" or cmd == "browse" then
    W.ui.peers:Toggle()

  elseif cmd == "sharing" then
    local on = a[2]
    if on == "on" then W.db.shareEnabled = true
    elseif on == "off" then W.db.shareEnabled = false
    else W.db.shareEnabled = not W.db.shareEnabled end
    W.ui.settings:Refresh()
    W.Print("log sharing " .. (W.db.shareEnabled and
      ("on, visible to your " .. string.lower(tostring(W.sync:ActiveChannel() or "group")) .. ".")
      or "off. Others cannot see you or pull your logs."))

  elseif cmd == "channel" then
    local c = string.upper(a[2] or "")
    if c ~= "RAID" and c ~= "PARTY" and c ~= "GUILD" and c ~= "AUTO" then
      W.Print("channel must be auto, raid, party or guild.")
      return
    end
    W.db.shareChannel = c
    W.ui.settings:Refresh()
    W.Print("sharing on " .. string.lower(c) ..
      (c == "AUTO" and " (raid, else party, else guild)." or "."))

  elseif cmd == "request" then
    W.sync:Discover(channelArg(a[2]))

  elseif cmd == "announce" or cmd == "post" then
    --[[ Announces whatever is on screen, and always through the
         confirmation. Naming a channel picks the destination; leaving it off
         opens the picker. Neither skips the preview -- there is deliberately
         no way to fire something into raid chat from a single keystroke. ]]
    local ctx, frame, anchor = announceContext()
    local channel = channelArg(a[2])
    local target = (channel == "WHISPER") and a[3] or nil
    local count = tonumber(a[3]) or tonumber(a[2]) or nil
    if channel == "WHISPER" then count = tonumber(a[4]) end

    if channel then
      W.announce:Request(ctx, channel, target, count)
    elseif frame and anchor then
      W.ui.AnnounceMenu(frame, anchor, ctx)
    else
      W.Print("open the meter or report first, or name a channel: " ..
        "|cffe0a22c/wrek announce raid|r")
    end

  elseif cmd == "lock" then
    local s = W.ui.meter:Settings()
    s.locked = not s.locked
    W.Print("meter " .. (s.locked and "locked." or "unlocked."))

  elseif cmd == "minimap" then
    W.db.minimap.show = not W.db.minimap.show
    if W.minimap then W.minimap:Update() end

  elseif cmd == "resume" then
    local mins = tonumber(a[2])
    if mins then
      W.db.resumeWindow = math.floor(mins * 60)
    end
    W.Print("rejoining the previous session after a break of up to " ..
      W.Duration(W.db.resumeWindow) .. ". |cffe0a22c/wrek resume <minutes>|r to change.")

  elseif cmd == "group" then
    local st = W.ui.meter:Settings()
    st.groupOnly = not st.groupOnly
    W.ui.report.state.groupOnly = st.groupOnly
    W.ui.meter:UpdateToggles()
    W.ui.meter:Refresh()
    W.ui.report:Refresh()
    W.Print(st.groupOnly
      and "counting your party/raid only."
      or "counting everyone nearby.")

  elseif cmd == "world" then
    W.db.trackOpenWorld = not W.db.trackOpenWorld
    W.ui.meter:UpdateToggles()
    W.Print("open-world combat " ..
      (W.db.trackOpenWorld and "is now recorded." or "is ignored (instances only)."))

  elseif cmd == "accept" then
    W.db.acceptShares = not W.db.acceptShares
    W.Print("shared reports " ..
      (W.db.acceptShares and "accepted." or "ignored."))

  elseif cmd == "debug" then
    W.db.debug = not W.db.debug
    W.Print("debug " .. (W.db.debug and "on." or "off."))

  else
    W.Print("unknown command '" .. cmd .. "'. /wrek help lists them.")
  end
end

SLASH_WREKKIT1 = "/wrek"
SLASH_WREKKIT2 = "/wrekkit"
SlashCmdList["WREKKIT"] = handler

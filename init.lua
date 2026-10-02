--[[ Wrekkit :: init

Bootstrap. Loads last so every module it wires up already exists.
]]

local W = Wrekkit

local f = CreateFrame("Frame", "WrekkitInitFrame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

f:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 ~= "Wrekkit" then return end

    W.InitDB()
    -- Before any frame exists: the skin decides how frames are built.
    W.Guard("skin", function() W.ui.ApplySkin() end)
    W.capture:Start()
    W.sync:Start()
    W.threat:Start()
    W.ui.threatFrames:Start()
    W.minimap:Update()

    local missing = W.capture:CheckEnvironment()
    if table.getn(missing) > 0 then
      W.Print("|cffd44f53missing:|r " .. table.concat(missing, ", ") ..
        " - recording will be incomplete.")
    end

    W.Print("v" .. W.version .. " ready. |cffe0a22c/wrek|r for the meter, " ..
      "|cffe0a22c/wrek report|r for the full view.")

    --[[ Bring the meter back up if it was up last time (the default).
         Deferred a moment rather than done inline: frame movers like
         MoveAnything reposition other addons' windows at load, and showing
         ours after that settles avoids fighting them over the anchor. ]]
    W.After(1, function()
      W.Guard("restore meter", function() W.ui.meter:RestoreVisibility() end)
      W.Guard("restore threat", function() W.ui.threat:UpdateVisibility() end)
    end, "restoreMeter")

    --[[ Say hello if the user turned sharing on. Delayed so the roster has
         settled: announcing before the raid frame populates would pick the
         wrong channel under the AUTO setting. ]]
    W.After(8, function()
      W.Guard("announce presence", function() W.sync:Announce() end)
    end, "announcePresence")

  elseif event == "PLAYER_LOGOUT" then
    -- Close the pull in progress so it lands in SavedVariables instead of
    -- being lost at the loading screen.
    if W.encounter.live then W.encounter:Finish() end
    -- And note how far the journal had got, for the next login's recovery.
    W.Guard("journal mark", function() W.store:MarkSaved() end)

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- A zone change ends whatever was being recorded: combat cannot span it.
    if W.encounter.live then W.encounter:Finish() end

    --[[ Bring back what a crash lost, once a login -- see St:Recover. Here
         rather than at ADDON_LOADED: the journal is named after the player,
         whose name is certain by now, and no pull can have ended yet. ]]
    if not W.store.recovered then
      W.store.recovered = true
      W.Guard("crash recovery", function() W.store:Recover() end)
    end
  end
end)

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
    W.capture:Start()
    W.sync:Start()
    W.minimap:Update()

    --[[ Auto-recover after a crash.

         SavedVariables are written only at a clean logout, so an empty
         history plus a non-empty journal means the last session ended badly.
         Restoring it silently would be presumptuous, but leaving the user to
         discover "/wrek load" on their own is worse -- so restore and say so.
         Only when the history is actually empty; never overwrite real data. ]]
    if table.getn(W.db.encounters) == 0 and W.store:Available()
        and W.store:FileExists(W.store:Filename()) then
      W.Guard("crash recovery", function()
        W.Print("history was empty but a saved journal exists - recovering.")
        W.store:Load()
      end)
    end

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

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- A zone change ends whatever was being recorded: combat cannot span it.
    if W.encounter.live then W.encounter:Finish() end
  end
end)

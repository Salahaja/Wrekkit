**Live server threat, tank tools, mob frames, and a Blizzard / pfUI look.** Everything since 0.4.4.

## New

### Threat meter
- Live threat for your target, **straight from the server** (OctoWoW answers the `TWT_UDTSv4` threat request, the same one TWThreat uses), not estimated from the combat log. It needs a party or raid. TWThreat can run alongside it.
- Shown **docked under the damage meter** (default), in its own window, or inside the meter while you fight. Includes a pull-aggro line, threat per second, and *% to pull* or *% of tank*.
- **On the target frame**: a clean % with a slim threat bar and a soft glow. Drag it anywhere (`/wrek threat move`) and it stays where you put it.
- **On nameplates**: stock, **ShaguPlates** or **pfUI** plates. Shows a coloured % or tints the plate's own health bar, and hands the bar back to the plate addon afterwards.
- **Warnings**: say it once when you cross a line. **Flash while close**: keeps flashing for as long as you are over *your* limit.

### Tanking
- *I'm the tank*: **auto** detects Defensive Stance, Bear Form and **Righteous Fury**. `/wrek threat role` shows what was detected.
- Every mob you hold, who is closest to pulling each one, and alerts for **"Stabbs at 88% on Whelp"** and **"LOST AGGRO"**.
- **LOOSE** mobs: a mob that goes to a healer is spotted through its nameplate, even if you never targeted it.
- **Click to taunt**: a Taunt bar pops up with a button per lost or loose mob. With SuperWoW it taunts without changing your target. Also on a keybinding and `/wrek taunt`.
- **Mob frames**: one mini frame per mob, showing its health, who it is hitting and its threat %. Your target is marked. **Collapsed**, the frames show "All 10 on you" and only bring back a mob that breaks off, or that someone has 80% of your threat on.

### Looks
- **Blizzard**: tooltip and dialog borders, panel buttons, stock checkboxes, dropdown menus, status-bar bars and gold titles.
- **pfUI**: uses pfUI's own backdrop, texture and font when pfUI is loaded.
- **Modern**: the old flat style. **Auto** picks pfUI when pfUI or ShaguPlates is present.
- Opacity for every window. Menus are grouped. Settings are in tabs.

## Improved
- **Crash-safe saving**: a pull torn by a crash mid-write is dropped instead of half-imported. Full rewrites go through a backup file. The journal is compacted past 1 MB.
- **Less memory churn** in combat. One memory clean-up after each fight, out of combat.
- **Saved settings** are checked at login, and anything out of range is reset.

## Install

Download `Wrekkit-0.8.0.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`.

Do **not** use the "Source code" links. They extract to a folder the client will not load.

OctoLauncher users can add it as a git addon instead: URL `https://github.com/Salahaja/Wrekkit`, folder `Wrekkit`, branch `main`.

**Fully restart the client** after installing. `/reload` will not pick up a new addon or its keybinding. `/wrek status` should then report **v0.8.0**.

## Requirements

- **Nampower** is required (OctoLauncher: Mods → Nampower).
- **SuperWoW** is strongly recommended (Mods → SuperWoW). Names, mob frames, loose detection and taunting without retargeting all need it.
- Threat needs a party or raid.

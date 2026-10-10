**Know which mobs you're about to pull, targeted or not, and get a real raid warning when it counts.**

## New
- **A tank's mobs, shared with the group.** The server tells a damage dealer about one mob: their target. A tank hears about every mob they hold, along with who is closest to pulling each one. The tank's Wrekkit now passes that to the party or raid about once a second. If you're the one closest to pulling any of those mobs, you get the usual THREAT warning and flash, and that mob's nameplate shows your %. This works even when you're AoEing five mobs and targeting none of them.
  - It needs the tank to run Wrekkit 0.9.4, and covers the mobs they're holding.
  - Relayed mobs are measured against the melee line, because the tank's data doesn't say who's in melee range. Casters are warned a little early, never late.
  - On by default: **Settings → Threat → Share threat on every mob**.
- **Big raid warning.** AGGRO, LOST AGGRO and danger-level THREAT also show as **WARNING: …** at the top of your screen, in the raid-warning style, with the raid-warning sound. Only you see it; nothing is sent to the raid. On by default: **Settings → Threat → Big raid warning**.

## Install

Download `Wrekkit-0.9.4.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.4**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

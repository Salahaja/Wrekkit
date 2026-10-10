**Raid markers in the mob window, and a mob window that works for DPS and healers too.**

## New
- **Raid markers.** A marked mob (skull, cross, star and so on) shows its marker at the left of its row in the mob window.
- **Mob window for DPS and healers.** Under **Settings → Frames & plates → Mob frames**, set **Show them** to **DPS and healing too** (it was called "always").
  - With a tank running Wrekkit 0.9.4 or later, a mob you're closest to pulling gets its own row with your %, and turns red once you're past your warning line.
  - A mob attacking you is red as before.
  - The rest share the "on others" line when the window is collapsed.

## Install

Download `Wrekkit-0.9.8.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.8**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

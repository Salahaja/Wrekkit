**Enemy cast bars and more control over the mob window, all behind settings.**

Everything new here starts **off**, or as it was, and lives in Settings → Frames & plates → Mob frames.

## New
- **Enemy cast bars** (off until turned on): while a mob casts, a bar shows the spell, its icon and the time left. Gold fills for a cast, and green drains for a channel. It ends the moment the cast lands, is interrupted or the mob dies. Needs Nampower.
  - **Cast bar:** over the row, inside the window (default), or beside it at a width you set (40–200px).
  - **Cast bar covers:** who the mob is on (the right part), or everything after its name.
- **Shift/Ctrl-click spells on mobs** (off until turned on): set a spell for Shift-click and one for Ctrl-click, picked from your spellbook. Clicking a mob's row casts it on that mob. With SuperWoW your target stays put.
- **Row layout:** split 60/40 (as before), or the mob's name full width, with the player it's hitting as a short tag by the %.

## Changed
- **The player side of a mob's row is now opt-in.** That's clicking the player a mob is on to heal or target them. While it's off, the whole row acts on the mob. If you had set a player click spell, it stays on for you.

## Install

Download `Wrekkit-0.9.25.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.25**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files and the cast bars. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

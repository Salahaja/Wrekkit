**Fixes the start-up error after updating to 0.9.37 and using /reload.**

## Fixed
- **"init.lua:26: attempt to index field `myDebuffs' (a nil value)".** 0.9.37 added a new file, and the client only reads an addon's file list when the game starts. After updating and using `/reload`, that file was never loaded, so Wrekkit's start-up stopped there, and the threat frames, the minimap button and the missing-addons check never started. Wrekkit now checks that a file an update added is loaded before using it. If it is not, Wrekkit says once to exit the game fully and start it again, and the rest of start-up goes ahead. The export buttons check the same way.

## Install

Download `Wrekkit-0.9.38.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from **0.9.36 or earlier, fully exit the game and start it again**: a `/reload` does not load the files added since. Coming from 0.9.37, a `/reload` is enough. `/wrek status` should then report **v0.9.38**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars, raid value, exports to a file and your debuffs on the mob frames. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **UnitXP_SP3** makes the mob frame distances exact (optional).
- **aux** for consumable prices (optional).

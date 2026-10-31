**Your own debuffs on the mob frames, with a countdown.**

## New
- **My debuffs on each mob** (Settings > Mob frames, off by default). Your own Serpent Sting, curses, DoTs and the like show as icons just left of each mob's row, with stacks. The one running out soonest is nearest the row.
  - **Only yours:** a debuff counts as yours when it lands on the mob just after you cast it there, or when the client names you as its caster. Another player's copy of the same spell is left out.
  - **Countdown:** the client gives no durations, so Wrekkit learns each one the first time it sees yours wear off, and counts down from the next one on. A recast restarts the countdown, an early dispel never shortens what was learned, and a mob that dies takes its debuffs with it.

## Install

Download `Wrekkit-0.9.37.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.37**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars, raid value, exports to a file and your debuffs on the mob frames. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **UnitXP_SP3** makes the mob frame distances exact (optional).
- **aux** for consumable prices (optional).

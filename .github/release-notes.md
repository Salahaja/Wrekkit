**Fixes client crashes (ERROR #132) with Raid value on.**

## Fixed
- **The client could crash mid-fight with Raid value on.** The crash report shows ERROR #132 at 0x004648AC, inside nampower.dll. Wrekkit reads a mob's live armor as it is hit, to make Sunder and the other armor debuffs exact. The combat log also reports mobs the client no longer has loaded: mobs too far away, just despawned, or dropped when the server goes down. Asked about one of those, Nampower read an object that wasn't there and took the client down. Wrekkit now checks that the client still has a mob before asking Nampower, UnitXP or SuperWoW anything about it. That covers the armor reading, the mob-frame distance and the right-click range check.

## Install

Download `Wrekkit-0.9.34.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.34**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **UnitXP_SP3** makes the mob frame distances exact (optional).
- **aux** for consumable prices (optional).

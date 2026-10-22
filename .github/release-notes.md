**The mob frame distance gets a column of its own, so mob names keep their room.**

## Changed
- **Distance on the mob frames is now its own column of the window.** Inside the row it took room from the mob's name, which then showed as "Heroic Training D...". With distance on, the window widens at the right for a column of its own, and the rows and names keep their width. The window narrows back when distance is off. A cast bar set beside the row starts past the window's edge.
- **"Distance shown"** (Settings → Mob frames) offers **its own column** (the default) or **inside the row**, as it was.

## Install

Download `Wrekkit-0.9.33.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.33**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **UnitXP_SP3** makes the mob frame distances exact (optional).
- **aux** for consumable prices (optional).

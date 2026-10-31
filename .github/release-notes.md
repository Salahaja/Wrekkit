**Glancing blows measured fairly, and the reset is back within reach on a compact meter.**

## Fixed
- **"A glance did" read over 100% for some players** (119%, up to 222%). Each glance was compared with the average of all their other hits in the pull: main hand and off hand together, every mob's armor together, and as few as two glances. Each glance is now compared with recent ordinary swings of the same hand on the same mob. The comparison waits for ten glances and never reads above 100%. Pulls recorded on 0.9.35 show the glance count and damage without the comparison.

## Changed
- **Compact meter:** with no toolbar, right-clicking the title opens with **Start a new log** and **Delete all history...**, then the toolbar's toggles (group only, picked players, open world). Before, the reset sat at the bottom of the menu and the toggles were missing.

## Install

Download `Wrekkit-0.9.36.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.36**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars, raid value and exports to a file. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **UnitXP_SP3** makes the mob frame distances exact (optional).
- **aux** for consumable prices (optional).

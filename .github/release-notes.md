**Raid value: armor debuffs are now exact, measured from each mob's real armor.**

## Changed
- **Sunder Armor, Faerie Fire, Curse of Recklessness, Expose Armor and Annihilator are exact.** Wrekkit now reads each mob's armor from the game, which drops with every Sunder. Their worth is measured from it, and they count with **Raid value** alone, no longer behind "Estimated effects" or marked "(est.)".
  - Where the mob started: a reading before any of those debuffs is on it. It's kept by mob name, so it's known for that mob type from then on.
  - What they took off: that starting armor against the reading now, shared between the debuffs by their size.
  - Expose Armor counts what it really took off, whatever the combo points or Improved Expose Armor.
  - A mob whose armor can't be read falls back to the estimate, still marked "(est.)" and kept on its own line in the drilldown.
- **Estimated effects (experimental)** now covers Battle Shout, Blessing of Might, Trueshot Aura, Hunter's Mark and Leader of the Pack, plus the armor fallback above.

## Install

Download `Wrekkit-0.9.28.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.28**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

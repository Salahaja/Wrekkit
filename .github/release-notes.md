**Consumables are counted all the time now, not just during a fight.**

## New
- **Consumables used between pulls count.** The flask, elixirs, food, Jujus and the Greater Fire Protection Potion drunk just before the boss are credited to the next pull, so a night's totals and its gold cost include the prep. Only your own group's count, so people eating in a city never land in your pull. Anything used more than two hours before a pull isn't credited to it.
- **Consumables Wrekkit never saw being used count too.** Someone who logged in with Flask of the Titans, or joined the group already wearing Elixir of the Mongoose, is counted from the buff they're wearing.
  - A drink and its buff always count as one use, never two.
  - A `/reload` doesn't count the same flask again.
  - This works for flasks, elixirs, protection potions and Jujus. It doesn't work for food eaten before you grouped: its "Well Fed" buff doesn't say which food it was.

## Install

Download `Wrekkit-0.9.20.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client** (0.9.19 added files); from 0.9.19 a `/reload` is enough. `/wrek status` should then report **v0.9.20**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

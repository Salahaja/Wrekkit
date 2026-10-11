**Consumables priced at the auction house, live; the Inspect window's Talents tab fixed; and the threat window can stay hidden when you're solo.**

## New
- **Consumes (gold).** A new metric, in the meter under *Utility* and as a **Consumes** tab in the report window. It shows each player's potions, flasks, elixirs, oils and food priced at the auction house, and updates as they use them.
  - Prices are **aux**'s value for each item, the same figure its tooltips show, or today's lowest buyout for something aux has only just seen.
  - Scans shared from your other accounts through VendorTruth count too.
  - Click a player to see each item's cost, e.g. `2 x 1g 20s`, most expensive first.
  - Items aux has never seen aren't guessed. They're flagged as `+2?` on the player's row and "no price" in their list.
  - Needs aux installed. Without it, the regular Consumables count still works.
- **Threat: "Hide when not in a group".** A new checkbox under *Window appears*. It keeps the threat window away while you're solo, whichever option you've picked, so "in combat" means your group's fights only.

## Fixed
- **The Inspect window's Talents tab no longer comes up blank** for players who do answer. Background inspects, Wrekkit's own and ChronicleCompanion's, were feeding the client's Talents tab other players' replies, so when you opened it, it showed leftovers instead of asking. Those replies are now kept away from it.
- **Inspects are sent in both forms**, so players on an older client build also answer.
- `/wrek specs` now shows what the Talents tab received, to help track down a blank tab.

## Why most players never show talents
It's their client, not Wrekkit. OctoWoW's client download leaves out the folder `Interface\AddOns\Turtle_General`. Without it the game never loads that built-in addon, and that client can't answer an inspect or see anyone's talents. Creating that folder with its `Turtle_General.pub` file fixes it.

0.9.16's notes said players only answer while targeted. That was wrong. Asking when you target someone stays, because it's a handy moment to ask.

## Install

Download `Wrekkit-0.9.17.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing, because this version adds a new file and a `/reload` won't load it. `/wrek status` should then report **v0.9.17**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

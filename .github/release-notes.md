**Consumables counted properly at last, priced from the auction house and shared with your guild; and click-to-cast in the mob window is picked, not typed.**

## Fixed
- **Consumables are counted for everyone, and procs aren't.** Wrekkit was counting your own weapon and trinket procs (Crusader, Hand of Justice…) and your Hearthstone as consumables, and missing every other player's potions. It now recognises a consumable by the spell it casts. On one Molten Core night: 247 counted (mostly procs) became 405 real consumables across the raid.
  - Covers potions, elixirs, flasks, food and drink, weapon oils, sharpening and weight stones, sappers and grenades, runes, all the Jujus, Stratholme Holy Water, Zanza, Dire Maul food and more.

## New
- **Consumes (gold) uses the latest price.** That's today's lowest buyout, or the last price the item sold at if it's out of stock today, instead of aux's long-run average.
  - **Nordanaar Herbal Tea** counts as 1/5 of a Small Dream Shard, and **Dreamtonic** as one.
- **"Scan consumes" at the auction house.** A button on the auction window (and `/wrek scan`) looks up every consumable your raids used and records the cheapest price per item. It only runs while you're at the AH, because that's the only place the game answers.
- **Guild price sharing.** Your scanned prices go to guildmates running Wrekkit, and theirs come to you. For each item the newest price wins. You can turn it off on the Sharing tab.
- **Mob window click spells are picked, not typed.** Each click slot shows the spell's icon. Click it to choose from your spellbook, drag a spell onto it, or right-click to clear it. A name that isn't in your spellbook shows red.
- **Cast on players outside your group** (off by default): your click spells also reach someone a mob has turned on who isn't in your party or raid. It never casts on anyone you can't help.

## Install

Download `Wrekkit-0.9.19.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing, because this version adds new files and a `/reload` won't load them. `/wrek status` should then report **v0.9.19**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

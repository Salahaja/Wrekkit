**A Raid Contrib tab in the report, announcements you can trim line by line, and two counting fixes: flasks drunk before the invite, and who gets credit for a group aura.**

## New
- **Raid Contrib tab** (in the report, `/wrek report`): each effect Raid value counted, such as Sunder Armor, the curses, Windfury or Nightfall, with its total and how many players built it. Then come the mana and healing the judgements give back. Click an effect for who added how much of it; click again to go back. It needs Raid value recording (Settings → Recording).
- **Announcing from it:** the confirmation has a **"Name who added each effect"** box. Leave it off for each effect's total and how many built it, or tick it for each player's share. Clicked into one effect, Announce posts that effect's builders, each with amount and share.
- **Leave lines out of any announcement:** click a numbered line in the confirmation's preview to drop it, and click again to bring it back. What is sent is renumbered.

## Fixed
- **Flasks and other consumables drunk before someone was invited were lost.** On one 10/17 Molten Core run, 15 players had a flask up but only 8 were counted, and Flask of the Titans never was. Consumables used between pulls are now judged when the next pull starts, not when they're drunk. Someone still not in the group then has their flask counted once they join.
- **A group aura or shout was credited to whoever held it.** A paladin standing in another paladin's Sanctity Aura was credited with it. It now goes to whoever was seen casting it. Otherwise, paladins known to run another aura are ruled out (yours is read from your stance bar), and if one is left it's theirs. Otherwise nobody is guessed. The same applies to Retribution Aura, Battle Shout, Trueshot Aura and Leader of the Pack. Pulls already recorded keep their old credit.
- **Changing Top or a box in the announce confirmation emptied a Raid value post.** It's kept now.
- **Report tabs ran past the window's edge at its smallest size.** They now narrow to fit.

## Install

Download `Wrekkit-0.9.30.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.30**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

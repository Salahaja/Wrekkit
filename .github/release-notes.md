**Raid value: what each player's buffs and debuffs add to everyone else's damage. Also: right-click a mob with your ranged attack or a spell of your own, and correct spell names without SuperWoW.**

Everything new starts **off**, or as it was. Raid value lives in Settings → Recording; the right-click options in Settings → Frames & plates → Mob frames.

## New
- **Raid value** (off until turned on): checked per hit, against the attacker's own buffs and the target mob's own debuffs, and credited to whoever provides them, never to the hitter. A new **Raid value** metric sits under Damage, and its drilldown shows which effect added how much.
  - **Spells:** Sanctity Aura, Power Infusion, Curse of Shadow and of the Elements, Improved Shadow Bolt, Shadow Weaving and Fire Vulnerability (per stack), Nightfall, and Judgement of the Crusader.
  - **Damage shields:** Retribution Aura goes to the group's paladin, Thorns to the druid who cast it.
  - **Melee:** Windfury Totem's extra swings go to the group's shaman. Expose Weakness is counted too.
  - **Stacking debuffs** (Sunder, Shadow Weaving, Fire Vulnerability, Annihilator) are split between everyone who applied them.
- **Raid support** (under Healing): the mana and health Judgement of Wisdom and Judgement of Light give back, credited to the paladin.
- **Credit raid value to providers** (off): moves those bonuses into the providers' own damage and healing. The raid total stays the same.
- **Estimated effects (experimental)** (off): adds the effects with no exact math, each marked "(est.)":
  - Sunder Armor, Expose Armor, Faerie Fire, Curse of Recklessness, Annihilator. These use the mob's own armor, read from the game and learned by name.
  - Battle Shout, Blessing of Might, Trueshot Aura, Hunter's Mark and Leader of the Pack.
- **Announcing raid value** posts what each effect added. Pick **each effect's total** (the default: how many players built it, no names), or **and who added it** (each player's share, e.g. "Sunder Armor (est.) 60k: Wiredbro 40k, Manner 20k").
- **Right-click attacks with:** melee (as before), your ranged attack, or **whichever reaches**. That one shoots from 8 yards out and swings closer. A click never switches off an attack already going.
  - The ranged attack: hunters use Auto Shot; warriors and rogues their bow, gun, crossbow or throw; priests, mages and warlocks a wand. Paladins, shamans and druids always swing.
- **Right-click mob casts:** pick a spell (Frostbolt, Arcane Shot...) to cast on a mob you right-click, in place of attacking. It's kept per character. A tank's taunt is unchanged.

## Fixed
- **Spell names without SuperWoW.** Spells were named only from cast starts, and the pairing was loose. A hunter's Auto Shot could read "Roasted Boar Meat" and Serpent Sting "Opening", while instants stayed "Spell 14285". Names now come from Nampower, which names every spell, icons included. Names learned the old way are dropped. Pulls recorded before keep their old labels.
- **Mob debuffs the client files as buffs** (11 of 103 Nightfall procs on one night) now count for raid value.

## Install

Download `Wrekkit-0.9.27.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.27**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

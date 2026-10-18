**Raid value: what each player's buffs and debuffs add to everyone else's damage, so a comp or a gear choice can be weighed in numbers.**

Everything new here starts **off**, and lives in Settings → Recording.

## New
- **Raid value** (off until turned on): checked per hit, against the attacker's own buffs and the target mob's own debuffs, and credited to whoever provides them, never to the hitter. A new **Raid value** metric sits under Damage, and its drilldown shows which effect added how much.
  - **Spells:** Sanctity Aura, Power Infusion, Curse of Shadow and of the Elements, Improved Shadow Bolt, Shadow Weaving and Fire Vulnerability (per stack), Nightfall, and Judgement of the Crusader.
  - **Damage shields:** Retribution Aura goes to the group's paladin, Thorns to the druid who cast it.
  - **Melee:** Windfury Totem's extra swings go to the group's shaman. Expose Weakness is counted too.
  - **Stacking debuffs** (Sunder, Shadow Weaving, Fire Vulnerability, Annihilator) are split between everyone who applied them.
- **Raid support** (under Healing): the mana and health Judgement of Wisdom and Judgement of Light give back, credited to the paladin.
- **Credit raid value to providers** (off): moves those bonuses into the providers' own damage and healing. The raid total stays the same.
- **Estimated effects (experimental)** (off): adds the effects with no exact math, each marked "(est.)":
  - Sunder Armor, Expose Armor, Faerie Fire, Curse of Recklessness, Annihilator. These use the mob's own armor, read from the game where it can be read, and learned by name.
  - Battle Shout, Blessing of Might, Trueshot Aura, Hunter's Mark and Leader of the Pack.
- **Announcing raid value** posts what each effect added. Pick **each effect's total** (the default: how many players built it, no names), or **and who added it** (each player's share, e.g. "Sunder Armor (est.) 60k: Wiredbro 40k, Manner 20k").

## Install

Download `Wrekkit-0.9.26.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.26**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

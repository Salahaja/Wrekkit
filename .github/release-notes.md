**No more lost damage from short pulls: a tank's opener on a line-of-sight pull, and quick kills while you're still drinking, are both kept now.**

## Fixed
- **A tank's opener was lost on a line-of-sight pull.** The tank hits a mob and pulls it back to the raid before anyone else is in combat. That opener made a pull of its own, which ended while the mob ran back and was thrown away as too short. That cost one tank 500 to 1,750 damage per pull in a Molten Core run, checked against Chronicle. A pull too short to keep is now held for 30 seconds. A fight that starts in that time carries on in it, opener included. Combat time only counts the fighting, so the wait doesn't lower anyone's DPS.
- **Short fights were thrown away even when they hurt a mob.** One example is a quick kill while you were out of combat, still drinking. A short pull with no fight after it is now kept if your group damaged a mob, and dropped only when nothing was hurt at all (a critter, or the combat flag flickering). It's settled on logout and on zone change too.

## Install

Download `Wrekkit-0.9.32.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.32**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **UnitXP_SP3** makes the mob frame distances exact (optional).
- **aux** for consumable prices (optional).

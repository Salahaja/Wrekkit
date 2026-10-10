**Other tanks are found, shared and picked from a button. And a pull now lasts as long as anyone in the group is fighting, not just you.**

## New: other tanks
- **Found automatically.** A group member in Defensive Stance, Bear or Dire Bear Form, or with Righteous Fury counts as a tank, whether or not they run Wrekkit. Their threat and the mobs they hold don't set off warnings.
- **Shared with the group.** Marking or unmarking a tank does it for everyone in the party or raid running Wrekkit. Each Wrekkit also tells the group when its player is tanking, at any range.
- **Tank button.** A shield in the threat window's title bar lists the group's warriors, druids and paladins, with a check beside each tank. Click a name to change it, mark your target, or clear all.
- **Unmarking sticks.** Unmark someone by hand and detection won't mark them again. Use this for a tank spec who is DPSing.
- **Cleared with the group.** Marks are cleared once you've left the group, it has disbanded, or you log in solo.
- Both behaviours have a checkbox under Settings → Threat. `/wrek threat tanks` lists marked, found and unmarked players.

## Fixed: pulls
- **Damage done while you were out of combat is kept.** If you died, or dropped combat before the raid did, the rest of the fight used to be thrown away. That's why Wrekkit showed less damage than ShaguDPS. A pull now ends only once you, every group member and every pet are out of combat.
- **Pulls the tank starts before you're in combat are kept whole,** from their first hit.
- **A group member who stays in combat after a fight no longer holds the pull open.** This happens with a pet, or a mob walking back to its spot. Once nobody in the group has dealt or taken damage for 15 seconds, the pull ends, and the next pack is its own pull.
- Solo, nothing changes.

## Install

Download `Wrekkit-0.9.3.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.3**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

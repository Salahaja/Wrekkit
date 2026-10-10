**A pull now lasts as long as anyone in the group is fighting, not just you.**

## Fixed
- **Damage done while you were out of combat is kept.** If you died, or dropped combat before the raid did, Wrekkit ended the pull and threw away what the raid did after that. It recorded those events but kept splitting them into fights too short to save. That's why it showed less damage than ShaguDPS. A pull now ends only once you, every group member and every pet are out of combat, which is how damage meters time a fight.
- **Pulls the tank starts before you're in combat are kept whole,** from their first hit.
- **A group member who stays in combat after a fight no longer holds the pull open.** This happens with a pet, or a mob walking back to its spot. Once you're out of combat and nobody in the group has dealt or taken damage for 15 seconds, the pull ends. The next pack is its own pull.
- Solo, nothing changes: leaving combat still ends the pull.

## Install

Download `Wrekkit-0.9.3.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.3**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

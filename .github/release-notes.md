**Crit % is right now, and mob names no longer spill over each other.**

## Fixed
- **Melee crits are counted.** Wrekkit was looking for crits in the wrong place for vanilla, so melee crits were never counted. Crit % from melee was always too low.
- **Crit % only counts hits that could crit.** Damage-over-time ticks (Consecration, DoTs) and damage shields (Retribution Aura, Thorns) still count as damage, but they can't crit, so they no longer drag the percentage down.
- **Heal crits are separate.** They were being added to damage crit %. There's now a **Heal Crit %** metric of its own under Healing in the meter's metric menu. HoT ticks are left out, since they can't crit either.
- **Mob names stay on one line.** Long mob names, like "Expert Training Dummy", wrapped onto several lines in the mob window and covered the row below. They're now cut short with "…". Widen the window to see more of each name.

Pulls recorded before this update keep their old crit numbers.

## Install

Download `Wrekkit-0.9.14.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.14**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

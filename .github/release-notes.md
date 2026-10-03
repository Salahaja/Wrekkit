**Mob watching and mob frames now work with or without SuperWoW.**

## New
- **A group scan that works on any 1.12 client.** Wrekkit now reads what every member of your group is targeting, and what each of those mobs is targeting. Every mob anyone in the group has targeted is watched, with its health and who it is hitting.
  - **Without SuperWoW:**
    - **LOOSE detection** works, including the alert.
    - **Mob frames** work.
    - **The Taunt bar** reaches the mob through the group member targeting it.
    - Mobs with the same name are told apart by their health.
  - **With SuperWoW**, the scan adds to the nameplates. A mob that someone in the raid has targeted is listed and watched even when its plate is not on screen.
- Clicking a mob frame targets that mob in both setups.

## Note
Without SuperWoW, a mob nobody in your group has targeted stays unseen, and taunting a mob changes your target. SuperWoW is still recommended.

## Install

Download `Wrekkit-0.8.2.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.8.2**.

## Requirements

- **Nampower** is required for the damage meter and the report. The threat meter itself works without it.
- **SuperWoW** is recommended.

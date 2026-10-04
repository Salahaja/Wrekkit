**Mark the other tanks, and their threat and their mobs stop setting off warnings.**

## New
- **Other tanks are treated as tanks.** In a raid with three or four tanks, mark the others. Once marked:
  - A mob on one of them is held, not loose.
  - A mob taunted off you by one is not **LOST AGGRO** and doesn't show up on the Taunt bar.
  - One of them close to your threat is a swap being set up. It doesn't trigger the "closing in" warning or the flash, and the next non-tank is measured instead.
  - Mob frames stay calm about mobs whose closest runner-up is another tank.
- **Three ways to mark them:**
  - right-click their name in the threat window;
  - `/wrek threat cotank` with them targeted, or `/wrek threat cotank <name>`;
  - type their names under **Co-tanks** in Settings → Threat.

  `/wrek threat tanks` lists them. They show as **(tank)** in the threat window.

## Install

Download `Wrekkit-0.9.1.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.1**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

**Right-click a mob in the mob window to attack it.**

## New
- **Right-click a mob to attack it.** It targets the mob and starts melee. It never stops a swing already going: 1.12's attack command toggles auto-attack, so Wrekkit only starts one when you aren't already swinging.
- **"Right-click a mob" setting** (Frames & plates → Mob frames):
  - **taunt if tanking, else attack** (default): tanks keep their right-click taunt, and everyone else attacks.
  - **attack**: always attack.
  - **taunt**: always taunt, as before.

  Left-click still just targets.

## Install

Download `Wrekkit-0.9.24.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.24**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

**Filter boxes no longer eat your keyboard, and the screen-edge flashes are off unless you want them.**

## Fixed
- **A filter box clicked by accident no longer swallows your keys.** In 1.12 a text box keeps the keyboard until Enter or Escape, so a stray click into "Filter name" stopped you moving and casting. Every Wrekkit text box now releases the keyboard by itself:
  - when you click elsewhere;
  - when the cursor has been off its window for a moment, such as moving out into the game world;
  - when combat starts;
  - when its window closes.

  What you typed stays and keeps filtering.

## Changed
- **The meter's and the report's filter boxes fold into a small magnifier** while empty. Click it to open the box and type. It folds back once released with nothing typed, and stays open while a filter is in use.
- **Screen-edge flashes are off by default.** That's both "Flash screen edges" and "Pulse screen edges". Existing players have them switched off once; turn them back on in Settings → Threat and they stay on.
- **"Screen edge width"** sets how far the flash reaches in, from a 1px line up to 100px (default 30px, was 70px).

## Install

Download `Wrekkit-0.9.22.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.22**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

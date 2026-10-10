**Make the meter look the way you want: bar style, colours, font, class icons, and no empty space.**

Everything here is off, or unchanged, by default. Settings are on the **Meter** tab unless noted.

## New
- **Fit to rows.** "Fit meter to its rows", and on the Threat tab "Fit window to its rows", shrink the window to the players it shows, with no empty space under them. It grows back as more players appear, never taller than you sized it.
- **Bars.** Pick the bar texture separately from the look: flat (the pfUI/modern style), smooth or Blizzard.
- **Bar opacity.** 20–100%. Flat bars at around 85% give pfUI's solid bars.
- **Colours.** Pick the accent and text colours separately from the look: Blizzard gold, pfUI teal or modern amber. For example, pfUI's colours with Blizzard's frames. Applies after a `/reload`.
- **Font.** Choose the game's Friz Quadrata, Arial Narrow, Skurri or Morpheus. With pfUI installed you can also choose pfUI's font, Myriad Pro, Expressway or PT Sans Narrow. It changes as you click, and numbers keep their narrow font so columns stay lined up.
- **Class icons.** Each player's class icon beside their name in the meter, the report and the threat window. Vanilla can't tell an addon someone's spec, so there are no spec icons.

## Fixed
- **Less space above the meter's bottom bar.** The meter drops the partly-used row under the last player, and the bottom bar is slimmer.

## Install

Download `Wrekkit-0.9.11.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.11**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

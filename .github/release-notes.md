**Fixes a crash when moving the meter, plus drawing fixes. Update if you're on 0.9.11.**

## Fixed
- **Crash when moving the meter.** Dragging the meter, or another Wrekkit window, could crash the game with `ERROR #132`. While a window is being dragged, Wrekkit now leaves its size and position alone.
- **Bars reach the end of their row.** The top bar stopped short of the row's right edge. The game can report an out-of-date size for parts of a window, so Wrekkit now measures them from their edges.
- **Settings window.** The right-hand column no longer runs past the window's border, and the bottom row of each tab is no longer cut off.

## New
- **`/wrek layout`** prints the meter's real sizes. If something draws wrong, send its output along with a screenshot.

## Install

Download `Wrekkit-0.9.12.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.12**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

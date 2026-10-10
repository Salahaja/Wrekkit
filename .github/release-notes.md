**Choose how the meter's bars fill a window.**

## New
- **Rows** (Settings → Meter) decides how the bars use the window's height:
  - **Fixed height:** as before. Bars use your Row height, and the window holds as many as fit.
  - **Stretch to fill:** as many bars as fit at your Row height, stretched evenly to fill the window with no gap.
  - **Set number:** choose how many bars with **Rows shown**, and they stretch to fill the window.
  - **Fill with players:** however many players are shown fill the window. Each bar can grow to at most three Row heights, so one player isn't one giant bar.

  "Fit meter to its rows", when it's on, sizes the window to the players instead. With two metrics, each half fills its own space.

Also includes everything in 0.9.12: the fix for the crash when moving the meter, bars reaching the end of their row, and the settings window fitting its border.

## Install

Download `Wrekkit-0.9.13.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.13**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

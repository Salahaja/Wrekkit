**Show two metrics at once, like damage and healing, over and under or side by side.**

## New
- **Two metrics in the meter.** The **1+2** button on the meter's title bar steps through the layouts:
  - **1+2:** one metric, as before.
  - **1/2:** two metrics, one over the other.
  - **1|2:** two metrics, side by side.

  The second metric starts as Healing. Click a half's header to pick its metric, and right-click it to back out of a drilldown. Each half drills into players and abilities on its own. The layouts are also in the meter's right-click title menu, and under Settings → Metrics in the meter.

## Fixed
- **Narrow rows no longer draw names over numbers.** A row that's too narrow now drops its per-second column first, then shortens the name.

## Install

Download `Wrekkit-0.9.7.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.7**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

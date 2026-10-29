**Hit table, death recaps, exports, a time-to-pull-aggro estimate, and much smaller meter and threat windows.**

## New
- **Hit table.** White swings that missed, were dodged, parried or fully blocked were dropped on arrival, so they were never counted. They are now. A **Hit Table** tab in the report, and **Miss % (hit table)** and **Glancing blows** in the meter, rank everyone: miss % counts true misses and fully resisted spells, with dodge % beside it. Click a player to see each attack's rates, then an attack for glancing blows: how many, their damage, what a glance did against an ordinary hit, and what glancing cost. A tank's crushing blows are counted on the damage they took.
- **Death recap.** Each player's last 10 seconds are kept: every hit taken, every heal that reached them (with overheal) and every hit they dodged, parried or blocked, with their health after each. The recap opens with what killed them, the damage they took and from whom, and the healing they got and from whom. Click a death on the report's timeline to open it.
- **Export.** The report's new **Export** button, the meter's **Export...** and `/wrek export` save what is on screen, or a priced **consumables list** (each player's consumables, counts and cost, their deaths, who used nothing, then each consumable and who used it), as a text file under `CustomData\` to drag into Discord. They can also open it in a box to copy from, or take a screenshot.
- **Threat window:**
  - **Time to pull aggro** (mine or everyone's): seconds until a player pulls aggro at their and the tank's threat per second, averaged over 20 seconds (10-60) so a single crit does not jolt it.
  - **Keep my row at the top.**
  - **Text size** of its own.
  - **No title bar**: the window fits its rows and can go down to 90px wide.
- **Meter:** **Raid Contrib by effect** and the **Death log**, as in the report, both announced as shown.
- **Announce:**
  - **Top 3 / 5 / 10** buttons, remembered for the next post.
  - Any line can be clicked out.
  - **Fewer messages** joins lines into as few chat messages as fit.
  - The Deaths tab posts the death list, or an opened death's recap.

## Changed
- **Tanking, the % is your hold**: 100% while nobody is near, falling as the closest player catches up, like a health bar. It used to show the runner-up's own %, so a mob held safely read 0%. Damage dealers and healers still see their own %.
- **Every threat warning, alert, flash and the taunt popup is off by default.** This only changes the defaults: your saved settings stay as they are, and the Threat tab's **Defaults** button applies the new ones.
- **Narrow windows:** narrow meter rows drop the rank number and keep one icon, and long names keep their first letters instead of "...". A compact meter goes down to 120px, in split view too. Narrow threat rows show the name, threat per second and the bar.
- **Raid Contrib posts say what each number is:** "+22.8k damage", "+12.3k mana".
- **Another player's drink or food** counts as **Drink** or **Food**, unpriced. Before, it took the name and price of whatever you last ate.

## Fixed
- **Heals on you were counted twice.**
- **A pull that ended with its mobs alive** (pulled back, kited) was split in two. It now waits for the rest of its fight.
- **Announcements set off the server's spam alert** at about ten lines. They now go eight messages at a time, then the rest after a pause.
- **An attack's "Missed" counted dodges and parries too**, on top of their own lines.
- **Long names in titles** ran under the window buttons and past the edge of the threat window and the meter. The meter's filter also covered the Pets button.
- **The announce window's Top setting** drew outside the window.

## Install

Download `Wrekkit-0.9.35.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.35**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars, raid value and exports to a file. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **UnitXP_SP3** makes the mob frame distances exact (optional).
- **aux** for consumable prices (optional).

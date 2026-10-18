**The filter box is a proper button now, and it stays its own size.**

## Changed
- **The folded filter is a "Filter" button**, drawn in your skin (Blizzard, pfUI or Wrekkit's own) like the Pets and Report buttons beside it, instead of a spyglass icon.
- **It opens to 80px**, enough for any name, instead of 110–120px.

## Fixed
- **Resizing the meter no longer stretches the filter box.** It used to grow with the window and wouldn't fold back to its button. It now stays 40px folded and 80px open, whatever size the window is.

## Install

Download `Wrekkit-0.9.23.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.23**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

**A TANK button, click a player to warn them, and the threat meter stays up when you die.**

## New
- **TANK button.** It's in the threat window's title bar and shows **TANK** (you're the tank, whatever your stance), **AUTO** (detected from stance, form or Righteous Fury) or **DPS** (never). Left-click switches between TANK and AUTO, and right-click picks DPS. It's lit blue while you count as the tank, and your group's Wrekkit is told right away.
- **Click to warn.** Left-click a player in the threat window, or a mob's row while tanking, to tell them their threat: "your threat is 94% on Ragefang - ease off!"
  - Someone running Wrekkit gets a big on-screen alert with the raid-warning sound.
  - Anyone else gets a whisper.
  - It's only sent when you click, and at most once per person every 5 seconds.

## Fixed
- **Dead, you still see the threat.** Dying used to clear the threat meter, hide its window and stop it watching for mobs going loose, as if the fight were over. It now keeps going while anyone in your group is still fighting.

## Install

Download `Wrekkit-0.9.6.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.6**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

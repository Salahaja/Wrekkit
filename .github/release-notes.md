**Hunters: right-clicking a mob in the world can start Auto Shot instead of a useless melee swing.**

Off until turned on, in Settings → Frames & plates → Mob frames.

## New
- **Hunters: right-click a mob shoots** (off until turned on). Right-clicking a mob in the world makes the client start a melee swing. With this on, Wrekkit checks the range when that swing starts, or when you change target mid-swing:
  - 8 yards or more away, it casts Auto Shot, which takes over from the swing.
  - Closer, the swing stays.
  - It never re-casts Auto Shot while it is already going, so nothing gets switched off.
  - It only applies to hunters.
  - If the client won't let it start Auto Shot, Wrekkit says so once in chat.

## Install

Download `Wrekkit-0.9.28.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. This release adds a file, so **fully restart the client**; a `/reload` won't load it. `/wrek status` should then report **v0.9.28**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional).

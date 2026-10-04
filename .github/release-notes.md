**Boss pulls are told apart from trash again, and a whole raid week is kept.**

## Fixed
- **Trash saved as bosses.** A pull counted as a boss if the biggest enemy had 40,000 health or more. Nearly all Molten Core trash is above that, so almost every pull was marked BOSS. A pull is now a boss if:
  - the game calls the enemy a world boss;
  - the enemy shows the skull level (with you at 54 or higher, a skull can only mean a boss);
  - or it is a known raid or world boss by name. This covers Molten Core (including Turtle's Incindis, Basalthar, Smoldaris and Sorcerer-Thane Thaurissan), Onyxia, BWL, ZG, AQ20, AQ40, Naxxramas and the world bosses.

  In a raid, trash with a lot of health is now trash. Outside a raid, health is still used, since that's the only way to tell a 5-man boss from its trash.
- **Fights already saved are re-checked once** when you log in, and chat says how many changed. Ones you marked by hand are left alone. Older saves didn't record enough about the enemy, so they are judged by name alone. A boss that isn't in the list can be re-marked with one click on its row.
- **A boss fight is named after the boss,** even when an add has more health.
- **History lost bosses from a long night.** It used to keep only the newest 60 pulls, which a full clear with trash goes past. It now keeps **every pull from the last 7 days**, a raid week, **with no limit on how many**.
  - Settings → Recording → History has *Keep pulls for* (1–90 days) and *Keep at most* (**no limit** by default).
  - If you never changed the old 60-pull limit, it moves to no limit automatically.
  - Locked pulls are kept however old they are.

## Install

Download `Wrekkit-0.8.3.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.8.3**.

## Requirements

- **Nampower** is required for the damage meter and the report. The threat meter itself works without it.
- **SuperWoW** is recommended.

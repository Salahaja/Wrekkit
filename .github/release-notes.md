**Specs fill in as you target people.**

## Fixed
- **Specs now come in for other players.** On this server a player only answers a talent inspect while the person asking has them targeted. That's why most of the group never showed a spec, and why the game's own Inspect seemed not to work. Wrekkit now asks a player the moment you target them, even in combat. It won't ask again if their spec is already known from the last 15 minutes. Healers, who target the whole raid, will collect nearly everyone's quickly.
- Players you never target still get a spec guessed from abilities only a deep talent gives (shown with a **?**).
- `/wrek inspect <name>` reminds you that the player usually needs to be your target.

## Install

Download `Wrekkit-0.9.16.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.16**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

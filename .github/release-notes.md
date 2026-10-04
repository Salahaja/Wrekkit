**Each raid ID gets its own file, so keeping or deleting a raid is one click.**

## New
- **One file per raid ID.** Each pull is written to a file for its lockout as soon as it ends: `CustomData\Wrekkit_<character>_<zone>_<raid ID>.txt`. Two nights on the same Molten Core lockout share a file.
- **Dungeons too.** They have no lockout ID, so each dungeon run gets its own file, named by date and time.
- **Less memory, smoother play.** SavedVariables now keep only the night in progress (the last 12 hours) plus anything you locked. A week of raiding no longer sits in the game's memory, where it made every garbage collection longer.
- **Older raids open on demand.** The report's session menu lists them under **Saved raids and runs**. Picking one reads its file. Only one is held in memory at a time.
- **Keep or delete one raid.** With a raid on screen, the session menu offers **Keep it past 7 days** and **Delete it…**, which removes that raid and nothing else. From chat: `/wrek raids` lists them, and `/wrek raids open|keep|delete <n>` acts on one.
- **No hitch after a fight.** Writing a 40-player pull is spread over a few frames instead of one.
- Your existing history is moved into files the first time you log in, a few frames at a time, and chat says when it is done.

## Fixed
- **The report changed what it was showing by itself.** When a new session began, the window switched to a different night and dropped the fights you had picked. It now stays on what you picked.

## Notes
- Needs Nampower's file API. Without it, or with Settings → Recording → History → *Save each raid to its own file* turned off, the history stays in SavedVariables as before.
- Raids are kept for 7 days unless you keep them (*Keep pulls for* in the same settings).
- The game cannot delete files, so a deleted or expired raid's file is emptied rather than removed. You can delete empty files yourself.
- Opening a big old raid takes a moment, since the whole file is read when you pick it.

## Install

Download `Wrekkit-0.9.0.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.0**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

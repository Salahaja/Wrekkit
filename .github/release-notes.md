**Fixes the "error in archive" message at the end of every pull.**

## Fixed
- **Per-raid files are written again.** 0.9.1 showed `Wrekkit error in archive: ... attempt to index global 'coroutine'` after each fight and never wrote the pull to its raid's file. The 1.12 client has no coroutine library. The pull is still turned into text a little each frame, just without one.
- **Nothing was lost.** A pull that didn't make it to its file stayed in SavedVariables, and it is written on the next login.

## Install

Download `Wrekkit-0.9.2.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.2**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

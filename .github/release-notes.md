**Fixes "error in archive: attempt to perform arithmetic on field `huge`".**

## Fixed
- **Per-raid files are written again on every setup.** Writing a pull to its raid's file used `math.huge`, which doesn't exist in this client's Lua. It only worked when some other addon happened to supply it, so with a different addon set every write failed with the error above.
- **Nothing was lost.** A pull is only marked as saved once its file is written. Pulls that hit the error stayed in SavedVariables and are written on your next login.

## Install

Download `Wrekkit-0.9.5.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.5**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

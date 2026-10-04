**The report stays on what you picked.**

## Fixed
- **The report changed what it was showing by itself.** The window remembered which session you were viewing by its place in a newest-first list. When a new session began (a new zone, or the first pull after a long break), every older session moved down one place. The window then showed a different night, and the fights you had picked no longer matched, so it fell back to "All encounters".

  It now remembers the session itself. Picking fights, or choosing a session from the menu, keeps you there until you change it. Until you pick something, it follows the newest session as before.

## Install

Download `Wrekkit-0.8.5.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.8.5**.

## Requirements

- **Nampower** is required for the damage meter and the report. The threat meter itself works without it.
- **SuperWoW** is recommended.

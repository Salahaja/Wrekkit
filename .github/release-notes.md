**aux's full scan works again, and Scan consumes now pages through the auction house like aux does.**

## Fixed
- **aux's full scan works again.** Since 0.9.19 it could fail. A Wrekkit scan left running would grab aux's page results and fire its own search in the middle of aux's scan. And Wrekkit read prices through aux's own lookup code, which writes as it reads, while aux was scanning. Now Wrekkit reads aux's saved prices directly and never calls aux's code. If any other search's results arrive during a Wrekkit scan, Wrekkit stops its scan and leaves them alone.
- **Scan consumes works on any character.** A bank alt with no raids recorded used to scan just one item. It now covers every consumable.
- **Scan consumes never sits on "Scanning".** If the auction house stops answering, the scan stops and tells you to reopen it. `/wrek scan status` shows exactly where a scan is.

## New
- **Scan consumes is much faster.** It pages through the Consumable category the way aux does, then name-searches only the few consumables the auction house files elsewhere: oils, stones, explosives, runes, dummies, Jujus and Holy Water. That's a few dozen searches instead of hundreds, and none are wasted on things that are never listed, like healthstones. Each answer is read and the next search sent immediately, so it runs as fast as the server answers.
- **aux's scans count.** When you close the auction house, today's aux prices for every consumable are taken in and shared with your guild, so a full aux scan prices everything by itself.

## Install

Download `Wrekkit-0.9.21.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.21**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **aux** for consumable prices (optional). **AuctionQueryThrottle.dll** makes Scan consumes much faster.

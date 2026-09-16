# Wrekkit

Raid analysis that lives in the client. Records damage, healing, deaths and
a timeline as you fight, and lets you review it afterwards without uploading
a log, opening a browser, or paying anyone for hosting.

Built for WoW 1.12 (vanilla) on a SuperWoW + Nampower client.

---

## Why this can exist

Nampower delivers structured combat events straight to Lua — with GUIDs,
spell ids, crit and periodic flags and mitigation breakdowns already parsed:

```
AUTO_ATTACK_SELF / _OTHER        SPELL_DAMAGE_EVENT_SELF / _OTHER
SPELL_HEAL_BY_SELF / _OTHER      SPELL_MISS_SELF / _OTHER
SPELL_DISPEL_BY_SELF / _OTHER    DAMAGE_SHIELD_SELF / _OTHER
ENVIRONMENTAL_DMG_SELF/_OTHER    UNIT_DIED
```

That is the same data a combat log file contains, arriving in memory at the
moment it happens. A log site's parser is doing no work the client cannot do
itself — so Wrekkit skips the file, the upload and the server, and aggregates
in place.

SuperWoW supplies the unit metadata on top: `UnitName`/`UnitClass`/
`UnitHealth` accept a GUID, `GetUnitGUID(guid.."owner")` resolves a pet to
its owner, and `SpellInfo(id)` turns a spell id into a name and icon.

---

## Requirements

No other addon, and no embedded library. `tools/audit.lua` records every
external API the addon actually reads and reports anything it cannot account
for; the full list is 19 stock 1.12 calls, 4 Blizzard UI globals, and the
following two client mods:

| Needs | For | If absent |
| --- | --- | --- |
| **SuperWoW** (`SuperWoWhook.dll`) | `SpellInfo`, `GetUnitGUID`, `GetUnitData` — unit lookup by GUID, pet owners, spell names | every call is guarded; units fall back to the raid roster and spells show as `Spell <id>` |
| **Nampower** (`nampower.dll`) | the combat events themselves, plus `WriteCustomFile` / `ReadCustomFile` for the crash journal | every call is guarded; without the events nothing records at all, and without the file API the journal is skipped and SavedVariables alone carry history |

**On OctoWoW, both are one click.** Open OctoLauncher, go to the mod list
and enable them:

| mod | launcher version | needed |
| --- | --- | --- |
| **Nampower** | v4.6.2 | **required** — nothing records without it |
| **SuperWoW** | v2.2 | strongly recommended — without it rows have no names |

Neither is enabled by default, which is the usual reason Wrekkit records
nothing on a fresh install. Wrekkit checks for both on load and names the
launcher toggle rather than silently recording nothing; `/wrek status`
reports the same thing at any time.

Every one of those calls is guarded, so a missing mod degrades the addon
rather than erroring. `tools/test_degraded.lua` runs the addon with each mod
removed and measures what survives:

| | SuperWoW + Nampower | Nampower only | SuperWoW only | Neither |
| --- | --- | --- | --- | --- |
| loads, windows open, commands work | yes | yes | yes | yes |
| **records combat at all** | yes | yes | **no** | **no** |
| names and classes on the rows | yes | **no** | – | – |
| spell names in the drilldown | yes | **no** | – | – |
| crash journal on disk | yes | yes | **no** | **no** |

**Nampower is the hard requirement** — it emits the combat events, and they
are the data. Without it the addon is perfectly healthy and completely
empty, so it says so twice: at login, and again the first time you leave
combat having seen no events.

**SuperWoW is degradable.** Without it everything is still recorded and the
totals are still right, but rows have no name or class and abilities read as
`Spell 11267`. Usable in a pinch, unpleasant.

It sets the `NP_Enable*Events` CVars itself, so it works whether or not
ChronicleCompanion is also running — the two are independent, do not
conflict, and can be used together.

---

## Using it

The live meter is **shown by default**. `/wrek` toggles it, `/wrek report`
opens the full view, and the minimap button does both (left-click,
right-click).

To hide the meter: the **X** in its title bar, or *Hide meter* in the segment
menu (right-click the title). That choice is remembered — it stays hidden
next login until you bring it back with `/wrek` or the minimap button, which
the addon tells you when you close it.

### Live meter

Deliberately spare, so it can sit on screen during a pull.

| Action | Does |
| --- | --- |
| click the segment | pick Current / last pull / All Session |
| the cog | settings: compact mode, text size, recording, history |
| left-click title | metric menu — damage, dps, healing, hps, overheal, taken, deaths, dispels, interrupts, crit %, enemy damage |
| right-click title | segment menu — current pull, last pull, all session |
| left-click a row | that player's ability breakdown |
| left-click an ability | full detail for it (see below) |
| right-click a row | back out |
| drag the corner | resize; row count follows the height |
| `Pets+` button | fold pets into their owner, or split them out |
| search box | filter by name |

Three icon toggles sit on the toolbar, lit when active:

| Icon | Does |
| --- | --- |
| 👥 | count only your party or raid, ignoring everyone else nearby |
| 🌐 | record combat outside instances too (off by default) |
| ↺ | left-click starts a new log; right-click deletes the history, behind a confirmation |

### Settings

The cog on either title bar opens the options window: compact mode, text
size, row height, what gets recorded, how long a break still counts as the
same session, how much history to keep. `/wrek config` opens it too.

Every control reads and writes the live setting rather than a copy, so it can
never disagree with the toolbar toggles or the slash commands, and everything
applies immediately -- a panel that needs a `/reload` teaches people not to
trust it.

**Compact mode** (`/wrek compact`) drops the toolbar and the footer and
tightens the rows, for a meter that can sit on screen permanently.

**Text size** scales the pixel dimensions along with the letters. Scaling type
without scaling what contains it just clips it, which is the usual way a text
size option ends up useless.

### Starting a new log

The reset button closes the current session and begins a fresh one. Pulls
recorded from that point are separate from everything before, so the meter
reads empty until you fight again — but nothing is deleted, and the previous
session stays in the report's sidebar.

This has to override the session-rejoining described below, or the two would
cancel out: rejoining is keyed on "same zone, recent activity", which is
exactly the situation right after a reset. A reset therefore records a
barrier timestamp, and nothing that finished at or before it is ever rejoined.

`/wrek reset all` is the destructive one. It empties the journal on disk as
well as the saved history — otherwise the next login's crash recovery would
restore precisely what you asked it to delete.

### Announcing to chat

**Report:** the *Announce* button in the header.
**Meter:** right-click the title → *Announce to...*
**Anywhere:** `/wrek announce` (optionally `/wrek announce raid`).

It posts **what is on screen** — the metric you are looking at, the
encounters you have selected, with your filters applied. The report follows
the open tab, so Healing posts healing and Deaths posts deaths; Summary shows
two panels side by side, so it posts both rather than silently picking one.

Every route goes through the same confirmation, which shows the exact lines
and, in large type, **where they are going** and how many people will read
it. Public channels are tinted as a warning. Cancel sends nothing; only
*Send* posts.

There is deliberately no one-click path to chat and no "just send it" API —
chat is public and irreversible, and the mistake worth preventing is not
wrong numbers, it is the right numbers in the wrong channel. Lines are paced
a few tenths of a second apart so the client's chat throttle never drops
them.

An active filter is named in the header (`[group only]`), because a top-5
that quietly excluded half the raid is worse than no post at all. If more
people were ranked than shown, the last line says how many were left out.

### Sharing logs with other people

Off by default. Turning it on broadcasts your name and what you have
recorded, which is not something to enable on someone's behalf.

```
/wrek sharing on          let others see you and pull your logs
/wrek channel raid        auto | raid | party | guild
/wrek peers               open the browser
```

`auto` picks raid, else party, else guild. Picking a specific channel and
not being in one is refused rather than silently ignored.

**The browser** (`/wrek peers`, the *Shared* button in the report, or
*Browse* in settings) lists who is running Wrekkit, what they have, and lets
you take only the logs you want:

1. **Look for players** — one broadcast; everyone running Wrekkit answers.
2. **Click a name** — asks that one person for their log list.
3. **Tick the logs you want, press Sync** — asks for exactly those.

Nothing is fetched until it is asked for. A raid-wide browse costs one
broadcast and a short exchange with whoever you clicked, rather than everyone
pushing their whole night at everyone else. Logs you already hold are marked
`have`, and pulling the same one twice replaces it rather than leaving two
copies.

**Every message is a broadcast with a name on it.** 1.12 has no directed
addon channel: `SendAddonMessage` accepts PARTY, RAID, GUILD and
BATTLEGROUND only, and handing it `"WHISPER"` does not fail politely — the
client reports "Unknown addon chat type" and can take the process down with
it (ERROR #132). So each message carries an addressee as its first field,
and receivers drop anything not addressed to them. A raid-wide "send me your
index" is answered by one person, not twenty-five, because the request names
who it is for.

Guildmates who are not the addressee discard it exactly the way they discard
any unrecognised prefix, so the cost is bandwidth on a channel you chose —
not noise anyone sees.

You can browse without being listed yourself. Pulling *from* someone needs
them to have sharing on; looking does not need you to.

### Keeping encounters

Every encounter in the report's sidebar has a padlock. Click it and that
encounter is **kept**: the ring buffer will not evict it, `/wrek prune` skips
it, and `/wrek reset all` leaves it behind. Unlock it first if you really
want it gone.

A lock that a later cleanup silently overrides is worse than no lock, because
it invites people to trust it — so nothing deletes a kept encounter, and the
ring buffer is allowed to exceed its cap rather than break that promise.

```
/wrek keep               lock the most recent encounter
/wrek prune              delete unlocked encounters older than 7 days
/wrek prune 30           ... older than 30 days
/wrek prune all          delete every unlocked encounter
```

Pruning rewrites the on-disk journal to match, so recovery can never restore
something that was just deleted.

### Consumables

The **Consumables** metric ranks who is burning potions, elixirs, flasks,
scrolls, bandages and food -- the "is that parse bought or played" question.
Clicking a player breaks it down by item.

This needs no list of consumable spell ids to maintain. Nampower's SPELL_GO
event carries the item that triggered a cast as its first argument: zero for
an ordinary spell, non-zero for an item. "Did this cast come from an item" is
therefore true by construction, and anything this server added itself is
picked up for free.

### Ability detail

Clicking a player opens their abilities; clicking an ability opens its full
spread — total, landed, missed, crits and crit rate, average, **average
normal and average crit separately**, largest and smallest.

The split average is the point. A spell that hits for 800 and crits for 1600
has a blended "1,040 average" it never once dealt; reporting normal and crit
apart tells you what the spell actually does. That needs crit damage tracked
separately at capture time, which is why it is a first-class field rather
than something derived later.

### Report

Sidebar lists the night's encounters; click one, or right-click several to
build a selection, or `All encounters` to merge the whole night — that is
what makes the header read "16 encounters selected".

Tabs: **Summary** (timeline chart plus damage and healing side by side),
**Damage**, **Healing**, **Taken**, **Enemies**, **Deaths**.

The timeline is a rolling average of damage done, damage taken and effective
healing, with a red tick at every player death. Click a legend entry to hide
that series.

---

## Commands

```
/wrek                    toggle the live meter
/wrek report             open the full report
/wrek mode <metric>      set the meter metric
/wrek modes              list every metric
/wrek segment <what>     current | last | overall

/wrek save               write history to CustomData\Wrekkit_<char>.txt
/wrek load               read that file back in
/wrek reset              start a new log (history is kept)
/wrek reset all          delete every encounter, on disk too
/wrek keep               lock the last encounter so nothing deletes it
/wrek prune [days|all]   delete unlocked encounters (default: older than 7d)

/wrek peers              browse who is sharing and pull their logs
/wrek sharing on|off     let others see you and pull your logs
/wrek channel <chan>     auto | raid | party | guild
/wrek share [chan]       push the last pull at a channel
/wrek request            look for other Wrekkit users
/wrek announce [metric]  post the top 5 to chat

/wrek config             open the settings window
/wrek compact            toggle the small meter layout
/wrek status             diagnose why nothing is being recorded
/wrek who                list every actor and how it was classified
/wrek lock               lock the meter in place
/wrek resume <minutes>   how long a break still counts as the same session
/wrek group              count only your party/raid, ignore everyone else
/wrek world              also record open-world combat (off by default)
/wrek accept             toggle accepting shared reports
/wrek minimap            toggle the minimap button
```

Escape closes the report window. It deliberately does **not** close the live
meter — that is a HUD element meant to stay put, and having it vanish when
you press Escape to clear a target would be a surprise, not a convenience.

## Surviving interruptions

A raid night gets interrupted: a disconnect, a server restart, a crash, a
`/reload` to fix some other addon. Two separate mechanisms keep that from
shredding the night into unusable fragments.

**Sessions rejoin themselves.** When combat starts, Wrekkit checks the last
session it recorded. Same zone, and last activity within 20 minutes? It
continues that session — same id, encounter numbering carries on, and the new
pulls land further along the same timeline instead of back at zero. A longer
gap is treated as a new raid. `/wrek resume <minutes>` changes the window.

The timeline offset is wall-clock based for exactly this reason: `GetTime()`
resets to zero every time the client starts, so a `GetTime`-based offset would
stack post-crash encounters back at the beginning of the night.

**The journal survives a crash.** SavedVariables are written *only at a clean
logout*, so a crash loses the whole night no matter how carefully it was
aggregated in memory. Wrekkit therefore appends each encounter to
`CustomData\Wrekkit_<character>.txt` the moment it ends, through Nampower's
file API. On the next login, if the history is empty but the journal is not,
it restores automatically and says so.

Recovery reconstructs the session too, deriving it from the restored
encounters rather than the saved pointer the crash destroyed — so the night
continues into the same session rather than starting a third one. Loading is
idempotent: encounters are matched by session and id, and the in-memory copy
wins, so running `/wrek load` twice changes nothing.

`/wrek save` still exists for a full compacted rewrite of the file.

## Saving and sharing

**SavedVariables** hold the rolling history automatically (60 encounters by
default, `WrekkitDB.maxEncounters`).

**The journal** at `CustomData\Wrekkit_<character>.txt` is appended to as each
encounter finishes (see *Surviving interruptions* above). It is plain text,
readable outside the game, survives a SavedVariables wipe, and `/wrek load`
imports it on any character. `/wrek save` rewrites it as a compacted
snapshot. Both are idempotent — encounters are identified by session and id,
so importing the same data twice cannot double any number.

**`/wrek share`** sends the last pull over the addon channel to anyone else
running Wrekkit, in the background, throttled so it cannot contribute to a
disconnect. They get it in their own history, filterable with their own
filters — the replacement for sending someone a link. Received encounters
are filed under their own session so they can never be merged into, or
confused with, what you recorded yourself.

**`/wrek announce`** posts a readable top 5 to party/raid/guild chat, which
is the only route that reaches people not running the addon.

---

## What it can and cannot know

Honest limits, all of them inherited from what vanilla exposes — the website
worked under the same ones:

- **Range.** The client only receives events for things it can see. Someone
  healing across the room from you is recorded; someone in a separate wing
  is not. This is why sharing exists.
- **Overhealing is derived, not reported.** Heal events carry the raw
  amount only. Wrekkit tracks each unit's health forward from damage and
  healing events, resyncing against `UnitHealth` every 0.4s, and splits the
  heal against the deficit it finds. A resync landing between a heal
  applying and its event arriving can under-count that one heal.
- **Interrupts are inferred.** Vanilla has no interrupt event, so Wrekkit
  counts Kick / Pummel / Shield Bash / Earth Shock / Counterspell landing on
  an enemy. That is an interrupt *attempt* that connected, not a confirmed
  cast stop.
- **No raw event log.** Rollups are summed as events arrive; raw events are
  never stored. A 25-man night is ~57k events, and keeping them would cost
  more memory than the client can spare. The one thing this gives up is
  re-filtering after the fact, which is the single feature a log site keeps.
- **Open-world combat is ignored** by default, so questing does not bury
  the raid history. `/wrek world` turns it on.

---

## Development

Nothing here is required to use the addon.

```
lua tools/audit.lua                          dependencies + completeness
lua tools/test_degraded.lua <scenario>       full | nosuper | nonam | neither
lua tools/vanilla_lint.lua *.lua ui/*.lua    1.12 / Lua 5.0 compatibility
lua tools/test_engine.lua                    capture, aggregation, save, sync
lua tools/test_ui.lua                        builds and drives both windows
lua tools/make_textures.lua                  regenerate textures/*.tga
lua tools/tga2png.lua                        preview those outside the game
```

`audit.lua` is the one that answers "is this complete and what does it
need". It proxies the global table, so every external API the addon touches
is recorded as it is read rather than guessed at by regex, and each is tagged
with its origin — anything unrecognised is reported as an undeclared
dependency. It loads the files in exact `.toc` order, so a load-order mistake
fails there rather than in the client, then drives a full session and reports
**function-level coverage**, naming anything it never called. An untouched
function is unverified, however green the rest looks.

Run all three checks before shipping a change. The lint matters most: vanilla
runs **Lua 5.0**, so `#t`, `a % b`, `string.gmatch`, `...`, `goto` and
bitwise operators all parse fine under a modern Lua and then fail to load in
the client. The test harnesses install 5.0 spellings so the addon cannot
quietly drift toward syntax that only works outside the game.

`test_ui.lua` stubs the 1.12 widget API strictly — an unstubbed method is an
error, not a silent no-op — so a misspelled widget call is caught here
instead of mid-raid. It checks that every path runs, not that anything looks
right; that still needs the client.

### Art

All textures are generated, not drawn: `tools/make_textures.lua` emits
uncompressed 32-bit BGRA top-down TGAs at power-of-two sizes, which is what
1.12 loads from an addon folder. Shapes are supersampled 4�—4 for
anti-aliasing, and most are authored white so the addon can tint them at
runtime — one bar texture serves every class colour.

There is no drawing API in this client and no texture rotation, so the
timeline chart is built from the only primitive available: rectangles. A
"line" is a column of 1px caps, the area beneath it is a second stretched
column, and the pool is fixed at 150 columns per series regardless of fight
length, so the texture count stays bounded.

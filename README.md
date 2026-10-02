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

The live meter is **shown by default**, with the threat meter docked
underneath it once you are in a group. `/wrek` toggles the meter,
`/wrek report` opens the full view, and the minimap button reaches all of it:

| minimap | |
| --- | --- |
| left-click | live meter |
| right-click | full report |
| shift-click | threat window |
| shift-right-click | settings |

To hide the meter: the **X** in its title bar, or *Hide meter* in the window
menu (right-click the title). That choice is remembered — it stays hidden
next login until you bring it back with `/wrek` or the minimap button, which
the addon tells you when you close it.

### Looks

Wrekkit dresses itself to match the rest of your UI, built from the same
art the game and its UI addons use -- not boxes of its own:

| Look | |
| --- | --- |
| **Blizzard** | the stock UI's own pieces: tooltip borders on the meter, threat window, mob frames and taunt bar; the parchment dialog border and header plate on Settings and the Report; dropdown menus with the gold highlight bar and check mark; the red panel buttons; the stock checkboxes; the red X close button; the chat window's size grabber; the target frame's status-bar texture; gold titles; the action bar's cooldown sweep on the taunt button |
| **pfUI** | pfUI / ShaguPlates: dark backdrops, one-pixel borders, flat bars. With pfUI loaded it calls pfUI's *own* backdrop function and uses pfUI's bar texture and font, so Wrekkit follows your pfUI settings exactly |
| **modern** | Wrekkit's own flat dark panels |

**auto** (default) picks pfUI when pfUI or ShaguPlates is loaded, Blizzard
otherwise. Change it under Settings -> Meter -> *Look*; it asks to reload,
because a look is how a frame is built, not a coat painted over it.
Nameplate threat text uses the same face as the plates it sits on.

### Live meter

Deliberately spare, so it can sit on screen during a pull.

| Action | Does |
| --- | --- |
| click the segment | which pulls: current, each of the last few by name, all session |
| the cog | settings |
| left-click title | metric menu, in groups — Damage, Healing, Survival, Utility, Enemies, and live Threat |
| right-click title | window menu — report, threat window, announce, compact, toolbar, lock, new log, hide |
| left-click a row | that player's ability breakdown |
| shift-click a row | pick or unpick that player (see ★ below) |
| left-click an ability | full detail for it (see below) |
| right-click a row | back out |
| drag the corner | resize; row count follows the height |
| `Pets+` button | fold pets into their owner, or split them out |
| search box | filter by name |

Four icon toggles sit on the toolbar, lit when active:

| Icon | Does |
| --- | --- |
| 👥 | count only your party or raid, ignoring everyone else nearby |
| ★ | show only the players you picked; right-click to see or clear the picks |
| 🌐 | record combat outside instances too (off by default) |
| ↺ | left-click starts a new log; right-click deletes the history, behind a confirmation |

### Threat meter

Live threat for your target, **straight from the server** rather than
estimated from the combat log. OctoWoW answers the same `TWT_UDTSv4` request
Turtle WoW's TWThreat uses, so the numbers are the server's own -- no spell
tables to go stale, no guessing at talents or stances. TWThreat can run
alongside it; each makes the other's replies more frequent, not wrong.

It needs a **party or raid** (the request travels on the group channel) and,
by default, an **elite or boss** target, which is all the server reports on.

**Where it shows** -- pick one in *Settings -> Threat*, from the threat
window's title menu, or with `/wrek threat <where>`:

| mode | |
| --- | --- |
| `docked` | (default) hangs under the damage meter at its width and moves with it |
| `window` | its own window, moved and sized independently |
| `meter` | no window; the damage meter turns into the threat meter while you fight and goes back to what it showed afterwards |
| `off` | no window -- frames, plates and warnings still work |

*Window appears* decides when: **in a group** (default -- alone the server has
nothing to say), **in combat**, or **always**. *Threat* is also in the meter's
metric menu in every mode.

**Rows** show threat, threat per second and a percentage, with a red
**pull-aggro line** at the threat where aggro would move to you. Aggro moves
at 110% of the tank's threat in melee range and 130% at range, so the
percentage defaults to *% to pull* -- 100 means it moves now. *% of tank*
shows the raw tank-relative number instead.

#### Tanking

*I'm the tank* is **auto** by default: Defensive Stance, Bear / Dire Bear
Form or Righteous Fury make you the tank, and shifting out makes you not --
a druid who drops form to heal stops getting tank alerts without touching
anything. *Always* and *never* override it.

As the tank, Wrekkit asks the server about **every mob you hold**, not just
your target, and:

- lists them under *Mobs you are holding*: each mob, the player closest to
  pulling it, and how close -- blue while safe, orange, then red
- alerts **"Stabbs at 88% on Onyxian Whelp"** when anyone crosses *...at*
  (85% of the way to pulling, by default) on any of them
- alerts **"LOST AGGRO: Onyxian Whelp"** when one turns away, and writes
  `LOST` on its nameplate for a few seconds. A mob that *died* is not lost
  aggro, and is not announced as such
- shows the runner-up's distance on the target frame and on every held
  mob's nameplate, instead of your own number

**Mobs you are not targeting.** On a pull of two, five or seven mobs, the
one that matters is rarely the one you have targeted, so all of them are
watched:

- **Held but slipping**: the server reports every mob you hold. Each one's
  nameplate shows how close its runner-up is, and **blinks** once that
  reaches your flash limit. The target frame shows a one-line count under
  the %: `5 held  2 slipping  1 loose`.
- **Already loose**: a mob that has gone to a healer is not one you hold,
  so the server cannot list it. Wrekkit reads every mob's *own* target from
  its nameplate (SuperWoW lets a mob's GUID stand for the mob), and a mob
  that stays on a group member other than you for a second is **LOOSE**:
  `LOOSE` blinking on its plate, a *Loose* section in the window naming who
  it is on, an alert -- **"LOOSE: Whelp on Mendy"** -- and the flash. The
  one-second wait is so a mob throwing one fireball at a priest is not
  called loose. Name your co-tanks under *Co-tanks* and their mobs are left
  alone.

This needs nameplates switched on (the `V` key) and SuperWoW; without
SuperWoW the held-mob list and its alerts still work, loose detection does
not.

**Taunting it back.** When a mob you were tanking turns away, or one goes
loose, a small **Taunt** bar pops up with a button per mob (newest first, up
to three): your taunt's icon, the mob, who it is on, and the cooldown
counting down on the icon. **Click to taunt it**; right-click to dismiss.
With SuperWoW the taunt goes straight at that mob and your target stays
where it was (*Taunt without retargeting*); without it, the mob is targeted
first. If Taunt is on cooldown it uses Mocking Blow; Growl for druids. A
server with its own taunt: type its name under *Taunt spell*. A mob that
comes back to you, dies, or is ten seconds old leaves the bar by itself.

The same action is on a key -- *Key Bindings -> Wrekkit -> Taunt the mob
that got away* -- and on `/wrek taunt`, so a macro or an action-bar button
works too. Drag the bar by its title to move it, or place it alongside the
target-frame % with `/wrek threat move`; where you leave it is saved.

**Mob frames.** One small frame per mob in the fight, stacked: its name,
its health, and **who it is hitting** -- `you` in blue, anyone else by name
in their class colour. Five mobs on you and a patrol walks into the healer:
that row turns red and blinks, with the healer's name on it. Mobs held but
with someone closing in show the runner-up's % on the right and blink at
your flash limit. **Click** a frame to target that mob, **right-click** to
taunt it.

**Collapsed**, the mobs that are fine share one line and only trouble gets
a row. Tanking ten mobs, the stack is a single blue line -- `All 10 on you`
-- until one breaks off or someone closes in on one; then that mob, and only
that mob, appears under it, red and blinking:

```
Mobs  10 (collapsed)
8 on you  1 elsewhere
Onyxian Warder   [██████████]    Mendy      !
```

*Collapse* is **when many** by default (above *Collapse above*, 4 mobs),
or **always**, or **never**. Click the title or the summary line to flip it
for the rest of the fight. More trouble than rows fit shows as `+N` on the
summary line.

The mob you have **targeted** is marked with a gold outline and a gold edge
on the left, and keeps its row even when the stack is collapsed. The right
column is the **threat %** for every mob that has one: your own on your
target (the runner-up's when you are tanking), the runner-up's on every
other mob you hold, and your last reading on a mob you tabbed off -- dimmed,
because it is no longer live. A `!` means the mob is loose or on you.

Rows keep the order mobs joined the fight and never reshuffle, so a row is
where your eye left it; trouble is shown by colour. Mobs come from the
nameplates *and* from every enemy the combat log has seen this pull, so one
with no plate in view is still listed while the client knows it. Settings
(Frames & plates -> Mob frames): on/off, *when tanking* (default) or
*always*, from how many mobs (2), at most how many rows (8). Drag the title
to move the stack, or place it with `/wrek threat move`. Needs SuperWoW.

Not tanking, you get the opposite: warnings as *you* approach the line, and
**"AGGRO! <mob> is on you"** if one turns on you -- targeted or not, the
plates catch the rest -- with `AGGRO` on the target frame or on that mob's
plate.

Warnings fire once on the way *up* past a line and re-arm only after
dropping 5 points below it, so a number hovering on a line cannot repeat
the alert every half second. Large text mid-screen, a red pulse at the
screen edges and a sound -- each switchable.

#### Flash while close

The warnings say it once; this keeps going. While you are over the limit
the target-frame % blinks -- and, if you tick *Pulse screen edges*, red
edges pulse around the screen -- until you drop back under it, then it
stops on its own. Set where it starts in *Flash while close*:

- **Flash me at** (85% to pull by default): your own threat, when not
  tanking. A mob turning on you always flashes.
- **Tanking, flash at** (90% by default): whoever is closest to pulling the
  target *or any other mob you hold*.
- **Flash speed**, 1-6 blinks a second.

*Preview* trips it at the default limits, so you can see it out of combat.

#### Target frame and nameplates

**Target frame**: your threat % drawn straight on the frame the way
unit-frame addons draw their own text -- outlined type, coloured green ->
yellow -> orange -> red, with no box around anything. *Style* picks **number
+ bar** (default: a slim threat bar under the %), **number** alone, or
**badge** (on a soft dark plate, for busy frames); *Soft glow* adds a faint
glow in the same colour that breathes when red; *Size* scales it.

**Put it where you like**: tick *Move it (drag)* in settings, or
`/wrek threat move`. A sample % appears -- even with nothing targeted -- and
you drag it anywhere; right-click it (or untick) to lock. The spot is saved
as an offset from the target frame, so it stays put relative to the frame
across logins, and follows the frame if you move it. *Reset %* (or
`/wrek threat resetpos`) puts it back just above the frame. Locked, it never
takes the mouse, so it cannot block a click on the target frame.

It finds pfUI's target frame or the stock one on its own; for anything else
(Luna, XPerl, ...) type the frame's name into *Frame name*.

**Nameplates**: one setting, *Nameplate addon*, picks whose plates to draw
on -- **auto** (default) finds ShaguPlates' or pfUI's and uses theirs,
**ShaguPlates/pfUI** insists on them, **stock** uses Blizzard's. *Show as*
picks a coloured percentage beside the plate, a plain one, or a **tinted
health bar**: the plate's own bar coloured by threat, handed back to
ShaguPlates/pfUI (or restored to its stock colour) the moment the mob has
nothing to show. The target is live; a mob you tabbed off keeps its last
reading, dimmed, for a few seconds. With SuperWoW plates are matched by
GUID; without it only by name, so identically named mobs share a reading.

`/wrek threat test` (or *Preview* in settings) puts 15 seconds of test data on
every display -- as a tank if you are one -- so the badge, plates and
warnings can be placed out of combat. *Defaults* puts every threat setting
back, keeping where the window is.

### Settings

The cog on either title bar opens the options window, `/wrek config` too. It
has four tabs, each about one thing:

| tab | |
| --- | --- |
| Meter | compact mode, text size, row height, opacity, in-combat fade, toolbar, lock |
| Recording | what is recorded, per-second basis, log range, history, the crash journal, freeing memory |
| Sharing | sharing your logs, the channel, live raid sync |
| Threat | the threat meter, warnings, flashing, tanking |
| Frames & plates | the target-frame % and the nameplates |

Saved settings are checked at every login and anything out of range -- an
older build's value, a hand edit -- is put back inside what its control can
produce, so the window can never show a value that is not in effect.

Every control reads and writes the live setting rather than a copy, so it can
never disagree with the toolbar toggles or the slash commands, and everything
applies immediately -- a panel that needs a `/reload` teaches people not to
trust it.

**Compact mode** (`/wrek compact`) drops the toolbar and the footer and
tightens the rows, for a meter that can sit on screen permanently.

**Text size** scales the pixel dimensions along with the letters. Scaling type
without scaling what contains it just clips it, which is the usual way a text
size option ends up useless.

**Opacity** fades a window's background, title bar and border while its
text and bars stay solid, so it stays readable with the game showing
through. Each window has its own: *Meter opacity* and *Report opacity* on the
Meter tab, *Threat window opacity* on the Threat tab (a docked threat window
follows the meter, since the two are one block). The threat window's title
menu has 100/80/60/40% presets, and `/wrek opacity <meter|threat|report> <n>`
sets any of them.

**In combat** fades the meter while you fight (pointing at it brings it
back) or hides it until the fight is over. `/wrek` shows it anyway, and a
meter you closed yourself stays closed.

**Per-second basis** picks what DPS and HPS divide by: combat time, like
Skada, or active time, like Recount. Each action counts as 3.5 seconds of
acting, so a caster between casts is acting and someone standing idle is
not; a player and their pet share one active time rather than adding up.

**Raise the combat log range** is on by default. The client only reports
combat within its log range, and its 30-yard default leaves most of a raid
out. Wrekkit raises it to 200 yards (adjustable), and switching the option
off puts back what the client had.

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

**Live raid sync** (settings, off by default) fills in raiders your client
cannot see. Each player's Wrekkit reports only its own totals, every 30
seconds and once more when a pull ends. Everyone else uses those only where
they saw less, and marks the row `*`. It needs sharing on, and the other
players on 0.4.0 or later.

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

### Buff uptime

Pick **Buff Uptime** from the metric menu, click a player to see their
buffs, and click one — a flask, an elixir — to rank the whole raid by how
long it was up. Players without it are listed as missing. Click it again to
go back.

A buff that was up before the pull counts from the start of the pull, which
matters because that is when a flask gets drunk. Only your party or raid is
followed. *Track buff uptime* in settings turns it off.

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

Clicking a death shows what killed them: the last eight hits before it, with
the health left after each — lava and falling included.

**Picking players** works here too. Shift-click players to pick them, and
the ★ toggle narrows every table to just them; percentages become shares of
the picked players. The picks are shared with the meter and kept between
sessions, while each window has its own ★ switch. Pets follow their owner,
and enemies are never hidden.

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

/wrek threat             show or hide the threat window
/wrek threat <where>     window | docked | meter | off
/wrek threat tank        cycle I'm-the-tank: auto, always, never
/wrek threat test        15s of test data on every threat display
/wrek threat move        place the target-frame %, taunt bar and mob frames
/wrek taunt              taunt the mob that got away (macro / key)
/wrek threat resetpos    put the target-frame % back above the frame
/wrek threat config      threat settings
/wrek mode threat        the meter shows live threat

/wrek config             open the settings window
/wrek opacity <w> <n>    meter, threat or report opacity, 20-100
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
logout or `/reload`*, so after a crash they still hold the last clean save and
nothing since — the whole night is gone from them, no matter how carefully it
was aggregated in memory. Wrekkit therefore appends each encounter to
`CustomData\Wrekkit_<character>.txt` the moment it ends, through Nampower's
file API, and every clean logout notes how far the journal had got. The next
login restores the pulls that started after that point and never reached the
saved history, and says how many. Older pulls the history dropped to stay
within its cap stay dropped. When nothing was lost it says nothing, and does
not even parse the journal.

Recovery reconstructs the session too, deriving it from the restored
encounters rather than the saved pointer the crash destroyed — so the night
continues into the same session rather than starting a third one. Loading is
idempotent: encounters are matched by session and id, and the in-memory copy
wins, so running `/wrek load` twice changes nothing.

**A crash in the middle of a write is survived too.** Each encounter in the
journal ends with an end marker, so one cut off by a crash is dropped rather
than imported with half its players missing, and the next write starts on a
fresh line so the torn tail can never run into it. A full rewrite (pruning,
locking, compaction) goes to `Wrekkit_<character>_backup.txt` first and the
journal second: whichever write a crash interrupts, one of the two is whole,
and the next login merges the backup back in and repairs the journal.

The journal is the crash net under the history, not a second archive, so once
it passes a megabyte it is rewritten down to what the history holds. Login
never has to parse a whole season of pulls.

`/wrek save` still exists for a full compacted rewrite of the file.

## Memory

A raid fight raises hundreds of combat events a second. Wrekkit is written
not to turn them into garbage -- the per-event detail tables are reused, the
threat meter parses the server's replies without splitting them into tables
and pools its rows, nameplates are found without rebuilding a list every
frame, and the meter reuses the numbers for finished pulls instead of
re-adding them twice a second.

What a fight does use is handed back afterwards: a few seconds after you
leave combat, if memory has grown by 2 MB since the last time, Wrekkit runs
one garbage collection -- never during a pull, where it would be a hitch.
*Free memory after fights* (Recording tab) turns it off. `/wrek status`
shows the Lua memory in use (every addon together; 1.12 cannot report one
addon's share) and what the last tidy freed.

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

- **Range.** The client only receives events within its combat log range.
  Its default is 30 yards; Wrekkit raises it to 200, which covers a raid
  instance. Past that, live raid sync fills in players who also run Wrekkit,
  and sharing covers the rest.
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

**Distance in yards on the mob frames, coloured by bands you set, plus two fixes: players who leave the group stay in your reports, and friendly fire no longer counts as damage done.**

## New
- **Show distance** (Settings → **Mob frames**, off until turned on): each mob's distance on its row, coloured by your own bands.
  - Up to six bands, each with a yard limit, a colour (the game's colour picker) and an on/off, plus a colour for beyond them all. A hunter's dead zone, a mage's 30, or a warlock's golden 21 yards are all possible.
  - **Start from my class** fills them in to edit from: a hunter's dead zone and Auto Shot range, a caster's 30/36/40, melee's 5/10/30.
  - Kept **per character**.
  - Optional: **Show the yards** (off means colour only) and **Colour the row** (tints the health bar too).
  - Exact with UnitXP_SP3, which takes a mob's GUID, so every row works, not just your target. Otherwise SuperWoW's centre-to-centre estimate, marked "~".
- The mob frame settings have **a tab of their own** now.

## Fixed
- **Players who left the group vanished from "group only".** Two healers who left after Molten Core disappeared from every pull they had healed. Each pull now keeps who was in your group while they took part, and the filter shows anyone in your group during those pulls or in it now. Pulls recorded before this update still use the group as it is now.
- **Friendly fire counted as damage done.** Examples: Living Bomb going off on you, Molten Core's fires spreading between players, your own Bloodrage. That was 35k of one warrior's 513k in a Molten Core run, and most of why Wrekkit read above other meters. It's now only damage taken. Checked against the same night's Chronicle log, damage agrees within about 1% for most players.

## Install

Download `Wrekkit-0.9.31.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. Coming from 0.9.18 or earlier, **fully restart the client**; from 0.9.19 or later a `/reload` is enough. `/wrek status` should then report **v0.9.31**.

## Requirements

- **Nampower** is required for the damage meter, the report, the per-raid files, the cast bars and raid value. The threat meter itself works without it.
- **SuperWoW** is recommended.
- **UnitXP_SP3** makes the mob frame distances exact (optional).
- **aux** for consumable prices (optional).

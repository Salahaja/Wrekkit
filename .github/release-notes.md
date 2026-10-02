**Default taunts for every tank class.**

## New
- **Class taunts out of the box.** The Taunt bar, the mob frames' right-click, the keybinding and `/wrek taunt` now know each tank class's taunts. Each one is tried in order until one is off cooldown:
  - **Warrior:** Taunt, then Mocking Blow
  - **Druid:** Growl
  - **Paladin:** Hand of Reckoning, then Righteous Defense
  - **Shaman:** Earthshaker Slam
- **Your own list.** Settings → Threat → *Taunt spells* takes a comma-separated list, best first, which replaces the class defaults.
- **Use AoE taunts too** (off by default) adds Challenging Shout or Challenging Roar as a last resort.
- `/wrek threat role` now also lists the taunts in force and which of them are in your spellbook.

## Fixed
- Taunts were matched against a single shared list, so paladins and shamans had no taunt at all, and icon matching was case-sensitive.

Everything in 0.8.0 is included. See the [0.8.0 notes](https://github.com/Salahaja/Wrekkit/releases/tag/v0.8.0).

## Install

Download `Wrekkit-0.8.1.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`.

Do **not** use the "Source code" links. They extract to a folder the client will not load.

**Fully restart the client** after installing. `/wrek status` should then report **v0.8.1**.

## Requirements

- **Nampower** is required.
- **SuperWoW** is strongly recommended.

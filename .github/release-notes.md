**Talent specs: see who is Holy, Prot or Ret, right on the meters.**

## New
- **Specs.** Wrekkit works out each group member's talent spec and can show it on the damage, healing and threat meters and in the report:
  - **Inspected:** Wrekkit asks each group member's client for their talents, one player at a time and never in combat, then again every 15 minutes. Answers ChronicleCompanion gets are used too.
  - **Guessed:** some players' clients never answer an inspect (about half, going by raid logs). Their spec is guessed when they use an ability only a deep talent gives, like Mortal Strike, Holy Shock or Shield Slam. A guessed spec is marked with a **?**.
  - Your own spec comes straight from your talents.
- **Icons** setting (replaces the old "Class icons" check): **off**, **class**, **spec** (the spec's icon where known, otherwise the class), or **class + spec** side by side. Your old class-icon setting carries over.
- **Spec after name** setting: adds a short grey spec after each player's name, like `Salahaja (Ret)`.
- The meter tooltip shows a player's spec with its points, e.g. *Retribution (5/11/35)*.
- **`/wrek specs`** lists every known spec and how it was found, plus who was asked lately and who answered.
- **`/wrek inspect <name>`** asks one player now. With no name (or `%t`) it asks your target.

## Install

Download `Wrekkit-0.9.15.zip` and extract it into `<your client>\Interface\AddOns\`. You should end up with `Interface\AddOns\Wrekkit\Wrekkit.toc`. Do **not** use the "Source code" links. **Fully restart the client** after installing. `/wrek status` should then report **v0.9.15**.

## Requirements

- **Nampower** is required for the damage meter, the report and the per-raid files. The threat meter itself works without it.
- **SuperWoW** is recommended.

# AffixFinder

AffixFinder is a World of Warcraft 3.3.5a addon for the **Synastria** private server. It helps you find where to farm random item affixes for attunement.

It ranks:

- zones with the most affixes left
- mobs with the best useful-affix drops per 1000 kills
- mobs to farm for **new attunables** - items you have not attuned at all yet, regardless of affixes
- specific resistance farms, such as fire or frost resistance
- account-wide class opportunities

AffixFinder only counts items that drop from killable mobs. Vendor, quest, crafting, container-only items, and melee weapons are not included. On Synastria, melee-weapon affixes do not affect attuned stats; ranged weapons, wands, and shields still count normally. (The **New items** mode is the one exception: melee weapons count there, because attuning the weapon itself still grants its fixed weapon stats.)

> Requires Synastria/WoWExt. The addon will load on other clients, but it only produces useful results on Synastria.

## Installation

Download the release zip, then copy the `AffixFinder` folder into:

```text
Interface/AddOns/
```

You should end up with:

```text
Interface/AddOns/AffixFinder/AffixFinder.toc
```

Enable **AffixFinder** at the character-select screen.

## Quick Start

- `/af ui` opens the window.
- `/af` shows affix counts for your current zone.
- `/af zones` ranks zones for your current character.
- `/af zones acc` ranks zones for your account.
- `/af zones ev 5` ranks zones by their best farmable mobs.
- `/af instances` ranks full dungeon/raid clears.
- `/af resist fire` ranks fire-resistance farms.
- `/af attune` ranks farms for items you haven't attuned at all yet.
- `/af attune instances` ranks full clears by new item attunes.
- `/af config` opens settings.
- `/af help` lists commands.

The first scan can take a little while. Later scans are much faster because AffixFinder caches lightweight scan data across sessions.

## Window

The **Find** control at the top picks what every tab counts:

- **Affixes** (default) - remaining random affixes, the classic AffixFinder model.
- **New items** - items you have not attuned *at all* yet: non-affixed items never attuned, plus affixed items with zero affixes attuned. Every unattuned item is worth exactly one new attune - affix multiplicity is deliberately ignored. Forge is greyed out in this mode (a forged attune also attunes base, so it cannot change what counts); Bind and Class still apply.

The tabs are views over whichever model is selected:

- **Zones** - zone rankings by remaining affix value
- **Mobs** - individual mob rankings, with zone and spawn filters
- **Items** - the actual affixed items still worth farming, with the specific suffixes you still need and the best mob to farm each from
- **Instances** - full dungeon/raid clears ranked by expected affixes per clear and per 1000 kills, for when you would rather just run a dungeon than camp one mob
- **Current Zone** - what is still useful where you are standing
- **Classes** - account-scope class breakdowns
- **Resist** - targeted farming for one resistance school (always affix-shaped; the Find mode does not apply there)
- **Progress** - account attunement completion and farmable value left by expansion

Clicking a mob (or an item's best-mob) row marks that mob on the map. Questie is optional; without it, AffixFinder still uses Synastria's own tracking when available.

### Tooltips

AffixFinder also adds a line to item tooltips everywhere in the game (bags, bank, auction house, loot, quest rewards, chat links, LootDB): how many affixes are still left to attune on the item and, when any remain, the best killable source and the suffixes you still need. Attunable items without an affix line of their own (non-affixed items, melee weapons) get the whole-item view instead: *not attuned yet* plus the best source, or a grey *attuned*. No window required.

## Settings

`/af config` opens the settings panel.

Useful settings include:

- include or exclude mythic items
- configure T3 map-warp assist from mob/resist rows
- choose the auto-rescan interval
- set the default minimum mob spawn count

AffixFinder does not save the full item graph or ranking results. It only persists small settings, window position, minimap-button position, and lightweight item-id caches (the affixed-item and attunable-item lists).

## Notes

- Scope can be **Character** or **Account**.
- Forge filters are one-way thresholds: **None** is base only, **TF+** includes Titanforged/Warforged/Lightforged, **WF+** includes Warforged/Lightforged, and **LF** includes Lightforged only.
- Forged attunement is cumulative downward: TF also attunes the base affix, WF also attunes TF and base, and LF also attunes WF, TF, and base. Attuning at any forge level at or above the filter's threshold satisfies it: AffixFinder unions what is *possible* across the included tiers (a suffix available at several forge levels is counted once), and counts a suffix as *remaining* only while it is unattuned at every included tier.
- Expected-value numbers (per-kill, per-1000-kills, per-clear) account for **forge rarity**: with a forged filter active, only the drops that actually roll at or above the threshold count (base rates: 5% Titanforged, 0.7% Warforged, 0.1% Lightforged). Prestiged characters' **Forge Power** is read from the server and applied as a multiplier (100% FP doubles the rates). `/af forgedbg` shows the exact rates in use. Affix *counts* (affixes left, items) are unaffected — rarity changes how long farming takes, not what exists.
- Bind filters can include BoP, BoE, or both.
- Melee weapons are ignored because their random affixes do not contribute attuned stats on Synastria. Ranged weapons, wands, and shields are still counted. The New items mode is the exception: it counts melee weapons, because it tracks whole-item attunes rather than affixes.
- The New items mode's candidate list (everything someone on the account can attune) is cached across sessions like the affixed-item list, stamped with the character level it was discovered at. Attunability only grows with level, so the cache is reused at or below that level and rediscovered automatically once a character levels past it - including mid-session, the moment you level up (at the cap it is effectively permanent). When both the affix list and this list need discovering, AffixFinder fills them in a single pass. If something else unlocks new attunables (say, creating a new class), use **Rescan** / `/af clearcache`.
- The Instances tab models a **full clear**: each mob's expected drops times its spawn count, summed over the instance. "Kills per clear" counts every mob that drops *any* affixed item (needed or not), so the per-1000-kills density divides by something close to a real clear; mobs that drop no affixed items at all are not counted. Difficulty and raid-size variants (Heroic, 10/25) fold into one row under the generic instance name, because the server splits their source data incompletely across the variant names; Mythic dungeons keep their own row (their drop pool is separate). Mobs with no recorded spawns (summons, scripted spawns) are not counted, and only mobs **inside** the instance count — the open-world area around an entrance that shares the instance's name (like the Deadmines cove in Westfall) is excluded. The Dungeon and Raid source filters work normally; World never applies. Sort raids by **Affixes/clear** — lockouts make density the wrong measure for them.
- Resistance values are estimates based on item level, because the exact rolled suffix value is not available during scans.
- Diagnostic commands such as `/af debug`, `/af zonedbg`, `/af warp`, and `/af forgedbg` are available if you want to inspect what the addon is reading.

## Acknowledgements

AffixFinder borrows useful ideas, assets, data-access patterns, and map/UI integration details from other Synastria addons. Special thanks to **Netrinil** for the Questie 3.3.5 work that AffixFinder can optionally use for precise map pins, and to **Qt** for qtRunner, whose tracking, warp, attunement, and source-row logic helped shape several of AffixFinder's farming workflows.

## License

Released under the [MIT License](LICENSE).

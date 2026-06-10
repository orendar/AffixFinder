# AffixFinder

AffixFinder is a World of Warcraft 3.3.5a addon for the **Synastria** private server. It helps you find where to farm random item affixes for attunement.

It ranks:

- zones with the most affixes left
- mobs with the best useful-affix drops per 1000 kills
- specific resistance farms, such as fire or frost resistance
- account-wide class opportunities

AffixFinder only counts items that drop from killable mobs. Vendor, quest, crafting, container-only items, and melee weapons are not included. On Synastria, melee-weapon affixes do not affect attuned stats; ranged weapons, wands, and shields still count normally.

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
- `/af config` opens settings.
- `/af help` lists commands.

The first scan can take a little while. Later scans are much faster because AffixFinder caches lightweight scan data across sessions.

## Window

The window includes:

- **Zones** - zone rankings by remaining affix value
- **Mobs** - individual mob rankings, with zone and spawn filters
- **Items** - the actual affixed items still worth farming, with the specific suffixes you still need and the best mob to farm each from
- **Instances** - full dungeon/raid clears ranked by expected affixes per clear and per 1000 kills, for when you would rather just run a dungeon than camp one mob
- **Current Zone** - what is still useful where you are standing
- **Classes** - account-scope class breakdowns
- **Resist** - targeted farming for one resistance school
- **Progress** - account attunement completion and farmable affixes left by expansion

Clicking a mob (or an item's best-mob) row marks that mob on the map. Questie is optional; without it, AffixFinder still uses Synastria's own tracking when available.

### Tooltips

AffixFinder also adds a line to item tooltips everywhere in the game (bags, bank, auction house, loot, quest rewards, chat links, LootDB): how many affixes are still left to attune on the item and, when any remain, the best killable source and the suffixes you still need. No window required.

## Settings

`/af config` opens the settings panel.

Useful settings include:

- include or exclude mythic items
- configure T3 map-warp assist from mob/resist rows
- choose the auto-rescan interval
- set the default minimum mob spawn count

AffixFinder does not save the full item graph or ranking results. It only persists small settings, window position, minimap-button position, and a lightweight affixed-item cache.

## Notes

- Scope can be **Character** or **Account**.
- Forge filters are one-way thresholds: **None** is base only, **TF+** includes Titanforged/Warforged/Lightforged, **WF+** includes Warforged/Lightforged, and **LF** includes Lightforged only.
- Forged attunement is cumulative downward: TF also attunes the base affix, WF also attunes TF and base, and LF also attunes WF, TF, and base. AffixFinder unions the included tiers, so a suffix available at several forge levels is counted once rather than multiplied.
- Bind filters can include BoP, BoE, or both.
- Melee weapons are ignored because their random affixes do not contribute attuned stats on Synastria. Ranged weapons, wands, and shields are still counted.
- The Instances tab models a **full clear**: each mob's expected drops times its spawn count, summed over the instance. "Kills per clear" counts every mob that drops any affixed item, so the per-1000-kills density divides by something close to a real clear. Difficulty and raid-size variants (Heroic, 10/25) fold into one row under the generic instance name; Mythic dungeons keep their own row (their drop pool is separate). Only mobs inside the instance count — open-world areas around an entrance that share the instance's name are excluded. Sort raids by **Affixes/clear** rather than density; lockouts make density the wrong measure for them.
- Resistance values are estimates based on item level, because the exact rolled suffix value is not available during scans.
- Diagnostic commands such as `/af debug`, `/af zonedbg`, and `/af warp` are available if you want to inspect what the addon is reading.

## Acknowledgements

AffixFinder borrows useful ideas, assets, data-access patterns, and map/UI integration details from other Synastria addons. Special thanks to **Netrinil** for the Questie 3.3.5 work that AffixFinder can optionally use for precise map pins, and to **Qt** for qtRunner, whose tracking, warp, attunement, and source-row logic helped shape several of AffixFinder's farming workflows.

## License

Released under the [MIT License](LICENSE).

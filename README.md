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
- `/af resist fire` ranks fire-resistance farms.
- `/af config` opens settings.
- `/af help` lists commands.

The first scan can take a little while. Later scans are much faster because AffixFinder caches lightweight scan data across sessions.

## Window

The window includes:

- **Zones** - zone rankings by remaining affix value
- **Mobs** - individual mob rankings, with zone and spawn filters
- **Current Zone** - what is still useful where you are standing
- **Classes** - account-scope class breakdowns
- **Resist** - targeted farming for one resistance school

Clicking a mob row marks that mob on the map. Questie is optional; without it, AffixFinder still uses Synastria's own tracking when available.

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
- Forge filters are thresholds: `tf` includes TF/WF/LF, `wf` includes WF/LF, and `lf` means LF only.
- Bind filters can include BoP, BoE, or both.
- Melee weapons are ignored because their random affixes do not contribute attuned stats on Synastria. Ranged weapons, wands, and shields are still counted.
- Resistance values are estimates based on item level, because the exact rolled suffix value is not available during scans.
- Diagnostic commands such as `/af debug`, `/af zonedbg`, and `/af warp` are available if you want to inspect what the addon is reading.

## Acknowledgements

AffixFinder borrows useful ideas, assets, data-access patterns, and map/UI integration details from other Synastria addons. Special thanks to **Netrinil** for the Questie 3.3.5 work that AffixFinder can optionally use for precise map pins, and to **Qt** for qtRunner, whose tracking, warp, attunement, and source-row logic helped shape several of AffixFinder's farming workflows.

## License

Released under the [MIT License](LICENSE).

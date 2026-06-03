# AffixFinder

AffixFinder is a World of Warcraft 3.3.5a addon for the **Synastria** private server. It tells you **where to farm item affixes for attunement**: how many affixes are left to attune (per character or per account) in your current zone, which zones have the most remaining affix value, and which individual mobs give the best expected useful-affix drops per 1000 kills.

All counts cover affixes obtainable from **killable mobs**. Items sourced only from vendors, quests, crafting, or world-object containers are not counted (they are not farmable by killing).

> **Requires Synastria/WoWExt.** AffixFinder relies on the server's custom item and attunement APIs (the same ones AtlasLoot, AttuneHelper, ScootsCraft, etc. use). Every custom call is guarded, so the addon won't error on a vanilla client, but it only produces results on Synastria.

## About attunement

Synastria has a deep long-term progression system built around item **attunement**. Any equippable item with stats can be attuned by equipping it and gaining experience while wearing it; once attuned, the character permanently gains a share of that item's stats. Most items have no random affix, so attuning them is a one-time task. Some items also carry **affixes** ("of the Monkey", "of Fire Resistance", and so on): attuning one affix is enough for the base item to count as attuned, but attuning additional affixes can further strengthen the character and feed other long-term systems.

AffixFinder helps you discover and prioritise the affixed items that are still worth attuning, and points you at the zones and mobs where you can farm them most efficiently.

## Installation

Copy the `AffixFinder` folder into your client's `Interface/AddOns/` directory (so you have `Interface/AddOns/AffixFinder/AffixFinder.toc`), then enable **AffixFinder** at the character-select screen.

AffixFinder stores **no scanned data** between sessions. The only persisted state is a handful of settings plus your window position and minimap-button angle (a few bytes). See [Performance and memory](#performance-and-memory).

## Quick start

- `/af ui` — open the browser window (or click the **spyglass minimap button**).
- `/af` — current-character affix counts for the zone you're standing in.
- `/af zones` — rank zones by remaining affix value for the current character.
- `/af zones ev 5` — rank zones by expected useful affix drops per 1000 kills of their best farmable mob (counting only mobs with a reported spawn count ≥ 5).
- `/af resist fire` — rank zones by the estimated **fire resistance** gained per 1000 kills (a different mode: farm one specific resist; see [Farming a specific resistance](#farming-a-specific-resistance)).
- `/af help` — print command usage.

The first zone command of a given scope/forge scans for a few seconds (chunked, so the client stays responsive), then results are cached and instant until you attune something or clear the cache.

## Window

`/af ui` opens a single browser window over the same data the slash commands report (also opened by the **minimap button** — a spyglass icon that defaults to the north-north-west of the minimap ring, clear of the calendar/clock, and is draggable to reposition; its position is remembered between sessions).

**Shared filter bar (top).** The filter bar mixes two kinds of control:

*Item-level (single-select; part of the scan/cache key — changing one runs a one-time scan per combination, then is instant on return):*

- **Scope** — `Character` / `Account`.
- **Forge** — `Base` / `TF+` / `WF+` / `LF`.

*Item-level (multi-select; also part of the cache key):*

- **Bind** — `BoP` / `BoE`, both on by default. (BoP is detected via the item's BoP tag bit; anything not BoP is treated as BoE. The two-on state is equivalent to "both".)

*Zone-level (multi-select; applied to the row list at display time, so toggling them never rescans):*

- **Source** — `Dungeon` / `Raid` / `World`, all on by default.
- **Expansion** — `Classic` / `TBC` / `WotLK`, all on by default.

*Class (single-select; **Account scope only**; display-time, so it never rescans):*

- **Class** — a dropdown of `All classes` (the default) plus the ten classes. Picking one re-slices the Zones, Mobs and Current Zone panels to just the affixes *that class* can attune; `All classes` shows the account totals. It only appears in Account scope (per-class is meaningless for a single character), and switching back to Character scope resets it to `All classes`. Because the account scan already computes every class's sub-totals, changing the class is instant and never triggers a scan. See [Per-class breakdown](#per-class-breakdown).

The Source and Expansion filters classify a zone by a normalized key — lowercased, punctuation turned to spaces, and difficulty/size qualifiers stripped from both ends, so `Utgarde Keep`, `Utgarde Keep Heroic`, `Naxxramas 25` and the server's compact codes (`Icecrown Citadel 25N`, plus the server-specific Mythic) all collapse to their base instance. Names come, in order of authority, from: the client's LFG dungeon database (exact localized 5-man dungeon names with type and expansion), static raid/dungeon name lists (the LFG DB doesn't list raids in 3.3.5), and the continent map (plus battlegrounds and continent names) for open-world zones. Hub-prefixed names like `Auchindoun: Auchenai Crypts` are matched by the instance name as a suffix (longest match wins). A zone it still can't place counts as `unknown` and is always shown, so these filters never silently hide data they can't place. Run `/af zonedbg` to see exactly how the current data classifies and which zones land as `unknown`.

**Panels (tabs).** Each tab is a different view of the *same* filtered slice, so switching tabs never rescans:

- **Zones** — zones ranked by total affixes left (the `/af zones` view). Hover a row for its per-category breakdown; click a row to drill the Mobs panel down to that zone.
- **Mobs** — *individual* mobs ranked by expected useful-affix drops per 1000 kills, one row per NPC (`Mob`, `Zone`, `Drops/1k`, `Spawns`, `Items`), with a **Zone** filter box (type a substring or click a Zones row) and a **Min spawns** control (default from [Settings](#settings), `5` out of the box, to hide the long tail of rare/sparse spawns; set it to `0` to include everything). Every column is a per-mob value — nothing is summed across mobs — so `Items` is how many affixed items (still having affixes left) that mob drops. Changing these only re-filters; it never rescans. Clicking a mob row places an AffixFinder pin on the world map at one of its spawn locations.
- **Current Zone** — the player's current zone broken down per item category (the `/af` view as a table).
- **Classes** — *(Account scope only)* the ten classes ranked by how many affixes the account can still attune on each (`Class`, `Affixes left`, `Items w/ left`, `Unattuned`), class-coloured. It respects the Source/Expansion filters, so with everything on it answers "which class should I main for affixes?" and with the filters narrowed it answers "best class for this content". See [Per-class breakdown](#per-class-breakdown).
- **Resist** — a different mode for farming **one chosen resistance**. A `Resist` selector (`Fire`/`Nature`/`Frost`/`Shadow`/`Arcane`) and a `Min spawns` box sit in the control strip; columns are `Zone`, `Resist/1k`, `Best mob`, `Spawns`, `Items`. Rows rank zones by the estimated resist *gained* per 1000 kills of the best farmable mob. The shared **Scope** filter and the display-time **Source/Expansion** filters apply; **Forge/Bind** do not (resist attunement is a flat fraction per forge, so it can't change the ranking). See [Farming a specific resistance](#farming-a-specific-resistance).

**List.** The list is virtualized, so hundreds of zones or thousands of mobs stay fast. Click any column header to sort by it; click again to reverse. The footer shows scan state and a **Rescan** button (equivalent to `/af clearcache` followed by a fresh scan). The window closes with its close button or `Escape`.

## Commands

- `/af ui` (or `/af window`): open/close the window.
- `/af config` (or `/af options`/`/af settings`): open the options panel under Interface → AddOns (see [Settings](#settings)).
- `/af`: current-character counts for the current zone.
- `/af account` or `/af acc`: account-scope counts.
- `/af acc tf`: account-scope counts for Titanforged and above.
- `/af acc wf`: account-scope counts for Warforged and above.
- `/af acc lf`: account-scope counts for Lightforged.
- `/af acc tf breakdown`: also prints per-item-category breakdowns for all three reported categories.
- `/af zones`: ranks zones by total affixes left to attune for the current character.
- `/af zones acc`: ranks zones by account-scope remaining affix value.
- `/af zones acc wf 15`: prints the top 15 zones for Warforged and above, account scope.
- `/af zones ev 5`: ranks zones by expected useful affix drops per 1000 kills of the best farmable mob, counting only mobs whose reported spawn count is at least 5.
- `/af zones acc ev 10`: account-scope expected-value ranking counting only mobs with a spawn count of at least 10.
- `/af zones ev [best|avg|total] N [limit]`: choose how each zone is scored across its qualifying mobs — `best` (default, the single best mob you would farm), `avg` (mean across mobs), or `total` (sum across mobs). `N` is the minimum mob spawn count; an optional trailing number limits how many zones print. Use `/af zones ev 0` to include mobs whose spawn count is unknown.
- `/af resist <fire|nature|frost|shadow|arcane> [character|account] [best|avg|total] [N] [limit]`: ranks zones by the estimated resist gained per 1000 kills for one chosen resistance (see [Farming a specific resistance](#farming-a-specific-resistance)). `N` is the minimum mob spawn count; the trailing number limits how many zones print. E.g. `/af resist fire`, `/af resist frost acc 5`, `/af resist arcane total 1 15`.
- `/af clearcache`: resets the in-memory caches (the affixed-item list and all aggregated results); the next zone command rediscovers and rescans. Use after a server data reload.
- `/af mem`: prints a memory diagnostic.
- `/af help`: prints command usage.

There are also a few developer diagnostics (`/af debug`, `/af zonedbg`, `/af affixdbg`, `/af affixid`, `/af resistval`) that dump the raw source rows or the affix/resist data behind a given item; they are not needed for normal use.

Forge flags are treated as thresholds: `tf` means TF/WF/LF, `wf` means WF/LF, and `lf` means LF only.

Bind flags filter by how the item binds: `bop` counts only Bind-on-Pickup items, `boe` counts everything that is not BoP (Bind-on-Equip and unbound), and `both` (the default) counts all. For example `/af zones acc boe` ranks zones by account-scope affixes available on BoE items only.

### How counts are derived

AffixFinder treats the server's item-location source rows as the source of truth. It groups affix value by the `zoneName` reported by the server's own loot data and ignores non-actionable placeholder zones such as `?`. The current-zone view (`/af`) matches the current zone's name against that same zone data, so `/af`, `/af zones`, and `/af zones ev` all count the same thing.

A "mob" is an NPC; its source rows are merged keeping the highest drop chance and spawn count. A row counts as a killable mob only when the source is a creature and not a vendor/quest/crafting source.

`/af zones ev N` treats `N` as the minimum spawn count a mob must have to qualify, which matches the farming question "is there a dense group of this mob to kill?" Sparse or unknown-spawn mobs (spawn count `0`) are excluded unless you pass `/af zones ev 0`.

For each qualifying mob, its expected useful-affix yield per kill is the sum, over every affixed item it drops that still has affixes left, of `dropChance * (affixes left / possible affixes)`. Multiplied by 1000 this is the mob's useful affix drops per 1000 kills. Each zone is scored by `best` (default), `avg`, or `total` across its qualifying mobs.

In the window's **Mobs** view, clicking a mob row resolves one spawn location for that NPC and places an AffixFinder pin on the map. Only the latest clicked mob keeps an AffixFinder pin, so the map stays focused on the target you are actively farming. Coordinates come from the server when available, with Questie spawn data as a fallback.

## Farming a specific resistance

The default views optimise for affix **quantity** (how many affixes are left to attune anywhere). The **Resist** mode (`/af resist <element>` or the Resist tab) optimises for one specific thing of **value** instead: a single resistance school, where the actual amount matters. On Synastria a resist is permanently attuned, so this answers "where do I farm to gain the most *fire* resistance per kill?".

An item qualifies for a chosen resist when its affix data says it can roll that resist family **and** that resist is not already attuned. Each qualifying source is then weighted by the resist it would actually grant:

```
per-kill value  =  drop chance  ×  (1 / number of affixes the item can roll)  ×  resist gained
```

- `1 / affixes-it-can-roll` is the chance a drop rolls *this* resist rather than one of the item's other affixes.
- `resist gained` is **20% of the item's base resist** — the amount one base-forge attune grants (Synastria grants 20% per forge level, identical across items, so this is a flat factor and forge level never changes the ranking).

Summed over a mob's drops and ×1000, this is the mob's estimated **resist points per 1000 kills**; each zone is scored by its best such mob (`best`, the default — what you actually farm — with `avg`/`total` also available). The `Items` count is how many items the best mob drops that still roll this resist unattuned, and it can run *opposite* to the resist ranking (many small-resist items vs few large-resist ones), which is why it is shown alongside.

### Why the resist amount is *estimated*

The exact resist an item grants lives in its rolled suffix tier, which is not readable from an item id ahead of time, so the amount is **estimated from item level** (calibrated against real in-game values). Item level is a good proxy because it also captures a real quirk of the data: low-level items roll pure "of X Resistance" (Classic), while higher-level items roll "of X Protection" hybrids (TBC/WotLK) that grant *less* resist — and item level is what decides which an item uses. Two consequences: the estimate carries some spread (item slot also affects the amount), so the curve is shown with a `~` and labelled an estimate; but the ranking is robust regardless, because resist is monotonic in item level.

## Settings

`/af config` (or Interface → AddOns → **AffixFinder**) opens the options panel. The settings persist across sessions (only these few scalars — never the scanned data):

- **Include mythic items in calculations** (default **off**). Mythic items are very hard to farm, so by default the rankings ignore them. This is an item-level filter, so it is part of the scan/cache key: toggling it runs a one-time scan for the new combination, then is instant on return.
- **T3 map-warp assist from the Mobs view** (default **off**). Mob rows always pin the latest clicked target. When this is enabled, clicking a mob also checks whether you have the zone's t3 warp attunement and opens that zone's world map so you can click the marked spot to warp there.
- **Auto-rescan interval** (default **60 min**, range `0`–`180`). When the addon detects a change (e.g. you attune something), it will not automatically rescan a given filter more than once per this interval — between rescans it keeps serving the slightly-stale cached slice. `0` means rescan on every detected change. The **Rescan** button and changing filters always rescan immediately, regardless of this setting.
- **Default minimum mob spawns** (default **5**, range `0`–`50`). The starting value for the Mobs panel's **Min spawns** control. Typing a value into the in-window control overrides this for the session; changing the default here updates the window unless you have already overridden it.

In addition, AffixFinder remembers your **window position** and **minimap-button angle** (two tiny scalars). These have none of the cost the scanned data would (see below), so they persist for convenience while the scanned data still never touches disk.

## Per-class breakdown

In Account scope, every affix the account can attune is also attributed to the specific classes that can use the item, so the window answers two questions: *which class should I farm on for a given zone* (the Class dropdown), and *which zone should I farm for a given class* (pick a class, then read the Zones/Mobs panels). The **Classes** panel ranks the classes head-to-head.

Because there is no per-class server API, the attribution is derived from WotLK 3.3.5 proficiencies. Because the account scan already knows each item's affixes-left and that attribution, the per-class sub-totals are computed during that one scan and the Class dropdown is a pure display-time re-slice (no extra scans).

The model:

- **Armor** uses the "intended/spec" material, made **level-aware** by the level-40 armor upgrade. Warriors/Paladins wear mail until 40 then plate; Hunters/Shamans wear leather until 40 then mail. So a **mail** item with required level `< 40` is a Warrior/Paladin leveling piece, while mail `≥ 40` is Hunter/Shaman; **leather** `< 40` also serves Hunter/Shaman on top of the always-on Rogue/Druid; **plate** is always Warrior/Paladin/Death Knight; **cloth** is the three pure casters.
- **Weapons** use real per-class proficiency; **shields** → Warrior/Paladin/Shaman; **held-in-off-hand** (orbs etc.) → every class; **relics** map to their one class (Idol→Druid, Libram→Paladin, Totem→Shaman, Sigil→Death Knight); **rings/necks/trinkets/cloaks** count for every class.

A class's per-zone/-mob numbers are a strict subset of the account totals, but the classes **overlap** (a ring counts for all ten, a mail item for two), so the per-class numbers are deliberately *not* a partition of the account total.

## Performance and memory

AffixFinder is built around two hard constraints — **correctness/completeness** and a small memory footprint — with compute time treated as the flexible resource:

- **No scan data is persisted.** The only thing saved between sessions is a few config scalars plus your window/minimap layout. The full item→mob graph and the aggregated results live only in memory and are rebuilt each session, so logging out is instant and the addon never grows a giant saved file.
- **Only aggregates are kept in memory — never the full graph.** A scan reads each item's mob sources transiently and folds them straight into small per-zone and per-mob structures, then discards the sources. Nothing is capped, so the results are complete and exact.
- **Two in-memory session caches:** the list of affixed item ids (found once by scanning the whole id space; static for the session), and the aggregated per-zone / per-mob results, keyed by scope+forge+bind. All `/af`, `/af zones`, and `/af zones ev` variations format from those aggregates, so changing the EV threshold/mode/limit never rescans. Only switching scope/forge/bind — or attuning, which clears the aggregates — triggers a new scan.

So the first zone command of a scope/forge pays a one-time scan (seconds, chunked); everything after is instant until you attune or `/af clearcache`. Scans are chunked with a per-frame time budget so the client stays responsive, and only one scan runs at a time.

## License

Released under the [MIT License](LICENSE).

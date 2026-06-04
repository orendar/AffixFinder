# AffixFinder

AffixFinder is a World of Warcraft 3.3.5a addon for the **Synastria** private server. It tells you **where to farm item affixes for attunement**: how many affixes are left to attune (per character or per account) in your current zone, which zones have the most remaining affix value, and which individual mobs give the best expected useful-affix drops per 1000 kills.

All counts cover affixes obtainable from **killable mobs**. Items sourced only from vendors, quests, crafting, or world-object containers are not counted (they are not farmable by killing).

> **Requires Synastria/WoWExt.** AffixFinder relies on the server's custom item and attunement APIs (the same ones AtlasLoot, AttuneHelper, ScootsCraft, etc. use). Every custom call is guarded, so the addon won't error on a vanilla client, but it only produces results on Synastria.

## About attunement

Synastria has a deep long-term progression system built around item **attunement**. Any equippable item with stats can be attuned by equipping it and gaining experience while wearing it; once attuned, the character permanently gains a share of that item's stats. Most items have no random affix, so attuning them is a one-time task. Some items also carry **affixes** ("of the Monkey", "of Fire Resistance", and so on): attuning one affix is enough for the base item to count as attuned, but attuning additional affixes can further strengthen the character and feed other long-term systems.

AffixFinder helps you discover and prioritise the affixed items that are still worth attuning, and points you at the zones and mobs where you can farm them most efficiently.

## Installation

Copy the `AffixFinder` folder into your client's `Interface/AddOns/` directory (so you have `Interface/AddOns/AffixFinder/AffixFinder.toc`), then enable **AffixFinder** at the character-select screen.

AffixFinder persists **only lightweight state** in SavedVariables: a handful of settings, your window position and minimap-button angle, and a cached **list of affixed item ids** (just integers, so the next session can skip the one slow discovery pass) — **never the item graph or the scanned results**, which always stay in memory. See [Performance and memory](#performance-and-memory).

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

The Source and Expansion filters classify a zone by a normalized key — lowercased, punctuation turned to spaces, and difficulty/size qualifiers stripped from both ends, so `Utgarde Keep`, `Utgarde Keep Heroic`, `Naxxramas 25` and the server's compact codes (`Icecrown Citadel 25N`, plus the server-specific Mythic) all collapse to their base instance. Names come from: the client's LFG dungeon database (exact localized 5-man dungeon names with type and expansion), static raid/dungeon name lists (the LFG DB doesn't list raids in 3.3.5), and the continent map (plus battlegrounds and continent names) for open-world zones. Open-world identity wins: a zone that is a warp destination, a continent-map zone, or on the curated battleground/continent list is treated as **world** even if the server's LFG database also lists it — Synastria registers open-world zones (e.g. warp destinations) in its LFG database, so without this a zone like Teldrassil would be mislabelled a dungeon. (Every server warp zone is an outdoor zone or city, so AffixFinder's bundled warp-zone list is the authoritative, always-available source for this, regardless of what the LFG database or map API report.) Hub-prefixed names like `Auchindoun: Auchenai Crypts` are matched by the instance name as a suffix (longest match wins). A zone it still can't place counts as `unknown` and is always shown, so these filters never silently hide data they can't place. Run `/af zonedbg` to see exactly how the current data classifies and which zones land as `unknown`.

**Panels (tabs).** Each tab is a different view of the *same* filtered slice, so switching tabs never rescans:

- **Zones** — zones ranked by total affixes left (the `/af zones` view). Hover a row for its per-category breakdown; click a row to drill the Mobs panel down to that zone.
- **Mobs** — *individual* mobs ranked by expected useful-affix drops per 1000 kills, one row per NPC (`Mob`, `Zone`, `Drops/1k`, `Spawns`, `Items`), with a **Zone** filter box (type a substring, click a Zones row, **Clear** to reset, or **Curr** to filter to the zone you are standing in) and a **Min spawns** control (default from [Settings](#settings), `5` out of the box, to hide the long tail of rare/sparse spawns; set it to `0` to include everything). Every column is a per-mob value — nothing is summed across mobs — so `Items` is how many affixed items (still having affixes left) that mob drops. Changing these only re-filters; it never rescans.
- **Current Zone** — the player's current zone broken down per item category (the `/af` view as a table).
- **Classes** — *(Account scope only)* the ten classes ranked by how many affixes the account can still attune on each (`Class`, `Affixes left`, `Items w/ left`, `Unattuned`), class-coloured. It respects the Source/Expansion filters, so with everything on it answers "which class should I main for affixes?" and with the filters narrowed it answers "best class for this content". See [Per-class breakdown](#per-class-breakdown).
- **Resist** — a different mode for farming **one chosen resistance**. A `Resist` selector (`Fire`/`Nature`/`Frost`/`Shadow`/`Arcane`) and a `Min spawns` box sit in the control strip; columns are `Zone`, `Resist/1k`, `Best mob`, `Spawns`, `Items`. Rows rank zones by the estimated resist *gained* per 1000 kills of the best farmable mob. Clicking a zone row pins that zone's **best mob** on the map exactly like the Mobs view (and, with the t3 warp assist enabled, opens the map to it). The shared **Scope** filter, the **Include mythics** setting, and the display-time **Source/Expansion** filters apply; **Forge**, **Bind**, and **Class** do not (resist attunement is a flat fraction per forge and is class-agnostic, so they can't change the ranking) — and the filter bar greys those three out while the Resist tab is active to make that clear. See [Farming a specific resistance](#farming-a-specific-resistance).

**List.** The list is virtualized (a small fixed pool of row frames over a `FauxScrollFrame`), so hundreds of zones or thousands of mobs cost a handful of frames rather than thousands. Click any column header to sort by it; click again to reverse — and hover a header for a one-line explanation of what that column means. The footer shows scan state — including a **stale** marker (with the auto-refresh countdown) when you have attuned something since the slice was built, see [Settings](#settings) — and a **Rescan** button (equivalent to `/af clearcache` followed by a fresh scan). The **Current Zone** panel re-renders automatically as you move between zones while the window is open. The window closes with its close button or `Escape`.

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
- `/af debug <itemId|link> [maxRows]`: dumps the raw `ItemLocGetSourceAt` rows for one item (each field, the computed drop probability, and whether the row is classified as a farmable mob). Accepts a bare item id or a shift-clicked item link.
- `/af zonedbg`: prints how the zones in the current data classify (category/expansion counts) and lists the zones that came back `unknown`.
- `/af warp`: probes the t3 map-warp assist for your **current** zone — prints how the zone classifies (`world`/`dungeon`/...), the resolved warp index, and the `CustomHasTeleport` tier (0 none, 1 T1, 2 T2, 3 T3), and whether that counts as T3 (so the assist would open the map).
- `/af affixdbg <itemId|link>`, `/af affixid <link>`, `/af resistval <link>`: developer diagnostics for the resist mode — they dump the affix mask ↔ `ItemAttuneAffix` mapping, the rolled affix id / key scheme, and an item's real resist value with an item-level scaling probe. Used to validate and calibrate the resist model; not needed for normal use.
- `/af clearcache`: resets the in-memory caches (the affixed-item list and all aggregated results); the next zone command rediscovers and rescans. Use after a server data reload.
- `/af mem`: prints a memory diagnostic (total Lua memory before/after a forced collect, memory attributed to this addon, and cache sizes).
- `/af help`: prints command usage.

Forge flags are treated as thresholds: `tf` means TF/WF/LF, `wf` means WF/LF, and `lf` means LF only.

Bind flags filter by how the item binds: `bop` counts only Bind-on-Pickup items, `boe` counts everything that is not BoP (Bind-on-Equip and unbound), and `both` (the default) counts all. For example `/af zones acc boe` ranks zones by account-scope affixes available on BoE items only.

### How counts are derived

AffixFinder treats the server's item-location source rows as the source of truth. It groups affix value by the `zoneName` reported by the server's own loot data and ignores non-actionable placeholder zones such as `?`. The current-zone view (`/af`) matches the current zone's name against that same zone data, so `/af`, `/af zones`, and `/af zones ev` all count the same thing.

Source rows are read the same way qtRunner reads them. The 8-value row is `srcType, srcObjType, srcObjId, chance, dropsPerThousand, objName, zoneName, spawnedCount`. A "mob" is an NPC id (`srcObjId`); its rows are merged keeping the highest drop chance and spawn count, and `chance` is treated as a drop percentage. A row counts as a killable mob only when `srcObjType == 0` (a creature) **and** `srcType` is not a vendor/quest/crafting type.

`/af zones ev N` treats `N` as the minimum spawn count a mob must have to qualify, which matches the farming question "is there a dense group of this mob to kill?" Sparse or unknown-spawn mobs (spawn count `0`) are excluded unless you pass `/af zones ev 0`.

For each qualifying mob, its expected useful-affix yield per kill is the sum, over every affixed item it drops that still has affixes left, of `dropChance * (affixes left / possible affixes)`. Multiplied by 1000 this is the mob's useful affix drops per 1000 kills. Each zone is scored by `best` (default), `avg`, or `total` across its qualifying mobs.

In the window's **Mobs** view, clicking a mob row marks that NPC on the world map and minimap; the **Resist** view does the same when you click a zone row, marking that zone's best mob. Only the latest clicked mob stays marked, so the map stays focused on the target you are actively farming.

The marker uses the server's own object tracking (the same mechanism qtRunner uses): you hand it the NPC id and the server — which knows every creature's spawn points — draws the marker itself, so **this works with no extra addons**. If **Questie** is installed, AffixFinder additionally drops a precise pin at the exact spawn coordinates and can position the map exactly there; without Questie it zooms the world map to the right zone. Questie is therefore a nice-to-have, **not a requirement**.

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

The exact resist an item grants lives in its rolled **suffix tier**, which is **not readable from an item id during a scan** — there is no `itemId -> value` server API, and the affix mask only identifies the resist *family*, not the tier or amount (`ItemAttuneAffix` stores stat *types*, e.g. `51 = fire`, not magnitudes). So the amount is estimated from **item level**, calibrated in-game against real `GetItemStats` values (`RESIST_CALIBRATION` in `AffixFinder.lua`, the one place to retune it).

Item level is a good proxy because it also captures a real quirk of the data: low-level items roll pure **"of X Resistance"** (Classic), while higher-level items roll **"of X Protection"** hybrids (TBC/WotLK) that grant *less* resist — and item level is what decides which an item uses, so a single item-level->value table reflects both. Two consequences: the estimate carries some spread (item slot also affects the amount — a shield gives less than a chest at the same level), and the curve is shown with a `~` and labelled an estimate. The ranking is robust regardless, because resist is monotonic in item level.

## Settings

`/af config` (or Interface → AddOns → **AffixFinder**) opens the options panel. The settings persist across sessions (only these few scalars — never the scanned data):

- **Include mythic items in calculations** (default **off**). Mythic items are very hard to farm, so by default the rankings ignore them. This is an item-level filter, so it is part of the scan/cache key: toggling it runs a one-time scan for the new combination, then is instant on return.
- **T3 map-warp assist from the Mobs/Resist views** (default **off**). Clicking a mob always marks the latest target on the map. When this is enabled, AffixFinder additionally opens that zone's world map so you can click the marked spot to warp there — but only when the map click can actually take you there. Synastria zone warps come in tiers by how many times you unlocked them: **T1** (fixed drop point), **T2 / warp mastery** (you set the point), and **T3 / warp attunement** (click *anywhere* on the map to land there). Only **T3** lets you click the marked spot, so the assist opens the map **only for zones you have at T3** — T1/T2 zones (and dungeons/raids, which have no zone warp at all) just get the marker. So you can safely leave it on with a partial set of T3 warps: it opens the map for the zones you can T3 to and quietly leaves the rest as a plain marker. (The tier check reads the server's `CustomHasTeleport`, which returns your unlock tier 0-3; AffixFinder bundles its own zone->warp-index table so this needs **no other addon**. Use `/af warp` to inspect the tier the addon reads for your current zone.)
- **Auto-rescan interval** (default **60 min**, range `0`–`180`). When the addon detects a change (e.g. you attune something), it will not automatically rescan a given filter more than once per this interval — between rescans it keeps serving the slightly-stale cached slice. `0` means rescan on every detected change. The **Rescan** button and changing filters always rescan immediately, regardless of this setting.
- **Default minimum mob spawns** (default **5**, range `0`–`50`). The starting value for the Mobs panel's **Min spawns** control. Typing a value into the in-window control overrides this for the session; changing the default here updates the window unless you have already overridden it.

In addition to the settings above, AffixFinder remembers your **window position** and **minimap-button angle** in `AffixFinderDB.ui` (two tiny scalars). These have none of the cost the item graph would (see below), so they persist for convenience while the scanned data still never touches disk.

## Per-class breakdown

In Account scope, every affix the account can attune is also attributed to the specific classes that can use the item, so the window answers two questions: *which class should I farm on for a given zone* (the Class dropdown), and *which zone should I farm for a given class* (pick a class, then read the Zones/Mobs panels). The **Classes** panel ranks the classes head-to-head.

There is no per-class server API — `CanAttuneItemHelper` only answers for the *current* character and `IsAttunableBySomeone` ignores class — so the attribution is derived statically from WotLK 3.3.5 proficiencies (in `getItemClasses`, `AffixFinder.lua`). Because the account scan already knows each item's affixes-left and that attribution, the per-class sub-totals are folded in during that one scan and the Class dropdown is a pure display-time re-slice (no extra scans).

The model:

- **Armor** uses the "intended/spec" material, made **level-aware** by the level-40 armor upgrade. Warriors/Paladins wear mail until 40 then plate; Hunters/Shamans wear leather until 40 then mail. So a **mail** item with required level `< 40` is a Warrior/Paladin leveling piece, while mail `≥ 40` is Hunter/Shaman; **leather** `< 40` also serves Hunter/Shaman on top of the always-on Rogue/Druid; **plate** is always Warrior/Paladin/Death Knight; **cloth** is the three pure casters.
- **Weapons** use real per-class proficiency; **shields** → Warrior/Paladin/Shaman; **held-in-off-hand** (orbs etc.) → every class; **relics** map to their one class (Idol→Druid, Libram→Paladin, Totem→Shaman, Sigil→Death Knight); **rings/necks/trinkets/cloaks** count for every class.

A class's per-zone/-mob numbers are a strict subset of the account totals, but the classes **overlap** (a ring counts for all ten, a mail item for two), so the per-class numbers are deliberately *not* a partition of the account total. The proficiency tables in `getItemClasses` are the single place to correct if a cell is wrong.

## Performance and memory

The hard constraints are **correctness/completeness** and **under ~100 MB**, with compute time treated as the flexible resource. The design follows directly from those:

- **No graph or results are persisted.** The only SavedVariable is `AffixFinderDB`: a few config scalars, the window/minimap layout, and a cached list of affixed item ids (`affixCache`, fingerprinted by `MAX_ITEMID`). Persisting the item->mob graph was what caused the multi-hundred-MB footprint (a SavedVariable is fully resident in RAM whenever loaded) and the minute-long logout (it is serialized in full on exit). The id list is just integers — cheap to store and load — so it has none of that effect; the graph and aggregates remain memory-only.
- **The affixed-id list is cached across sessions.** Finding which item ids carry a random affix is the one pass over the whole id space, and the answer is static for a given server-data version. It is saved (as ids only) and reloaded when the `MAX_ITEMID` fingerprint still matches, so only the *first ever* session pays that discovery cost. `/af clearcache` (or **Rescan**) drops it, forcing a fresh discovery after a server data reload.
- **The full graph is never stored — only aggregated.** The graph is ~1.27M item->mob rows (~110MB if kept), but what the views consume is tiny: per-zone affix totals (~200 zones) and per-mob expected value (~6.7k mobs). A scan reads each item's mob sources transiently and folds them straight into those small structures, then discards the sources. No capping, so results are complete and exact.
- **Two session caches:** the list of affixed item ids (found once by scanning the whole id space; static for the session, and additionally cached on disk as ids — see above), and the aggregated per-zone / per-mob results, keyed by scope+forge+bind (memory-only, never written to disk). All `/af`, `/af zones`, and `/af zones ev` variations format from the aggregated results, so changing the EV threshold/mode/limit never rescans. Only switching scope/forge/bind — or attuning, which clears the aggregates — triggers a new scan.

So the first zone command of a scope/forge pays a one-time scan (seconds, chunked); everything after is instant until you attune or `/af clearcache`. Passes are chunked with a per-frame **time budget** (about 6 ms) rather than a fixed item count, so the client stays responsive regardless of per-item cost. Only one scan runs at a time; a command issued while another is in progress reports "busy" rather than stacking work.

## Acknowledgements

AffixFinder borrows useful ideas, assets, data-access patterns, and map/UI integration details from other Synastria addons. Special thanks to **Netrinil** for the Questie 3.3.5 work that AffixFinder can optionally use for precise map pins, and to **Qt** for qtRunner, whose tracking, warp, attunement, and source-row logic helped shape several of AffixFinder's farming workflows.

## License

Released under the [MIT License](LICENSE).

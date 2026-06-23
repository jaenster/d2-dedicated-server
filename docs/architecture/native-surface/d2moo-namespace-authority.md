# D2MOO namespace authority

When a reconstructed function looks misclassified (server logic filed under
`D2Client`), the correct home is **not a guess** — D2MOO (the open
reimplementation that mirrors the original D2 DLL/file layout) is ground truth.
Its per-DLL ordinal `.def` exports name functions `SUBSYSTEM_VerbNoun @ordinal`,
so the **subsystem prefix encodes the module**. Source: `D2MOO/source/*/definitions/*.1.10f.def`.

Our reconstruction's names differ (`FindWaypointIdByLevelId` vs D2MOO
`WAYPOINTS_GetWaypointNoFromLevelId`), so matching is behavioural, but the
**domain → module** mapping below is authoritative.

## D2Common — the shared data/model layer (1308 exports)

`ITEMS, UNITS, DATATBLS, DUNGEON, SKILLS, INVENTORY, PATH, STATLIST, STATES,
MISSILE, COLLISION, MONSTERS, ENVIRONMENT, ITEMMODS, TEXT, UNITROOM, DRLG, CHAT,
WAYPOINTS, UNITFINDS, SEED, QUESTRECORD, LOG, DRLGPRESET, COMPOSIT, MISSTREAM`

src files: `D2Chat, D2Collision, D2Composit, D2Dungeon, D2Environment,
D2Inventory, D2Log, D2QuestRecord, D2Seed, D2Skills, D2StatList, D2States,
D2Text, D2Waypoints` + `DataTbls/ Drlg/ Items/ Monsters/ Path/ Units/`.

## D2Game — server gameplay (exports: GAME, QUESTS, PLAYER, TASK, CLIENTS, DEBUG)

src subsystems: `AI, DEBUG, GAME, INVENTORY, ITEMS, MISSILES, MONSTER, OBJECTS,
PLAYER, QUESTS, SKILLS, UNIT`.

NB several domains appear in **both** DLLs: D2Common holds the data/model
(`SKILLS_GetSkillLevel`, `INVENTORY_GetCompositItem`), D2Game holds the server
behaviour (skill execution, inventory ops). Split by what the function does:
reads/returns data → D2Common; mutates game state per a client command → D2Game.

## D2Client — presentation only

Genuinely client: `GFX/D2GFX, DRAW, LIGHTMAP, PALETTE, CEL, DC6, AUTOMAP, CURSOR,
FONT, PANEL/MINIPANEL/SPELLSEL/BELT (UI), CHARSEL/MAINMENU, CUTSCENE`, plus
`D2Win` (windowing) and `D2Sound`. These stay; the server stubs/wires them.

## Resolutions for our misplaced list

- Waypoint fns → **D2Common** (`D2Waypoints`); also `DUNGEON_HasWaypoint @10060`
  settles the ambiguous-gap `HasWaypoint` → D2Common.
- `COMPOSIT_*` → **D2Common** (`D2Composit`) — *not* presentation.
- `.txt` accessors (`*TxtLine`, `Get*Line`, `TXT_*`) → **D2Common::DataTbls**.
- RNG / random → **D2Common** (`D2Seed`).
- stat getters → **D2Common** (`D2StatList` / `D2States`).
- chat/text helpers → **D2Common** (`D2Chat` / `D2Text`).

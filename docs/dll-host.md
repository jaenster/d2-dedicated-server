# Hosting the pre-1.14 DLLs

A game server built on the real `D2Game.dll` instead of the 1.14d monolith. The interesting result
of the investigation: **the host contract is the one d2gs already implements.** It did not change
between 1.10f and 1.14d, so `engine/realm.zig` is most of the port already.

## The two calls that start a server

Both live in `D2Game.dll` and are exported by ordinal, so no offsets are needed:

|ordinal|function|what the host must pass|
|-|-|-|
|10002|`GAME_InitGameDataTable`|two host-allocated structures: the game-data table and the game-list handle. D2Game asserts both non-null (`ptGameDataTbl`, `phGameList`)|
|10023|`GAME_SetServerCallbackFunctions`|a pointer to the callback table below|

Verified against the real 1.10f binary rather than taken from D2MOO: `GAME_SetServerCallbackFunctions`
@`0x6FC358E0` **stores the pointer** (`DAT_6fd45830 = param_1`) and sets a validity flag — it does
**not** copy the struct. The host therefore has to keep the table alive for the life of the process;
a stack temporary would leave D2Game calling into freed memory.

## The callback table

`D2ServerCallbackFunctions`, 0x40 bytes, 16 pointers, `#pragma pack(1)`. `__fastcall` unless noted.

|slot|callback|already in `engine/realm.zig`|
|-|-|-|
|0x00|`pfCloseGame(u16 gameId, u32 product, u32 spawnedPlayers, i32 frame)`|yes|
|0x04|`pfLeaveGame(...)` — 14 args, ends with the save timestamp|yes|
|0x08|`pfGetDatabaseCharacter(clientInfo**, charName, clientId, accountName)`|**yes** — the one that drives the join|
|0x0C|`pfSaveDatabaseCharacter(clientInfo**, charName, accountName, saveData, size, token)`|yes|
|0x10|`pfServerLogMessage(i32 level, fmt, ...)` — **cdecl varargs**|no|
|0x14|`pfEnterGame(u16 gameId, charName, classId, level, flags)`|yes|
|0x18|`pfFindPlayerToken(charName, tokenId, gameId, outAccount, outToken, a6, a7)`|yes|
|0x1C|`pfSaveDatabaseGuild` — unused|no|
|0x20|`pfUnlockDatabaseCharacter(gameData*, charName, accountName)`|no|
|0x24|unknown, unused|no|
|0x28|`pfUpdateCharacterLadder(charName, classId, level, exp, 0, flags, timestamp)`|no|
|0x2C|`pfUpdateGameInformation(u16 gameId, charName, classId, level)`|no|
|0x30|`pfHandlePacket(packet*, size)`|no|
|0x34|`pfSetGameData() -> u32`|no|
|0x38|`pfRelockDatabaseCharacter(clientInfo**, charName, accountName)`|no|
|0x3C|`pfLoadComplete(i32)` — **stdcall**, unused|no|

Slots 0x00–0x18 match d2gs's independently reverse-engineered 1.14d table exactly, including
`pfGetDatabaseCharacter` at 0x08. Two independent derivations agreeing on the layout is the strongest
evidence available that the interface is stable across the whole DLL era.

**1.14d is a superset.** d2gs also fills `fpGetDatabaseFileTime` at slot **0x54**, past the end of the
0x40 struct — 1.14d grew the table. So the ladder-timestamp workaround d2gs needs (`nReason 0x1a`
refusals) has no 1.10f equivalent and can be dropped when hosting 1.10f.

Mixed calling conventions matter: most entries are `__fastcall`, `pfServerLogMessage` is cdecl
varargs, `pfLoadComplete` is stdcall. Zig needs naked-asm shims for the fastcall ones.

## Which modules to load

From the real import tables (`~/code/d2-patch-extract/1.13c-lod/IMPORTS.txt`):

|module|why|surface|
|-|-|-|
|**D2Game**|the server logic itself|—|
|**D2Common**|units, tables, collision, path, items|**716 symbols — cannot be faked**|
|Fog|pool allocator, MPQ, asserts|71 ordinals|
|Storm|archives, memory|18 ordinals|
|D2Net|packet send/recv|11 ordinals|
|D2Lang|`Unicode::` string helpers|13 ordinals|
|D2CMP|cel decompression|9 ordinals|

Load D2Game + D2Common for real; the other five are cheaper to implement than to keep per-version.
Implementing them is also how the host gets to own the allocator, the MPQ reads and the socket layer
— which is most of what a server wants control of anyway.

Measured, this is what satisfying D2Game+D2Common actually costs:

|module|exports|D2Game+D2Common import|
|-|-|-|
|D2Net|40|11|
|D2CMP|107|8|
|Storm|361|10|
|D2Lang|63|4|

**The Fog surface is the union over every module loaded, not over D2Game+D2Common.** That is 92
ordinals, against the 53 those two import — and 31 of the difference exists solely because Blizzard's
D2Net is present (10149 `FOG_InitializeServer`, 10151-10187, 10219-10224: its QServer and socket
layer), with 7 more for D2CMP. Getting this wrong is not a soft failure: wine aborts the process on a
call to an unimplemented export, so a short export list reads as a hard kill with a dialog.

Which settles the order to replace them in. Standing up our own D2Net costs **14 functions** (the 11
D2Game+D2Common import, plus the 3 the host calls) and *removes* 31 Fog ordinals of Blizzard
networking we would otherwise have to write purely to keep a module we intend to replace. It is
strictly less work than keeping it, and it is the layer where our own realm integration belongs.

Not needed at all: D2Client, D2Win, D2gfx, D2DDraw, D2Direct3D, D2Glide, D2Gdi, D2Sound, D2Launch,
D2Multi, D2MCPClient, Bnclient, Binkw32, D2VidTst.

## Init order — from Blizzard's own host

No guesswork needed. `D2Server.dll` (retail 1.00, in the Ghidra project at `/server/D2Server.dll`)
**is** the original closed-realm game server: it imports 26 D2Game ordinals, 32 Fog, 11 Storm, 6
D2Net, 5 D2Common, and its `WinMain` @`0x10009EA0` is the startup sequence verbatim:

```
FOG_10139()                          Fog pre-init
LoadMPQArchives()                    MPQ FIRST, before anything else
<C++ static init table walk>
CreateDialogParamA / ShowWindow      the server UI (a headless host skips this)
FOG_InitErrorMgr()                   the HOST installs the error manager
ParseIniFile()
LoadBnClientDll()                    only when the char server is enabled
D2LANG_10000()                       D2Lang init
DATATBLS_LoadAllTxts(lang, 1, 0)     the data tables
D2NET_SERVER_Initialize(0, 0)
D2NET_SERVER_SetMaxClientsPerGame(n) n from the ini
D2NET_SERVER_SetHackListEnabled(1)
D2GAME_10046()                       D2Game module init
ConnectToCharServer() + wait         realm link, before the callbacks are installed
GAME_SetServerCallbackFunctions(&table)
GAME_InitGameDataTable(&p1, &p2)
TASK_InitializeClock()
CreateThread(McpServiceThread)       the realm (MCP) link
N x CreateThread(GameWorkerThread)   N = CPU count, read from FOG_GetSystemInfo()+0x28
<Win32 message loop>
```

Shutdown is the mirror: `PurgeAllGames` → `TASK_FreeAllQueueSlots` → `D2NET_SERVER_Release` →
`D2GAME_10050` → `DATATBLS_UnloadAllBins` → `D2LANG_10001` → `D2COMMON_10983` → `UnloadMPQArchives`.

Three things this corrects about the obvious guess:

- **`SetServerCallbackFunctions` comes BEFORE `InitGameDataTable`**, not after.
- **The host calls `FOG_InitErrorMgr`**, early and itself — it is not something D2Game does for you.
- **Games tick on N worker threads**, one per CPU, running `TASK_ProcessGame` / `D2GAME_10043`. The
  main thread only pumps messages. A headless host replaces the message loop, not the workers.

The host-facing D2Game ordinals are stable across the DLL era: 1.00's D2Server imports 10002, 10023,
10039, 10046, 10047 — the same numbers 1.10f uses.

## `apps/d2host` — the spike, and it runs

`zig build d2host` produces an x86-windows console exe; `wine d2host.exe <dir-with-the-dlls>` loads
the seven modules, resolves both ordinals, installs a table of reporting stubs, and calls the two init
functions. **Verified working against real 1.10f binaries under wine:** all seven load, ordinals
resolve at `0x6FC35880` / `0x6FC358E0` exactly as Ghidra said, and both calls return.

Nothing calls back during init, so the stubs stay silent — which is itself the answer to "what does
D2Game need at startup": only the two structures and a table it merely stores.

## Bring-up log: what the spike proved, in order

Each step below was found by running it, not by reading code — the value of the spike is that a
failure names its own cause.

1. **All seven modules load** and both ordinals resolve at the addresses Ghidra predicted.
2. **`GAME_InitGameDataTable` + `GAME_SetServerCallbackFunctions` both return.** No callback fires
   during this, so startup asks nothing of the host beyond the two structures and the table.
3. **`GAME_CreateNewEmptyGame` (@10047) blocked forever** — 0% CPU, state `S`. `WINEDEBUG=+relay`
   named the cause exactly:
   `RtlpWaitForCriticalSection section 6FD45800 "?" ... blocked by 0000` — an *uninitialised*
   critical section, owned by nobody. That address is `DAT_6fd45800`, the game-list lock the
   decompile shows `GAME_CreateNewEmptyGame` taking on its first line via Fog's `@10050`.
4. **The missing call is D2Game `@10046`**, now named `GAME_InitServerModule` in the database. It is
   the module init and must run *first*: `InitializeCriticalSection(&DAT_6fd45800)`, clear the
   0x400-entry game array, `CLIENTS_Initialize`, `FOG_InitErrorMgr(handler)`,
   `SUNITPROXY_FillGlobalItemCache`. Correct order is **10046 → 10002 → 10023**.
5. With 10046 wired in, the hang is gone and the failure moves on: **segfault in Fog at `0x6FF56FB8`**,
   instruction `MOV [ECX + 0xbbc], EAX`, faulting address `0xbbc` — so `ECX` is null. `0xbbc` is an
   offset into the `0xc4c`-byte structure that **`FOG_InitializeServer` (@10149)** allocates.

**Next missing call: Fog's own init, before D2Game's.** This is exactly the documented order — Fog
pool first — which the spike skipped. `FOG_InitializeServer` takes 8 arguments and creates sockets,
so its parameters need establishing before the next attempt; 1.14d's fully-named `Game.exe` performs
the equivalent sequence and is the cheapest place to read them off.

6. **Our Fog now serves files, and the failure became specific.** With the real calling conventions
   and a file layer in place, `DATATBLS_LoadAllTxts` gets as far as `FOG_AllocLinker` and then names
   what it wants: `Error opening file: DATA\GLOBAL\EXCEL\compcode.bin`. A missing-input failure
   rather than a broken-ABI one.
7. **Fog reads the MPQs, and the table and tile load completes.** Serving files out of the archives
   rather than an extracted tree is a correctness requirement, not a convenience: a listfile is an
   ordinary, optional member and retail's `Patch_D2.mpq` has none, so extraction only recovers
   members someone already knew to name. `data\global\excel\CompCode.bin` is the proof — absent from
   every listing, present in the archive, required by the loader. Lookup is by name hash, so the
   archive answers for unlisted members. Against the minimal 1.14d archives (12 MB of the retail
   256 MB), 1.10f's D2Common opens **2,640 files with one miss** and gets through the whole table
   load and the DT1 tile load into level init.
8. **The one miss and its sibling are server-only tables.** `runessrv` and `cubeserver` appear in no
   shipped archive and are absent from a 40,700-entry community listfile of every D2 MPQ — Blizzard
   built them into server distributions only. A `.bin` is a `u32` record count followed by fixed
   records (`CompCode.bin` is 115 x 4 + 4; `montype.bin` is 59 x 12 + 4), so an empty table is four
   zero bytes and the loader accepts it.
9. **Next: the export set must cover every loaded module.** The abort after the tile load is
   `Fog.dll.10149` — reached from D2Net, not from D2Game. See the module table above.

## Supporting more than one version

Measured from the export and import tables of the real DLLs — 1.00, 1.06b, 1.07, 1.09d, 1.10f —
rather than assumed. The result is that far less varies than the version count suggests.

**Ordinals are a hand-maintained ABI, not linker output.** D2Game has holes at exactly
10030/10031/10032 in every version from 1.00 to 1.10f, and D2Common's export table has 137 holes by
1.10f against none in 1.06b: numbers are retired and never reused, new work is appended. So all
eight host-facing D2Game entries (10002, 10010, 10023, 10039, 10043, 10046, 10047, 10050) are
present, at the same numbers, in every version.

Ordinals imported by D2Game+D2Common, and the overlap at each step:

|provider|1.00|1.06b|1.07|1.09d|1.10f|
|-|-|-|-|-|-|
|Fog|34|40|49|49|53|
|Storm|17|12|11|10|10|
|D2Net|9|11|11|11|11|
|D2Lang|3|3|4|4|4|
|D2CMP|8|8|8|8|8|

|boundary|Fog|Storm|D2Net|D2Lang|D2CMP|
|-|-|-|-|-|-|
|1.00 → 1.06b|33/34|12/12|9/9|3/3|8/8|
|1.06b → 1.07|**9/40**|10/11|11/11|3/3|8/8|
|1.07 → 1.09d|46/49|10/10|11/11|4/4|8/8|
|1.09d → 1.10f|**49/49 ⊂ 53**|10/10|11/11|4/4|8/8|

**Fog renumbered exactly once, at the LoD boundary.** Everything else holds across the whole range,
including that boundary. 1.09d's Fog imports are an exact subset of 1.10f's; the four additions are
10252–10255 (popcount, CLZ, the Calc expression compiler). So there are two Fog numberings —
`classic` (1.00–1.06b) and `lod` (1.07 onward) — not one per version.

### Rewriting import tables instead of shipping a Fog per family

A by-ordinal import is a bare `0x80000000 | n` in the thunk array: a `u32` in the file, no
relocation, no size change. So a version's `D2Game.dll`/`D2Common.dll` can be retargeted onto one
canonical Fog numbering before load, and we ship a single Fog. `lod` is canonical — it is the
numbering already implemented and named.

The mapping table is keyed by **name**, with one column per numbering, and serves three uses: the
import rewrite, our own calls into the engine (necessary, because D2Common's numbering does drift —
D2Game's D2Common imports go 740 → 711 across 1.09d → 1.10f, 72 retired and 43 new), and naming
1.06b/1.09d exports in Ghidra from the 1.10f corpus.

The RE debt this leaves is small and specific: Storm/D2Net/D2Lang/D2CMP and D2Game need **no rows at
all**, the LoD Fog column is identity, and D2Common needs a row only per ordinal the host itself
calls. What is genuinely unknown is **31 classic-era Fog ordinals** (40 imported, 9 already coincide
with LoD). Those are a fingerprinting job, not hand work: match against 1.10f's named Fog on which
Storm ordinals a function calls (Storm's numbering is stable across the whole range, so it is a
version-proof anchor), the string literals it references, and its opcode sequence with immediates
and relocations masked.

One trap to design against: a wrong row fails as a *silently wrong call*, not a missing import. So
the rewriter must refuse an ordinal with no entry rather than pass it through — the same discipline
`stackArgs` uses for uncounted callback slots.

### 1.10 is where compiled tables start

**Corrected by running it.** 1.09d's `CompileTxt` has *both* paths — the `.bin` strings are right
there in its D2Common — and picks between them on `DAT_6fdc5bc0`, which is **1 in the image and
never written**. So 1.09d always reads `.bin`, its `.txt` branch is dead code, and a live 1.09d run
opens `playerclass.bin`, `states.bin` and the rest exactly like 1.10f does.

That inverts the conclusion below. Retail's archives ship no `.bin`, so 1.09d cannot be fed retail
data directly — it needs 1.09-era compiled tables, and the engine asserts rather than coping when
given 1.14d-era ones:

```
assert "nLoadedValue < MAX_SKILL_RESTRICTED_STATES"  DataTbls.cpp:561
```

Those `.bin` files can be *generated*, and by this engine: `CompileTxt`'s first branch, gated on
`DAT_6fde1cec` (0 in the image, and written by an exported setter at 0x6fd47950), reads the `.txt`,
decodes it, and **writes the `.bin` back out** — which is how Blizzard built the server
distributions. It needs `FOG @10207`, the txt→record decode, which we still stub. So one piece of
work unblocks both: implement 10207, run 1.09d once in compile mode against retail text tables, and
keep the `.bin` files it emits. 1.09d hardcodes most of its limits and ships few tables, so the set
to generate is small.

That inverts the bring-up order. 1.10f was chosen first for its naming density, but the blocker
turned out to be data, and **1.09d is the cheaper first boot**: same Fog family as 1.10f (49/49
identity, so every Fog ordinal already implemented applies unchanged), same D2Game host ordinals,
and text tables we already have. Its only new cost is counting `stack_args` at its callback call
sites — which `callbacks.stackArgs` refuses to guess.

`packages/d2engine/version.zig` holds all of the above as data.

## The base addresses collide — plan for relocation

1.10f's own link layout is self-conflicting, from the PE headers:

|module|preferred base|SizeOfImage|end|
|-|-|-|-|
|D2Net|0x6FC00000|0x00D000|0x6FC0D000|
|D2Lang|0x6FC10000|0x015000|0x6FC25000|
|**D2Game**|0x6FC30000|0x127000|**0x6FD57000**|
|**D2Common**|**0x6FD40000**|0x0B4000|**0x6FDF4000**|
|**D2CMP**|**0x6FDF0000**|0x107000|0x6FEF7000|
|Fog|0x6FF50000|0x056000|0x6FFA6000|
|Storm|0x6FFB0000|0x045000|0x6FFF5000|

D2Game overruns D2Common by **92 KB** (it grew 160 KB in 1.10), and D2Common overruns D2CMP by 16 KB.
Whoever loads first keeps its link address and the loser gets relocated, so **D2Game and D2Common can
never both be at their preferred bases.** Measured both ways: the order in `main.zig` costs one
relocation (D2Common → `0x1e10000`, D2Game keeps `0x6FC30000`), while loading D2Common first costs two
(D2CMP *and* D2Game move, D2Game landing at `0x1f60000`).

Consequences:

- **Resolve everything by ordinal.** RVAs survive relocation; absolute addresses do not. The spike
  proved this — after relocation the ordinals still resolved, at base + the same RVA.
- D2MOO's annotated addresses and the Ghidra databases are **preferred-base** addresses. Correct for
  static analysis, wrong at runtime for whichever module moved. Any runtime hook must add the actual
  `HMODULE` base to an RVA, never use the literal.
- This is not a wine artifact — it is in Blizzard's own headers, so the retail 1.10f client relocates
  a module too.

## Where the binaries are

`~/code/d2-1.10f-binaries/` (also `extracted/LODPatch_110/` on the NAS). Every version 1.01–1.13d is
under `Diablo 2/patch/extracted/<installer>/`, rebuilt with `tools/d2patch`.

1.10f is the version to build against first: it is the only pre-1.14 version with a dense naming
corpus (4,108 D2MOO addresses, all applied to the Ghidra project), so when something misbehaves the
disassembly is readable.

## Open questions

- ~~A scan of the 41 xref sites to `DAT_6fd45830` only recovered slots 0x08, 0x0C and 0x20.~~
  Resolved: a wider sweep recovers **twelve** of the sixteen. See "Every callback arity, counted"
  below — the heuristic needed to follow `LEA reg,[table+n]` / `ADD reg,n`, which is how the engine
  reaches the higher slots, and to fall back to the decompiler where a register is clobbered across
  a switch.
- `pfHandlePacket` (0x30) is dispatched by `GAME_ProcessRealmMessage` (1.10f @0x6fc38140, 1.09d
  @0x6fc37f50) with zero arguments, from the case that also answers 0xFA/0xFB/0xFC connect and
  disconnect bookkeeping. So it is on the client-message path, not a separate realm control channel.
- The **third** method D2Game uses to reach the host, past the 16-slot callback table: what its four
  virtual methods do. See below.

## What is left

### One image per engine, and the version is compiled in

A release artifact is built FOR an engine rather than carrying all of them and choosing later:

```
deploy/build-d2host.sh 0.0.1            # every engine that is ready
deploy/build-d2host.sh 0.0.1 1.09d      # just one
```

Tags are `<our release>-d2-<engine>` — `d2gs:0.0.1-d2-109d` — the same shape as a base image
naming what it is built on. Both halves are build args (`APP_VERSION`, `D2_VERSION`).

The point of pinning at build time is that it moves the readiness gate from runtime to the
compiler. `-Dengine-version=1.06b` does not produce an image that exits on start; it fails to
build:

```
error: -Dengine-version=1.06b is not ready to serve: missing fpEnterGame,
       fpUpdateCharacterLadder (and/or no measured client layout)
```

So the set of engines that *can* be tagged is exactly the set that is finished, and nobody has to
maintain a list of which those are — `build-d2host.sh` iterates every known version and lets the
compiler decide. A refusal there is a correct outcome, not a broken pipeline.

Two things follow from the version being a constant rather than a flag:

- `D2GS_ENGINE_VERSION` is **refused**, not ignored, if it disagrees with the build. An image
  tagged for one engine quietly serving another is the failure a per-version tag exists to prevent.
- The binary shrinks to one engine's code. The default build (no `-Dengine-version`) still carries
  every measured version and keeps the runtime switch, which is what local bring-up wants — a probe
  run is a run of the same binary.

Game data is not baked in, and for these versions the *era* matters as much as the licence: a
`.bin` is a raw struct dump, so an install from another patch level decodes as garbage rather than
failing cleanly. Mount the matching era at `/game`.

### The work queue, in dependency order

- [ ] **`FOG @10207` — the txt→record decoder.** The keystone: it unblocks 1.08, 1.09d and 1.06b
      at once, and closes 1.10f's runewords/cube gap. Not so the engines read `.txt` — they do not,
      see below — but because `CompileTxt`'s other branch, gated on `DAT_6fde1cec` and an exported
      setter, reads `.txt` and **writes `.bin` back out** using that version's own field
      descriptors. That is how Blizzard built server distributions, and it is the only way to get
      era-correct tables for versions whose data we do not have. Real function: 1.10f Fog
      @0x6ff5aa60. Field descriptor is 0x14 bytes — name, type (0 terminates), size/bit, record
      offset, linker-or-callback — and roughly 20 column types. Every piece it leans on (linkers,
      string tree, `GetRowFromTxt`, `CreateBinFile`) is already implemented in `packages/d2fog`.
- [ ] **Drive the compiler and keep the output.** Once 10207 exists: set the per-version compile
      flag, run each engine once against the retail text tables, and keep the `.bin` files it
      emits as that version's data.
- [ ] **1.06b: wire `tools/fogrewrite` into a staged install** and boot it. The rosetta and the
      rewriter are both done; nothing has been run through them yet.
- [ ] **1.06b: three slots are unmeasured** — `fpEnterGame`, `fpUpdateCharacterLadder`,
      `fpUpdateGameInformation`. Their call sites have an indirect call in the window, so the stack
      simulation cannot resolve what it consumes. They are `null` and therefore refused.
- [ ] **1.06b: find its `.bin`/`.txt` selector.** 1.07, 1.08 and 1.09d all hardcode it to 1 (always
      `.bin`); 1.06b's was not located. If it turns out to be 0, 1.06b needs no era data at all —
      only 10207.
- [ ] **1.06b: measure its callback shape** with `D2GS_ENGINE_PROBE=1`, the same way 1.07's was.
- [ ] **13 rosetta rows rest on the structural constraints only** (order + matching `ret N`), not
      on a decisive fingerprint. `lodFor` refuses them unless a caller opts in.
- [ ] **1.13c renumbered D2Game's host ordinals** — `@10023` is a bare `ret 4`, `@10046` is
      `mov eax,1; ret 0x18`. `version.GameOrdinals` does not extend to it and needs its own row.
- [ ] **1.07/1.08's S->C direction is unverified.** Our test client speaks 1.14d, so it stops
      understanding after GameFlags. Irrelevant with a period client; it only blocks *our* ability
      to watch world state locally.

### Notes that changed the plan

**Every pre-1.10 build reads `.bin`, not `.txt`.** This document used to say only 1.10f had a
compiled-table path. All of 1.06b, 1.07, 1.08 and 1.09d carry both, and 1.07/1.08/1.09d hardcode
the selector to `.bin`. A `.bin` is a raw struct dump, so only its own era's engine can read one:
1.08 loads 1.07's `lvltypes.bin` at the wrong stride and asks for `DATA\GLOBAL\TILES\wn\Floor.dt1`
— a fragment, not a filename — where 1.07 reads the same file and gets
`DATA\GLOBAL\TILES\Act1\Town\Floor.dt1` with zero misses.

**The patch installers carry no data.** `LODPatch_109d.exe` carves to 1.7 MB of twenty PE deltas
and no data member, so era tables cannot be recovered from the patches — they have to be compiled.



**Goal 1 (a working 1.10f server) is done.** Every item that used to block it — our own D2Net,
game creation, the 16 callbacks, a real client joining and playing — is finished and verified: see
"A character joins a game on the 1.10f engine" and "A 1.14d client plays on the 1.10f server" below.

What remains is goal 2 (multiple versions, cleanly) plus the small honest gaps 1.10f itself still
has:

- **`d2host` selects its version at runtime, not at compile time.** `D2GS_ENGINE_VERSION` (default
  1.10f) picks the build the same way `D2GS_REDIS_ADDR` picks a store — one binary carries every
  measured version's code, and `switch (requested) { inline else => |v| ... }` monomorphizes the
  whole bring-up-and-tick path once per `Version` enum value, dispatched at runtime. Two layers
  catch a version that is not actually usable, at two different points:

  1. `callbacks.isComplete` — every slot in `callbacks.accounted_slots` (all sixteen bar the two
     convention exceptions, 0x10 cdecl-varargs and 0x3C stdcall) has an answer: either a counted
     stack-arg number or `no_site_found`. Selecting a version that still has a `null` fails cleanly
     at runtime, naming exactly what is missing (`callbacks.missingSlots`).
  2. `Binding(comptime version)`'s own comptime asserts — completeness of *data* is not correctness
     of *code*. A handler may name FEWER stack parameters than the engine pushes, because the shim
     pushes and cleans all of them and trailing arguments simply go unread; naming MORE reads the
     engine's stack as if it were arguments. So `assertReads` enforces a floor per slot, which is
     also what lets one `findPlayerToken` body serve 1.10f's five-argument call and 1.09d's three
     instead of needing a per-version override.

  Adding a version that reaches both gates is exactly: measure its remaining required slots and
  `hostapi.clientFields`, and — only if an arity genuinely differs from what `Binding`'s current
  bodies assume — add that one version's override function. Nothing else in `d2host` changes.
- **1.09d: every slot measured, and it boots as far as the data lets it.** Both versions were
  swept the same way and the results are in `callbacks.v109d` / `callbacks.v110f`. The two are NOT
  interchangeable: `fpFindPlayerToken` takes 3 stack args on 1.09d and 5 on 1.10f, `fpCloseGame`
  takes 0 and 2, and `fpUnlockDatabaseCharacter` has a 1.10f dispatch (`GAME_JoinGame` @0x6fc372fc)
  with no 1.09d counterpart. Everything else agrees, including `fpLeaveGame`'s 13.

  `D2GS_ENGINE_VERSION=1.09d` now gets through module load, both ordinal lookups (at 1.09d's own
  0x6fc35680 / 0x6fc356e0), the callback table, `STRTABLE_Init`, and eleven data tables — then
  faults with `EIP=0` inside D2Common's `DataTbls.cpp` while compiling `states`, before that
  table's `AllocLinker`. What it is NOT: the callback ABI (no callback had fired yet), a Fog gap
  (our Fog exports all 39 ordinals 1.09d's D2Common imports), a broken import table in the rebuilt
  DLL (its USER32/`wsprintfA` thunk is structurally identical to 1.10f's), or a wrong entry arity
  (`DATATBLS_LoadAllTxts` is `RET 0xC` on both, matching the `(0, 1, 0)` d2host passes). The most
  likely remaining cause is the archives: these are 1.14d-era compiled tables, and 1.09d is reading
  them with its own record layout.

  (`version.zig`'s `spec(.v109d)` originally left `.stack_args` as an empty literal rather than
  wiring in the measured `callbacks.v109d` — a real bug the runtime dispatch caught immediately:
  selecting 1.09d reported both facts as still missing. Fixed; the two measurements are now
  actually reachable through `spec()`.)

  Still uncounted for 1.09d: every other callback slot's stack-arg count, and whether the worker
  loop / task re-arm / `ARENAFLAG_ClientUpdate` requirement behave the same (probably yes — same
  engine family — but "probably" is exactly what this file exists to replace with "measured").
- **1.06b: the callback ABI is measured, the Fog rosetta is not.** `callbacks.v106b` is complete —
  swept from table global 0x6fd74aa4 — and it is the widest dispatch set of any build: 1.06b is the
  only one that calls `fpSaveDatabaseGuild` (0x1C, one stack arg, @0x6fd383b1) and the unnamed 0x24,
  both of which the LoD builds never reach. Several arities are narrower than LoD's, and
  `fpLeaveGame` is **12** here against 13 on both LoD builds — which is where this file's old, wrong
  1.10f value came from. It is not runnable: `hostapi.clientFields` has no 1.06b row, and the Fog
  rosetta gap below still blocks it, so the readiness gate refuses it.
- **1.00: not yet started.** Same investigation, classic Fog family. The Fog rosetta gap
  documented below (31 unmapped classic-era ordinals) blocks these before the callback ABI would
  even matter.
- **1.08: not yet started**, no binaries confirmed on hand.
- **Fill the classic Fog rosetta column — 31 ordinals** — and build the import rewriter, so one
  Fog serves 1.00-1.06b as well as 1.07+. Nothing before 1.07 runs until this exists.
- **Own D2CMP (8 functions), Storm (10) and D2Lang (4, plus the string-table init).** Drops the
  last modules we do not control and takes their Fog imports with them, leaving D2Game and
  D2Common as the only Blizzard code loaded.
- **Implement `FOG @10207`** (txt → record decode, needs the `D2BinFieldStrc` column
  descriptors) or reverse the 1.10f record layouts, then generate `runessrv.bin` and
  `cubeserver.bin`. Until then runewords and cube recipes are empty — non-fatal, and the only
  known data gap.
- **`fpSaveDatabaseGuild` (0x1C) and the unnamed 0x24 have no dispatch site** on either version
  swept. They are recorded as `no_site_found` and the host leaves them **null**, which replaced the
  guessed arity `d2host` used to carry for 0x1C. Null is the safe answer to an unfound site and a
  guessed `ret n` is not: every dispatch the sweep did find tests the slot before calling it, so a
  slot we wrongly believe is unused costs a skipped feature, while a wrong stack cleanup costs a
  corrupted engine stack that nothing checks.


## Every callback arity, counted

The stack-arg count for a slot is what the host's shim pops on return, so a wrong one unbalances the
engine's stack. These used to come from the decompiler's rendered prototypes. Four of the twelve
were wrong, in the direction that corrupts:

|slot|name|1.09d|1.10f|was recorded|
|-|-|-|-|-|
|0x00|fpCloseGame|0|2|2|
|0x04|fpLeaveGame|13|13|**12**|
|0x08|fpGetDatabaseCharacter|2|2|2|
|0x0C|fpSaveDatabaseCharacter|4|4|4|
|0x14|fpEnterGame|2|2|**3**|
|0x18|fpFindPlayerToken|3|5|5|
|0x1C|fpSaveDatabaseGuild|no site|no site|guessed 1|
|0x20|fpUnlockDatabaseCharacter|no site|1|1|
|0x24|(unnamed)|no site|no site|guessed 0|
|0x28|fpUpdateCharacterLadder|0|0|**5**|
|0x2C|fpUpdateGameInformation|0|0|**2**|
|0x30|fpHandlePacket|0|0|0|
|0x34|fpSetGameData|0|0|0|
|0x38|fpRelockDatabaseCharacter|1|1|1|

0x10 (cdecl varargs) and 0x3C (stdcall, one arg) are not counted — their conventions are fixed and
the host writes them out directly.

The method, which matters because the first two attempts at it both under-reported:

1. Walk every reference to the version's callback-table global (`DAT_6fd45830` on 1.10f,
   `DAT_6fd24174` on 1.09d), follow the register that receives it, and count raw `PUSH`es back to
   the dispatch's own basic block. Most references are not dispatches at all — 28 of 1.10f's 41 are
   `if (server)` guards.
2. Follow `LEA reg,[table+n]` and `ADD reg,n`. Without this the higher slots are invisible:
   `GAME_TriggerClientSave` reaches 0x28 as `CALL [EBP]` after `ADD EBP,0x28`, and a naive read
   scores it as slot 0x00 with a contradictory count.
3. Cross-check with the decompiler on every function holding a reference. This is what recovers
   0x30, whose dispatch sits in a switch case far enough from the load that a linear walk has lost
   the register.

Three traps worth naming, because each produced a plausible wrong number:

- **Prologue pushes are not arguments.** `CLIENTS_SetGameData` opens with `PUSH ESI` and closes with
  `POP ESI`; counting it makes 0x34 look like a one-argument call.
- **Preceding calls consume their own pushes.** `GAME_UpdateAllClients` pushes four arguments for an
  intermediate call before pushing 0x14's two; the boundary is the previous `CALL`.
- **Finding no site is not proof of no site.** The first sweep concluded 1.10f never dispatches
  `fpHandlePacket` — and a live `d2host` run logs the stub firing. That is why the recorded state is
  `no_site_found` and the host answers it with a null pointer rather than a guessed `ret n`.


## The game-data table is an object, not a buffer

`GAME_InitGameDataTable`'s first argument is not opaque storage. D2Game reaches into it by fixed
offset *and calls virtual methods on it*, so the host implements an interface rather than allocating
space. This is a second host seam alongside the callback table, and nothing documents it — it was
recovered by running into each field in turn.

From 1.10f's `GAME_CreateNewEmptyGame` (@0x6fc35e70) and its helper (@0x6fc3b590):

|offset|what the engine does with it|
|-|-|
|+0x00|**vtable pointer.** `eax = [esi]; call *[eax+4]` — the engine invokes the second virtual method|
|+0x10|a counter it decrements in threes, floored at zero|
|+0x1c|pointer to an array of 12-byte slots, indexed `edx*12`|
|+0x24|**a power-of-two mask**, not a capacity: `edx = [+0x24] & counter`. Range-checked against 0x3FF|
|+0x44|passed by address to the helper|
|+0x48|incremented per creation; on wraparound to 0 it sets +0x4C to 1|
|+0x4C|flag paired with +0x48|
|+0x50|`CRITICAL_SECTION`, entered at 0x6fc35f59 and left at 0x6fc35fb2 — **D2Game never initialises it**|

Blizzard's host confirms every one of these. In 1.00's `D2Server.dll` the two structures are statics
0x70 apart (`0x10029688` and `0x100296F8`), registered as C++ statics with a constructor at
`0x1000A240` that sets the vtable to `0x1001F004`, `[+0x10] = 0`, `[+0x24] = 3` and points `[+0x1c]`
at four 12-byte slots — a mask of 3 for 4 slots, which is what makes `+0x24` a mask rather than a
count.

The vtable has **four methods** (the fifth entry is null):

```
0x1001F004:  +0x00 0x100010FA   +0x04 0x100012DF  <- the one CreateNewEmptyGame calls
             +0x08 0x100012A3   +0x0C 0x10001244
```

`apps/d2host` builds the struct fields and initialises the lock, which took game creation from a
deadlock on zeroed memory to a null vtable call. Implementing the four methods is what is left; the
signature of the second is `__thiscall (this, slot*, arg, arg) -> int`, whose result is added to
`[+0x04]` when non-zero.


## Bring-up log, part two: a game exists

Continuing the numbering above.

10. **Our own D2Net cleared the abort.** 14 stdcall entries, arities read off the real binary's
    `RET n`. The engine took to it immediately — `D2NET_10019` is called during
    `GAME_InitServerModule`.
11. **The game-data table needed building, and then implementing.** Two failures in a row, both
    from handing D2Game a zeroed buffer: it deadlocked on the uninitialised `CRITICAL_SECTION` at
    `+0x50`, then segfaulted on the null slot array at `+0x1c`. With the fields built it reached
    the virtual call, and with the four methods implemented it went straight through.
12. **`GAME_CreateNewEmptyGame` returns 1.** The engine allocates a record through our
    `alloc_record`, links it into the list at `+0x08`, calls `pfSetGameData` — the first callback
    of ours it has ever used — and reports one live game.
13. **The network pump drains on -1, not 0.** `D2Game @10003` (@0x6fc38530) is three loops of
    `eax = ReadFromMessageList(buf, 0x200); if (eax == -1) break`. The return is a **client id**, so
    0 is a real one: our stubs returning 0 made the engine process a phantom zero-length message
    forever, which presented as a hang in the pump rather than a wrong value. With -1 the loops
    drain and the frame completes.

State: seven modules loaded, three of them ours (Fog, D2Net, and the game-data table object),
2,636 files served from the archives, one game created, five frames ticked, zero asserts.

14. **A real client reaches the engine, and the engine answers.** `SERVER_Initialize` opens the
    listener; accept and recv are polled from inside the read path rather than a thread, since the
    host already ticks and keeping every socket touch on one thread means none of it needs locking.
    A message is handed over as `[clientId:u32][payload]` on list 2, whose processor is the one
    that consults the callback table.

    **It does not bind 4000.** That is d2ingress's — the port the client hardcodes — and it splices
    game traffic through to whatever port a GS advertises in its store record, which realmd copies
    into the per-game route. Binding it here would collide with the ingress and stop a fleet
    sharing a host. The default is 4100 and the override is `D2GS_GS_ADDR`, matching `apps/d2gs`.
    Note the difference in cost: the injected 1.14d server has to rewrite a hardcoded `push 0xfa0`
    inside the engine to move off 4000 (`apps/d2gs/runtime/gsport.zig`); owning D2Net makes it a
    variable.

    Connecting with a plain TCP socket and sending five bytes:

    ```
    d2net: client 0 connected
    d2net: client 0 -> 5 bytes
    d2host: engine called pfHandlePacket
    d2net: -> client 0, 357 bytes (kind 2)
    ```

    The whole loop closes: our Fog feeds the archives, our D2Net delivers the packet, D2Game parses
    it, calls our callback table, and replies through our `SERVER_Send`. Zero asserts, zero crashes.

The send signature came from the engine's own call site rather than a guess: `push nLen; push pBuf;
push clientId; push 2` at 0x6fc381a2 makes it `SERVER_Send(kind, clientId, pData, nLen)`, and the
`@10016` called immediately after a rejection send is the disconnect.

15. **The stream is framed into packets.** A TCP read is not a packet and D2Game will not tolerate
    being handed one. The real D2Net framed before the engine ever saw the bytes:
    `SERVER_ValidateClientPacket` @0x6FC01FE0 calls `SERVER_GetClientPacketSize` @0x6FC01E60, which
    indexes a table at **0x6FC08418** by the leading opcode and rejects anything at or above 0x70
    (except 0xFF) or longer than 0x204. That table is now in `packages/d2net`, read out of 1.10f's
    own binary. Verified both ways: three packets sent in a single write arrive as three, and a
    packet split across two writes is reassembled.

### A 1.14d client cannot join a 1.10f server

Worth stating plainly, because the opposite is a reasonable guess. Against 1.14d's equivalent table
(libd2 `net.cs.OUTGOING_SIZE`, dumped from `NET_D2GS_CLIENT_OUTGOING_SIZE @0x00730dc0`), **102 of
112 entries are identical** — every gameplay opcode 0x00-0x63 matches byte for byte.

All ten differences fall in 0x64-0x6F, the join and handshake range:

|opcode|1.10f|1.14d|
|-|-|-|
|0x64|9|0|
|0x65|17|0|
|0x66|46|-1|
|0x67|29|46|
|**0x68**|**1**|**37**|
|0x6b|-1|1|
|0x6c|9|-1|
|0x6d|1|13|
|0x6e|0|1|
|0x6f|1|0|

`0x68` is the client's first packet. A 1.14d client sends 37 bytes; a 1.10f server frames 1 and
treats the remaining 36 as the start of the next packet, so the stream desynchronises before
anything else happens. The gameplay vocabulary is shared; the handshake is not. Testing needs a
1.10f-era client, or our own clientless one taught this table.

16. **It is a member of the fleet.** With `D2GS_REDIS_ADDR` and `D2GS_GSID` set it publishes
    itself into the shared store and takes work from the realm queue, exactly as `apps/d2gs` does
    and over the same protocol — because it is now literally the same code. The GS side of that
    store had already been re-implemented once (`apps/d2gs-native/store.zig`), so it moved out to
    `packages/gs-store` rather than being written a third time.

    Verified against the dev redis. The heartbeat record decodes as it should —
    `7f 00 00 01 | 0e 10 | 07 00 00 00 | 00 00 00 00 | 00` is 127.0.0.1, port 4110, 7 games max,
    0 live, not full — and a CREATEGAME pushed onto `realmd:gsq:<gsid>` comes back on
    `realmd:gsreply:<seq>` as `10 00 | 20 00 | 63 00 00 00 | 00 00 00 00 | 01 00 00 00`: seq 99,
    CREATE_OK, game id 1. The realm asked for a game and the 1.10f engine made one.

    Without a store address it stays the standalone spike that creates one game and ticks, which is
    still the quickest way to prove a build.

What this does *not* do yet: load a character. The callbacks are still reporting stubs rather than
realm calls, and the 1.14d implementations in `apps/d2gs/engine/realm.zig` cannot be reused as they
stand — they read the client struct at 1.14d offsets (`ECX-0x5B` for the name, `ECX-8` for the
container), so the equivalent 1.10f offsets have to be established first.


## The host-facing D2Game API, mapped

Blizzard's own `D2Server.dll` imports exactly **26 D2Game ordinals**, which bounds what a host may
call. A third-party 1.13c server publishes a `D2GSINTERFACE` of named function pointers for the same
job, and its signatures give the arity of each — so the two together identify most of the set
without reading a single function body.

|D2GSINTERFACE|args|1.10f ordinal|how it was pinned|
|-|-|-|-|
|`D2GSNewEmptyGame`|8|**@10047**|`GAME_CreateNewEmptyGame`, and `RET 0x20`|
|`D2GSSendDatabaseCharacter`|8|**@10007**|`RET 0x20` and it calls `CLIENTS_AttachSaveFile`|
|`D2GSEndAllGames`|0|**@10006**|`GAME_CloseAllGames`|
|`D2GSSendClientChatMessage`|5|**@10018**|the only 5-argument host ordinal|
|`D2GSSetTickCount` / `D2GSSetACData` / `D2GSLoadConfig`|1|@10016 / @10020 / @10023|not yet separated; all 1-arg|
|`D2GSStart`|1|—|takes their own `D2GSINFO`, so it is wrapper code, not an ordinal|

Their `EVENTCALLBACKTABLE` is a third independent derivation of the engine→host table and agrees
with ours on all sixteen slots. Two disagreements of naming rather than layout are worth recording:
they call slot 0x24 `fpReserved1` and slot 0x30 `fpReserved2`, but we have *observed* the engine
call 0x30 — it is `pfHandlePacket`. And they declare `void* fpReservedDebug[10]` after the sixteen,
which means the tail `Extended` models was already there in the DLL era rather than being a 1.14d
invention; 1.14d's `fpGetDatabaseFileTime` at 0x54 lands inside it.

## The character load

`fpGetDatabaseCharacter` is asynchronous — the call site at 0x6fc37413 discards the return value —
so the answer goes back through `@10007`:

```
BOOL __stdcall D2GSSendDatabaseCharacter(
    DWORD dwClientId, LPVOID lpSaveData, DWORD dwSize, DWORD dwTotalSize,
    BOOL bLock, DWORD dwReserved1, LPPLAYERINFO lpPlayerInfo, DWORD dwReserved2);
```

The client-struct offsets are 1.14d's, and that is measured rather than assumed: 1.10f does
`leal 0x68(%esi), %ecx` immediately before `calll *0x8(%eax)`, and writes the two name fields as a
consecutive pair into `+0x0D` and `+0x1D` at 0x6fc32685. Same layout, so the pointer arithmetic in
`apps/d2gs/engine/realm.zig` ports over unchanged.

`apps/d2host` implements it: fetch the save from `packages/gs-store` — the same
`realmd:char:<account>:<char>` key the 1.14d server already uses — queue it, and deliver from the
tick loop rather than inside the join call, because delivering synchronously runs the engine's join
continuation halfway through its own join. A zero-length fetch is delivered as a refusal
(`bLock` nonzero) rather than dropped, so a client is told rather than left on a loading screen.


## A character joins a game on the 1.10f engine

The whole closed-realm path, with `apps/d2host` as the only game server on the realm:

```
d2host: JOINGAME cached t110f/Tenf for the character fetch
d2net: client 0 packet 0x67 (29 bytes)
d2host: fpFindPlayerToken - /Tenf gameid=1 token=0x1
d2net: client 0 joined game 0x1
engine[6]: [CLIENT]  ClientAddToGame:  Added client 0 'Tenf' to game 1 'live4'
engine[6]: [SERVER]  sSrvSendGameInit: Sent game init to client 0 'Tenf' for game 1 'live4'
engine[6]: [SERVER]  SrvJoinGame:      client 0 'Tenf' joined game 1 'live4'
d2host: fpGetDatabaseCharacter - save bytes 0x14f
engine[7]: [LOAD]    CKSUM:5ADBB0FD len:335  Tenf
engine[6]: [SERVER]  SrvRecvDatabaseCharacter: Sent ACTINITDONE for client 0 'Tenf'
```

realmd created the game, the client joined it, the engine loaded the character out of the shared
store and checksummed it. Five things had to be right, and each was wrong first:

1. **The join is opcode 0x67, 29 bytes, on message list 0.** `CCMD_ProcessClientSystemMessage`
   owns 0x66-0x6F and `GAME_VerifyJoinGame` hangs off its 0x67 case. 1.14d joins with 0x68 at 37
   bytes — the opcode shifted by one and the payload grew, which is why a 1.14d client
   desynchronises here rather than being cleanly refused. Layout:
   `u8 0x67 | u32 token | u16 gameId | u8 (<=6) | u32 | u8 class (<=0xC) | char name[16]`.
2. **The host owns the game-lookup index.** `D2GameDataTable_Ptr` @0x6fc3b6a0 reads a bucket head
   at `slots + (gameId & mask)*12 + 8` and the chain-link offset at `+0`, and `alloc_record` is
   handed that bucket — so populating it is the host's job. Leaving it empty surfaces much later
   as `SrvJoinGame: *** Failed to lock game N ***`.
3. **Tick with the ordinals Blizzard's host uses.** `D2Server.dll` imports 26 D2Game ordinals and
   @10004/@10005 are not among them. Driving those halts the engine with
   `This should never happen! [sUpdateClients]` the moment a game has a client in it. The tick is
   @10003 (network) and @10043 (games).
4. **The account comes from the realm, not the engine.** The engine leaves `pClient+0x1D` empty on
   the join path, so the save key would be `realmd:char::<char>`. The realm's JOINGAME carries the
   account; caching it there is what makes the fetch resolve.
5. **The transport remembers which game a client is in.** The engine calls
   `SERVER_SetClientGameGUID` on join and reads it back with `SERVER_GetClientGameGUID` whenever it
   needs to lock that client's game. Answering 0 fails the delivery with
   `*** Failed SrvLockGame for client N ***` — it is the engine's state, but ours to hold.

### The server talks back

```
SERVER SENT 10 BYTES:  01 00 04 00 10 00 01 00 00 02
d2net: -> client 0, 9 bytes    game init (0x01)
d2net: -> client 0, 1 bytes    ACTINITDONE (0x02)
```

Outbound is not a send call the host makes. `D2GAME_PACKETS_SendPacket` @0x6fc3c710 never touches a
socket — it **queues** into a per-client list in 0x200-byte chunks. The drain is
`@10045` → `FUN_6fc386d0` → `GAME_UpdateAllClients` @0x6fc389c0, where every `SERVER_Send` call
site lives. Three things had to be right, and each was silent in a different way:

1. **`@10045` re-arms the task, so it is not optional.** `@10043` *unlinks* the due task and hands
   it over; `@10045` does `*task += 0x28` (40 ms, one frame) and re-inserts it. Skipping it even
   once — we gated it on having a connected client — drops that game out of the scheduler for good.
   The engine simply goes quiet, with nothing logged.
2. **A game must be created with `ARENAFLAG_ClientUpdate` (0x04).** `GAME_UpdateAllClients` starts
   with `ARENA_NeedsClientUpdate`, which reads that flag back as
   `(*(u8*)(pGame[0x1d28] + 8) >> 2) & 1`, and **halts the process** when it is clear:
   `This should never happen! [sUpdateClients]`. Creating with `flags = 0` therefore kills the
   server the first time the game is processed, and the halt names nothing useful. The flag builder
   now lives in `packages/d2engine/gameflags.zig` so both servers share it.
3. **`FOG_GetSyncTime` is in frames, not milliseconds.** The reap check is
   `0x708 < GetSyncTime() - pGame[0x771]`. At 25 fps, 1800 frames is a 72-second idle timeout;
   returning `GetTickCount()` makes it 1.8 seconds and every game is deleted before anyone can
   join, reported as `Deleting game from sSrvTaskProcessGame(), I/O timeout`.

The worker loop, from `D2Server.dll` @0x10009DE0 and now implemented in `apps/d2host`:

```
esi = @10041()                              a worker slot index (0..0x1f)
loop: @10043(ecx=esi, edx=&task)            take the due task; returns ms until the next
      @10003()                              pump the network
      if (task) @10045(ecx=esi, edx=task)   update + flush + re-arm
```

`TASK_GetNextDueTask` (@10043) and `TASK_ProcessGameTask` (@10045) are named and described in the
shared Ghidra database, along with `GAME_UpdateAllClients` and its halt condition.


## The stock 1.10f client will not run here (SafeDisc)

Worth writing down, because it looks like a configuration problem for a long time and is not one.

`Game.exe` extracts `CmdLineExt03.dll` into `%TEMP%` at startup and loads it; under wine that faults
writing to its own image base. Disabling it (`WINEDLLOVERRIDES="CmdLineExt03=d"`) clears that crash
and the next one is a divide-by-zero at 0x00416277 — inside an XOR decryption loop in a section
named `.uako`. The section table settles it:

|binary|sections|
|-|-|
|1.10f `Game.exe`|`.text .rdata .data` **`.uako .mnkam`** `.idata .rsrc`|
|1.14d `Game.exe`|`.text .rdata .data .rsrc .reloc`|

1.10f is SafeDisc-wrapped and 1.14d is not, which is why the 1.14d client runs here without
ceremony. Replicating the 1.10f patch does not help: the patch is where that `Game.exe` comes from.
Driving a stock 1.10f client needs the disc or an unwrapped binary.

The consequence for testing is that the client has to be ours. That is not a downside — a scripted
client is a better test than a headed one — but it does mean the packet vocabulary cannot live
inside a Windows DLL where nothing else can reach it, which is why it moved to
`packages/d2engine/cs_packets.zig`.


## A 1.14d client plays on the 1.10f server

The stock 1.10f client cannot be driven here (SafeDisc, above) and pre-1.12 clients want the disc, so
the practical test client is the 1.14d one — which runs under wine without either. Exactly **one**
packet stands in the way, and we own the transport it arrives on:

```
1.14d  0x68, 37 bytes:  op | u32 hash | u16 token | u8 | u32 | u64 extra | u8 class | name[16]
1.10f  0x67, 29 bytes:  op | u32 hash | u16 gameId| u8 | u32 |             u8 class | name[16]
```

Same fields with an 8-byte insertion, so the translation is dropping bytes 12..20 and renumbering
the opcode. The leading fields line up exactly, which matters because d2ingress rewrites the token
at byte 5 into the engine's game id and that lands on 1.10f's `gameId` unchanged.
`packages/d2engine/cs_packets.zig` does it, `packages/d2net` applies it before framing, and
`D2HOST_ACCEPT_114D_CLIENT=0` turns it off for a genuine same-version client.

Result:

```
d2net:  translated a 1.14d join (0x68/37) into 1.10f (0x67/29)
engine: ClientAddToGame:  Added client 0 'Tenf' to game 1 'tr1'
engine: SrvRecvDatabaseCharacter: Sent ACTINITDONE for client 0 'Tenf'
[GS] joined: 3 packets, 1 world bytes after 0x6b  => IN GAME
[GS] parsed: 3/3 packets (100%)
```

That the client parses **everything** the 1.10f engine sends is the point: the 102 of 112 C->S
entries that match are not a coincidence of the table, they are the same protocol. Only the session
block 0x64-0x6F was renumbered between the versions.

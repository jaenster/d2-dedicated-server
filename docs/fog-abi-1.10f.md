# Fog.dll 1.10f — exact ABI for the ordinals D2Common needs

Source of truth: the real `Fog.dll` / `D2Common.dll` / `D2Lang.dll` from `~/code/d2-1.10f-binaries/`,
read through the live ghidra-mcp project (`Diablo2Lod/windows/1.10f/*`). D2MOO
(`~/code/CPP/D2MOO`) was used as a cross-check only; where the two disagree the binary wins and the
disagreement is called out below.

Preferred image bases: Fog `0x6FF50000`, D2Common `0x6FD40000`, D2Lang `0x6FC10000`.
Ordinal → RVA comes from each DLL's own export table (ordinal base 10000, all NONAME).

## Reading the conventions

Every entry below was decided from the epilogue and the prologue, not from a header:

- `RET n` + first read is `[ESP+4]` → **stdcall**, `n/4` args.
- `RET n` + args arrive in `ECX`/`EDX` → **fastcall**, 2 register args + `n/4` stack args.
- plain `RET` + args in `ECX`/`EDX` → **fastcall** with no stack args (this is *not* cdecl).
- plain `RET` + caller does `ADD ESP,k` → **cdecl**.

## The table

| Ord | Name | RVA | Conv | Args | Returns |
|-|-|-|-|-|-|
| 10023 | FOG_DisplayAssert | 0xED30 | cdecl | 3: `szMsg`, `szFile`, `nLine` | void (returns; caller then calls `exit(-1)`) |
| 10029 | FOG_Trace | 0x120A0 | cdecl varargs | 1+: `szFormat`, ... | void |
| 10030 | FOG_TraceF | 0x120E0 | cdecl varargs | 2+: `szFileSubName`, `szFormat`, ... | void |
| 10042 | FOG_Alloc | 0x8F50 | fastcall | 4: ECX=`nSize`, EDX=`szFile`, +0=`nLine`, +4=`n0` | `void*` (NULL on failure) |
| 10043 | FOG_Free | 0x8F90 | fastcall | 4: ECX=`pMem`, EDX=`szFile`, +0=`nLine`, +4=`n0` | `BOOL` (always 1) |
| 10045 | FOG_AllocPool | 0x8FF0 | fastcall | 5: ECX=`pMemPool`, EDX=`nSize`, +0=`szFile`, +4=`nLine`, +8=`n0` | `void*` |
| 10050 | FOG_EnterCriticalSection | 0xDC20 | fastcall | 2: ECX=`pCriticalSection`, EDX=`nLine` (unused) | void |
| 10102 | FOG_FOpenFile | 0x11600 | fastcall | 2: ECX=`szFileName`, EDX=`HSFILE* phFile` | `BOOL` |
| 10103 | FOG_FCloseFile | 0x11610 | fastcall | 1: ECX=`hFile` | `BOOL` |
| 10104 | FOG_FReadFile | 0x11620 | fastcall | 7: ECX=`hFile`, EDX=`pBuffer`, +0=`nBytesToRead`, +4=`pBytesRead`, +8/+C/+10 = 0,0,0 | `BOOL` |
| 10105 | FOG_FGetFileSize | 0x11650 | fastcall | 2: ECX=`hFile`, EDX=`pdwFileSizeHigh` | `DWORD` low size (0 == fatal) |
| 10115 | FOG_GetSavePath | 0x11900 | fastcall | 2: ECX=`pBuffer`, EDX=`nBufferSize` | `BOOL` from CreatePathHierarchy |
| 10208 | FOG_CreateBinFile | 0xA8B0 | stdcall | 2: `pDataBuffer`, `nBufferSize` | `D2BinFileStrc*` (NULL if no rows) |
| 10209 | FOG_FreeBinFile | 0xAA10 | stdcall | 1: `pBinFile` | void |
| 10210 | FOG_GetRecordCountFromBinFile | 0xAA50 | stdcall | 1: `pBinFile` | `int` = `pBinFile->nRowCount` |
| 10211 | FOG_AllocLinker | 0xB720 | stdcall | 2: `szFile`, `nLine` | `D2TxtLinkStrc*` (16 B, zeroed) |
| 10212 | FOG_FreeLinker | 0xB750 | stdcall | 1: `pLinker` | void |
| 10213 | FOG_GetLinkIndex | 0xB810 | stdcall | 3: `pLinker`, `dwCode`, `bLogError` | `int` index, or `-1` |
| 10214 | FOG_GetStringFromLinkIndex | 0xB8F0 | stdcall | 3: `pLinker`, `nIndex`, `szOut` (>= 5 bytes) | `BOOL` found |
| 10215 | FOG_AddCodeToLinkingTable | 0xB990 | stdcall | 2: `pLinker`, `dwCode` | `int` index assigned |
| 10216 | FOG_AddRecordToLinkingTable | 0xBD80 | stdcall | 2: `pLinker`, `szString` | void |
| 10217 | FOG_GetRowFromTxt | 0xBC20 | stdcall | 3: `pLinker`, `szText`, `bLogError` | `int` index, or `-1` |

Absolute addresses = `0x6FF50000 + RVA`.

## Per-function notes

### 10102 FOG_FOpenFile — `BOOL __fastcall (const char* szFileName /*ECX*/, HSFILE* phFile /*EDX*/)`

Body is a two-instruction thunk: `PUSH EDX; PUSH ECX; CALL <Storm ordinal 267 (SFileOpenFile)>; RET`.
No stack args at all, hence the plain `RET`. Storm gets `(szFileName, phFile)` in that order and
returns its `BOOL` in EAX, which Fog passes straight through.

Contract our replacement must honour:

- return **non-zero** on success and store an opaque, non-NULL handle in `*phFile`;
- return **0** on failure *and* set `SetLastError(ERROR_FILE_NOT_FOUND /*2*/)` when the file is
  merely absent — D2Common's `ARCHIVE_OpenFile` calls `GetLastError()` and suppresses the
  `"Error opening file: %s"` trace only for error 2 when its `bQuiet` flag is set;
- the handle is only ever handed back to 10105, 10104 and 10103.

Our current stub is `callconv(.winapi) (name, out_handle, flags)` — wrong convention *and* wrong
arity. Under stdcall the engine's `ECX`/`EDX` arguments are never read and the stub's `RET 0xC` eats
12 bytes of D2Common's frame.

### 10103 FOG_FCloseFile — `BOOL __fastcall (HSFILE hFile /*ECX*/)`

`PUSH ECX; CALL <Storm 253 (SFileCloseFile)>; RET`.

### 10104 FOG_FReadFile — `BOOL __fastcall (HSFILE /*ECX*/, void* pBuffer /*EDX*/, size_t nBytesToRead, size_t* pBytesRead, 0, 0, 0)`

`RET 0x14` → 5 stack args on top of ECX/EDX. The body re-pushes them for
`<Storm 289 (SFileReadFile)>` and **swaps the last two** (`Storm(p1,p2,p3,p4,p5,p7,p6)`), which is
harmless while D2Common passes `0,0,0`. `D2Common!ARCHIVE_ReadFileToBuffer` asserts
`nBytesToRead == *pBytesRead` afterwards, so a short read is fatal.

### 10105 FOG_FGetFileSize — `DWORD __fastcall (HSFILE /*ECX*/, DWORD* pdwFileSizeHigh /*EDX*/)`

Thunk to `<Storm 265 (SFileGetFileSize)>`. **Must not return 0**: `ARCHIVE_GetFileSize`
(`D2Common+0x84152`) treats 0 as fatal — it calls `SFileGetFileName`, then
`FOG_DisplayError(3, szPath, szFile, nLine)` (cdecl, 4 args) and `exit(-1)`.

### 10115 FOG_GetSavePath — `BOOL __fastcall (char* pBuffer /*ECX*/, size_t nBufferSize /*EDX*/)`

Reads `HKCU\...\Diablo II\Save Path`, falls back to `Install Path`, falls back to the exe directory
(`GetModuleFileNameA` + truncate at the last `\`), appends `Save\`, writes the result back to the
registry, guarantees a trailing backslash, then tail-calls `FOG_CreatePathHierarchy` (`0x11730`) —
whose return value becomes ours.

**Disagrees with D2MOO**, which declares the return as `size_t`. It is the `BOOL` from
`CreatePathHierarchy`. Every known caller ignores it, so this is cosmetic.

### 10042 / 10043 / 10045 — memory

`FOG_Alloc` is `RET 8`: `ECX=nSize`, `EDX=szFile`, then `nLine`, then an always-zero 4th dword.
On failure it logs through the shared error sink `(2, szFile, nLine, msg)` and returns NULL.
`FOG_Free` is the same shape with `ECX=pMem`, and always returns 1.
`FOG_AllocPool` is `RET 0xC`: `ECX=pMemPool` (D2Common always passes 0 = default pool),
`EDX=nSize`, then `szFile`, `nLine`, `0`.

Verified from the live call sites, e.g. `D2Common+0x842AF`
(`LEA ECX,[ESI+0x320]` = filesize+800, `EDX=szFile`, `PUSH nLine`, `PUSH 0`).

Neither Alloc nor AllocPool zeroes memory — D2Common `memset`s afterwards where it cares. Our stub
passing `HEAP_ZERO_MEMORY` is harmless but not faithful.

### 10050 FOG_EnterCriticalSection — `void __fastcall (CRITICAL_SECTION* /*ECX*/, int nLine /*EDX*/)`

`PUSH ESI; MOV ESI,ECX; CALL <deadlock bookkeeping>; PUSH ESI; CALL [EnterCriticalSection]; POP ESI; RET`.
Plain `RET` because there are no stack args. `nLine` in EDX is not read here.
**It does not initialise the section** — the real Fog relies on the owner having called
`InitializeCriticalSection`. Our stub's lazy-init is a deliberate divergence, and a good one.

### 10023 FOG_DisplayAssert — `void __cdecl (const char* szMsg, const char* szFile, int nLine)`

Reads `[ESP+4]`, `[ESP+8]`, `[ESP+0xC]`, forwards to the error sink as `(5, szFile, nLine, szMsg)`
with `ADD ESP,0x10`, then tail-jumps. Confirmed from both sides: `FOG_Trace` itself calls it with
3 pushes + `ADD ESP,0xC`, and `D2Common+0xFE36` does `PUSH nLine; PUSH szFile; PUSH "pbData"; CALL`.

**Our stub is `callconv(.winapi)` — that is a stack-corrupting bug.** Same for 10024/10025 and for
`FOG_Trace`/`FOG_TraceF`, all of which are cdecl in the binary and stdcall in `fog.zig`.

Note it *returns* to its caller; the caller then executes `exit(-1)` on its own. A non-fatal assert
stub therefore cannot keep the engine alive past an assert — it only changes what gets logged.

### 10029 / 10030 — tracing

`FOG_Trace(const char* szFormat, ...)` — asserts `szFormat != NULL` (`DataTbls`-style assert with
`__LINE__ 0x118`), varargs start at `[ESP+8]`.
`FOG_TraceF(const char* szFileSubName, const char* szFormat, ...)` — asserts `szFormat` (arg 2, at
`[ESP+8]`), varargs start at `[ESP+0xC]`; a NULL `szFileSubName` selects the default log.
Both cdecl. Matches D2MOO.

### 10208–10210 — the .txt "bin file" tokeniser

`FOG_CreateBinFile(void* pData, int nSize)` allocates a **16-byte** header via
`FOG_AllocPool(0, 0x10, ...)` and then destructively tokenises `pData` in place: every `\t` and
`\r` becomes `\0`, `\r` must be followed by `\n` (`assert "*data == SYM_EOL"`), the first line is
the column header (its tab count lands in `+0x0C`), and every subsequent line increments the row
count in `+0x08`. Lines whose first cell is `"Expansion"` are removed by memmove and do not count.
Column count is capped at `0x118` (`assert file->nCellCount < EXCELMAXCELLS`).

Header layout:

| Off | Meaning |
|-|-|
| +0x00 | `char* pData` (start of the buffer) |
| +0x04 | `char* pFirstRow` (after the header line) |
| +0x08 | `int nRowCount` |
| +0x0C | `int nColumnCount` |

Returns NULL if the buffer held only a header line (it frees both the caller's buffer *and* its own
header in that case — note it calls `FOG_Free` on `pData`, so `pData` must have come from
`FOG_Alloc`).

`FOG_GetRecordCountFromBinFile` is literally `MOV EAX,[arg+8]; RET 4`.
`FOG_FreeBinFile` does `FOG_Free(pBin->pData, ...)` then `FOG_FreePool(0, pBin, ...)`.

### 10211–10217 — the linker (`D2TxtLinkStrc`)

`FOG_AllocLinker(szFile, nLine)` returns a zeroed 16-byte struct from `FOG_AllocPool(0, 0x10, szFile, nLine, 0)`:

| Off | Blizzard's name (from the assert strings) | Meaning |
|-|-|-|
| +0x00 | `nSize` | number of entries |
| +0x04 | — | capacity of the code table (grows by 0x40) |
| +0x08 | `pTbl` | `struct { u32 dwCode; i32 nIndex; }[]`, sorted by `dwCode` |
| +0x0C | `pStrTbl` | root of a 0x2C-byte-node string BST |

A linker is **either** a code table **or** a string tree, never both — 10215 asserts `!pStrTbl` and
10216 asserts `!pTbl`.

String node (0x2C bytes): `char szKey[0x20]` (copied with `SStrCopy(...,0x20)` then case-folded),
`i32 nIndex` at +0x20, `left` at +0x24, `right` at +0x28.

- **10213 `FOG_GetLinkIndex(pLinker, dwCode, bLogError)`** — binary search of `pTbl` for `dwCode`;
  returns the stored index, or `-1`. Traces a warning if the table is empty, and (when `bLogError`
  and `dwCode > 0x202020A0`, i.e. it looks like a real 4-char code) traces a not-found message.
  **The index is the return value; there is no out-parameter.** Our stub's `out_idx` is wrong.
- **10214 `FOG_GetStringFromLinkIndex(pLinker, nIndex, szOut)`** — linear scan of `pTbl` for an
  entry whose index equals `nIndex`; unpacks the 4 code bytes into `szOut`, mapping `' '` to `'\0'`,
  and always writes `szOut[4] = '\0'`. **`szOut` must be at least 5 bytes.** Returns 1/0.
  Our stub returning a `[*:0]const u8` is wrong: this writes into a caller buffer.
- **10215 `FOG_AddCodeToLinkingTable(pLinker, dwCode)`** — asserts `pLinker` (`assert "hIndex"`) and
  `!pStrTbl`. Grows `pTbl` by 0x40 entries via `FOG_ReallocPool` when full (zeroing the new tail),
  binary-searches for the insertion point, memmoves the tail up, stores `{dwCode, nSize}`,
  increments `nSize`, and returns the assigned index. On a duplicate code it traces and retries with
  `dwCode+1`, so codes are always unique.
- **10216 `FOG_AddRecordToLinkingTable(pLinker, szString)`** — asserts `pLinker` and `!pTbl`.
  Allocates a 0x2C node from `FOG_AllocPool`, `SStrCopy(node, szString, 0x20)`, case-folds it,
  sets `node->nIndex = nSize`, inserts into the BST by `strcmp`. On an exact duplicate it traces,
  frees the node, and still increments `nSize`. Returns nothing meaningful.
  **Disagrees with D2MOO**, which types the return as `int`; the binary leaves EAX undefined.
- **10217 `FOG_GetRowFromTxt(pLinker, szText, bLogError)`** — copies `szText` into a 0x20 stack key,
  case-folds it, walks the BST, returns `node->nIndex` or `-1`. Asserts
  `"!ptIndex->nSize || pNode"` when the tree is empty but `nSize != 0`. When `bLogError` and
  `szText` is neither empty nor `"*"`, traces a not-found message.

D2MOO names the whole 10211–10217 group `__stdcall`; the binary agrees for all seven (each starts by
reading `[ESP+4]` and ends in `RET 4/8/0xC`). D2MOO's `FOG_10215` prototype `(void* pBin, int a2)`
is right in shape but the second argument is a packed 4-char code, not an arbitrary int.

## What `DATATBLS_LoadAllTxts` (D2Common #10576, `0x6FD504B0`) actually expects

`#10576` is only a driver: it takes one argument (in `ECX` for all the sub-loaders) and calls ~35
per-table loaders back to back. The file work happens one level down, in
`DATATBLS_CompileTxt` (`D2Common+0xFD70`, `#10578`), which is where the reported assert lives.

The chain, verified instruction by instruction:

```
DATATBLS_CompileTxt
  -> ARCHIVE_AllocateBufferAndReadFile   D2Common+0x84268   __fastcall
       ECX = hArchive, EDX = szFilePath, stack: pdwBytesWritten, szSrcFile, nLine
     -> ARCHIVE_OpenFile                 D2Common+0x840F0
          -> FOG #10102  ECX = szFilePath, EDX = &hFile          (local at [EBP-4])
          on 0: GetLastError(); unless (bQuiet && err == 2) FOG_Trace("Error opening file: %s", path)
          returns 0  ==>  ARCHIVE_AllocateBufferAndReadFile returns NULL
     -> ARCHIVE_GetFileSize              D2Common+0x84152
          -> FOG #10105  ECX = hFile, EDX = &dwSizeHigh          (local at [EBP-8])
          0 is fatal (FOG_DisplayError(3,...) + exit(-1))
     -> FOG #10042  ECX = dwFileSize + 800, EDX = szSrcFile, push nLine, push 0
     -> ARCHIVE_ReadFileToBuffer         D2Common+0x841C1
          -> FOG #10104  ECX = hFile, EDX = pBuffer, push 0,0,0, push &nRead, push dwFileSize
          asserts dwFileSize == nRead
     -> ARCHIVE_CloseFile -> FOG #10103
     -> *pdwBytesWritten = dwFileSize
     returns pBuffer
```

`pbData` **is that returned buffer.** The assert at `D2Common+0xFE36` is

```
PUSH 0x88E                  ; nLine 2190
PUSH <"...\D2Common\DATATBLS\DataTbls.cpp">
PUSH <"pbData">
CALL FOG_DisplayAssert      ; cdecl
```

so it fires purely because `ARCHIVE_AllocateBufferAndReadFile` returned NULL, which in our build
happens because `FOG_FOpenFile` returns 0. (D2MOO calls the same variable `pData`; the real 1.10f
source calls it `pbData` — the binary's string wins.)

Immediately after the assert, on the success path, the buffer is consumed as:

```
PUSH dwDataSize ; PUSH pbData ; CALL FOG #10208   -> pBinFile
PUSH pBinFile   ;               CALL FOG #10210   -> nRecordCount
ESI = nRecordCount * dwRecordSize
PUSH 0 ; PUSH 0x895 ; PUSH szFile ; EDX = ESI ; ECX = 0 ; CALL FOG #10045
```

So the minimum viable `FOG_FOpenFile` is:

1. resolve `szFileName` (paths look like `DATA\GLOBAL\EXCEL\<name>.txt`) against our MPQ/loose-file
   layer, case-insensitively, with `\` separators;
2. on success hand back a non-NULL handle *and* return non-zero;
3. make `FOG_FGetFileSize` return the real byte count (never 0) and `FOG_FReadFile` deliver exactly
   that many bytes with `*pBytesRead` set to the same value;
4. on a genuine miss, `SetLastError(2)` and return 0 — the engine will trace and then assert, which
   is the correct, diagnosable failure.

The buffer D2Common allocates is `size + 800` and `FOG_CreateBinFile` rewrites it in place, so the
data must be the raw `.txt` bytes with CRLF line endings — `FOG_CreateBinFile` asserts on a bare
`\r` not followed by `\n`.

## D2Lang 1.10f: which ordinal is the initialiser

**Answer: `D2Lang #10000` at `0x6FC12F90` — the same ordinal as in 1.00. An init call *is* required
before any string lookup.**

The premise that 1.10f ordinal 10000 is a `Unicode::` method is wrong. Parsing D2Lang.dll's export
directory (ordinal base 10000, 63 functions, 49 named):

- ordinals **10000–10013 are NONAME** — the C `D2LANG_*` API;
- ordinals **10014+ carry decorated C++ names** (`??0Unicode@@QAE@G@Z`, `?compare@Unicode@@…`).

D2MOO's `D2Lang.1.10f.def` lists them in exactly that split, so D2MOO and the binary agree here; the
confusion comes from reading the *name* table (sorted alphabetically) rather than the *ordinal*
table.

`#10000` is `STRTABLE_Initialize`:

```
int __fastcall D2LANG_Initialize(HD2ARCHIVE hArchive /*ECX, unused in 1.10f*/,
                                 const char* szLanguage /*EDX, may be NULL*/,
                                 BOOL bExpansion /*[ESP+4]*/);
```

`RET 4` → fastcall with exactly one stack argument. What it does:

- reference-counts (`+[0x6FC20CD8]`) and returns 1 immediately if already initialised;
- if `szLanguage` is NULL it auto-detects via `#10006`;
- maps the language to a charset (`LATIN` / `LATIN2` / …) and loads
  `data\local\font\%s\default.map` through `Unicode::loadSysMap`;
- loads `data\local\lng\%s\string.tbl` — **returns 0 if this fails**, the only non-asserting failure;
- loads `data\local\lng\%s\patchstring.tbl` (asserts `sghPatchStringTable != NULL`);
- if `bExpansion` is non-zero, loads `data\local\lng\%s\expansionstring.tbl`
  (asserts `sghExpansionStringTable != NULL`);
- allocates the per-table Unicode string arrays with `FOG #10042`;
- caches four single-character strings (indices `0x14D0`–`0x14D3`) with `Unicode::unicode2Win`,
  falling back to `'K' 'M' 'B' 'T'`;
- returns 1.

`#10001` at `0x6FC13BE0` is the matching `STRTABLE_Shutdown` (decrements the refcount, frees
everything with `FOG #10043`, calls `Unicode::unloadSysMap`).

The archive handle global (`0x6FC20CDC`) is **read four times and never written** in 1.10f — it
stays NULL and every load goes through the default archive chain. Nothing needs to be published to
D2Lang before the call; pass `NULL` for `ECX`.

Practical consequence for the fault the host saw: calling `#10000` with the wrong convention (or as a
`Unicode::` thiscall method) puts garbage in `EDX`, which is dereferenced as `szLanguage` in the very
first `strcpy` loop. Called correctly, it needs the `.tbl` files reachable through Fog's file layer,
and it needs `FOG_DisplayAssert` (`#10023`) to be reachable, because a missing `patchstring.tbl` goes
through the assert path and then dereferences NULL if the assert is made non-fatal.

D2Common's data-table load does **not** depend on D2Lang; `#10000` is only required before
`D2LANG_GetStringFromTblIndex` (`#10004`) / `D2LANG_GetStringByReferenceString` (`#10003`).

## Where the real binary contradicted D2MOO

1. **`FOG_GetSavePath` (#10115) returns a `BOOL`**, not a `size_t` — it tail-calls
   `FOG_CreatePathHierarchy`. D2MOO declares `size_t`.
2. **`FOG_10216_AddRecordToLinkingTable` returns nothing.** D2MOO types it `int`; the binary leaves
   `EAX` holding whatever the last helper wrote.
3. **`FOG_10215`'s second argument is a packed 4-character code (`uint32_t`)**, not a generic `int` —
   the duplicate-collision path compares it against `0x202020A0` and increments it, which only makes
   sense for a `' '`-padded code.

Everything else that D2MOO declares for this set — conventions, arities, and all 22 RVAs — matches
the 1.10f binary exactly.

## Gap list against `packages/d2fog/fog.zig` (current stubs)

| Ordinal | Stub as written | Reality |
|-|-|-|
| 10102 | stdcall, 3 args | fastcall, 2 args (ECX/EDX) |
| 10103 | stdcall, 1 stack arg | fastcall, ECX |
| 10104 | stdcall, 4 args | fastcall, 2 reg + 5 stack |
| 10105 | stdcall, 2 args | fastcall, ECX/EDX |
| 10115 | stdcall, returns pointer | fastcall, returns BOOL |
| 10042/43/45 | stdcall | fastcall, and 10045 takes the pool in ECX |
| 10023/24/25/26 | stdcall | cdecl |
| 10029/10030 | stdcall / partial | cdecl varargs |
| 10050 | stdcall, 2 args | fastcall ECX/EDX |
| 10211 | **0 args** | stdcall, 2 args → `RET 8` mismatch corrupts the caller's frame |
| 10213 | out-parameter | index is the return value |
| 10214 | returns a pointer | writes 5 bytes into the caller's `szOut`, returns BOOL |
| 10215 | 2 u32 args, stdcall | correct shape; second arg is a packed code |
| 10216 | 3 args | 2 args |
| 10217 | 2 args | 3 args → `RET 8` vs `RET 0xC` |

The stdcall-vs-fastcall and the arity mismatches are not cosmetic: with `RET n` doing the cleanup,
every wrong `n` desynchronises D2Common's stack at the call site.

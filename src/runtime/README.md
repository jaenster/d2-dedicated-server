# src/runtime — in-process machinery

Everything `d2gs.dll` needs to live inside `Game.exe`: byte-patching, the
`__fastcall` shim generator, headless survival, crash/assert diagnostics, the
fiber game-loop driver, and join-debugging hooks. None of this calls the realm —
it's the low-level plumbing the engine bindings and test harnesses sit on.

## Core plumbing

- `patch.zig` — `VirtualProtect` byte-patch util: `writeJump`/`writeCall`/`writeNops`/
  `writeBytes`, saves originals for `revertAll()`. The base for every hook here.
- `fastcall.zig` — comptime generator turning the engine's `__fastcall` ABI (ECX,
  EDX + N stack args, callee cleanup) into a plain Zig `callconv(.c)` handler via a
  `callconv(.naked)` shim. Avoids Zig's buggy x86 fastcall (ziglang/zig#10363).
- `headless.zig` — survival byte-patches: stub renderers/media loaders, hide the
  window, guard DC6 nulls — so the host runs with no display.

## Client enablement (for driving a real client)

- `checkrev_patch.zig` — bypass the bnet version check (`--bypass-checkrev`).
- `multiinstance.zig` — patch `FindWindowA` so the GS + a client (or two clients)
  run at once ("only one copy" check defeated; d2bs's `Multi`).
- `gamecrashfix.zig` — d2bs's D2CMP null-deref guard (avoids a crash UI).

## Diagnostics

- `crash.zig` — vectored exception handler: logs the faulting address + register
  context + `[esp]` return address (maps call-to-null faults back to the caller).
- `halt_hook.zig` — hooks `ERROR_UnrecoverableInternalError_Halt` to log the
  asserting caller + line; `--suppress-halts` swallows asserts instead of exiting.
- `joindiag.zig` — hooks the join path to log refusal reasons (0xB4) + SrvJoinAct
  entry (engine `SRVLog` is a no-op in retail, so we hook directly).
- `pkttrace.zig` — traces every `:4000` client↔GS packet id, inbound (3 dispatch
  call-site hooks) + outbound (a `SendPacket_Helper` entry trampoline). Gated by
  `--pkttrace` (verbose).

## Game-loop driving (test harnesses)

- `async.zig` — fiber tasks that yield across engine frames.
- `gameloop.zig` — hooks the in-game / out-of-game loop sleeps into a per-frame
  callback, so a harness can step the client deterministically.

All addresses are absolute against image base `0x00400000` (no ASLR), rebased off
the live module base defensively.

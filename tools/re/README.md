# Measurement scripts

Static analysis over the real DLLs, in Python + capstone. These are not part of any build — they
answer questions whose answers become *data* elsewhere in the tree (`packages/d2engine/callbacks.zig`,
`fogabi.zig`, `fogrosetta.zig`, `cs_packets.zig`). They live here because the answers are only as
trustworthy as the method that produced them, and every one of these encodes a method that took
more than one attempt to get right.

    pip3 install capstone

| script | question it answers |
|-|-|
| `cbsweep.py` | Which server-callback slots does a `D2Game.dll` dispatch, and with how many stack args? Also prints the `lea ecx,[reg+N]` at slot 0x08, which is where pRealm sits in the client struct. |
| `argcount.py` | The same count done properly, by **simulating the stack** and resolving what each intermediate call pops. |
| `fogsweep.py` | What arity does each module call each **Fog** ordinal with? Fog is stdcall, so a replacement must pop exactly this. |
| `arity_check.py` | Cross-check a classic→LoD Fog mapping: what the caller pushes must equal what the callee's `ret N` pops. |
| `rosetta.py` | Fingerprint each classic Fog export against the LoD ones — referenced strings, Storm ordinals called, mnemonics. |
| `rosetta3.py` | Solve the whole classic→LoD map under three constraints at once: fingerprint, monotonic order, and matching arity. |
| `mpqprobe.py` | Ask an MPQ whether it holds a member. Names are hashed, not stored, so an archive can only be interrogated — never listed. |

## Two traps these exist to avoid

**The push count is not the arity.** Counting pushes back to the previous `CALL` assumes that call
consumed everything before it. It does not — an intermediate stdcall pops only its own arguments and
the rest still belong to the pending call. That silently undercounted three callback slots on every
version. `argcount.py` resolves each intermediate call's `ret N`, through its import thunk into the
owning DLL where necessary.

**Finding no site is not proof of no site.** A sweep that follows the table register linearly loses
it across a switch, and `fpHandlePacket` was recorded as "never dispatched" on a version that
demonstrably calls it. Where a sweep comes back empty, say so as *no site found* and have the host
answer it with a null pointer — never with a guessed `ret N`.

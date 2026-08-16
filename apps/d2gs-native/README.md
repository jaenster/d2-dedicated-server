# d2gs-native

Runs Diablo II 1.14d's macOS i386 Mach-O binary as a headless game server, directly on i386 Linux.

Same game, different host ABI. The image is mapped as it ships: segments copied in, every pointer
slid, every import bound to a host function or to a thunk that names itself when the game calls it.
No wine, no emulation, no format conversion — a 4.4 MB image and one process instead of a wine
process tree, which is what makes a game server cheap enough to run many of.

## Dry run

Parses, maps, resolves every import and protects the image, prints the report, and stops before the
entry point. This works on any host, including macOS arm64, so the load path can be checked without
an i386 box — with one gap the report names: fixup slots are 32 bits, so on a host that maps the
image above 4 GiB the binds and rebases cannot be written and are skipped.

    zig build d2gs-native
    ./zig-out/bin/d2gs-native /path/to/DiabloII --dry-run
    D2MAC_BIN=/path/to/DiabloII ./zig-out/bin/d2gs-native --dry-run

Without `--dry-run` it jumps to the image entry point, and refuses to do so unless the host is
i386 Linux.

## Joining a realm

The server takes no flags beyond the image path — everything else is environment, so a container
needs no command line. Without `D2GS_REALM` it boots and serves, but registers with nobody and
says so.

| variable | meaning |
|-|-|
| `D2MAC_BIN` | path to the `DiabloII` Mach-O, if not given as the argument |
| `D2GS_REALM` | `host:port` of realmd's gs-link. Unset = no realm |
| `D2GS_GS_ADDR` | the `host:port` this server advertises to clients, default `127.0.0.1:4000` |
| `D2GS_D2DBS` | `host:port` of the character store. Defaults to the realm host, one port below gs-link |
| `D2GS_GSID` | fleet id. Defaults to FNV-1a over hostname **and** advertised port, so two servers on one host do not collide |
| `D2GS_MAX_GAMES` | concurrent games, 1..7, default 1 |
| `D2GS_CHAR_SOURCE` | `memory` (default) or `file` |

The realm link is the same protocol the wine server speaks, so a fleet can mix both kinds. On a
join the character is fetched over the network from d2dbs — no shared disk.

**It always binds :4000.** Unlike the wine server, which moves its listener to whatever
`D2GS_GS_ADDR` advertises, the port is an immediate inside `QSERVER_CreateAndInit` and nothing
patches it. `D2GS_GS_ADDR` changes only what clients are *told*, so map the port instead
(`-p 14000:4000`). A mismatch fails misleadingly: the connection is accepted and then closes
without a byte, while every log in between says the game was created and the join acked.

## Concurrency

`D2GS_MAX_GAMES` raises the cap to at most seven, the same engine ceiling wine has. It defaults
to 1 because with it raised roughly half of a round's games are admitted and the rest refused —
cleanly, and the games that run are correct, but the shortfall is not yet explained.

The engine's own scheduler services one game (`QSERVER_TickAllGames` reads only `gpGameTable[1]`),
but `ServerGameLoop` is passed the game it advances, so the host keeps its own list and runs that
body per game. Each game also needs a *forced* `QSERVER_DispatchAndCleanup`, which honours its
40 ms budget only when both arguments are zero — otherwise the first game spends the budget and
the rest never flush.

## Not implemented

- Graphics and sound. A server never reaches AGL or the audio units, and those imports stay thunks.
- The argv/environ/stack handoff. LC_UNIXTHREAD expects a process stack laid out the way the kernel
  lays one out; the entry point currently starts on this thread's stack as it is.

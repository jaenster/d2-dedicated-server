# d2gs-native

Runs Diablo II 1.14d's macOS i386 Mach-O binary as a headless game server, directly on i386 Linux.

Same game, different host ABI. The image is mapped as it ships: segments copied in, every pointer
slid, every import bound to a host function or to a thunk that names itself when the game calls it.
No wine, no emulation, no format conversion — a ~6 MB image and one process instead of a wine
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

## Not implemented

- Graphics and sound. A server never reaches AGL or the audio units, and those imports stay thunks.
- The argv/environ/stack handoff. LC_UNIXTHREAD expects a process stack laid out the way the kernel
  lays one out; the entry point currently starts on this thread's stack as it is.

# A realm with extensions

A complete realm built out of the `realmd` package plus its own code. It declares **every** hook
the realm offers, doing the smallest real thing each one is for. Copy this directory, delete the
hooks you do not want, and what is left still compiles.

The full surface is documented in [`../../docs/realm-extensions.md`](../../docs/realm-extensions.md).

- `main.zig` — the whole difference between the stock `realmd` binary and yours: it names your
  extensions and calls `realmd.run`.
- `ext/example.zig` — the extension itself.

## Building it here

`zig build realm-example`. Upstream builds it as part of `zig build test`, because the stock realmd
compiles the hook fan-out away (empty registry) — without something that declares every hook, a
changed signature would break nobody's build here and everybody's downstream.

## Building it as your own realm

Depend on this repo and take the `realmd` module:

```zig
// build.zig
const d2gs = b.dependency("d2gs", .{ .target = target, .optimize = optimize });

const realmd = b.addExecutable(.{
    .name = "realmd",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }),
});
realmd.root_module.addImport("realmd", d2gs.module("realmd"));
b.installArtifact(realmd);
```

One `addImport` is enough — the package carries its own dependencies.

## Running it

The realm's own configuration is unchanged. This extension adds three options of its own, in its
namespace:

| variable | meaning |
|-|-|
| `REALMD_EXT_EXAMPLE_SEASON` | season number, persisted on first boot (default 1) |
| `REALMD_EXT_EXAMPLE_GREETING` | what `/season` says after the number |
| `REALMD_EXT_EXAMPLE_API_PORT` | port for its own HTTP listener; unset means it binds nothing |

```
REALMD_EXT_EXAMPLE_SEASON=7 REALMD_EXT_EXAMPLE_API_PORT=7788 ./zig-out/bin/realm-example
curl http://127.0.0.1:7788/     # {"season":"7"}
```

Give the port a different value per instance, or leave it unset on all but one — a fixed port makes
the second instance fail to bind, and a listener that will not bind is fatal on purpose.

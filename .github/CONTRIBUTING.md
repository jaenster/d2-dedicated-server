# Contributing

This is a clean-room reimplementation of a server the game already talks to, so the rules here are
mostly about *evidence*: what a claim has to be backed by before it lands.

## The one rule

**Never invent a number.** Offsets, opcodes, packet sizes, ordinals, table values — every one of
them is measurable, from the game's own binaries or its `.txt` tables. If a value came from a wiki,
another project, or an inference, say so in the comment next to it, and say what would confirm it.
[`VERIFY.md`](../VERIFY.md) is where that ledger lives.

A wrong guess here does not fail loudly. The engine accepts the packet, dispatches it to whatever
that opcode means on that build, and goes quiet — which reads as a timeout somewhere else entirely.
Several of the longest hunts in this repo's history were exactly that.

## Building

```
zig build                     # everything
zig build test                # unit tests: wire codecs, save integrity, the seeded generators
zig build e2e                 # 34 clientless scenarios against a real realmd (needs Docker)
zig build stress-e2e          # rounds of real games against a real game server
```

Zig `0.16.0` — the same version CI pins. The realm and ingress build for native Linux; the game
server's runtime builds for `x86-windows` because it is loaded by the game's own process.

For the pre-1.14 engines, `tools/e2e-engines.sh` runs every one of them end to end against
[`deploy/e2e-engines.txt`](../deploy/e2e-engines.txt). It needs the realm up (`./run-stack.sh`) and
a game tree per engine. **Do not edit sources while it runs** — it rebuilds `d2fog`/`d2net`/`d2host`
per engine, and a mid-run edit produces an empty log on whichever engine was building.

## Pull requests

- One subject per PR. A protocol fix and a refactor in the same diff cannot be reverted separately.
- Comment `/e2e` on the PR to run the seven-engine gate; it adds the `run-e2e` label, which is what
  actually triggers the run on your head commit.
- Say how you tested it. "Builds" is not testing — this repo's failure mode is a server that starts
  fine and serves nothing.
- If you change something an engine depends on, run the engine gate. A fix for one version quietly
  breaking another is the single most common regression here.

## Commit messages

Subject line is `area: what is now true`, in prose, no trailing period:

```
d2fog: the BitStream grew a field at 1.10, so Initialize writes four or five
d2host: resolve D2Game by name, not by being last in the list
```

The body is for *why*, and especially for what the symptom looked like before it was understood —
those notes are the reason a version-specific bug does not have to be re-derived a second time. No
tool or assistant attribution in commits.

## Scope

No Blizzard game files in the repository, ever. See [`LEGAL.md`](../LEGAL.md). This targets Linux
containers; Windows compatibility is explicitly not a goal (see the README).

# Extending the realm

A realm built from this repo can add its own code and **override the realm's own decisions**
without editing anything here. You depend on the `realmd` package, write a root file that names
your modules, and build your own binary. The stock binary carries none of your code; yours carries
all of it.

A complete, working realm is in [`examples/realm-extension/`](../examples/realm-extension/) — it
declares every hook there is. Copy it and delete what you do not want.

## The shape

An extension is a plain module that declares a `pub fn` named after a hook. No base type, no
vtable, no registration call. A comptime `inline for` over the registry calls `ext.<hook>(...)`
only where `@hasDecl` finds it, so:

- a hook you do not declare costs nothing at runtime and nothing in the binary;
- a hook whose **signature** is wrong is a compile error — you find out at build time, not from a
  realm that quietly stopped calling you;
- a hook whose **name** is misspelled is silently never called. This is the one mistake the
  arrangement cannot catch. Copy the names from the example.

```zig
// your main.zig — the whole difference between the stock realmd and yours
const std = @import("std");
const realmd = @import("realmd");

pub const realm_extensions = .{
    @import("ext/ladder.zig"),
    @import("ext/seasons.zig"),
};

pub fn main(init: std.process.Init.Minimal) !void {
    return realmd.run(init);
}
```

```zig
// your build.zig
const d2gs = b.dependency("d2gs", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("realmd", d2gs.module("realmd"));
```

Order matters for the hooks that stop at the first answer: the extension listed first decides, and
the rest are not asked.

## The three kinds of hook

Which kind a hook is tells you what you are allowed to do with it.

| kind | returns | meaning |
|-|-|-|
| observe | `void` | it already happened; you are being told |
| veto | `?u32` / `bool` | the realm is about to ALLOW something; refuse it or stay out of the way |
| override | `?T` | the realm is about to DECIDE something; make the decision instead, or return null and let it decide as it would |

Every override has a stock answer that still runs when no extension claims it, so a realm with no
extensions behaves exactly as it does today.

## The hooks

**Startup**

- `startup(cfg) !void` — the store is up, nothing is listening yet. Read your configuration here.
  Returning an error aborts startup, which is the right answer for config you cannot run without.
- `name` (a `pub const`, not a function) — names you in the startup log, and is the namespace your
  storage and configuration live under.

**Who gets in**

- `authenticate(req: hook.AuthRequest) ?hook.Auth` — OVERRIDE the password check. Null means "not
  mine" and the realm's own check runs, so you can own only the accounts you know about. This is
  the hook for an existing account database, a launcher token, SSO, or a ban list. `.accept` also
  creates an account the realm has never seen — you are the authority saying the player is real.
- `accountCreate(account) bool` — VETO an account before it exists. Also asked on the permissive
  auto-registration path, so a permissive realm is not a hole straight past you.
- `accountLogin(account, ok) void` — OBSERVE a finished logon.

**Characters**

- `charCreate(account, charname, class) ?u32` — VETO; return an MCP result code to refuse.
- `charVersion(account, charname, client_version) ?[]const u8` — OVERRIDE which engine a new
  character belongs to. See [Engine versions](#engine-versions).
- `charCompatible(account, charname, char_version, client_version) ?bool` — OVERRIDE whether a
  character may be played by the client asking for it.
- `charLogon(account, charname) void` — OBSERVE.
- `charSave(account, charname, bytes) void` — OBSERVE the `.d2s` on its way to the store. Read it;
  do not keep the slice.

**Games**

- `gameCreate(account, charname, gamename, difficulty) ?u32` — VETO.
- `gameJoin(account, charname, gamename) ?u32` — VETO.
- `gameVisible(account, gamename, gameid) ?bool` — OVERRIDE what the join list shows this player.
  Hiding is cosmetic: a player who knows the name can still try to join, and `gameJoin` is where
  that is actually refused.
- `pickGs(req: hook.GsPick) ?u32` — OVERRIDE which game server hosts a game, given the live fleet
  snapshot. This is the decision that turns one fleet into several: hardcore on its own machines, a
  region kept local, a guild pinned. Your choice is reserved atomically and can still lose the
  race; if it does, the realm falls back to its own pick rather than failing the create.

  `req.servers` is already narrowed to the servers that run `req.version`, so a pick made from it
  cannot land a character on an engine that cannot host it. Each `GsInfo` also carries the server's
  own labels — `s.version()` and `s.label("region")` — for finer routing. A realm that wants the
  unnarrowed fleet can take it from `realmd.fleet.snapshot` and owns what follows.

**Chat**

- `chatCommand(c, tag, text) bool` — ADD a `/command`. Runs after the realm's own, so you cannot
  shadow one by accident. Return true once you have answered it.
- `chatSay(c, account, channel, text) bool` — VETO a line of channel talk: mutes, flood control,
  word filters.

**Raw protocol**

- `bncsPacket(c, id, body) bool` / `mcpPacket(c, id, body) bool` — every packet before the realm's
  own dispatch. Return false to consume it. The escape hatch for protocol work this repo does not
  model.

**Listeners of your own**

- `listeners() []const hook.Listener` — ADD ports the realm binds at startup, alongside its own.
  This is how a realm grows a login path the D2 client never had: a launcher endpoint, a REST hook
  a website calls, a metrics surface. A `handler` is a `net.Handler`, exactly what `bncs.zig` and
  `health.zig` write.

  Collected **after** `startup`, so read your port from configuration rather than hardcoding one —
  a fixed port makes the second instance of your realm fail to bind. A bind that fails is fatal,
  as the realm's own listeners are: a realm that comes up healthy with half of itself missing is
  worse than one that refuses to start.

## Logging in

`realmd.auth` is the whole login surface: what the client sent, and every primitive the realm
decides with. The `authenticate` hook is the decision; this is what you decide with.

```zig
pub const Request = struct {
    account: []const u8,
    client_token: u32, server_token: u32,   // the nonces the hash is salted with
    hash: [20]u8,                           // what the client sent
    client_version: []const u8 = "",        // the engine it is running, empty if unknown
    exe_version: u32 = 0, verbyte: u8 = 0,  // what it actually said it was
    ip: [4]u8 = .{0,0,0,0},
};

realmd.auth.passwordHash(plaintext) [20]u8   // seed your own table with something verify accepts
realmd.auth.verify(stored_hash, req) bool    // does this request prove that password?
realmd.auth.verifyStored(req) ?bool          // the same against the realm's own table; null = no such account
realmd.auth.issueTicket(account, ttl_s, &buf) ?[]const u8
realmd.auth.redeemTicket(req) bool
```

There are two ways to own logins and most realms want both.

**Own the passwords.** Keep accounts wherever you already keep them and answer `authenticate` with
`verify(your_hash, req)`. The client's half of the exchange is a double hash over two
per-connection nonces, so a stored hash on its own is never enough to log in with — which is also
why you cannot do this check by hand without reimplementing Blizzard's broken SHA-1.

**Skip the password.** Something outside the game already knows who the player is — a launcher, a
website, a Discord bot. It calls `issueTicket` and hands the result to the client *as its
password*; `authenticate` answers with `redeemTicket(req)`. Tickets are single-use and expire, and
are consumed even on a wrong guess, so the issuer stays the authority instead of becoming a
password vendor. Pair it with a `listeners()` endpoint and the whole login flow lives outside D2.

Returning `.accept` for an account the realm has never seen also creates it: you saying yes *is*
the authority that the player is real. Returning null leaves the login to the realm, so you can own
only the accounts you know about.

## Engine versions

A realm hosting more than one game version has a problem a single-version realm does not: a 1.09d
client cannot play a 1.13c character or join a 1.13c game. The save format and the wire framing
both moved between them, so handing the wrong one over does not fail cleanly — the client either
refuses the load or writes the character back wrong.

So the realm tracks it, in one vocabulary shared with the fleet: the tag is the same string a game
server publishes as its `v=` label (`1.09d`, `1.13c`, `1.14d`).

| moment | what happens |
|-|-|
| a client logs in | the realm resolves its engine from what it reported, and carries it on the session |
| a character is created | it is stamped with that engine, once, and never restamped — `charVersion` overrides |
| a character is loaded | a genuine mismatch is refused; `charCompatible` overrides |
| a game is created | it is routed to a server publishing that `v=` label |

Unknown is never a mismatch. A character made before the realm recorded versions has none, a client
the realm has no mapping for has none, and either one means "no constraint" — so this changes
nothing at all on a realm running one engine.

**The client map is configuration.** Blizzard's per-patch EXE version numbers are not derivable
from anything in this repo, and a table of half-remembered build numbers would silently send
players to the wrong engine, so only the 1.14d entry ships. Fill the rest in with:

```
REALMD_CLIENT_VERSIONS=1.13.0.60=1.13c,1.0.10.39=1.10f,vb:10=1.09d
```

Keys are a version quad, a raw dword (`0x01000e3f`), or a version byte (`vb:10`). An unmapped
client is logged once with the exact line that would name it, so filling the map is copy-paste
rather than research.

## Talking back to a player

A hook handed a `*bncs.Conn` may use exactly four things on it. Everything else on that struct is
the realm's own business.

- `c.account_name()` / `c.channel_name()` — who and where.
- `c.tell(text)` — an info line in this client's chat window.
- `c.warn(text)` — the same, rendered as an error, for refusals.

## Storage

Extensions get their own namespace, keyed by your `name`. Nothing the realm stores can collide
with it, no other extension can reach it, and **no upstream schema change can break it** — which
is the compatibility promise that makes upgrading safe for a realm carrying extensions.

```zig
const db = realmd.store.ext("ladder");

db.put("season", "7");              // durable — Postgres, the store of record
db.get("season", &buf);
db.del("season");
db.keys("season:", &out);           // durable keys with a prefix, into your array

db.cachePut("hot", bytes, 60);      // in flight — Redis, shared across instances
db.cacheGet("hot", &buf);
db.cacheDel("hot");
db.incr("kills", 1, 3600);          // shared counter; the TTL arms only on creation
```

Durable is where a ladder's standings belong. The cache is for what you are willing to lose on a
restart — rate limits, a computed leaderboard, per-session scratch.

### Per-character metadata

Characters carry a free-form JSON document of their own, next to the save. Use it for anything that
belongs to *that character* rather than to your extension as a whole — a ladder's per-character
totals, a season stamp, an unlock.

```zig
realmd.store.setCharMetaKey(account, charname, "season", "7");
realmd.store.charMetaKey(account, charname, "season", &buf);
realmd.store.mergeCharMeta(account, charname, "{\"kills\":12,\"unlocked\":true}");
realmd.store.charMeta(account, charname, &buf);   // the whole document
```

The writers **merge**, they do not replace, and that is not a convenience: the document is shared
by every extension on the realm, so a write that replaced it would delete the others' work. The
realm itself writes nothing into it.

The character's engine is deliberately *not* in there — it is its own column, because the realm
routes and gates on it and it must not be something an extension can overwrite by accident.

The split is the same one the realm itself uses and means the same thing. Do not lean on the cache
for anything that must survive.

## Configuration

Your options come from `REALMD_EXT_<NAME>_<KEY>`, upper-cased with `-` folded to `_`. You name them;
this repo never learns they exist.

```zig
pub fn startup(cfg: anytype) !void {
    const c = cfg.ext("my-ladder");
    season   = c.int(u32, "season", 1);          // REALMD_EXT_MY_LADDER_SEASON
    greeting = c.getOr("greeting", "Welcome.");  // REALMD_EXT_MY_LADDER_GREETING
    if (c.flag("strict")) { ... }                // set means on; =0/false/no means off
}
```

## Keeping up with upstream

Pin a tag. Hook signatures are checked at compile time, so an upgrade that changed one fails your
build with the exact call site rather than leaving a hook silently uncalled.

Upstream builds `examples/realm-extension` as part of `zig build test` for this reason: the stock
binary compiles the hook fan-out away (its registry is empty), so without something that actually
declares every hook, a signature change would break nobody's build here and everybody's downstream.

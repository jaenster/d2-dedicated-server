//! stress-e2e — rounds of real games against a real game server, in Zig rather than bash and a
//! subprocess fleet.
//!
//! Drives real games through a real GS: each round spawns `--clients` threads that each log into
//! the realm once and play `--runs` games back to back (create, join, wait for the world, dwell,
//! leave), exactly like `clientless`'s own `--runs` lifecycle test. `d2-realm`/`d2-session` are
//! `clientless`'s public modules — the same BNCS/MCP/GS-session code the `clientless` binary
//! itself runs on, reused directly rather than re-implemented or subprocess-spawned.
//!
//! Concurrent clients in a round each get their OWN game
//! rather than racing into one shared name — that race hits a known, still-open GS reap-timing
//! bug (a brand-new empty game can be reaped before a racing JOINGAME lands), which belongs to
//! that bug's own fix, not to every regression this gate is meant to catch.
//!
//! Exit code: 0 if every round reached every client's world, 1 otherwise (see tools/e2e's
//! matching contract, wired the same way into `zig build stress-e2e`).
//!
//! Test characters are created on demand (Realm.createCharacter) rather than shipped as fixture
//! .d2s saves: nothing to seed, nothing to keep in sync with the engine's save format, and no
//! dependency on tools/realmd-test (pre-clientless, gitignored, not something a CI checkout has).

const std = @import("std");
const realm = @import("d2-realm");
const session = @import("d2-session");

extern "c" fn usleep(usec: c_uint) c_int;

const MAX_CLIENTS = 16;

const Config = struct {
    host: []const u8 = "127.0.0.1",
    bnet_port: u16 = 6112,
    gs_port: u16 = 4000,
    rounds: u32 = 20,
    clients: u32 = 2,
    runs: u32 = 1,
    dwell_ms: i64 = 3000,
    same_game: bool = false,
    keep_going: bool = false,
    account: []const u8 = "tester:tester",
    /// "name:class" pairs (class = eD2PlayerClassID: 0 Amazon, 1 Sorceress, 2 Necromancer,
    /// 3 Paladin, 4 Barbarian, 5 Druid, 6 Assassin). Created on demand if the account doesn't
    /// have them yet — see Realm.createCharacter below.
    chars: []const u8 = "EpicSorc:1,EpicAma:0",
    /// How long to retry a full login+create+join+world probe before giving up and starting the
    /// real rounds regardless. realmd's image is `scratch` (no shell, so no Docker HEALTHCHECK)
    /// and a GS can take a moment to publish itself into redis after it starts — this absorbs both
    /// without the caller needing its own wait loop. 0 skips the probe entirely.
    wait_ms: i64 = 20000,
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("stress-e2e: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseArgs(init_args: anytype) !Config {
    var cfg = Config{};
    var args = std.process.Args.Iterator.init(init_args);
    _ = args.next(); // argv[0]
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--host")) cfg.host = args.next() orelse fatal("--host needs a value", .{})
        else if (std.mem.eql(u8, a, "--bnet-port")) cfg.bnet_port = std.fmt.parseInt(u16, args.next() orelse fatal("--bnet-port needs a value", .{}), 10) catch fatal("bad --bnet-port", .{})
        else if (std.mem.eql(u8, a, "--gs-port")) cfg.gs_port = std.fmt.parseInt(u16, args.next() orelse fatal("--gs-port needs a value", .{}), 10) catch fatal("bad --gs-port", .{})
        else if (std.mem.eql(u8, a, "--rounds")) cfg.rounds = std.fmt.parseInt(u32, args.next() orelse fatal("--rounds needs a value", .{}), 10) catch fatal("bad --rounds", .{})
        else if (std.mem.eql(u8, a, "--clients")) cfg.clients = std.fmt.parseInt(u32, args.next() orelse fatal("--clients needs a value", .{}), 10) catch fatal("bad --clients", .{})
        else if (std.mem.eql(u8, a, "--runs")) cfg.runs = std.fmt.parseInt(u32, args.next() orelse fatal("--runs needs a value", .{}), 10) catch fatal("bad --runs", .{})
        else if (std.mem.eql(u8, a, "--dwell")) cfg.dwell_ms = (std.fmt.parseInt(i64, args.next() orelse fatal("--dwell needs a value", .{}), 10) catch fatal("bad --dwell", .{})) * 1000
        else if (std.mem.eql(u8, a, "--same-game")) cfg.same_game = true
        else if (std.mem.eql(u8, a, "--keep-going")) cfg.keep_going = true
        else if (std.mem.eql(u8, a, "--account")) cfg.account = args.next() orelse fatal("--account needs a value", .{})
        else if (std.mem.eql(u8, a, "--chars")) cfg.chars = args.next() orelse fatal("--chars needs a value", .{})
        else if (std.mem.eql(u8, a, "--wait-ms")) cfg.wait_ms = std.fmt.parseInt(i64, args.next() orelse fatal("--wait-ms needs a value", .{}), 10) catch fatal("bad --wait-ms", .{})
        else fatal("unknown flag {s}", .{a});
    }
    if (cfg.clients > MAX_CLIENTS) fatal("--clients {d} exceeds the max of {d}", .{ cfg.clients, MAX_CLIENTS });
    return cfg;
}

const ClientOutcome = struct {
    entered: u32 = 0,
};

const Char = struct {
    name: []const u8,
    class: u8,
};

fn splitAccount(account: []const u8) struct { user: []const u8, pass: []const u8 } {
    const i = std.mem.indexOfScalar(u8, account, ':') orelse fatal("--account must be user:pass, got \"{s}\"", .{account});
    return .{ .user = account[0..i], .pass = account[i + 1 ..] };
}

fn parseChar(entry: []const u8) Char {
    const i = std.mem.indexOfScalar(u8, entry, ':') orelse return .{ .name = entry, .class = 1 };
    const class = std.fmt.parseInt(u8, entry[i + 1 ..], 10) catch fatal("bad class in --chars entry \"{s}\"", .{entry});
    return .{ .name = entry[0..i], .class = class };
}

/// The account's own character if it has one by this name already; otherwise creates it. Every
/// concurrent client of a fresh account races this on round 1 — MCP_CHARCREATE on an existing
/// name just fails and falls through to chooseCharacter, so it's harmless, not just idempotent.
fn chooseOrCreate(r: *realm.Realm, who: Char) !realm.Character {
    return r.chooseCharacter(who.name) catch r.createCharacter(who.name, who.class, true);
}

fn runClient(gpa: std.mem.Allocator, cfg: *const Config, game_stem: []const u8, who_cfg: Char, out: *ClientOutcome) void {
    const char_name = who_cfg.name;
    const acct = splitAccount(cfg.account);

    var r = realm.Realm.connect(gpa, .{ .host = cfg.host, .port = cfg.bnet_port, .log = false }) catch |e| {
        std.debug.print("  [{s}] realm connect failed: {s}\n", .{ char_name, @errorName(e) });
        return;
    };
    defer r.deinit();

    r.login(acct.user, acct.pass) catch |e| {
        std.debug.print("  [{s}] login failed: {s}\n", .{ char_name, @errorName(e) });
        return;
    };
    r.enterRealm(null) catch |e| {
        std.debug.print("  [{s}] enterRealm failed: {s}\n", .{ char_name, @errorName(e) });
        return;
    };
    const who = chooseOrCreate(&r, who_cfg) catch |e| {
        std.debug.print("  [{s}] chooseCharacter/createCharacter failed: {s}\n", .{ char_name, @errorName(e) });
        return;
    };

    var run: u32 = 1;
    while (run <= cfg.runs) : (run += 1) {
        // Same stem+run naming as clientless's own playRuns(), so concurrent clients sharing a
        // stem land on the identical name for a given run and race into the same game.
        var namebuf: [16]u8 = undefined;
        const name = if (cfg.runs == 1)
            game_stem[0..@min(game_stem.len, namebuf.len - 1)]
        else
            std.fmt.bufPrint(&namebuf, "{s}{d}", .{ game_stem[0..@min(game_stem.len, namebuf.len - 4)], run }) catch game_stem;

        const made = r.createGame(.{ .name = name }) catch |e| {
            std.debug.print("  [{s}] run {d}/{d} \"{s}\" CREATEGAME failed: {s}\n", .{ char_name, run, cfg.runs, name, @errorName(e) });
            continue;
        };
        const ticket = r.joinGame(name, "") catch |e| {
            std.debug.print("  [{s}] run {d}/{d} \"{s}\" JOINGAME failed: {s} (create said {s})\n", .{ char_name, run, cfg.runs, name, @errorName(e), made.describe() });
            continue;
        };

        var s = session.Session.open(gpa, .{
            .host = ticket.gsHost(),
            .port = cfg.gs_port,
            .game_id = ticket.token,
            .game_hash = ticket.hash,
            .character = who.name(),
            .char_class = who.class,
        }) catch |e| {
            std.debug.print("  [{s}] run {d}/{d} \"{s}\" GS connect failed: {s}\n", .{ char_name, run, cfg.runs, name, @errorName(e) });
            continue;
        };
        defer s.deinit();

        s.waitUntilInGame(15000) catch |e| {
            if (s.refused) |said| {
                std.debug.print("  [{s}] run {d}/{d} \"{s}\" token={d} REFUSED: {s}\n", .{ char_name, run, cfg.runs, name, ticket.token, said.describe() });
            } else {
                std.debug.print("  [{s}] run {d}/{d} \"{s}\" token={d} NEVER ENTERED: {s}\n", .{ char_name, run, cfg.runs, name, ticket.token, @errorName(e) });
            }
            s.leave();
            continue;
        };

        // "in game" is not the test — the client can have SENT the join without the server
        // having handed it a world. A unit count of zero is an empty world.
        if (s.world.unitCount() > 0) {
            out.entered += 1;
            std.debug.print("  [{s}] run {d}/{d} \"{s}\" token={d} world: act={d} level={d} mapSeed=0x{x:0>8} units={d}\n", .{
                char_name, run, cfg.runs, name, ticket.token, s.world.act, s.world.level_id, s.world.map_seed, s.world.unitCount(),
            });
        } else {
            std.debug.print("  [{s}] run {d}/{d} \"{s}\" token={d} reached the GS but the world is empty (act={d})\n", .{
                char_name, run, cfg.runs, name, ticket.token, s.world.act,
            });
        }

        const until = session.nowMs() + cfg.dwell_ms;
        while (session.nowMs() < until) {
            const tick = s.pump(50) catch break;
            if (tick.eof) break;
        }
        s.leave();
    }
}

/// Every client shares one account, so letting each connect concurrently and race
/// MCP_CHARCREATE the first time a character doesn't exist yet is exactly the kind of race this
/// tool otherwise exists to find — just not one worth finding in realmd's account bookkeeping
/// instead of the join path. One connection, one character at a time, before any round starts.
fn ensureCharacters(gpa: std.mem.Allocator, cfg: *const Config, chars: []const Char) bool {
    const acct = splitAccount(cfg.account);
    var r = realm.Realm.connect(gpa, .{ .host = cfg.host, .port = cfg.bnet_port, .log = false }) catch return false;
    defer r.deinit();
    r.login(acct.user, acct.pass) catch return false;
    r.enterRealm(null) catch return false;
    for (chars) |c| _ = chooseOrCreate(&r, c) catch return false;
    return true;
}

/// One full login -> create -> join -> world round-trip, discarded either way. Used only to
/// tell "the stack isn't up yet" apart from "the stack is up and this is a real failure".
fn probeOnce(gpa: std.mem.Allocator, cfg: *const Config, who_cfg: Char) bool {
    const acct = splitAccount(cfg.account);
    var r = realm.Realm.connect(gpa, .{ .host = cfg.host, .port = cfg.bnet_port, .log = false }) catch return false;
    defer r.deinit();
    r.login(acct.user, acct.pass) catch return false;
    r.enterRealm(null) catch return false;
    const who = chooseOrCreate(&r, who_cfg) catch return false;
    _ = r.createGame(.{ .name = "e2eprobe" }) catch return false;
    const ticket = r.joinGame("e2eprobe", "") catch return false;

    var s = session.Session.open(gpa, .{
        .host = ticket.gsHost(),
        .port = cfg.gs_port,
        .game_id = ticket.token,
        .game_hash = ticket.hash,
        .character = who.name(),
        .char_class = who.class,
    }) catch return false;
    defer s.deinit();

    s.waitUntilInGame(5000) catch {
        s.leave();
        return false;
    };
    s.leave();
    return true;
}

/// Also where every character gets created (see ensureCharacters) — even with --wait-ms 0 this
/// still makes ONE attempt, so a plain run still avoids the concurrent-first-create race below.
fn waitForStack(gpa: std.mem.Allocator, cfg: *const Config, chars: []const Char) void {
    const single_attempt = cfg.wait_ms <= 0;
    if (!single_attempt) std.debug.print("==> waiting up to {d}ms for realmd + a registered GS\n", .{cfg.wait_ms});
    const deadline = session.nowMs() + cfg.wait_ms;
    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        if (ensureCharacters(gpa, cfg, chars) and probeOnce(gpa, cfg, chars[0])) {
            if (!single_attempt) std.debug.print("==> stack ready (probe succeeded on attempt {d})\n", .{attempt});
            return;
        }
        if (single_attempt or session.nowMs() >= deadline) {
            if (!single_attempt) std.debug.print("==> stack not confirmed ready after {d} attempts ({d}ms) — starting anyway\n", .{ attempt, cfg.wait_ms });
            return;
        }
        _ = usleep(500_000);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    const cfg = try parseArgs(init.args);

    var chars: [MAX_CLIENTS]Char = undefined;
    var nchars: usize = 0;
    var it = std.mem.splitScalar(u8, cfg.chars, ',');
    while (it.next()) |c| : (nchars += 1) {
        if (nchars >= MAX_CLIENTS) break;
        chars[nchars] = parseChar(c);
    }
    if (nchars < cfg.clients) fatal("--chars only lists {d} names for {d} clients", .{ nchars, cfg.clients });

    waitForStack(gpa, &cfg, chars[0..cfg.clients]);

    std.debug.print("==> {d} rounds x {d} client(s) x {d} run(s) per login\n", .{ cfg.rounds, cfg.clients, cfg.runs });

    var passed: u32 = 0;
    var first_fail: ?u32 = null;
    var round: u32 = 1;
    while (round <= cfg.rounds) : (round += 1) {
        var basebuf: [12]u8 = undefined;
        const base = if (cfg.same_game) "e2estress" else std.fmt.bufPrint(&basebuf, "e2e{d}", .{round}) catch "e2e";

        var threads: [MAX_CLIENTS]std.Thread = undefined;
        var outcomes: [MAX_CLIENTS]ClientOutcome = [_]ClientOutcome{.{}} ** MAX_CLIENTS;
        var stembufs: [MAX_CLIENTS][16]u8 = undefined;

        var i: u32 = 0;
        while (i < cfg.clients) : (i += 1) {
            // Each client gets its OWN game, not a shared one to race into: concurrent
            // CREATEGAME/JOINGAME on the identical name hits a known, still-open reap-timing
            // race (a brand-new empty game can be reaped before the racing JOINGAME lands) —
            // real, but not something a regression gate should flake red on for everyone else.
            const stem = std.fmt.bufPrint(&stembufs[i], "{s}c{d}", .{ base, i }) catch base;
            threads[i] = try std.Thread.spawn(.{}, runClient, .{ gpa, &cfg, stem, chars[i], &outcomes[i] });
        }
        i = 0;
        while (i < cfg.clients) : (i += 1) threads[i].join();

        var entered: u32 = 0;
        i = 0;
        while (i < cfg.clients) : (i += 1) entered += outcomes[i].entered;
        const want = cfg.clients * cfg.runs;

        if (entered == want) {
            passed += 1;
            std.debug.print("  round {d}  {d}/{d} in-game  ok\n", .{ round, entered, want });
        } else {
            std.debug.print("  round {d}  {d}/{d} in-game  <- FAIL\n", .{ round, entered, want });
            if (first_fail == null) first_fail = round;
            if (!cfg.keep_going) break;
        }
    }

    std.debug.print("==> result: {d}/{d} rounds clean\n", .{ passed, cfg.rounds });
    if (first_fail) |r| {
        std.debug.print("stress-e2e: round {d} failed\n", .{r});
        std.process.exit(1);
    }
}

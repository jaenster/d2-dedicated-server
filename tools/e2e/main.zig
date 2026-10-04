//! Clientless E2E test runner for realmd. Optionally auto-starts its own realmd
//! (REALMD_BIN, default ./zig-out/bin/realmd) with a temp data dir + health port
//! 18080, runs the named scenarios, prints [PASS]/[FAIL]/[SKIP] + a summary, and
//! exits non-zero on any failure. Ported from tools/e2e/{run,scenarios}.py.
const std = @import("std");
const net = @import("net.zig");
const rc = @import("realmclient.zig");
const gsstore = @import("gsstore.zig");
const fakegs = @import("fakegs.zig");
const FakeGS = @import("fakegs.zig").FakeGS;

// libc process control. The 0.16 std.process.spawn API requires an Io instance
// + Environ.Map; we call fork/execve/kill/waitpid directly instead — same
// "talk to libc, skip the churny std wrappers" approach net.zig takes for
// sockets. getenv mirrors packages/realm-infra/config.zig.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn fork() c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

// libc socket bits for the echo server (mirrors net.zig's approach). We bind to an
// ephemeral port (port 0) and read it back with getsockname so the FakeGS can advertise it.
const posix = std.posix;
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *c_uint) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
const cclose = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "close" });

fn envOr(name: [*:0]const u8, default: [:0]const u8) [:0]const u8 {
    if (getenv(name)) |v| return std.mem.span(v);
    return default;
}

const Status = enum { pass, fail, skip };
const Result = struct { name: []const u8, status: Status, msg: []const u8 };

const alloc = std.heap.c_allocator;

// Admin API bearer token the harness starts realmd with (REALMD_ADMIN_TOKEN).
const ADMIN_TOKEN = "testtoken";
var HEALTH_PORT: u16 = 18080;

fn msg(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, fmt, args) catch "(alloc failed)";
}

// --- crafts: minimal_d2s ---
const D2S_SIGNATURE: u32 = 0xAA55AA55;

/// Minimal .d2s: sig@0, expansion bit@0x24, class@0x28, level@0x2b, pad to 0x40.
fn minimalD2s(buf: *[0x40]u8, name: []const u8, class_id: u8, level: u8) []const u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], D2S_SIGNATURE, .little);
    const n = @min(name.len, @as(usize, 15));
    @memcpy(buf[0x14..][0..n], name[0..n]);
    buf[0x24] = 0x20; // expansion
    buf[0x28] = class_id;
    buf[0x2b] = level;
    return buf[0..];
}

/// A save whose header carries a progression byte (0x25) — how far the character has got,
/// which is what the difficulty gates are checked against.
fn d2sWithProgression(buf: *[0x80]u8, name: []const u8, class_id: u8, level: u8, progression: u8) []const u8 {
    const out = d2sWithExperience(buf, name, class_id, level, 1000);
    buf[0x25] = progression;
    return out;
}

/// A save with a real attribute section: header, then "gf" marker + a packed list holding
/// level and experience (not a header field; a fixture without this can't rank by it).
/// Widths are ItemStatCost.txt's CSvBits: id 9 bits, level 7, experience 32, list ends id 0x1FF.
fn d2sWithExperience(buf: *[0x80]u8, name: []const u8, class_id: u8, level: u8, experience: u32) []const u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], D2S_SIGNATURE, .little);
    const n = @min(name.len, @as(usize, 15));
    @memcpy(buf[0x14..][0..n], name[0..n]);
    buf[0x24] = 0x20; // expansion
    buf[0x28] = class_id;
    buf[0x2b] = level;

    buf[0x30] = 'g';
    buf[0x31] = 'f';
    var bit: usize = 0;
    const put = struct {
        fn f(b: []u8, at: *usize, value: u32, width: u8) void {
            var i: u8 = 0;
            while (i < width) : (i += 1) {
                if ((value >> @intCast(i)) & 1 != 0) b[0x32 + (at.* >> 3)] |= @as(u8, 1) << @intCast(at.* & 7);
                at.* += 1;
            }
        }
    }.f;
    put(buf, &bit, 12, 9); // stat id: level
    put(buf, &bit, level, 7);
    put(buf, &bit, 13, 9); // stat id: experience
    put(buf, &bit, experience, 32);
    put(buf, &bit, 0x1FF, 9); // terminator
    return buf[0 .. 0x32 + (bit + 7) / 8];
}

// Scenarios

fn scLogin() Result {
    const name = "login";
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return .{ .name = name, .status = .fail, .msg = msg("{s}", .{@errorName(e)}) };
    c.auth() catch |e| return .{ .name = name, .status = .fail, .msg = msg("{s}", .{@errorName(e)}) };
    c.login("LoginGuy") catch |e| return .{ .name = name, .status = .fail, .msg = msg("{s}", .{@errorName(e)}) };
    c.enterRealm() catch |e| return .{ .name = name, .status = .fail, .msg = msg("{s}", .{@errorName(e)}) };
    if (c.status != 0) return .{ .name = name, .status = .fail, .msg = msg("realm status={d}", .{c.status}) };
    if (c.sessionId() < 1) return .{ .name = name, .status = .fail, .msg = msg("session id not minted ({d})", .{c.sessionId()}) };
    return .{ .name = name, .status = .pass, .msg = msg("session minted id={d} cookie=0x{x}", .{ c.sessionId(), c.cookie }) };
}

// Proves BNCS login AND the MCP realm session run over a SINGLE port (:6112) via
// the selector-mux in bncs.handle (0x01 + non-0xFF -> d2cs.handleFrom). The client
// points its MCP socket at 6112 instead of the dedicated d2cs port.
fn scMcpOn6112() Result {
    const name = "mcp_over_6112";
    const acct = "MuxGuy";
    const char = "MuxSorc";
    var d2s: [0x40]u8 = undefined;
    const blob = minimalD2s(&d2s, char, 1, 7); // 1 = Sorceress
    const sr = rc.storePutChar(acct, char, blob) catch |e| return fail(name, "save {s}", .{@errorName(e)});
    if (sr != 0) return fail(name, "staging the character failed: result={d}", .{sr});

    // MCP muxed onto the SAME port as BNCS — the point of the scenario, so it follows
    // the bnet port rather than the literal 6112.
    var c = rc.RealmClient{ .d2cs_port = rc.HOST_BNET };
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "connectBnet {s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "auth {s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "login {s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "enterRealm {s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "connectD2cs(bnet port) {s}", .{@errorName(e)});
    const su = c.startup() catch |e| return fail(name, "MCP startup over the bnet port: {s}", .{@errorName(e)});
    if (su != 0) return fail(name, "MCP startup result=0x{x}", .{su});

    var entries: [16]rc.CharEntry = undefined;
    var dst: [2048]u8 = undefined;
    const cl = c.charList(&entries, &dst) catch |e| return fail(name, "charList over the bnet port: {s}", .{@errorName(e)});
    var found = false;
    for (entries[0..cl.count]) |e| {
        if (std.mem.eql(u8, e.name, char)) found = true;
    }
    if (!found) return fail(name, "char {s} not in MCP list over 6112", .{char});
    return .{ .name = name, .status = .pass, .msg = msg("BNCS+MCP both served on :6112 (char {s} listed)", .{char}) };
}

fn scCharListStatstring() Result {
    const name = "char_list_statstring";
    const acct = "EpicAma";
    const char = "StatSorc";
    var d2s: [0x40]u8 = undefined;
    const blob = minimalD2s(&d2s, char, 1, 42); // 1 = Sorceress
    const sr = rc.storePutChar(acct, char, blob) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (sr != 0) return fail(name, "staging the character failed: result={d}", .{sr});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    const su = c.startup() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (su != 0) return fail(name, "d2cs startup result=0x{x}", .{su});

    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const cl = c.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var found: ?rc.CharEntry = null;
    for (entries[0..cl.count]) |e| {
        if (std.mem.eql(u8, e.name, char)) found = e;
    }
    const ch = found orelse return fail(name, "char {s} not in list", .{char});
    const cls = if (ch.class_id >= 0 and ch.class_id < rc.CLASS_NAMES.len)
        rc.CLASS_NAMES[@intCast(ch.class_id)]
    else
        "?";
    if (!std.mem.eql(u8, cls, "Sorceress")) return fail(name, "decoded class={s} (id={d}), want Sorceress", .{ cls, ch.class_id });
    if (ch.level != 42) return fail(name, "decoded level={d}, want 42", .{ch.level});
    return .{ .name = name, .status = .pass, .msg = msg("listed {s}: class={s} level={d} flags={d} (total={d})", .{ char, cls, ch.level, ch.flags, cl.total }) };
}

fn scCharCopy() Result {
    const name = "char_copy";
    const acct = "CopyAcct";
    const src = "Original";
    const dst = "CopyCat";
    var d2sbuf: [0x40]u8 = undefined;
    const blob = minimalD2s(&d2sbuf, src, 1, 20); // Sorceress, level 20
    const sr = rc.storePutChar(acct, src, blob) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (sr != 0) return fail(name, "staging the character failed: result={d}", .{sr});

    // Clone Original -> CopyCat within the same account via the admin API.
    var jb: [160]u8 = undefined;
    const json = std.fmt.bufPrint(&jb, "{{\"src_account\":\"{s}\",\"src_char\":\"{s}\",\"dst_char\":\"{s}\"}}", .{ acct, src, dst }) catch return fail(name, "json", .{});
    var rxbuf: [2048]u8 = undefined;
    const r = net.httpRequest(HEALTH_PORT, "POST", "/admin/chars/copy", ADMIN_TOKEN, json, &rxbuf) catch |e| return fail(name, "copy {s}", .{@errorName(e)});
    if (r.status != 200) return fail(name, "copy status={d} body={s}", .{ r.status, r.body });

    // A second copy must be refused (destination now exists).
    var rx2: [2048]u8 = undefined;
    const r2 = net.httpRequest(HEALTH_PORT, "POST", "/admin/chars/copy", ADMIN_TOKEN, json, &rx2) catch |e| return fail(name, "copy2 {s}", .{@errorName(e)});
    if (r2.status == 200) return fail(name, "duplicate copy must be rejected, got 200", .{});

    // Both the original and the clone must now list for the account.
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});
    var entries: [64]rc.CharEntry = undefined;
    var dst_buf: [4096]u8 = undefined;
    const cl = c.charList(&entries, &dst_buf) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var have_src = false;
    var have_dst = false;
    for (entries[0..cl.count]) |e| {
        if (std.mem.eql(u8, e.name, src)) have_src = true;
        if (std.mem.eql(u8, e.name, dst)) have_dst = true;
    }
    if (!have_src or !have_dst) return fail(name, "after copy expected both {s} and {s} (src={}, dst={})", .{ src, dst, have_src, have_dst });
    return .{ .name = name, .status = .pass, .msg = msg("'{s}' cloned to '{s}'; dup rejected; both list (total={d})", .{ src, dst, cl.total }) };
}

fn scClassicChar() Result {
    const name = "classic_char";
    const acct = "ClassicAcct";
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    // A classic Barbarian (class 4, no expansion bit) must be allowed.
    const barb = c.charCreateFresh(4, 0, "ClassicBarb") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (barb != 0) return fail(name, "classic Barbarian rejected (result=0x{x})", .{barb});

    // A classic Druid (class 5) must be REJECTED — Druid/Assassin are expansion-only.
    const cdruid = c.charCreateFresh(5, 0, "ClassicDruid") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cdruid == 0) return fail(name, "classic Druid was allowed, want rejection", .{});

    // The same Druid WITH the expansion bit must be allowed.
    const xdruid = c.charCreateFresh(5, 0x20, "ExpacDruid") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (xdruid != 0) return fail(name, "expansion Druid rejected (result=0x{x})", .{xdruid});

    return .{ .name = name, .status = .pass, .msg = msg("classic Barbarian ok, classic Druid rejected (0x{x}), expansion Druid ok", .{cdruid}) };
}

fn scLadder() Result {
    const name = "ladder_list";
    const acct = "LadderAcct";
    var d2s: [0x40]u8 = undefined;
    const king = rc.storePutChar(acct, "LadderKing", minimalD2s(&d2s, "LadderKing", 1, 99)) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (king != 0) return fail(name, "save LadderKing result={d}", .{king});
    const pawn = rc.storePutChar(acct, "LadderPawn", minimalD2s(&d2s, "LadderPawn", 1, 1)) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (pawn != 0) return fail(name, "save LadderPawn result={d}", .{pawn});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    var entries: [256]rc.LadderEntry = undefined;
    var dst: [8192]u8 = undefined;
    const cnt = c.ladderData(0x23, &entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var king_rank: ?usize = null;
    var pawn_rank: ?usize = null;
    var king_level: u32 = 0;
    for (entries[0..cnt], 0..) |e, i| {
        if (std.mem.eql(u8, e.name, "LadderKing")) {
            king_rank = i;
            king_level = e.level;
        }
        if (std.mem.eql(u8, e.name, "LadderPawn")) pawn_rank = i;
    }
    const kr = king_rank orelse return fail(name, "LadderKing not on ladder (cnt={d})", .{cnt});
    const pr = pawn_rank orelse return fail(name, "LadderPawn not on ladder (cnt={d})", .{cnt});
    if (king_level != 99) return fail(name, "LadderKing level={d} want 99", .{king_level});
    if (kr >= pr) return fail(name, "not ranked by level: King@{d} not before Pawn@{d}", .{ kr, pr });
    return .{ .name = name, .status = .pass, .msg = msg("ladder lists {d}; LadderKing(99)@{d} ranked above LadderPawn(1)@{d}", .{ cnt, kr, pr }) };
}

/// A ladder is ordered by experience, which is not in the save header — it lives in the
/// packed attribute list. Two characters at the SAME level is the case that tells the two
/// apart: ranking on the header's level byte can only tie them.
fn scLadderExperience() Result {
    const name = "ladder_experience";
    const acct = "ExpAcct";
    var buf: [0x80]u8 = undefined;
    const ahead = rc.storePutChar(acct, "ExpAhead", d2sWithExperience(&buf, "ExpAhead", 1, 90, 1_900_000_000)) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (ahead != 0) return fail(name, "save ExpAhead result={d}", .{ahead});
    const behind = rc.storePutChar(acct, "ExpBehind", d2sWithExperience(&buf, "ExpBehind", 1, 90, 1_200_000_000)) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (behind != 0) return fail(name, "save ExpBehind result={d}", .{behind});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    var entries: [256]rc.LadderEntry = undefined;
    var dst: [8192]u8 = undefined;
    const cnt = c.ladderData(0x23, &entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var ahead_rank: ?usize = null;
    var behind_rank: ?usize = null;
    var ahead_exp: u32 = 0;
    for (entries[0..cnt], 0..) |e, i| {
        if (std.mem.eql(u8, e.name, "ExpAhead")) {
            ahead_rank = i;
            ahead_exp = e.experience;
        }
        if (std.mem.eql(u8, e.name, "ExpBehind")) behind_rank = i;
    }
    const ar = ahead_rank orelse return fail(name, "ExpAhead not on ladder (cnt={d})", .{cnt});
    const br = behind_rank orelse return fail(name, "ExpBehind not on ladder (cnt={d})", .{cnt});
    if (ahead_exp != 1_900_000_000) return fail(name, "ExpAhead experience={d}, want 1900000000 (decoded from the attribute list)", .{ahead_exp});
    if (ar >= br) return fail(name, "same level, more experience did not rank first: ExpAhead@{d} vs ExpBehind@{d}", .{ ar, br });
    return .{ .name = name, .status = .pass, .msg = msg("equal level 90: exp {d} @{d} ranked above exp 1200000000 @{d}", .{ ahead_exp, ar, br }) };
}

/// CHARUPGRADE has to actually convert the save. It used to ack success and change
/// nothing, so the character came back classic and the screen kept offering the upgrade.
fn scCharUpgrade() Result {
    const name = "char_upgrade";
    const acct = "UpgradeAcct";
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    // A classic character: status carries no expansion bit, so the list reports flags 0.
    const created = c.charCreateFresh(4, 0, "Classicus") catch |e| return fail(name, "{s}", .{@errorName(e)}); // Barbarian
    if (created != 0) return fail(name, "create result=0x{x}", .{created});

    const before = charFlags(&c, "Classicus") orelse return fail(name, "'Classicus' missing from the list before upgrade", .{});
    if (before & 0x20 != 0) return fail(name, "fixture is already expansion (flags=0x{x})", .{before});

    const res = c.charUpgrade("Classicus") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (res != 0) return fail(name, "upgrade result={d}, want 0", .{res});

    const after = charFlags(&c, "Classicus") orelse return fail(name, "'Classicus' missing from the list after upgrade", .{});
    if (after & 0x20 == 0) return fail(name, "still classic after upgrade (flags=0x{x}) — the save was not converted", .{after});

    // Running it again must stay a success: the conversion it asked for is already true.
    const again = c.charUpgrade("Classicus") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (again != 0) return fail(name, "re-upgrading an expansion character result={d}, want 0", .{again});

    // A character that isn't there is a genuine failure.
    const missing = c.charUpgrade("NotAChar") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (missing == 0) return fail(name, "upgrading a nonexistent character reported success", .{});

    return .{ .name = name, .status = .pass, .msg = msg("classic flags=0x{x} -> expansion flags=0x{x}; idempotent; missing char rejected", .{ before, after }) };
}

/// The statstring flags the char list reports for one character, or null if absent.
/// The low byte mirrors the .d2s status byte, so 0x20 is the expansion bit.
fn charFlags(c: *rc.RealmClient, want: []const u8) ?u16 {
    var chars: [16]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const got = c.charList(&chars, &dst) catch return null;
    for (chars[0..got.count]) |e| {
        if (std.mem.eql(u8, e.name, want)) return e.flags;
    }
    return null;
}

/// A character belongs to the engine it was made on, and a client of another engine may not have
/// it. The whole point of the gate: a 1.09d client handed a 1.13c save either refuses the load or
/// writes the character back wrong, and neither is something the player can undo.
///
/// Three things have to hold together, so all three are asserted here: the version is recorded at
/// creation from the connecting client, a matching client still gets in, and a mismatched one is
/// refused with the code the client actually renders (0x46).
fn scCharVersion() Result {
    const name = "char_version";
    const acct = "VersionAcct";
    const old_char = "Antique";
    const new_char = "Modern";
    // The two builds the harness maps in REALMD_CLIENT_VERSIONS.
    const ver_old: u32 = (1 << 24) | 7;
    const ver_new: u32 = (1 << 24) | 8;

    // Made on the old client.
    var a = rc.RealmClient{ .exe_version = ver_old };
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    a.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    a.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    a.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((a.startup() catch 1) != 0) return fail(name, "d2cs startup failed on the old client", .{});
    if ((a.charCreateFresh(1, 0x20, old_char) catch 1) != 0) return fail(name, "could not create '{s}'", .{old_char});
    const same = a.charLogon(old_char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (same != 0) return fail(name, "the client that MADE '{s}' was refused it (0x{x})", .{ old_char, same });

    // The same account from the new client. The old character must be refused and a new one made
    // here must not be — otherwise the gate is just "nobody plays anything".
    var b = rc.RealmClient{ .exe_version = ver_new };
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    b.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    b.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    b.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((b.startup() catch 1) != 0) return fail(name, "d2cs startup failed on the new client", .{});

    const crossed = b.charLogon(old_char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (crossed != 0x46) return fail(name, "'{s}' on the wrong engine gave 0x{x}, want 0x46", .{ old_char, crossed });

    if ((b.charCreateFresh(2, 0x20, new_char) catch 1) != 0) return fail(name, "could not create '{s}'", .{new_char});
    const own = b.charLogon(new_char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (own != 0) return fail(name, "'{s}' was refused by the client that made it (0x{x})", .{ new_char, own });

    // Both are still LISTED to both clients — the ruling is "show everything, refuse on load", so
    // a player can see their whole account from any client and is told why one will not open.
    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const cl = b.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var seen_old = false;
    var seen_new = false;
    for (entries[0..cl.count]) |e| {
        if (std.mem.eql(u8, e.name, old_char)) seen_old = true;
        if (std.mem.eql(u8, e.name, new_char)) seen_new = true;
    }
    if (!seen_old or !seen_new) return fail(name, "the new client lists old={} new={}, want both", .{ seen_old, seen_new });

    return .{ .name = name, .status = .pass, .msg = msg(
        "'{s}' made on e2e-old is refused (0x46) by an e2e-new client, that client's own char is not, and both still list",
        .{old_char},
    ) };
}

fn scCharCreate() Result {
    const name = "create_char";
    const acct = "CreateAcct";
    const char = "Newbie";

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    // MCP_CHARCREATE a Sorceress (class 1) — realmd must build + persist a level-1 .d2s.
    const res = c.charCreateFresh(1, 0x20, char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (res != 0) return fail(name, "create result={d} want 0", .{res});

    // It must now appear in CHARLIST2 as a level-1 Sorceress.
    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const cl = c.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var found: ?rc.CharEntry = null;
    for (entries[0..cl.count]) |e| {
        if (std.mem.eql(u8, e.name, char)) found = e;
    }
    const fe = found orelse return fail(name, "created char '{s}' not listed (total={d})", .{ char, cl.total });
    if (fe.class_id != 1) return fail(name, "class_id={d} want 1 (Sorceress)", .{fe.class_id});
    if (fe.level != 1) return fail(name, "level={d} want 1", .{fe.level});

    // A duplicate name must be rejected (non-zero result).
    const dup = c.charCreate(1, 0x20, char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (dup == 0) return fail(name, "duplicate create succeeded, want rejection", .{});

    return .{ .name = name, .status = .pass, .msg = msg("created '{s}' (Sorceress lvl 1), listed, dup rejected (result=0x{x})", .{ char, dup }) };
}

fn scCharDelete() Result {
    const name = "delete_char";
    const acct = "DelAcct";
    const char = "DeleteMe";
    var d2s: [0x40]u8 = undefined;
    const blob = minimalD2s(&d2s, char, 1, 10);
    const sr = rc.storePutChar(acct, char, blob) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (sr != 0) return fail(name, "staging the character failed: result={d}", .{sr});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const before = c.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var present = false;
    for (entries[0..before.count]) |e| {
        if (std.mem.eql(u8, e.name, char)) present = true;
    }
    if (!present) return fail(name, "char {s} not present before delete", .{char});

    const res = c.charDelete(char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (res != 0) return fail(name, "delete result={d}", .{res});

    var entries2: [64]rc.CharEntry = undefined;
    var dst2: [4096]u8 = undefined;
    const after = c.charList(&entries2, &dst2) catch |e| return fail(name, "{s}", .{@errorName(e)});
    for (entries2[0..after.count]) |e| {
        if (std.mem.eql(u8, e.name, char)) return fail(name, "char {s} still listed after delete", .{char});
    }
    return .{ .name = name, .status = .pass, .msg = msg("'{s}' deleted: account char count {d} -> {d}", .{ char, before.total, after.total }) };
}

fn scCreateJoinGame() Result {
    const name = "create_join_game";
    var gs = FakeGS{ .gsid = 0xABCD, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 42 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("GameGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    // Tokens are now realm-global minted values (NOT the GS gameid) — the d2ingress
    // translates them back to the gameid. So assert non-zero + uniqueness, not == 42.
    const cg = c.createGame("mygame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    if (cg.token == 0) return fail(name, "create token=0 (expected a minted token)", .{});

    const jg = c.joinGame("mygame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (jg.result != 0) return fail(name, "join result={d}", .{jg.result});
    if (jg.token == 0) return fail(name, "join token=0 (expected a minted token)", .{});
    if (jg.token == cg.token) return fail(name, "join token={d} same as create token (tokens must be unique)", .{jg.token});
    if (!(jg.ip[0] == 127 and jg.ip[1] == 0 and jg.ip[2] == 0 and jg.ip[3] == 1))
        return fail(name, "join gs_ip={d}.{d}.{d}.{d} want 127.0.0.1", .{ jg.ip[0], jg.ip[1], jg.ip[2], jg.ip[3] });
    // The GS sees TWO join-notifies: create auto-seeds the creator's join (the account
    // reaches the GS only via the join-context notify — see onCreateGame), then the
    // explicit joinGame seeds it again. So creates=1, joins=2 for a create-then-join.
    if (gs.creates != 1 or gs.joins != 2) return fail(name, "FakeGS saw creates={d} joins={d}, want 1/2", .{ gs.creates, gs.joins });
    return .{ .name = name, .status = .pass, .msg = msg("create+join ok create-token={d} join-token={d} gs_ip=127.0.0.1 (creates={d} joins={d})", .{ cg.token, jg.token, gs.creates, gs.joins }) };
}

/// A character just created is the one the next game is for. The client goes from the creation
/// screen straight to the lobby without an MCP_CHARLOGON, so the realm has to take the create as
/// the selection — or the first game names an empty character to the game server.
fn scCreateCharThenGame() Result {
    const name = "create_char_then_game";
    const acct = "FirstGameAcct";
    const char = "FirstGamer";
    var gs = FakeGS{ .gsid = 0xABCE, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 43 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const res = c.charCreateFresh(1, 0x20, char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (res != 0) return fail(name, "create char result=0x{x}", .{res});
    // No charLogon here, exactly as the game client does it.
    const cg = c.createGame("firstgame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create game result={d}", .{cg.result});
    if (gs.joins == 0) return fail(name, "FakeGS saw no join notify", .{});
    const jc = std.mem.sliceTo(&gs.join_char, 0);
    const ja = std.mem.sliceTo(&gs.join_account, 0);
    if (!std.mem.eql(u8, jc, char)) return fail(name, "GS was told char='{s}' want '{s}'", .{ jc, char });
    if (!std.ascii.eqlIgnoreCase(ja, acct)) return fail(name, "GS was told account='{s}' want '{s}'", .{ ja, acct });
    return .{ .name = name, .status = .pass, .msg = msg("first game after create names '{s}' of '{s}' to the GS", .{ jc, ja }) };
}

/// A refused logon leaves the connection with nothing: a realm session, a game list, a game
/// cannot be had on it, and the realm closes it. The same for an MCP connection whose startup was
/// refused. (Both used to go on serving: a refused logon still named the account on the
/// connection, and SID_LOGONREALMEX minted a session for it.)
fn scRejectedLogonGated() Result {
    const name = "rejected_logon_gated";
    const acct = "GatedAcct";
    var gs = FakeGS{ .gsid = 0xABD0, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 45 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();

    // an account with a password
    {
        var a = rc.RealmClient{};
        defer a.close();
        a.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
        a.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
        const made = a.createAccount(acct, "right-password") catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (made != 0) return fail(name, "create account result={d}", .{made});
    }

    // a wrong password: refused, and the realm logon on the same connection gets nothing
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    const res = c.loginPwResult(acct, "wrong-password") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (res == 0) return fail(name, "a wrong password was accepted", .{});
    c.setBnetTimeout(2000);
    if (c.enterRealm()) |_| {
        if (c.sessionId() != 0) return fail(name, "SID_LOGONREALMEX minted session {d} after a refused logon", .{c.sessionId()});
    } else |_| {} // the connection was closed: what we want

    // an MCP connection whose startup is refused cannot create or join
    var m = rc.RealmClient{};
    defer m.close();
    m.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    m.lo = 0x0bad_5e55;
    m.hi = 0x0bad_5e55;
    m.account = acct;
    const st = m.startup() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (st == 0) return fail(name, "a made-up session was accepted", .{});
    const cg = m.createGame("gatedgame", "d");
    if (cg) |r| if (r.result == 0) return fail(name, "created a game after a refused startup", .{}) else {} else |_| {}
    if (gs.creates != 0) return fail(name, "the GS was asked to create a game ({d})", .{gs.creates});

    // and one that never started up at all
    var n = rc.RealmClient{};
    defer n.close();
    n.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    const jg = n.joinGame("gatedgame");
    if (jg) |r| if (r.result == 0) return fail(name, "joined a game without a startup", .{}) else {} else |_| {}
    if (gs.joins != 0) return fail(name, "the GS was told of a join ({d})", .{gs.joins});
    return .{ .name = name, .status = .pass, .msg = msg("refused logon: no realm session; refused or missing startup: no create, no join", .{}) };
}

/// The store refuses a save built from bytes it has since moved past.
///
/// This is the mechanism that makes a rollback impossible rather than merely unlikely. Every other
/// guard narrows the ways older bytes can reach the store — the seat table, the character lock,
/// the retry queue's age bound, refusing to delete a character that is in a game. This one closes
/// the question: even if every one of those failed at once, the store itself will not accept a
/// save whose version has been superseded.
fn scSaveFence() Result {
    const name = "save_fence";
    const acct = "FenceAcct";
    const char = "Fenced";

    var d2s: [0x40]u8 = undefined;
    const v1 = minimalD2s(&d2s, char, 1, 10);
    if ((rc.storePutChar(acct, char, v1) catch 1) != 0) return fail(name, "staging failed", .{});

    const at_load = rc.storeCharVersion(acct, char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (at_load == 0) return fail(name, "staged character has no version to fence on", .{});

    // A save built from what we loaded is accepted, and moves the version on.
    var b2: [0x40]u8 = undefined;
    const v2 = minimalD2s(&b2, char, 1, 20);
    const after = (rc.storePutCharFenced(acct, char, v2, at_load) catch |e| return fail(name, "{s}", .{@errorName(e)})) orelse
        return fail(name, "a save at the version we loaded was refused", .{});
    if (after <= at_load) return fail(name, "version did not advance: {d} -> {d}", .{ at_load, after });

    // Now the rollback, attempted directly: a second server still holding the OLD version tries to
    // write the OLD bytes. This is what every bug in this area eventually reduces to, and it must
    // be refused whatever led to it.
    const stale = rc.storePutCharFenced(acct, char, v1, at_load) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (stale != null) return fail(name, "a stale save was ACCEPTED — the fence is not holding", .{});

    // And the newer character is intact: refused, not partially applied.
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const cl = c.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    for (entries[0..cl.count]) |e| {
        if (!std.mem.eql(u8, e.name, char)) continue;
        if (e.level != 20) return fail(name, "level={d} after a refused stale save, want 20", .{e.level});
    }
    return .{ .name = name, .status = .pass, .msg = msg("v{d} -> v{d} accepted; the same save replayed at v{d} refused, character still level 20", .{ at_load, after, at_load }) };
}

/// A character name belongs to the realm, not to an account.
///
/// Names used to be checked only within the creating account, so two players could both have a
/// "Bob" — and then every part of the system that identifies a character by name alone had two
/// answers: the game servers' seat tables, the save-retry queue, a departing player's seat
/// release, and the Mac engine's own `<charname>.d2s`. That is not a rollback, it is one player's
/// save filed under the other's account.
fn scRealmUniqueNames() Result {
    const name = "realm_unique_names";
    const shared = "Contested";

    var a = rc.RealmClient{};
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    a.login("NameOwner") catch |e| return fail(name, "{s}", .{@errorName(e)});
    a.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    a.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((a.startup() catch 1) != 0) return fail(name, "d2cs startup failed (A)", .{});
    const made = a.charCreateFresh(1, 0x20, shared) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (made != 0) return fail(name, "first create of '{s}' failed: {d}", .{ shared, made });

    var b = rc.RealmClient{};
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    b.login("NameRival") catch |e| return fail(name, "{s}", .{@errorName(e)});
    b.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    b.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((b.startup() catch 1) != 0) return fail(name, "d2cs startup failed (B)", .{});
    const taken = b.charCreateFresh(1, 0x20, shared) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (taken == 0) return fail(name, "a second account created '{s}' — names are not realm-unique", .{shared});

    // The rival must not have acquired anything.
    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const cl = b.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    for (entries[0..cl.count]) |e| {
        if (std.mem.eql(u8, e.name, shared)) return fail(name, "the refused character is listed for the second account", .{});
    }
    return .{ .name = name, .status = .pass, .msg = msg("'{s}' claimed by one account; a second account refused (0x{x})", .{ shared, taken }) };
}

/// A character that is in a game cannot be deleted out from under it.
///
/// The game server holds the character in memory and writes it back on its own timer, so a delete
/// accepted here does not end the session — it loses a race with it. The next save recreates the
/// character; and if the player made a NEW one with the same name in between, that stale save
/// lands on top of the new character instead. Both outcomes read to the player as a rollback.
fn scDeleteInGame() Result {
    const name = "delete_in_game";
    const acct = "DelGuard";
    const char = "Busy";

    var gs = FakeGS{ .gsid = 0xDE1E, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 0xDE1E };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    if ((c.charCreateFresh(1, 0x20, char) catch 1) != 0) return fail(name, "could not create '{s}'", .{char});
    if ((c.charLogon(char) catch 1) != 0) return fail(name, "could not log on as '{s}'", .{char});

    // Deletable before it is anywhere. Asserted first so a later refusal cannot be mistaken for
    // delete simply being broken.
    const cg = c.createGame("delgame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    const jg = c.joinGame("delgame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (jg.result != 0) return fail(name, "join result={d}", .{jg.result});

    // Now it is in a game, and the realm holds its seat.
    const refused = c.charDelete(char) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (refused == 0) return fail(name, "delete of an in-game character SUCCEEDED, want refusal", .{});

    // And it is still there.
    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const after = c.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var present = false;
    for (entries[0..after.count]) |e| {
        if (std.mem.eql(u8, e.name, char)) present = true;
    }
    if (!present) return fail(name, "'{s}' vanished from the list after a refused delete", .{char});

    return .{ .name = name, .status = .pass, .msg = msg("delete of an in-game character refused (0x{x}); '{s}' still listed", .{ refused, char }) };
}

/// A save is only durable if it is written under the right ACCOUNT — and the account reaches the
/// game server in one place only: the JOINGAME the realm dispatches. Get that pairing wrong and
/// nothing fails: the save lands at an address no login path reads, the server logs a success,
/// and the player comes back rolled back to their previous session. `save_durability` below
/// covers the other half — that a save which reached the store survives the flush; this one is
/// about it reaching the right place to begin with. That silence is why it is a scenario.
fn scSaveAccountKey() Result {
    const name = "save_account_key";
    const acct = "SaveAcct";
    const char = "Persist";

    var gs = FakeGS{ .gsid = 0x5A4E, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 0x5A4E };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    if ((c.charCreateFresh(1, 0x20, char) catch 1) != 0) return fail(name, "could not create '{s}'", .{char});
    if ((c.charLogon(char) catch 1) != 0) return fail(name, "could not log on as '{s}'", .{char});

    const cg = c.createGame("savegame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    const jg = c.joinGame("savegame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (jg.result != 0) return fail(name, "join result={d}", .{jg.result});

    // What the realm told the server this character belongs to. Everything below keys off this
    // rather than off `acct`, because this is the only value a real server ever has.
    const told_char = std.mem.sliceTo(&gs.join_char, 0);
    const told_acct = std.mem.sliceTo(&gs.join_account, 0);
    if (told_char.len == 0 or told_acct.len == 0)
        return fail(name, "JOINGAME carried char='{s}' account='{s}' — the server cannot key a save without both", .{ told_char, told_acct });
    if (!std.ascii.eqlIgnoreCase(told_char, char))
        return fail(name, "JOINGAME named char '{s}', want '{s}'", .{ told_char, char });
    if (!std.ascii.eqlIgnoreCase(told_acct, acct))
        return fail(name, "JOINGAME named account '{s}', want '{s}'", .{ told_acct, acct });

    // The session happens. The server saves under the account it was told.
    var d2s: [0x40]u8 = undefined;
    const played = minimalD2s(&d2s, char, 1, 42);
    const sr = rc.storePutChar(told_acct, char, played) catch |e| return fail(name, "saving under '{s}': {s}", .{ told_acct, @errorName(e) });
    if (sr != 0) return fail(name, "save under '{s}' failed: result={d}", .{ told_acct, sr });

    // Logging back in must show the session that just happened, not the one before it.
    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const after = c.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var lvl: ?u32 = null;
    for (entries[0..after.count]) |e| {
        if (std.mem.eql(u8, e.name, char)) lvl = e.level;
    }
    const played_level = lvl orelse return fail(name, "'{s}' vanished from the character list after a save", .{char});
    if (played_level != 42) return fail(name, "level={d} after the save, want 42 — the save did not come back", .{played_level});

    // And the shape of the rollback, asserted directly. A save keyed by the CHARACTER's name
    // instead of the account — what the server wrote whenever it had lost the join's account —
    // must leave the real character untouched. It is a well-formed save at an address nothing
    // reads, which is exactly why the bug was invisible from the server's side.
    const stray = minimalD2s(&d2s, char, 1, 99);
    _ = rc.storePutChar(char, char, stray) catch |e| return fail(name, "{s}", .{@errorName(e)});

    var entries2: [64]rc.CharEntry = undefined;
    var dst2: [4096]u8 = undefined;
    const final = c.charList(&entries2, &dst2) catch |e| return fail(name, "{s}", .{@errorName(e)});
    for (entries2[0..final.count]) |e| {
        if (!std.mem.eql(u8, e.name, char)) continue;
        if (e.level != 42)
            return fail(name, "level={d} after a save keyed by the character name, want 42", .{e.level});
    }

    return .{ .name = name, .status = .pass, .msg = msg("JOINGAME carried {s}/{s}; a save under that account came back (lvl 1 -> 42) and one under the char name did not", .{ told_acct, told_char }) };
}

/// The join screen's PLAYERS column, and the description beside it. realmd only ever sees
/// joins pass through it, so a count it maintained alone could only ever climb; the number
/// that matters is the one the hosting GS reports. Asserting a DROP is the whole point.
fn scGamePopulation() Result {
    const name = "game_population";
    var gs = FakeGS{ .gsid = 0xF00D, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 4242 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("PopGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const cg = c.createGame("popgame", "come on in") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});

    var rows: [8]rc.GameEntry = undefined;
    var dst: [512]u8 = undefined;

    // Find our game in the list. Other tests leave games behind in the same realmd, so
    // match by name rather than assuming we're the only row.
    const findRow = struct {
        fn f(list: []const rc.GameEntry) ?rc.GameEntry {
            for (list) |g| {
                if (std.mem.eql(u8, g.name, "popgame")) return g;
            }
            return null;
        }
    }.f;

    var n = c.gameList(&rows, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    const created = findRow(rows[0..n]) orelse return fail(name, "'popgame' missing from the list of {d}", .{n});
    if (created.players != 1) return fail(name, "fresh game shows {d} players, want the creator's 1", .{created.players});
    if (!std.mem.eql(u8, created.description, "come on in"))
        return fail(name, "description='{s}' want 'come on in'", .{created.description});

    // Four in the game now — the GS says so, and its word replaces realmd's guess.
    gs.sendUpdateGameInfo(4242, 4, true) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (!awaitPlayers(&c, &rows, &dst, findRow, 4)) return fail(name, "count did not rise to 4", .{});

    // Three of them leave. This is the direction realmd could never see on its own.
    gs.sendUpdateGameInfo(4242, 1, false) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (!awaitPlayers(&c, &rows, &dst, findRow, 1)) return fail(name, "count did not fall back to 1", .{});

    n = c.gameList(&rows, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    const final = findRow(rows[0..n]) orelse return fail(name, "'popgame' vanished from the list", .{});
    if (!std.mem.eql(u8, final.description, "come on in"))
        return fail(name, "description lost across updates: '{s}'", .{final.description});
    return .{ .name = name, .status = .pass, .msg = msg("players 1 -> 4 -> 1 from the GS; description '{s}' survived", .{final.description}) };
}

/// A player who leaves a game is free to join it again at once, and the game's count follows.
///
/// The realm held the seat for as long as the game lived when the leave did not clear it, and a
/// join whose client never arrived the same way: the character was then "held by game:N" for good,
/// the game's member set kept the lock renewed, and the list kept counting a player who was gone.
fn scSeatReleasedOnLeave() Result {
    const name = "seat_released_on_leave";
    const acct = "SeatGuy";
    const char = "Rider";
    const gid: u32 = 0x5EA7;

    var gs = FakeGS{ .gsid = 0x5EA7, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = gid };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});
    if ((c.charCreateFresh(1, 0x20, char) catch 1) != 0) return fail(name, "could not create '{s}'", .{char});
    if ((c.charLogon(char) catch 1) != 0) return fail(name, "could not log on as '{s}'", .{char});

    var rcl = gsstore.Client.connect(fakegs.redis_port) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
    defer rcl.close();
    var gcb: [64]u8 = undefined;
    const gamechars = std.fmt.bufPrint(&gcb, "realmd:gamechars:{d}", .{gid}) catch unreachable;
    const lockkey = "realmd:charlock:" ++ acct ++ "/" ++ char;

    const cg = c.createGame("seatgame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    const jg = c.joinGame("seatgame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (jg.result != 0) return fail(name, "join result={d}", .{jg.result});
    gs.sendSeatNotice(gid, 1, 1, char, acct) catch |e| return fail(name, "{s}", .{@errorName(e)});

    const findRow = struct {
        fn f(list: []const rc.GameEntry) ?rc.GameEntry {
            for (list) |g| {
                if (std.mem.eql(u8, g.name, "seatgame")) return g;
            }
            return null;
        }
    }.f;
    var rows: [8]rc.GameEntry = undefined;
    var dst: [512]u8 = undefined;
    if (!awaitPlayers(&c, &rows, &dst, findRow, 1)) return fail(name, "count did not settle at 1 after the enter", .{});
    const held = rcl.cmd(&.{ "GET", lockkey }) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
    if (held != .bulk or held.bulk == null) return fail(name, "the character is not held while it is in the game", .{});

    // The leave. Nothing else is sent: the lock, the member and the count all have to follow it.
    gs.sendSeatNotice(gid, 0, 2, char, acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (!awaitPlayers(&c, &rows, &dst, findRow, 0)) return fail(name, "count did not fall to 0 after the leave", .{});
    var freed = false;
    var waited: u32 = 0;
    while (waited < 1000) : (waited += 25) {
        const l = rcl.cmd(&.{ "GET", lockkey }) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
        const m = rcl.cmd(&.{ "SISMEMBER", gamechars, acct ++ "/" ++ char }) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
        if (l == .bulk and l.bulk == null and m == .int and m.int == 0) {
            freed = true;
            break;
        }
        _ = net.usleep(25_000);
    }
    if (!freed) return fail(name, "after the leave the lock or the game's member set still held the character", .{});

    // And it can go straight back in.
    const again = c.joinGame("seatgame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (again.result != 0) return fail(name, "rejoin after a leave refused: result=0x{x}", .{again.result});
    return .{ .name = name, .status = .pass, .msg = msg("leave freed the lock and the member, count 1 -> 0, rejoin accepted", .{}) };
}

/// A join the player never completed must not lock them out of asking again, nor count twice.
fn scUnconfirmedJoinRetaken() Result {
    const name = "unconfirmed_join_retaken";
    const acct = "GhostGuy";
    const char = "Stray";
    const gid: u32 = 0x6057;

    var gs = FakeGS{ .gsid = 0x6057, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = gid };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});
    if ((c.charCreateFresh(1, 0x20, char) catch 1) != 0) return fail(name, "could not create '{s}'", .{char});
    if ((c.charLogon(char) catch 1) != 0) return fail(name, "could not log on as '{s}'", .{char});

    const cg = c.createGame("strayjoin", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    const first = c.joinGame("strayjoin") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (first.result != 0) return fail(name, "first join result=0x{x}", .{first.result});

    const findRow = struct {
        fn f(list: []const rc.GameEntry) ?rc.GameEntry {
            for (list) |g| {
                if (std.mem.eql(u8, g.name, "strayjoin")) return g;
            }
            return null;
        }
    }.f;
    var rows: [8]rc.GameEntry = undefined;
    var dst: [512]u8 = undefined;
    var n = c.gameList(&rows, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    const before = (findRow(rows[0..n]) orelse return fail(name, "game missing from the list", .{})).players;

    // The client never reaches the game server: no enter notice. It asks again, and is not shut out
    // by its own earlier attempt.
    const second = c.joinGame("strayjoin") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (second.result != 0) return fail(name, "second join refused by the first's seat: result=0x{x}", .{second.result});
    n = c.gameList(&rows, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    const after = (findRow(rows[0..n]) orelse return fail(name, "game missing from the list", .{})).players;
    if (after != before) return fail(name, "asking again counted a second player: {d} -> {d}", .{ before, after });

    // Once the server confirms the player, the seat is real and nothing takes it over.
    gs.sendSeatNotice(gid, 1, 1, char, acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (!awaitPlayers(&c, &rows, &dst, findRow, 1)) return fail(name, "count did not settle at 1", .{});
    return .{ .name = name, .status = .pass, .msg = msg("an unconfirmed seat was taken back on the second ask; count stayed {d}", .{after}) };
}

/// Poll the game list until 'popgame' reports `want` players. UPDATEGAMEINFO is fire-and-
/// forget, so there is no reply to wait on — only the effect to observe.
fn awaitPlayers(
    c: *rc.RealmClient,
    rows: []rc.GameEntry,
    dst: []u8,
    findRow: *const fn ([]const rc.GameEntry) ?rc.GameEntry,
    want: u8,
) bool {
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 25) {
        const n = c.gameList(rows, dst) catch return false;
        if (findRow(rows[0..n])) |g| {
            if (g.players == want) return true;
        }
        _ = net.usleep(25_000);
    }
    return false;
}

/// Every rejection code is checked against what the 1.14d client actually switches on
/// (OOG_PollJoinCreatePump @0x441770) — a swap between two plausible codes used to show
/// the wrong rejection message, or render nothing. The join screen's detail panel used to
/// answer token -1 unconditionally (the client's "no info" branch), leaving it blank for
/// every game; now it carries the real thing, laid out the way Incoming0x06 scatters it.
fn scGameInfo() Result {
    const name = "game_info_panel";
    var gs = FakeGS{ .gsid = 0x1F0, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 909 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("InfoGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    var dst: [512]u8 = undefined;

    // A game nobody made must still answer, with the "no info" token rather than silence.
    const none = c.gameInfo("ghostgame", &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (none.token != 0xFFFF_FFFF) return fail(name, "unknown game -> token 0x{x}, want 0xffffffff (no info)", .{none.token});

    const cg = c.createGame("infogame", "detail me") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});

    // Two characters arrive. Only the GS knows this happened, so only the GS can say so.
    gs.sendPlayerUpdate(909, 1, true, "Zealot", 88, 3) catch |e| return fail(name, "{s}", .{@errorName(e)});
    gs.sendPlayerUpdate(909, 2, true, "Frostie", 42, 1) catch |e| return fail(name, "{s}", .{@errorName(e)});

    var d: rc.GameDetail = .{};
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 25) {
        d = c.gameInfo("infogame", &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (d.players == 2) break;
        _ = net.usleep(25_000);
    }
    if (d.players != 2) return fail(name, "panel shows {d} players, want 2", .{d.players});
    if (!std.mem.eql(u8, d.description, "detail me")) return fail(name, "description='{s}' want 'detail me'", .{d.description});
    if (!std.mem.eql(u8, d.names[0], "Zealot") or !std.mem.eql(u8, d.names[1], "Frostie"))
        return fail(name, "names are '{s}'/'{s}', want Zealot/Frostie", .{ d.names[0], d.names[1] });
    if (d.levels[0] != 88 or d.classes[0] != 3) return fail(name, "Zealot listed as level {d} class {d}, want 88/3", .{ d.levels[0], d.classes[0] });
    if (d.levels[1] != 42 or d.classes[1] != 1) return fail(name, "Frostie listed as level {d} class {d}, want 42/1", .{ d.levels[1], d.classes[1] });
    if (d.level != 88) return fail(name, "reference level {d}, want the highest present (88)", .{d.level});
    if (d.max_players != 8) return fail(name, "max players {d}, want 8", .{d.max_players});

    // One leaves: the roster has to compact, not leave a hole the panel would stop at.
    gs.sendPlayerUpdate(909, 1, false, "Zealot", 88, 3) catch |e| return fail(name, "{s}", .{@errorName(e)});
    waited = 0;
    while (waited < 2000) : (waited += 25) {
        d = c.gameInfo("infogame", &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (d.players == 1) break;
        _ = net.usleep(25_000);
    }
    if (d.players != 1) return fail(name, "after a leave the panel shows {d} players, want 1", .{d.players});
    if (!std.mem.eql(u8, d.names[0], "Frostie")) return fail(name, "remaining player is '{s}', want Frostie", .{d.names[0]});

    return .{ .name = name, .status = .pass, .msg = msg("unknown=no-info; 2 players named+levelled, leave compacted to Frostie; desc '{s}'", .{d.description}) };
}

/// Opens a logged-in d2cs connection for `acct`, ready to create or join.
fn openLobby(c: *rc.RealmClient, acct: []const u8) !void {
    try c.connectBnet();
    try c.auth();
    try c.login(acct);
    try c.enterRealm();
    try c.connectD2cs();
    if ((try c.startup()) != 0) return error.StartupFailed;
}

/// A game takes the players its creator chose and no more: the creator's own join is seat one, a
/// join past the limit is refused with "Game is Full." (0x2b) and a zero address, and a refused
/// join leaves the seat count where it was. Eight is the engine's ceiling, so a ninth is refused in
/// a game that asked for eight.
fn scGameMaxPlayers() Result {
    const name = "game_max_players";
    var gs = FakeGS{ .gsid = 0x4A11, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .next_gameid = 9300 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    const Case = struct { game: []const u8, max: u8, seats: usize };
    const cases = [_]Case{
        .{ .game = "solo1", .max = 1, .seats = 1 },
        .{ .game = "duo2", .max = 2, .seats = 2 },
        .{ .game = "full8", .max = 8, .seats = 8 },
    };
    var clients: [9]rc.RealmClient = undefined;
    for (&clients) |*cl| cl.* = .{};
    defer for (&clients) |*cl| cl.close();

    var round: usize = 0;
    for (cases) |cs| {
        // Every case uses its own accounts, so a seat held in one game cannot be what refuses a join in
        // the next.
        var abuf: [9][24]u8 = undefined;
        var i: usize = 0;
        while (i < cs.seats + 1) : (i += 1) {
            const acct = std.fmt.bufPrint(&abuf[i], "Mp{d}x{d}", .{ round, i }) catch unreachable;
            if (clients[i].d2cs != null) clients[i].close();
            openLobby(&clients[i], acct) catch |e| return fail(name, "{s}: lobby for {s}: {s}", .{ cs.game, acct, @errorName(e) });
        }
        const cg = clients[0].createGameMax(cs.game, "d", cs.max) catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (cg.result != 0) return fail(name, "{s}: create result={d}", .{ cs.game, cg.result });
        i = 0;
        while (i < cs.seats) : (i += 1) {
            const j = clients[i].joinGame(cs.game) catch |e| return fail(name, "{s}", .{@errorName(e)});
            if (j.result != 0) return fail(name, "{s}: join {d} of {d} -> 0x{x}, want 0", .{ cs.game, i + 1, cs.seats, j.result });
        }
        // Past the limit, twice: a refused join must not have taken a seat.
        var extra: usize = 0;
        while (extra < 2) : (extra += 1) {
            const full = clients[cs.seats].joinGame(cs.game) catch |e| return fail(name, "{s}", .{@errorName(e)});
            if (full.result != 0x2b) return fail(name, "{s}: join {d} of {d} -> 0x{x}, want 0x2b (game is full)", .{ cs.game, cs.seats + 1, cs.seats, full.result });
            if (!std.mem.eql(u8, &full.ip, &[_]u8{ 0, 0, 0, 0 })) return fail(name, "{s}: a refused join carried address {any}, want zero", .{ cs.game, full.ip });
        }
        round += 1;
    }
    return .{ .name = name, .status = .pass, .msg = msg("max 1: 2nd refused; max 2: 3rd refused; max 8: 9th refused (0x2b, zero address)", .{}) };
}

fn scJoinErrors() Result {
    const name = "join_error_codes";
    var gs = FakeGS{ .gsid = 0xE770, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 777 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("ErrGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    // A game nobody made: "Game does not exist." (0x2a), NOT the password message.
    const missing = c.joinGame("nosuchgame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (missing.result != 0x2a) return fail(name, "join of a missing game -> 0x{x}, want 0x2a (game does not exist)", .{missing.result});

    // A real game with a password: the wrong one is 0x29, and it must not be confusable
    // with the code above — that swap is the bug this test exists for.
    const cg = c.createGameWithPassword("pwgame", "d", "letmein") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    const wrong = c.joinGameWithPassword("pwgame", "nope") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (wrong.result != 0x29) return fail(name, "wrong password -> 0x{x}, want 0x29 (name and password don't match)", .{wrong.result});
    const right = c.joinGameWithPassword("pwgame", "letmein") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (right.result != 0) return fail(name, "correct password -> 0x{x}, want 0", .{right.result});

    // An empty name is its own error, and reaches the client as "Invalid Game Name".
    const unnamed = c.createGame("", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (unnamed.result != 0x1e) return fail(name, "empty game name -> 0x{x}, want 0x1e (invalid game name)", .{unnamed.result});

    return .{ .name = name, .status = .pass, .msg = msg("missing=0x2a wrong-pw=0x29 ok=0 unnamed=0x1e", .{}) };
}

fn scFleetCapacity() Result {
    const name = "fleet_capacity";
    var gs_a = FakeGS{ .gsid = 0xAAA, .ip = .{ 127, 0, 0, 2 }, .maxgame = 1, .next_gameid = 100 };
    var gs_b = FakeGS{ .gsid = 0xBBB, .ip = .{ 127, 0, 0, 3 }, .maxgame = 1, .next_gameid = 200 };
    gs_a.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs_a.stop();
    gs_b.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs_b.stop();
    if (!gs_a.isRegistered() or !gs_b.isRegistered()) return fail(name, "both FakeGS must register", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("FleetGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const r1 = (c.createGame("game1", "d") catch |e| return fail(name, "{s}", .{@errorName(e)})).result;
    const r2 = (c.createGame("game2", "d") catch |e| return fail(name, "{s}", .{@errorName(e)})).result;
    if (r1 != 0 or r2 != 0) return fail(name, "first two creates must pass (r1={d} r2={d})", .{ r1, r2 });
    if (gs_a.creates != 1 or gs_b.creates != 1) return fail(name, "creates must spread one-each (a={d} b={d})", .{ gs_a.creates, gs_b.creates });

    const r3 = (c.createGame("game3", "d") catch |e| return fail(name, "{s}", .{@errorName(e)})).result;
    if (r3 == 0) return fail(name, "third create must fail (fleet full)", .{});
    if (gs_a.creates != 1 or gs_b.creates != 1) return fail(name, "no extra creates sent when full", .{});
    return .{ .name = name, .status = .pass, .msg = msg("spread a={d} b={d}, 3rd rejected (result={d})", .{ gs_a.creates, gs_b.creates, r3 }) };
}

/// A server that answers a create with a refusal (a draining machine, one shutting down) is not the
/// end of the create while another server can host the game.
fn scRefusedServerFallsBack() Result {
    const name = "refused_server_falls_back";
    // The refusing server is the less loaded one, so it is the first pick.
    var gs_a = FakeGS{ .gsid = 0xAA1, .ip = .{ 127, 0, 0, 2 }, .refuse_create_with = 0x77, .next_gameid = 100 };
    var gs_b = FakeGS{ .gsid = 0xBB1, .ip = .{ 127, 0, 0, 3 }, .extra_live = 1, .next_gameid = 200 };
    gs_a.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs_a.stop();
    gs_b.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs_b.stop();
    if (!gs_a.isRegistered() or !gs_b.isRegistered()) return fail(name, "both FakeGS must register", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("RefusedGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const r = (c.createGame("refgame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)})).result;
    if (r != 0) return fail(name, "create must succeed on the second server (result={d})", .{r});
    if (gs_a.creates != 1) return fail(name, "the less loaded server must have been asked first (a={d})", .{gs_a.creates});
    if (gs_b.creates != 1) return fail(name, "the game must land on the other server (b={d})", .{gs_b.creates});
    return .{ .name = name, .status = .pass, .msg = msg("refusal from a={d} then hosted on b={d}", .{ gs_a.creates, gs_b.creates }) };
}

/// A server that never answers (dead, but its record has not expired yet) costs one timeout, not the
/// create: the request is taken back and the next server hosts the game.
fn scSilentServerFallsBack() Result {
    const name = "silent_server_falls_back";
    var gs_a = FakeGS{ .gsid = 0xAA2, .ip = .{ 127, 0, 0, 2 }, .answer_after_ms = 600_000, .next_gameid = 100 };
    var gs_b = FakeGS{ .gsid = 0xBB2, .ip = .{ 127, 0, 0, 3 }, .extra_live = 1, .next_gameid = 200 };
    gs_a.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs_a.stop();
    gs_b.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs_b.stop();
    if (!gs_a.isRegistered() or !gs_b.isRegistered()) return fail(name, "both FakeGS must register", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("SilentGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const r = (c.createGame("silentgame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)})).result;
    if (r != 0) return fail(name, "create must succeed on the live server (result={d})", .{r});
    if (gs_b.creates != 1) return fail(name, "the game must land on the live server (b={d})", .{gs_b.creates});

    var rcl = gsstore.Client.connect(fakegs.redis_port) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
    defer rcl.close();
    var kb: [64]u8 = undefined;
    const qk = std.fmt.bufPrint(&kb, "realmd:gsq:{x}", .{gs_a.gsid}) catch unreachable;
    const len = rcl.cmd(&.{ "LLEN", qk }) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
    if (len != .int or len.int != 0) return fail(name, "the silent server's request must be taken back, or it creates a stale game when it revives", .{});
    return .{ .name = name, .status = .pass, .msg = msg("silent a skipped (queue emptied), hosted on b", .{}) };
}

/// The slash commands the 1.14d client forwards. It intercepts a few locally (/fps,
/// /players, /nopickup) but hands the rest to the realm verbatim, including whisper
/// aliases realmd did not recognise and /help, which it cannot answer itself.
/// Going into a game takes you out of the channel. Both signals the client sends for this
/// — SID_NOTIFYJOIN and SID_LEAVECHAT — used to be accepted and ignored, which left a
/// player who was off playing still listed in the lobby and still being sent its chat.
/// SID_GETFILETIME decides whether a BNFTP asset ever transfers: the client hands the
/// timestamp straight to its download layer, which compares it against what it has cached,
/// so a zero means "older than anything you own" and nothing is fetched. realmd replied
/// zero for everything — including files it was sitting on and would happily serve.
/// Nightmare and Hell are earned. The thresholds are the client's own: CharSel @0x4349b0
/// offers a difficulty at all only above progression 3 (classic) / 4 (expansion), and
/// UIMENU_SelectDifficultySinglePlayerOrTcpip @0x439780 reveals Hell above 7 / 9.
fn scDifficultyGate() Result {
    const name = "difficulty_gate";
    const acct = "DiffAcct";
    var gs = FakeGS{ .gsid = 0xD1FF, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .next_gameid = 900 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    // Three expansion characters either side of the two gates: 4 is one short of
    // Nightmare, 5 clears it, 9 is one short of Hell, 10 clears it.
    var buf: [0x80]u8 = undefined;
    const chars = [_]struct { name: []const u8, prog: u8 }{
        .{ .name = "DiffFresh", .prog = 4 },
        .{ .name = "DiffNm", .prog = 5 },
        .{ .name = "DiffNine", .prog = 9 },
        .{ .name = "DiffHell", .prog = 10 },
    };
    for (chars) |ch| {
        const blob = d2sWithProgression(&buf, ch.name, 1, 80, ch.prog);
        const r = rc.storePutChar(acct, ch.name, blob) catch |e| return fail(name, "save {s}", .{@errorName(e)});
        if (r != 0) return fail(name, "save {s} result={d}", .{ ch.name, r });
    }

    // The games themselves are made by a character that has cleared everything.
    const maker = d2sWithProgression(&buf, "DiffMaker", 1, 99, 15);
    _ = rc.storePutChar(acct, "DiffMaker", maker) catch |e| return fail(name, "save maker {s}", .{@errorName(e)});

    var owner = rc.RealmClient{};
    defer owner.close();
    owner.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((owner.startup() catch 1) != 0) return fail(name, "startup failed", .{});
    if ((owner.charLogon("DiffMaker") catch 1) != 0) return fail(name, "charlogon DiffMaker failed", .{});

    // Difficulty rides in bits 12-14 of the create flags.
    const nm = owner.createGameDiff("nmgame", "d", 1) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (nm.result != 0) return fail(name, "create nightmare game result={d}", .{nm.result});
    const hell = owner.createGameDiff("hellgame", "d", 2) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (hell.result != 0) return fail(name, "create hell game result={d}", .{hell.result});
    const norm = owner.createGameDiff("normgame", "d", 0) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (norm.result != 0) return fail(name, "create normal game result={d}", .{norm.result});

    const cases = [_]struct { char: []const u8, game: []const u8, want: u32, why: []const u8 }{
        .{ .char = "DiffFresh", .game = "normgame", .want = 0, .why = "Normal is open to everyone" },
        .{ .char = "DiffFresh", .game = "nmgame", .want = 0x73, .why = "progression 4 has not unlocked Nightmare" },
        .{ .char = "DiffNm", .game = "nmgame", .want = 0, .why = "progression 5 has" },
        .{ .char = "DiffNine", .game = "hellgame", .want = 0x74, .why = "progression 9 has not unlocked Hell" },
        .{ .char = "DiffHell", .game = "hellgame", .want = 0, .why = "progression 10 has" },
    };
    for (cases) |cs| {
        var c = rc.RealmClient{};
        defer c.close();
        c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
        c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
        c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
        c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
        c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
        if ((c.startup() catch 1) != 0) return fail(name, "startup failed", .{});
        if ((c.charLogon(cs.char) catch 1) != 0) return fail(name, "charlogon {s} failed", .{cs.char});
        const j = c.joinGame(cs.game) catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (j.result != cs.want)
            return fail(name, "{s} joining {s} -> 0x{x}, want 0x{x} ({s})", .{ cs.char, cs.game, j.result, cs.want, cs.why });
    }

    return .{ .name = name, .status = .pass, .msg = msg("Nightmare gated at progression 5, Hell at 10; Normal open (engine thresholds)", .{}) };
}

/// Make a character with `status`, log it on, and have it create a game — then hand back the
/// flag bytes the request carried to the GS. The whole point is the trip: the .d2s status byte
/// the client asked for has to survive into CREATEGAMEREQ, and only the server sees both ends.
fn createGameFlags(gs: *FakeGS, acct: []const u8, char: []const u8, status: u8, game: []const u8) !fakegs.CreateFlags {
    var c = rc.RealmClient{};
    defer c.close();
    try c.connectBnet();
    try c.auth();
    try c.login(acct);
    try c.enterRealm();
    try c.connectD2cs();
    if ((try c.startup()) != 0) return error.StartupFailed;
    if ((try c.charCreateFresh(1, status, char)) != 0) return error.CharCreateFailed; // 1 = Sorceress
    if ((try c.charLogon(char)) != 0) return error.CharLogonFailed;
    const cg = try c.createGame(game, "d");
    if (cg.result != 0) return error.CreateGameRefused;
    if (gs.creates == 0) return error.NoCreateReachedGs;
    return gs.create_flags;
}

/// A classic character's game must reach the GS as classic. Getting this wrong makes the
/// engine build an expansion world for a client that has no expansion data.
fn scClassicGameFlags() Result {
    const name = "classic_game_flags";
    var gs = FakeGS{ .gsid = 0xC1A5, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 7101 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    const f = createGameFlags(&gs, "FlagAcct", "FlagClassic", 0, "classicflags") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (f.expansion != 0) return fail(name, "expansion={d}, want 0 for a classic character", .{f.expansion});
    return .{ .name = name, .status = .pass, .msg = msg("classic creator -> expansion=0 (ladder={d} hardcore={d} diff={d})", .{ f.ladder, f.hardcore, f.difficulty }) };
}

/// Hardcore is the one flag a mistake cannot be undone by: a softcore world for a hardcore
/// character silently drops permadeath.
fn scHardcoreGameFlags() Result {
    const name = "hardcore_game_flags";
    var gs = FakeGS{ .gsid = 0xC0DE, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 7102 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    const f = createGameFlags(&gs, "FlagAcct", "FlagHardcore", 0x24, "hcflags") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (f.hardcore != 1) return fail(name, "hardcore={d}, want 1 for a hardcore character", .{f.hardcore});
    if (f.expansion != 1) return fail(name, "expansion={d}, want 1 (the character has 0x20 too)", .{f.expansion});
    return .{ .name = name, .status = .pass, .msg = msg("hardcore creator -> hardcore=1 expansion=1 (ladder={d})", .{f.ladder}) };
}

/// The ladder bit used to be dropped between the request and the engine's game flags, so
/// every ladder character was refused entry to the game it had just made.
fn scLadderGameFlags() Result {
    const name = "ladder_game_flags";
    var gs = FakeGS{ .gsid = 0x1ADD, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 7103 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    const f = createGameFlags(&gs, "FlagAcct", "FlagLadder", 0x60, "ladderflags") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (f.ladder != 1) return fail(name, "ladder={d}, want 1 for a ladder character", .{f.ladder});
    if (f.expansion != 1) return fail(name, "expansion={d}, want 1 (the character has 0x20 too)", .{f.expansion});
    return .{ .name = name, .status = .pass, .msg = msg("ladder creator -> ladder=1 expansion=1 (hardcore={d})", .{f.hardcore}) };
}

/// And the other edge: a non-ladder character must not be handed a ladder game, which is what
/// a flag hardcoded on rather than dropped would do.
fn scNonLadderGameFlags() Result {
    const name = "non_ladder_game_flags";
    var gs = FakeGS{ .gsid = 0x0ADD, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 7104 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    const f = createGameFlags(&gs, "FlagAcct", "FlagSoftie", 0x20, "noladderflags") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (f.ladder != 0) return fail(name, "ladder={d}, want 0 for a non-ladder character", .{f.ladder});
    if (f.hardcore != 0) return fail(name, "hardcore={d}, want 0 for a softcore character", .{f.hardcore});
    return .{ .name = name, .status = .pass, .msg = msg("non-ladder creator -> ladder=0 hardcore=0 (expansion={d})", .{f.expansion}) };
}

/// A logged-on realm client whose character carries `status` (.d2s byte 0x24).
fn clientWithChar(acct: []const u8, char: []const u8, status: u8) !rc.RealmClient {
    var c = rc.RealmClient{};
    errdefer c.close();
    try c.connectBnet();
    try c.auth();
    try c.login(acct);
    try c.enterRealm();
    try c.connectD2cs();
    if ((try c.startup()) != 0) return error.StartupFailed;
    if ((try c.charCreateFresh(1, status, char)) != 0) return error.CharCreateFailed;
    if ((try c.charLogon(char)) != 0) return error.CharLogonFailed;
    return c;
}

const list_kinds = [_]struct { char: []const u8, game: []const u8, status: u8 }{
    .{ .char = "ListClassic", .game = "g-classic", .status = 0x00 },
    .{ .char = "ListClassicLad", .game = "g-classic-lad", .status = 0x40 },
    .{ .char = "ListClassicHc", .game = "g-classic-hc", .status = 0x04 },
    .{ .char = "ListExp", .game = "g-exp", .status = 0x20 },
    .{ .char = "ListExpLad", .game = "g-exp-lad", .status = 0x60 },
    .{ .char = "ListExpHc", .game = "g-exp-hc", .status = 0x24 },
};

/// The game list shows a character only the games it could join: classic or expansion, ladder or
/// not, hardcore or not. Each of six kinds makes one game and must then see exactly its own.
fn scGameListFiltered() Result {
    const name = "game_list_filtered";
    var gs = FakeGS{ .gsid = 0x1157, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .next_gameid = 8100 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    // The list is capped, and the games earlier scenarios left behind would crowd this one's out of
    // it: forget them (the index only; their records lapse on their own).
    {
        var rcl = gsstore.Client.connect(fakegs.redis_port) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
        defer rcl.close();
        _ = rcl.cmd(&.{ "DEL", "realmd:games" }) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
    }

    var clients: [list_kinds.len]rc.RealmClient = undefined;
    var opened: usize = 0;
    defer for (clients[0..opened]) |*c| c.close();
    for (list_kinds, 0..) |k, i| {
        var acct: [24]u8 = undefined;
        const an = std.fmt.bufPrint(&acct, "ListAcct{d}", .{i}) catch unreachable;
        clients[i] = clientWithChar(an, k.char, k.status) catch |e| return fail(name, "{s} {s}", .{ k.char, @errorName(e) });
        opened += 1;
        const cg = clients[i].createGame(k.game, "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (cg.result != 0) return fail(name, "{s} create result={d}", .{ k.char, cg.result });
    }
    for (list_kinds, 0..) |k, i| {
        var rows: [16]rc.GameEntry = undefined;
        var dst: [1024]u8 = undefined;
        const n = clients[i].gameList(&rows, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
        // Other scenarios leave games behind; only this one's ("g-...") are judged.
        var mine: usize = 0;
        var own = false;
        for (rows[0..n]) |g| {
            if (!std.mem.startsWith(u8, g.name, "g-")) continue;
            mine += 1;
            if (std.mem.eql(u8, g.name, k.game)) own = true;
        }
        if (mine != 1 or !own) {
            return fail(name, "{s} (0x{x:0>2}) lists {d} of this scenario's games (own listed: {}); want only '{s}'", .{ k.char, k.status, mine, own, k.game });
        }
        // The detail panel of a game the list would not show says nothing, as for a missing one.
        const other = list_kinds[(i + 1) % list_kinds.len].game;
        var d: [512]u8 = undefined;
        const info = clients[i].gameInfo(other, &d) catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (info.token != 0xFFFF_FFFF) return fail(name, "{s}: game info of '{s}' answered (token 0x{x})", .{ k.char, other, info.token });
    }
    return .{ .name = name, .status = .pass, .msg = msg("classic/expansion x ladder x hardcore: each of 6 kinds lists only its own game, and no detail for the others", .{}) };
}

/// An expansion character that asks to join a classic game by name is told so with the code the
/// client words as "an Expansion character cannot join a game created by a Diablo II character",
/// carrying a zero address (which is what makes the client read the result), and nothing reaches
/// the game server.
fn scJoinWrongKind() Result {
    const name = "join_wrong_kind";
    var gs = FakeGS{ .gsid = 0x1158, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .next_gameid = 8200 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    var classic = clientWithChar("WrongAcctC", "WrongClassic", 0x00) catch |e| return fail(name, "classic {s}", .{@errorName(e)});
    defer classic.close();
    var exp = clientWithChar("WrongAcctE", "WrongExp", 0x20) catch |e| return fail(name, "expansion {s}", .{@errorName(e)});
    defer exp.close();
    const cg = classic.createGame("wrongkind", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});

    const jr = exp.joinGame("wrongkind") catch |e| return fail(name, "join: {s}", .{@errorName(e)});
    if (jr.result != 0x79) return fail(name, "expansion into classic -> 0x{x}, want 0x79", .{jr.result});
    if (jr.ip[0] != 0 or jr.ip[1] != 0 or jr.ip[2] != 0 or jr.ip[3] != 0) return fail(name, "a refusal carried an address", .{});

    // The other direction, and the ladder and hardcore mixes, each with its own code.
    const cg2 = exp.createGame("wrongexp", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg2.result != 0) return fail(name, "create wrongexp result={d}", .{cg2.result});
    const joins_before = gs.joins;
    const cases = [_]struct { joiner: []const u8, acct: []const u8, status: u8, want: u32 }{
        .{ .joiner = "WrongClassic2", .acct = "WrongAcctC2", .status = 0x00, .want = 0x78 },
        .{ .joiner = "WrongLadder", .acct = "WrongAcctL", .status = 0x60, .want = 0x7d },
        .{ .joiner = "WrongHardcore", .acct = "WrongAcctH", .status = 0x24, .want = 0x71 },
    };
    for (cases) |cs| {
        var j = clientWithChar(cs.acct, cs.joiner, cs.status) catch |e| return fail(name, "{s} {s}", .{ cs.joiner, @errorName(e) });
        defer j.close();
        const r = j.joinGame("wrongexp") catch |e| return fail(name, "{s}: {s}", .{ cs.joiner, @errorName(e) });
        if (r.result != cs.want) return fail(name, "{s} -> 0x{x}, want 0x{x}", .{ cs.joiner, r.result, cs.want });
        if (r.ip[0] != 0 or r.ip[1] != 0 or r.ip[2] != 0 or r.ip[3] != 0) return fail(name, "{s}: a refusal carried an address", .{cs.joiner});
    }
    if (gs.joins != joins_before) return fail(name, "the game server saw {d} join(s) for refused clients", .{gs.joins - joins_before});
    return .{ .name = name, .status = .pass, .msg = msg("exp->classic 0x79, classic->exp 0x78, ladder 0x7d, hardcore 0x71, each with a zero address; no join reached the GS", .{}) };
}

fn scGetFileTime() Result {
    const name = "get_file_time";
    const data_dir = envOr("REALMD_DATA_DIR", "/tmp/e2e-realmd");

    var cmd: [512]u8 = undefined;
    const staged = std.fmt.bufPrintZ(&cmd, "mkdir -p '{s}/bnftp' && printf gateways > '{s}/bnftp/bnserver-D2DV.ini'", .{ data_dir, data_dir }) catch
        return fail(name, "could not build the staging command", .{});
    const rc_stage = system(staged.ptr);
    if (rc_stage != 0) return fail(name, "staging the file failed (rc={d}): {s}", .{ rc_stage, staged });
    var vcmd: [512]u8 = undefined;
    const verify = std.fmt.bufPrintZ(&vcmd, "test -f '{s}/bnftp/bnserver-D2DV.ini'", .{data_dir}) catch return fail(name, "fmt", .{});
    if (system(verify.ptr) != 0) return fail(name, "the staged file is not there: {s}", .{verify});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("FileGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});

    const held = c.getFileTime("bnserver-D2DV.ini") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (held == 0) return fail(name, "a file we serve reported filetime 0 (staged under {s})", .{data_dir});
    // A FILETIME is 100ns ticks since 1601; anything sane is far past the 1970 epoch.
    const epoch_1970: u64 = 11644473600 * 10_000_000;
    if (held < epoch_1970) return fail(name, "filetime {d} predates 1970 — not a FILETIME", .{held});

    const absent = c.getFileTime("no-such-file.ini") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (absent != 0) return fail(name, "a file we do NOT have reported filetime {d}, want 0", .{absent});

    return .{ .name = name, .status = .pass, .msg = msg("held file reports a real FILETIME ({d}); an absent one reports 0", .{held}) };
}

/// The channel list shows characters, not accounts, so whisper/whois/ignore must accept the
/// name the player actually sees. Load test: a full friends list, every entry online/in a
/// channel — 50 entries at max name+channel length is ~2.8KB against the 2048-byte buffer it
/// used to get; before the bounds-checked writer that was an OOB slice (server down because
/// someone had too many friends). Concurrency: everything the realm keeps (chat registry,
/// session table, game table, rosters) sits behind per-connection spinlocks; this runs many
/// clients at once and checks the realm stays coherent, not just running.
const stress_clients = 64;

const StressWorker = struct {
    index: usize,
    ok: bool = false,
    thread: ?std.Thread = null,

    fn run(self: *StressWorker) void {
        var nb: [32]u8 = undefined;
        const acct = std.fmt.bufPrint(&nb, "Stress{d:0>3}", .{self.index}) catch return;
        var c = rc.RealmClient{};
        defer c.close();
        c.connectBnet() catch return;
        c.auth() catch return;
        c.login(acct) catch return;
        c.enterChat() catch return;
        c.joinChannel("Diablo II") catch return;
        // Say something, so other workers' broadcast paths run while this one is mutating
        // the registry — the contention this is here to create.
        var mb: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&mb, "worker {d} reporting", .{self.index}) catch return;
        c.chatCommand(line) catch return;
        c.chatCommand("/whois Stress000") catch return;
        self.ok = true;
    }
};

fn scConcurrentClients() Result {
    const name = "concurrent_clients";

    var workers: [stress_clients]StressWorker = undefined;
    for (&workers, 0..) |*wk, i| wk.* = .{ .index = i };
    for (&workers) |*wk| {
        wk.thread = std.Thread.spawn(.{}, StressWorker.run, .{wk}) catch null;
    }
    var spawned: usize = 0;
    for (&workers) |*wk| {
        if (wk.thread) |t| {
            t.join();
            spawned += 1;
        }
    }
    var succeeded: usize = 0;
    for (&workers) |*wk| {
        if (wk.ok) succeeded += 1;
    }
    if (spawned == 0) return fail(name, "could not spawn any workers", .{});
    // Some churn is tolerable under load, but a broad failure means the realm stopped
    // serving rather than merely slowed down.
    if (succeeded * 4 < spawned * 3) return fail(name, "only {d}/{d} concurrent clients completed", .{ succeeded, spawned });

    // All disconnected; the realm must still take a new client (listener + tables survived the
    // churn). The wait is for the server to NOTICE: each socket close must be observed by its
    // own read loop, and joining our workers only proves our side finished — probing too early
    // reads teardown-in-progress as a leak.
    _ = net.usleep(1_500_000);
    var after = rc.RealmClient{};
    defer after.close();
    after.connectBnet() catch |e| return fail(name, "realm stopped accepting after the load: {s}", .{@errorName(e)});
    after.auth() catch |e| return fail(name, "auth after load: {s}", .{@errorName(e)});
    after.login("AfterLoad") catch |e| return fail(name, "login after load: {s}", .{@errorName(e)});
    after.enterChat() catch |e| return fail(name, "enterChat after load: {s}", .{@errorName(e)});
    after.joinChannel("Diablo II") catch |e| return fail(name, "joinChannel after load: {s}", .{@errorName(e)});
    after.setBnetTimeout(1500);

    // And the channel must not still be listing workers that disconnected: a leaked member
    // would be shown to this client as a SHOWUSER on join.
    var ghosts: usize = 0;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const ev = after.readChatEvent() catch break;
        if (ev.eid != rc.EID_SHOWUSER) continue;
        if (std.mem.indexOf(u8, ev.username, "Stress") != null) {
            std.debug.print("channel still lists '{s}'\n", .{ev.username});
            ghosts += 1;
        }
    }
    if (ghosts > 0) return fail(name, "{d} disconnected clients are still in the channel", .{ghosts});

    return .{ .name = name, .status = .pass, .msg = msg("{d}/{d} concurrent clients; realm still serving and the channel drained clean", .{ succeeded, spawned }) };
}

fn scFriendsListLoad() Result {
    const name = "friends_list_load";
    const acct = "LoadAcct";
    const channel = "Diablo II";

    var owner = rc.RealmClient{};
    defer owner.close();
    owner.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.enterChat() catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.joinChannel(channel) catch |e| return fail(name, "{s}", .{@errorName(e)});
    owner.setBnetTimeout(3000);

    // Fill the list to its limit with the longest names the store will take.
    const want = 50;
    var added: usize = 0;
    var i: usize = 0;
    while (i < want) : (i += 1) {
        var nb: [32]u8 = undefined;
        const friend = std.fmt.bufPrint(&nb, "LoadFriend{d:0>2}xxxx", .{i}) catch return fail(name, "fmt", .{});
        var cb: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cb, "/f add {s}", .{friend}) catch return fail(name, "fmt", .{});
        owner.chatCommand(cmd) catch |e| return fail(name, "{s}", .{@errorName(e)});
        added += 1;
    }
    _ = net.usleep(300_000);

    // Bring a few of them online and into the channel, so their entries carry a location
    // string too — the part that pushed the reply over the edge.
    var online: [6]rc.RealmClient = undefined;
    var opened: usize = 0;
    defer for (online[0..opened]) |*oc| oc.close();
    var k: usize = 0;
    while (k < online.len) : (k += 1) {
        var nb: [32]u8 = undefined;
        const who = std.fmt.bufPrint(&nb, "LoadFriend{d:0>2}xxxx", .{k}) catch return fail(name, "fmt", .{});
        online[k] = rc.RealmClient{};
        opened = k + 1;
        online[k].connectBnet() catch |e| return fail(name, "friend {s}", .{@errorName(e)});
        online[k].auth() catch |e| return fail(name, "friend {s}", .{@errorName(e)});
        online[k].login(who) catch |e| return fail(name, "friend {s}", .{@errorName(e)});
        online[k].enterChat() catch |e| return fail(name, "friend {s}", .{@errorName(e)});
        online[k].joinChannel(channel) catch |e| return fail(name, "friend {s}", .{@errorName(e)});
    }
    _ = net.usleep(300_000);

    // The structured reply must come back whole, with every entry, and the server must
    // still be alive afterwards.
    var names: [64][]const u8 = undefined;
    var dst: [4096]u8 = undefined;
    const listed = owner.friendsList(&names, &dst) catch |e| return fail(name, "friendslist {s}", .{@errorName(e)});
    if (listed != added) return fail(name, "listed {d} of {d} friends — the reply was truncated", .{ listed, added });

    // Still serving: a second request on the same connection proves it did not fall over.
    const again = owner.friendsList(&names, &dst) catch |e| return fail(name, "second friendslist {s}", .{@errorName(e)});
    if (again != added) return fail(name, "second list returned {d}, want {d}", .{ again, added });

    return .{ .name = name, .status = .pass, .msg = msg("{d} friends ({d} online in a channel) serialize whole, twice", .{ listed, opened }) };
}

fn scNameResolution() Result {
    const name = "name_resolution";
    const channel = "Diablo II";

    var a = rc.RealmClient{};
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login("ResolveAcctA") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterChatAs("Amazon", "TypeGuru,Amazon") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.joinChannel(channel) catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.setBnetTimeout(2000);

    var b = rc.RealmClient{};
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.login("ResolveAcctB") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.enterChatAs("Necro", "TypeGuru,Necro") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.joinChannel(channel) catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.setBnetTimeout(2000);
    _ = net.usleep(150_000);

    // Whisper by the CHARACTER name — what B sees in the list — not the account.
    b.chatCommand("/w Amazon seen you") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    var got = false;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const ev = a.readChatEvent() catch break;
        if (ev.eid != rc.EID_WHISPER) continue;
        got = std.mem.indexOf(u8, ev.text, "seen you") != null;
        break;
    }
    if (!got) return fail(name, "a whisper to the character name never arrived", .{});

    // And by the full chat identity.
    b.chatCommand("/w Amazon*ResolveAcctA and again") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    got = false;
    i = 0;
    while (i < 10) : (i += 1) {
        const ev = a.readChatEvent() catch break;
        if (ev.eid != rc.EID_WHISPER) continue;
        got = std.mem.indexOf(u8, ev.text, "and again") != null;
        break;
    }
    if (!got) return fail(name, "a whisper to the full char*account identity never arrived", .{});

    // /whois by character name has to find them too.
    b.chatCommand("/whois Amazon") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    var found = false;
    i = 0;
    while (i < 10) : (i += 1) {
        const ev = b.readChatEvent() catch break;
        if (ev.eid == rc.EID_ERROR and std.mem.indexOf(u8, ev.text, "not logged on") != null)
            return fail(name, "/whois by character name said the user is not logged on", .{});
        if (ev.eid != rc.EID_INFO) continue;
        if (std.mem.indexOf(u8, ev.text, channel) != null) {
            found = true;
            break;
        }
    }
    if (!found) return fail(name, "/whois by character name did not locate them", .{});

    // /ignore by character name must actually squelch: the stored key is the account, and
    // typing the visible name used to store something the check never compared against.
    b.chatCommand("/ignore Amazon") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    _ = net.usleep(150_000);
    a.chatCommand("you should not see this") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    _ = net.usleep(250_000);
    b.setBnetTimeout(400);
    i = 0;
    while (i < 6) : (i += 1) {
        const ev = b.readChatEvent() catch break;
        if (ev.eid == rc.EID_TALK and std.mem.indexOf(u8, ev.text, "should not see") != null)
            return fail(name, "/ignore by character name did not squelch them", .{});
    }

    return .{ .name = name, .status = .pass, .msg = msg("whisper, /whois and /ignore all accept the character name the list shows", .{}) };
}

fn scLeaveChannel() Result {
    const name = "leave_channel";
    const channel = "Diablo II";

    var watcher = rc.RealmClient{};
    defer watcher.close();
    watcher.connectBnet() catch |e| return fail(name, "W {s}", .{@errorName(e)});
    watcher.auth() catch |e| return fail(name, "W {s}", .{@errorName(e)});
    watcher.login("LeaveWatch") catch |e| return fail(name, "W {s}", .{@errorName(e)});
    watcher.enterChat() catch |e| return fail(name, "W {s}", .{@errorName(e)});
    watcher.joinChannel(channel) catch |e| return fail(name, "W {s}", .{@errorName(e)});
    watcher.setBnetTimeout(2000);

    var player = rc.RealmClient{};
    defer player.close();
    player.connectBnet() catch |e| return fail(name, "P {s}", .{@errorName(e)});
    player.auth() catch |e| return fail(name, "P {s}", .{@errorName(e)});
    player.login("LeaveGoer") catch |e| return fail(name, "P {s}", .{@errorName(e)});
    player.enterChat() catch |e| return fail(name, "P {s}", .{@errorName(e)});
    player.joinChannel(channel) catch |e| return fail(name, "P {s}", .{@errorName(e)});
    player.setBnetTimeout(2000);
    _ = net.usleep(150_000);

    // Off to play. The channel should be told they left.
    player.notifyJoin("hunting") catch |e| return fail(name, "P {s}", .{@errorName(e)});
    var announced = false;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const ev = watcher.readChatEvent() catch break;
        if (ev.eid != rc.EID_LEAVE) continue;
        announced = std.mem.indexOf(u8, ev.username, "LeaveGoer") != null;
        if (announced) break;
    }
    if (!announced) return fail(name, "the channel was never told LeaveGoer left for a game", .{});

    // They are still logged on, and /whois should place them in the GAME, not a channel.
    watcher.chatCommand("/whois LeaveGoer") catch |e| return fail(name, "W {s}", .{@errorName(e)});
    var placed = false;
    i = 0;
    while (i < 12) : (i += 1) {
        const ev = watcher.readChatEvent() catch break;
        if (ev.eid != rc.EID_INFO) continue;
        if (std.mem.indexOf(u8, ev.text, "in the game hunting") != null) {
            placed = true;
            break;
        }
        if (std.mem.indexOf(u8, ev.text, "channel") != null)
            return fail(name, "/whois still puts a player in a game in a channel: '{s}'", .{ev.text});
    }
    if (!placed) return fail(name, "/whois did not place LeaveGoer in their game", .{});

    // And channel talk must no longer reach them.
    watcher.chatCommand("lobby noise") catch |e| return fail(name, "W {s}", .{@errorName(e)});
    _ = net.usleep(200_000);
    player.setBnetTimeout(400);
    i = 0;
    while (i < 4) : (i += 1) {
        const ev = player.readChatEvent() catch break;
        if (ev.eid == rc.EID_TALK and std.mem.indexOf(u8, ev.text, "lobby noise") != null)
            return fail(name, "a player in a game still received channel chat", .{});
    }

    return .{ .name = name, .status = .pass, .msg = msg("NOTIFYJOIN removes them from the channel; /whois names the game; channel talk stops", .{}) };
}

fn scChatCommands() Result {
    const name = "chat_commands";
    const channel = "Diablo II";

    var a = rc.RealmClient{};
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login("CmdAlice") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterChatAs("AliceChar", "TypeGuru,AliceChar") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.joinChannel(channel) catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.setBnetTimeout(2000);

    var b = rc.RealmClient{};
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.login("CmdBob") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.enterChat() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.joinChannel(channel) catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.setBnetTimeout(2000);
    _ = net.usleep(150_000);

    // Every alias the client offers has to land as a whisper. /m and /msg used to fall
    // through to the unknown-command path and do nothing.
    const aliases = [_][]const u8{ "/w", "/whisper", "/m", "/msg", "/W", "/Msg" };
    for (aliases) |alias| {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} CmdBob via{s}", .{ alias, alias }) catch return fail(name, "fmt", .{});
        a.chatCommand(line) catch |e| return fail(name, "A {s}", .{@errorName(e)});

        var got = false;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const ev = b.readChatEvent() catch break;
            if (ev.eid != rc.EID_WHISPER) continue;
            got = std.mem.indexOf(u8, ev.text, "via") != null;
            break;
        }
        if (!got) return fail(name, "'{s}' did not arrive as a whisper", .{alias});
    }

    // The client has no /r of its own and forwards it, so the realm answers the last whisperer.
    const replies = [_][]const u8{ "/r", "/reply", "/R" };
    for (replies) |verb| {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} back{s}", .{ verb, verb }) catch return fail(name, "fmt", .{});
        b.chatCommand(line) catch |e| return fail(name, "B {s}", .{@errorName(e)});

        var got = false;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const ev = a.readChatEvent() catch break;
            if (ev.eid != rc.EID_WHISPER) continue;
            got = std.mem.indexOf(u8, ev.text, "back") != null;
            break;
        }
        if (!got) return fail(name, "'{s}' did not reach the last whisperer", .{verb});
    }

    // /help is forwarded by the client because it cannot answer it; a blank reply is
    // indistinguishable from the command doing nothing.
    a.chatCommand("/help") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    var helped = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const ev = a.readChatEvent() catch break;
        if (ev.eid != rc.EID_INFO) continue;
        if (std.mem.indexOf(u8, ev.text, "whisper") != null) {
            helped = true;
            break;
        }
    }
    if (!helped) return fail(name, "/help did not list any commands", .{});

    // And a typo has to say so rather than answering with an empty line.
    a.chatCommand("/notacommand") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    var told = false;
    i = 0;
    while (i < 32) : (i += 1) {
        const ev = a.readChatEvent() catch break;
        if (ev.eid != rc.EID_ERROR) continue;
        told = std.mem.indexOf(u8, ev.text, "not a valid command") != null;
        break;
    }
    if (!told) return fail(name, "an unknown command was not reported as one", .{});

    return .{ .name = name, .status = .pass, .msg = msg("6 whisper aliases and /r replies delivered, /help lists commands, unknown command reported", .{}) };
}

/// The chat lobby names people by CHARACTER and account: the 1.14d client splits a channel username
/// on '*' (COMCALLBACK_FormatChannelUserData @0x4471b0) and matches its own name and each row by
/// the account after it.
fn scLobbyCharNames() Result {
    const name = "lobby_char_names";
    const channel = "Diablo II";

    var a = rc.RealmClient{};
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login("CharAcctA") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    // What a real client asks to be known as: the bare character, and "<realm>,<character>". The realm
    // answers with Battle.net's unique name for a Diablo II user, charname*account.
    a.enterChatAs("Sorceress", "TypeGuru,Sorceress") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    if (!std.mem.eql(u8, a.uniqueName(), "Sorceress*CharAcctA"))
        return fail(name, "ENTERCHAT unique name is '{s}', want 'Sorceress*CharAcctA'", .{a.uniqueName()});
    a.joinChannel(channel) catch |e| return fail(name, "A {s}", .{@errorName(e)});

    var b = rc.RealmClient{};
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.login("CharAcctB") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.enterChatAs("Barbarian", "TypeGuru,Barbarian") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.setBnetTimeout(2000);
    b.joinChannel(channel) catch |e| return fail(name, "B {s}", .{@errorName(e)});

    // B joined second, so B is shown the people already there. A must arrive as the
    // character, not as CharAcctA.
    var saw_a: bool = false;
    var seen: [64]u8 = undefined;
    var seen_len: usize = 0;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const ev = b.readChatEvent() catch break;
        if (ev.eid != rc.EID_SHOWUSER and ev.eid != rc.EID_JOIN) continue;
        if (std.mem.eql(u8, ev.username, "Sorceress*CharAcctA")) {
            saw_a = true;
            break;
        }
        if (std.mem.indexOf(u8, ev.username, "CharAcctA") != null) {
            const n = @min(ev.username.len, seen.len);
            @memcpy(seen[0..n], ev.username[0..n]);
            seen_len = n;
            break;
        }
    }
    if (!saw_a) {
        if (seen_len > 0) return fail(name, "channel list named A '{s}' — the account, so the client has no character to draw", .{seen[0..seen_len]});
        return fail(name, "never saw A in B's channel list", .{});
    }

    // And a line of chat has to carry the same identity, or the client cannot attribute it.
    _ = net.usleep(100_000);
    a.chatCommand("oi") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    i = 0;
    while (i < 8) : (i += 1) {
        const ev = b.readChatEvent() catch |e| return fail(name, "B no TALK ({s})", .{@errorName(e)});
        if (ev.eid != rc.EID_TALK) continue;
        if (!std.mem.eql(u8, ev.username, "Sorceress*CharAcctA"))
            return fail(name, "TALK came from '{s}', want 'Sorceress*CharAcctA'", .{ev.username});
        return .{ .name = name, .status = .pass, .msg = msg("channel list and chat both name A 'Sorceress*CharAcctA' (character and account)", .{}) };
    }
    return fail(name, "B never received A's TALK", .{});
}

/// A character named like its account (case aside) used to be left out of its chat name: the realm took
/// the request for a client with no character, the statstring lookup missed and the lobby drew a user it
/// could not parse as a character (a brown-robed figure under the account name). The name and the
/// statstring both have to carry the character, whose class and level the list is drawn from.
fn scLobbyCharNamedLikeAccount() Result {
    const name = "lobby_char_named_like_account";
    const channel = "Diablo II";
    var save: [0x80]u8 = undefined;
    _ = rc.storePutChar("samename", "Samename", d2sWithProgression(&save, "Samename", 0, 41, 0)) catch |e| return fail(name, "save {s}", .{@errorName(e)});

    var a = rc.RealmClient{};
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login("samename") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterChatAs("Samename", "beta,Samename") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    if (!std.mem.eql(u8, a.uniqueName(), "Samename*samename"))
        return fail(name, "unique name is '{s}', want 'Samename*samename'", .{a.uniqueName()});
    a.setBnetTimeout(1500);
    a.joinChannel(channel) catch |e| return fail(name, "A {s}", .{@errorName(e)});
    const own = nextEvent(&a, rc.EID_SHOWUSER, 6) orelse return fail(name, "A is not in its own user list", .{});
    const head = "PX2Dbeta,Samename,";
    if (!std.mem.startsWith(u8, own.text, head))
        return fail(name, "statstring is '{s}', want PX2D + realm,character,", .{own.text});
    const blob = own.text[head.len..];
    if (blob.len < 28 or blob[13] != 1 or blob[25] != 41)
        return fail(name, "statstring carries class+1 {d} level {d}, want 1 and 41", .{ if (blob.len > 13) blob[13] else 0, if (blob.len > 25) blob[25] else 0 });
    return .{ .name = name, .status = .pass, .msg = msg("a character named like its account is named and drawn as the character (class and level in its statstring)", .{}) };
}

/// The next event of kind `eid` a client is sent within `tries` events; null when none comes.
fn nextEvent(c: *rc.RealmClient, eid: u32, tries: usize) ?rc.ChatEvent {
    var i: usize = 0;
    while (i < tries) : (i += 1) {
        const ev = c.readChatEvent() catch return null;
        if (ev.eid == eid) return ev;
    }
    return null;
}

/// The whole SID_CHATEVENT sequence Battle.net sent a Diablo II client: on a join EID_CHANNEL
/// (the channel's name in the TEXT) and an EID_SHOWUSER for every user in the channel, the joiner
/// included, each named charname*account with the statstring the list is drawn from; EID_JOIN and
/// EID_LEAVE to the others; talk from the speaker's name and NOT echoed back (the client draws its
/// own); a whisper from the sender's name, echoed to the sender as EID_WHISPERSENT naming the
/// target; EID_EMOTE to everyone including the speaker.
fn scLobbyChatEvents() Result {
    const name = "lobby_chat_events";
    const channel = "Diablo II";
    const name_a = "EvSorc*EvAcctA";
    const name_b = "EvNecro*EvAcctB";
    var save: [0x80]u8 = undefined;
    _ = rc.storePutChar("EvAcctA", "EvSorc", d2sWithProgression(&save, "EvSorc", 1, 33, 0)) catch |e| return fail(name, "save {s}", .{@errorName(e)});
    _ = rc.storePutChar("EvAcctB", "EvNecro", d2sWithProgression(&save, "EvNecro", 2, 44, 0)) catch |e| return fail(name, "save {s}", .{@errorName(e)});

    var a = rc.RealmClient{};
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login("EvAcctA") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterChatAs("EvSorc", "TypeGuru,EvSorc") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    if (!std.mem.eql(u8, a.uniqueName(), name_a)) return fail(name, "A's unique name is '{s}'", .{a.uniqueName()});
    a.setBnetTimeout(1500);
    a.joinChannel(channel) catch |e| return fail(name, "A {s}", .{@errorName(e)});

    // The joiner is told the channel by its name in the text, and finds itself in the list.
    const ch = nextEvent(&a, rc.EID_CHANNEL, 4) orelse return fail(name, "A got no EID_CHANNEL", .{});
    if (!std.mem.eql(u8, ch.text, channel)) return fail(name, "EID_CHANNEL text is '{s}', want the channel's name", .{ch.text});
    const self_a = nextEvent(&a, rc.EID_SHOWUSER, 4) orelse return fail(name, "A is not in its own user list", .{});
    if (!std.mem.eql(u8, self_a.username, name_a)) return fail(name, "A's own row is '{s}', want '{s}'", .{ self_a.username, name_a });
    if (!std.mem.startsWith(u8, self_a.text, "PX2DTypeGuru,EvSorc,"))
        return fail(name, "A's statstring is '{s}', want PX2D + realm,character,", .{self_a.text});
    // class + 1 at 13 of the blob after the second comma, level at 25
    const blob = self_a.text["PX2DTypeGuru,EvSorc,".len..];
    if (blob.len < 28 or blob[13] != 2 or blob[25] != 33) return fail(name, "A's statstring carries class {d} level {d}, want the saved 2/33", .{ blob[13], blob[25] });

    var b = rc.RealmClient{};
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.login("EvAcctB") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.enterChatAs("EvNecro", "TypeGuru,EvNecro") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.setBnetTimeout(1500);
    b.joinChannel(channel) catch |e| return fail(name, "B {s}", .{@errorName(e)});

    // B sees the channel, then both users, itself among them.
    if (nextEvent(&b, rc.EID_CHANNEL, 2) == null) return fail(name, "B got no EID_CHANNEL", .{});
    var saw_a = false;
    var saw_b = false;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const ev = nextEvent(&b, rc.EID_SHOWUSER, 3) orelse break;
        if (std.mem.eql(u8, ev.username, name_a)) saw_a = true;
        if (std.mem.eql(u8, ev.username, name_b)) saw_b = true;
    }
    if (!saw_a or !saw_b) return fail(name, "B's user list: saw A={any} B={any}", .{ saw_a, saw_b });

    // A is told B joined, with B's statstring.
    const jb = nextEvent(&a, rc.EID_JOIN, 4) orelse return fail(name, "A never saw B join", .{});
    if (!std.mem.eql(u8, jb.username, name_b) or !std.mem.startsWith(u8, jb.text, "PX2D"))
        return fail(name, "EID_JOIN was '{s}' / '{s}'", .{ jb.username, jb.text });

    // Talk carries the speaker's name and is not sent back to the speaker.
    a.chatCommand("hello there") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    const talk = nextEvent(&b, rc.EID_TALK, 4) orelse return fail(name, "B got no talk", .{});
    if (!std.mem.eql(u8, talk.username, name_a) or !std.mem.eql(u8, talk.text, "hello there"))
        return fail(name, "talk was '{s}': '{s}'", .{ talk.username, talk.text });
    a.setBnetTimeout(400);
    if (nextEvent(&a, rc.EID_TALK, 3) != null) return fail(name, "A's own talk was echoed back (the client draws it itself: it would show twice)", .{});
    a.setBnetTimeout(1500);

    // A whisper arrives from the sender's name; the sender's echo names the target.
    a.chatCommand("/w EvNecro psst") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    const wh = nextEvent(&b, rc.EID_WHISPER, 4) orelse return fail(name, "B got no whisper", .{});
    if (!std.mem.eql(u8, wh.username, name_a) or !std.mem.eql(u8, wh.text, "psst"))
        return fail(name, "whisper was '{s}': '{s}'", .{ wh.username, wh.text });
    const sent = nextEvent(&a, rc.EID_WHISPERSENT, 4) orelse return fail(name, "A got no EID_WHISPERSENT", .{});
    if (!std.mem.eql(u8, sent.username, name_b) or !std.mem.eql(u8, sent.text, "psst"))
        return fail(name, "the echo was '{s}': '{s}'", .{ sent.username, sent.text });

    // An emote goes to everyone, the speaker too.
    b.chatCommand("/me waves") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    const em_a = nextEvent(&a, rc.EID_EMOTE, 4) orelse return fail(name, "A got no emote", .{});
    const em_b = nextEvent(&b, rc.EID_EMOTE, 4) orelse return fail(name, "B got no emote of its own", .{});
    if (!std.mem.eql(u8, em_a.username, name_b) or !std.mem.eql(u8, em_a.text, "waves") or !std.mem.eql(u8, em_b.text, "waves"))
        return fail(name, "emote was '{s}': '{s}'", .{ em_a.username, em_a.text });

    // Leaving is announced by name.
    b.leaveChat() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    const gone = nextEvent(&a, rc.EID_LEAVE, 4) orelse return fail(name, "A never saw B leave", .{});
    if (!std.mem.eql(u8, gone.username, name_b)) return fail(name, "EID_LEAVE was '{s}'", .{gone.username});

    return .{ .name = name, .status = .pass, .msg = msg("channel, own row, statstring, join/leave, talk, whisper (+sent), emote all as Battle.net sent them", .{}) };
}

fn scLobbyChatAtoB() Result {
    const name = "lobby_chat_a_to_b";
    const acct_a = "ChatAlice";
    const acct_b = "ChatBob";
    const channel = "Diablo II";

    var a = rc.RealmClient{};
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login(acct_a) catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterChat() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.joinChannel(channel) catch |e| return fail(name, "A {s}", .{@errorName(e)});

    var b = rc.RealmClient{};
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.login(acct_b) catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.enterChat() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.joinChannel(channel) catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.setBnetTimeout(2000); // never block forever on a missing event

    // Let B's join propagate before A talks, so A already sees B in-channel.
    _ = net.usleep(100_000);
    a.chatCommand("hello B") catch |e| return fail(name, "A {s}", .{@errorName(e)});

    // B reads events, skipping the CHANNEL/SHOWUSER/JOIN noise, until the TALK.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const ev = b.readChatEvent() catch |e| return fail(name, "B no TALK event ({s})", .{@errorName(e)});
        if (ev.eid != rc.EID_TALK) continue;
        if (!std.mem.eql(u8, ev.username, acct_a))
            return fail(name, "TALK from {s}, want {s}", .{ ev.username, acct_a });
        if (!std.mem.eql(u8, ev.text, "hello B"))
            return fail(name, "TALK text '{s}', want 'hello B'", .{ev.text});
        return .{ .name = name, .status = .pass, .msg = msg("B received TALK from {s}: '{s}'", .{ ev.username, ev.text }) };
    }
    return fail(name, "no EID_TALK among first 8 events B received", .{});
}

// Real Battle.net OLS account creation + password verification (xSHA-1):
//   1. CREATEACCOUNT2 "AuthUser"/"secret"  -> result 0 (created)
//   2. CREATEACCOUNT2 "AuthUser" again     -> non-zero (name taken)
//   3. login "AuthUser"/"secret"           -> 0 (success)
//   4. login "AuthUser"/"wrongpw"          -> non-zero (rejected)
fn scCreateAccountRealAuth() Result {
    const name = "create_account_real_auth";
    const acct = "AuthUser";

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});

    const r1 = c.createAccount(acct, "secret") catch |e| return fail(name, "create1 {s}", .{@errorName(e)});
    if (r1 != 0) return fail(name, "first create result={d}, want 0 (created)", .{r1});

    const r2 = c.createAccount(acct, "secret") catch |e| return fail(name, "create2 {s}", .{@errorName(e)});
    if (r2 == 0) return fail(name, "dup create result=0, want non-zero (name taken)", .{});

    const r3 = c.loginPwResult(acct, "secret") catch |e| return fail(name, "login-good {s}", .{@errorName(e)});
    if (r3 != 0) return fail(name, "correct-password login result={d}, want 0", .{r3});

    // Fresh connection: a new per-connection server_token, but the stored hash
    // means the wrong password must still be rejected.
    var c2 = rc.RealmClient{};
    defer c2.close();
    c2.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c2.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    const r4 = c2.loginPwResult(acct, "wrongpw") catch |e| return fail(name, "login-bad {s}", .{@errorName(e)});
    if (r4 == 0) return fail(name, "wrong-password login result=0, want non-zero (rejected)", .{});

    return .{ .name = name, .status = .pass, .msg = msg("create=0 dup={d} good-login=0 bad-login={d}", .{ r2, r4 }) };
}

// HTTP admin API on the health port: bearer-token auth, GS fleet listing,
// account creation that a real realm login then accepts.
//   1. a FakeGS registers (non-empty fleet)
//   2. GET /admin/gameservers + token -> 200, contains the FakeGS gsid
//   3. GET /admin/gameservers WITHOUT token -> 401
//   4. POST /admin/accounts {name,password} -> 200 created
//   5. realm loginPw(AdminMade, pw) -> success (admin-created account works)
//   6. GET /admin/status -> 200, gameservers >= 1
fn scAdminApi() Result {
    const name = "admin_api";
    var rxbuf: [8192]u8 = undefined;

    var gs = FakeGS{ .gsid = 0x5151, .ip = .{ 127, 0, 0, 1 }, .maxgame = 50, .gameid = 7 };
    gs.start(3000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    // 2. listing with the token contains the gsid (formatted lowercase hex "0x5151").
    const r1 = net.httpRequest(HEALTH_PORT, "GET", "/admin/gameservers", ADMIN_TOKEN, "", &rxbuf) catch |e| return fail(name, "gameservers {s}", .{@errorName(e)});
    if (r1.status != 200) return fail(name, "gameservers status={d} want 200", .{r1.status});
    if (std.mem.indexOf(u8, r1.body, "0x5151") == null) return fail(name, "gameservers body missing gsid 0x5151: {s}", .{r1.body});

    // 3. same request without the token -> 401.
    var rx2: [1024]u8 = undefined;
    const r2 = net.httpRequest(HEALTH_PORT, "GET", "/admin/gameservers", "", "", &rx2) catch |e| return fail(name, "noauth {s}", .{@errorName(e)});
    if (r2.status != 401) return fail(name, "no-token status={d} want 401", .{r2.status});

    // 4. create an account via the admin API.
    var rx3: [1024]u8 = undefined;
    const r3 = net.httpRequest(HEALTH_PORT, "POST", "/admin/accounts", ADMIN_TOKEN, "{\"name\":\"AdminMade\",\"password\":\"pw\"}", &rx3) catch |e| return fail(name, "create {s}", .{@errorName(e)});
    if (r3.status != 200) return fail(name, "create status={d} body={s}", .{ r3.status, r3.body });

    // 5. that account must log in over the real realm protocol.
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    const lr = c.loginPwResult("AdminMade", "pw") catch |e| return fail(name, "login {s}", .{@errorName(e)});
    if (lr != 0) return fail(name, "admin-created login result={d} want 0", .{lr});

    // 6. status reflects the registered fleet.
    var rx4: [1024]u8 = undefined;
    const r4 = net.httpRequest(HEALTH_PORT, "GET", "/admin/status", ADMIN_TOKEN, "", &rx4) catch |e| return fail(name, "status {s}", .{@errorName(e)});
    if (r4.status != 200) return fail(name, "status status={d} want 200", .{r4.status});
    if (std.mem.indexOf(u8, r4.body, "\"gameservers\":0") != null) return fail(name, "status reports gameservers=0: {s}", .{r4.body});
    if (std.mem.indexOf(u8, r4.body, "\"gameservers\"") == null) return fail(name, "status missing gameservers: {s}", .{r4.body});

    return .{ .name = name, .status = .pass, .msg = msg("gameservers listed gsid=0x5151, no-token=401, account created+logged-in, status ok", .{}) };
}

fn fail(name: []const u8, comptime fmt: []const u8, args: anytype) Result {
    return .{ .name = name, .status = .fail, .msg = msg(fmt, args) };
}

fn skip(name: []const u8, m: []const u8) Result {
    return .{ .name = name, .status = .skip, .msg = m };
}

// realmd child management
fn waitPort(port: u16, deadline_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < deadline_ms) : (waited += 100) {
        if (net.portOpen(port)) return true;
        _ = net.usleep(100_000);
    }
    return false;
}

/// A single REALMD_* env override (name/value) applied before fork+execve.
const EnvVar = struct { name: [*:0]const u8, value: [*:0]const u8 };

/// fork+execve a realmd child with `envs` applied (child inherits our environ, so the values
/// must be set at fork time), then restored afterwards — a scenario spawning its own
/// REALMD_DATA_DIR once silently redirected every later scenario's idea of where data lives.
/// Returns the child pid; waits up to 10s for `wait_port` to listen, exits the harness if not.
fn spawnRealmd(bin: [:0]const u8, envs: []const EnvVar, wait_port: u16) !c_int {
    // COPY the old values: getenv returns a pointer into the environ block, and the
    // setenv below overwrites that very entry, so keeping the pointer would restore
    // whatever happened to land there afterwards.
    var saved: [24][512]u8 = undefined;
    var had: [24]bool = undefined;
    // Silently skipping either of these would put the environment back wrong, which is the
    // exact failure this function exists to prevent — and it surfaces as a product bug in
    // an unrelated scenario. A harness may shout.
    if (envs.len > saved.len) std.debug.panic("spawnRealmd: {d} env vars, only {d} can be restored", .{ envs.len, saved.len });
    for (envs, 0..) |e, i| {
        had[i] = false;
        if (getenv(e.name)) |old| {
            const v = std.mem.span(old);
            if (v.len >= saved[i].len) std.debug.panic("spawnRealmd: {s} is {d} bytes, too long to save/restore", .{ e.name, v.len });
            @memcpy(saved[i][0..v.len], v);
            saved[i][v.len] = 0;
            had[i] = true;
        }
        _ = setenv(e.name, e.value, 1);
    }
    defer for (envs, 0..) |e, i| {
        if (had[i]) {
            const restored: [*:0]const u8 = @ptrCast(&saved[i]);
            _ = setenv(e.name, restored, 1);
        } else _ = unsetenv(e.name);
    };
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{bin.ptr};
        _ = execve(bin.ptr, &argv, environ);
        std.process.exit(127); // execve only returns on failure
    }
    if (!waitPort(wait_port, 10_000)) {
        _ = kill(pid, 9);
        std.debug.print("ERROR: realmd did not start listening on {d} in time.\n", .{wait_port});
        std.process.exit(2);
    }
    return pid;
}

/// fork+execve realmd with REALMD_DATA_DIR/REALMD_HEALTH_PORT set in our env
/// (inherited by the child). Returns the child pid, or null on existing realmd.
// The realm runs ephemeral state (sessions + games + token routes) in redis, and the
// d2ingress reads token routes from it asynchronously — so the harness brings up a real
// redis in docker, points realmd + d2ingress at it, and flushes it for a clean slate.
const REDIS_HOST_PORT: u16 = 6399;
const PG_HOST_PORT: u16 = 55499;

/// Bring up the two stores realmd needs. Both, always: there is no filesystem fallback to fall
/// back to, which is the point — a harness that could run without them would be testing a
/// configuration that does not exist.
fn startStores() void {
    _ = system("docker rm -f e2e-redis e2e-postgres >/dev/null 2>&1"); // clear stale containers
    if (system("docker run -d --rm --name e2e-redis -p 6399:6379 redis:7-alpine >/dev/null 2>&1") != 0) {
        std.debug.print("ERROR: could not start the redis container (docker is required).\n", .{});
        std.process.exit(2);
    }
    if (system("docker run -d --rm --name e2e-postgres -p 55499:5432 " ++
        "-e POSTGRES_USER=realmd -e POSTGRES_PASSWORD=realmd -e POSTGRES_DB=realmd " ++
        "postgres:16-alpine >/dev/null 2>&1") != 0)
    {
        std.debug.print("ERROR: could not start the postgres container (docker is required).\n", .{});
        stopStores();
        std.process.exit(2);
    }
    if (!waitPort(REDIS_HOST_PORT, 10_000) or !waitPort(PG_HOST_PORT, 30_000)) {
        std.debug.print("ERROR: a store container did not come up (redis :{d}, postgres :{d})\n", .{ REDIS_HOST_PORT, PG_HOST_PORT });
        stopStores();
        std.process.exit(2);
    }
    _ = system("docker exec e2e-redis redis-cli FLUSHALL >/dev/null 2>&1"); // clean slate
    _ = setenv("REALMD_REDIS_ADDR", "127.0.0.1:6399", 1);
    _ = setenv("REALMD_PG_DSN", "postgres://realmd:realmd@127.0.0.1:55499/realmd", 1);
    // The port being open is not the same as the server accepting connections, and neither is
    // `pg_isready`.
    //
    // On its FIRST boot the postgres image runs initdb, which starts a temporary server to create
    // the database and then shuts it down and restarts the real one. That temporary server listens
    // on a Unix socket only — so `pg_isready`, which prefers the socket, reports "accepting
    // connections" against a server that is about to disappear and was never reachable over TCP.
    // Meanwhile docker has already published the port, so a plain port check passes too. realmd
    // then connects into the gap and dies with `EndOfStream`, and the whole suite fails for
    // reasons that have nothing to do with what it was testing. That was roughly one run in two.
    //
    // `-h 127.0.0.1` is what tells the two apart: it forces TCP, which only the real server
    // offers. A query, not a ping, because a server can accept a connection while still recovering.
    var waited: u32 = 0;
    var pg_ready = false;
    while (waited < 60_000) : (waited += 250) {
        if (system("docker exec e2e-postgres psql -U realmd -h 127.0.0.1 -d realmd -c 'select 1' >/dev/null 2>&1") == 0) {
            pg_ready = true;
            break;
        }
        _ = net.usleep(250_000);
    }
    if (!pg_ready) {
        // Said plainly and fatally. Carrying on gets realmd killed by a connection error further
        // down, which reads as a realm bug rather than a container that never came up.
        std.debug.print("ERROR: postgres never accepted a TCP query on :{d} within 60s\n", .{PG_HOST_PORT});
        stopStores();
        std.process.exit(2);
    }
    std.debug.print("started e2e-redis :{d} and e2e-postgres :{d} (postgres answered a query)\n", .{ REDIS_HOST_PORT, PG_HOST_PORT });
}

fn stopStores() void {
    _ = system("docker rm -f e2e-redis e2e-postgres >/dev/null 2>&1");
}

fn maybeStartRealmd() !?c_int {
    if (net.portOpen(rc.HOST_BNET)) {
        // Reusing whatever answers on the port is convenient when iterating against a realm
        // already up, and a trap otherwise: that server isn't the binary just built, wasn't
        // given this harness's data dir/admin token/permissive-auth, and carries other state.
        // Set E2E_NO_REUSE=1 to refuse instead of guessing.
        std.debug.print(
            \\
            \\!! REUSING an existing realmd on 127.0.0.1:{d} — NOT the freshly built one.
            \\!! It has its own data dir and env, so failures below may say nothing about
            \\!! your changes. Stop that process (or set E2E_NO_REUSE=1) for a real run.
            \\
            \\
        , .{rc.HOST_BNET});
        if (std.mem.eql(u8, envOr("E2E_NO_REUSE", "0"), "1")) {
            std.debug.print("E2E_NO_REUSE=1 and port {d} is taken — refusing to test a server I did not start.\n", .{rc.HOST_BNET});
            std.process.exit(2);
        }
        return null;
    }
    const bin = envOr("REALMD_BIN", "./zig-out/bin/realmd");
    const data_dir = envOr("REALMD_DATA_DIR", "/tmp/e2e-realmd");
    // The child has to be told the SAME health port the scenarios above will ask on. That is
    // HEALTH_PORT, which E2E_PORT_BASE has already moved — so defaulting this to a literal 18080
    // meant the base override started a child that tried to bind whatever else owned 18080,
    // failed, and left every scenario reporting ConnectFailed as though the server were broken.
    var health_buf: [8]u8 = undefined;
    const health = envOr("REALMD_HEALTH_PORT", std.fmt.bufPrintZ(&health_buf, "{d}", .{HEALTH_PORT}) catch "18080");
    // Fresh data dir each run — accounts/chars/games persist otherwise and break
    // isolation (e.g. a re-created account would already exist on the 2nd run).
    var rmbuf: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&rmbuf, "rm -rf {s}", .{data_dir})) |cmd| {
        _ = system(cmd.ptr);
    } else |_| {}
    _ = mkdir(data_dir, 0o755); // ignore EEXIST; realmd creates subdirs itself
    _ = setenv("REALMD_DATA_DIR", data_dir, 1);
    _ = setenv("REALMD_HEALTH_PORT", health, 1);
    // Tell realmd to listen where the clients are going to look. Without this an
    // overridden port base moves only our end and realmd still fights for 6112.
    var pbuf: [6][8]u8 = undefined;
    const ports = [_]struct { name: [*:0]const u8, port: u16 }{
        .{ .name = "REALMD_BNET_PORT", .port = rc.HOST_BNET },
    };
    for (ports, 0..) |pp, i| {
        if (std.fmt.bufPrintZ(&pbuf[i], "{d}", .{pp.port})) |v| {
            _ = setenv(pp.name, v.ptr, 1);
        } else |_| {}
    }
    // Mandatory: the address clients are told to dial for game traffic. realmd refuses to start
    // without it, because a client sent straight at a game server presents a realm-global token
    // that server has never heard of.
    _ = setenv("REALMD_GAME_ADDR", "127.0.0.1", 1);
    _ = setenv("REALMD_ADMIN_TOKEN", ADMIN_TOKEN, 1); // enable the admin API (admin_api scenario)
    _ = setenv("REALMD_PERMISSIVE_AUTH", "1", 1); // legacy auth (auto-register + verify) for the synthetic xsha1 client
    // Two invented client builds, so the version scenario has two engines to disagree about. Real
    // builds are not used deliberately: this asserts the MECHANISM, and it must not start failing
    // the day someone corrects a real build number.
    _ = setenv("REALMD_CLIENT_VERSIONS", "1.0.0.7=e2e-old,1.0.0.8=e2e-new", 1);
    std.debug.print("starting realmd: {s} (data_dir={s}, health={s})\n", .{ bin, data_dir, health });

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // child: exec realmd, inheriting our (now-augmented) environ.
        const argv = [_:null]?[*:0]const u8{bin.ptr};
        _ = execve(bin.ptr, &argv, environ);
        std.process.exit(127); // execve only returns on failure
    }
    if (!waitPort(rc.HOST_BNET, 10_000)) {
        _ = kill(pid, 9);
        std.debug.print("ERROR: realmd did not start listening in time.\n", .{});
        std.process.exit(2);
    }
    return pid;
}

// Verify ONE GS hosts MULTIPLE concurrent games: a single FakeGS accepts 3 creates
// and realmd tracks all 3 against that one gsid. This is the realmd side of the
// multi-game-per-GS model (capacity, routing, tracking); the engine actually ticking
// N real games needs the GS under wine and is out of scope for the clientless harness.
fn scMultiGameOneGs() Result {
    const name = "multi_game_one_gs";
    var gs = FakeGS{ .gsid = 0xD2D2, .ip = .{ 127, 0, 0, 1 }, .maxgame = 10, .next_gameid = 500 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("MultiGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const names3 = [_][]const u8{ "mg_one", "mg_two", "mg_three" };
    for (names3) |gn| {
        const cg = c.createGame(gn, "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (cg.result != 0) return fail(name, "create {s} result={d}", .{ gn, cg.result });
    }
    if (gs.creates != 3) return fail(name, "one GS must host 3 games, saw creates={d}", .{gs.creates});

    // realmd tracks all 3 under the one gsid — confirm via the admin API.
    var rxbuf: [4096]u8 = undefined;
    const r = net.httpRequest(HEALTH_PORT, "GET", "/admin/games", ADMIN_TOKEN, "", &rxbuf) catch |e| return fail(name, "admin games {s}", .{@errorName(e)});
    if (r.status != 200) return fail(name, "admin games status={d}", .{r.status});
    for (names3) |gn| {
        if (std.mem.indexOf(u8, r.body, gn) == null) return fail(name, "game {s} not in /admin/games", .{gn});
    }
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, r.body, idx, "0xd2d2")) |p| : (idx = p + 1) count += 1;
    if (count < 3) return fail(name, "expected 3 games on gsid 0xd2d2, found {d}", .{count});
    // The listing has to carry what an operator actually needs — how full a game is, what
    // it was called, and which kind it is — not just an address.
    if (std.mem.indexOf(u8, r.body, "\"players\":") == null) return fail(name, "/admin/games has no player count: {s}", .{r.body});
    if (std.mem.indexOf(u8, r.body, "\"description\":\"d\"") == null) return fail(name, "/admin/games lost the description: {s}", .{r.body});
    if (std.mem.indexOf(u8, r.body, "\"expansion\":") == null) return fail(name, "/admin/games does not say what kind of game it is: {s}", .{r.body});
    return .{ .name = name, .status = .pass, .msg = msg("one GS hosts 3 games (creates={d}), all tracked under gsid 0xd2d2", .{gs.creates}) };
}

/// The banner ad above the chat window. The client is strict about this in a way that
/// makes a half-answer indistinguishable from no ad at all: NET_SID_CLIENT_Incoming_CheckAd
/// wants a body longer than 0x10, an id it isn't already showing, and BOTH the filename and
/// the URL non-empty, or it silently keeps what it has. realmd used to accept CHECKAD and
/// say nothing, and answer QUERYADURL with id 0 and an empty string.
fn scBannerAd() Result {
    const name = "banner_ad";
    const bin = envOr("REALMD_BIN", "./zig-out/bin/realmd");
    const data_dir = envOr("REALMD_DATA_DIR", "/tmp/e2e-realmd");

    // The ad file has to be fetchable, so drop it where BNFTP serves from.
    var cmd: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&cmd, "mkdir -p {s}/bnftp && printf 'BANNERPIXELS' > {s}/bnftp/banner.pcx", .{ data_dir, data_dir })) |c| {
        _ = system(c.ptr);
    } else |_| return fail(name, "could not stage the ad file", .{});

    const envs = [_]EnvVar{
        .{ .name = "REALMD_DATA_DIR", .value = data_dir },
        .{ .name = "REALMD_INSTANCE", .value = "AD" },
        // Set here rather than inherited: when the harness reuses an already-running
        // realmd it never gets as far as configuring the environment.
        .{ .name = "REALMD_PERMISSIVE_AUTH", .value = "1" },
        .{ .name = "REALMD_AD_FILE", .value = "banner.pcx" },
        .{ .name = "REALMD_AD_URL", .value = "https://example.invalid/promo" },
        .{ .name = "REALMD_BNET_PORT", .value = "20112" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "20118" },
        .{ .name = "REALMD_GAME_PORT", .value = "0" },
        .{ .name = "REALMD_GAME_ADDR", .value = "127.0.0.1" },
    };
    const pid = spawnRealmd(bin, &envs, 20112) catch |e| return fail(name, "spawn {s}", .{@errorName(e)});
    defer {
        _ = kill(pid, 15);
        _ = waitpid(pid, null, 0);
    }

    var c = rc.RealmClient{ .bnet_port = 20112, .d2cs_port = 20112 };
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("AdWatcher") catch |e| return fail(name, "{s}", .{@errorName(e)});

    var dst: [256]u8 = undefined;
    const maybe = c.checkAd(0, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    const ad = maybe orelse return fail(name, "CHECKAD got no reply — the client would show nothing", .{});

    // Each of these is a gate the client applies before it will fetch the banner.
    if (ad.body_len <= 0x10) return fail(name, "reply body is {d} bytes; the client ignores anything <= 0x10", .{ad.body_len});
    if (ad.id == 0) return fail(name, "ad id is 0 — the client's starting value, so it sees no change", .{});
    if (!std.mem.eql(u8, ad.filename, "banner.pcx")) return fail(name, "filename='{s}' want banner.pcx", .{ad.filename});
    if (!std.mem.eql(u8, ad.url, "https://example.invalid/promo")) return fail(name, "url='{s}'", .{ad.url});
    if (ad.extension != 0x00786370) return fail(name, "extension tag 0x{x}, want 'pcx' packed (0x786370)", .{ad.extension}); // 'p','c','x',0
    if (ad.filetime == 0) return fail(name, "filetime is 0; the download layer needs one to judge a cached copy", .{});

    // Same ad asked for twice must keep the same id, or the client re-downloads the
    // banner on every check.
    var dst2: [256]u8 = undefined;
    const again = (c.checkAd(ad.id, &dst2) catch |e| return fail(name, "{s}", .{@errorName(e)})) orelse
        return fail(name, "second CHECKAD got no reply", .{});
    if (again.id != ad.id) return fail(name, "ad id changed between checks ({x} -> {x}) — that re-downloads the banner every time", .{ ad.id, again.id });

    // And clicking it has to lead somewhere.
    var dst3: [256]u8 = undefined;
    const click = c.queryAdUrl(ad.id, &dst3) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (click.id != ad.id) return fail(name, "QUERYADURL answered for ad 0x{x}, asked about 0x{x}", .{ click.id, ad.id });
    if (!std.mem.eql(u8, click.url, "https://example.invalid/promo")) return fail(name, "click url='{s}'", .{click.url});

    return .{ .name = name, .status = .pass, .msg = msg("ad 0x{x} '{s}' ({d}B body, stable id) clicks through to {s}", .{ ad.id, ad.filename, ad.body_len, click.url }) };
}

/// Friends must outlive the process that heard about them (the list used to be in-memory,
/// so restarts silently emptied it). A second realmd over the same data dir is a stronger
/// test than a restart: its table is empty and it never saw the /f add, so it can only list
/// the friend by reading the store. Presence is deliberately NOT asserted — that's a fact
/// about live connections, and the friend has none on that instance.
/// A save that only redis has must survive the instance that was going to move it.
///
/// The character lives in redis and Postgres is the store of record, so there is always a window
/// where the only copy of a save is in the cache. If the instance that would have flushed it dies
/// in that window, the next one has to finish the job — nothing else here loses a player's
/// progress permanently.
///
/// The proof deletes the redis copy afterwards and reads the character back. It can only come from
/// Postgres at that point, so "the dirty flag cleared" cannot pass for "the save was written".
fn scSaveDurability() Result {
    const name = "save_durability";
    const acct = "DurableAcct";
    const char = "Durabilis";

    var d2s: [0x40]u8 = undefined;
    const blob = minimalD2s(&d2s, char, 1, 33); // Sorceress, level 33
    // storePutChar stages it the way a game server saves — bytes, version, dirty — and waits for a
    // flush worker to clear the mark, which it only does after Postgres has taken the save.
    const sr = rc.storePutChar(acct, char, blob) catch |e| return fail(name, "staging {s}", .{@errorName(e)});
    if (sr != 0) return fail(name, "staging the character failed: result={d}", .{sr});

    // Now take the cache away. Anything that answers from here on is the store of record.
    var c = gsstore.Client.connect(fakegs.redis_port) catch |e| return fail(name, "redis {s}", .{@errorName(e)});
    defer c.close();
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:char:{s}:{s}", .{ acct, char }) catch return fail(name, "key", .{});
    _ = c.cmd(&.{ "DEL", key }) catch |e| return fail(name, "del {s}", .{@errorName(e)});
    var sb: [192]u8 = undefined;
    const setkey = std.fmt.bufPrint(&sb, "realmd:chars:{s}", .{acct}) catch return fail(name, "key", .{});
    _ = c.cmd(&.{ "SREM", setkey, char }) catch |e| return fail(name, "srem {s}", .{@errorName(e)});

    var cl = rc.RealmClient{};
    defer cl.close();
    cl.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    cl.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    cl.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    cl.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    cl.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((cl.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const list = cl.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    for (entries[0..list.count]) |e| {
        if (!std.mem.eql(u8, e.name, char)) continue;
        if (e.level != 33) return fail(name, "recovered '{s}' at level {d}, want 33 — the save was altered", .{ char, e.level });
        return .{ .name = name, .status = .pass, .msg = msg("a save only redis had reached postgres, and survived losing the cache", .{}) };
    }
    return fail(name, "'{s}' is gone with the cache — the flush never reached the store of record", .{char});
}

fn scFriendsPersist() Result {
    const name = "friends_persist";
    const bin = envOr("REALMD_BIN", "./zig-out/bin/realmd");
    const data_dir = "/tmp/e2e-realmd-friends";
    const acct = "FriendKeeper";

    // Its own data dir and its own instances: this test is about what reaches disk, so it
    // must not share a store with anything else, and must not depend on the main harness
    // instance (which may be a realmd the harness merely found running).
    var cmd: [256]u8 = undefined;
    if (std.fmt.bufPrintZ(&cmd, "rm -rf {s}", .{data_dir})) |rm| _ = system(rm.ptr) else |_| {}

    const base = [_]EnvVar{
        .{ .name = "REALMD_DATA_DIR", .value = data_dir },
        .{ .name = "REALMD_PERMISSIVE_AUTH", .value = "1" },
        .{ .name = "REALMD_GAME_PORT", .value = "0" },
        .{ .name = "REALMD_GAME_ADDR", .value = "127.0.0.1" },
    };
    const envs_w = base ++ [_]EnvVar{
        .{ .name = "REALMD_INSTANCE", .value = "FW" },
        .{ .name = "REALMD_BNET_PORT", .value = "21112" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "21118" },
    };
    const writer_pid = spawnRealmd(bin, &envs_w, 21112) catch |e| return fail(name, "spawn writer {s}", .{@errorName(e)});
    defer {
        _ = kill(writer_pid, 15);
        _ = waitpid(writer_pid, null, 0);
    }

    var c = rc.RealmClient{ .bnet_port = 21112, .d2cs_port = 21112 };
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterChat() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.joinChannel("Diablo II") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.chatCommand("/f add Gheed") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.chatCommand("/f add Charsi") catch |e| return fail(name, "{s}", .{@errorName(e)});

    var names: [8][]const u8 = undefined;
    var dst: [256]u8 = undefined;
    const before = c.friendsList(&names, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (before != 2) return fail(name, "added 2 friends, list reports {d}", .{before});

    // A second instance over the same store: cold table, never saw the adds. The only way
    // it can list them is off disk.
    const envs_r = base ++ [_]EnvVar{
        .{ .name = "REALMD_INSTANCE", .value = "FR" },
        .{ .name = "REALMD_BNET_PORT", .value = "22112" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "22118" },
    };
    const cold_pid = spawnRealmd(bin, &envs_r, 22112) catch |e| return fail(name, "spawn cold {s}", .{@errorName(e)});
    defer {
        _ = kill(cold_pid, 15);
        _ = waitpid(cold_pid, null, 0);
    }

    var cold = rc.RealmClient{ .bnet_port = 22112, .d2cs_port = 22112 };
    defer cold.close();
    cold.connectBnet() catch |e| return fail(name, "cold {s}", .{@errorName(e)});
    cold.auth() catch |e| return fail(name, "cold {s}", .{@errorName(e)});
    cold.login(acct) catch |e| return fail(name, "cold {s}", .{@errorName(e)});

    var names2: [8][]const u8 = undefined;
    var dst2: [256]u8 = undefined;
    const after = cold.friendsList(&names2, &dst2) catch |e| return fail(name, "cold {s}", .{@errorName(e)});
    if (after != 2) return fail(name, "a cold instance lists {d} friends, want the 2 that were stored", .{after});
    var saw_gheed = false;
    var saw_charsi = false;
    for (names2[0..after]) |n| {
        if (std.mem.eql(u8, n, "Gheed")) saw_gheed = true;
        if (std.mem.eql(u8, n, "Charsi")) saw_charsi = true;
    }
    if (!saw_gheed or !saw_charsi) return fail(name, "cold instance listed '{s}'/'{s}', want Gheed and Charsi", .{ names2[0], names2[1] });

    // A friend who is actually in a channel should be reported as being there. This is the
    // only part of the friends feature a real 1.14d client can see, since it arrives as
    // chat text — the structured 0x65 reply is dropped by the client outright.
    var pal = rc.RealmClient{ .bnet_port = 21112, .d2cs_port = 21112 };
    defer pal.close();
    pal.connectBnet() catch |e| return fail(name, "pal {s}", .{@errorName(e)});
    pal.auth() catch |e| return fail(name, "pal {s}", .{@errorName(e)});
    pal.login("Gheed") catch |e| return fail(name, "pal {s}", .{@errorName(e)});
    pal.enterChat() catch |e| return fail(name, "pal {s}", .{@errorName(e)});
    pal.joinChannel("Diablo II") catch |e| return fail(name, "pal {s}", .{@errorName(e)});
    _ = net.usleep(150_000);

    c.chatCommand("/f list") catch |e| return fail(name, "{s}", .{@errorName(e)});
    var located = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const ev = c.readChatEvent() catch break;
        // Gheed also generates a channel-JOIN on this connection; only the INFO lines are
        // the /f list reply.
        if (ev.eid != rc.EID_INFO or !std.mem.eql(u8, ev.username, "Gheed")) continue;
        if (std.mem.indexOf(u8, ev.text, "Diablo II") != null) {
            located = true;
            break;
        }
        return fail(name, "/f list says Gheed is '{s}' — should name the channel they are in", .{ev.text});
    }
    if (!located) return fail(name, "/f list never reported where Gheed is", .{});

    return .{ .name = name, .status = .pass, .msg = msg("2 friends survive a cold instance; /f list places Gheed in his channel", .{}) };
}

// Two realmd instances (A, B) sharing one data dir (REALMD_SHARED) keep sessions
// in a shared store: a session minted on A's bnetd must resolve on B's d2cs.
// Instance A: bnet 16112 / health 16118.
// Instance B: 17112 / 17113 / 17114 / 17115 / 17118, SAME data dir, instance "B".
/// Chat across two realmd instances: a channel is the union of what every instance holds, or it
/// is not a channel. The failure this guards is silent — talk simply does not arrive, a whisper
/// says "that user is not logged on" about someone plainly online, and the user list shows half
/// the room with nothing to say it is half.
fn scChatAcrossInstances() Result {
    const name = "chat_across_instances";
    const bin = envOr("REALMD_BIN", "./zig-out/bin/realmd");
    const channel = "Diablo II";

    const envs_a = [_]EnvVar{
        .{ .name = "REALMD_INSTANCE", .value = "ChatA" },
        .{ .name = "REALMD_BNET_PORT", .value = "16112" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "16118" },
        .{ .name = "REALMD_GAME_PORT", .value = "0" },
        .{ .name = "REALMD_GAME_ADDR", .value = "127.0.0.1" },
    };
    const a_pid = spawnRealmd(bin, &envs_a, 16112) catch |e| return fail(name, "spawn A {s}", .{@errorName(e)});
    const envs_b = [_]EnvVar{
        .{ .name = "REALMD_INSTANCE", .value = "ChatB" },
        .{ .name = "REALMD_BNET_PORT", .value = "17112" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "17118" },
        .{ .name = "REALMD_GAME_PORT", .value = "0" },
        .{ .name = "REALMD_GAME_ADDR", .value = "127.0.0.1" },
    };
    const b_pid = spawnRealmd(bin, &envs_b, 17112) catch |e| {
        _ = kill(a_pid, 15);
        _ = waitpid(a_pid, null, 0);
        return fail(name, "spawn B {s}", .{@errorName(e)});
    };
    defer {
        _ = kill(a_pid, 15);
        _ = kill(b_pid, 15);
        _ = waitpid(a_pid, null, 0);
        _ = waitpid(b_pid, null, 0);
    }

    var a = rc.RealmClient{ .bnet_port = 16112, .d2cs_port = 16112 };
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login("CrossAlice") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterChatAs("AliceChar", "TypeGuru,AliceChar") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.joinChannel(channel) catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.setBnetTimeout(3000);

    // B joins second, on the OTHER instance, so its user list has to include someone it does not
    // hold. This is the part that silently showed an empty room.
    _ = net.usleep(200_000);
    var b = rc.RealmClient{ .bnet_port = 17112, .d2cs_port = 17112 };
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.login("CrossBob") catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.enterChat() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.joinChannel(channel) catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.setBnetTimeout(3000);

    var saw_alice = false;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const ev = b.readChatEvent() catch break;
        if (ev.eid == rc.EID_SHOWUSER and std.mem.eql(u8, ev.username, "AliceChar*CrossAlice")) {
            saw_alice = true;
            break;
        }
    }
    if (!saw_alice) return fail(name, "B's channel list did not include CrossAlice, who is on the other instance", .{});

    // Talk has to cross.
    _ = net.usleep(200_000);
    a.chatCommand("hello from A") catch |e| return fail(name, "A talk {s}", .{@errorName(e)});
    var heard = false;
    i = 0;
    while (i < 12) : (i += 1) {
        const ev = b.readChatEvent() catch break;
        if (ev.eid != rc.EID_TALK) continue;
        if (!std.mem.eql(u8, ev.text, "hello from A")) continue;
        heard = true;
        break;
    }
    if (!heard) return fail(name, "B never heard A's channel talk from the other instance", .{});

    // And a whisper has to find someone the sending instance has never seen.
    b.chatCommand("/w CrossAlice psst") catch |e| return fail(name, "B whisper {s}", .{@errorName(e)});
    var whispered = false;
    i = 0;
    while (i < 12) : (i += 1) {
        const ev = a.readChatEvent() catch break;
        if (ev.eid == rc.EID_ERROR) return fail(name, "whisper across instances refused: {s}", .{ev.text});
        if (ev.eid != rc.EID_WHISPER) continue;
        if (!std.mem.eql(u8, ev.text, "psst")) continue;
        whispered = true;
        break;
    }
    if (!whispered) return fail(name, "A never received the whisper B sent from the other instance", .{});

    // By the CHARACTER, which is what a player types and only the instance holding it can resolve.
    b.chatCommand("/w AliceChar again") catch |e| return fail(name, "B whisper {s}", .{@errorName(e)});
    whispered = false;
    i = 0;
    while (i < 12) : (i += 1) {
        const ev = a.readChatEvent() catch break;
        if (ev.eid == rc.EID_ERROR) return fail(name, "whisper to a character across instances refused: {s}", .{ev.text});
        if (ev.eid == rc.EID_WHISPER and std.mem.eql(u8, ev.text, "again")) {
            whispered = true;
            break;
        }
    }
    if (!whispered) return fail(name, "A never received the whisper addressed to its character from the other instance", .{});

    return .{ .name = name, .status = .pass, .msg = msg("one channel across two instances: user list, talk and whisper (by account and by character) all cross", .{}) };
}

fn scMultiInstance() Result {
    const name = "multi_instance";
    const bin = envOr("REALMD_BIN", "./zig-out/bin/realmd");

    // Shared data dir, fresh each run (isolation: accounts/sessions persist on fs).
    const data_dir = "/tmp/e2e-realmd-shared";
    var rmbuf: [256]u8 = undefined;
    if (std.fmt.bufPrintZ(&rmbuf, "rm -rf {s}", .{data_dir})) |cmd| {
        _ = system(cmd.ptr);
    } else |_| {}
    _ = mkdir(data_dir, 0o755);

    const envs_a = [_]EnvVar{
        .{ .name = "REALMD_SHARED", .value = "1" },
        .{ .name = "REALMD_INSTANCE", .value = "A" },
        .{ .name = "REALMD_DATA_DIR", .value = data_dir },
        .{ .name = "REALMD_BNET_PORT", .value = "16112" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "16118" },
        .{ .name = "REALMD_GAME_PORT", .value = "0" }, // no embedded edge (avoid 14001 clash)
        .{ .name = "REALMD_GAME_ADDR", .value = "127.0.0.1" },
    };
    const a_pid = spawnRealmd(bin, &envs_a, 16112) catch |e| return fail(name, "spawn A {s}", .{@errorName(e)});

    const envs_b = [_]EnvVar{
        .{ .name = "REALMD_SHARED", .value = "1" },
        .{ .name = "REALMD_INSTANCE", .value = "B" },
        .{ .name = "REALMD_DATA_DIR", .value = data_dir },
        .{ .name = "REALMD_BNET_PORT", .value = "17112" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "17118" },
        .{ .name = "REALMD_GAME_PORT", .value = "0" }, // no embedded edge (avoid 14001 clash)
        .{ .name = "REALMD_GAME_ADDR", .value = "127.0.0.1" },
    };
    const b_pid = spawnRealmd(bin, &envs_b, 17112) catch |e| {
        _ = kill(a_pid, 15);
        _ = waitpid(a_pid, null, 0);
        return fail(name, "spawn B {s}", .{@errorName(e)});
    };
    defer {
        _ = kill(a_pid, 15);
        _ = kill(b_pid, 15);
        _ = waitpid(a_pid, null, 0);
        _ = waitpid(b_pid, null, 0);
    }

    // One fake GS, published into the shared store. It belongs to neither instance — that is the
    // point: both see it, and either can place a game on it.
    var gs = FakeGS{ .gsid = 0x9999, .ip = .{ 127, 0, 0, 1 }, .gameid = 77 };
    gs.start(2000) catch |e| return fail(name, "FakeGS {s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not publish itself", .{});

    // Mint a session on instance A (bnetd 16112 -> d2cs handoff lives in shared store).
    var a = rc.RealmClient{ .bnet_port = 16112, .d2cs_port = 16112 };
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login("MultiInst") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterRealm() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    if (a.sessionId() < 1) return fail(name, "A minted no session", .{});

    // Resolve A's session on instance B's d2cs (17113). Copy A's session fields
    // into B's client so its STARTUP carries A's cookie/status/lo/hi/account.
    var b = rc.RealmClient{ .bnet_port = 17112, .d2cs_port = 17112 };
    defer b.close();
    b.cookie = a.cookie;
    b.status = a.status;
    b.lo = a.lo;
    b.hi = a.hi;
    b.account = a.account;
    b.connectD2cs() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    const su = b.startup() catch |e| return fail(name, "B startup {s}", .{@errorName(e)});
    if (su != 0) return fail(name, "B failed to resolve A's session (startup result=0x{x})", .{su});

    // Cloud-native game visibility: a game created through instance A must be listable
    // through instance B — both enumerate the same shared ephemeral store. Create on A...
    a.connectD2cs() catch |e| return fail(name, "A d2cs {s}", .{@errorName(e)});
    if ((a.startup() catch 1) != 0) return fail(name, "A d2cs startup failed", .{});
    const cg = a.createGame("fleetgame", "d") catch |e| return fail(name, "A create {s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "A create result={d}", .{cg.result});
    // ...and confirm B's admin API lists it (shared-store snapshotGames, not A's memory).
    var rxbuf: [16384]u8 = undefined;
    const lg = net.httpRequest(17118, "GET", "/admin/games", ADMIN_TOKEN, "", &rxbuf) catch |e| return fail(name, "B admin games {s}", .{@errorName(e)});
    if (lg.status != 200) return fail(name, "B admin games status={d}", .{lg.status});
    if (std.mem.indexOf(u8, lg.body, "fleetgame") == null)
        return fail(name, "game created on A is NOT visible via B's /admin/games (shared enumeration broken)", .{});

    return .{ .name = name, .status = .pass, .msg = msg("session minted on A resolved on B; game created on A listed via B's /admin/games (fleet-wide)", .{}) };
}

// A tiny echo TCP server standing in for a real backend GS :4000 game port. Binds an
// ephemeral port (read via getsockname), accepts in a loop, one thread per connection,
// echoing what it reads. Looping (not one-shot) matters: d2ingress opens a throwaway
// port-probe connection first, so the real test connection still needs its own accept.
// `got`/`got_len` capture the first non-empty payload so the scenario can assert delivery.
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });
const c_write = @extern(*const fn (c_int, [*]const u8, usize) callconv(.c) isize, .{ .name = "write" });

const EchoServer = struct {
    listen_fd: c_int = -1,
    port: u16 = 0,
    thread: ?std.Thread = null,
    got: [256]u8 = undefined,
    got_len: usize = 0,
    // When set, each accepted conn opens with a 2-byte 0xAF00 greeting BEFORE it starts
    // echoing — mimicking the real 1.14d engine's leading connection-established frame that
    // d2ingress must strip (stripGsGreeting). Lets a scenario prove the strip end-to-end.
    send_greeting: bool = false,

    fn start(self: *EchoServer) !void {
        const fd = socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        const one: c_int = 1;
        _ = setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one, @sizeOf(c_int));
        var addr = std.mem.zeroes(posix.sockaddr.in);
        addr.family = posix.AF.INET;
        addr.port = 0; // ephemeral
        addr.addr = std.mem.nativeToBig(u32, 0x7f00_0001); // 127.0.0.1
        if (@hasField(posix.sockaddr.in, "len")) addr.len = @sizeOf(posix.sockaddr.in);
        if (bind(fd, &addr, @sizeOf(posix.sockaddr.in)) != 0) return error.BindFailed;
        if (listen(fd, 8) != 0) return error.ListenFailed;
        var sn = std.mem.zeroes(posix.sockaddr.in);
        var l: c_uint = @sizeOf(posix.sockaddr.in);
        if (getsockname(fd, &sn, &l) != 0) return error.SockNameFailed;
        self.listen_fd = fd;
        self.port = std.mem.bigToNative(u16, sn.port);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    // Accept forever; each connection echoed on a detached thread. The loop ends when
    // stop() closes the listen fd and accept() errors.
    fn acceptLoop(self: *EchoServer) void {
        while (true) {
            const cfd = accept(self.listen_fd, null, null);
            if (cfd < 0) return;
            const t = std.Thread.spawn(.{}, echoConn, .{ self, cfd }) catch {
                _ = cclose(cfd);
                continue;
            };
            t.detach();
        }
    }

    fn echoConn(self: *EchoServer, cfd: c_int) void {
        defer _ = cclose(cfd);
        if (self.send_greeting) {
            const greeting = [2]u8{ 0xAF, 0x00 }; // the leading frame d2ingress must strip
            _ = c_write(cfd, &greeting, greeting.len);
        }
        var buf: [256]u8 = undefined;
        while (true) {
            const n = c_read(cfd, &buf, buf.len);
            if (n <= 0) return;
            const un: usize = @intCast(n);
            // Accumulate the captured payload (across short reads) so a fragmented first
            // packet still lands fully in `got` for the scenario's byte assertions.
            const cur = @atomicLoad(usize, &self.got_len, .seq_cst);
            if (cur < self.got.len) {
                const room = self.got.len - cur;
                const take = @min(un, room);
                @memcpy(self.got[cur..][0..take], buf[0..take]);
                @atomicStore(usize, &self.got_len, cur + take, .seq_cst);
            }
            _ = c_write(cfd, &buf, un); // echo back
        }
    }

    fn received(self: *EchoServer) []const u8 {
        const n = @atomicLoad(usize, &self.got_len, .seq_cst);
        return self.got[0..n];
    }

    fn stop(self: *EchoServer) void {
        if (self.listen_fd >= 0) _ = cclose(self.listen_fd);
        if (self.thread) |t| t.join();
        self.thread = null;
    }
};

/// fork+execve the d2ingress binary (REALMD_D2INGRESS_BIN, default ./zig-out/bin/d2ingress).
/// It reads token routes from redis (REALMD_REDIS_ADDR, inherited from startStores) — the
/// same redis realmd writes them to — and listens on REALMD_INGRESS_PORT. Waits up to 10s for
/// the port; exits the harness if it never comes up. Mirrors spawnRealmd.
fn spawnD2ingress(ingress_port: u16) !c_int {
    const bin = envOr("REALMD_D2INGRESS_BIN", "./zig-out/bin/d2ingress");
    const data_dir = envOr("REALMD_DATA_DIR", "/tmp/e2e-realmd");
    var pbuf: [8]u8 = undefined;
    const portz = std.fmt.bufPrintZ(&pbuf, "{d}", .{ingress_port}) catch return error.BadPort;
    _ = setenv("REALMD_DATA_DIR", data_dir, 1);
    _ = setenv("REALMD_INGRESS_PORT", portz.ptr, 1);
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{bin.ptr};
        _ = execve(bin.ptr, &argv, environ);
        std.process.exit(127);
    }
    if (!waitPort(ingress_port, 10_000)) {
        _ = kill(pid, 9);
        std.debug.print("ERROR: d2ingress did not start listening on {d} in time.\n", .{ingress_port});
        std.process.exit(2);
    }
    return pid;
}

// Token-offset of the u16 game token in the crafted GAMELOGON (0x68), matching the
// d2ingress's TOKEN_OFFSET: nId(u8) ++ nGameHash(u32) ++ nGameToken(u16) → byte 5.
const INGRESS_TOKEN_OFFSET: usize = 5;

// Prove the NAT-proof gateway path: realmd mints a globally-unique token on JOIN, d2ingress
// rewrites the in-packet token to the GS's real gameid, then splices to the right backend.
//   1. echo server stands in for the backend GS game port (ephemeral port P), captures the
//      first packet so we can assert the rewritten token.
//   2. FakeGS registers with ip=127.0.0.1 / gs_port=P and a known gameid=3.
//   3. client create+joins — realmd records {token T -> 127.0.0.1:P, gameid 3}, returns T.
//   4. spawn d2ingress on :14000, pointed at the same redis realmd wrote the route to.
//   5. connect to :14000, send GAMELOGON buf[0]=0x68, token T @offset 5, tail "PAYLOAD".
//      Assert echo got byte[0]==0x68, u16@5==3 (rewrite proof), tail matches (splice proof).
fn scD2ingressTokenTranslate() Result {
    const name = "d2ingress_token_translate";
    const INGRESS_PORT: u16 = 14000;
    const GS_GAMEID: u32 = 3;

    // Greeting ON: the echo backend opens with 0xAF00 (like the real engine), so this
    // scenario also proves d2ingress STRIPS the GS greeting — if it didn't, the client's
    // first post-handshake byte would be 0xAF, not the echoed 0x68 packet (assert below).
    var echo = EchoServer{ .send_greeting = true };
    echo.start() catch |e| return fail(name, "echo start {s}", .{@errorName(e)});
    defer echo.stop();

    var gs = FakeGS{ .gsid = 0x9999, .ip = .{ 127, 0, 0, 1 }, .gs_port = echo.port, .maxgame = 10, .gameid = GS_GAMEID };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("IngressGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const cg = c.createGame("ingressgame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    // The join mints a unique token and records {token -> 127.0.0.1:echo.port, gameid 3}.
    const jg = c.joinGame("ingressgame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (jg.result != 0) return fail(name, "join result={d}", .{jg.result});
    const token = jg.token; // realm-global token the d2ingress will translate
    if (token == 0) return fail(name, "join returned token=0 (expected a minted token)", .{});

    const ingress_pid = spawnD2ingress(INGRESS_PORT) catch |e| return fail(name, "spawn d2ingress {s}", .{@errorName(e)});
    defer {
        _ = kill(ingress_pid, 15);
        _ = waitpid(ingress_pid, null, 0);
    }

    // Craft a GAMELOGON: id 0x68, gameHash u32, the minted token at offset 5, tail PAYLOAD.
    const tail = "PAYLOAD";
    var logon: [INGRESS_TOKEN_OFFSET + 2 + tail.len]u8 = undefined;
    @memset(&logon, 0);
    logon[0] = 0x68;
    std.mem.writeInt(u16, logon[INGRESS_TOKEN_OFFSET..][0..2], token, .little);
    @memcpy(logon[INGRESS_TOKEN_OFFSET + 2 ..][0..tail.len], tail);

    const fd = net.connectLocal(INGRESS_PORT) catch |e| return fail(name, "connect d2ingress {s}", .{@errorName(e)});
    defer net.closeSocket(fd);

    // On accept the d2ingress speaks for the not-yet-dialled GS and sends a 2-byte 0xAF00
    // connection-established handshake (real D2GS setup; see main.zig accept loop). Consume
    // it before the echoed game packet, or it shifts every later byte by two.
    var hs: [2]u8 = undefined;
    net.readFull(fd, &hs) catch |e| return fail(name, "no 0xAF00 handshake ({s})", .{@errorName(e)});
    if (hs[0] != 0xaf or hs[1] != 0x00) return fail(name, "handshake={x:0>2}{x:0>2}, want af00", .{ hs[0], hs[1] });

    net.writeAll(fd, &logon) catch |e| return fail(name, "send {s}", .{@errorName(e)});

    // The d2ingress replays the (rewritten) packet to the echo backend, which echoes it —
    // AFTER opening with a 0xAF00 greeting that d2ingress must strip. So the first byte we read here
    // is the echoed 0x68 packet; a 0xAF would mean the GS-greeting strip failed to remove it.
    var back: [logon.len]u8 = undefined;
    net.readFull(fd, &back) catch |e| return fail(name, "no echo back through d2ingress ({s})", .{@errorName(e)});
    if (back[0] == 0xaf) return fail(name, "GS greeting NOT stripped — client got 0xAF as first game byte", .{});

    // Backend must have seen the rewritten packet: id 0x68, token now == GS gameid 3, tail intact.
    var waited: u32 = 0;
    while (echo.received().len < logon.len and waited < 1000) : (waited += 20) _ = net.usleep(20_000);
    const got = echo.received();
    if (got.len < logon.len) return fail(name, "backend saw {d} bytes, want {d}", .{ got.len, logon.len });
    if (got[0] != 0x68) return fail(name, "backend first byte 0x{x:0>2}, want 0x68", .{got[0]});
    const got_token = std.mem.readInt(u16, got[INGRESS_TOKEN_OFFSET..][0..2], .little);
    if (got_token != @as(u16, @truncate(GS_GAMEID)))
        return fail(name, "rewritten token={d}, want {d} (GS gameid)", .{ got_token, GS_GAMEID });
    if (!std.mem.eql(u8, got[INGRESS_TOKEN_OFFSET + 2 ..][0..tail.len], tail))
        return fail(name, "tail '{s}', want '{s}'", .{ got[INGRESS_TOKEN_OFFSET + 2 ..][0..tail.len], tail });
    if (back[0] != 0x68 or std.mem.readInt(u16, back[INGRESS_TOKEN_OFFSET..][0..2], .little) != @as(u16, @truncate(GS_GAMEID)))
        return fail(name, "echoed packet not the rewritten one", .{});

    return .{ .name = name, .status = .pass, .msg = msg("token 0x{x} translated to gameid {d}, packet rewritten + spliced to backend :{d}", .{ token, GS_GAMEID, echo.port }) };
}

// Same token-translate splice as the d2ingress test, but through realmd's EMBEDDED game
// edge (gameedge.zig) instead of a standalone d2ingress — proves the lightweight single-
// binary path: in-process route lookup + thread-per-conn splice. Runs in a DEDICATED
// realmd instance (sharing the redis store) because the embedded edge and a standalone
// d2ingress are mutually-exclusive deploy modes — we don't want both in one process.
fn scEmbeddedGameEdge() Result {
    const name = "embedded_game_edge";
    const EDGE_PORT: u16 = 14001;
    const GS_GAMEID: u32 = 5;
    const bin = envOr("REALMD_BIN", "./zig-out/bin/realmd");

    const data_dir = "/tmp/e2e-realmd-edge";
    var rmbuf: [256]u8 = undefined;
    if (std.fmt.bufPrintZ(&rmbuf, "rm -rf {s}", .{data_dir})) |cmd| {
        _ = system(cmd.ptr);
    } else |_| {}
    _ = mkdir(data_dir, 0o755);
    const envs = [_]EnvVar{
        .{ .name = "REALMD_SHARED", .value = "1" },
        .{ .name = "REALMD_INSTANCE", .value = "E" },
        .{ .name = "REALMD_DATA_DIR", .value = data_dir },
        .{ .name = "REALMD_BNET_PORT", .value = "18112" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "18118" },
        .{ .name = "REALMD_GAME_PORT", .value = "14001" }, // the embedded edge under test
        .{ .name = "REALMD_GAME_ADDR", .value = "127.0.0.1" },
    };
    const pid = spawnRealmd(bin, &envs, 18112) catch |e| return fail(name, "spawn edge realmd {s}", .{@errorName(e)});
    defer {
        _ = kill(pid, 15);
        _ = waitpid(pid, null, 0);
    }
    if (!waitPort(EDGE_PORT, 5000)) return fail(name, "embedded edge never bound :{d}", .{EDGE_PORT});

    var echo = EchoServer{};
    echo.start() catch |e| return fail(name, "echo start {s}", .{@errorName(e)});
    defer echo.stop();

    var gs = FakeGS{ .gsid = 0x8888, .ip = .{ 127, 0, 0, 1 }, .gs_port = echo.port, .maxgame = 10, .gameid = GS_GAMEID };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    var c = rc.RealmClient{ .bnet_port = 18112, .d2cs_port = 18112 };
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("EdgeGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const cg = c.createGame("edgegame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    const jg = c.joinGame("edgegame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (jg.result != 0) return fail(name, "join result={d}", .{jg.result});
    const token = jg.token;
    if (token == 0) return fail(name, "join returned token=0", .{});

    // Craft a GAMELOGON with the minted token, then drive it through realmd's edge.
    const tail = "PAYLOAD";
    var logon: [INGRESS_TOKEN_OFFSET + 2 + tail.len]u8 = undefined;
    @memset(&logon, 0);
    logon[0] = 0x68;
    std.mem.writeInt(u16, logon[INGRESS_TOKEN_OFFSET..][0..2], token, .little);
    @memcpy(logon[INGRESS_TOKEN_OFFSET + 2 ..][0..tail.len], tail);

    const fd = net.connectLocal(EDGE_PORT) catch |e| return fail(name, "connect edge {s}", .{@errorName(e)});
    defer net.closeSocket(fd);

    var hs: [2]u8 = undefined;
    net.readFull(fd, &hs) catch |e| return fail(name, "no 0xAF00 handshake ({s})", .{@errorName(e)});
    if (hs[0] != 0xaf or hs[1] != 0x00) return fail(name, "handshake={x:0>2}{x:0>2}, want af00", .{ hs[0], hs[1] });

    net.writeAll(fd, &logon) catch |e| return fail(name, "send {s}", .{@errorName(e)});

    var back: [logon.len]u8 = undefined;
    net.readFull(fd, &back) catch |e| return fail(name, "no echo back through edge ({s})", .{@errorName(e)});

    var waited: u32 = 0;
    while (echo.received().len < logon.len and waited < 1000) : (waited += 20) _ = net.usleep(20_000);
    const got = echo.received();
    if (got.len < logon.len) return fail(name, "backend saw {d} bytes, want {d}", .{ got.len, logon.len });
    if (got[0] != 0x68) return fail(name, "backend first byte 0x{x:0>2}, want 0x68", .{got[0]});
    const got_token = std.mem.readInt(u16, got[INGRESS_TOKEN_OFFSET..][0..2], .little);
    if (got_token != @as(u16, @truncate(GS_GAMEID)))
        return fail(name, "rewritten token={d}, want {d} (GS gameid)", .{ got_token, GS_GAMEID });
    if (!std.mem.eql(u8, got[INGRESS_TOKEN_OFFSET + 2 ..][0..tail.len], tail))
        return fail(name, "tail mismatch", .{});

    return .{ .name = name, .status = .pass, .msg = msg("embedded edge: token 0x{x} -> gameid {d}, rewritten + spliced (no d2ingress)", .{ token, GS_GAMEID }) };
}

/// Accounts these scenarios create, and therefore have to be able to create.
///
/// The suite used to be re-runnable only because the filesystem data dir was wiped between runs.
/// Against a store that actually persists — Postgres — the second run met its own accounts and
/// every create failed as "exists". Clearing them here makes a run independent of what the last
/// one left, whatever the store is.
const fixture_accounts = [_][]const u8{
    "AdminMade", "AuthUser", "CopyAcct",
};

/// Characters a scenario expects to create, so a leftover must not be there to collide with.
/// Named separately from the accounts because these belong to accounts the suite never creates —
/// they are staged straight into the store.
const fixture_chars = [_]struct { account: []const u8, char: []const u8 }{
    .{ .account = "CopyAcct", .char = "CopyCat" },
};

fn resetFixtures() void {
    var rxbuf: [4096]u8 = undefined;
    for (fixture_accounts) |acct| {
        var json: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&json, "{{\"name\":\"{s}\"}}", .{acct}) catch continue;
        _ = net.httpRequest(HEALTH_PORT, "POST", "/admin/accounts/delete", ADMIN_TOKEN, body, &rxbuf) catch continue;
    }
    for (fixture_chars) |fc| {
        var json: [160]u8 = undefined;
        const body = std.fmt.bufPrint(&json, "{{\"account\":\"{s}\",\"char\":\"{s}\"}}", .{ fc.account, fc.char }) catch continue;
        _ = net.httpRequest(HEALTH_PORT, "POST", "/admin/chars/delete", ADMIN_TOKEN, body, &rxbuf) catch continue;
    }
}

/// `E2E_ONLY=scName[,scName...]` runs just those scenarios; the rest report as skipped.
fn only(comptime id: []const u8, comptime run: fn () Result) Result {
    const want = envOr("E2E_ONLY", "");
    if (want.len == 0) return run();
    var it = std.mem.splitScalar(u8, want, ',');
    while (it.next()) |w| if (std.mem.eql(u8, std.mem.trim(u8, w, " "), id)) return run();
    return .{ .name = id, .status = .skip, .msg = "not in E2E_ONLY" };
}

pub fn main() !void {
    // A whole run can be moved off the default ports. Without this, a stray realm server
    // on 6112 quietly becomes the system under test.
    const port_base = std.fmt.parseInt(u16, envOr("E2E_PORT_BASE", "0"), 10) catch 0;
    if (port_base != 0) {
        rc.setPortBase(port_base);
        HEALTH_PORT = port_base + 1968; // keeps the usual 6112 -> 18080 relationship
        std.debug.print("port base overridden: bnet={d} health={d}\n", .{ rc.HOST_BNET, HEALTH_PORT });
    }
    startStores();
    const child = try maybeStartRealmd();
    resetFixtures();

    const results = [_]Result{
        only("scLogin", scLogin),
        only("scMcpOn6112", scMcpOn6112),
        only("scCharListStatstring", scCharListStatstring),
        only("scCreateJoinGame", scCreateJoinGame),
        only("scSaveAccountKey", scSaveAccountKey),
        only("scDeleteInGame", scDeleteInGame),
        only("scSaveFence", scSaveFence),
        only("scRealmUniqueNames", scRealmUniqueNames),
        only("scGamePopulation", scGamePopulation),
        only("scSeatReleasedOnLeave", scSeatReleasedOnLeave),
        only("scUnconfirmedJoinRetaken", scUnconfirmedJoinRetaken),
        only("scJoinErrors", scJoinErrors),
        only("scGameMaxPlayers", scGameMaxPlayers),
        only("scGameInfo", scGameInfo),
        only("scFleetCapacity", scFleetCapacity),
        only("scRefusedServerFallsBack", scRefusedServerFallsBack),
        only("scSilentServerFallsBack", scSilentServerFallsBack),
        only("scAdminApi", scAdminApi),
        only("scMultiGameOneGs", scMultiGameOneGs),
        only("scD2ingressTokenTranslate", scD2ingressTokenTranslate),
        only("scEmbeddedGameEdge", scEmbeddedGameEdge),
        only("scCreateAccountRealAuth", scCreateAccountRealAuth),
        only("scCharCreate", scCharCreate),
        only("scCreateCharThenGame", scCreateCharThenGame),
        only("scRejectedLogonGated", scRejectedLogonGated),
        only("scCharVersion", scCharVersion),
        only("scClassicChar", scClassicChar),
        only("scLadder", scLadder),
        only("scLadderExperience", scLadderExperience),
        only("scCharUpgrade", scCharUpgrade),
        only("scCharDelete", scCharDelete),
        only("scCharCopy", scCharCopy),
        only("scLobbyChatAtoB", scLobbyChatAtoB),
        only("scLobbyCharNames", scLobbyCharNames),
        only("scLobbyCharNamedLikeAccount", scLobbyCharNamedLikeAccount),
        only("scLobbyChatEvents", scLobbyChatEvents),
        only("scChatCommands", scChatCommands),
        only("scConcurrentClients", scConcurrentClients),
        only("scFriendsListLoad", scFriendsListLoad),
        only("scNameResolution", scNameResolution),
        only("scLeaveChannel", scLeaveChannel),
        only("scDifficultyGate", scDifficultyGate),
        only("scClassicGameFlags", scClassicGameFlags),
        only("scHardcoreGameFlags", scHardcoreGameFlags),
        only("scLadderGameFlags", scLadderGameFlags),
        only("scNonLadderGameFlags", scNonLadderGameFlags),
        only("scGameListFiltered", scGameListFiltered),
        only("scJoinWrongKind", scJoinWrongKind),
        only("scGetFileTime", scGetFileTime),
        only("scBannerAd", scBannerAd),
        only("scSaveDurability", scSaveDurability),
        only("scFriendsPersist", scFriendsPersist),
        only("scChatAcrossInstances", scChatAcrossInstances),
        only("scMultiInstance", scMultiInstance),
    };

    if (child) |pid| {
        _ = kill(pid, 15); // SIGTERM
        _ = waitpid(pid, null, 0);
    }
    stopStores();

    var npass: u32 = 0;
    var nfail: u32 = 0;
    var nskip: u32 = 0;
    for (results) |r| {
        const tag = switch (r.status) {
            .pass => "PASS",
            .fail => "FAIL",
            .skip => "SKIP",
        };
        std.debug.print("[{s}] {s}: {s}\n", .{ tag, r.name, r.msg });
        switch (r.status) {
            .pass => npass += 1,
            .fail => nfail += 1,
            .skip => nskip += 1,
        }
    }
    std.debug.print("\nsummary: {d} passed, {d} failed, {d} skipped ({d} total)\n", .{ npass, nfail, nskip, results.len });
    if (nfail != 0) std.process.exit(1);
}

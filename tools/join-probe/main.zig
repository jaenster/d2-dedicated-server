//! join-probe - one clientless player: log on as an account, pick (or make) a character, create a game the way the
//! client does and stay in it, reporting whether the server put the player in.
//!
//!     zig build join-probe -- --host H --account A --char C [--class N] [--stay S] [--make]
//!
//! With --make the account and the character are made when missing (class 0 Amazon .. 6 Assassin). The exit code
//! is 0 when the player was in the game for the whole stay.
const std = @import("std");
const realm = @import("d2-realm");
const session = @import("d2-session");
const Session = session.Session;

extern "c" fn usleep(usec: c_uint) c_int;

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var host: []const u8 = "127.0.0.1";
    var bnet_port: u16 = 6112;
    var gs_port: u16 = 4000;
    var account: []const u8 = "";
    var cname: []const u8 = "";
    var class: u8 = 1;
    var stay: i64 = 60;
    var make = false;
    var verbose = false;
    var args = init.args.iterate();
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--make")) {
            make = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
            continue;
        }
        const v = args.next() orelse return error.MissingValue;
        if (std.mem.eql(u8, a, "--host")) host = v else if (std.mem.eql(u8, a, "--gs-port")) gs_port = try std.fmt.parseInt(u16, v, 10) else if (std.mem.eql(u8, a, "--bnet-port")) bnet_port = try std.fmt.parseInt(u16, v, 10) else if (std.mem.eql(u8, a, "--account")) account = v else if (std.mem.eql(u8, a, "--char")) cname = v else if (std.mem.eql(u8, a, "--class")) class = try std.fmt.parseInt(u8, v, 10) else if (std.mem.eql(u8, a, "--stay")) stay = try std.fmt.parseInt(i64, v, 10);
    }
    var r = try realm.Realm.connect(gpa, .{ .host = host, .port = bnet_port, .log = verbose, .product = "D2XP" });
    defer r.deinit();
    if (make) _ = r.createAccount(account, "x") catch false;
    try r.login(account, "x");
    try r.enterRealm(null);
    const ch = r.chooseCharacter(cname) catch |e| blk: {
        if (!make) return e;
        _ = try r.createCharacter(cname, class, true);
        break :blk try r.chooseCharacter(cname);
    };
    std.debug.print("character {s} class {d} chosen\n", .{ ch.name(), ch.class });
    var gn: [16]u8 = undefined;
    const gname = try std.mem.print(&gn, "jp{d}", .{@mod(session.nowMs(), 100000)});
    _ = try r.createGame(.{ .name = gname });
    const ticket = try r.joinGame(gname, "");
    var s = try Session.open(gpa, .{ .host = host, .port = gs_port, .game_id = ticket.token, .game_hash = ticket.hash, .character = ch.name(), .char_class = ch.class });
    defer s.deinit();
    s.waitUntilInGame(20000) catch |e| {
        if (s.refused) |said| std.debug.print("refused: {s}\n", .{said.describe()});
        std.debug.print("FAIL not in game: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("in game, staying {d}s\n", .{stay});
    const start = session.nowMs();
    const end = start + stay * 1000;
    while (session.nowMs() < end) {
        const t = s.pump(50) catch |e| {
            std.debug.print("FAIL pump: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        if (t.eof) {
            std.debug.print("FAIL disconnected after {d}ms\n", .{session.nowMs() - start});
            std.process.exit(1);
        }
    }
    std.debug.print("PASS {s}/{s} stayed {d}s in {s}\n", .{ account, ch.name(), stay, gname });
    s.leave();
    _ = usleep(2500 * 1000);
}

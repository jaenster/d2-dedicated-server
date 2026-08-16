//! FakeGS — a stand-in game server, for testing realmd without wine or Game.exe.
//!
//! It does what a real one does now: publishes its own record into the shared store, drains its
//! request queue there, answers create/join on the reply key named by the request's seq, and
//! reports players entering and leaving as events. realmd is never dialled — there is nothing to
//! dial — so this also stands in for the fleet an instance holds no connection to, which is the
//! whole point of the arrangement.
const std = @import("std");
const net = @import("net.zig");
const gsstore = @import("gsstore.zig");
const rc = @import("realmclient.zig");

/// Where the harness's redis is. Set once by main before any FakeGS starts.
pub var redis_port: u16 = 6399;

pub const FakeGS = struct {
    gsid: u32 = 0xABCD,
    ip: [4]u8 = .{ 127, 0, 0, 1 },
    gs_port: u16 = 4000,
    maxgame: u32 = 100,
    gameid: u32 = 42,
    next_gameid: ?u32 = null, // if set, hand out incrementing ids
    /// Answer every create with this instead of success. 0 = accept.
    refuse_create_with: u32 = 0,

    registered: bool = false,
    creates: u32 = 0,
    joins: u32 = 0,
    stop_flag: bool = false,
    thread: ?std.Thread = null,
    _next: u32 = 0,
    /// The event connection, separate from the queue thread's. A real server reports from its
    /// engine tick while its queue thread may be mid-request, and one connection shared between
    /// them desyncs — the second caller reads the first one's reply.
    ev: ?gsstore.Client = null,
    ev_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn key(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
    }

    fn publish(self: *FakeGS, c: *gsstore.Client, live: u32) !void {
        var kb: [64]u8 = undefined;
        const k = key(&kb, "realmd:gs:{x}", .{self.gsid});
        var v: [15]u8 = undefined;
        @memcpy(v[0..4], &self.ip);
        std.mem.writeInt(u16, v[4..6], self.gs_port, .little);
        std.mem.writeInt(u32, v[6..10], self.maxgame, .little);
        std.mem.writeInt(u32, v[10..14], live, .little);
        v[14] = 0; // not full
        _ = try c.cmd(&.{ "SET", k, &v, "PX", "90000" });
        var ib: [16]u8 = undefined;
        _ = try c.cmd(&.{ "SADD", "realmd:gs", key(&ib, "{x}", .{self.gsid}) });
    }

    fn run(self: *FakeGS) void {
        var c = gsstore.Client.connect(redis_port) catch return;
        defer c.close();
        var e = gsstore.Client.connect(redis_port) catch return;
        self.ev = e;
        if (self.next_gameid) |n| self._next = n;

        self.publish(&c, 0) catch return;
        // A server that just started hosts nothing, so realmd must drop whatever still names it.
        var boot: [16]u8 = undefined;
        std.mem.writeInt(u16, boot[0..2], 16, .little);
        std.mem.writeInt(u16, boot[2..4], rc.GS_ADDRINFO, .little);
        std.mem.writeInt(u32, boot[4..8], 1, .little);
        std.mem.writeInt(u32, boot[8..12], self.maxgame, .little);
        std.mem.writeInt(u32, boot[12..16], self.gsid, .little);
        _ = e.cmd(&.{ "RPUSH", "realmd:gsev", boot[0..16] }) catch {};
        @atomicStore(bool, &self.registered, true, .seq_cst);

        var qk: [64]u8 = undefined;
        const queue = key(&qk, "realmd:gsq:{x}", .{self.gsid});
        var live: u32 = 0;
        while (!self.stop_flag) {
            const rep = c.cmd(&.{ "LPOP", queue }) catch break;
            const packet = switch (rep) {
                .bulk => |b| b orelse {
                    _ = net.usleep(5_000);
                    continue;
                },
                else => {
                    _ = net.usleep(5_000);
                    continue;
                },
            };
            if (packet.len < 8) continue;
            var buf: [1024]u8 = undefined;
            const n = @min(packet.len, buf.len);
            @memcpy(buf[0..n], packet[0..n]);
            const typ = std.mem.readInt(u16, buf[2..4], .little);
            const seq = std.mem.readInt(u32, buf[4..8], .little);

            var result: u32 = 0;
            var gid = self.gameid;
            if (typ == rc.GS_CREATEGAME) {
                self.creates += 1;
                if (self.refuse_create_with != 0) {
                    result = self.refuse_create_with;
                    gid = 0;
                } else {
                    if (self.next_gameid != null) {
                        gid = self._next;
                        self._next += 1;
                    }
                    live += 1;
                    self.publish(&c, live) catch {};
                }
            } else if (typ == rc.GS_JOINGAME) {
                self.joins += 1;
            } else continue;

            var reply: [16]u8 = undefined;
            std.mem.writeInt(u16, reply[0..2], 16, .little);
            std.mem.writeInt(u16, reply[2..4], @intCast(typ), .little);
            std.mem.writeInt(u32, reply[4..8], seq, .little);
            std.mem.writeInt(u32, reply[8..12], result, .little);
            std.mem.writeInt(u32, reply[12..16], gid, .little);
            var rk: [64]u8 = undefined;
            const rkey = key(&rk, "realmd:gsreply:{x}", .{seq});
            _ = c.cmdBig(&.{ "SET", rkey }, reply[0..16]) catch break;
            _ = c.cmd(&.{ "PEXPIRE", rkey, "30000" }) catch break;
        }
    }

    fn evLock(self: *FakeGS) void {
        while (self.ev_lock.swap(true, .acquire)) _ = net.usleep(200);
    }

    fn evUnlock(self: *FakeGS) void {
        self.ev_lock.store(false, .release);
    }

    /// Report a game's population the way a real GS does on player enter/leave:
    /// an absolute count, not a delta. `joined` only tags which edge caused it.
    pub fn sendUpdateGameInfo(self: *FakeGS, gameid: u32, players: u32, joined: bool) !void {
        try self.sendPlayerUpdate(gameid, players, joined, "", 0, 0);
    }

    /// The full form: the character the change happened to rides along, which is how
    /// realmd learns who is in a game at all.
    pub fn sendPlayerUpdate(self: *FakeGS, gameid: u32, players: u32, joined: bool, char: []const u8, level: u32, class: u32) !void {
        var b: [96]u8 = undefined;
        var w = net.Writer.init(b[8..]);
        w.u32v(if (joined) 1 else 2);
        w.u32v(gameid);
        w.u32v(players);
        w.u32v(level);
        w.u32v(class);
        w.cstr(char);
        const total = 8 + w.slice().len;
        std.mem.writeInt(u16, b[0..2], @intCast(total), .little);
        std.mem.writeInt(u16, b[2..4], rc.GS_UPDATEGAMEINFO, .little);
        std.mem.writeInt(u32, b[4..8], 0, .little);
        try self.emit(b[0..total]);
    }

    /// Report a game ending, freeing whatever characters it still held.
    pub fn sendCloseGame(self: *FakeGS, gameid: u32) !void {
        var b: [12]u8 = undefined;
        std.mem.writeInt(u16, b[0..2], 12, .little);
        std.mem.writeInt(u16, b[2..4], rc.GS_CLOSEGAME, .little);
        std.mem.writeInt(u32, b[4..8], 0, .little);
        std.mem.writeInt(u32, b[8..12], gameid, .little);
        try self.emit(&b);
    }

    fn emit(self: *FakeGS, packet: []const u8) !void {
        if (self.ev == null) return error.NotConnected;
        self.evLock();
        defer self.evUnlock();
        _ = self.ev.?.cmdBig(&.{ "RPUSH", "realmd:gsev" }, packet) catch return error.WriteFailed;
    }

    /// Spawn the queue thread and wait up to wait_ms for the record to be published.
    pub fn start(self: *FakeGS, wait_ms: u32) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        var waited: u32 = 0;
        while (waited < wait_ms) : (waited += 10) {
            if (@atomicLoad(bool, &self.registered, .seq_cst)) break;
            _ = net.usleep(10_000);
        }
    }

    pub fn isRegistered(self: *FakeGS) bool {
        return @atomicLoad(bool, &self.registered, .seq_cst);
    }

    /// Leave the fleet the way a dying server does — by taking its own record out, so the next
    /// test does not inherit a server that is not answering.
    pub fn stop(self: *FakeGS) void {
        self.stop_flag = true;
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.ev) |*e| {
            var kb: [64]u8 = undefined;
            var ib: [16]u8 = undefined;
            _ = e.cmd(&.{ "DEL", key(&kb, "realmd:gs:{x}", .{self.gsid}) }) catch {};
            _ = e.cmd(&.{ "SREM", "realmd:gs", key(&ib, "{x}", .{self.gsid}) }) catch {};
            e.close();
            self.ev = null;
        }
    }
};

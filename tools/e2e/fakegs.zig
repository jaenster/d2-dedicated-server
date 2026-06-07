//! FakeGS — a stand-in game server that connects to realmd's gs-link, registers
//! (AUTHREPLY + SETGSINFO + ADDRINFO) and answers CREATE/JOINGAME. Runs on a
//! background thread. Ported from realmclient.py FakeGS.
const std = @import("std");
const net = @import("net.zig");
const rc = @import("realmclient.zig");
const Socket = net.Socket;

pub const FakeGS = struct {
    gsid: u32 = 0xABCD,
    ip: [4]u8 = .{ 127, 0, 0, 1 },
    gs_port: u16 = 4000,
    maxgame: u32 = 100,
    gameid: u32 = 42,
    next_gameid: ?u32 = null, // if set, hand out incrementing ids

    registered: bool = false,
    creates: u32 = 0,
    joins: u32 = 0,
    sock: ?Socket = null,
    stop_flag: bool = false,
    thread: ?std.Thread = null,
    _next: u32 = 0,

    fn run(self: *FakeGS) void {
        const fd = net.connectLocal(rc.HOST_GS) catch return;
        self.sock = fd;
        if (self.next_gameid) |n| self._next = n;
        var rx: [1024]u8 = undefined;
        while (!self.stop_flag) {
            const c = rc.ctlRecv(fd, &rx) catch break;
            switch (c.typ) {
                rc.GS_AUTHREQ => {
                    rc.ctlSend(fd, rc.GS_AUTHREPLY, "") catch break;
                    var gi: [8]u8 = undefined;
                    var w = net.Writer.init(&gi);
                    w.u32v(self.maxgame);
                    w.u32v(0);
                    rc.ctlSend(fd, rc.GS_SETGSINFO, w.slice()) catch break;
                    var ai: [14]u8 = undefined;
                    var aw = net.Writer.init(&ai);
                    aw.u32v(self.maxgame);
                    aw.u32v(self.gsid);
                    aw.bytes(&self.ip);
                    aw.u16v(self.gs_port);
                    rc.ctlSend(fd, rc.GS_ADDRINFO, aw.slice()) catch break;
                    @atomicStore(bool, &self.registered, true, .seq_cst);
                },
                rc.GS_CREATEGAME => {
                    self.creates += 1;
                    var gid = self.gameid;
                    if (self.next_gameid != null) {
                        gid = self._next;
                        self._next += 1;
                    }
                    var rb: [8]u8 = undefined;
                    var w = net.Writer.init(&rb);
                    w.u32v(0);
                    w.u32v(gid);
                    rc.ctlSend(fd, rc.GS_CREATEGAME, w.slice()) catch break;
                },
                rc.GS_JOINGAME => {
                    self.joins += 1;
                    var rb: [8]u8 = undefined;
                    var w = net.Writer.init(&rb);
                    w.u32v(0);
                    w.u32v(self.gameid);
                    rc.ctlSend(fd, rc.GS_JOINGAME, w.slice()) catch break;
                },
                else => {},
            }
        }
    }

    /// Spawn the background thread and wait up to wait_ms for registration.
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

    pub fn stop(self: *FakeGS) void {
        self.stop_flag = true;
        if (self.sock) |fd| net.closeSocket(fd);
        if (self.thread) |t| t.join();
        self.thread = null;
    }
};

//! The store side of a game server, for the harness.
//!
//! A game server no longer connects to realmd, so a stand-in cannot register by dialling one. It
//! publishes itself into redis, takes create/join from its own queue there, and reports events —
//! and this is the small piece of redis needed to do that.
//!
//! Framing comes from `packages/resp`, the same IO-free codec realmd and the injected DLL use, so
//! the harness cannot drift from what it is testing. Only the sockets are local.
const std = @import("std");
const resp = @import("resp");
const net = @import("net.zig");
const Socket = net.Socket;

pub const Client = struct {
    fd: Socket,
    rx: [8192]u8 = undefined,

    pub fn connect(port: u16) !Client {
        return .{ .fd = try net.connectLocal(port) };
    }

    pub fn close(self: *Client) void {
        net.closeSocket(self.fd);
    }

    /// Send one command and read one reply. The reply's slices point into this client's buffer
    /// and are valid until the next call.
    pub fn cmd(self: *Client, args: []const []const u8) !resp.Reply {
        var tx: [1024]u8 = undefined;
        const wire = resp.encode(&tx, args) orelse return error.TooLong;
        try net.writeAll(self.fd, wire);
        return self.readReply();
    }

    /// Same, but the last argument may be larger than the command buffer — a reply packet, or a
    /// character save.
    pub fn cmdBig(self: *Client, head: []const []const u8, tail: []const u8) !resp.Reply {
        var tx: [1024]u8 = undefined;
        var n: usize = 0;
        n += (std.fmt.bufPrint(tx[n..], "*{d}\r\n", .{head.len + 1}) catch return error.TooLong).len;
        for (head) |a| {
            n += (std.fmt.bufPrint(tx[n..], "${d}\r\n", .{a.len}) catch return error.TooLong).len;
            if (n + a.len + 2 > tx.len) return error.TooLong;
            @memcpy(tx[n..][0..a.len], a);
            n += a.len;
            tx[n] = '\r';
            tx[n + 1] = '\n';
            n += 2;
        }
        n += (std.fmt.bufPrint(tx[n..], "${d}\r\n", .{tail.len}) catch return error.TooLong).len;
        try net.writeAll(self.fd, tx[0..n]);
        try net.writeAll(self.fd, tail);
        try net.writeAll(self.fd, "\r\n");
        return self.readReply();
    }

    fn readReply(self: *Client) !resp.Reply {
        var fill: usize = 0;
        while (true) {
            switch (resp.parse(self.rx[0..fill])) {
                .ok => |o| return o.reply,
                .invalid => return error.BadReply,
                .need_more => {
                    if (fill == self.rx.len) return error.ReplyTooLong;
                    var one: [4096]u8 = undefined;
                    const want = @min(one.len, self.rx.len - fill);
                    const got = std.posix.read(self.fd, one[0..want]) catch return error.ReadFailed;
                    if (got == 0) return error.Closed;
                    @memcpy(self.rx[fill..][0..got], one[0..got]);
                    fill += got;
                },
            }
        }
    }
};

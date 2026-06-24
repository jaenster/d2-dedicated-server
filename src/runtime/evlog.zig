//! Structured event log — emits one JSON object per line to the d2gs log, e.g.
//!   {"evt":"monster_spawn","name":"Mephisto","class":242,"x":17500,"y":8100}
//! so a Grafana/Loki (or vector/promtail) pipeline can scrape d2gs_log.txt and
//! treat every server event as a queryable structured record. No allocation: each
//! event builds into a fixed stack buffer, then flushes through log.print (stdout +
//! file). Designed to be called from the srvtrace entry-detour shims.
//!
//! All values are emitted as JSON. Strings are escaped; wide (UTF-16) engine names
//! are down-converted (ASCII kept, non-ASCII → '?'). Truncation is silent but the
//! line always stays valid JSON (we never cut mid-escape, and end() always closes).
const std = @import("std");
const log = @import("../log.zig");

const CAP = 480;

pub const Event = struct {
    buf: [CAP]u8 = undefined,
    n: usize = 0,
    /// becomes true once we'd overflow; further fields are dropped (line stays valid).
    full: bool = false,

    fn raw(self: *Event, s: []const u8) void {
        if (self.full) return;
        if (self.n + s.len > CAP - 2) { // leave room for the closing "}"
            self.full = true;
            return;
        }
        @memcpy(self.buf[self.n .. self.n + s.len], s);
        self.n += s.len;
    }

    fn rawByte(self: *Event, c: u8) void {
        if (self.full) return;
        if (self.n + 1 > CAP - 2) {
            self.full = true;
            return;
        }
        self.buf[self.n] = c;
        self.n += 1;
    }

    /// Emit a JSON-escaped string body (no surrounding quotes).
    fn escAscii(self: *Event, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                0...8, 11, 12, 14...0x1f => {}, // drop other control chars
                else => self.rawByte(c),
            }
        }
    }

    fn key(self: *Event, k: []const u8) void {
        self.rawByte(',');
        self.rawByte('"');
        self.escAscii(k);
        self.raw("\":");
    }

    /// Start an event: a bare JSON object `{"evt":"<name>"` — no prefix, so every
    /// line is valid JSON straight into `jq` / promtail's json stage. Filter by the
    /// `evt` field (e.g. `grep '"evt":"tick"'`).
    pub fn begin(name: []const u8) Event {
        var e = Event{};
        e.raw("{\"evt\":\"");
        e.escAscii(name);
        e.rawByte('"');
        return e;
    }

    /// ,"k":"v" — ASCII/byte string value.
    pub fn str(self: *Event, k: []const u8, v: []const u8) void {
        self.key(k);
        self.rawByte('"');
        self.escAscii(v);
        self.rawByte('"');
    }

    /// ,"k":"<utf16z>" — a null-terminated wide engine string (char/monster/item
    /// name). ASCII kept; bytes >= 0x80 become '?'. Bounded scan. `ptr` may be null.
    pub fn wstr(self: *Event, k: []const u8, ptr: ?[*:0]const u16) void {
        self.key(k);
        self.rawByte('"');
        if (ptr) |p| {
            var i: usize = 0;
            while (i < 64 and p[i] != 0) : (i += 1) {
                const w = p[i];
                const c: u8 = if (w < 0x80) @intCast(w) else '?';
                switch (c) {
                    '"' => self.raw("\\\""),
                    '\\' => self.raw("\\\\"),
                    0...0x1f => self.rawByte('?'),
                    else => self.rawByte(c),
                }
            }
        }
        self.rawByte('"');
    }

    /// ,"k":<int>
    pub fn int(self: *Event, k: []const u8, v: i64) void {
        self.key(k);
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        self.raw(s);
    }

    /// ,"k":"0x.." — a pointer/id as hex string (keeps full 32-bit width readable).
    pub fn hex(self: *Event, k: []const u8, v: usize) void {
        self.key(k);
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "\"0x{x}\"", .{v}) catch return;
        self.raw(s);
    }

    /// ,"k":true/false
    pub fn boolean(self: *Event, k: []const u8, v: bool) void {
        self.key(k);
        self.raw(if (v) "true" else "false");
    }

    /// Close and flush the line.
    pub fn end(self: *Event) void {
        self.rawByte('}');
        log.print(self.buf[0..self.n]);
    }
};

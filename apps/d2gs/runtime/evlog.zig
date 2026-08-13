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
//!
//! Event is generic over buffer capacity: `Event` (480) is the default for the
//! compact per-action traces; a bigger cap (e.g. the DRLG room-layout dump) uses
//! `EventN(N)`. Nested arrays/objects are supported via the array/obj primitives.
const std = @import("std");
const log = @import("../log.zig");

/// Build an event type with a `cap`-byte line buffer. Use `Event` for the default.
pub fn EventN(comptime cap: usize) type {
    return struct {
        const Self = @This();

        buf: [cap]u8 = undefined,
        n: usize = 0,
        /// becomes true once we'd overflow; further fields are dropped (line stays valid).
        full: bool = false,

        fn raw(self: *Self, s: []const u8) void {
            if (self.full) return;
            if (self.n + s.len > cap - 2) { // leave room for the closing "}"
                self.full = true;
                return;
            }
            @memcpy(self.buf[self.n .. self.n + s.len], s);
            self.n += s.len;
        }

        fn rawByte(self: *Self, c: u8) void {
            if (self.full) return;
            if (self.n + 1 > cap - 2) {
                self.full = true;
                return;
            }
            self.buf[self.n] = c;
            self.n += 1;
        }

        /// Emit a JSON-escaped string body (no surrounding quotes).
        fn escAscii(self: *Self, s: []const u8) void {
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

        fn key(self: *Self, k: []const u8) void {
            self.rawByte(',');
            self.rawByte('"');
            self.escAscii(k);
            self.raw("\":");
        }

        /// `"k":` with NO leading comma — for the first field inside a fresh object.
        fn keyFirst(self: *Self, k: []const u8) void {
            self.rawByte('"');
            self.escAscii(k);
            self.raw("\":");
        }

        fn num(self: *Self, v: i64) void {
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
            self.raw(s);
        }

        /// Start an event: a bare JSON object `{"evt":"<name>"` — no prefix, so every
        /// line is valid JSON straight into `jq` / promtail's json stage. Filter by the
        /// `evt` field (e.g. `grep '"evt":"tick"'`).
        pub fn begin(name: []const u8) Self {
            var e = Self{};
            e.raw("{\"evt\":\"");
            e.escAscii(name);
            e.rawByte('"');
            return e;
        }

        /// ,"k":"v" — ASCII/byte string value.
        pub fn str(self: *Self, k: []const u8, v: []const u8) void {
            self.key(k);
            self.rawByte('"');
            self.escAscii(v);
            self.rawByte('"');
        }

        /// ,"k":"<utf16z>" — a null-terminated wide engine string (char/monster/item
        /// name). ASCII kept; bytes >= 0x80 become '?'. Bounded scan. `ptr` may be null.
        pub fn wstr(self: *Self, k: []const u8, ptr: ?[*:0]const u16) void {
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
        pub fn int(self: *Self, k: []const u8, v: i64) void {
            self.key(k);
            self.num(v);
        }

        /// "k":<int> with NO leading comma — the first field of a fresh object.
        pub fn intFirst(self: *Self, k: []const u8, v: i64) void {
            self.keyFirst(k);
            self.num(v);
        }

        /// ,"k":"0x.." — a pointer/id as hex string (keeps full 32-bit width readable).
        pub fn hex(self: *Self, k: []const u8, v: usize) void {
            self.key(k);
            var tmp: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "\"0x{x}\"", .{v}) catch return;
            self.raw(s);
        }

        /// ,"k":true/false
        pub fn boolean(self: *Self, k: []const u8, v: bool) void {
            self.key(k);
            self.raw(if (v) "true" else "false");
        }

        // -- nested array/object primitives (for structured dumps like drlg_level) --

        /// ,"k":[ — open a keyed array value. Caller emits elements then arrayEnd().
        pub fn arrayField(self: *Self, k: []const u8) void {
            self.key(k);
            self.rawByte('[');
        }
        /// ] — close the current array.
        pub fn arrayEnd(self: *Self) void {
            self.rawByte(']');
        }
        /// ,"k":{ — open a keyed object value. Caller emits fields (intFirst then int)
        /// then objClose().
        pub fn objField(self: *Self, k: []const u8) void {
            self.key(k);
            self.rawByte('{');
        }
        /// { — open a bare object (an array element). Inside, use intFirst then int.
        pub fn objOpen(self: *Self) void {
            self.rawByte('{');
        }
        /// } — close the current object.
        pub fn objClose(self: *Self) void {
            self.rawByte('}');
        }
        /// , — element separator inside an array.
        pub fn comma(self: *Self) void {
            self.rawByte(',');
        }

        /// A bare number as an array element (no key, no comma — caller emits comma()
        /// between elements). For integer arrays like adjacency lists `[2,5,7]`.
        pub fn numVal(self: *Self, v: i64) void {
            self.num(v);
        }

        /// Close and flush the line.
        pub fn end(self: *Self) void {
            self.rawByte('}');
            log.print(self.buf[0..self.n]);
        }

        /// Close and flush via the RAW sink (no structured wrapper, no 768-byte
        /// truncation). For large complete-JSON lines that must survive intact, e.g.
        /// the DRLG oracle's whole-level dumps.
        pub fn endRaw(self: *Self) void {
            self.rawByte('}');
            log.printRaw(self.buf[0..self.n]);
        }
    };
}

/// Default compact event (480-byte line) used by the per-action srvtrace shims.
pub const Event = EventN(480);

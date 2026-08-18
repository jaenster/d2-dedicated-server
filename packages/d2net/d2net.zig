//! Our own D2Net.dll — the game server's transport.
//!
//! The real one is a thin wrapper: every export we need is a stdcall shim forwarding to a Fog
//! QServer ordinal (`SERVER_Initialize` @10003 pushes four packet callbacks, port 4000 and mode 3
//! straight into `FOG_InitializeServer` @10149). Keeping it would mean implementing 31 Fog
//! networking ordinals purely to serve a module we intend to replace, so we replace the module: 14
//! functions, and those 31 ordinals disappear along with Blizzard's socket layer.
//!
//! Arities are measured, not guessed — every entry is stdcall and the real binary's `RET n` gives
//! the stack-arg count exactly. A wrong count desynchronises D2Game's stack at the call site.
//!
//! How the engine drives this, from `D2Game @10003` (@0x6fc38530): three drain loops, one per
//! message list, each of the form
//!
//!     loop: n = ReadFromMessageList(buf, 0x200); if (n == -1) break; process(buf, n); goto loop
//!
//! so **-1 is the empty sentinel** and 0 is a legitimate return. Each list has its own processor:
//!
//! | list | ordinal | processor | what it is |
//! |------|---------|-----------|------------|
//! | 0 | 10011 | 0x6fc31910 | switch on a byte opcode in 0x66..0x6F — control traffic |
//! | 1 | 10010 | 0x6fc31c00 | looks the leading dword up as a game |
//! | 2 | 10012 | 0x6fc38140 | reads the callback table at 0x6fd45830 — **client packets** |
//!
//! All three take `[clientId:u32][payload...]` in the buffer: the list-2 processor does
//! `ebx = [buf]` and uses it as the client id for `SERVER_Send` and the disconnect call.

const std = @import("std");

extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(h: *anyopaque, buf: [*]const u8, n: u32, wrote: *u32, ov: ?*anyopaque) callconv(.winapi) i32;

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
const SOCKET_ERROR: i32 = -1;
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const FIONBIO: u32 = 0x8004667E;
const WSAEWOULDBLOCK: i32 = 10035;

const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port: u16 = 0, // network byte order
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};

extern "ws2_32" fn WSAStartup(ver: u16, data: *anyopaque) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, ty: i32, proto: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr_in, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr_in, len: ?*i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: u32, arg: *u32) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, opt: i32, val: *const i32, len: i32) callconv(.winapi) i32;

var out: ?*anyopaque = null;

fn say(msg: []const u8) void {
    const h = out orelse blk: {
        out = GetStdHandle(@bitCast(@as(i32, -11)));
        break :blk out orelse return;
    };
    var wrote: u32 = 0;
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), &wrote, null);
    _ = WriteFile(h, "\r\n", 2, &wrote, null);
}

fn sayFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    say(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

// ── framing ──────────────────────────────────────────────────────────────────
//
// A TCP read is not a packet, and D2Game will not tolerate being handed one. The real D2Net framed
// the stream before the engine ever saw it: `SERVER_ValidateClientPacket` @0x6FC01FE0 calls
// `SERVER_GetClientPacketSize` @0x6FC01E60, which looks the leading opcode byte up in a table at
// 0x6FC08418 and rejects anything at or above 0x70 (except 0xFF) or longer than 0x204. Replacing
// D2Net means replacing that too.

/// Total wire size per C->S opcode, including the opcode byte. Read out of 1.10f's own D2Net at
/// 0x6FC08418, not transcribed from another version: 0 means the opcode is unused and framing
/// fails, -1 means variable-length and the packet has to be scanned.
///
/// It is worth knowing how close the versions are here, and where they are not. Against 1.14d's
/// equivalent (libd2 `net.cs.OUTGOING_SIZE`) 102 of 112 entries are identical — every gameplay
/// opcode 0x00-0x63 matches byte for byte. All ten differences fall in 0x64-0x6F, the join and
/// handshake range, and one of them is decisive: 0x68, the client's very first packet, is 1 byte
/// here and 37 in 1.14d. So a stock 1.14d client cannot speak to this server — it desyncs on the
/// first packet — while a 1.10f-era client shares the entire gameplay vocabulary.
const packet_size = [0x70]i32{
      0,   5,   9,   5,   9,   5,   9,   9, // 0x00-0x07
      5,   9,   9,   1,   5,   9,   9,   5, // 0x08-0x0F
      9,   9,   1,   9,  -1,  -1,  13,   5, // 0x10-0x17
     17,   5,   9,   9,   3,   9,   9,  17, // 0x18-0x1F
     13,   9,   5,   9,   5,   9,  13,   9, // 0x20-0x27
      9,   9,   9,   0,   0,   1,   3,   9, // 0x28-0x2F
      9,   9,  17,  17,   5,  17,   9,   5, // 0x30-0x37
     13,   5,   3,   3,   9,   5,   5,   3, // 0x38-0x3F
      1,   1,   1,   1,  17,   9,  13,  13, // 0x40-0x47
      1,   9,   0,   9,   5,   3,   0,   7, // 0x48-0x4F
      9,   9,   5,   1,   1,   0,   0,   0, // 0x50-0x57
      3,  17,   0,   0,   0,   7,   6,   5, // 0x58-0x5F
      1,   3,   5,   5,   9,  17,  46,  29, // 0x60-0x67
      1,   1,   1,  -1,   9,   1,   0,   1, // 0x68-0x6F
};

/// The engine's own bound, from the `cmp ax, 0x204` in `SERVER_ValidateClientPacket`.
const max_packet = 0x204;

/// How many bytes at the front of `buf` form one packet: null when more is needed, 0 when the
/// opcode cannot be framed at all (a desync — the caller drops the client rather than guessing).
fn packetLen(buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const op = buf[0];
    // 0xFF is the fixed-size control packet the table does not cover.
    if (op == 0xFF) return if (buf.len < 16) null else 16;
    if (op >= packet_size.len) return 0;
    const entry = packet_size[op];
    if (entry == 0) return 0;
    if (entry > 0) {
        const n: usize = @intCast(entry);
        if (n > max_packet) return 0;
        return if (buf.len < n) null else n;
    }
    // Variable-length: a u16 length follows the opcode. 0x14/0x15/0x6b are the three here.
    if (buf.len < 3) return null;
    const n = 3 + @as(usize, std.mem.readInt(u16, buf[1..3], .little));
    if (n > max_packet) return 0;
    return if (buf.len < n) null else n;
}

// ── the listener ─────────────────────────────────────────────────────────────

/// Where this game server actually listens — **not** the port a client dials. The client
/// hardcodes 4000 and d2ingress owns it, splicing game traffic through to whatever port the GS
/// advertises in its own store record; realmd copies that into the per-game route d2ingress reads.
/// Binding 4000 here would both collide with the ingress and stop a fleet sharing a host.
///
/// 4100 is the same default `apps/d2gs` uses when it joins a realm. That one has to rewrite a
/// hardcoded `push 0xfa0` inside the engine to move off 4000 (see `apps/d2gs/runtime/gsport.zig`);
/// since we own D2Net outright, here it is just a variable.
var listen_port: u16 = 4100;

/// Set by the host before `SERVER_Initialize`, from `--gs-addr ip:port` / `D2GS_GS_ADDR`. Exported
/// by name rather than ordinal: it is ours, not part of the D2Net ABI the engine imports.
export fn D2NET_SetListenPort(port: u16) callconv(.winapi) void {
    if (port != 0) listen_port = port;
}

/// D2Game's own client cap is per game; this is the socket table behind it.
const max_clients = 32;

const Client = struct {
    sock: SOCKET = INVALID_SOCKET,
    /// Unframed bytes as they arrived. A read is not a packet: it can hold several, or half of
    /// one, so this accumulates until `packetLen` says a whole packet is present.
    buf: [4 * max_packet]u8 = undefined,
    len: usize = 0,

    fn active(self: Client) bool {
        return self.sock != INVALID_SOCKET;
    }
};

var clients: [max_clients]Client = @splat(.{});
var listener: SOCKET = INVALID_SOCKET;
var server_up = false;
var max_clients_per_game: u32 = 0;
var hack_list_enabled: u32 = 0;

fn setNonBlocking(s: SOCKET) void {
    var yes: u32 = 1;
    _ = ioctlsocket(s, FIONBIO, &yes);
}

fn htons(v: u16) u16 {
    return std.mem.nativeToBig(u16, v);
}

/// Accept whatever is pending and read whatever has arrived. Called from the read path rather than
/// a thread: the host already ticks, and polling inside the drain keeps every socket touch on one
/// thread, so none of this needs locking.
fn poll() void {
    if (listener != INVALID_SOCKET) {
        while (true) {
            const s = accept(listener, null, null);
            if (s == INVALID_SOCKET) break;
            setNonBlocking(s);
            const slot = for (&clients, 0..) |*c, i| {
                if (!c.active()) break .{ c, i };
            } else {
                say("d2net: no client slot free, dropping connection");
                _ = closesocket(s);
                continue;
            };
            slot[0].* = .{ .sock = s, .len = 0 };
            sayFmt("d2net: client {d} connected", .{slot[1]});
        }
    }

    for (&clients, 0..) |*c, i| {
        if (!c.active() or c.len == c.buf.len) continue;
        const n = recv(c.sock, c.buf[c.len..].ptr, @intCast(c.buf.len - c.len), 0);
        if (n > 0) {
            c.len += @intCast(n);
            sayFmt("d2net: client {d} -> {d} bytes ({d} buffered)", .{ i, n, c.len });
        } else if (n == 0 or WSAGetLastError() != WSAEWOULDBLOCK) {
            sayFmt("d2net: client {d} disconnected", .{i});
            _ = closesocket(c.sock);
            c.* = .{};
        }
    }
}

/// Hand the engine one pending message as `[clientId:u32][payload]`, and return its total length.
fn takeMessage(buf: ?[*]u8, cap: u32) u32 {
    poll();
    const dst = buf orelse return no_message;
    for (&clients, 0..) |*c, i| {
        if (!c.active() or c.len == 0) continue;
        const n = packetLen(c.buf[0..c.len]) orelse continue; // incomplete, wait for more
        if (n == 0) {
            // Unframeable opcode: the stream is desynchronised and every later byte is garbage,
            // so there is nothing to resynchronise to. Drop the client rather than feed the
            // engine noise.
            sayFmt("d2net: client {d} sent unframeable opcode 0x{x}, dropping", .{ i, c.buf[0] });
            _ = closesocket(c.sock);
            c.* = .{};
            continue;
        }
        const total = 4 + n;
        if (total > cap) {
            sayFmt("d2net: client {d} packet too long for the engine buffer ({d} > {d})", .{ i, total, cap });
            _ = closesocket(c.sock);
            c.* = .{};
            continue;
        }
        std.mem.writeInt(u32, dst[0..4], @intCast(i), .little);
        @memcpy(dst[4..total], c.buf[0..n]);
        // Keep whatever followed: one read routinely carries more than one packet.
        std.mem.copyForwards(u8, c.buf[0 .. c.len - n], c.buf[n..c.len]);
        c.len -= n;
        sayFmt("d2net: client {d} packet 0x{x} ({d} bytes)", .{ i, dst[4], n });
        return @intCast(total);
    }
    return no_message;
}

// ── server lifecycle ─────────────────────────────────────────────────────────

/// `@10003 SERVER_Initialize(a, b)`.
export fn SERVER_Initialize(a: u32, b: u32) callconv(.winapi) u32 {
    var wsadata: [512]u8 = undefined;
    _ = WSAStartup(0x0202, &wsadata);

    listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener == INVALID_SOCKET) {
        sayFmt("d2net: socket() failed ({d})", .{WSAGetLastError()});
        return 0;
    }
    const reuse: i32 = 1;
    _ = setsockopt(listener, 0xFFFF, 0x0004, &reuse, @sizeOf(i32)); // SOL_SOCKET, SO_REUSEADDR

    const addr = sockaddr_in{ .port = htons(listen_port), .addr = 0 };
    if (bind(listener, &addr, @sizeOf(sockaddr_in)) == SOCKET_ERROR or
        listen(listener, 8) == SOCKET_ERROR)
    {
        sayFmt("d2net: bind/listen on {d} failed ({d})", .{ listen_port, WSAGetLastError() });
        _ = closesocket(listener);
        listener = INVALID_SOCKET;
        return 0;
    }
    setNonBlocking(listener);
    server_up = true;
    sayFmt("d2net: listening on {d} (a={d} b={d})", .{ listen_port, a, b });
    return 1;
}

export fn SERVER_SetMaxClientsPerGame(n: u32) callconv(.winapi) u32 {
    max_clients_per_game = n;
    return 0;
}

export fn SERVER_SetHackListEnabled(n: u32) callconv(.winapi) u32 {
    hack_list_enabled = n;
    return 0;
}

// ── the packet path ──────────────────────────────────────────────────────────

/// `@10006 SERVER_Send(kind, clientId, pData, nLen)`. The argument order is the engine's, read off
/// its own call site: `push nLen; push pBuf; push clientId; push 2` at 0x6fc381a2. The real one
/// asserts `nLen <= MAX_MSG_SIZE` before handing the buffer on, which is how we know it is the send.
export fn SERVER_Send(kind: u32, client: u32, data: ?[*]const u8, len: u32) callconv(.winapi) u32 {
    if (client >= clients.len or !clients[client].active()) return 0;
    const p = data orelse return 0;
    var sent: usize = 0;
    while (sent < len) {
        const n = send(clients[client].sock, p + sent, @intCast(len - sent), 0);
        if (n <= 0) {
            sayFmt("d2net: send to client {d} failed ({d})", .{ client, WSAGetLastError() });
            return 0;
        }
        sent += @intCast(n);
    }
    sayFmt("d2net: -> client {d}, {d} bytes (kind {d})", .{ client, len, kind });
    return 1;
}

/// -1, not 0: the drain loops break on -1 and 0 is a legitimate length.
const no_message: u32 = 0xFFFF_FFFF;

/// List 2 is the one whose processor consults the callback table, so client packets go there.
/// Lists 0 and 1 carry traffic our transport does not originate, and answer "empty".
export fn SERVER_ReadFromMessageList0(buf: u32, len: u32) callconv(.winapi) u32 {
    _ = buf;
    _ = len;
    return no_message;
}
export fn SERVER_ReadFromMessageList1(buf: u32, len: u32) callconv(.winapi) u32 {
    _ = buf;
    _ = len;
    return no_message;
}
export fn SERVER_ReadFromMessageList2(buf: ?[*]u8, len: u32) callconv(.winapi) u32 {
    return takeMessage(buf, len);
}

// ── per-client queries ───────────────────────────────────────────────────────

/// `@10014 (clientId, szOut, nSize)` — the engine calls this with a 16-byte buffer before a
/// rejection, so it must always leave a valid string behind when it answers yes.
export fn SERVER_GetIpAddressStringFromClientId(client: u32, buf: ?[*]u8, len: u32) callconv(.winapi) u32 {
    _ = client;
    const s = "0.0.0.0";
    const p = buf orelse return 0;
    if (len <= s.len) return 0;
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return 1;
}

/// `@10016 (clientId)` — called straight after the engine sends a rejection, so it is the kick.
export fn SERVER_DisconnectClient(client: u32) callconv(.winapi) u32 {
    if (client >= clients.len or !clients[client].active()) return 0;
    sayFmt("d2net: disconnecting client {d}", .{client});
    _ = closesocket(clients[client].sock);
    clients[client] = .{};
    return 1;
}

export fn D2NET_10015(a: u32, b: u32, c: u32) callconv(.winapi) u32 {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}

export fn D2NET_10019(a: u32) callconv(.winapi) u32 {
    _ = a;
    return 0;
}

export fn SERVER_SetClientGameGUID(client: u32, guid: u32) callconv(.winapi) u32 {
    sayFmt("d2net: client {d} joined game 0x{x}", .{ client, guid });
    return 0;
}

export fn SERVER_GetClientGameGUID(client: u32) callconv(.winapi) u32 {
    _ = client;
    return 0;
}

export fn SERVER_WSAGetLastError(a: u32, b: u32, c: u32) callconv(.winapi) u32 {
    _ = a;
    _ = b;
    _ = c;
    return @bitCast(WSAGetLastError());
}

/// mingw auto-exports every `export fn` a second time under its decorated name, numbered from just
/// above the highest ordinal the .def uses. Left alone they would land on 10027-10047 — inside real
/// D2Net's own ordinal range (it ends at 10040) — so an engine build importing one of those numbers
/// would silently bind to an alias instead of failing to load. This sentinel raises the floor.
export fn D2NET_ordinal_ceiling() callconv(.winapi) u32 {
    return 0;
}

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
const cs = @import("d2engine").cs_packets;

const max_packet = cs.max_packet;
const packetLen = cs.packetLen;

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
    /// The game the engine put this client in; see SERVER_SetClientGameGUID.
    game_guid: u32 = 0,

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
/// Accept a 1.14d client's join and hand the engine the 1.10f one. Off by default: it exists so a
/// 1.14d client — which runs under wine without a disc, unlike 1.10f's SafeDisc-wrapped Game.exe —
/// can be used to exercise this server. Everything after the join is byte-identical between the two
/// versions, so this one rewrite is the whole of the compatibility layer.
var translate_join = false;

export fn D2NET_SetTranslate114dJoin(on: u32) callconv(.winapi) void {
    translate_join = on != 0;
}

/// Which engine this transport is framing for. The size table and the join opcode are both
/// per-version — 1.10f inserted two opcodes ahead of the join, so 1.07 frames the same packets at
/// different numbers — and getting either wrong desynchronises the stream on the first packet.
/// Defaults to 1.10f, which is what this file was written against.
var sizes: []const i32 = &cs.packet_size_110f;
var join_op: u8 = cs.join_110f;

/// cdecl and by plain name, like Fog's: the engine never calls this, only our host does, and a
/// stdcall export would pick up mingw's `@4` decoration.
export fn D2NET_SetEngineVersion(v: u32) callconv(.c) i32 {
    inline for (@typeInfo(@import("d2engine").version.Version).@"enum".fields) |f| {
        if (f.value == v) {
            const tbl = cs.packetSizes(@enumFromInt(f.value)) orelse {
                sayFmt("d2net: no packet table read for {s} — framing as 1.10f", .{f.name});
                return 0;
            };
            sizes = tbl;
            join_op = (cs.joinPacket(@enumFromInt(f.value)) orelse return 0).op;
            const sys = cs.systemRange(@enumFromInt(f.value)) orelse return 0;
            system_lo = sys.lo;
            system_hi = sys.hi;
            sayFmt("d2net: framing for {s} ({d} opcodes, join 0x{x}, system 0x{x}-0x{x})", .{
                f.name, sizes.len, join_op, system_lo, system_hi,
            });
            return 1;
        }
    }
    return 0;
}

/// Frame with the selected version's table rather than the compile-time default.
fn packetLenFor(buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const op = buf[0];
    if (op >= sizes.len) return 0;
    return cs.packetLenWith(sizes, buf);
}

/// Rewrite in place at the head of a client's buffer, before framing sees it.
fn translateHead(c: *Client) void {
    if (!translate_join or c.len < cs.join_114d_len) return;
    if (c.buf[0] != cs.join_114d) return;
    var rewritten: [cs.join_110f_len]u8 = undefined;
    const n = cs.translateJoin114dTo(c.buf[0..cs.join_114d_len], &rewritten, join_op) orelse return;
    @memcpy(c.buf[0..n], rewritten[0..n]);
    // Close the gap the shorter packet leaves, so whatever followed stays framed.
    const rest = c.len - cs.join_114d_len;
    if (rest > 0) std.mem.copyForwards(u8, c.buf[n .. n + rest], c.buf[cs.join_114d_len..c.len]);
    c.len = n + rest;
    sayFmt("d2net: translated a 1.14d join (0x68/{d}) into 0x{x}/{d}", .{ cs.join_114d_len, join_op, n });
}

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

/// Which drain loop a packet belongs to. The engine does not sort them for us — each list has its
/// own processor and its own vocabulary, so handing a packet to the wrong one is silently ignored
/// at best.
///
///   - **list 0** `CCMD_ProcessClientSystemMessage` @0x6fc31910 switches on `buf[4]` after
///     subtracting 0x66, so it owns opcodes **0x66-0x6F** — the session traffic, including the
///     join. `GAME_VerifyJoinGame` hangs off its case for **0x67**.
///   - **list 1** `CCMD_ProcessClientMessage` @0x6fc31c00 takes everything else: the in-game
///     commands.
///
/// Note this is where 1.14d's join went: 1.10f joins with **0x67, 29 bytes**, while 1.14d uses
/// **0x68, 37 bytes**. The opcode shifted by one and the payload grew, which is why a 1.14d client
/// desynchronises here rather than merely being refused.
var system_lo: u8 = 0x66;
var system_hi: u8 = 0x6f;

fn listFor(opcode: u8) u32 {
    return if (opcode >= system_lo and opcode <= system_hi) 0 else 1;
}

/// Hand the engine one pending message as `[clientId:u32][payload]`, and return its total length.
/// `list` is the drain loop asking; a packet belonging to another list is left for that one, which
/// costs nothing because the engine drains all three in the same frame.
fn takeMessageFor(list: u32, buf: ?[*]u8, cap: u32) u32 {
    poll();
    const dst = buf orelse return no_message;
    for (&clients, 0..) |*c, i| {
        if (!c.active() or c.len == 0) continue;
        translateHead(c);
        const n = packetLenFor(c.buf[0..c.len]) orelse continue; // incomplete, wait for more
        if (n != 0 and listFor(c.buf[0]) != list) continue; // another drain loop's packet
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
    sayFmt("d2net-trace: SetMaxClientsPerGame", .{});
    max_clients_per_game = n;
    return 0;
}

export fn SERVER_SetHackListEnabled(n: u32) callconv(.winapi) u32 {
    sayFmt("d2net-trace: SetHackListEnabled", .{});
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
    // The first bytes of a reply are what say whether the engine accepted a join or refused it, and
    // a refusal on the system list looks identical to a world update from the outside.
    {
        var hex: [3 * 24]u8 = undefined;
        var n: usize = 0;
        const show = @min(len, 24);
        for (0..show) |i| {
            const b = (p + i)[0];
            const d = "0123456789abcdef";
            hex[n] = d[b >> 4];
            hex[n + 1] = d[b & 15];
            hex[n + 2] = ' ';
            n += 3;
        }
        sayFmt("d2net:    head: {s}", .{hex[0..n]});
    }
    return 1;
}

/// -1, not 0: the drain loops break on -1 and 0 is a legitimate length.
const no_message: u32 = 0xFFFF_FFFF;

export fn SERVER_ReadFromMessageList0(buf: ?[*]u8, len: u32) callconv(.winapi) u32 {
    return takeMessageFor(0, buf, len);
}
export fn SERVER_ReadFromMessageList1(buf: ?[*]u8, len: u32) callconv(.winapi) u32 {
    return takeMessageFor(1, buf, len);
}

/// List 2's processor reads its opcode at `buf[5]`, not `buf[4]` like the other two, so it takes a
/// different envelope entirely. Nothing we originate belongs there yet.
export fn SERVER_ReadFromMessageList2(buf: u32, len: u32) callconv(.winapi) u32 {
    _ = buf;
    _ = len;
    return no_message;
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
    sayFmt("d2net-trace: DisconnectClient", .{});
    if (client >= clients.len or !clients[client].active()) return 0;
    sayFmt("d2net: disconnecting client {d}", .{client});
    _ = closesocket(clients[client].sock);
    clients[client] = .{};
    return 1;
}

export fn D2NET_10015(a: u32, b: u32, c: u32) callconv(.winapi) u32 {
    sayFmt("d2net-trace: D2NET_10015", .{});
    _ = a;
    _ = b;
    _ = c;
    return 0;
}

export fn D2NET_10019(a: u32) callconv(.winapi) u32 {
    sayFmt("d2net-trace: D2NET_10019", .{});
    _ = a;
    return 0;
}

/// Which game each client is in. The engine sets this when a client joins and reads it back
/// whenever it needs to lock that client's game — `CLIENTS_OnDatabaseCharacterReceived` does
/// `SrvLockGame(GetClientGameGUID(clientId))`, so a transport that forgets it answers 0 and the
/// character delivery fails with `*** Failed SrvLockGame for client N ***`. It is the engine's
/// state, but we are the ones holding it.
export fn SERVER_SetClientGameGUID(client: u32, guid: u32) callconv(.winapi) u32 {
    sayFmt("d2net-trace: SetClientGameGUID", .{});
    if (client >= clients.len) return 0;
    clients[client].game_guid = guid;
    sayFmt("d2net: client {d} joined game 0x{x}", .{ client, guid });
    return 0;
}

export fn SERVER_GetClientGameGUID(client: u32) callconv(.winapi) u32 {
    sayFmt("d2net-trace: GetClientGameGUID", .{});
    return if (client < clients.len) clients[client].game_guid else 0;
}

export fn SERVER_WSAGetLastError(a: u32, b: u32, c: u32) callconv(.winapi) u32 {
    _ = a;
    _ = b;
    _ = c;
    return @bitCast(WSAGetLastError());
}

/// How many clients are connected. Ours to answer, and the host uses it to decide whether the
/// engine's per-game update is safe to drive: that path halts the process on a game with nothing
/// in it, and a count we already keep is a safer test than walking the engine's own structures.
export fn D2NET_ConnectedClients() callconv(.winapi) u32 {
    var n: u32 = 0;
    for (&clients) |*c| {
        if (c.active()) n += 1;
    }
    return n;
}

/// mingw auto-exports every `export fn` a second time under its decorated name, numbered from just
/// above the highest ordinal the .def uses. Left alone they would land on 10027-10047 — inside real
/// D2Net's own ordinal range (it ends at 10040) — so an engine build importing one of those numbers
/// would silently bind to an alias instead of failing to load. This sentinel raises the floor.
export fn D2NET_ordinal_ceiling() callconv(.winapi) u32 {
    return 0;
}

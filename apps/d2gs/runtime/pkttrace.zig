//! D2GS :4000 inbound packet tracing — log every client->GS packet by mode, so we
//! can see exactly what the real client sends during the realm join handshake.
//!
//! HandleAnyIncomingPacket dispatches dequeued packets to three handlers by mode
//! (GameSetup 0x67-0x70, InGame <0x67, System >0x70). We patch the three call
//! sites; at each, ECX=pBytes (the dequeued buffer), EDX=iSize. The buffer is
//! { nClientId:u32, packetId:u8, ... } so the id is pBytes[4].

const patch = @import("patch.zig");
const log = @import("../log.zig");
const evlog = @import("evlog.zig");

extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, typ: u32, protect: u32) callconv(.winapi) ?*anyopaque;
const MEM_COMMIT_RESERVE: u32 = 0x3000;
const PAGE_EXECUTE_READWRITE: u32 = 0x40;

const GAMESETUP_CALL: usize = 0x0052d011;
const GAMESETUP_FN: usize = 0x0053f100;
const INGAME_CALL: usize = 0x0052d03e;
const INGAME_FN: usize = 0x0053f3d0;
const SYSTEM_CALL: usize = 0x0052d06e;
const SYSTEM_FN: usize = 0x0052cc20;

fn idOf(pbytes: usize) u8 {
    return @as([*]const u8, @ptrFromInt(pbytes))[4];
}
fn clientOf(pbytes: usize) u32 {
    return @as(*align(1) const u32, @ptrFromInt(pbytes)).*; // nClientId @ +0
}
// Inbound dequeued buffer = { nClientId:u32, packetId:u8, ... }; emit as JSON so the
// whole trace shares the [srvtrace] structured stream (no plain-text noise).
fn pktIn(mode: []const u8, pbytes: usize) void {
    var e = evlog.Event.begin("pkt_in");
    e.str("mode", mode);
    e.int("client", clientOf(pbytes));
    e.hex("id", idOf(pbytes));
    e.end();
}
fn logSetup(pbytes: usize) callconv(.c) void {
    pktIn("GameSetup", pbytes);
}
fn logInGame(pbytes: usize) callconv(.c) void {
    pktIn("InGame", pbytes);
}
fn logSystem(pbytes: usize) callconv(.c) void {
    pktIn("System", pbytes);
}

// Intercept template: ECX=pBytes, EDX=iSize must reach the original handler. Save
// both, log the id (from ECX), restore, tail-jump to the real handler.
fn setupShim() callconv(.naked) void {
    asm volatile (
        \\push %%ecx
        \\push %%edx
        \\push %%ecx
        \\call %[f:P]
        \\add $4, %%esp
        \\pop %%edx
        \\pop %%ecx
        \\mov %[t], %%eax
        \\jmp *%%eax
        :
        : [f] "X" (&logSetup),
          [t] "i" (GAMESETUP_FN),
    );
}
fn inGameShim() callconv(.naked) void {
    asm volatile (
        \\push %%ecx
        \\push %%edx
        \\push %%ecx
        \\call %[f:P]
        \\add $4, %%esp
        \\pop %%edx
        \\pop %%ecx
        \\mov %[t], %%eax
        \\jmp *%%eax
        :
        : [f] "X" (&logInGame),
          [t] "i" (INGAME_FN),
    );
}
fn systemShim() callconv(.naked) void {
    asm volatile (
        \\push %%ecx
        \\push %%edx
        \\push %%ecx
        \\call %[f:P]
        \\add $4, %%esp
        \\pop %%edx
        \\pop %%ecx
        \\mov %[t], %%eax
        \\jmp *%%eax
        :
        : [f] "X" (&logSystem),
          [t] "i" (SYSTEM_FN),
    );
}

// ── outbound: SendPacket_Helper entry trampoline ─────────────────────────────
// SendPacket_Helper @0x53b280 is the chokepoint for every server->client packet
// (it queues into the client's packet list). Prologue (verified):
//   55          push ebp
//   8b ec       mov ebp,esp
//   53          push ebx
//   33 db       xor ebx,ebx        -> 6 PIC bytes, relocate into a trampoline
// then resume at SENDPKT+6. ABI: EDI=pClient, [esp+4]=pBytes, [esp+8]=nSize.
const SENDPKT: usize = 0x0053b280;
const SENDPKT_PROLOGUE = [_]u8{ 0x55, 0x8b, 0xec, 0x53, 0x33, 0xdb };
var trampoline: usize = 0;

fn logOut(pbytes: usize, nsize: usize) callconv(.c) void {
    var e = evlog.Event.begin("pkt_out");
    e.hex("id", @as([*]const u8, @ptrFromInt(pbytes))[0]);
    e.int("size", @as(i64, @intCast(nsize)));
    e.end();
}

fn sendShim() callconv(.naked) void {
    asm volatile (
        \\pushal
        \\mov 0x24(%%esp), %%eax
        \\push 0x28(%%esp)
        \\push %%eax
        \\call %[f:P]
        \\add $8, %%esp
        \\popal
        \\mov %[tramp], %%eax
        \\jmp *(%%eax)
        :
        : [f] "X" (&logOut),
          [tramp] "X" (&trampoline),
    );
}

fn installOutbound() void {
    const entry: [*]const u8 = @ptrFromInt(SENDPKT);
    for (SENDPKT_PROLOGUE, 0..) |b, i| {
        if (entry[i] != b) {
            log.print("pkttrace: outbound prologue unexpected — skipping send hook");
            return;
        }
    }
    const mem = VirtualAlloc(null, 32, MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE) orelse {
        log.print("pkttrace: VirtualAlloc failed — skipping send hook");
        return;
    };
    const tr: [*]u8 = @ptrCast(mem);
    // relocated prologue (6 PIC bytes) + jmp rel32 -> SENDPKT+6
    for (SENDPKT_PROLOGUE, 0..) |b, i| tr[i] = b;
    tr[6] = 0xE9;
    const back: usize = SENDPKT + 6;
    const rel: i32 = @intCast(@as(isize, @bitCast(back)) - @as(isize, @bitCast(@intFromPtr(tr) + 6)) - 5);
    const rb: [4]u8 = @bitCast(rel);
    tr[7] = rb[0];
    tr[8] = rb[1];
    tr[9] = rb[2];
    tr[10] = rb[3];
    trampoline = @intFromPtr(tr);

    if (patch.MemoryPatch(SENDPKT).jump(@intFromPtr(&sendShim)).nops(1).commit()) {
        log.print("pkttrace: outbound SendPacket hook installed");
    } else {
        log.print("pkttrace: outbound detour FAILED");
    }
}

pub fn install() void {
    var ok = true;
    ok = patch.MemoryPatch(GAMESETUP_CALL).call(@intFromPtr(&setupShim)).commit() and ok;
    ok = patch.MemoryPatch(INGAME_CALL).call(@intFromPtr(&inGameShim)).commit() and ok;
    ok = patch.MemoryPatch(SYSTEM_CALL).call(@intFromPtr(&systemShim)).commit() and ok;
    log.print(if (ok) "pkttrace: inbound dispatch hooks installed" else "pkttrace: inbound hook FAILED");
    installOutbound();
}

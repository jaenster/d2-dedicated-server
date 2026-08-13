//! Make the Battle.net gateway list come from memory, never the registry — so clients
//! can share one wineprefix without the gateway-assert crash.
//!
//! D2Client::BNGatewayAccess::Load @0x5186d0 calls GetGatewayList @0x518190, which reads
//! the REG_MULTI_SZ value via Storm's SSTR_RegistryReadValueEx. With two Game.exe sharing
//! one wineprefix (shared HKCU user.reg), that read returns EMPTY for the 2nd client under
//! contention -> Load falls to UpdateGatewaysFromIni @0x518850, whose ini parse asserts
//! (FindSection @0x5183f0 -> NULL -> BNetGW.cpp:0x277 -> 0xc0000005). Writing the registry
//! value ourselves did NOT fix it: the contended read still came back empty.
//! See [[d2-multiclient-gateway-assert]].
//!
//! So we detour GetGatewayList itself: fill the gateway-access struct from an in-memory
//! REG_MULTI_SZ we build (every realm entry -> the injected IP), allocated with the engine's
//! own SMemAlloc so the engine's later SMemFree (SaveAndUnload) is valid. No registry read
//! ever happens -> no contention -> no crash, regardless of wineprefix sharing.
//!
//! GetGatewayList is __thiscall: ECX = pGatewayAccess (this), one stack arg (the value name
//! we ignore), `ret 4`. Struct fields it sets: +0x10 pGatewayData, +0x14 nGatewayDataSize,
//! +0x18 nFormatVersion. Buffer layout (same as the working rig value):
//!   <version>\0 <curidx>\0  then N x (<ip>\0 <timezone>\0 <name>\0), MULTI_SZ double-null.
const std = @import("std");
const patch = @import("patch.zig");
const fastcall = @import("fastcall.zig");
const log = @import("../log.zig");

const GETGATEWAYLIST_ADDR: usize = 0x00518190;
// UpdateGatewaysFromIni(this, szText) @0x518850 — __stdcall, 2 stack args. Parses a
// server-pushed (BNFTP) or default gateway ini and asserts (FindSection -> NULL ->
// BNetGW.cpp:0x277) when the buffer is bad. Since the detour above always supplies a
// valid gateway, this is only ever the server/default trying to OVERRIDE our injected
// list — which we want to ignore — so we no-op it (ret 8) to kill the assert for good.
const UPDATEGATEWAYS_ADDR: usize = 0x00518850;
// Fog::SMem::SMemAlloc(size, file, line, flags) -> ptr  (__stdcall: callee cleans 16 bytes)
const SMemAlloc: *const fn (u32, [*:0]const u8, u32, u32) callconv(.winapi) ?[*]u8 = @ptrFromInt(0x00413020);

// Our realm entries — all resolve to the injected realm IP (filled by apply()).
const Gateway = struct { tz: []const u8, name: []const u8 };
const gateways = [_]Gateway{
    .{ .tz = "8", .name = "TypeGuru" },
    .{ .tz = "6", .name = "Realm2" },
    .{ .tz = "-9", .name = "Realm3" },
    .{ .tz = "-1", .name = "Realm4" },
};

// The real Battle.net gateways (server hostname + timezone + display name), used by
// applyDefault() when the client is launched with NO realm flag: we still must supply a
// valid list so the loader never reads the registry (→ no contention assert), but there's
// no reason to pin it to localhost — give it the genuine gateways instead.
const RealGateway = struct { server: []const u8, tz: []const u8, name: []const u8 };
const real_gateways = [_]RealGateway{
    .{ .server = "uswest.battle.net", .tz = "8", .name = "U.S. West" },
    .{ .server = "useast.battle.net", .tz = "6", .name = "U.S. East" },
    .{ .server = "asia.battle.net", .tz = "-9", .name = "Asia" },
    .{ .server = "europe.battle.net", .tz = "-1", .name = "Europe" },
};

var buf: [512]u8 = undefined;
var buf_len: usize = 0;

fn appendStr(pos: *usize, s: []const u8) void {
    @memcpy(buf[pos.* .. pos.* + s.len], s);
    pos.* += s.len;
    buf[pos.*] = 0; // string terminator inside the MULTI_SZ
    pos.* += 1;
}

/// GetGatewayList detour: ECX=this, stack arg ignored, ret 4 (modelled as Callback2(1)).
fn fillGatewaysImpl(ecx: usize, edx: usize, name_arg: usize) callconv(.c) void {
    _ = edx;
    // Load queries "Override Battle.net gateways" first, then "Diablo II Battle.net gateways".
    // Only mock the normal one — filling the Override query sets bIsOverride=1 and sends Load
    // down a different path that dereferences a null. ("Override.." starts 'O', normal 'D'.)
    const name: [*:0]const u8 = @ptrFromInt(name_arg);
    if (name[0] != 'D') return;
    const pData: *usize = @ptrFromInt(ecx + 0x10);
    if (pData.* != 0) return; // already loaded (matches the original's guard)
    const size: u32 = @intCast(buf_len);
    @as(*u32, @ptrFromInt(ecx + 0x14)).* = size; // nGatewayDataSize
    const mem = SMemAlloc(size, "d2gs", 0x156, 0) orelse return;
    @memcpy(mem[0..buf_len], buf[0..buf_len]);
    pData.* = @intFromPtr(mem); // pGatewayData
    @as(*u32, @ptrFromInt(ecx + 0x18)).* = 9999; // nFormatVersion (>=1000 so Load keeps it)
}

const shim = fastcall.Callback2(1, fillGatewaysImpl).shim;

/// Build the in-memory gateway list (realm entries -> `ip`) and detour GetGatewayList.
/// Build the MULTI_SZ header (version + current-index) into buf at `pos`.
fn beginList(pos: *usize) void {
    appendStr(pos, "9999"); // server-list version
    appendStr(pos, "1"); // current gateway index (1-based)
}

/// Close the MULTI_SZ (double-null) and publish the length.
fn endList(pos: *usize) void {
    buf[pos.*] = 0; // MULTI_SZ double-null terminator
    pos.* += 1;
    buf_len = pos.*;
}

/// Detour GetGatewayList to return the in-memory `buf`, and no-op the ini parser so a
/// server-pushed/default list can't override it or assert. Shared by apply/applyDefault.
fn installDetour() void {
    if (patch.MemoryPatch(GETGATEWAYLIST_ADDR).jump(@intFromPtr(&shim)).commit()) {
        log.print("realmgw: GetGatewayList detoured (gateway list from memory)");
    } else {
        log.print("realmgw: FAILED to detour GetGatewayList");
    }
    if (patch.MemoryPatch(UPDATEGATEWAYS_ADDR).retImm(8).commit()) {
        log.print("realmgw: UpdateGatewaysFromIni no-op'd (ret 8)");
    } else {
        log.print("realmgw: FAILED to no-op UpdateGatewaysFromIni");
    }
}

/// Realm mode: point every gateway entry at the injected realm `ip` so the client
/// connects to our realmd instead of Battle.net.
pub fn apply(ip: []const u8) void {
    var pos: usize = 0;
    beginList(&pos);
    for (gateways) |g| {
        appendStr(&pos, ip);
        appendStr(&pos, g.tz);
        appendStr(&pos, g.name);
    }
    endList(&pos);
    installDetour();
    log.print("realmgw: realm gateways installed (entries -> injected IP)");
}

/// No realm flag: install the genuine Battle.net gateways. This still routes the gateway
/// list through memory (so the loader never reads the contended registry and never
/// asserts), but does NOT pin the client to localhost — a plain client gets real gateways.
pub fn applyDefault() void {
    var pos: usize = 0;
    beginList(&pos);
    for (real_gateways) |g| {
        appendStr(&pos, g.server);
        appendStr(&pos, g.tz);
        appendStr(&pos, g.name);
    }
    endList(&pos);
    installDetour();
    log.print("realmgw: default Battle.net gateways installed (no realm flag)");
}

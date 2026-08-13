//! ver-IX86-1.dll / CheckRevision.dll — a FAITHFUL replica of the genuine (2020)
//! Battle.net CheckRevision module the 1.14d client downloads and calls during the
//! version check. Verified byte-for-byte identical to the real Blizzard DLL (loaded
//! in the same process) across many challenges — see CHECKREVISION.md.
//!
//! The genuine module is an Authenticode self-attest + SHA-1 responder:
//!   full = base64( SHA1( first4(b64decode(versionString)) + ":"+fileVersion+":" + sigOk ) )
//! and it returns that string SPLIT across the out-params (a quirk of reusing the
//! classic CheckRevision ABI slots):
//!   *lpDialogResult  = a MessageBoxW result (0 unless the legal-disclaimer path fires)
//!   *lpResultLength   = the FIRST 4 bytes of `full`, packed little-endian as a u32
//!   lpResultBuffer    = the REST of `full`, NUL-terminated  (also returned in EAX)
//!
//! Game.exe call site (BNDOWNLOAD_PerformCheckRevision @0x51e6d0):
//!   (*pfnCheckRevision)(&exePath, &emptyBuf, &emptyBuf, &challenge, &ver, &checksum, &result)
//! i.e. args 1-3 are the classic file paths (ignored here — we read the host EXE
//! ourselves), arg4 is the server challenge, args 5-7 are the split outputs above.
//!
//! The hash math, base64 and challenge decode live in `checkrev_core.zig`, which is
//! pure Zig (no Win32, no libc) so native realmd can compute/validate the same
//! response without wine. This file only adds the Win32 host-introspection: the EXE
//! file version (VERSION.dll) and the signature gate (WinVerifyTrust).
const std = @import("std");
const win = std.os.windows;
const core = @import("d2_bnet").checkrev;

extern "kernel32" fn GetModuleFileNameW(m: ?win.HMODULE, buf: [*]u16, n: u32) callconv(.winapi) u32;
extern "version" fn GetFileVersionInfoSizeW(f: [*:0]const u16, h: ?*u32) callconv(.winapi) u32;
extern "version" fn GetFileVersionInfoW(f: [*:0]const u16, h: u32, len: u32, data: *anyopaque) callconv(.winapi) i32;
extern "version" fn VerQueryValueW(blk: *const anyopaque, sub: [*:0]const u16, out: **anyopaque, outlen: *u32) callconv(.winapi) i32;
extern "wintrust" fn WinVerifyTrust(hwnd: ?win.HWND, action: *win.GUID, data: *anyopaque) callconv(.winapi) i32;

const VS_FIXEDFILEINFO = extern struct {
    dwSignature: u32,
    dwStrucVersion: u32,
    dwFileVersionMS: u32,
    dwFileVersionLS: u32,
    dwProductVersionMS: u32,
    dwProductVersionLS: u32,
    dwFileFlagsMask: u32,
    dwFileFlags: u32,
    dwFileOS: u32,
    dwFileType: u32,
    dwFileSubtype: u32,
    dwFileDateMS: u32,
    dwFileDateLS: u32,
};

// WINTRUST_ACTION_GENERIC_VERIFY_V2 {00AAC56B-CD44-11d0-8CC2-00C04FC295EE}
var WVT_GUID = win.GUID{ .Data1 = 0x00AAC56B, .Data2 = 0xCD44, .Data3 = 0x11D0, .Data4 = .{ 0x8C, 0xC2, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE } };

const WINTRUST_FILE_INFO = extern struct {
    cbStruct: u32 = @sizeOf(WINTRUST_FILE_INFO),
    pcwszFilePath: [*:0]const u16,
    hFile: ?win.HANDLE = null,
    pgKnownSubject: ?*win.GUID = null,
};
const WINTRUST_DATA = extern struct {
    cbStruct: u32 = @sizeOf(WINTRUST_DATA),
    pPolicyCallbackData: ?*anyopaque = null,
    pSIPClientData: ?*anyopaque = null,
    dwUIChoice: u32 = 2, // WTD_UI_NONE
    fdwRevocationChecks: u32 = 0,
    dwUnionChoice: u32 = 1, // WTD_CHOICE_FILE
    pFile: ?*WINTRUST_FILE_INFO = null,
    dwStateAction: u32 = 0,
    hWVTStateData: ?*anyopaque = null,
    pwszURLReference: ?*u16 = null,
    dwProvFlags: u32 = 0,
    dwUIContext: u32 = 0,
};

fn fileTrusted(pathW: [*:0]const u16) bool {
    var fi = WINTRUST_FILE_INFO{ .pcwszFilePath = pathW };
    var wd = WINTRUST_DATA{ .pFile = &fi };
    return WinVerifyTrust(null, &WVT_GUID, &wd) == 0;
}

/// Read the host EXE's VS_FIXEDFILEINFO version as "a.b.c.d" (genuine default: "0.0.0.0").
fn hostVersion(out: []u8) []const u8 {
    var pathW: [260]u16 = undefined;
    if (GetModuleFileNameW(null, &pathW, 260) == 0) return "0.0.0.0";
    pathW[259] = 0;
    var handle: u32 = 0;
    const sz = GetFileVersionInfoSizeW(@ptrCast(&pathW), &handle);
    if (sz == 0 or sz > 8192) return "0.0.0.0";
    var blk: [8192]u8 = undefined;
    if (GetFileVersionInfoW(@ptrCast(&pathW), 0, sz, &blk) == 0) return "0.0.0.0";
    var ffi: *anyopaque = undefined;
    var flen: u32 = 0;
    const root = [_:0]u16{'\\'};
    if (VerQueryValueW(&blk, &root, &ffi, &flen) == 0 or flen == 0) return "0.0.0.0";
    const v: *VS_FIXEDFILEINFO = @ptrCast(@alignCast(ffi));
    const r = std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{
        (v.dwFileVersionMS >> 16) & 0xFFFF,
        v.dwFileVersionMS & 0xFFFF,
        (v.dwFileVersionLS >> 16) & 0xFFFF,
        v.dwFileVersionLS & 0xFFFF,
    }) catch return "0.0.0.0";
    return r;
}

pub export fn DllMain(_: win.HINSTANCE, _: win.DWORD, _: ?*anyopaque) callconv(.winapi) win.BOOL {
    return win.BOOL.TRUE;
}

pub export fn CheckRevision(
    _: usize, // arg1 exePath (classic file1) — unused; we read the host ourselves
    _: usize, // arg2 (classic file2) — unused
    _: usize, // arg3 (classic file3) — unused
    versionString: [*:0]const u8, // arg4: server challenge (base64)
    lpDialogResult: *i32, // arg5
    lpResultLength: *u32, // arg6
    lpResultBuffer: [*]u8, // arg7
) callconv(.{ .x86_stdcall = .{} }) ?*anyopaque {
    lpDialogResult.* = 0;
    lpResultLength.* = 0;
    lpResultBuffer[0] = 0;

    const challenge = std.mem.span(versionString);

    // host EXE file version (the genuine DLL hashes this, not the path)
    var verbuf: [64]u8 = undefined;
    const version = hostVersion(&verbuf);

    // sigOk: honest WinVerifyTrust on the host EXE. The self-module half is assumed
    // trusted (we ARE the legitimate module), so against a Blizzard-signed Game.exe
    // this yields 1 — matching the genuine DLL; against anything untrusted, 0.
    var pathW: [260]u16 = undefined;
    _ = GetModuleFileNameW(null, &pathW, 260);
    pathW[259] = 0;
    const sig_ok: u8 = if (fileTrusted(@ptrCast(&pathW))) 1 else 0;

    var full: [40]u8 = undefined;
    const resp = core.response(challenge, version, sig_ok, &full) orelse return @ptrCast(lpResultBuffer);

    // genuine output split: first 4 bytes -> *lpResultLength (LE u32), rest -> buffer + NUL
    if (resp.len >= 4) {
        lpResultLength.* = @as(u32, resp[0]) | (@as(u32, resp[1]) << 8) |
            (@as(u32, resp[2]) << 16) | (@as(u32, resp[3]) << 24);
        const rest = resp[4..];
        @memcpy(lpResultBuffer[0..rest.len], rest);
        lpResultBuffer[rest.len] = 0;
    }
    return @ptrCast(lpResultBuffer);
}

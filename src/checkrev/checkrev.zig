//! ver-IX86-1.dll — the CheckRevision module realmd packs into the version-check
//! MPQ it serves over BNFTP.
//!
//! D2 1.14d (BNDOWNLOAD_PerformCheckRevision) downloads ver-IX86-1.mpq, extracts
//! the inner file <basename>.dll (= ver-IX86-1.dll), Authenticode-verifies it
//! (must be signed O="Blizzard Entertainment, Inc."), LoadLibrary's it, and calls
//! the exported `CheckRevision`. realmd accepts ANY SID_AUTH_CHECK, so we just
//! return plausible dummy version/checksum and complete the flow without crashing.
//!
//! ABI (from the call site `*pFVar4(file1,file2,file3,formula,*ver,*sum,info)`):
//! 7 args. FARPROC is stdcall in the Win32 headers, so we export stdcall. We log
//! to realmd_checkrev.txt in the game CWD so we can confirm the client actually
//! loaded+called us (i.e. passed both signature gates). See [[d2-checkrevision]].
const std = @import("std");
const win = std.os.windows;

const FILE_APPEND_DATA: u32 = 4;
const FILE_SHARE_RW: u32 = 3;
const OPEN_ALWAYS: u32 = 4;
const INVALID_HANDLE: ?win.HANDLE = @ptrFromInt(std.math.maxInt(usize));

extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: u32, share: u32, sec: ?*anyopaque, disp: u32, flags: u32, tmpl: ?win.HANDLE) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn WriteFile(h: win.HANDLE, buf: [*]const u8, n: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: win.HANDLE) callconv(.winapi) i32;

fn mark(msg: []const u8) void {
    const h = CreateFileA("realmd_checkrev.txt", FILE_APPEND_DATA, FILE_SHARE_RW, null, OPEN_ALWAYS, 0x80, null) orelse return;
    if (h == INVALID_HANDLE) return;
    defer _ = CloseHandle(h);
    var w: u32 = 0;
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), &w, null);
}

pub export fn DllMain(_: win.HINSTANCE, _: win.DWORD, _: ?*anyopaque) callconv(.winapi) win.BOOL {
    return win.BOOL.TRUE;
}

pub export fn CheckRevision(
    file1: ?[*:0]const u8,
    file2: ?[*:0]const u8,
    file3: ?[*:0]const u8,
    formula: ?[*:0]const u8,
    out_version: *u32,
    out_checksum: *u32,
    out_exeinfo: [*]u8,
) callconv(.{ .x86_stdcall = .{} }) c_int {
    _ = .{ file1, file2, file3, formula };
    mark("CheckRevision called (stdcall)\n");
    out_version.* = 0x0100_0001; // any value — server accepts any AUTH_CHECK
    out_checksum.* = 0xDEAD_BEEF;
    const info = "Game.exe 01/01/14 00:00:00 1234567";
    @memcpy(out_exeinfo[0..info.len], info);
    out_exeinfo[info.len] = 0;
    return 1; // nonzero = success
}

//! Dead-simple file logger — appends to d2gs_log.txt in the process CWD (the
//! game dir). Avoids std.fs so it works the moment the DLL attaches.
const std = @import("std");
const win = std.os.windows;

const GENERIC_WRITE: u32 = 0x4000_0000;
const FILE_SHARE_READ: u32 = 1;
const OPEN_ALWAYS: u32 = 4;
const FILE_APPEND_DATA: u32 = 4;
const INVALID_HANDLE: ?win.HANDLE = @ptrFromInt(std.math.maxInt(usize));

const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

extern "kernel32" fn CreateFileA(
    name: [*:0]const u8,
    access: u32,
    share: u32,
    sec: ?*anyopaque,
    disp: u32,
    flags: u32,
    template: ?win.HANDLE,
) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn WriteFile(h: win.HANDLE, buf: [*]const u8, n: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: win.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn AllocConsole() callconv(.winapi) i32;

/// Ensure stdout is usable. If the process already has a stdout handle (wine
/// passes the launching terminal's stdout through to the app), keep it — that's
/// the one connected to the Linux tty/pipe. Only AllocConsole as a fallback when
/// there's no handle at all (e.g. real Windows GUI subsystem with no console).
pub fn initConsole() void {
    const h = GetStdHandle(STD_OUTPUT_HANDLE);
    if (h == null or h == INVALID_HANDLE) _ = AllocConsole();
}

fn writeAll(h: win.HANDLE, msg: []const u8) void {
    var w: u32 = 0;
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), &w, null);
    _ = WriteFile(h, "\n", 1, &w, null);
}

pub fn print(msg: []const u8) void {
    // stdout — so `wine Game.exe ...` shows logs like a normal Linux CLI process.
    if (GetStdHandle(STD_OUTPUT_HANDLE)) |out| {
        if (out != INVALID_HANDLE) writeAll(out, msg);
    }
    // file — survives even when there's no console.
    const h = CreateFileA("d2gs_log.txt", FILE_APPEND_DATA, FILE_SHARE_READ, null, OPEN_ALWAYS, 0, null) orelse return;
    if (h == INVALID_HANDLE) return;
    defer _ = CloseHandle(h);
    writeAll(h, msg);
}

/// Append "<prefix>0xHEX\n".
pub fn hex(prefix: []const u8, value: usize) void {
    var buf: [16]u8 = undefined;
    const hexd = "0123456789abcdef";
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v != 0) : (v >>= 4) {
        i -= 1;
        buf[i] = hexd[v & 0xf];
    }
    var line: [64]u8 = undefined;
    var n: usize = 0;
    for (prefix) |c| {
        if (n >= line.len) break;
        line[n] = c;
        n += 1;
    }
    for (buf[i..]) |c| {
        if (n >= line.len) break;
        line[n] = c;
        n += 1;
    }
    print(line[0..n]);
}

/// Log "<prefix><null-terminated C string at ptr>". Safe on null/garbage-ish ptr
/// (bounded scan). ptr may be 0.
pub fn cstr(prefix: []const u8, ptr: usize) void {
    var line: [160]u8 = undefined;
    var n: usize = 0;
    for (prefix) |c| {
        if (n >= line.len) break;
        line[n] = c;
        n += 1;
    }
    if (ptr != 0) {
        const s: [*]const u8 = @ptrFromInt(ptr);
        var i: usize = 0;
        while (i < 64 and s[i] != 0 and n < line.len) : (i += 1) {
            line[n] = s[i];
            n += 1;
        }
    }
    print(line[0..n]);
}

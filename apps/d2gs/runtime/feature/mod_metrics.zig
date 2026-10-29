//! The loaded mods' own Prometheus text, appended to /metrics.
//!
//! Every DLL the process was started with through `--loaddll <path>` that exports
//! `d2gs_metrics(buf: [*]u8, cap: u32) callconv(.c) u32` is asked, on the health thread, to render
//! its families into the rest of the buffer; it returns the bytes it wrote. A mod without the
//! export is skipped. The mods are found by the base name of each `--loaddll` path.
const std = @import("std");
const gs_health = @import("gs_health");

const LPWSTR = [*:0]u16;
const HMODULE = *opaque {};
const MetricsFn = *const fn (buf: [*]u8, cap: u32) callconv(.c) u32;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPWSTR;
extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(h: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "shell32" fn CommandLineToArgvW(cmd: LPWSTR, argc: *c_int) callconv(.winapi) ?[*]LPWSTR;

/// The `--loaddll` values in `argv`.
pub fn loadedDlls(argv: []const [*:0]const u16, out: [][*:0]const u16) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < argv.len and n < out.len) : (i += 1) {
        if (!eqlAscii(argv[i], "--loaddll")) continue;
        out[n] = argv[i + 1];
        n += 1;
        i += 1;
    }
    return n;
}

/// The part of a path after its last `\` or `/`.
pub fn baseName(path: [*:0]const u16) [*:0]const u16 {
    var base = path;
    var i: usize = 0;
    while (path[i] != 0) : (i += 1) {
        if (path[i] == '\\' or path[i] == '/') base = path + i + 1;
    }
    return base;
}

fn eqlAscii(a: [*:0]const u16, comptime lit: []const u8) bool {
    for (lit, 0..) |c, i| if (a[i] != c) return false;
    return a[lit.len] == 0;
}

/// Each loaded mod's metrics after what `w` holds, as far as the buffer goes.
pub fn append(w: *gs_health.Writer) void {
    var argc: c_int = 0;
    const argv = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return;
    defer _ = LocalFree(@ptrCast(argv));
    const args: [*]const [*:0]const u16 = @ptrCast(argv);
    var dlls: [16][*:0]const u16 = undefined;
    const n = loadedDlls(args[0..@intCast(argc)], &dlls);
    for (dlls[0..n]) |path| {
        const h = GetModuleHandleW(baseName(path)) orelse continue;
        const f: MetricsFn = @ptrCast(GetProcAddress(h, "d2gs_metrics") orelse continue);
        const room = w.buf.len - w.n;
        if (room == 0) return;
        const got = f(w.buf[w.n..].ptr, @intCast(room));
        w.n += @min(got, room);
    }
}

const testing = std.testing;
const W = std.unicode.utf8ToUtf16LeStringLiteral;

test "the --loaddll values and their base names" {
    const argv = [_][*:0]const u16{ W("Game.exe"), W("--loaddll"), W("Z:\\mods\\my_mod.dll"), W("-w"), W("--loaddll"), W("plain.dll"), W("--loaddll") };
    var out: [4][*:0]const u16 = undefined;
    const n = loadedDlls(&argv, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u16, W("my_mod.dll"), std.mem.span(baseName(out[0])));
    try testing.expectEqualSlices(u16, W("plain.dll"), std.mem.span(baseName(out[1])));
    try testing.expectEqualSlices(u16, W("x.dll"), std.mem.span(baseName(W("a/b\\x.dll"))));
}

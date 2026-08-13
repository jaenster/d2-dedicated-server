//! Dead-simple logger — writes to stdout + d2gs_log.txt in the process CWD. Avoids
//! std.fs so it works the moment the DLL attaches. When `json` is set (default), each
//! line is emitted as a structured object `{"ts","tag":"d2gs","msg",[ "game","gsid"]}`
//! — matching realmd's log shape — auto-stamping the ambient game context (logctx.zig)
//! so every line is queryable in Loki/Grafana and tells which game it belongs to.
const std = @import("std");
const win = std.os.windows;
const obs = @import("obs");

/// Emit structured JSON lines instead of raw text. On by default (the GS is a server);
/// set false at boot for human-readable local runs.
pub var json: bool = true;

const FILETIME = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetSystemTimeAsFileTime(ft: *FILETIME) callconv(.winapi) void;

/// Wall-clock unix seconds (kernel32; no libc dependency).
fn unixSeconds() u64 {
    var ft: FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    const ticks = (@as(u64, ft.high) << 32) | ft.low; // 100ns intervals since 1601
    return (ticks -% 116444736000000000) / 10000000; // → seconds since 1970
}

/// Wall-clock unix milliseconds — the host clock obs.zig uses for span durations.
fn unixMillis() u64 {
    var ft: FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    const ticks = (@as(u64, ft.high) << 32) | ft.low;
    return (ticks -% 116444736000000000) / 10000; // → ms since 1970
}

/// Span-complete sink: a span's exit emits one structured line. print() auto-stamps the
/// trace + span (still current at exit) + token/gsid, so it slots into the trace.
fn onSpanExit(name: []const u8, dur_ms: u64) void {
    var b: [96]u8 = undefined;
    var n: usize = appendStr(&b, 0, "span ");
    n = appendStr(&b, n, name);
    n = appendStr(&b, n, " dur_ms=");
    n = appendDec(&b, n, dur_ms);
    print(b[0..n]);
}

/// Point obs.zig at the GS host clock + span sink. Call once at boot.
pub fn initObs() void {
    obs.nowMsFn = &unixMillis;
    obs.spanSink = &onSpanExit;
}

const GENERIC_WRITE: u32 = 0x4000_0000;
const FILE_SHARE_READ: u32 = 1;
const FILE_SHARE_WRITE: u32 = 2;
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
    // Message and newline in ONE WriteFile. Under wine every call crosses to wineserver, so a
    // second one to write a single byte doubles the cost of logging a line.
    var w: u32 = 0;
    var buf: [1024]u8 = undefined;
    if (msg.len + 1 <= buf.len) {
        @memcpy(buf[0..msg.len], msg);
        buf[msg.len] = '\n';
        _ = WriteFile(h, &buf, @intCast(msg.len + 1), &w, null);
        return;
    }
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), &w, null);
    _ = WriteFile(h, "\n", 1, &w, null);
}

/// The append handle for d2gs_log.txt, opened once. 0 = not yet opened, 1 = opening failed.
///
/// This used to CreateFileA + CloseHandle around every line, which under wine is an open, a
/// stat and a close per log line, each a wineserver round trip -- together about a tenth of the
/// game server's CPU. FILE_SHARE_WRITE matters now that the handle is held: a second GS on the
/// same directory could not open the file at all otherwise. FILE_APPEND_DATA keeps concurrent
/// appends atomic, so a shared handle needs no lock of its own.
var log_handle = std.atomic.Value(usize).init(0);

fn logFile() ?win.HANDLE {
    switch (log_handle.load(.acquire)) {
        0 => {},
        1 => return null,
        else => |v| return @ptrFromInt(v),
    }
    const h = CreateFileA("d2gs_log.txt", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_ALWAYS, 0, null);
    const v: usize = if (h) |hh| (if (hh == INVALID_HANDLE) 1 else @intFromPtr(hh)) else 1;
    // Two threads racing here both open; the loser closes its own and uses the winner's.
    if (log_handle.cmpxchgStrong(0, v, .acq_rel, .acquire)) |won| {
        if (v > 1) _ = CloseHandle(@ptrFromInt(v));
        return if (won <= 1) null else @ptrFromInt(won);
    }
    return if (v <= 1) null else @ptrFromInt(v);
}

/// Write one line to both sinks: stdout (so `wine Game.exe` logs like a normal CLI
/// process) and d2gs_log.txt (survives with no console).
fn emit(line: []const u8) void {
    if (GetStdHandle(STD_OUTPUT_HANDLE)) |out| {
        if (out != INVALID_HANDLE) writeAll(out, line);
    }
    if (logFile()) |h| writeAll(h, line);
}

/// Raw, uncapped passthrough to both sinks — NO structured `{"ts","msg":...}` wrapper
/// and no 768-byte truncation. For payloads that are already a complete JSON line and
/// may be very large (the DRLG oracle dumps a whole level per line). Use sparingly.
pub fn printRaw(msg: []const u8) void {
    emit(msg);
}

/// The single funnel — every print/hex/cstr helper ends here. In JSON mode it wraps
/// `msg` in `{"ts","tag":"d2gs","msg",[ "game","gsid"]}`, stamping the ambient game
/// context (logctx). The fixed buffer can't overflow (escape + truncate are bounded).
pub fn print(msg: []const u8) void {
    if (!json) {
        emit(msg);
        return;
    }
    var b: [768]u8 = undefined;
    var n: usize = appendStr(&b, 0, "{\"ts\":");
    n = appendDec(&b, n, unixSeconds());
    n = appendStr(&b, n, ",\"tag\":\"d2gs\",\"msg\":\"");
    n = appendEsc(&b, n, msg);
    n = appendStr(&b, n, "\"");
    // ambient trace/span context (per-thread) — correlate logs across a trace + with
    // srvtrace events (same `token`), and forward-compatible with OTLP/Tempo.
    const c = obs.current();
    if (c.hasTrace()) {
        var th: [32]u8 = undefined;
        n = appendStr(&b, n, ",\"trace\":\"");
        n = appendStr(&b, n, obs.traceHex(&th, c.trace_hi, c.trace_lo));
        n = appendStr(&b, n, "\",\"span\":");
        n = appendDec(&b, n, c.span);
        if (c.parent != 0) {
            n = appendStr(&b, n, ",\"parent\":");
            n = appendDec(&b, n, c.parent);
        }
    }
    if (c.acct_len != 0) {
        n = appendStr(&b, n, ",\"acct\":\"");
        n = appendEsc(&b, n, c.account());
        n = appendStr(&b, n, "\"");
    }
    if (c.token != 0) {
        // same key srvtrace events use, so a log line correlates with its game's events
        n = appendStr(&b, n, ",\"token\":");
        n = appendDec(&b, n, c.token);
    }
    if (obs.gsid != 0) {
        n = appendStr(&b, n, ",\"gsid\":");
        n = appendDec(&b, n, obs.gsid);
    }
    n = appendStr(&b, n, "}");
    emit(b[0..n]);
}

/// Append the decimal of `value` into `line` at `n`; returns the new length.
fn appendDec(line: []u8, n_in: usize, value: u64) usize {
    var buf: [20]u8 = undefined;
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v != 0) : (v /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
    }
    return appendStr(line, n_in, buf[i..]);
}

/// Append a JSON-escaped copy of `s` into `line` at `n` (leaves 2 bytes of slack so a
/// 2-char escape never splits); returns the new length.
fn appendEsc(line: []u8, n_in: usize, s: []const u8) usize {
    var n = n_in;
    for (s) |c| {
        if (n + 2 >= line.len) break;
        switch (c) {
            '"' => {
                line[n] = '\\';
                line[n + 1] = '"';
                n += 2;
            },
            '\\' => {
                line[n] = '\\';
                line[n + 1] = '\\';
                n += 2;
            },
            '\n' => {
                line[n] = '\\';
                line[n + 1] = 'n';
                n += 2;
            },
            '\r' => {
                line[n] = '\\';
                line[n + 1] = 'r';
                n += 2;
            },
            '\t' => {
                line[n] = '\\';
                line[n + 1] = 't';
                n += 2;
            },
            0...8, 11, 12, 14...0x1f => {}, // drop other control chars
            else => {
                line[n] = c;
                n += 1;
            },
        }
    }
    return n;
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

/// Append the lowercase hex of `value` into `line` at `n`, return new `n`.
fn appendHex(line: []u8, n_in: usize, value: usize) usize {
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
    var n = n_in;
    for (buf[i..]) |c| {
        if (n >= line.len) break;
        line[n] = c;
        n += 1;
    }
    return n;
}

fn appendStr(line: []u8, n_in: usize, s: []const u8) usize {
    var n = n_in;
    for (s) |c| {
        if (n >= line.len) break;
        line[n] = c;
        n += 1;
    }
    return n;
}

/// Append "<prefix> 0x<a> 0x<b>\n" — two hex values on one line.
pub fn hex2(prefix: []const u8, a: usize, b: usize) void {
    var line: [96]u8 = undefined;
    var n: usize = appendStr(&line, 0, prefix);
    n = appendStr(&line, n, " 0x");
    n = appendHex(&line, n, a);
    n = appendStr(&line, n, " 0x");
    n = appendHex(&line, n, b);
    print(line[0..n]);
}

/// Append "<prefix> 0x<a> 0x<b> 0x<c>\n" — three hex values on one line.
pub fn hex3(prefix: []const u8, a: usize, b: usize, c: usize) void {
    var line: [128]u8 = undefined;
    var n: usize = appendStr(&line, 0, prefix);
    n = appendStr(&line, n, " 0x");
    n = appendHex(&line, n, a);
    n = appendStr(&line, n, " 0x");
    n = appendHex(&line, n, b);
    n = appendStr(&line, n, " 0x");
    n = appendHex(&line, n, c);
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

//! make_vermpq — build a version-check MPQ for realmd to serve over BNFTP.
//!   make_vermpq <out.mpq> <local-dll> <archive-name>
//!
//! Adds the (Authenticode-signed) CheckRevision DLL into a fresh MPQ under the
//! name the client extracts (<mpq-basename>.dll), then applies the Blizzard WEAK
//! signature (StormLib has the factored key built in) so the client's
//! SFILE_VerifyFileSignature accepts it. See ../../src/realmd/assets/README.md.
//!
//! Links StormLib (a C library); built by build.sh via `zig build-exe`.
const std = @import("std");

// ── StormLib C ABI ───────────────────────────────────────────────────────────
const HANDLE = ?*anyopaque;
const DWORD = u32;
const BOOL = c_int;

extern fn SFileCreateArchive(name: [*:0]const u8, create_flags: DWORD, max_files: DWORD, out: *HANDLE) callconv(.c) BOOL;
extern fn SFileAddFileEx(mpq: HANDLE, file: [*:0]const u8, archived: [*:0]const u8, flags: DWORD, compression: DWORD, compression_next: DWORD) callconv(.c) BOOL;
extern fn SFileSignArchive(mpq: HANDLE, signature_type: DWORD) callconv(.c) BOOL;
extern fn SFileCloseArchive(mpq: HANDLE) callconv(.c) BOOL;
extern fn remove(path: [*:0]const u8) callconv(.c) c_int; // libc — overwrite a stale MPQ

const MPQ_CREATE_LISTFILE: DWORD = 0x0010_0000;
const MPQ_CREATE_ATTRIBUTES: DWORD = 0x0020_0000;
const MPQ_FILE_COMPRESS: DWORD = 0x0000_0200;
const MPQ_COMPRESSION_ZLIB: DWORD = 0x02;
const SIGNATURE_TYPE_WEAK: DWORD = 1;

fn die(comptime msg: []const u8) u8 {
    std.debug.print("make_vermpq: {s}\n", .{msg});
    return 1;
}

fn usage() u8 {
    std.debug.print("usage: make_vermpq <out.mpq> <local-dll> <archive-name>\n", .{});
    return 2;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // program name
    const out = it.next() orelse return usage();
    const dll = it.next() orelse return usage();
    const arcname = it.next() orelse return usage();
    if (it.next() != null) return usage(); // too many args

    _ = remove(out.ptr); // overwrite if it exists

    var mpq: HANDLE = null;
    if (SFileCreateArchive(out.ptr, MPQ_CREATE_LISTFILE | MPQ_CREATE_ATTRIBUTES, 16, &mpq) == 0)
        return die("SFileCreateArchive failed");
    if (SFileAddFileEx(mpq, dll.ptr, arcname.ptr, MPQ_FILE_COMPRESS, MPQ_COMPRESSION_ZLIB, MPQ_COMPRESSION_ZLIB) == 0) {
        _ = SFileCloseArchive(mpq);
        return die("SFileAddFileEx failed");
    }
    if (SFileSignArchive(mpq, SIGNATURE_TYPE_WEAK) == 0) {
        _ = SFileCloseArchive(mpq);
        return die("SFileSignArchive(WEAK) failed");
    }
    if (SFileCloseArchive(mpq) == 0)
        return die("SFileCloseArchive failed");

    std.debug.print("wrote {s} (weak-signed, contains {s})\n", .{ out, arcname });
    return 0;
}

//! Loading a 32-bit Mach-O executable into this process, without dyld and without converting it
//! to anything else.
//!
//! Diablo II's Mac build is the same game as the Windows build, compiled for a different host ABI.
//! Running it needs three things: its segments mapped, its pointers slid to wherever they landed,
//! and its imports pointed at something. None of that needs a file format conversion — the image
//! is mapped as it ships and every fixup dyld would have applied is applied here.

const std = @import("std");

pub const image = @import("image.zig");
pub const fixups = @import("fixups.zig");
pub const load = @import("load.zig");

pub const Image = image.Image;
pub const Segment = image.Segment;

/// Every distinct symbol the image imports, sorted. Both streams are walked: the eager one holds
/// data references, the lazy one holds the several hundred function stubs, and neither is a subset
/// of the other.
pub fn collectImports(gpa: std.mem.Allocator, img: *const Image) ![][]const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    const Collector = struct {
        gpa: std.mem.Allocator,
        seen: *std.StringHashMapUnmanaged(void),

        pub fn bind(self: @This(), _: fixups.Site, _: fixups.BindType, name: []const u8, _: i64) !void {
            try self.seen.put(self.gpa, name, {});
        }
    };
    const c: Collector = .{ .gpa = gpa, .seen = &seen };

    const d = img.dyld;
    try fixups.walkBind(img.bytes[d.bind_off..][0..d.bind_size], true, c);
    try fixups.walkBind(img.bytes[d.lazy_bind_off..][0..d.lazy_bind_size], false, c);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = seen.keyIterator();
    while (it.next()) |k| try out.append(gpa, k.*);
    const names = try out.toOwnedSlice(gpa);
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return names;
}

/// Count of rebase sites, which is what a load has to rewrite before the image can run anywhere
/// other than its preferred address.
pub fn countRebases(img: *const Image) !usize {
    const Counter = struct {
        n: *usize,
        pub fn rebase(self: @This(), _: fixups.Site, _: fixups.RebaseType) !void {
            self.n.* += 1;
        }
    };
    var n: usize = 0;
    const d = img.dyld;
    try fixups.walkRebase(img.bytes[d.rebase_off..][0..d.rebase_size], Counter{ .n = &n });
    return n;
}

/// Map the executable read-only. Deliberately raw POSIX rather than std.Io: this is the one file
/// the loader reads, it reads it once at startup, and threading an Io through for it would be the
/// only reason the package needed one.
///
/// Mapped rather than slurped because the bytes have to outlive the load either way — every import
/// name a thunk reports, possibly hours later, points into them, as do the load commands. Held as a
/// mapping they are file-backed and clean, so N server processes on one host share one copy and the
/// kernel may evict it; slurped they were private dirty, duplicated per process, and the growing
/// read left its abandoned generations behind in the arena as well.
pub fn mapFile(path: [*:0]const u8) ![]align(std.heap.page_size_min) const u8 {
    var f = try openImage(path);
    f.closeFd();
    return f.bytes;
}

/// The same mapping with its descriptor still open, which is what a loader needs: the segments are
/// mapped from the file a second time, so the pages the image never writes stay clean and shared
/// instead of being copied into anonymous memory per process.
pub const File = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fd: c_int,

    /// The descriptor is only needed until the segments are mapped; the mapping outlives it.
    pub fn closeFd(self: *File) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

pub fn openImage(path: [*:0]const u8) !File {
    const fd = open(path, 0); // O_RDONLY is 0 everywhere this runs
    if (fd < 0) return error.FileNotFound;
    errdefer _ = std.c.close(fd);

    // Sized by reading rather than by fstat, for the reason the slurp had: musl's i386 fstat is not
    // exposed as one symbol across targets, and a counting loop needs no agreement about which
    // struct stat this platform uses. A short read is normal on a bind-mounted filesystem, so this
    // counts what it was actually given and stops only at end of file.
    var size: usize = 0;
    var chunk: [64 << 10]u8 = undefined;
    while (true) {
        const got = std.c.read(fd, &chunk, chunk.len);
        if (got < 0) return error.ReadFailed;
        if (got == 0) break;
        size += @intCast(got);
    }
    if (size == 0) return error.ReadFailed;

    const bytes = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    return .{ .bytes = bytes, .fd = fd };
}

pub fn unmapFile(bytes: []align(std.heap.page_size_min) const u8) void {
    std.posix.munmap(bytes);
}

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;

/// The game binary, if this machine has one. Reading it is how the tests here stay honest, and it
/// is never in the repo — `D2MAC_BIN` points at an installed copy.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

fn testImage() !?[]align(std.heap.page_size_min) const u8 {
    const path = getenv("D2MAC_BIN") orelse return null;
    return mapFile(path) catch null;
}

const testing = std.testing;

test "the 1.14d Mac binary parses into the segments a loader has to map" {
    const bytes = (try testImage()) orelse return error.SkipZigTest;
    defer unmapFile(bytes);

    const img = try image.parse(bytes);

    // __PAGEZERO, __TEXT, __DATA, __OBJC, __LINKEDIT. __TEXT wants 0x1000, which is below Linux's
    // default mmap_min_addr — the image has to slide, and rebase is what makes that legal.
    try testing.expectEqual(@as(usize, 5), img.segments().len);
    try testing.expectEqual(@as(u32, 0x1000), img.segment("__TEXT").?.vmaddr);
    try testing.expectEqual(@as(u32, 0x396000), img.segment("__DATA").?.vmaddr);

    // __DATA's vmsize exceeds its filesize: the difference is bss and must be mapped as zeroes
    // rather than left short.
    const data = img.segment("__DATA").?;
    try testing.expect(data.vmsize > data.filesize);

    const span = img.span();
    try testing.expectEqual(@as(u32, 0x1000), span.low);
    // The whole process image is a few megabytes. This is the number the wine stack is being
    // compared against.
    try testing.expect(span.high - span.low < 8 << 20);
}

test "entry point and fixup streams" {
    const bytes = (try testImage()) orelse return error.SkipZigTest;
    defer unmapFile(bytes);

    const img = try image.parse(bytes);
    const text = img.segment("__TEXT").?;
    try testing.expect(img.entry >= text.vmaddr and img.entry < text.vmaddr + text.vmsize);

    try testing.expect(try countRebases(&img) > 0);

    // 45 C++ static constructors sit in __DATA,__mod_init_func. dyld would run them; a loader that
    // does not leaves every one of those globals at zero.
    const init = img.initializers().?;
    try testing.expectEqual(@as(u32, 0x396d38), init.addr);
    try testing.expectEqual(@as(u32, 45), init.size / 4);
}

test "the import set is the shim's whole job" {
    const gpa = testing.allocator;
    const bytes = (try testImage()) orelse return error.SkipZigTest;
    defer unmapFile(bytes);

    const img = try image.parse(bytes);
    const names = try collectImports(gpa, &img);
    defer gpa.free(names);

    // 641 undefined symbols in the symbol table, and the bind streams reach all but the two
    // dyld-private ones. Every name here needs an address at load time or the image faults on
    // first use.
    try testing.expect(names.len > 600);
    try testing.expect(names.len <= 641);

    var found_pthread = false;
    var found_gl = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "_pthread_create")) found_pthread = true;
        if (std.mem.startsWith(u8, n, "_agl")) found_gl = true;
    }
    // Threads are POSIX and port straight across; AGL is the part a headless server never reaches.
    try testing.expect(found_pthread);
    try testing.expect(found_gl);
}

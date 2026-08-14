//! Mapping the image and applying the fixups dyld would have.
//!
//! The image is copied into anonymous memory rather than mapped from the file. It costs a few
//! megabytes of memcpy once, and it buys the ability to write rebases and binds into __TEXT before
//! that segment is made read-only — which a file-backed private mapping would also allow, but only
//! by dirtying the same pages anyway.

const std = @import("std");
const image = @import("image.zig");
const fixups = @import("fixups.zig");

pub const Error = error{
    SegmentOutOfRange,
    UnsupportedFixup,
    UnresolvedImport,
    ProtectFailed,
} || fixups.Error || std.posix.MMapError;

/// Resolve an imported symbol name to an address in this process, or null if nothing provides it.
pub const Resolver = *const fn (name: []const u8) ?usize;

pub const Loaded = struct {
    img: image.Image,
    memory: []align(std.heap.page_size_min) u8,
    /// Distance between where the image wanted to be and where it is. Every address read out of
    /// Ghidra needs this added before it means anything at runtime.
    slide: i64,
    /// The name that could not be resolved, kept because a bind failure is the interesting kind:
    /// it names the exact piece of the host the game wants and the shim has not implemented.
    missing: ?[]const u8 = null,

    pub fn entry(self: *const Loaded) usize {
        return @intCast(@as(i64, self.img.entry) + self.slide);
    }

    /// Runtime address of an address read out of Ghidra.
    pub fn at(self: *const Loaded, static_addr: u32) usize {
        return @intCast(@as(i64, static_addr) + self.slide);
    }

    pub fn unmap(self: *Loaded) void {
        std.posix.munmap(self.memory);
    }
};

/// Map every segment and copy its file contents in. Nothing is executable yet and no fixup has
/// been applied — the image is inert until `applyFixups` and `protect` have run.
pub fn map(img: *const image.Image) Error!Loaded {
    const span = img.span();
    const total = std.mem.alignForward(usize, span.high - span.low, std.heap.page_size_min);

    // One reservation for the whole image so the segments keep their relative layout; the game
    // computes addresses across segment boundaries and a per-segment mapping would scatter them.
    const memory = try std.posix.mmap(
        null,
        total,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer std.posix.munmap(memory);

    const slide: i64 = @as(i64, @intCast(@intFromPtr(memory.ptr))) - @as(i64, span.low);

    for (img.segments()) |seg| {
        if (seg.vmsize == 0 or seg.is("__PAGEZERO")) continue;
        if (seg.filesize == 0) continue; // bss: the anonymous mapping is already zeroed
        const dst_off = seg.vmaddr - span.low;
        const n = @min(seg.filesize, seg.vmsize);
        @memcpy(memory[dst_off..][0..n], img.bytes[seg.fileoff..][0..n]);
    }

    return .{ .img = img.*, .memory = memory, .slide = slide };
}

const Applier = struct {
    loaded: *Loaded,
    resolve: Resolver,

    /// The four bytes a fixup rewrites, as bytes. Nothing in the format promises a fixup site is
    /// four-byte aligned, so this deliberately does not produce a `*u32`.
    fn slot(self: Applier, site: fixups.Site) Error!*[4]u8 {
        const segs = self.loaded.img.segments();
        if (site.segment >= segs.len) return Error.SegmentOutOfRange;
        const seg = segs[site.segment];
        const low = self.loaded.img.span().low;
        if (seg.vmaddr < low) return Error.SegmentOutOfRange; // __PAGEZERO holds no fixups
        const off = @as(u64, seg.vmaddr - low) + site.offset;
        if (off + 4 > self.loaded.memory.len) return Error.SegmentOutOfRange;
        return self.loaded.memory[@intCast(off)..][0..4];
    }

    /// Runtime address of the fixup site itself, which the PC-relative kinds are measured from.
    fn siteAddr(self: Applier, site: fixups.Site) Error!u32 {
        const segs = self.loaded.img.segments();
        if (site.segment >= segs.len) return Error.SegmentOutOfRange;
        const vm = @as(i64, segs[site.segment].vmaddr) + @as(i64, @intCast(site.offset)) + self.loaded.slide;
        return @truncate(@as(u64, @bitCast(vm)));
    }

    /// The three kinds differ only in what "the address" means at the site. `pointer` is a data
    /// word; the two text kinds sit inside instructions, which is also why a site cannot be assumed
    /// aligned. PC-relative displacements are measured from the end of the four bytes.
    pub fn rebase(self: Applier, site: fixups.Site, kind: fixups.RebaseType) Error!void {
        const p = try self.slot(site);
        const cur = std.mem.readInt(u32, p, .little);
        const slid: i64 = @as(i64, cur) + self.loaded.slide;
        const value: u32 = switch (kind) {
            .pointer, .text_absolute32 => @truncate(@as(u64, @bitCast(slid))),
            // Both ends of a PC-relative reference move together, so the displacement is unchanged.
            .text_pcrel32 => cur,
            _ => return Error.UnsupportedFixup,
        };
        std.mem.writeInt(u32, p, value, .little);
    }

    pub fn bind(self: Applier, site: fixups.Site, kind: fixups.BindType, name: []const u8, addend: i64) Error!void {
        const target = self.resolve(name) orelse {
            self.loaded.missing = name;
            return Error.UnresolvedImport;
        };
        const abs: i64 = @as(i64, @intCast(target)) + addend;
        const value: u32 = switch (kind) {
            .pointer, .text_absolute32 => @truncate(@as(u64, @bitCast(abs))),
            .text_pcrel32 => @truncate(@as(u64, @bitCast(abs - @as(i64, try self.siteAddr(site)) - 4))),
            _ => return Error.UnsupportedFixup,
        };
        const p = try self.slot(site);
        std.mem.writeInt(u32, p, value, .little);
    }
};

/// Slide every pointer the image embeds, then point every import at the host. Both bind streams
/// are applied eagerly: lazy binding exists so a process can start without touching every
/// framework, and a server that is going to run for hours gains nothing by deferring it.
pub fn applyFixups(loaded: *Loaded, resolve: Resolver) Error!void {
    const d = loaded.img.dyld;
    const bytes = loaded.img.bytes;
    const applier: Applier = .{ .loaded = loaded, .resolve = resolve };

    if (d.rebase_size > 0) {
        try fixups.walkRebase(bytes[d.rebase_off..][0..d.rebase_size], applier);
    }
    try fixups.walkBind(bytes[d.bind_off..][0..d.bind_size], true, applier);
    if (d.lazy_bind_size > 0) {
        try fixups.walkBind(bytes[d.lazy_bind_off..][0..d.lazy_bind_size], false, applier);
    }
}

/// dyld runs the C++ static constructors between binding and the entry point. Nothing else does,
/// so skipping this leaves the game's globals at zero and the first thing that reads one crashes a
/// long way from the cause.
///
/// The image's own `start` is not used to get here: it reads argc off a Darwin process stack and
/// then does nothing with it but call PreInitApplication, so the host calls that directly rather
/// than emulating a stack layout for the sake of a discarded loop.
/// `trace` is called with each constructor's index and address before it runs. One of these will
/// eventually be the last thing a crashed process did, and the caller is the only one that knows
/// how to record that.
pub fn runInitializers(loaded: *const Loaded, trace: ?*const fn (usize, u32) void) void {
    const sec = loaded.img.initializers() orelse return;
    const low = loaded.img.span().low;
    const base = loaded.memory.ptr + (sec.addr - low);

    const empty: [*:null]const ?[*:0]const u8 = @ptrCast(&[_]?[*:0]const u8{null});
    const Init = *const fn (c_int, @TypeOf(empty), @TypeOf(empty), @TypeOf(empty)) callconv(.c) void;

    var i: usize = 0;
    while (i + 4 <= sec.size) : (i += 4) {
        const target = std.mem.readInt(u32, base[i..][0..4], .little);
        if (target == 0) continue;
        if (trace) |t| t(i / 4, target);
        const f: Init = @ptrFromInt(target);
        f(0, empty, empty, empty);
    }
}

/// Give each segment the protection it asked for. Until this runs the image is writable
/// everywhere, which is what let the fixups land in __TEXT.
pub fn protect(loaded: *Loaded) Error!void {
    const low = loaded.img.span().low;
    for (loaded.img.segments()) |seg| {
        if (seg.vmsize == 0 or seg.is("__PAGEZERO")) continue;
        const start = std.mem.alignBackward(usize, seg.vmaddr - low, std.heap.page_size_min);
        const end = std.mem.alignForward(usize, (seg.vmaddr - low) + seg.vmsize, std.heap.page_size_min);
        if (end > loaded.memory.len) continue;

        const prot: std.c.PROT = .{
            .READ = seg.initprot & image.prot_read != 0,
            .WRITE = seg.initprot & image.prot_write != 0,
            .EXEC = seg.initprot & image.prot_exec != 0,
        };
        const page: [*]align(std.heap.page_size_min) u8 = @alignCast(loaded.memory[start..].ptr);
        if (std.c.mprotect(page, end - start, prot) != 0) return Error.ProtectFailed;
    }
}

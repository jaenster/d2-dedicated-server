//! What a 32-bit Mach-O executable declares about itself: where its segments want to live, where
//! execution starts, and where dyld's fixup opcode streams are.
//!
//! Parsing only. Mapping and fixups live next door, so this file runs on any host — which matters,
//! because the only i386 Linux in reach is a deploy target and the binary is read here.

const std = @import("std");

pub const Error = error{
    NotMachO,
    NotI386,
    Truncated,
    TooManySegments,
    TooManySections,
    NoEntry,
    NoDyldInfo,
};

pub const magic: u32 = 0xfeedface;
pub const cpu_type_x86: u32 = 7;

const req_dyld: u32 = 0x8000_0000;

pub const Cmd = enum(u32) {
    segment = 0x1,
    symtab = 0x2,
    unixthread = 0x5,
    dysymtab = 0xb,
    load_dylib = 0xc,
    load_dylinker = 0xe,
    uuid = 0x1b,
    version_min_macosx = 0x24,
    dyld_info_only = 0x22 | req_dyld,
    _,
};

pub const prot_read: u32 = 1;
pub const prot_write: u32 = 2;
pub const prot_exec: u32 = 4;

pub const Segment = struct {
    name: [16]u8,
    vmaddr: u32,
    vmsize: u32,
    fileoff: u32,
    filesize: u32,
    maxprot: u32,
    initprot: u32,

    pub fn is(self: Segment, want: []const u8) bool {
        return std.mem.eql(u8, std.mem.sliceTo(&self.name, 0), want);
    }
};

/// Offsets of the four opcode streams dyld would have run. Sizes of zero mean the stream is absent,
/// which is legal for everything except bind on an executable that imports anything at all.
pub const DyldInfo = struct {
    rebase_off: u32 = 0,
    rebase_size: u32 = 0,
    bind_off: u32 = 0,
    bind_size: u32 = 0,
    lazy_bind_off: u32 = 0,
    lazy_bind_size: u32 = 0,
};

pub const Section = struct {
    name: [16]u8,
    addr: u32,
    size: u32,
    offset: u32,
    flags: u32,

    /// Low byte of the flags word. The only one that matters here is `mod_init_func_pointers`.
    pub fn kind(self: Section) u8 {
        return @truncate(self.flags);
    }

    pub fn is(self: Section, want: []const u8) bool {
        return std.mem.eql(u8, std.mem.sliceTo(&self.name, 0), want);
    }
};

pub const section_mod_init_func: u8 = 0x9;

/// A Mach-O carries no upper bound on segment or section count; this one has five and twenty-four,
/// and the format gives no reason for a game binary to grow dozens more, so the arrays are fixed
/// and overflow is an error.
pub const max_segments = 16;
pub const max_sections = 48;

pub const Image = struct {
    bytes: []const u8,
    seg_storage: [max_segments]Segment,
    seg_count: usize,
    /// Initial EIP from LC_UNIXTHREAD. This binary predates LC_MAIN, so the entry is a raw
    /// register state rather than an offset.
    entry: u32,
    dyld: DyldInfo,

    sec_storage: [max_sections]Section,
    sec_count: usize,

    pub fn segments(self: *const Image) []const Segment {
        return self.seg_storage[0..self.seg_count];
    }

    pub fn sections(self: *const Image) []const Section {
        return self.sec_storage[0..self.sec_count];
    }

    /// The C++ static constructors. dyld runs these between binding and the entry point; nothing
    /// else does, so a loader that skips them hands the game uninitialised globals.
    pub fn initializers(self: *const Image) ?Section {
        for (self.sections()) |s| if (s.kind() == section_mod_init_func) return s;
        return null;
    }

    pub fn segment(self: *const Image, name: []const u8) ?Segment {
        for (self.segments()) |s| if (s.is(name)) return s;
        return null;
    }

    /// Lowest and highest virtual address the image wants, ignoring __PAGEZERO — that one is a
    /// hole the kernel keeps unmapped to catch null derefs, and reserving it here would waste the
    /// bottom of the address space for nothing.
    pub fn span(self: *const Image) struct { low: u32, high: u32 } {
        var low: u32 = std.math.maxInt(u32);
        var high: u32 = 0;
        for (self.segments()) |s| {
            if (s.vmsize == 0 or s.is("__PAGEZERO")) continue;
            low = @min(low, s.vmaddr);
            high = @max(high, s.vmaddr +| s.vmsize);
        }
        return .{ .low = low, .high = high };
    }
};

fn read(comptime T: type, bytes: []const u8, off: usize) Error!T {
    if (off + @sizeOf(T) > bytes.len) return Error.Truncated;
    return std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little);
}

pub fn parse(bytes: []const u8) Error!Image {
    if (try read(u32, bytes, 0) != magic) return Error.NotMachO;
    if (try read(u32, bytes, 4) != cpu_type_x86) return Error.NotI386;

    const ncmds = try read(u32, bytes, 16);

    var img: Image = .{
        .bytes = bytes,
        .seg_storage = undefined,
        .seg_count = 0,
        .sec_storage = undefined,
        .sec_count = 0,
        .entry = 0,
        .dyld = .{},
    };

    var off: usize = 28;
    for (0..ncmds) |_| {
        const cmd: Cmd = @enumFromInt(try read(u32, bytes, off));
        const size = try read(u32, bytes, off + 4);
        if (size < 8 or off + size > bytes.len) return Error.Truncated;

        switch (cmd) {
            .segment => {
                if (img.seg_count == max_segments) return Error.TooManySegments;
                var seg: Segment = undefined;
                if (off + 56 > bytes.len) return Error.Truncated;
                @memcpy(&seg.name, bytes[off + 8 ..][0..16]);
                seg.vmaddr = try read(u32, bytes, off + 24);
                seg.vmsize = try read(u32, bytes, off + 28);
                seg.fileoff = try read(u32, bytes, off + 32);
                seg.filesize = try read(u32, bytes, off + 36);
                seg.maxprot = try read(u32, bytes, off + 40);
                seg.initprot = try read(u32, bytes, off + 44);
                img.seg_storage[img.seg_count] = seg;
                img.seg_count += 1;

                const nsects = try read(u32, bytes, off + 48);
                var sec_off = off + 56;
                for (0..nsects) |_| {
                    if (img.sec_count == max_sections) return Error.TooManySections;
                    var sec: Section = undefined;
                    if (sec_off + 68 > bytes.len) return Error.Truncated;
                    @memcpy(&sec.name, bytes[sec_off..][0..16]);
                    sec.addr = try read(u32, bytes, sec_off + 32);
                    sec.size = try read(u32, bytes, sec_off + 36);
                    sec.offset = try read(u32, bytes, sec_off + 40);
                    sec.flags = try read(u32, bytes, sec_off + 56);
                    img.sec_storage[img.sec_count] = sec;
                    img.sec_count += 1;
                    sec_off += 68;
                }
            },
            .unixthread => {
                // cmd, cmdsize, flavor, count, then the register state. i386_THREAD_STATE puts EIP
                // at word 10.
                img.entry = try read(u32, bytes, off + 16 + 10 * 4);
            },
            .dyld_info_only => {
                img.dyld = .{
                    .rebase_off = try read(u32, bytes, off + 8),
                    .rebase_size = try read(u32, bytes, off + 12),
                    .bind_off = try read(u32, bytes, off + 16),
                    .bind_size = try read(u32, bytes, off + 20),
                    .lazy_bind_off = try read(u32, bytes, off + 32),
                    .lazy_bind_size = try read(u32, bytes, off + 36),
                };
            },
            else => {},
        }
        off += size;
    }

    if (img.entry == 0) return Error.NoEntry;
    if (img.dyld.bind_size == 0) return Error.NoDyldInfo;
    return img;
}

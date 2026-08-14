//! What the Mac game binary needs from a host, printed.
//!
//! `machoinfo <binary>` for the layout, `machoinfo <binary> --imports` for the symbol list the
//! shim has to answer. The second one is how packages/darwin's table is kept honest against the
//! actual image rather than against a list somebody typed.

const std = @import("std");
const macho = @import("macho");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 2) {
        std.debug.print("usage: machoinfo <binary> [--imports]\n", .{});
        return error.Usage;
    }
    const imports_only = argv.len > 2 and std.mem.eql(u8, argv[2], "--imports");

    const bytes = try macho.mapFile(argv[1]);
    const img = try macho.image.parse(bytes);
    const names = try macho.collectImports(gpa, &img);

    if (imports_only) {
        for (names) |n| std.debug.print("{s}\n", .{n});
        return;
    }

    const span = img.span();
    std.debug.print("entry     0x{x:0>8}\n", .{img.entry});
    std.debug.print("span      0x{x:0>8}..0x{x:0>8}  ({d} KiB resident)\n", .{
        span.low, span.high, (span.high - span.low) / 1024,
    });
    std.debug.print("rebases   {d}\n", .{try macho.countRebases(&img)});
    std.debug.print("imports   {d}\n\n", .{names.len});

    for (img.segments()) |seg| {
        std.debug.print("  {s:<12} vm 0x{x:0>8}+0x{x:<8} file 0x{x:0>8}+0x{x:<8} prot {c}{c}{c}\n", .{
            std.mem.sliceTo(&seg.name, 0),
            seg.vmaddr,      seg.vmsize,
            seg.fileoff,     seg.filesize,
            @as(u8, if (seg.initprot & macho.image.prot_read != 0) 'r' else '-'),
            @as(u8, if (seg.initprot & macho.image.prot_write != 0) 'w' else '-'),
            @as(u8, if (seg.initprot & macho.image.prot_exec != 0) 'x' else '-'),
        });
    }
}

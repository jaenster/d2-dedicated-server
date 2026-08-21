//! A realm built out of the `realmd` package plus its own code — the whole template.
//!
//! This file is the entire difference between the stock realmd binary and one carrying
//! extensions. Everything the realm does comes from the package; everything this realm adds is in
//! the modules named below. Nothing in the upstream repo is edited to make it happen.
//!
//! Copy this directory to start a realm of your own: `build.zig` says where the package comes
//! from, this file names your extensions, and `ext/` is yours.
const std = @import("std");
const realmd = @import("realmd");

/// The registry. Order matters for the hooks that stop at the first answer (a veto, an override):
/// the extension listed first gets to decide, and the rest are not asked.
pub const realm_extensions = .{
    @import("ext/example.zig"),
};

pub fn main(init: std.process.Init.Minimal) !void {
    return realmd.run(init);
}

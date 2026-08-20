//! The realm binary this repo ships: realmd with no extensions.
//!
//! Everything is in realmd.zig, which is also the package a downstream realm imports. To run your
//! own, this file is the whole template — declare `realm_extensions` and keep the rest.
const std = @import("std");
const realmd = @import("realmd");

pub fn main(init: std.process.Init.Minimal) !void {
    return realmd.run(init);
}

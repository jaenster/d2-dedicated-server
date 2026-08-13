//! bncs_auth — the three cryptographic primitives a Battle.net logon is built out of, in one
//! package because they are used by four different binaries and by two different targets: realmd
//! verifies passwords with them, the ver-IX86-1.dll we serve over BNFTP computes the version
//! check with them, and both probes replay a real logon against Blizzard with them.
//!
//! They are grouped by their role, not by their maths — D2 uses THREE distinct hashes and mixing
//! them up is the classic way to get a logon that almost works:
//!   * `xsha1`    — Blizzard's BROKEN SHA-1, and only ever for the OLS password hash.
//!   * `checkrev` — the version check, which uses STANDARD SHA-1 over the hashed MPQ.
//!   * `cdkey`    — the CD-key decode, whose hash is standard SHA-1 as well.
//!
//! Every one of them carries vectors taken from a real 1.14d client, so a change that breaks the
//! wire fails here first. No real CD keys are committed.

pub const xsha1 = @import("xsha1.zig");
pub const checkrev = @import("checkrev_core.zig");
pub const cdkey = @import("cdkey.zig");

// Naming each one is what puts its vectors into `zig build test`; a re-export alone would leave
// the file unanalysed.
test {
    _ = xsha1;
    _ = checkrev;
    _ = cdkey;
}

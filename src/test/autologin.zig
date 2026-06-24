//! Auto-login script — drives the real client through the Battle.net/realm menus into a
//! created or joined game. Written as a charon-style menu script: a `fn() void` async task
//! that composes the oog.zig control primitives and yields each frame. Frame-driven via the
//! OOG game loop (no threads, no time-sleeps) — `awaitLocation` waits for the next screen, so
//! there is no racing the realm's char-list / form transitions. See oog.zig + [[d2-ui-controls]].

const std = @import("std");
const oog = @import("oog.zig");
const log = @import("../log.zig");

var account: [64]u16 = undefined;
var password: [64]u16 = undefined;
var game_name = [_]u16{ 'r', 'e', 'a', 'l', 'm', 't', 'e', 's', 't', 0 };
var want_join: bool = false;

fn toUtf16(out: *[64]u16, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len and i < 63) : (i += 1) out[i] = s[i];
    out[i] = 0;
}

fn acctZ() [*:0]const u16 {
    return @ptrCast(&account);
}
fn passZ() [*:0]const u16 {
    return @ptrCast(&password);
}
fn gameZ() [*:0]const u16 {
    return @ptrCast(&game_name);
}

/// The menu script. Each `awaitLocation` yields menu frames until that screen is up, then
/// we act — so the char-select select-and-OK never fires before the realm char list loads
/// (the old race), and there are no fixed sleeps to tune.
fn loginTask() void {
    oog.awaitLocation(.login);
    oog.doLogin(acctZ(), passZ());
    log.print("autologin: logged in");

    oog.awaitLocation(.char_select);
    oog.enterFirstChar();
    log.print("autologin: entered realm with first char");

    oog.awaitLocation(.lobby);
    if (want_join) {
        if (oog.findControl(oog.TYPE_BUTTON, -1, 652, 469, -1, -1)) |tab| oog.clickControl(tab); // JOIN tab
        oog.awaitLocation(.join);
        var boxes: [2]*oog.Control = undefined;
        if (oog.editboxes(&boxes) >= 1) oog.setControlText(boxes[0], gameZ());
        oog.waitFrames(1);
        // JOIN action button: the wide one at (594,433), fall back to (433,433).
        if (oog.findControl(oog.TYPE_BUTTON, -1, 594, 433, -1, -1) orelse
            oog.findControl(oog.TYPE_BUTTON, -1, 433, 433, -1, -1)) |b| oog.clickControl(b);
        log.print("autologin: clicked JOIN game");
    } else {
        if (oog.findControl(oog.TYPE_BUTTON, -1, 533, 469, -1, -1)) |tab| oog.clickControl(tab); // CREATE tab
        oog.awaitLocation(.create);
        var boxes: [2]*oog.Control = undefined;
        if (oog.editboxes(&boxes) >= 1) oog.setControlText(boxes[0], gameZ());
        oog.waitFrames(1);
        // CREATE button: bottom-right of the form, with a fallback slot.
        if (oog.findControl(oog.TYPE_BUTTON, -1, 594, 433, -1, -1) orelse
            oog.findControl(oog.TYPE_BUTTON, -1, 432, 433, -1, -1)) |b| oog.clickControl(b);
        log.print("autologin: clicked CREATE game");
    }
    log.print("autologin: script done");
}

/// Auto-login + CREATE a game with the default name.
pub fn install(acct: []const u8, pass: []const u8) void {
    toUtf16(&account, acct);
    toUtf16(&password, pass);
    want_join = false;
    oog.run(&loginTask);
    log.print("autologin: script installed (create)");
}

/// Auto-login + JOIN an existing game by name.
pub fn installJoin(acct: []const u8, pass: []const u8, game: []const u8) void {
    toUtf16(&account, acct);
    toUtf16(&password, pass);
    var i: usize = 0;
    while (i < game.len and i < 63) : (i += 1) game_name[i] = game[i];
    game_name[i] = 0;
    want_join = true;
    oog.run(&loginTask);
    log.print("autologin: script installed (join)");
}

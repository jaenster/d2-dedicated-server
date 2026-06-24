//! Out-of-game (menu) control-scripting layer — a Zig port of d2bs's Control.cpp.
//!
//! The point: drive the bnet/realm menus by querying which screen is CURRENTLY up
//! (`getLocation`) and acting on it, instead of blind `Sleep()`s that race screen
//! transitions. You act only when the expected screen exists, and you know a transition
//! finished when the location changes — no timing guesses. This is how d2bs scripts the
//! menus, and it's a reusable primitive for any "drive the client" automation.
//!
//! Screens are identified by probing for distinctive controls at known positions (the
//! coords come straight from d2bs OOG_GetLocation). d2bs additionally matches controls by
//! locale-string-id; the positions alone are unique for the screens we drive, so we match
//! by type + position. Char-select is gated on a char slot that actually HAS text, which
//! is the robust fix for the old "act before the realm char list loaded" race.

const std = @import("std");
const fastcall = @import("../runtime/fastcall.zig");
const async_ = @import("../runtime/async.zig");
const gameloop = @import("../runtime/gameloop.zig");

// d2bs CONTROL_* (Constants.h).
pub const TYPE_EDITBOX: u32 = 0x01;
pub const TYPE_IMAGE: u32 = 0x02;
pub const TYPE_TEXTBOX: u32 = 0x04;
pub const TYPE_BUTTON: u32 = 0x06;

pub const ControlText = extern struct {
    wText: [5]?*u16, // 0x00
    dwColor: u32, // 0x14
    dwAlign: u32, // 0x18
    pNext: ?*ControlText, // 0x1C
};

pub const Control = extern struct {
    dwType: u32, // 0x00
    f04: u32, // 0x04
    dwDisabled: u32, // 0x08
    dwPosX: u32, // 0x0C
    dwPosY: u32, // 0x10
    dwSizeX: u32, // 0x14
    dwSizeY: u32, // 0x18
    pad1: [0x3C - 0x1C]u8, // 0x1C..0x3C
    pNext: ?*Control, // 0x3C
    pad2: [0x48 - 0x40]u8, // 0x40..0x48
    pFirstText: ?*ControlText, // 0x48
};

const FirstControl: *?*Control = @ptrFromInt(0x007D55BC);
const SetControlTextFn = fastcall.fastcall_call(0x004FF5A0, fn (*Control, [*:0]const u16) usize);
const GetHwnd: *const fn () callconv(.winapi) ?*anyopaque = @ptrFromInt(0x004F59A0);

extern "user32" fn PostMessageA(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: usize) callconv(.winapi) i32;

const WM_LBUTTONDOWN: u32 = 0x201;
const WM_LBUTTONUP: u32 = 0x202;
const max_walk = 96; // bound the control-list walk against a transient/corrupt list

/// Find a control by type and any of {disabled, x, y, w, h}; pass -1 to wildcard a field.
/// (d2bs also filters by locale text; the positions are unique for the menus we drive.)
pub fn findControl(ctype: u32, disabled: i32, x: i32, y: i32, w: i32, h: i32) ?*Control {
    var c = FirstControl.*;
    var n: usize = 0;
    while (c) |ctrl| : (c = ctrl.pNext) {
        if (n >= max_walk) break;
        n += 1;
        if (ctrl.dwType != ctype) continue;
        if (disabled >= 0 and ctrl.dwDisabled != @as(u32, @intCast(disabled))) continue;
        if (x >= 0 and ctrl.dwPosX != @as(u32, @intCast(x))) continue;
        if (y >= 0 and ctrl.dwPosY != @as(u32, @intCast(y))) continue;
        if (w >= 0 and ctrl.dwSizeX != @as(u32, @intCast(w))) continue;
        if (h >= 0 and ctrl.dwSizeY != @as(u32, @intCast(h))) continue;
        return ctrl;
    }
    return null;
}

fn has(ctype: u32, x: i32, y: i32, w: i32, h: i32) bool {
    return findControl(ctype, -1, x, y, w, h) != null;
}

/// Up to 2 edit-boxes (account/password, or the game-name field) in list order.
pub fn editboxes(out: *[2]*Control) usize {
    var found: usize = 0;
    var c = FirstControl.*;
    var n: usize = 0;
    while (c) |ctrl| : (c = ctrl.pNext) {
        if (n >= max_walk) break;
        n += 1;
        if (ctrl.dwType == TYPE_EDITBOX and found < 2) {
            out[found] = ctrl;
            found += 1;
        }
    }
    return found;
}

/// First FULLY-LOADED character slot. d2bs's char-select gate: a sized text-box whose text
/// list is 2-deep (pFirstText->pNext = name line + level/class line). Requiring both lines
/// means the realm char list has actually parsed into the slot — selecting before that makes
/// the realm enter with no character (charlist then disconnect, no CHARLOGON).
pub fn firstCharSlot() ?*Control {
    var c = FirstControl.*;
    var n: usize = 0;
    while (c) |ctrl| : (c = ctrl.pNext) {
        if (n >= max_walk) break;
        n += 1;
        if (ctrl.dwType == TYPE_TEXTBOX and ctrl.dwSizeX > 40 and ctrl.dwSizeY > 40) {
            if (ctrl.pFirstText) |ft| {
                if (ft.pNext != null) return ctrl;
            }
        }
    }
    return null;
}

pub fn click(x: u32, y: u32) void {
    const lp: usize = x | (y << 16);
    _ = PostMessageA(GetHwnd(), WM_LBUTTONDOWN, 0, lp);
    _ = PostMessageA(GetHwnd(), WM_LBUTTONUP, 0, lp);
}

/// Click a control at its center (d2bs clickControl: x=posX+sizeX/2, y=posY-sizeY/2).
pub fn clickControl(ctrl: *Control) void {
    click(ctrl.dwPosX + ctrl.dwSizeX / 2, ctrl.dwPosY -% ctrl.dwSizeY / 2);
}

pub fn setControlText(ctrl: *Control, text: [*:0]const u16) void {
    _ = SetControlTextFn.call(.{ ctrl, text });
}

pub const Location = enum {
    none,
    connecting,
    login_error,
    char_create_dupe, // a "name already exists" OK popup
    create, // create-game form
    join, // join-game form
    ladder, // ladder tab
    login, // bnet login form
    char_select, // char list with a populated slot
    char_select_empty, // char list, no chars loaded yet
    char_create, // create-character screen
    please_wait,
    lobby, // base chat screen
};

/// Identify the current menu screen. Probe order mirrors d2bs OOG_GetLocation — earlier,
/// more specific screens win (e.g. the create/join tab is detected before the base lobby).
pub fn getLocation() Location {
    if (has(TYPE_BUTTON, 330, 416, 128, 35)) return .connecting; // "Connecting to Battle.net"
    if (has(TYPE_BUTTON, 335, 412, 128, 35)) return .login_error; // "Login Error"
    if (has(TYPE_BUTTON, 351, 337, 96, 32)) return .char_create_dupe; // OK popup (dupe name etc.)
    if (has(TYPE_BUTTON, 433, 433, 96, 32)) { // a lobby sub-screen (CANCEL present)
        if (has(TYPE_TEXTBOX, 459, 380, 150, 12)) return .create; // "Create Game" label
        if (has(TYPE_BUTTON, 594, 433, 172, 32)) return .join; // "Join Game" wide button
        return .ladder;
    }
    if (has(TYPE_BUTTON, 33, 572, 128, 35)) { // EXIT present -> a login/char screen
        if (has(TYPE_BUTTON, 264, 484, 272, 35)) return .login; // LOGON button
        if (has(TYPE_BUTTON, 627, 572, 128, 35) and has(TYPE_BUTTON, 33, 528, 168, 60)) {
            // char-select (OK + "create new"): real char-select only if a slot has text.
            if (firstCharSlot() != null) return .char_select;
            return .char_select_empty;
        }
        if (has(TYPE_BUTTON, 627, 572, 128, 35)) return .char_create; // create-char with a class picked
        return .char_create;
    }
    if (has(TYPE_TEXTBOX, 268, 300, 264, 100)) return .please_wait;
    if (has(TYPE_BUTTON, 27, 480, 120, 20)) return .lobby; // "ENTER CHAT"
    return .none;
}

// ── script driver (charon-style: hand it a `fn() void` task) ─────────────────────────
// A "script" is just an async task that composes the primitives below and yields each
// frame. `run(task)` drives it off the OOG game loop — spawn once, tick every frame. This
// is the foundation for any menu/botting automation: write a fn, hand it here.

var script_fn: ?*const fn () void = null;
var script_started: bool = false;

fn driverFrame() void {
    if (!script_started) {
        script_started = true;
        if (script_fn) |f| async_.spawn(f);
        return;
    }
    if (async_.isActive()) _ = async_.tick();
}

/// Run a menu script off the OOG game loop (no threads, no sleeps — frame-synchronized).
pub fn run(task: *const fn () void) void {
    script_fn = task;
    script_started = false;
    gameloop.on_oog = &driverFrame;
    gameloop.on_game = &driverFrame; // keep ticking through the in-game transition
    gameloop.install();
}

// ── frame-driven waits (run inside an async_.spawn task; each yield = one menu frame) ──

/// Yield menu frames until getLocation() == target. NO time-sleep — we advance exactly
/// in step with the OOG game loop and stop the frame the screen appears.
pub fn awaitLocation(target: Location) void {
    while (getLocation() != target) async_.yield();
}

/// Yield until getLocation() matches any of `targets`; returns which one. Lets a script
/// branch on whichever screen comes next (e.g. lobby vs an error popup).
pub fn awaitAny(targets: []const Location) Location {
    while (true) {
        const loc = getLocation();
        for (targets) |t| if (loc == t) return loc;
        async_.yield();
    }
}

/// Yield `n` menu frames.
pub fn waitFrames(n: u32) void {
    async_.waitFrames(n);
}

// ── high-level menu ops (call when getLocation() is the matching screen) ──

/// Fill the account/password edit-boxes (ordered by Y: account above password) and click LOGON.
pub fn doLogin(account: [*:0]const u16, password: [*:0]const u16) void {
    var boxes: [2]*Control = undefined;
    if (editboxes(&boxes) < 2) return;
    var acc = boxes[0];
    var pass = boxes[1];
    if (acc.dwPosY > pass.dwPosY) {
        const t = acc;
        acc = pass;
        pass = t;
    }
    setControlText(acc, account);
    setControlText(pass, password);
    click(264 + 272 / 2, 484 - 35 / 2); // LOGON button center
}

/// Select the first populated character slot, give the select a couple of frames to
/// register, then click OK to enter the realm.
pub fn enterFirstChar() void {
    if (firstCharSlot()) |slot| clickControl(slot);
    async_.waitFrames(2);
    if (findControl(TYPE_BUTTON, -1, 627, 572, 128, 35)) |ok| clickControl(ok);
}

/// Type a game name into the form's first edit-box and click the action button at (px,py).
pub fn fillNameAndClick(name: [*:0]const u16, px: u32, py: u32, pw: u32, ph: u32) void {
    var boxes: [2]*Control = undefined;
    if (editboxes(&boxes) >= 1) setControlText(boxes[0], name);
    click(px + pw / 2, py -% ph / 2);
}

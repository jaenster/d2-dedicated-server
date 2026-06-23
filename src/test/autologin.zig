//! Auto-login harness: drive the real client through the Battle.net login form
//! programmatically (fill account + password edit-boxes, click LOG ON), so the
//! realm login phase can be tested without manual GUI input.
//!
//! Mechanism reversed from d2bs-ejt (1.14d). Controls live in a linked list at
//! D2WIN_FirstControl; each Control has type/pos/size and an edit-box text buffer.
//! We set text via D2WIN_SetControlText and click the button by posting mouse
//! messages to the game window (same as d2bs SendMouseClick). See [[d2-ui-controls]].
const std = @import("std");
const fastcall = @import("../runtime/fastcall.zig");
const log = @import("../log.zig");

extern "kernel32" fn CreateThread(a: ?*anyopaque, st: usize, f: *const fn (?*anyopaque) callconv(.winapi) u32, p: ?*anyopaque, fl: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;

/// Read an unsigned env var (0 if unset/invalid). Used for opt-in test knobs.
fn envU32(name: [*:0]const u8) u32 {
    var buf: [16]u8 = undefined;
    const n = GetEnvironmentVariableA(name, &buf, buf.len);
    if (n == 0 or n >= buf.len) return 0;
    return std.fmt.parseInt(u32, buf[0..n], 10) catch 0;
}

const Control = extern struct {
    dwType: u32, // 0x00  (1=editbox, 6=button)
    f04: u32, // 0x04
    dwDisabled: u32, // 0x08
    dwPosX: u32, // 0x0C
    dwPosY: u32, // 0x10
    dwSizeX: u32, // 0x14
    dwSizeY: u32, // 0x18
    pad: [0x3C - 0x1C]u8, // 0x1C..0x3C
    pNext: ?*Control, // 0x3C
};

const FirstControl: *?*Control = @ptrFromInt(0x007D55BC);
const SetControlText = fastcall.fastcall_call(0x004FF5A0, fn (*Control, [*:0]const u16) usize);
const GetHwnd: *const fn () callconv(.winapi) ?*anyopaque = @ptrFromInt(0x004F59A0);

extern "user32" fn PostMessageA(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: usize) callconv(.winapi) i32;

const CONTROL_EDITBOX: u32 = 0x01;
const CONTROL_TEXTBOX: u32 = 0x04;
const CONTROL_BUTTON: u32 = 0x06;
const WM_LBUTTONDOWN: u32 = 0x201;
const WM_LBUTTONUP: u32 = 0x202;

// The LOG ON button on the bnet login screen (d2bs: CONTROL_BUTTON 5288 @ this rect).
const LOGON_X: u32 = 264;
const LOGON_Y: u32 = 484;
const LOGON_W: u32 = 272;
const LOGON_H: u32 = 35;

var account: [64]u16 = undefined;
var password: [64]u16 = undefined;
var game_name = [_]u16{ 'r', 'e', 'a', 'l', 'm', 't', 'e', 's', 't', 0 };
var want_join: bool = false; // join an existing game instead of creating one

/// Dump every button's rect (posX|posY<<16, sizeX|sizeY<<16) — used to discover
/// screen coordinates (e.g. the JOIN tab) we haven't mapped yet.
fn dumpButtons() void {
    var c = FirstControl.*;
    var n: usize = 0;
    while (c) |ctrl| : (c = ctrl.pNext) {
        if (n >= max_walk) break;
        n += 1;
        if (ctrl.dwType != CONTROL_BUTTON) continue;
        log.hex("autologin: btn posXY=0x", ctrl.dwPosX | (ctrl.dwPosY << 16));
        log.hex("autologin:     sizeXY=0x", ctrl.dwSizeX | (ctrl.dwSizeY << 16));
    }
}

fn toUtf16(out: *[64]u16, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len and i < 63) : (i += 1) out[i] = s[i];
    out[i] = 0;
}

const max_walk = 64; // bound the walk so a transient/corrupt list can't run off

fn findButton(px: u32, py: u32) ?*Control {
    var c = FirstControl.*;
    var n: usize = 0;
    while (c) |ctrl| : (c = ctrl.pNext) {
        if (n >= max_walk) break;
        n += 1;
        if (ctrl.dwType == CONTROL_BUTTON and ctrl.dwPosX == px and ctrl.dwPosY == py) return ctrl;
    }
    return null;
}

/// Collect up to 2 edit-boxes (account, password) from the control list.
fn findEditboxes(out: *[2]*Control) usize {
    var found: usize = 0;
    var c = FirstControl.*;
    var n: usize = 0;
    while (c) |ctrl| : (c = ctrl.pNext) {
        if (n >= max_walk) break;
        n += 1;
        if (ctrl.dwType == CONTROL_EDITBOX and found < 2) {
            out[found] = ctrl;
            found += 1;
        }
    }
    return found;
}

fn click(x: u32, y: u32) void {
    const lp: usize = x | (y << 16);
    _ = PostMessageA(GetHwnd(), WM_LBUTTONDOWN, 0, lp);
    _ = PostMessageA(GetHwnd(), WM_LBUTTONUP, 0, lp);
}

// d2bs click point for a control: x = posX + sizeX/2, y = posY - sizeY/2.
fn clickCtrl(ctrl: *Control) void {
    click(ctrl.dwPosX + ctrl.dwSizeX / 2, ctrl.dwPosY -% ctrl.dwSizeY / 2);
}

const POLL_MS: u32 = 20; // poll granularity — tight, so we advance the frame a control appears

/// Poll up to ~max_ms for a CONTROL_BUTTON at (px,py). Checks FIRST (returns
/// immediately if it's already there), then sleeps one short slice and retries.
/// This is how we stay "lightning quick": we never wait a fixed amount, we wait
/// exactly until the next screen's control exists and then act the same frame.
fn waitForButton(px: u32, py: u32, max_ms: u32) ?*Control {
    var waited: u32 = 0;
    while (true) {
        if (findButton(px, py)) |b| return b;
        if (waited >= max_ms) return null;
        Sleep(POLL_MS);
        waited += POLL_MS;
    }
}

/// Poll up to ~max_ms until at least `min` edit-boxes exist (a freshly-opened
/// create/join form builds its controls a few frames after the tab click).
fn waitForEditboxes(boxes: *[2]*Control, min: usize, max_ms: u32) usize {
    var waited: u32 = 0;
    while (true) {
        const n = findEditboxes(boxes);
        if (n >= min or waited >= max_ms) return n;
        Sleep(POLL_MS);
        waited += POLL_MS;
    }
}

/// First character slot (a CONTROL_TEXTBOX with text) on the char-select screen.
fn firstCharSlot() ?*Control {
    var c = FirstControl.*;
    var n: usize = 0;
    while (c) |ctrl| : (c = ctrl.pNext) {
        if (n >= max_walk) break;
        n += 1;
        if (ctrl.dwType == CONTROL_TEXTBOX and ctrl.dwSizeX > 40 and ctrl.dwSizeY > 40) return ctrl;
    }
    return null;
}

/// Poll for the bnet login screen, then fill the form and click LOG ON. Runs on
/// its own thread so we never patch the game loops (patching the OOG loop breaks
/// the version-check flow that runs in it). Reading/writing controls from here is
/// safe enough: at the login screen the control list is stable.
fn pollThread(_: ?*anyopaque) callconv(.winapi) u32 {
    // No fixed startup wait: waitForButton polls for the login screen and returns
    // the frame it appears. Reading the (empty) control list before then is safe.
    // 1) LOGIN — fill account/password, click LOG IN. Long timeout: the very first
    // screen can lag behind a real version-check download.
    if (waitForButton(LOGON_X, LOGON_Y, 30000)) |_| {
        var boxes: [2]*Control = undefined;
        if (findEditboxes(&boxes) >= 2) {
            var acc_box = boxes[0];
            var pass_box = boxes[1];
            if (acc_box.dwPosY > pass_box.dwPosY) {
                const t = acc_box;
                acc_box = pass_box;
                pass_box = t;
            }
            _ = SetControlText.call(.{ acc_box, @as([*:0]const u16, @ptrCast(&account)) });
            _ = SetControlText.call(.{ pass_box, @as([*:0]const u16, @ptrCast(&password)) });
            // SetControlText writes the box buffer synchronously, so click immediately.
            click(LOGON_X + LOGON_W / 2, LOGON_Y - LOGON_H / 2);
            log.print("autologin: logged in");
        }
    }

    // 2) CHARACTER SELECT — select the first character, click OK (627,572).
    if (waitForButton(627, 572, 30000)) |ok| {
        // The char slots are filled by the realm's MCP charlist (a round-trip that
        // lands a few frames after the screen's OK button appears). Selecting before
        // the char is bound makes OK enter the realm with no character -> the client
        // drops the d2cs link with no CHARLOGON. Give the list time to populate.
        Sleep(800);
        if (firstCharSlot()) |slot| {
            clickCtrl(slot);
            // The slot-select must process across a few game frames (≥1 frame = ~40ms
            // at 25fps) before OK, or the realm enters with no character selected.
            Sleep(150);
            log.print("autologin: selected character");
        }
        clickCtrl(ok);
        log.print("autologin: clicked OK (entering realm)");
    }

    // 3) LOBBY — the CREATE tab (533,469) is present once the lobby is up.
    if (waitForButton(533, 469, 30000)) |create_tab| {
        if (want_join) {
            // JOIN an existing game. Dump the lobby buttons first so we can map the
            // JOIN tab coords, then drive the join form.
            log.print("autologin: lobby reached (join mode) — buttons:");
            dumpButtons();
            // JOIN tab sits right of the CREATE tab (533,469) at (652,469).
            if (findButton(652, 469)) |join_tab| {
                clickCtrl(join_tab);
                log.print("autologin: opened Join Game");
                var boxes: [2]*Control = undefined;
                const have = waitForEditboxes(&boxes, 1, 3000); // act the frame the join form builds
                // Opt-in: linger on the JOIN screen so the game list refresh (MCP 0x05)
                // completes and the screenshot thread captures the populated list.
                const hold_ms = envU32("D2GS_JOIN_HOLD_MS");
                if (hold_ms != 0) {
                    log.hex("autologin: holding on JOIN screen ms=0x", hold_ms);
                    Sleep(hold_ms);
                }
                dumpButtons(); // join form buttons
                if (have >= 1) {
                    _ = SetControlText.call(.{ boxes[0], @as([*:0]const u16, @ptrCast(&game_name)) });
                    log.print("autologin: typed game name to join");
                }
                // JOIN GAME action button: the wide one at (594,433) (same slot the
                // CREATE button uses), fall back to (433,433).
                if (findButton(594, 433) orelse findButton(433, 433)) |btn| {
                    clickCtrl(btn);
                    log.print("autologin: clicked JOIN game");
                }
            }
        } else {
            clickCtrl(create_tab);
            log.print("autologin: opened Create Game");
            // 4) CREATE FORM — type a game name in the first edit-box, click CREATE.
            var boxes: [2]*Control = undefined;
            if (waitForEditboxes(&boxes, 1, 3000) >= 1) { // act the frame the create form builds
                _ = SetControlText.call(.{ boxes[0], @as([*:0]const u16, @ptrCast(&game_name)) });
                log.print("autologin: typed game name");
            }
            // CREATE button (bottom-right of the create form).
            if (waitForButton(432, 433, 3000)) |btn| {
                clickCtrl(btn);
                log.print("autologin: clicked CREATE game");
            } else if (findButton(594, 433)) |btn| {
                clickCtrl(btn);
                log.print("autologin: clicked CREATE game (alt)");
            }
        }
    }
    return 0;
}

fn startThread(acct: []const u8, pass: []const u8) void {
    toUtf16(&account, acct);
    toUtf16(&password, pass);
    _ = CreateThread(null, 0, pollThread, null, 0, null);
}

/// Auto-login + CREATE a game with the default name.
pub fn install(acct: []const u8, pass: []const u8) void {
    want_join = false;
    startThread(acct, pass);
    log.print("autologin: poll thread started (create)");
}

/// Auto-login + JOIN an existing game by name.
pub fn installJoin(acct: []const u8, pass: []const u8, game: []const u8) void {
    want_join = true;
    var i: usize = 0;
    while (i < game.len and i < 63) : (i += 1) game_name[i] = game[i];
    game_name[i] = 0;
    startThread(acct, pass);
    log.print("autologin: poll thread started (join)");
}

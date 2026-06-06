//! Fiber-based task system (ported from aether's async.zig). Lets a task run
//! sequential logic across game frames: the task yields each frame, the game-loop
//! hook ticks it. Used to drive the client through menus into a game.

const std = @import("std");
const log = @import("../log.zig");

const LPVOID = ?*anyopaque;
const DWORD = u32;

extern "kernel32" fn ConvertThreadToFiber(param: LPVOID) callconv(.winapi) LPVOID;
extern "kernel32" fn CreateFiber(stack_size: DWORD, start: *const fn (LPVOID) callconv(.winapi) void, param: LPVOID) callconv(.winapi) LPVOID;
extern "kernel32" fn SwitchToFiber(fiber: LPVOID) callconv(.winapi) void;
extern "kernel32" fn DeleteFiber(fiber: LPVOID) callconv(.winapi) void;

var main_fiber: LPVOID = null;
var task_fiber: LPVOID = null;
var task_fn: ?*const fn () void = null;
var task_done: bool = false;

pub fn getMainFiber() LPVOID {
    return main_fiber;
}

/// Convert the current (game) thread into a fiber. Call once, on the game thread.
pub fn init() void {
    if (main_fiber != null) return;
    main_fiber = ConvertThreadToFiber(null);
    if (main_fiber == null) log.print("async: ConvertThreadToFiber failed");
}

/// Yield back to the game loop for one frame. Call from within a task.
pub fn yield() void {
    SwitchToFiber(main_fiber.?);
}

pub fn waitFrames(n: u32) void {
    for (0..n) |_| yield();
}

/// Advance the active task one frame. Call from the game loop. Returns true while
/// a task is still running.
pub fn tick() bool {
    if (task_fiber == null) return false;
    if (task_done) {
        cleanup();
        return false;
    }
    SwitchToFiber(task_fiber.?);
    if (task_done) {
        cleanup();
        return false;
    }
    return true;
}

pub fn spawn(func: *const fn () void) void {
    cancel();
    task_fn = func;
    task_done = false;
    task_fiber = CreateFiber(64 * 1024, &fiberEntry, null);
    if (task_fiber == null) {
        log.print("async: CreateFiber failed");
        task_fn = null;
    }
}

pub fn cancel() void {
    if (task_fiber) |f| {
        DeleteFiber(f);
        task_fiber = null;
        task_fn = null;
        task_done = false;
    }
}

pub fn isActive() bool {
    return task_fiber != null and !task_done;
}

fn cleanup() void {
    if (task_fiber) |f| {
        DeleteFiber(f);
        task_fiber = null;
        task_fn = null;
        task_done = false;
    }
}

fn fiberEntry(_: LPVOID) callconv(.winapi) void {
    if (task_fn) |func| func();
    task_done = true;
    SwitchToFiber(main_fiber.?);
}

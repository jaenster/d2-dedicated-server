const types = @import("types.zig");
const globals = @import("globals.zig");
const functions = @import("functions.zig");
const POINT = types.POINT;

/// Convert world coordinates to automap screen coordinates.
pub fn toAutomap(x: f64, y: f64) POINT {
    const div: f64 = @floatFromInt(globals.divisor().*);
    const offset = globals.automapOffset().*;
    return .{
        .x = @as(i32, @intFromFloat((x * 16.0 + y * -16.0) / div)) - offset.x + 8,
        .y = @as(i32, @intFromFloat((x * 8.0 + y * 8.0) / div)) - offset.y - 8,
    };
}

/// Convert world coordinates to screen coordinates.
pub fn toScreen(x: f64, y: f64) POINT {
    return .{
        .x = @as(i32, @intFromFloat(x * 16.0 + y * -16.0)) - functions.GetMouseXOffset.call(.{}),
        .y = @as(i32, @intFromFloat(x * 8.0 + y * 8.0)) - functions.GetMouseYOffset.call(.{}),
    };
}

/// Convert automap screen coordinates back to world coordinates.
pub fn fromAutomap(sx: i32, sy: i32) struct { x: f64, y: f64 } {
    const div: f64 = @floatFromInt(globals.divisor().*);
    const offset = globals.automapOffset().*;
    const a: f64 = @as(f64, @floatFromInt(sx + offset.x - 8)) * div;
    const b: f64 = @as(f64, @floatFromInt(sy + offset.y + 8)) * div;
    return .{
        .x = (a + 2.0 * b) / 32.0,
        .y = (2.0 * b - a) / 32.0,
    };
}

/// Draw an X marker on the automap at world position (x, y).
pub fn drawAutomapX(x: f64, y: f64, color: u32, size: f64) void {
    const a1 = toAutomap(x - size, y);
    const b1 = toAutomap(x + size, y);
    const a2 = toAutomap(x, y - size);
    const b2 = toAutomap(x, y + size);
    functions.DrawLine.call(a1.x, a1.y, b1.x, b1.y, color, 0xFF);
    functions.DrawLine.call(a2.x, a2.y, b2.x, b2.y, color, 0xFF);
}

/// Draw a cross (+) marker on the automap at world position (x, y).
pub fn drawAutomapCross(x: f64, y: f64, color: u32, size: i32) void {
    const p = toAutomap(x, y);
    functions.DrawLine.call(p.x - size, p.y, p.x + size, p.y, color, 0xFF);
    functions.DrawLine.call(p.x, p.y - size, p.x, p.y + size, color, 0xFF);
}

/// Call the game's AUTOMAP_DrawXMarker at 0x0045A7F0.
/// Custom calling convention: ECX=nX, EAX=nY, stack=nColor.
pub fn drawAutomapMarker(x: f64, y: f64, color: u32) void {
    const p = toAutomap(x, y);
    asm volatile (
        \\pushl %[color]
        \\call *%[func]
        :
        : [func] "r" (@as(u32, 0x0045A7F0)),
          [color] "r" (color),
          [nx] "{ecx}" (p.x),
          [ny] "{eax}" (p.y),
        : .{ .edx = true, .esi = true, .memory = true }
    );
}

/// Draw a dotted line on the automap between two screen positions.
pub fn drawDottedLine(x0: c_int, y0: c_int, x1: c_int, y1: c_int, color: u32) void {
    const dx: f64 = @floatFromInt(x1 - x0);
    const dy: f64 = @floatFromInt(y1 - y0);
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1.0) return;
    const seg: f64 = 4.0; // pixels per segment
    const gap: f64 = 3.0;
    const step = seg + gap;
    var t: f64 = 0;
    while (t < len) {
        const t_end = @min(t + seg, len);
        const sx: c_int = x0 + @as(c_int, @intFromFloat(dx * t / len));
        const sy: c_int = y0 + @as(c_int, @intFromFloat(dy * t / len));
        const ex: c_int = x0 + @as(c_int, @intFromFloat(dx * t_end / len));
        const ey: c_int = y0 + @as(c_int, @intFromFloat(dy * t_end / len));
        functions.DrawLine.call(sx, sy, ex, ey, color, 0x80);
        t += step;
    }
}

/// Draw a dot on the automap at world position (x, y).
pub fn drawAutomapDot(x: f64, y: f64, color: u32) void {
    const p = toAutomap(x, y);
    functions.DrawLine.call(p.x - 1, p.y, p.x + 1, p.y, color, 0xFF);
    functions.DrawLine.call(p.x, p.y - 1, p.x, p.y + 1, color, 0xFF);
}

/// Draw a cross (+) in screen (game view) space at world position.
pub fn drawScreenCross(x: f64, y: f64, color: u32, size: i32) void {
    const p = toScreen(x, y);
    functions.DrawLine.call(p.x - size, p.y, p.x + size, p.y, color, 0xFF);
    functions.DrawLine.call(p.x, p.y - size, p.x, p.y + size, color, 0xFF);
}

/// Draw a dotted line in screen (game view) space between two world positions.
pub fn drawScreenDottedLine(x0: f64, y0: f64, x1: f64, y1: f64, color: u32) void {
    const p0 = toScreen(x0, y0);
    const p1 = toScreen(x1, y1);
    drawDottedLine(p0.x, p0.y, p1.x, p1.y, color);
}

/// Get world position for a unit — handles object/item static paths vs dynamic paths.
pub fn unitPos(unit: *const types.UnitAny) struct { x: f64, y: f64 } {
    if (unit.pPath != null) {
        if (unit.isStaticUnit()) {
            const pos = unit.getPos();
            return .{
                .x = @floatFromInt(pos.x),
                .y = @floatFromInt(pos.y),
            };
        }
        // Living units use position + sub-tile offset
        const dp = unit.dynamicPath().?;
        return .{
            .x = @as(f64, @floatFromInt(dp.xPos)) + @as(f64, @floatFromInt(dp.xOffset)) / 65536.0,
            .y = @as(f64, @floatFromInt(dp.yPos)) + @as(f64, @floatFromInt(dp.yOffset)) / 65536.0,
        };
    }
    return .{ .x = 0, .y = 0 };
}

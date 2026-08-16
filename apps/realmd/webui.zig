//! Serves the embedded admin web UI on the health/admin HTTP listener (health.zig routes every
//! non-probe, non-/admin path here). Single self-contained HTML file (Vite + React via
//! vite-plugin-singlefile), embedded at build time: `zig build -Dwebui=true` builds webui/ and
//! embeds dist/index.html, otherwise a stub page is embedded (JSON API still works). The page
//! itself is NOT token-gated — every data call hits /admin/* which IS (admin.zig) — and is a
//! single-page app, so any unmatched path returns the same HTML.
const std = @import("std");
const net = @import("realm_infra").net;

// Wired by build.zig via addAnonymousImport("webui_blob", ...): the real bundle when
// -Dwebui=true, the stub page otherwise.
const blob = @embedFile("webui_blob");

fn respondHtml(fd: net.Socket, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
    _ = net.writeAll(fd, h);
    _ = net.writeAll(fd, body);
}

/// Serve the SPA for `path` (any non-API GET). path is currently unused — the app is a
/// single bundle that routes client-side — but kept for future asset splitting.
pub fn handle(fd: net.Socket, path: []const u8) void {
    _ = path;
    respondHtml(fd, blob);
}

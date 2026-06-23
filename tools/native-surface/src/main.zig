//! native-surface — static call-graph scoping of the headless-server port surface.
//!
//! Reads the reconstruction's per-file `*.cpp.map` JSON sidecars (authoritative
//! `address` / `namespace` / `calledFunctions`), recovers the indirect-dispatch
//! edges that Ghidra can't (skill/missile/AI/object/qserver function-pointer
//! tables show up as `&Func` address-taken refs in the `.cpp` text), seeds the
//! closure on the server command handlers PLUS every address-taken server
//! function, BFS's the transitive callees, and emits a subsystem tree + DOT.
//!
//!   zig build run -- --recon <recon-dir> --out <out-dir> [--edge-min N]
//!   (recon dir also read from $D2_RECON_SRC)

const std = @import("std");

const WIN_LO: u32 = 0x400000;
const WIN_HI: u32 = 0x6fffff;

const PRUNE_TOPS = [_][]const u8{
    "D2Client", "D2Win", "D2Sound", "D2CMP", "D2OpenGL",
    "D2Lang",   "StormMac", "MacSpecific", "VisualStudio",
};

fn isPrune(top: []const u8) bool {
    for (PRUNE_TOPS) |p| if (std.mem.eql(u8, top, p)) return true;
    return false;
}

// Subsystems that are unambiguously presentation/IO — a function that calls into
// these is a genuine client boundary; one that doesn't (yet sits in a pruned
// namespace and is called by the server) is misclassified and should move out.
const HARD_CLIENT = [_][]const u8{
    "D2Client/Renderer", "D2Client/UI",   "D2Client/Draw",   "D2Client/Engine",
    "D2Client/Forms",    "D2Client/OOG",  "D2Client/Chat",   "D2Client/Warden",
    "D2Sound",           "D2CMP",         "D2OpenGL",        "D2Win",
};
fn isHardClient(sub: []const u8) bool {
    for (HARD_CLIENT) |h| if (std.mem.startsWith(u8, sub, h)) return true;
    return false;
}

// Name prefixes that mark a function as genuinely presentation/IO even when it's
// a leaf that calls nothing deeper (so the "calls no client code" test misses it).
// NOTE: per D2MOO, COMPOSIT / CHAT / TEXT / WAYPOINTS / SEED are D2Common, NOT
// presentation — they are deliberately absent here.
const PRESENTATION_NAMES = [_][]const u8{
    "GFX_",   "D2GFX",   "SOUND",   "SOUNDHDR", "DRAW",     "LIGHTMAP", "LIGHT_",
    "PANEL_", "D2WIN",   "CEL_",    "AUTOMAP",  "CURSOR",   "PALETTE",
    "FONT",   "SPELLSEL", "BELT_",  "MINIPANEL", "INVENTORY_Draw", "CONTROL_",
    "DC6",    "GetDC6",  "MPQ_",    "CUTSCENE", "WND_",     "MAINMENU", "CHARSEL",
    "GetMouse", "CutScene",
};
fn isPresentationName(name: []const u8) bool {
    for (PRESENTATION_NAMES) |p| if (std.mem.startsWith(u8, name, p)) return true;
    // light-radius getters/setters
    if (std.mem.indexOf(u8, name, "Radius") != null) return true;
    return false;
}

const Func = struct {
    addr: u32,
    name: []const u8,
    top: []const u8,
    sub: []const u8,
    prune: bool,
    calls: [][]const u8,
    types: [][]const u8,
};

const Ctx = struct {
    a: std.mem.Allocator,
    funcs: std.ArrayList(Func) = .empty,
    name_index: std.StringHashMap(std.ArrayList(u32)),
    addr_taken: std.StringHashMap(void),

    fn classify(self: *Ctx, ns: []const u8, file_top: []const u8) struct { top: []const u8, sub: []const u8 } {
        if (ns.len > 0) {
            const sep = "::";
            const si = std.mem.indexOf(u8, ns, sep) orelse {
                const top = self.a.dupe(u8, ns) catch unreachable;
                return .{ .top = top, .sub = top };
            };
            const first = ns[0..si];
            const rest = ns[si + 2 ..];
            const second = if (std.mem.indexOf(u8, rest, sep)) |k| rest[0..k] else rest;
            const top = self.a.dupe(u8, first) catch unreachable;
            const sub = std.fmt.allocPrint(self.a, "{s}/{s}", .{ first, second }) catch unreachable;
            return .{ .top = top, .sub = sub };
        }
        const top = self.a.dupe(u8, file_top) catch unreachable;
        return .{ .top = top, .sub = top };
    }

    fn addFunc(self: *Ctx, addr: u32, name: []const u8, top: []const u8, sub: []const u8, calls: [][]const u8, types: [][]const u8) void {
        const fid: u32 = @intCast(self.funcs.items.len);
        self.funcs.append(self.a, .{
            .addr = addr,
            .name = name,
            .top = top,
            .sub = sub,
            .prune = isPrune(top),
            .calls = calls,
            .types = types,
        }) catch unreachable;
        const gop = self.name_index.getOrPut(name) catch unreachable;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(self.a, fid) catch unreachable;
    }
};

fn fileTop(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |i| return path[0..i];
    // root-level file like "_unnamespaced.cpp.map" -> strip extension
    if (std.mem.indexOfScalar(u8, path, '.')) |i| return path[0..i];
    return path;
}

fn parseMap(ctx: *Ctx, bytes: []const u8, scratch: std.mem.Allocator, file_top: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, bytes, .{}) catch return;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const fns_v = root.get("functions") orelse return;
    const arr = switch (fns_v) {
        .array => |x| x,
        else => return,
    };
    for (arr.items) |item| {
        const fo = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const addr_s = if (fo.get("address")) |v| (switch (v) {
            .string => |s| s,
            else => continue,
        }) else continue;
        const addr = std.fmt.parseInt(u32, addr_s, 16) catch continue;
        if (addr < WIN_LO or addr > WIN_HI) continue;
        const name_raw = if (fo.get("name")) |v| (switch (v) {
            .string => |s| s,
            else => continue,
        }) else continue;
        const name = ctx.a.dupe(u8, name_raw) catch unreachable;
        const ns = if (fo.get("namespace")) |v| (switch (v) {
            .string => |s| s,
            else => "",
        }) else "";

        var calls: std.ArrayList([]const u8) = .empty;
        if (fo.get("calledFunctions")) |cv| switch (cv) {
            .array => |ca| for (ca.items) |c| switch (c) {
                .string => |cs| {
                    if (std.mem.eql(u8, cs, name_raw)) continue; // skip self
                    calls.append(ctx.a, ctx.a.dupe(u8, cs) catch unreachable) catch unreachable;
                },
                else => {},
            },
            else => {},
        };
        var types: std.ArrayList([]const u8) = .empty;
        if (fo.get("usedTypes")) |tv| switch (tv) {
            .array => |ta| for (ta.items) |t| switch (t) {
                .string => |ts| types.append(ctx.a, ctx.a.dupe(u8, ts) catch unreachable) catch unreachable,
                else => {},
            },
            else => {},
        };
        const cl = ctx.classify(ns, file_top);
        ctx.addFunc(addr, name, cl.top, cl.sub, calls.items, types.items);
    }
}

/// Scan `.cpp` text for `&Identifier` — every address-taken function name, i.e.
/// the entries of the data-driven dispatch tables (skills/missiles/AI/objects/
/// qserver handlers) that never appear in any `calledFunctions`.
fn scanAddrTaken(ctx: *Ctx, bytes: []const u8) void {
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] != '&') continue;
        const c = bytes[i + 1];
        if (!(std.ascii.isAlphabetic(c) or c == '_')) continue;
        var j = i + 1;
        while (j < bytes.len and (std.ascii.isAlphanumeric(bytes[j]) or bytes[j] == '_')) j += 1;
        const ident = bytes[i + 1 .. j];
        if (!ctx.addr_taken.contains(ident)) {
            const k = ctx.a.dupe(u8, ident) catch unreachable;
            ctx.addr_taken.put(k, {}) catch unreachable;
        }
        i = j - 1;
    }
}

fn resolveEdges(ctx: *Ctx, adj: []std.ArrayList(u32)) usize {
    var ambiguous: usize = 0;
    for (ctx.funcs.items, 0..) |f, fid| {
        for (f.calls) |nm| {
            const cand = ctx.name_index.get(nm) orelse continue;
            if (cand.items.len == 1) {
                adj[fid].append(ctx.a, cand.items[0]) catch unreachable;
                continue;
            }
            var matched = false;
            for (cand.items) |c| if (std.mem.eql(u8, ctx.funcs.items[c].sub, f.sub)) {
                adj[fid].append(ctx.a, c) catch unreachable;
                matched = true;
            };
            if (matched) continue;
            for (cand.items) |c| if (std.mem.eql(u8, ctx.funcs.items[c].top, f.top)) {
                adj[fid].append(ctx.a, c) catch unreachable;
                matched = true;
            };
            if (!matched) ambiguous += 1;
        }
    }
    return ambiguous;
}

const Pair = struct { key: []const u8, n: u32 };
fn pairDesc(_: void, a: Pair, b: Pair) bool {
    return a.n > b.n;
}

fn bprint(buf: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(a, fmt, args) catch unreachable;
    buf.appendSlice(a, s) catch unreachable;
}

fn bump(m: *std.StringHashMap(u32), a: std.mem.Allocator, key: []const u8) void {
    _ = a;
    const g = m.getOrPut(key) catch unreachable;
    if (!g.found_existing) g.value_ptr.* = 0;
    g.value_ptr.* += 1;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    // ---- args / env ----
    var recon: ?[]const u8 = init.environ_map.get("D2_RECON_SRC");
    var out: []const u8 = "native-surface-out";
    var edge_min: u32 = 14;
    const node_min: u32 = 8;
    {
        const args = try init.minimal.args.toSlice(a);
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--recon") and i + 1 < args.len) {
                i += 1;
                recon = args[i];
            } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
                i += 1;
                out = args[i];
            } else if (std.mem.eql(u8, args[i], "--edge-min") and i + 1 < args.len) {
                i += 1;
                edge_min = try std.fmt.parseInt(u32, args[i], 10);
            }
        }
    }
    const root_dir = recon orelse {
        std.debug.print("error: set $D2_RECON_SRC or pass --recon <dir>\n", .{});
        std.process.exit(2);
    };

    var ctx = Ctx{
        .a = a,
        .name_index = std.StringHashMap(std.ArrayList(u32)).init(a),
        .addr_taken = std.StringHashMap(void).init(a),
    };

    // ---- walk: parse maps + scan .cpp for address-taken refs ----
    var dir = try std.Io.Dir.cwd().openDir(io, root_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var n_maps: usize = 0;
    var n_src: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, "/.git/") != null) continue;
        const is_map = std.mem.endsWith(u8, entry.path, ".cpp.map");
        const is_src = !is_map and std.mem.endsWith(u8, entry.path, ".cpp");
        if (!is_map and !is_src) continue;

        var fa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer fa.deinit();
        const sa = fa.allocator();
        const bytes = dir.readFileAlloc(io, entry.path, sa, .unlimited) catch continue;

        if (is_map) {
            parseMap(&ctx, bytes, sa, fileTop(entry.path));
            n_maps += 1;
        } else {
            scanAddrTaken(&ctx, bytes);
            n_src += 1;
        }
    }
    const N = ctx.funcs.items.len;

    // ---- edges ----
    const adj = try a.alloc(std.ArrayList(u32), N);
    for (adj) |*x| x.* = .empty;
    const ambiguous = resolveEdges(&ctx, adj);

    // ---- roots: SCMD handlers + address-taken server functions ----
    var roots: std.ArrayList(u32) = .empty;
    var n_scmd: usize = 0;
    var n_indirect: usize = 0;
    for (ctx.funcs.items, 0..) |f, fid| {
        const scmd = std.mem.startsWith(u8, f.name, "SCMD_0x");
        const indirect = !f.prune and ctx.addr_taken.contains(f.name);
        if (scmd) n_scmd += 1;
        if (scmd or indirect) {
            roots.append(a, @intCast(fid)) catch unreachable;
            if (indirect and !scmd) n_indirect += 1;
        }
    }

    // ---- BFS ----
    const visited = try a.alloc(bool, N);
    @memset(visited, false);
    var stack: std.ArrayList(u32) = .empty;
    for (roots.items) |r| if (!visited[r]) {
        visited[r] = true;
        stack.append(a, r) catch unreachable;
    };
    while (stack.pop()) |fid| {
        // client/render/sound are a cut boundary: count them as reached (a
        // native server stubs that edge) but don't unfold their subtrees.
        if (ctx.funcs.items[fid].prune) continue;
        for (adj[fid].items) |nb| if (!visited[nb]) {
            visited[nb] = true;
            stack.append(a, nb) catch unreachable;
        };
    }

    // ---- tally ----
    var sub_count = std.StringHashMap(u32).init(a);
    var sub_top = std.StringHashMap([]const u8).init(a);
    var top_count = std.StringHashMap(u32).init(a);
    var sub_funcs = std.StringHashMap(std.ArrayList([]const u8)).init(a);
    var reach: usize = 0;
    var keep: usize = 0;
    for (ctx.funcs.items, 0..) |f, fid| {
        if (!visited[fid]) continue;
        reach += 1;
        if (!f.prune) keep += 1;
        const sc = sub_count.getOrPut(f.sub) catch unreachable;
        if (!sc.found_existing) sc.value_ptr.* = 0;
        sc.value_ptr.* += 1;
        sub_top.put(f.sub, f.top) catch unreachable;
        const tc = top_count.getOrPut(f.top) catch unreachable;
        if (!tc.found_existing) tc.value_ptr.* = 0;
        tc.value_ptr.* += 1;
        const gp = sub_funcs.getOrPut(f.sub) catch unreachable;
        if (!gp.found_existing) gp.value_ptr.* = .empty;
        gp.value_ptr.append(a, f.name) catch unreachable;
    }

    // ---- subsystem edges (for DOT) ----
    var sub_edge = std.StringHashMap(u32).init(a);
    for (ctx.funcs.items, 0..) |f, fid| {
        if (!visited[fid]) continue;
        for (adj[fid].items) |nb| {
            if (!visited[nb]) continue;
            const ns = ctx.funcs.items[nb].sub;
            if (std.mem.eql(u8, f.sub, ns)) continue;
            const key = std.fmt.allocPrint(a, "{s}\x00{s}", .{ f.sub, ns }) catch unreachable;
            const se = sub_edge.getOrPut(key) catch unreachable;
            if (!se.found_existing) se.value_ptr.* = 0;
            se.value_ptr.* += 1;
        }
    }

    // ---- holes: what the server set references but does not contain ----
    var h_ext = std.StringHashMap(u32).init(a); // not reconstructed -> implement/link
    var h_bound = std.StringHashMap(u32).init(a); // calls into pruned code -> stub
    var h_gap = std.StringHashMap(u32).init(a); // reconstructed server fn, not in closure
    var h_ns = std.StringHashMap([]const u8).init(a); // name -> a namespace (for bound/gap)
    var h_types = std.StringHashMap(u32).init(a); // usedTypes frequency
    for (ctx.funcs.items, 0..) |f, fid| {
        if (!visited[fid] or f.prune) continue; // only the server-relevant functions
        for (f.calls) |nm| {
            const cand = ctx.name_index.get(nm) orelse {
                bump(&h_ext, a, nm);
                continue;
            };
            var any_np = false;
            var any_vis_np = false;
            for (cand.items) |c| if (!ctx.funcs.items[c].prune) {
                any_np = true;
                if (visited[c]) any_vis_np = true;
            };
            if (!any_np) {
                bump(&h_bound, a, nm);
                h_ns.put(nm, ctx.funcs.items[cand.items[0]].sub) catch unreachable;
            } else if (!any_vis_np) {
                bump(&h_gap, a, nm);
                h_ns.put(nm, ctx.funcs.items[cand.items[0]].sub) catch unreachable;
            }
        }
        for (f.types) |t| bump(&h_types, a, t);
    }

    // ---- misclassified: boundary fns that call no real presentation code ----
    // These sit in a pruned namespace but are pure logic the server needs ->
    // they belong in D2Common/D2Game, not D2Client. (vs genuine stub points.)
    var h_misplaced = std.StringHashMap(u32).init(a);
    var h_mis_ns = std.StringHashMap([]const u8).init(a);
    {
        var it = h_bound.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (isPresentationName(name)) continue; // clearly client by name
            const cand = ctx.name_index.get(name) orelse continue;
            var touches_client = false;
            outer: for (cand.items) |c| {
                if (!ctx.funcs.items[c].prune) continue;
                for (ctx.funcs.items[c].calls) |cn| {
                    const tc = ctx.name_index.get(cn) orelse continue;
                    for (tc.items) |t| if (isHardClient(ctx.funcs.items[t].sub)) {
                        touches_client = true;
                        break :outer;
                    };
                }
            }
            if (!touches_client) {
                h_misplaced.put(name, e.value_ptr.*) catch unreachable;
                h_mis_ns.put(name, ctx.funcs.items[cand.items[0]].sub) catch unreachable;
            }
        }
    }

    // ---- emit ----
    var od = std.Io.Dir.cwd().openDir(io, out, .{}) catch |e| {
        std.debug.print("error: cannot open --out dir '{s}': {}\n", .{ out, e });
        std.process.exit(1);
    };
    defer od.close(io);
    try emit(a, io, od, &sub_count, &sub_top, &top_count, &sub_funcs, &sub_edge, node_min, edge_min);
    try emitHoles(a, io, od, &h_ext, &h_bound, &h_gap, &h_ns, &h_types);
    try emitMisplaced(a, io, od, &h_misplaced, &h_mis_ns);
    std.debug.print("holes: {d} external, {d} client-boundary ({d} of them MISPLACED -> server_misplaced.md), {d} gaps, {d} types\n", .{ h_ext.count(), h_bound.count(), h_misplaced.count(), h_gap.count(), h_types.count() });

    std.debug.print(
        \\parsed: {d} win functions  ({d} maps, {d} cpp scanned)
        \\roots:  {d}  ({d} SCMD handlers + {d} address-taken server fns)
        \\address-taken names: {d}   ambiguous-dropped edges: {d}
        \\reachable: {d}   (server-relevant {d} / client-leak {d})
        \\out: {s}/  (server_tree.txt, server.dot, server_worklist.md)
        \\
    , .{ N, n_maps, n_src, roots.items.len, n_scmd, n_indirect, ctx.addr_taken.count(), ambiguous, reach, keep, reach - keep, out });

    // top-level tree to stdout
    printTopTree(a, &top_count, &sub_count, &sub_top);
}

fn collectDesc(a: std.mem.Allocator, m: *std.StringHashMap(u32)) []Pair {
    var list: std.ArrayList(Pair) = .empty;
    var it = m.iterator();
    while (it.next()) |e| list.append(a, .{ .key = e.key_ptr.*, .n = e.value_ptr.* }) catch unreachable;
    std.mem.sort(Pair, list.items, {}, pairDesc);
    return list.items;
}

fn subLeaf(sub: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, sub, '/')) |i| sub[i + 1 ..] else sub;
}

fn printTopTree(a: std.mem.Allocator, top_count: *std.StringHashMap(u32), sub_count: *std.StringHashMap(u32), sub_top: *std.StringHashMap([]const u8)) void {
    const tops = collectDesc(a, top_count);
    for (tops) |tp| {
        if (isPrune(tp.key)) continue;
        std.debug.print("{s}  ({d})\n", .{ tp.key, tp.n });
        const subs = collectDesc(a, sub_count);
        for (subs) |sp| {
            const stp = sub_top.get(sp.key) orelse continue;
            if (!std.mem.eql(u8, stp, tp.key)) continue;
            std.debug.print("    {s: <24} {d}\n", .{ subLeaf(sp.key), sp.n });
        }
    }
}

fn emit(
    a: std.mem.Allocator,
    io: std.Io,
    od: std.Io.Dir,
    sub_count: *std.StringHashMap(u32),
    sub_top: *std.StringHashMap([]const u8),
    top_count: *std.StringHashMap(u32),
    sub_funcs: *std.StringHashMap(std.ArrayList([]const u8)),
    sub_edge: *std.StringHashMap(u32),
    node_min: u32,
    edge_min: u32,
) !void {
    const subs = collectDesc(a, sub_count);
    const tops = collectDesc(a, top_count);

    // ---- server_tree.txt ----
    {
        var buf: std.ArrayList(u8) = .empty;
        for (tops) |tp| {
            bprint(&buf, a, "{s} ({d})\n", .{ tp.key, tp.n });
            for (subs) |sp| {
                const stp = sub_top.get(sp.key) orelse continue;
                if (!std.mem.eql(u8, stp, tp.key)) continue;
                bprint(&buf, a, "  {s} ({d})\n", .{ sp.key, sp.n });
                if (sub_funcs.get(sp.key)) |fl| {
                    const names = fl.items;
                    std.mem.sort([]const u8, names, {}, strLess);
                    for (names) |nm| bprint(&buf, a, "    {s}\n", .{nm});
                }
            }
        }
        try writeFile(od, io, "server_tree.txt", buf.items);
    }

    // ---- server_worklist.md ----
    {
        var buf: std.ArrayList(u8) = .empty;
        bprint(&buf, a, "| subsystem | reachable fns |\n|-|-|\n", .{});
        for (subs) |sp| {
            const stp = sub_top.get(sp.key) orelse continue;
            if (isPrune(stp) or sp.n < 3) continue;
            bprint(&buf, a, "| {s} | {d} |\n", .{ sp.key, sp.n });
        }
        try writeFile(od, io, "server_worklist.md", buf.items);
    }

    // ---- server.dot ----
    {
        var buf: std.ArrayList(u8) = .empty;
        bprint(&buf, a, "digraph NativeSurface {{\n", .{});
        bprint(&buf, a, "  rankdir=LR; node [shape=box,style=\"filled,rounded\",fontname=\"Helvetica\"];\n", .{});
        bprint(&buf, a, "  graph [splines=polyline,nodesep=0.4,ranksep=1.1];\n", .{});
        for (subs) |sp| {
            if (sp.n < node_min) continue;
            const stp = sub_top.get(sp.key) orelse continue;
            const color = if (isPrune(stp)) "#d9d9d9" else if (std.mem.eql(u8, stp, "D2Common")) "#9ecae1" else if (std.mem.eql(u8, stp, "D2Game")) "#a1d99b" else "#fdd0a2";
            bprint(&buf, a, "  \"{s}\" [label=\"{s}\\n{d} fns\",fillcolor=\"{s}\"];\n", .{ sp.key, sp.key, sp.n, color });
        }
        var it = sub_edge.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < edge_min) continue;
            const sep = std.mem.indexOfScalar(u8, e.key_ptr.*, 0).?;
            const src = e.key_ptr.*[0..sep];
            const dst = e.key_ptr.*[sep + 1 ..];
            if ((sub_count.get(src) orelse 0) < node_min) continue;
            if ((sub_count.get(dst) orelse 0) < node_min) continue;
            bprint(&buf, a, "  \"{s}\" -> \"{s}\" [color=\"#00000066\"];\n", .{ src, dst });
        }
        bprint(&buf, a, "}}\n", .{});
        try writeFile(od, io, "server.dot", buf.items);
    }
}

fn emitHoles(
    a: std.mem.Allocator,
    io: std.Io,
    od: std.Io.Dir,
    ext: *std.StringHashMap(u32),
    bound: *std.StringHashMap(u32),
    gap: *std.StringHashMap(u32),
    ns: *std.StringHashMap([]const u8),
    types: *std.StringHashMap(u32),
) !void {
    var buf: std.ArrayList(u8) = .empty;
    bprint(&buf, a, "# Holes in the server surface\n\n", .{});
    bprint(&buf, a, "What the ~4.5k server functions reference but the set does not satisfy.\n\n", .{});

    bprint(&buf, a, "## External symbols — referenced, not reconstructed ({d})\n", .{ext.count()});
    bprint(&buf, a, "Must be implemented or linked natively (CRT, Win32, Storm imports, intrinsics).\n\n", .{});
    bprint(&buf, a, "| symbol | call sites |\n|-|-|\n", .{});
    for (collectDesc(a, ext)) |p| bprint(&buf, a, "| {s} | {d} |\n", .{ p.key, p.n });

    bprint(&buf, a, "\n## Client/render/sound boundary — server calls into pruned code ({d})\n", .{bound.count()});
    bprint(&buf, a, "Each is a stub point: reimplement, no-op, or route over the wire.\n\n", .{});
    bprint(&buf, a, "| function | call sites | subsystem |\n|-|-|-|\n", .{});
    for (collectDesc(a, bound)) |p| bprint(&buf, a, "| {s} | {d} | {s} |\n", .{ p.key, p.n, ns.get(p.key) orelse "" });

    bprint(&buf, a, "\n## Ambiguous-resolution gaps — reconstructed server fns referenced but not in closure ({d})\n", .{gap.count()});
    bprint(&buf, a, "Likely real edges dropped because the callee name collides across modules. Review.\n\n", .{});
    bprint(&buf, a, "| function | call sites | subsystem |\n|-|-|-|\n", .{});
    for (collectDesc(a, gap)) |p| bprint(&buf, a, "| {s} | {d} | {s} |\n", .{ p.key, p.n, ns.get(p.key) orelse "" });

    bprint(&buf, a, "\n## Type / data surface — structs the server set touches ({d})\n", .{types.count()});
    bprint(&buf, a, "The data structures a native port must define (usedTypes frequency).\n\n", .{});
    bprint(&buf, a, "| type | uses |\n|-|-|\n", .{});
    for (collectDesc(a, types)) |p| {
        if (p.n < 3) continue;
        bprint(&buf, a, "| {s} | {d} |\n", .{ p.key, p.n });
    }
    try writeFile(od, io, "server_holes.md", buf.items);
}

fn emitMisplaced(
    a: std.mem.Allocator,
    io: std.Io,
    od: std.Io.Dir,
    mis: *std.StringHashMap(u32),
    ns: *std.StringHashMap([]const u8),
) !void {
    var buf: std.ArrayList(u8) = .empty;
    bprint(&buf, a, "# Misclassified functions — server logic filed under client\n\n", .{});
    bprint(&buf, a, "Functions in a pruned (client/render/sound) namespace that the server\n", .{});
    bprint(&buf, a, "calls and that themselves touch NO presentation code — i.e. pure logic in\n", .{});
    bprint(&buf, a, "the wrong place. Move out (most belong in D2Common / D2Game). Move the\n", .{});
    bprint(&buf, a, "symbol in Ghidra (`move_symbol_to_namespace`); it flows to the recon on regen.\n\n", .{});
    bprint(&buf, a, "Verified example moved: D2ApplyPercent (0x483360) _SkillHelpers -> D2Common::Stats.\n\n", .{});
    bprint(&buf, a, "| function | call sites | current namespace |\n|-|-|-|\n", .{});
    for (collectDesc(a, mis)) |p| {
        bprint(&buf, a, "| {s} | {d} | {s} |\n", .{ p.key, p.n, ns.get(p.key) orelse "" });
    }
    try writeFile(od, io, "server_misplaced.md", buf.items);
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn writeFile(od: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    try od.writeFile(io, .{ .sub_path = name, .data = bytes });
}

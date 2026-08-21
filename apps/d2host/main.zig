//! Host the pre-1.14 DLLs directly: load the module set, install a callback table, and see how far
//! D2Game gets before it complains. Runs as an x86-windows exe under wine.
//!
//! This is the other shape of game server. `apps/d2gs` injects into 1.14d's merged Game.exe and
//! detours it; here D2Game.dll is a library we drive, which is what it was built to be before 1.14
//! merged everything. The host contract is documented in `docs/dll-host.md` — notably it is the same
//! callback table `apps/d2gs/engine/realm.zig` already fills for 1.14d.
//!
//!   d2host <dir-with-the-dlls>
//!
//! It reports each step, so a failure names the module or call that broke rather than just dying.

const std = @import("std");
const fastcall = @import("fastcall");
const store = @import("gs_store");
const proto = @import("realm_proto").protocol;
const cb = @import("d2engine").callbacks;
const hostapi = @import("d2engine").hostapi;
const gameflags = @import("d2engine").gameflags;
const d2version = @import("d2engine").version;
const build_options = @import("build_options");

const HMODULE = *anyopaque;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
extern "kernel32" fn InitializeCriticalSection(cs: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GetProcAddress(m: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn SetCurrentDirectoryA(path: [*:0]const u8) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(h: *anyopaque, buf: [*]const u8, n: u32, wrote: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn AllocConsole() callconv(.winapi) i32;
extern "kernel32" fn AddVectoredExceptionHandler(first: u32, handler: *const fn (*ExceptionPointers) callconv(.winapi) i32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCommandLineA() callconv(.winapi) [*:0]const u8;

var out_handle: ?*anyopaque = null;

fn say(msg: []const u8) void {
    const h = out_handle orelse return;
    var wrote: u32 = 0;
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), &wrote, null);
    _ = WriteFile(h, "\r\n", 2, &wrote, null);
}

fn sayFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    say(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

fn sayHex(prefix: []const u8, v: usize) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}0x{x}", .{ prefix, v }) catch return;
    say(s);
}

/// The port this server listens on — never 4000. d2ingress owns the client-facing 4000 (the port
/// the client hardcodes) and splices game traffic through to the port a GS advertises, so binding
/// it here would collide with the ingress and stop a fleet sharing a host. Same default and same
/// override as `apps/d2gs`: `--gs-addr ip:port`, or `D2GS_GS_ADDR` for k8s.
fn listenPort() u16 {
    var buf: [64]u8 = undefined;
    const n = GetEnvironmentVariableA("D2GS_GS_ADDR", &buf, buf.len);
    if (n == 0 or n >= buf.len) return 4100;
    const spec = buf[0..n];
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return 4100;
    return std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch 4100;
}

/// Read an environment variable into `buf`, or null when unset.
fn env(name: [*:0]const u8, buf: []u8) ?[]const u8 {
    const n = GetEnvironmentVariableA(name, buf.ptr, @intCast(buf.len));
    return if (n == 0 or n >= buf.len) null else buf[0..n];
}

/// This server's identity in the shared store. Same knobs as `apps/d2gs`, because a fleet that
/// mixes both has to be configured one way.
var gsid: u32 = 0;
var public_ip: [4]u8 = .{ 127, 0, 0, 1 };
var public_port: u16 = 4100;
var max_games: u32 = 7;
var live_games: u32 = 0;

/// What this server publishes about itself, so a realm can choose WHICH server rather than
/// whichever is free. `v` is the engine, and it is set from the version this instantiation of `run`
/// was generated for — so it cannot disagree with what the process actually drives.
///
/// A fleet stops being interchangeable the moment it hosts more than one engine: a 1.10f client
/// sent to a 1.13c server does not get a worse game, it gets no game.
var gs_labels: []const u8 = "";

/// The realm link is optional. Without a store address this stays a standalone spike that creates
/// one game and ticks — which is exactly what it was, and still the quickest way to prove a build.
fn realmConfigured() bool {
    return gsid != 0 and store.enabled();
}

/// Read the store address and this server's identity, the same env the DLL server takes so a
/// fleet mixing both is configured one way.
fn configureRealm() void {
    var buf: [128]u8 = undefined;
    if (env("D2GS_REDIS_ADDR", &buf)) |addr| store.configure(addr);
    var idbuf: [32]u8 = undefined;
    if (env("D2GS_GSID", &idbuf)) |v| gsid = std.fmt.parseInt(u32, v, 10) catch 0;
    var abuf: [64]u8 = undefined;
    if (env("D2GS_GS_ADDR", &abuf)) |spec| {
        if (std.mem.lastIndexOfScalar(u8, spec, ':')) |c| {
            public_port = std.fmt.parseInt(u16, spec[c + 1 ..], 10) catch public_port;
            var it = std.mem.splitScalar(u8, spec[0..c], '.');
            var i: usize = 0;
            while (it.next()) |octet| : (i += 1) {
                if (i >= 4) break;
                public_ip[i] = std.fmt.parseInt(u8, octet, 10) catch return;
            }
        }
    }
}

// ── the character load ───────────────────────────────────────────────────────
//
// `fpGetDatabaseCharacter` is asynchronous: the call site at 0x6fc37413 discards the return value,
// so the answer goes back through a separate engine entry point. That is `D2Game @10007`, whose
// `RET 0x20` matches a published third-party host's `D2GSSendDatabaseCharacter` — eight stdcall
// args — and whose body calls `CLIENTS_AttachSaveFile`.
//
// Delivering from inside the callback would run the engine's join continuation halfway through its
// own join call, so the fetch queues here and the tick loop delivers it afterwards. That is the
// same shape `apps/d2gs/engine/realm.zig` needs on 1.14d, for the same reason.

/// Shape from d2engine; only the location is per version.
var send_character: ?*const hostapi.SendDatabaseCharacterFn = null;

/// Pre-1.10 takes one argument fewer, and we are the caller here, so the wrong shape drifts OUR
/// stack rather than the engine's. Selected at load time from the version's measured arity.
var send_character7: ?*const hostapi.SendDatabaseCharacterFn7 = null;

/// One in-flight character load. A join asks for exactly one save, so a small table is enough; a
/// full one refuses the join rather than dropping it silently, which would leave a client sitting
/// on a loading screen until it timed out.
const Pending = struct {
    used: bool = false,
    client_id: u32 = 0,
    len: u32 = 0,
    /// Read off the client at +0x60. The engine compares it and drops the client on a mismatch,
    /// so it is not optional and it cannot be zero.
    container: usize = 0,
    save: [8192]u8 = undefined,
};

/// A zeroed FILETIME and the {FILETIME*, unk0x194} pair pointing at it. The engine copies both
/// dwords into pClient+0x190/+0x194 rather than reading them, so placeholders are fine — but the
/// pointer itself has to be valid.
var load_filetime: [2]u32 = .{ 0, 0 };
var load_filetimes: [2]u32 = undefined;

var pending: [8]Pending = @splat(.{});

/// Everything version-specific the callback table needs, generated once per `version`. This is
/// the actual mechanism behind "the version is a suggestion, not a rebuild": `run()` below is
/// itself generic over `comptime version`, and picking a different (measured) version at runtime
/// means the *same binary* instantiates a *different* `Binding`, with no source edit — the two
/// things that differ between engine builds (a callback's stack-arg count, and where the client
/// struct's fields sit relative to ECX) are exactly the two things this closes over.
///
/// Two guardrails, not one: `hostapi.clientFields` already refuses to build for a version with no
/// measured offsets (`orelse @compileError`). The `comptime` asserts below catch a narrower but
/// just as real mistake — a *future* version whose measured arity for one of these two slots
/// differs from what this specific template's function body was written for. Without them, adding
/// a version with (say) a 3-stack-arg `fpFindPlayerToken` would silently reuse this 5-arg
/// `findPlayerToken`, reading three real values and two words of engine stack garbage instead of
/// failing to compile. A version whose arity genuinely differs needs its own override here, the
/// same way `apps/d2gs/engine/realm.zig` has its own 1.14d-specific implementations.
fn Binding(comptime version: d2version.Version) type {
    const spec = d2version.spec(version);
    // A version can have every arity counted and still have an unknown client layout, because the
    // two are found different ways: arities come off the call sites, the layout only shows up in
    // memory. Rather than block on that, such a version builds a probe — it boots, and the first
    // fetch prints what is actually around ECX so the offsets can be measured rather than guessed.
    const name_source = hostapi.charNameSource(version);
    const probing = name_source == null;
    const client_fields = switch (name_source orelse hostapi.CharNameSource{ .edx_pointer = {} }) {
        .realm_relative => |f| f,
        .edx_pointer => hostapi.ClientFieldOffsets{ .name = 0, .account = 0 },
    };
    const name_in_edx = (name_source orelse hostapi.CharNameSource{ .edx_pointer = {} }) == .edx_pointer;

    // A handler may declare FEWER stack parameters than the engine pushes — the shim pushes all
    // `n_stack` of them and cleans up `n_stack`, so trailing arguments a handler never names are
    // simply never read. Declaring MORE is the bug: those read whatever the engine left on the
    // stack. So the invariant is a floor, not an equality, which is also what lets one handler
    // body serve 1.10f's five-argument fpFindPlayerToken and 1.09d's three.
    comptime {
        assertReads(version, .fpFindPlayerToken, 2, "findPlayerToken reads game_id and account");
        // The probe names no stack parameters at all, so the floor only binds a real handler —
        // and the two shapes read a different number of them.
        if (!probing)
            assertReads(version, .fpGetDatabaseCharacter, if (name_in_edx) 1 else 2, if (name_in_edx)
                "getDatabaseCharacterEdx reads client_id"
            else
                "getDatabaseCharacter reads client_id and account");
    }

    return struct {
        /// Slot 0x08. `__fastcall`, ECX = &pClient->pRealm.
        ///
        /// The offsets from ECX to the name/account fields are per-version, not a fixed 1.14d
        /// constant: pRealm's own position in the client struct moves (1.10f +0x68, 1.09d +0x54),
        /// which shifts the ECX-relative distance even though both versions keep the fields
        /// themselves at the same +0x0D/+0x1D within the struct.
        /// Dump what surrounds ECX so the character name and account can be located by eye. The
        /// engine hands this callback `&pClient->pRealm`, and the fields sit at negative offsets
        /// from it whose distance is per-version — 1.10f's pRealm is at client+0x68, 1.09d's at
        /// +0x54, 1.07's at +0x20 — so the layout cannot be carried over from another build.
        pub fn probeClientFields(ecx: usize, edx: usize) callconv(.c) usize {
            sayFmt("d2host: PROBE fpGetDatabaseCharacter, ecx=0x{x}", .{ecx});
            // The realm already told us which character is joining, so the probe does not have to
            // be read by eye: search memory around ECX for that exact name and report the distance.
            // That is the measurement `hostapi.clientFields` wants, taken from the only place the
            // layout is actually visible.
            // EDX is the other candidate on builds where ECX turns out to be the game rather than
            // the client: 1.07 passes one stack arg where 1.10f passes two, so the arguments are
            // not merely shifted, they are different things.
            sayFmt("d2host: PROBE edx=0x{x}", .{edx});
            if (edx > 0x10000) {
                const p: [*]const u8 = @ptrFromInt(edx);
                var txt: [32]u8 = undefined;
                for (0..32) |i| txt[i] = if (p[i] >= 0x20 and p[i] < 0x7f) p[i] else '.';
                sayFmt("  [edx] = {s}", .{txt});
            }
            var found_any = false;
            for (&join_contexts) |*j| {
                if (!j.used) continue;
                const names = [_][]const u8{ j.charName(), std.mem.sliceTo(&j.account, 0) };
                const labels = [_][]const u8{ "szCharName", "szAccName" };
                for (names, labels) |needle, label| {
                    if (needle.len == 0) continue;
                    const span: usize = 0x600;
                    const anchors = [_]struct { name: []const u8, at: usize }{
                        .{ .name = "ecx", .at = ecx },
                        .{ .name = "edx", .at = edx },
                    };
                    for (anchors) |anchor| {
                        if (anchor.at <= span) continue;
                        const from = anchor.at -% span;
                        var at: usize = 0;
                        while (at < span * 2) : (at += 1) {
                            const p: [*]const u8 = @ptrFromInt(from + at);
                            if (!std.mem.eql(u8, p[0..needle.len], needle)) continue;
                            // A field, not a stray copy: it should be NUL-terminated in place.
                            if (p[needle.len] != 0) continue;
                            const delta = @as(isize, @intCast(from + at)) - @as(isize, @intCast(anchor.at));
                            sayFmt("  found {s} \"{s}\" at {s}{d} (0x{x} away)", .{
                                label, needle, anchor.name, delta, @abs(delta),
                            });
                            found_any = true;
                        }
                    }
                }
            }
            if (!found_any) say("  neither name found within +/-0x600 of ecx — widen the search");
            say("d2host: probe only — refusing the join until the offsets are recorded");
            return 0;
        }

        /// 1.07's shape: EDX is the character name and there is one stack arg, not two. The
        /// account is not passed at all, so it comes from the realm's JOINGAME the same way the
        /// other shape's fallback does.
        pub fn getDatabaseCharacterEdx(ecx: usize, edx: usize, client_id: usize) callconv(.c) usize {
            _ = ecx;
            const char_name = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(edx)), 0);
            const acct_name = accountFor(char_name) orelse "";
            if (acct_name.len == 0)
                sayFmt("d2host: no account known for '{s}' — the realm sent no JOINGAME for it", .{char_name});
            const slot = for (&pending) |*p| {
                if (!p.used) break p;
            } else {
                say("d2host: no free character slot — refusing this join");
                return 0;
            };
            slot.* = .{ .used = true, .client_id = @intCast(client_id), .container = 0 };
            slot.len = @intCast(store.getChar(acct_name, char_name, &slot.save));
            sayFmt("d2host: fpGetDatabaseCharacter ({s}) — save bytes 0x{x}", .{ char_name, slot.len });
            return 0;
        }

        pub fn getDatabaseCharacter(ecx: usize, edx: usize, client_id: usize, account: usize) callconv(.c) usize {
            _ = .{ edx, account };
            const sz_char: [*:0]const u8 = @ptrFromInt(ecx -% client_fields.name);
            const sz_acct: [*:0]const u8 = @ptrFromInt(ecx -% client_fields.account);
            const char_name = std.mem.sliceTo(sz_char, 0);
            // The realm's JOINGAME is the only place the account is known; the engine leaves its
            // own field empty on this path, so fall back to it only if we were never told.
            const acct_name = accountFor(char_name) orelse std.mem.sliceTo(sz_acct, 0);
            if (acct_name.len == 0) {
                // Nothing told us the account: the engine leaves its field empty on this path and
                // no JOINGAME for this character reached us. Say so, because the alternative is a
                // fetch against `realmd:char::<char>` that misses for a reason nothing explains.
                sayFmt("d2host: no account known for '{s}' — the realm sent no JOINGAME for it", .{char_name});
            }

            const slot = for (&pending) |*p| {
                if (!p.used) break p;
            } else {
                say("d2host: no free character slot — refusing this join");
                return 0;
            };

            // pClient+0x60, which is ECX-8. The engine checks this against pClient[0x18] when the
            // save comes back and removes the client if it disagrees.
            const container_slot: *const usize = @ptrFromInt(ecx -% 8);
            slot.* = .{ .used = true, .client_id = @intCast(client_id), .container = container_slot.* };
            slot.len = @intCast(store.getChar(acct_name, char_name, &slot.save));
            sayHex("d2host: fpGetDatabaseCharacter — save bytes ", slot.len);
            return 0;
        }

        /// Slot 0x18, the closed-realm join gate. `__fastcall` with five stack args on 1.10f.
        ///
        /// Called from `GAME_VerifyJoinGame`. Five stack args is from the call site's five pushes,
        /// which is the reliable count — the decompiler renders the indirect call with fewer
        /// because it cannot know an unnamed pointer's signature.
        ///
        /// **Nonzero accepts.** Zero makes the engine log
        /// `[HACKLIST] <D2CLTSYS_JOINGAME> ACCT:%s CLIENT:%s GAMEID:%d TOKEN:%x ERROR: Invalid Token`
        /// and refuse the join. That message is also where the argument names come from — it is
        /// built from EBP/EDI/ESI/EBX, the account, character, game id and token — so the
        /// identities below are read off the engine's own logging rather than guessed, but they
        /// are inference, unlike the count.
        ///
        /// The slot cannot be left null: the engine runs `IsBadCodePtr` on it first and a bad
        /// pointer is an assert and `exit(-1)`, not a skipped call.
        ///
        /// This is an authorisation decision, so it is made rather than assumed. The realm stages
        /// (account, character) here before it tells the client where to connect, and BOTH halves
        /// are checked: the character the engine reports must have been staged, and the account
        /// claimed alongside it must be the one the realm staged it under.
        ///
        /// Matching the character alone is not enough, which is the trap worth naming. Both fields
        /// arrive from the client's own join packet, so a client that knows a character currently
        /// staged on this server could otherwise name it and be handed that character's save.
        /// Requiring the pair means impersonation also needs the victim's account name.
        ///
        /// With no realm there is nothing to check against, and refusing would break the standalone
        /// smoke path that creates its own game — so enforcement follows the realm.
        /// Only the first two stack arguments are named: 1.10f pushes five and 1.09d three, but
        /// both push the game id first and the account second, and the shim cleans up whatever
        /// that version's count is.
        pub fn findPlayerToken(ecx: usize, edx: usize, game_id: usize, account: usize) callconv(.c) usize {
            const char_name: [*:0]const u8 = @ptrFromInt(ecx);
            const acct_name: [*:0]const u8 = @ptrFromInt(account);
            sayFmt("d2host: fpFindPlayerToken — {s}/{s} gameid={d} token=0x{x}", .{
                std.mem.sliceTo(acct_name, 0),
                std.mem.sliceTo(char_name, 0),
                game_id,
                edx,
            });
            if (!realmConfigured()) return 1;
            const want = std.mem.sliceTo(char_name, 0);
            const staged = accountFor(want) orelse {
                sayFmt("d2host: REFUSED join — the realm staged no context for '{s}'", .{want});
                return 0;
            };
            // The account is only checked where the build actually supplies one. Not every version
            // passes it here — 1.06b keeps it in a BSS global the create path leaves empty, and the
            // stack layout differs besides (1.10f pushes five arguments, 1.09d three) — so an empty
            // string means "this build did not tell us", not "the client claimed nothing".
            const claimed = std.mem.sliceTo(acct_name, 0);
            if (claimed.len != 0 and !std.mem.eql(u8, staged, claimed)) {
                sayFmt("d2host: REFUSED join — '{s}' is staged for '{s}', not '{s}'", .{ want, staged, claimed });
                return 0;
            }
            return 1;
        }

        /// A reporting stub for a slot this version dispatches, or null for one it never does.
        /// Null is the honest answer to "never dispatched": every dispatch site the scan found
        /// reads the slot and branches on it, so a null cannot be called by accident — whereas a
        /// stub for a call that never comes needs a stack-cleanup count nothing can check.
        inline fn stubFor(comptime which: cb.Slot, comptime name: []const u8) ?*const anyopaque {
            // A slot the sweep found no call site for still gets a POINTER, just not a returning
            // one. Leaving it null means the engine calls address zero, and the process dies as
            // "Illegal instruction at address 0x0" — which names neither the slot nor the fact
            // that a callback was involved at all.
            //
            // `no_site_found` is not proof there is no site: dispatch is often
            // `lea reg,[table+slot]; call [reg]`, which a displacement scan never sees. So this is
            // the case where a version's table is INCOMPLETE, and the useful thing is to say which
            // slot to go and measure.
            //
            // It cannot simply return: with the arity unknown there is no way to balance the
            // stack, and guessing corrupts the caller instead of the process. So it reports and
            // stops, which is what was going to happen anyway — just legibly.
            if (comptime !cb.dispatches(spec.stack_args, which)) return Unmeasured(name).ptr;
            return Stub(name, cb.stackArgs(spec.stack_args, which)).ptr;
        }

        // Every arity routes through `cb.stackArgs(spec.stack_args, .slot)` rather than a literal,
        // so a stub for a slot `version` has never had counted is a COMPILE ERROR, not a silent
        // reuse of another version's number under a different engine.
        pub fn buildCallbackTable() CallbackTable {
            return .{
                // Not a report. It is the only moment the realm learns a game ended, and until it
                // did the realm went on believing every character in that game was still in it.
                .close_game = @ptrCast(&fastcall.Callback2(
                    cb.stackArgs(spec.stack_args, .fpCloseGame),
                    closeGame,
                ).shim),
                .leave_game = stubFor(.fpLeaveGame, "pfLeaveGame"),
                // The one slot that is a real implementation rather than a report: it drives every join.
                .get_database_character = if (probing) @ptrCast(&fastcall.Callback2(
                    cb.stackArgs(spec.stack_args, .fpGetDatabaseCharacter),
                    probeClientFields,
                ).shim) else if (name_in_edx) @ptrCast(&fastcall.Callback2(
                    cb.stackArgs(spec.stack_args, .fpGetDatabaseCharacter),
                    getDatabaseCharacterEdx,
                ).shim) else @ptrCast(&fastcall.Callback2(
                    cb.stackArgs(spec.stack_args, .fpGetDatabaseCharacter),
                    getDatabaseCharacter,
                ).shim),
                .save_database_character = stubFor(.fpSaveDatabaseCharacter, "pfSaveDatabaseCharacter"),
                .server_log_message = @ptrCast(&serverLogMessage),
                .enter_game = stubFor(.fpEnterGame, "pfEnterGame"),
                .find_player_token = @ptrCast(&fastcall.Callback2(
                    cb.stackArgs(spec.stack_args, .fpFindPlayerToken),
                    findPlayerToken,
                ).shim),
                .save_database_guild = stubFor(.fpSaveDatabaseGuild, "pfSaveDatabaseGuild"),
                .unlock_database_character = stubFor(.fpUnlockDatabaseCharacter, "pfUnlockDatabaseCharacter"),
                .unk_0x24 = stubFor(.fpReserved0x24, "unk0x24"),
                .update_character_ladder = stubFor(.fpUpdateCharacterLadder, "pfUpdateCharacterLadder"),
                .update_game_information = stubFor(.fpUpdateGameInformation, "pfUpdateGameInformation"),
                .handle_packet = stubFor(.fpHandlePacket, "pfHandlePacket"),
                .set_game_data = stubFor(.fpSetGameData, "pfSetGameData"),
                .relock_database_character = stubFor(.fpRelockDatabaseCharacter, "pfRelockDatabaseCharacter"),
                .load_complete = @ptrCast(&loadComplete),
            };
        }

        /// The tail past 0x40. Filled only where the build is known to index it — but the storage
        /// carries it either way, because "this build does not index it" is a claim about a sweep
        /// and the cost of the sweep being wrong is a call through whatever follows the table.
        pub fn buildCallbackTail() cb.Ext113c {
            if (!spec.callback_tail) return .{};
            return .{
                .fpGetDatabaseFileTime = @ptrCast(&fastcall.Callback2(0, getDatabaseFileTime).shim),
            };
        }
    };
}

/// Hand every fetched save to the engine, outside the join call stack. A zero-length fetch is a
/// refusal, not a silence: bLock nonzero tells the engine the load failed and it disconnects.
fn pumpCharacterLoads() void {
    for (&pending) |*p| {
        if (!p.used) continue;
        p.used = false;
        const refused = p.len == 0;
        if (refused) say("d2host: character fetch failed — refusing the join");
        const size: u32 = if (refused) 0 else p.len;
        const lock: u32 = if (refused) 1 else 0;
        if (send_character7) |send| {
            // No container argument before 1.10: the engine had not started cross-checking it.
            _ = send(p.client_id, &p.save, size, size, lock, 0, &load_filetimes);
        } else if (send_character) |send| {
            _ = send(p.client_id, &p.save, size, size, lock, 0, &load_filetimes, p.container);
        } else return;
        if (!refused) {
            sayHex("d2host: character delivered, bytes ", p.len);
            // The four fields the engine's header parser gates on, before it will build anything.
            // Every one of its rejections comes back as the same opaque "Error:14=nError", so the
            // only way to tell a bad checksum from a stale new-character bit is to say what we sent.
            if (p.len >= 0x28) {
                const sig = std.mem.readInt(u32, p.save[0..4], .little);
                const ver = std.mem.readInt(u32, p.save[4..8], .little);
                const declared = std.mem.readInt(u32, p.save[8..12], .little);
                const status = std.mem.readInt(u32, p.save[0x24..0x28], .little);
                sayFmt("d2host: save sig=0x{x} ver=0x{x} declared={d} actual={d} status=0x{x} new_char={s}", .{
                    sig, ver, declared, p.len, status,
                    if (status & 1 != 0) "yes" else "NO — the engine will want a full save body",
                });
            }
        }
    }
}

/// Resolved from our own D2Net, by name.
var connected_clients_fn: ?*const fn () callconv(.winapi) u32 = null;

fn connectedClients() u32 {
    const f = connected_clients_fn orelse return 0;
    return f();
}

var flush_logged = false;
var flushes: usize = 0;
var alloc_logged = false;

/// The engine call that makes a game, resolved once at startup so the realm handler can use it.
const CreateGameFn = *const fn (
    [*:0]u8, // game name (written to, not const)
    [*:0]const u8, // password
    [*:0]const u8, // description
    u32, // flags
    u8, // arena template
    u8, // max level difference
    u8, // max players
    *u16, // out: game id
) callconv(.winapi) i32;

var create_game: ?CreateGameFn = null;

/// Answer one CREATEGAME from the realm by actually creating it. The realm keeps the authoritative
/// game list; this only reports what the engine did, so a refusal has to be reported as a refusal
/// rather than a silence — a client left waiting on a game that was never made just times out.
fn handleCreateGame(seq: u32, body: []const u8) void {
    var reply = std.mem.zeroes(proto.CreateGameReply);
    reply.h = proto.header(.creategame, @sizeOf(proto.CreateGameReply), seq);

    const make = create_game orelse {
        reply.result = 1;
        _ = store.putReply(seq, std.mem.asBytes(&reply), 30);
        return;
    };
    if (body.len < 5) {
        reply.result = 1;
        _ = store.putReply(seq, std.mem.asBytes(&reply), 30);
        return;
    }

    // Flags are load-bearing, not cosmetic: without ARENAFLAG_ClientUpdate the engine halts the
    // whole process the first time this game's task is processed. Same builder the 1.14d server
    // uses, so the two cannot drift.
    const ladder = body[0];
    const is_expansion = body[1] != 0;
    const difficulty: u3 = @truncate(body[2]);
    const is_hardcore = body[3] != 0;
    const flags = gameflags.gameFlags(difficulty, is_expansion, is_hardcore);

    var off: usize = 4;
    const want_name = proto.readCStr(body, &off);
    const want_pass = proto.readCStr(body, &off);

    // The engine writes into the name buffer, so it cannot be the realm's bytes.
    var name: [32:0]u8 = @splat(0);
    var pass: [32:0]u8 = @splat(0);
    @memcpy(name[0..@min(want_name.len, 31)], want_name[0..@min(want_name.len, 31)]);
    @memcpy(pass[0..@min(want_pass.len, 31)], want_pass[0..@min(want_pass.len, 31)]);

    var game_id: u16 = 0;
    const ok = make(&name, &pass, "", flags, ladder, 0, 8, &game_id);
    if (ok == 0) {
        say("d2host: CREATEGAME refused by the engine");
        reply.result = proto.CREATE_SERVER_FULL;
    } else {
        live_games += 1;
        reply.gameid = game_id;
        sayHex("d2host: CREATEGAME made game ", game_id);
    }
    _ = store.putReply(seq, std.mem.asBytes(&reply), 30);
}

/// Who is joining, remembered from the realm's JOINGAME so the character fetch can find them.
///
/// The engine's join path carries the character name and the token but **never the account** — it
/// leaves `pClient+0x1D` empty — and the save is keyed by account. Without this the fetch looks up
/// `realmd:char::<char>` and misses, which surfaces as a refused join with nothing to explain it.
const JoinContext = struct {
    used: bool = false,
    char: [24]u8 = @splat(0),
    account: [24]u8 = @splat(0),

    fn charName(self: *const JoinContext) []const u8 {
        return std.mem.sliceTo(&self.char, 0);
    }
};

var join_contexts: [16]JoinContext = @splat(.{});

fn rememberJoin(char: []const u8, account: []const u8) void {
    if (char.len == 0 or account.len == 0) {
        sayFmt("d2host: JOINGAME with no char/account to cache ('{s}'/'{s}')", .{ char, account });
        return;
    }
    // Newest wins: a re-join of the same character replaces its entry rather than filling the
    // table with stale copies.
    const slot = for (&join_contexts) |*j| {
        if (j.used and std.mem.eql(u8, j.charName(), char)) break j;
    } else for (&join_contexts) |*j| {
        if (!j.used) break j;
    } else &join_contexts[0];

    slot.* = .{ .used = true };
    @memcpy(slot.char[0..@min(char.len, 23)], char[0..@min(char.len, 23)]);
    @memcpy(slot.account[0..@min(account.len, 23)], account[0..@min(account.len, 23)]);
    sayFmt("d2host: JOINGAME cached {s}/{s} for the character fetch", .{ account, char });
}

fn accountFor(char: []const u8) ?[]const u8 {
    for (&join_contexts) |*j| {
        if (j.used and std.mem.eql(u8, j.charName(), char)) return std.mem.sliceTo(&j.account, 0);
    }
    return null;
}

/// `JOINGAMEREQ: gameid, token, charname\0, account\0`. The realm has already authorised this
/// join; the engine validates it again through `fpFindPlayerToken` when the client connects.
fn handleJoinGame(seq: u32, body: []const u8) void {
    sayFmt("d2host: JOINGAME seq {d}, {d} body bytes", .{ seq, body.len });
    var reply = std.mem.zeroes(proto.JoinGameReply);
    reply.h = proto.header(.joingame, @sizeOf(proto.JoinGameReply), seq);
    if (body.len < 8) {
        reply.result = 1;
        _ = store.putReply(seq, std.mem.asBytes(&reply), 30);
        return;
    }
    const gameid = std.mem.readInt(u32, body[0..4], .little);
    var off: usize = 8;
    const charname = proto.readCStr(body, &off);
    const account = proto.readCStr(body, &off);
    rememberJoin(charname, account);
    reply.gameid = gameid;
    _ = store.putReply(seq, std.mem.asBytes(&reply), 30);
}

/// Take at most one request per tick, which is what the DLL server does — the queue is drained by
/// the tick rate rather than in a burst, so one slow creation cannot stall the game loop.
fn pumpRealm() void {
    var buf: [1024]u8 = undefined;
    const n = store.popRequest(gsid, &buf);
    if (n < proto.HEADER_LEN) return;
    const size = std.mem.readInt(u16, buf[0..2], .little);
    const typ = std.mem.readInt(u16, buf[2..4], .little);
    const seq = std.mem.readInt(u32, buf[4..8], .little);
    if (size > n or size < proto.HEADER_LEN) return; // truncated; nothing sensible to answer
    // Every request is announced, including ones we do not handle. A realm message that arrives
    // and is quietly ignored is indistinguishable from one that never arrived, and that ambiguity
    // is expensive to debug from the other end.
    switch (@as(proto.Type, @enumFromInt(typ))) {
        .creategame => handleCreateGame(seq, buf[proto.HEADER_LEN .. size]),
        .joingame => handleJoinGame(seq, buf[proto.HEADER_LEN .. size]),
        else => sayFmt("d2host: realm request type 0x{x} seq {d} — not handled", .{ typ, seq }),
    }
}

/// Frames to run before exiting. 50 ms apart, so this is about a minute — enough to attach a
/// client by hand and watch what the engine makes of it.
const tick_frames = 1200;

var arg_buf: [512]u8 = undefined;

/// The one argument we take, straight off the command line: argv[0] may be quoted, everything after
/// the first unquoted space is the directory. Returns null when no argument was given.
fn firstArg() ?[*:0]const u8 {
    const cmd = GetCommandLineA();
    var i: usize = 0;
    if (cmd[0] == '"') {
        i = 1;
        while (cmd[i] != 0 and cmd[i] != '"') i += 1;
        if (cmd[i] == '"') i += 1;
    } else {
        while (cmd[i] != 0 and cmd[i] != ' ') i += 1;
    }
    while (cmd[i] == ' ') i += 1;
    if (cmd[i] == 0) return null;
    var n: usize = 0;
    while (cmd[i + n] != 0 and n + 1 < arg_buf.len) : (n += 1) arg_buf[n] = cmd[i + n];
    while (n > 0 and (arg_buf[n - 1] == ' ' or arg_buf[n - 1] == '"')) n -= 1;
    arg_buf[n] = 0;
    if (n == 0) return null;
    return @ptrCast(&arg_buf);
}

/// Resolve an export by ordinal: GetProcAddress takes the ordinal in the low word of the name ptr.
fn byOrdinal(m: HMODULE, ordinal: u16) ?*anyopaque {
    return GetProcAddress(m, @ptrFromInt(@as(usize, ordinal)));
}

// ── the callback table ───────────────────────────────────────────────────────
//
// 16 pointers, 0x40 bytes, packed. Every stub only reports that it was reached: the point of the
// spike is to learn which ones D2Game actually calls during init, and in what order.

const CallbackTable = extern struct {
    close_game: ?*const anyopaque,
    leave_game: ?*const anyopaque,
    get_database_character: ?*const anyopaque,
    save_database_character: ?*const anyopaque,
    server_log_message: ?*const anyopaque,
    enter_game: ?*const anyopaque,
    find_player_token: ?*const anyopaque,
    save_database_guild: ?*const anyopaque,
    unlock_database_character: ?*const anyopaque,
    unk_0x24: ?*const anyopaque,
    update_character_ladder: ?*const anyopaque,
    update_game_information: ?*const anyopaque,
    handle_packet: ?*const anyopaque,
    set_game_data: ?*const anyopaque,
    relock_database_character: ?*const anyopaque,
    load_complete: ?*const anyopaque
};

/// What the engine is actually handed. 1.13c and 1.14d index past the shared sixteen, and the one
/// appended slot they call — 0x54 — is dispatched with no null guard, so the table has to physically
/// extend that far even on a build that never reads it. The tail costs 0x18 bytes; getting it wrong
/// costs a call through whatever follows a 0x40-byte struct in BSS.
const EngineTable = extern struct {
    base: CallbackTable,
    ext: cb.Ext113c = .{},
};

comptime {
    // The engine indexes this table by fixed offset; a layout change silently corrupts dispatch.
    std.debug.assert(@sizeOf(CallbackTable) == 0x40);
    std.debug.assert(@offsetOf(EngineTable, "ext") == 0x40);
    std.debug.assert(@offsetOf(CallbackTable, "get_database_character") == 0x08);
    std.debug.assert(@offsetOf(CallbackTable, "save_database_character") == 0x0C);
    std.debug.assert(@offsetOf(CallbackTable, "enter_game") == 0x14);
    std.debug.assert(@offsetOf(CallbackTable, "find_player_token") == 0x18);
    std.debug.assert(@offsetOf(CallbackTable, "load_complete") == 0x3C);
}

/// Refuse to build a handler that names more stack parameters than the engine actually pushes.
/// The failure this prevents is quiet: the extra parameters would read whatever happened to be on
/// the engine's stack above the real arguments, which looks like plausible data right up until it
/// is a pointer.
fn assertReads(
    comptime version: d2version.Version,
    comptime which: cb.Slot,
    comptime reads: usize,
    comptime what: []const u8,
) void {
    const pushed = cb.stackArgs(d2version.spec(version).stack_args, which);
    if (pushed < reads) @compileError(std.fmt.comptimePrint(
        "{s}: the engine pushes {d} stack arg(s) for {s}, but {s} — a handler cannot read " ++
            "arguments the engine never pushed",
        .{ @tagName(version), pushed, @tagName(which), what },
    ));
}

/// Build a reporting stub for one slot. `n_stack` is the arg count past ECX/EDX, which is also what
/// the shim must pop — get it wrong and the engine's stack is corrupt on return.
/// A slot this version has no measured arity for. Reached only if the engine really does dispatch
/// it — which is itself the finding, because the table said it never would.
fn Unmeasured(comptime name: []const u8) type {
    return struct {
        fn impl(ecx: usize, edx: usize, ...) callconv(.c) usize {
            _ = ecx;
            _ = edx;
            say("d2host: FATAL — the engine called " ++ name ++ ", which this version has no measured");
            say("d2host:   stack-arg count for. It is listed as no_site_found, so the sweep missed a");
            say("d2host:   dispatch (typically `lea reg,[table+slot]; call [reg]`). Count the pushes at");
            say("d2host:   that site and give " ++ name ++ " its arity in packages/d2engine/callbacks.zig.");
            say("d2host:   Returning is not possible without it: the stack cannot be balanced.");
            ExitProcess(3);
            return 0;
        }
        const ptr: *const anyopaque = @ptrCast(&fastcall.Callback2(0, impl).shim);
    };
}

fn Stub(comptime name: []const u8, comptime n_stack: usize) type {
    return struct {
        fn impl(ecx: usize, edx: usize, ...) callconv(.c) usize {
            _ = edx;
            say("d2host: engine called " ++ name);
            _ = ecx;
            return 0;
        }
        const ptr: *const anyopaque = @ptrCast(&fastcall.Callback2(n_stack, impl).shim);
    };
}

/// The four QServer callbacks Fog takes. Same reporting shape as `Stub`, kept separate so the
/// network side is obvious in the log when a client eventually connects.
fn QStub(comptime name: []const u8, comptime n_stack: usize) type {
    return struct {
        fn impl(ecx: usize, edx: usize, ...) callconv(.c) usize {
            _ = ecx;
            _ = edx;
            say("d2host: qserver called " ++ name);
            return 0;
        }
        const ptr: *const anyopaque = @ptrCast(&fastcall.Callback2(n_stack, impl).shim);
    };
}

/// cdecl varargs, not fastcall — the engine's own logger, and the only channel through which it
/// explains itself. Formatting it rather than counting the calls is the difference between "the
/// join failed" and knowing which check refused it.
fn serverLogMessage(level: i32, fmt: [*:0]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var buf: [512]u8 = undefined;
    sayFmt("engine[{d}]: {s}", .{ level, cformat(&buf, fmt, &ap) });
}

/// Enough of C's `%` vocabulary to read the engine's own messages. An unknown directive is emitted
/// verbatim, so a message we cannot fully format is still legible rather than lost.
fn cformat(buf: []u8, fmt: [*:0]const u8, ap: anytype) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (fmt[i] != 0 and n < buf.len) {
        if (fmt[i] != '%') {
            buf[n] = fmt[i];
            n += 1;
            i += 1;
            continue;
        }
        i += 1;
        while (fmt[i] != 0 and (fmt[i] == '-' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '#' or
            fmt[i] == '.' or fmt[i] == 'l' or fmt[i] == 'h' or (fmt[i] >= '0' and fmt[i] <= '9'))) i += 1;
        const rest = buf[n..];
        switch (fmt[i]) {
            0 => break,
            's' => {
                const p = @cVaArg(ap, ?[*:0]const u8);
                const v = if (p) |q| std.mem.sliceTo(q, 0) else "(null)";
                n += (std.fmt.bufPrint(rest, "{s}", .{v}) catch break).len;
            },
            'd', 'i' => n += (std.fmt.bufPrint(rest, "{d}", .{@cVaArg(ap, i32)}) catch break).len,
            'u' => n += (std.fmt.bufPrint(rest, "{d}", .{@cVaArg(ap, u32)}) catch break).len,
            'x' => n += (std.fmt.bufPrint(rest, "{x}", .{@cVaArg(ap, u32)}) catch break).len,
            'X' => n += (std.fmt.bufPrint(rest, "{X}", .{@cVaArg(ap, u32)}) catch break).len,
            'c' => n += (std.fmt.bufPrint(rest, "{c}", .{@as(u8, @truncate(@cVaArg(ap, u32)))}) catch break).len,
            else => |c| {
                buf[n] = c;
                n += 1;
            },
        }
        i += 1;
    }
    return buf[0..n];
}

/// stdcall, one arg.
fn loadComplete(a: i32) callconv(.winapi) i32 {
    _ = a;
    say("d2host: engine called pfLoadComplete");
    return 0;
}

/// How long a realm event lives, and how many may queue. Same figures the 1.14d server publishes
/// with, because both feed the one drain loop in realmd.
const event_cap: u32 = 4096;
const event_ttl_s: u32 = 3600;

/// Slot 0x00, the end of a game. Every measured version passes the game id in ECX — 1.09's
/// `CloseGame(wGameId)` takes nothing else at all, and the builds that push two more stack
/// arguments still lead with it — so the handler names no stack argument and the shim cleans up
/// whatever that version's count is.
///
/// This has to reach the realm. `removeGameById` and `releaseGameChars` both sit on realmd's side
/// of a CLOSEGAME, so while this only reported, a finished game stayed in the join list forever and
/// every character in it stayed claimed. That surfaces three moves later and reads as three
/// separate bugs: `create game '<name>' -> name already exists`, `character '<name>' is held by
/// game:N`, and a join refused 0x2b "game is full" with nobody in it.
fn closeGame(ecx: usize, edx: usize) callconv(.c) usize {
    _ = edx;
    const gid: u32 = @truncate(ecx);
    sayFmt("d2host: pfCloseGame — game {d} ended", .{gid});
    if (live_games > 0) live_games -= 1;
    if (realmConfigured() and gid != 0) {
        var c = std.mem.zeroes(proto.CloseGame);
        c.h = proto.header(.closegame, @sizeOf(proto.CloseGame), 0);
        c.gameid = gid;
        _ = store.pushEvent(std.mem.asBytes(&c), event_cap, event_ttl_s);
    }
    return 0;
}

/// Slot 0x54, `__fastcall(FILETIME *out)` — the one appended slot 1.13c and 1.14d call, and neither
/// guards it: the only thing in front of the dispatch is the "callbacks installed" flag.
///
/// The engine asks the realm for the timestamp of the character's stored save and compares it with
/// the stamp inside the save the client just uploaded (`SrvVerifyJoinGame` @0x6fd0baf0, then
/// `CompareFileTime` against the delivered data at +0x190) — so a client cannot hand back an older
/// copy of its own character. The realm keeps no per-save timestamp, so the honest answer is a zero
/// FILETIME: nothing on record, and every delivered save is at least as new as that.
fn getDatabaseFileTime(ecx: usize, edx: usize) callconv(.c) usize {
    _ = edx;
    if (ecx != 0) {
        const out: *[2]u32 = @ptrFromInt(ecx);
        out.* = .{ 0, 0 };
    }
    return 0;
}

/// MUST outlive every call into D2Game: SetServerCallbackFunctions stores this pointer rather than
/// copying the struct (verified at 1.10f 0x6FC358E0), so a stack temporary would dangle.
var callbacks: EngineTable = undefined;

/// The game-data table is not an opaque buffer — it is a host-owned object D2Game reaches into by
/// fixed offset, and Blizzard's own host built it with a C++ constructor. In 1.00's `D2Server.dll`
/// the two structures are statics 0x70 apart, and the ctor @0x1000A240 sets `[+0x24] = 3` and
/// points `[+0x1c]` at four 12-byte slots.
///
/// 1.10f's `GAME_CreateNewEmptyGame` shows how they are used (@0x6fc3b590):
/// `edx = [+0x24] & counter; entry = [+0x1c] + edx*12` — so **`+0x24` is a power-of-two mask**,
/// not a capacity, and `+0x1c` is its slot array. A zeroed buffer means a null array and mask 0,
/// which segfaults on the first game. The mask is also range-checked against 0x3FF, so it has to
/// stay below that.
const token_slots = 512;
const GameToken = extern struct { a: u32 = 0, b: u32 = 0, c: u32 = 0 };

comptime {
    std.debug.assert(@sizeOf(GameToken) == 12); // the engine's own stride: edx*12
    std.debug.assert(token_slots - 1 < 0x3FF); // the mask is rejected at or above this
}

var game_tokens: [token_slots]GameToken align(16) = @splat(.{});

/// Field offsets in the game-data table, named for what the engine does with them.
const gdt = struct {
    const vtable = 0x00; // -> GameDataVTable; the engine calls slot +0x04 to allocate a record
    const arena = 0x04; // record = [arena] + <slot1's return>; zero here makes that the pointer
    const list_head = 0x08; // intrusive list head, always a valid node (see linkRecord below)
    const counter = 0x10; // decremented in threes, floored at zero
    const slots = 0x1c; // -> game_tokens
    const mask = 0x24; // token_slots - 1
    const lock = 0x50; // CRITICAL_SECTION, the host's to initialise
};

/// The interface D2Game invokes on the game-data table. Four methods; the fifth entry in
/// Blizzard's is null, which is what bounds it. Arities are the `RET n` of D2Server's own
/// implementations — `__thiscall`, so `this` arrives in ECX and the callee pops the stack args.
const GameDataVTable = extern struct {
    destroy: *const anyopaque, // +0x00  (this, flags)      ret 4   — scalar deleting destructor
    alloc_record: *const anyopaque, // +0x04  (this, slot*, a, b) ret 0xc — the only one game creation uses
    release: *const anyopaque, // +0x08  (this, flags)      ret 4
    reset: *const anyopaque, // +0x0C  (this)             ret 0
    terminator: ?*const anyopaque = null,
};

/// One per-game record — and it is the engine's **game object**, not a handle to one. That is easy
/// to under-size: the engine writes `[rec]`, `[rec+4]` and `[rec+0x14]` early, then treats the same
/// allocation as a full game, with its CRITICAL_SECTION at +0x18, its client list at +0x88 and
/// flags at +0xA8 (`D2GAME_UpdateAllClients` @0x6fc389c0). A 0x40-byte record let all of that land
/// in the next record and halted the engine with "This should never happen! [sUpdateClients]".
///
/// The vtable is not told the size — it arrives as `(slot, 0, 0)`, because in Blizzard's host this
/// is a template that knows its element type — so this is deliberately generous rather than
/// measured. Pinning the true size is worth doing; guessing it small is not.
const GameRecord = extern struct { bytes: [0x8000]u8 align(16) = @splat(0) };

/// Well past the seven games a single engine has memory pools for.
var game_records: [64]GameRecord = @splat(.{});
var records_used: usize = 0;

/// `[this+8]` is dereferenced as a node on every insert (`edx = [esi+8]; edi = [edx+4]`), including
/// the very first, so it can never be null. This is the sentinel it starts as.
var list_sentinel: [4]usize align(4) = @splat(0);

var vtable: GameDataVTable = undefined;

/// Byte offset within a record of the chain link this host maintains. The engine writes
/// `record[0]` (the game id) and `record[1]` and `record[0x14]` itself, so the link has to live
/// clear of those — and it can, because the *engine reads the offset out of the slot* rather than
/// assuming one.
const record_link_offset = 0x20;

/// vtable +0x04. `__thiscall (this /*ECX*/, slot* /*the hash bucket*/, int, int) -> void*`.
///
/// Two jobs, and the second one is easy to miss. The engine takes the result as the new game's
/// record and links it into `[this+8]`, so returning null trips its assert. But it also expects
/// **the bucket to be populated by us**: `D2GameDataTable_Ptr` @0x6fc3b6a0 looks a game up as
///
///     slot = this[0x1c] + (gameId & this[0x24]) * 12
///     rec  = *(slot + 8);  while (rec > 0) { if (*rec == gameId) return rec;
///                                            rec = *(rec + *(slot + 0) + 4) }
///
/// so `slot+8` is the bucket head and `slot+0` is the byte offset of the chain link inside a
/// record. Leaving the bucket empty makes every lookup miss, which surfaces much later and much
/// less helpfully as `SrvJoinGame: *** Failed to lock game N ***`.
fn allocRecord(_: usize, _: usize, slot: usize, a: usize, b: usize) callconv(.c) usize {
    // The size is not passed — `(slot, 0, 0)` — because in Blizzard's host this is a template
    // that knows its element type. Recorded once so the next person does not go looking for it.
    if (!alloc_logged) {
        alloc_logged = true;
        sayFmt("d2host: alloc_record(slot=0x{x}, a=0x{x}, b=0x{x})", .{ slot, a, b });
    }
    if (records_used >= game_records.len) {
        say("d2host: game-data records exhausted");
        return 0;
    }
    const rec = &game_records[records_used];
    records_used += 1;
    rec.* = .{};

    // Chain onto whatever this bucket already held, so two games that hash together both stay
    // findable. The link offset is ours to choose because the engine reads it back from the slot.
    if (slot != 0) {
        const bucket: [*]usize = @ptrFromInt(slot);
        const link: *usize = @ptrFromInt(@intFromPtr(rec) + record_link_offset + 4);
        link.* = bucket[2];
        bucket[0] = record_link_offset;
        bucket[2] = @intFromPtr(rec);
    }
    return @intFromPtr(rec);
}

fn gdtDestroy(_: usize, _: usize, _: usize) callconv(.c) usize {
    say("d2host: game-data table destroy");
    return 0;
}

fn gdtRelease(_: usize, _: usize, _: usize) callconv(.c) usize {
    say("d2host: game-data table release");
    return 0;
}

fn gdtReset(_: usize, _: usize) callconv(.c) usize {
    say("d2host: game-data table reset");
    return 0;
}

var game_data_table: [64 * 1024]u8 align(16) = @splat(0);
var game_list: [64 * 1024]u8 align(16) = @splat(0);

fn field(comptime T: type, offset: usize) *T {
    return @ptrCast(@alignCast(&game_data_table[offset]));
}

/// Put the table into the state D2Game expects before it is handed over. The engine treats it as a
/// live object from the first game creation onward, so every field it reads has to mean something
/// by then — there is no second chance to fill this in.
fn buildGameDataTable() void {
    // __thiscall is __stdcall with `this` in ECX, so the fastcall shims fit: they pop the same
    // stack args and simply pass an EDX the handlers ignore.
    vtable = .{
        .destroy = @ptrCast(&fastcall.Callback2(1, gdtDestroy).shim),
        .alloc_record = @ptrCast(&fastcall.Callback2(3, allocRecord).shim),
        .release = @ptrCast(&fastcall.Callback2(1, gdtRelease).shim),
        .reset = @ptrCast(&fastcall.Callback2(0, gdtReset).shim),
    };

    field(usize, gdt.vtable).* = @intFromPtr(&vtable);
    field(usize, gdt.arena).* = 0;
    field(usize, gdt.list_head).* = @intFromPtr(&list_sentinel);
    field(u32, gdt.counter).* = 0;
    field(usize, gdt.slots).* = @intFromPtr(&game_tokens);
    field(u32, gdt.mask).* = token_slots - 1;
    InitializeCriticalSection(@ptrCast(&game_data_table[gdt.lock]));
    sayHex("d2host: game-data table built, vtable at ", @intFromPtr(&vtable));
}

const Module = struct { name: [*:0]const u8, handle: ?HMODULE = null };

/// Which modules load, and in what order — sourced from `d2version.spec(version).modules` rather
/// than a literal, so the module set is exactly as version-agnostic as everything else here.
/// Presently that spec is the same list for every DLL-era version (see `version.zig`), but the
/// point is that a future version whose set genuinely differs needs a data change there, not a
/// second copy of this loop.
///
/// Load order matters twice over. Initialisation order — allocator and archives before the data
/// tables that use them, game logic last — is the obvious one.
///
/// The other is base addresses, and 1.10f's own layout is self-conflicting: D2Game
/// `0x6FC30000+0x127000` overruns D2Common's `0x6FD40000` by 92 KB (D2Game grew 160 KB in 1.10), and
/// D2Common in turn overruns D2CMP's `0x6FDF0000` by 16 KB. Whoever loads first keeps its link
/// address; the loser is relocated, so **D2Game and D2Common can never both sit at theirs**.
///
/// This order is the cheapest arrangement, measured: D2Game keeps `0x6FC30000` and only D2Common
/// moves. Loading D2Common first instead costs two relocations (D2CMP *and* D2Game). Either way,
/// resolve everything by ordinal — RVAs hold across relocation, absolute addresses do not.
fn loadModules(comptime module_names: []const [:0]const u8) ![module_names.len]Module {
    var modules: [module_names.len]Module = undefined;
    inline for (module_names, 0..) |name, i| {
        modules[i] = .{ .name = name };
        modules[i].handle = LoadLibraryA(name);
        if (modules[i].handle == null) {
            say("d2host: FAILED to load a module: " ++ name);
            sayHex("d2host:   err=", GetLastError());
            return error.LoadLibraryFailed;
        }
        sayHex("d2host: loaded " ++ name ++ ", base=", @intFromPtr(modules[i].handle.?));
    }
    return modules;
}

fn moduleHandle(modules: []const Module, name: []const u8) ?HMODULE {
    for (modules) |m| {
        if (std.mem.eql(u8, std.mem.sliceTo(m.name, 0), name)) return m.handle;
    }
    return null;
}

/// Whether a version has everything `run`/`Binding` need to actually build and drive it: every
/// required callback slot counted, and the client-struct field offsets known. This is the gate
/// that turns "1.09d isn't finished yet" from a fact someone has to remember into something the
/// program checks and refuses to violate — a version can be *selected* long before it is *ready*,
/// and the two are meant to be handled differently: selecting an unknown version is a usage
/// mistake (reject early), selecting a known-but-incomplete one is expected, ongoing work (reject
/// clearly, naming exactly what is missing, not a build failure three files away).
/// Whether `v` can serve games: every arity counted AND a measured client layout.
fn ready(comptime v: d2version.Version) bool {
    return cb.isComplete(d2version.spec(v).stack_args) and hostapi.charNameSource(v) != null;
}

/// Whether `v` can be booted just far enough to measure what it is still missing. Arities have to
/// be counted either way — those are what keep the engine's stack balanced — but the client layout
/// is exactly what such a run is for, so it is not required.
fn probeable(comptime v: d2version.Version) bool {
    return cb.isComplete(d2version.spec(v).stack_args);
}

/// `D2GS_ENGINE_VERSION` picks which build this process drives, the same way `D2GS_REDIS_ADDR`
/// picks the store — a run-time knob, not a source edit. Defaults to 1.10f, the only version
/// `ready()` currently accepts; naming an unready or unknown one is reported by `main`, not here.
fn envFlag(comptime name: [:0]const u8) bool {
    var buf: [16]u8 = undefined;
    const v = env(name, &buf) orelse return false;
    return !std.mem.eql(u8, v, "0");
}

fn resolveVersion() d2version.Version {
    var buf: [32]u8 = undefined;
    const requested = env("D2GS_ENGINE_VERSION", &buf) orelse return .v110f;
    return d2version.Version.parse(requested) orelse {
        sayFmt("d2host: D2GS_ENGINE_VERSION='{s}' not a known version, defaulting to 1.10f", .{requested});
        return .v110f;
    };
}

// x86 CONTEXT, far enough in to reach the integer registers. The engine faults inside Blizzard
// code with no symbols, so the useful fact is never the fault address — it is the return address
// the CALL pushed, which names the instruction that dispatched through a null.
const ExceptionRecord = extern struct {
    code: u32,
    flags: u32,
    next: ?*ExceptionRecord,
    address: usize,
    n_params: u32,
    params: [15]usize,
};

const Context = extern struct {
    flags: u32,
    dr: [6]u32,
    float: [112]u8,
    seg_gs: u32,
    seg_fs: u32,
    seg_es: u32,
    seg_ds: u32,
    edi: u32,
    esi: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    ebp: u32,
    eip: u32,
    seg_cs: u32,
    eflags: u32,
    esp: u32,
    seg_ss: u32,
};

const ExceptionPointers = extern struct {
    record: *ExceptionRecord,
    context: *Context,
};

/// Report a fault with the one thing a post-mortem register dump cannot give: who called.
/// A `CALL` through a null pointer leaves EIP at 0 and the caller's return address at [ESP], so
/// reading the top of the stack turns "it crashed somewhere in D2Common" into an address that maps
/// straight onto the disassembly.
fn onException(info: *ExceptionPointers) callconv(.winapi) i32 {
    const rec = info.record;
    if (rec.code != 0xC0000005) return 0; // EXCEPTION_CONTINUE_SEARCH
    const c = info.context;
    sayFmt("d2host: ACCESS VIOLATION eip=0x{x} esp=0x{x}", .{ c.eip, c.esp });
    sayFmt("d2host:   eax=0x{x} ebx=0x{x} ecx=0x{x} edx=0x{x} esi=0x{x} edi=0x{x} ebp=0x{x}", .{
        c.eax, c.ebx, c.ecx, c.edx, c.esi, c.edi, c.ebp,
    });
    // Only meaningful when EIP is null: then nothing has run in the callee, so [ESP] is exactly
    // the return address the CALL pushed.
    const stack: [*]const u32 = @ptrFromInt(c.esp);
    for (0..6) |i| sayFmt("d2host:   [esp+0x{x}] = 0x{x}", .{ i * 4, stack[i] });
    // What is actually executing. When EIP lands inside the stack the bytes are not code at all,
    // and seeing them says which data got jumped into — the register dump alone cannot.
    //
    // Not for a null EIP: reading around address 0 faults inside the handler and takes the rest of
    // the report with it — which is how the one fault that says most about its cause (a CALL through
    // a null slot) used to be the one that reported least.
    if (c.eip >= 0x10000) {
        const code: [*]const u8 = @ptrFromInt(c.eip -% 8);
        var buf: [96]u8 = undefined;
        var n: usize = 0;
        for (0..24) |i| {
            const b = code[i];
            const hex = "0123456789abcdef";
            buf[n] = hex[b >> 4];
            buf[n + 1] = hex[b & 15];
            buf[n + 2] = if (i == 7) '|' else ' ';
            n += 3;
        }
        sayFmt("d2host:   bytes at eip-8: {s}", .{buf[0..n]});
    } else {
        sayFmt("d2host:   EIP is not code — a CALL through a null pointer. The caller is [esp+0x0].", .{});
    }
    return 0;
}

pub fn main() !void {
    _ = AllocConsole();
    out_handle = GetStdHandle(@bitCast(@as(i32, -11))); // STD_OUTPUT_HANDLE
    _ = AddVectoredExceptionHandler(1, &onException);
    say("d2host: start");

    const install_dir = firstArg();

    // Built for one engine: the version is a constant, so `ready()` is checked by the compiler and
    // an unfinished version cannot produce a binary at all. `D2GS_ENGINE_VERSION` is refused
    // rather than ignored — an image tagged for one engine quietly serving another is exactly the
    // failure a per-version tag exists to prevent.
    if (comptime build_options.engine_version) |pinned| {
        const v = comptime d2version.Version.parse(pinned) orelse
            @compileError("-Dengine-version=" ++ pinned ++ " is not a known version");
        comptime {
            if (!ready(v)) @compileError("-Dengine-version=" ++ pinned ++ " is not ready to serve: " ++
                "missing " ++ cb.missingSlots(d2version.spec(v).stack_args) ++
                " (and/or no measured client layout) — see docs/dll-host.md");
        }
        var buf: [32]u8 = undefined;
        if (env("D2GS_ENGINE_VERSION", &buf)) |asked| {
            if (d2version.Version.parse(asked) != v) {
                sayFmt("d2host: built for {s}; refusing D2GS_ENGINE_VERSION='{s}'", .{ @tagName(v), asked });
                return error.WrongEngineForThisBuild;
            }
        }
        sayFmt("d2host: targeting {s} (pinned at build time)", .{@tagName(v)});
        return run(v, install_dir);
    }

    const requested = resolveVersion();

    // `inline else` monomorphizes this switch's body once per `d2version.Version` enum value, with
    // `v` comptime-known inside each generated copy — which is what lets `ready(v)` and
    // `run(v, ...)` below be ordinary compile-time-checked calls even though `requested` itself is
    // only known at runtime. The version genuinely is "just a suggestion" in the sense that asked:
    // the SAME binary carries every measured version's code, and a flag picks among them.
    switch (requested) {
        inline else => |v| {
            if (comptime !ready(v)) {
                // A version with every arity counted but no client layout is not broken, it is
                // half-measured — and the run that measures the rest is a run of this binary. That
                // is what D2GS_ENGINE_PROBE asks for, and it is opt-in so nobody gets a server that
                // silently refuses every join.
                if (comptime probeable(v)) {
                    if (envFlag("D2GS_ENGINE_PROBE")) {
                        sayFmt("d2host: {s} PROBE — arities counted, client layout not; " ++
                            "booting to dump it on the first character fetch", .{@tagName(v)});
                        return run(v, install_dir);
                    }
                    sayFmt("d2host: {s} has every arity counted but no client layout — " ++
                        "set D2GS_ENGINE_PROBE=1 to boot and measure it", .{@tagName(v)});
                    return error.VersionNotReady;
                }
                sayFmt("d2host: {s} is not ready yet — missing: {s}", .{
                    @tagName(v),
                    comptime cb.missingSlots(d2version.spec(v).stack_args),
                });
                return error.VersionNotReady;
            }
            sayFmt("d2host: targeting {s}", .{@tagName(v)});
            try run(v, install_dir);
            say("d2host: run returned cleanly, process exiting");
            return;
        },
    }
}

/// The whole bring-up and tick loop, generic over `version`. Selecting a different (measured)
/// version means the *caller* picks a different `version` to instantiate this with — nothing in
/// here is 1.10f-specific by name; every fact that differs between engine builds already lives in
/// `d2version`/`d2engine.hostapi`/`Binding`, and this function just consumes whichever version's
/// data it was handed.
fn run(comptime version: d2version.Version, install_dir: ?[*:0]const u8) !void {
    const spec = comptime d2version.spec(version);

    if (install_dir) |dir| {
        if (SetCurrentDirectoryA(dir) == 0) {
            sayHex("d2host: SetCurrentDirectory failed, err=", GetLastError());
        } else {
            say("d2host: cwd set");
        }
    }

    var modules = try loadModules(spec.modules);
    say("d2host: all modules loaded");

    // Fog is stdcall and two builds disagree about what some of its entry points take, so it has
    // to be told which engine it is standing in for before anything calls it. Nothing does during
    // LoadLibrary, so here is early enough — and it must be before the D2Lang/D2Common init below,
    // whose table loading is exactly what the drift destroys.
    // The transport has the same problem for the same reason: the C->S size table and the join
    // opcode are per-version, and framing with the wrong table desynchronises on the first packet.
    if (moduleHandle(&modules, "D2Net.dll")) |net| {
        if (GetProcAddress(net, "D2NET_SetEngineVersion")) |p| {
            const set: *const fn (u32) callconv(.c) i32 = @ptrCast(@alignCast(p));
            if (set(@intFromEnum(version)) == 0)
                sayFmt("d2host: D2Net kept its default framing for {s}", .{@tagName(version)});
        }
    }

    if (envFlag("D2FOG_DUMP_FIELDS")) {
        if (moduleHandle(&modules, "Fog.dll")) |fog| {
            if (GetProcAddress(fog, "FOG_DumpFields")) |p| {
                const f: *const fn (u32) callconv(.c) void = @ptrCast(@alignCast(p));
                f(1);
                say("d2host: Fog will describe each table's column layout");
            }
        }
    }

    if (moduleHandle(&modules, "Fog.dll")) |fog| {
        if (GetProcAddress(fog, "FOG_SetEngineVersion")) |p| {
            const set: *const fn (u32) callconv(.c) i32 = @ptrCast(@alignCast(p));
            if (set(@intFromEnum(version)) == 0)
                sayFmt("d2host: Fog kept its default ABI for {s}", .{@tagName(version)});
        } else say("d2host: Fog has no FOG_SetEngineVersion — using its built-in ABI");
    }

    const d2game = modules[modules.len - 1].handle.?;
    const d2common = moduleHandle(&modules, "D2Common.dll").?;
    const d2lang = moduleHandle(&modules, "D2Lang.dll").?;
    const d2net = moduleHandle(&modules, "D2Net.dll").?;

    // Every one of these comes from the version spec. They were literals, and 1.13c is the build
    // that proves why: it renumbered its whole export table, so 10002 there is the client flush
    // and 10023 a bare `ret 4`. Calling those with this one's arguments faults on the first
    // instruction, which looks like a bad pointer rather than the wrong function.
    const game_ord = comptime d2version.spec(version).game;
    const init_table = byOrdinal(d2game, game_ord.init_game_data_table) orelse {
        say("d2host: D2Game init_game_data_table missing");
        return error.MissingOrdinal;
    };
    const set_callbacks = byOrdinal(d2game, game_ord.set_server_callbacks) orelse {
        say("d2host: D2Game set_server_callbacks missing");
        return error.MissingOrdinal;
    };
    sayHex("d2host: GAME_InitGameDataTable=", @intFromPtr(init_table));
    sayHex("d2host: GAME_SetServerCallbackFunctions=", @intFromPtr(set_callbacks));

    // Everything version-specific about the table — every slot's arity, and the two real
    // implementations' internals — lives in `Binding(version)`. `run` is generic, so this line is
    // the same regardless of which version the current instantiation is for.
    callbacks = .{
        .base = Binding(version).buildCallbackTable(),
        .ext = Binding(version).buildCallbackTail(),
    };
    say("d2host: callback table built");

    // Blizzard's own host (`D2Server.dll`, WinMain @0x10009EA0) defines the minimal init, and this
    // follows it. Two of its steps are deliberately absent: `FOG_10139` and `FOG_InitErrorMgr` are
    // Fog's HOST-facing API, and since we ship Fog ourselves there is nothing to initialise — our
    // Fog is ready on load. Likewise `LoadMPQArchives`: archives are our Fog's business, behind its
    // file ordinals. Everything below is the engine-facing part, in Blizzard's order.

    // D2Lang @10000, the string-table init, exactly where D2Server calls it. D2Lang's exports look
    // like nothing but `Unicode::` methods because the export NAME table is alphabetical while the
    // ordinal table is not: 10000-10013 are the NONAME C API and 10014+ are the named C++ ones.
    // It is __fastcall(hArchive, szLanguage, bExpansion), which is why calling it as stdcall faulted.
    // Skipping it leaves sghStringTable null and D2Common's charstats load asserts in strtable.cpp.
    if (byOrdinal(d2lang, comptime d2version.spec(version).lang.strtable_init)) |p| {
        say("d2host: calling D2Lang STRTABLE_Init");
        // Classic takes the two register arguments and nothing else. Pushing `bExpansion` at a
        // build that ends `ret 0` strands it: ESP is left four bytes low and the fault surfaces on
        // the next aligned SSE spill in OUR code, nowhere near a string table.
        const r = if (comptime d2version.spec(version).lang.strtable_init_takes_expansion) blk: {
            const Init = fn (u32, [*:0]const u8, u32) callconv(.c) u32;
            break :blk fastcall.fastcallAt(Init).call(@intFromPtr(p), .{ 0, "ENG", 1 });
        } else blk: {
            const Init = fn (u32, [*:0]const u8) callconv(.c) u32;
            break :blk fastcall.fastcallAt(Init).call(@intFromPtr(p), .{ 0, "ENG" });
        };
        sayHex("d2host: D2Lang init returned=", r);
    } else say("d2host: D2Lang @10000 missing");

    // Compile the tables instead of consuming them. D2Common @11242 sets the flag CompileTxt reads
    // at its top: with it on, the loader reads the `.txt`, decodes it through FOG @10207, and
    // WRITES the `.bin` back out — which is how a version whose compiled tables nobody shipped
    // gets them. The argument is inverted (`flag = (arg == 0)`), so zero turns compilation on.
    //
    // Opt-in, because it is a build step wearing a server's clothes: it wants `data/global/excel/`
    // to exist in the working directory and it rewrites tables there.
    if (envFlag("D2GS_COMPILE_TABLES")) {
        if (comptime spec.common.set_compile_tables) |ord| if (byOrdinal(d2common, ord)) |p| {
            const set_compile: *const fn (u32) callconv(.winapi) void = @ptrCast(@alignCast(p));
            set_compile(0);
            say("d2host: table COMPILE mode on — .txt in, .bin out");
        } else say("d2host: the compile-tables setter is missing — cannot enable it")
        else say("d2host: this engine has no compile-tables setter (it reads .txt directly)");
    }

    // DATATBLS_LoadAllTxts(a, lang, flags) — D2Server passes (0, 1, 0). The ordinal is per version:
    // classic renumbered D2Common, and 1.06b's @10576 is an unrelated bounds check that returns
    // without loading anything.
    if (byOrdinal(d2common, spec.common.load_all_txts)) |p| {
        sayFmt("d2host: calling D2Common @{d} (DATATBLS_LoadAllTxts)", .{spec.common.load_all_txts});
        @as(*const fn (u32, u32, u32) callconv(.winapi) void, @ptrCast(@alignCast(p)))(0, 1, 0);
        say("d2host: DATATBLS_LoadAllTxts returned");
    } else say("d2host: the table loader ordinal is missing");

    configureRealm();

    // Ours, by name: tell the transport where to listen before it binds. Not an ordinal, because
    // it is not part of the D2Net ABI the engine imports.
    connected_clients_fn = @ptrCast(@alignCast(GetProcAddress(d2net, "D2NET_ConnectedClients")));

    // A 1.14d client is the only pre-1.14-compatible client that runs here without the disc, so
    // allow it to join by translating its one incompatible packet. D2HOST_ACCEPT_114D_CLIENT=0
    // turns it off for a genuine same-version client.
    if (GetProcAddress(d2net, "D2NET_SetTranslate114dJoin")) |p| {
        var b: [8]u8 = undefined;
        const on: u32 = if (env("D2HOST_ACCEPT_114D_CLIENT", &b)) |v| @intFromBool(!std.mem.eql(u8, v, "0")) else 1;
        @as(*const fn (u32) callconv(.winapi) void, @ptrCast(@alignCast(p)))(on);
        if (on != 0) say("d2host: accepting 1.14d clients (join packet translated)");
    }
    if (GetProcAddress(d2net, "D2NET_SetListenPort")) |p| {
        const port = public_port;
        @as(*const fn (u16) callconv(.winapi) void, @ptrCast(@alignCast(p)))(port);
        sayHex("d2host: listen port set to ", port);
    }

    // D2Net: server up, client cap, hack list — the same three D2Server makes.
    const net_ord = comptime d2version.spec(version).net;
    if (byOrdinal(d2net, net_ord.initialize)) |p| {
        say("d2host: calling D2Net @10003 (SERVER_Initialize)");
        _ = @as(*const fn (u32, u32) callconv(.winapi) i32, @ptrCast(@alignCast(p)))(0, 0);
    }
    if (byOrdinal(d2net, net_ord.set_max_clients)) |p| {
        _ = @as(*const fn (u32) callconv(.winapi) i32, @ptrCast(@alignCast(p)))(8);
        say("d2host: D2Net SetMaxClientsPerGame(8)");
    }
    if (byOrdinal(d2net, net_ord.set_hacklist)) |p| {
        _ = @as(*const fn (u32) callconv(.winapi) i32, @ptrCast(@alignCast(p)))(1);
        say("d2host: D2Net SetHackListEnabled(1)");
    }

    // Two orders exist, and the version decides. On 1.07 through 1.10f the module init must come
    // FIRST: it runs InitializeCriticalSection on the game-list lock, and skipping it leaves the
    // first game-list operation blocked forever on an uninitialised section — wine says it plainly,
    // "RtlpWaitForCriticalSection section 6FD45800 blocked by 0000". It also clears the 0x400-entry
    // game array, initialises the client table, installs D2Game's Fog error handler and fills the
    // item cache.
    //
    // 1.13c wants the opposite, and that is not a guess: Marsgod's working 1.13c D2Server.dll
    // registers the callback table and the game-data table and only THEN calls the module init.
    // Doing it our way there faults inside the init itself.
    const init_last = comptime version == .v113c;

    const InitModule = *const fn () callconv(.winapi) i32;
    const SetFn = *const fn (*anyopaque) callconv(.winapi) void;
    const InitFn = *const fn (*anyopaque, *anyopaque) callconv(.winapi) void;
    const init_module = byOrdinal(d2game, game_ord.init_server_module) orelse {
        say("d2host: init_server_module missing — the game-list lock will never be initialised");
        return error.MissingOrdinal;
    };

    if (!init_last) {
        say("d2host: calling GAME_InitServerModule");
        sayHex("d2host: GAME_InitServerModule returned=", @intCast(@as(InitModule, @ptrCast(@alignCast(init_module)))()));
    }

    // GAME_SetServerCallbackFunctions(pTable) — stdcall, stores the pointer (does not copy).
    say("d2host: calling GAME_SetServerCallbackFunctions");
    @as(SetFn, @ptrCast(@alignCast(set_callbacks)))(@ptrCast(&callbacks));
    say("d2host: GAME_SetServerCallbackFunctions returned");

    // GAME_InitGameDataTable(ptGameDataTbl, phGameList) — stdcall, both asserted non-null.
    buildGameDataTable();
    say("d2host: calling GAME_InitGameDataTable");
    @as(InitFn, @ptrCast(@alignCast(init_table)))(@ptrCast(&game_data_table), @ptrCast(&game_list));
    say("d2host: GAME_InitGameDataTable returned");
    sayHex("d2host: esp after InitGameDataTable = ", espNow());

    if (init_last) {
        say("d2host: calling GAME_InitServerModule (after registration, 1.13c's order)");
        sayHex("d2host: GAME_InitServerModule returned=", @intCast(@as(InitModule, @ptrCast(@alignCast(init_module)))()));
    }

    say("d2host: init sequence survived");

    try createGame(version, d2game);
}

/// Try to stand a game up and tick it. Every call is announced before it happens, so a hard failure
/// names the step instead of just killing the process.
/// Roughly where our stack is. Only the TREND matters: two points at the same depth in our own
/// call tree must see the same value, so a baseline that walks between them is an engine call
/// whose callee popped a different amount than we pushed. That damage is invisible until some
/// unrelated function returns into the drift.
inline fn espNow() usize {
    return asm volatile (""
        : [ret] "={esp}" (-> usize),
    );
}

fn createGame(comptime version: d2version.Version, d2game: HMODULE) !void {
    const game_ord = comptime d2version.spec(version).game;
    // TASK_InitializeClock @10039 — the game clock the tick functions read.
    if (byOrdinal(d2game, game_ord.init_clock)) |p| {
        const InitClock = *const fn () callconv(.winapi) void;
        say("d2host: calling TASK_InitializeClock");
        @as(InitClock, @ptrCast(@alignCast(p)))();
        say("d2host: TASK_InitializeClock returned");
    } else say("d2host: ordinal 10039 (TASK_InitializeClock) missing");

    // GAME_SetInitSeed @10010 — fixes the world seed so a run is reproducible.
    if (byOrdinal(d2game, game_ord.set_init_seed)) |p| {
        const SetSeed = *const fn (i32) callconv(.winapi) void;
        say("d2host: calling GAME_SetInitSeed(1)");
        @as(SetSeed, @ptrCast(@alignCast(p)))(1);
        say("d2host: GAME_SetInitSeed returned");
    } else say("d2host: ordinal 10010 (GAME_SetInitSeed) missing");

    // GAME_CreateNewEmptyGame @10047 — stdcall, returns BOOL and writes the game id.
    const create = byOrdinal(d2game, game_ord.create_empty_game) orelse {
        say("d2host: ordinal 10047 (GAME_CreateNewEmptyGame) missing");
        return error.MissingOrdinal;
    };
    create_game = @ptrCast(@alignCast(create));

    // @10007 — the async half of fpGetDatabaseCharacter. Without it a fetched save has nowhere to
    // go and every join stalls, so say so at startup rather than at the first join.
    if (byOrdinal(d2game, hostapi.sendDatabaseCharacter(version).?.ordinal)) |p| {
        load_filetimes = .{ @truncate(@intFromPtr(&load_filetime)), 0 };
        if (comptime hostapi.sendDatabaseCharacterArgs(version) orelse 8 == 7) {
            send_character7 = @ptrCast(@alignCast(p));
            say("d2host: D2GSSendDatabaseCharacter @10007 resolved (7-argument form)");
        } else {
            send_character = @ptrCast(@alignCast(p));
            say("d2host: D2GSSendDatabaseCharacter @10007 resolved");
        }
    } else say("d2host: ordinal 10007 missing — characters cannot be delivered");

    // With a realm, games are made on request and creating one here would be a phantom the realm
    // does not know about. Without one, this is still the quickest proof the engine works.
    var ok: i32 = 1;
    if (!realmConfigured()) {
        var name: [32:0]u8 = @splat(0);
        @memcpy(name[0..5], "spike");
        var game_id: u16 = 0;
        say("d2host: no realm configured — creating one game directly");
        ok = create_game.?(&name, "", "d2host spike", gameflags.gameFlags(0, true, false), 0, 0, 8, &game_id);
        sayHex("d2host: GAME_CreateNewEmptyGame returned=", @intCast(ok));
        sayHex("d2host: esp after CreateNewEmptyGame = ", espNow());
        sayHex("d2host:   gameId=", game_id);
        if (ok != 0) live_games += 1;
    } else {
        sayHex("d2host: joined the realm as gsid ", gsid);
    }

    if (byOrdinal(d2game, 10012)) |p| {
        const Count = *const fn () callconv(.c) i32; // fastcall, no args — same as cdecl here
        const n = @as(Count, @ptrCast(@alignCast(p)))();
        sayHex("d2host: GAME_GetGamesCount=", @intCast(n));
    }

    if (ok == 0) {
        say("d2host: game creation refused — data tables are the likely gap");
        return;
    }

    // The tick is Blizzard's worker loop, argument for argument. Its shape is not guessable and
    // getting it wrong is what kept the engine's replies off the wire: it queues outbound packets
    // per client (`CLIENTS_PacketDataList_Append`) and only @10045 drains them to D2Net, so a tick
    // without it leaves a client joined and permanently silent.
    //
    // D2Server.dll @0x10009DE0:
    //     esi = @10041()                            acquire a worker context
    //     loop: @10043(ecx=esi, edx=&game)          process one game
    //           if (game) @10045(ecx=esi, edx=game) flush that game's clients
    //
    // Calling @10005 directly instead — it is the flush's inner half — halts the engine with
    // "This should never happen! [sUpdateClients]"; it is reached *through* @10045, and D2Server
    // does not import it at all.
    const netmsgs = byOrdinal(d2game, game_ord.net_messages);
    const worker_ctx_fn = byOrdinal(d2game, game_ord.worker_context);
    const process_game = byOrdinal(d2game, game_ord.process_game);
    const flush_game = byOrdinal(d2game, game_ord.flush_game);

    var worker_ctx: usize = 0;
    if (worker_ctx_fn) |p| {
        worker_ctx = @as(*const fn () callconv(.c) usize, @ptrCast(@alignCast(p)))();
        sayHex("d2host: worker context ", worker_ctx);
    } else say("d2host: ordinal 10041 missing — games cannot be processed");
    // Announced per call, not per frame: a tick that never returns is the failure mode here, and
    // only naming the call in flight distinguishes "hung in @10004" from "hung in @10005".
    // Long enough to connect to by hand. The transport polls inside the read path, so a frame is
    // also a network poll — there is no separate accept loop to run.
    gs_labels = "v=" ++ comptime d2version.spec(version).name;
    sayFmt("d2host: publishing labels [{s}]", .{gs_labels});
    say("d2host: ticking");
    var i: usize = 0;
    var last_beat: usize = 0;
    while (realmConfigured() or i < tick_frames) : (i += 1) {
        if (realmConfigured()) {
            pumpRealm();
            // ~5s at 50ms a frame. The record carries a 90s TTL, so missing a few beats under
            // load takes this server out of rotation rather than handing the realm a stale route.
            if (i - last_beat >= 100) {
                last_beat = i;
                _ = store.putHeartbeat(gsid, public_ip, public_port, max_games, live_games, live_games >= max_games, 90, gs_labels);
            }
        }
        if (netmsgs) |p| @as(*const fn () callconv(.c) void, @ptrCast(@alignCast(p)))();

        // Immediately after the network pump and BEFORE the game tasks run, because a join is
        // processed in the call above and the fetch it queues has to reach the engine within the
        // same frame. Left until the next one, `sSrvTaskProcessGame` gets there first, finds a game
        // whose only client has no player unit yet, and deletes it as empty -- so the delivery then
        // looks up a game that no longer exists, the lock returns null, and the engine reports
        // `SrvRecvDatabaseCharacter: *** Failed SrvLockGame ***` and drops the client.
        //
        // Still outside the callback, which is the thing that must not happen: delivering from
        // inside fpGetDatabaseCharacter would re-enter the engine's join continuation halfway
        // through its own join call. After the pump returns is late enough for that and early
        // enough for this.
        pumpCharacterLoads();

        // Drain every game the worker has ready, not just one per frame: at 50 ms a frame a
        // single game per tick is a hard cap on how fast anything reaches a client.
        if (process_game) |proc| {
            var spins: usize = 0;
            while (spins < 64) : (spins += 1) {
                // One word is enough: given 128 bytes of room and 1.06b driving it, the engine
                // wrote slot 0 and nothing else, so EDX really is a single out-parameter here.
                var game: usize = 0;
                _ = fastcall.fastcallAt(fn (usize, *usize) callconv(.c) usize)
                    .call(@intFromPtr(proc), .{ worker_ctx, &game });
                if (game == 0) break;
                if (!flush_logged) {
                    flush_logged = true;
                    sayHex("d2host: worker handed us a game at ", game);
                }
                // @10045 ends in D2GAME_UpdateAllClients, which *halts the process* unless the
                // game wants a client update: it calls ARENA_NeedsClientUpdate first and treats a
                // false there as "this should never happen". The condition is the engine's own —
                // `(*(u8*)(inner[0x1d28] + 8) >> 2) & 1`, where `inner` is `*(game+8)` — so we
                // test it rather than discover it as a crash.
                // @10045 is not optional and must not be conditional: besides flushing, it is
                // what RE-ARMS the task — `*task += 0x28; TASK_LinkList_Insert(...)`, due again in
                // 40 ms. @10043 has already unlinked it, so skipping the flush even once drops
                // that game out of the scheduler for good, which is what made the engine go quiet
                // after the first frame.
                if (flush_game) |flush| {
                    flushes += 1;
                    if (flushes % 500 == 1) sayFmt("d2host: processed {d} game frame(s)", .{flushes});
                    _ = fastcall.fastcallAt(fn (usize, usize) callconv(.c) usize)
                        .call(@intFromPtr(flush), .{ worker_ctx, game });
                }
            }
        }
        // 10 ms is the idle cadence a third-party host publishes as DEFAULT_IDLE_SLEEP, and
        // Blizzard's own worker loop is tighter still — it spins on a network wait rather than
        // sleeping. At 50 ms the engine's scheduler rarely had a game ready when we asked.
        Sleep(10);
    }
    say("d2host: tick loop finished");
    sayHex("d2host: esp after tick loop = ", espNow());
}

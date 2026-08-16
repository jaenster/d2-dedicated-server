//! Process-global chat-channel registry. BNCS connections that SID_JOINCHANNEL
//! register a Member here; talking/whispering broadcasts to other members in the
//! same channel. Broadcasts originate on arbitrary connection threads, so the
//! registry is guarded by a spinlock and each member has its own send_lock so a
//! slow/blocked peer can't tear a packet sent by another thread.
const std = @import("std");
const net = @import("realm_infra").net;
const Lock = @import("realm_infra").lock.Lock;

pub const max_name = 16;
pub const max_channel = 32;
pub const max_stat = 128; // SID_CHATEVENT statstring (the per-user char info D2 draws)
pub const max_status = 96; // /away and /dnd message length
pub const max_ignores = 32; // per-user squelch (/ignore) list size

pub const Member = struct {
    fd: net.Socket = -1,
    in_use: bool = false,
    name: [max_name]u8 = [_]u8{0} ** max_name,
    name_len: u8 = 0,
    channel: [max_channel]u8 = [_]u8{0} ** max_channel,
    channel_len: u8 = 0,
    /// The game they went off to play, if any. A player in a game is still connected to
    /// bnetd — whispers must reach them — but they are no longer in the channel, so
    /// channel talk must not. Set from SID_NOTIFYJOIN, cleared when they rejoin a channel.
    game: [max_channel]u8 = [_]u8{0} ** max_channel,
    game_len: u8 = 0,
    flags: u32 = 0, // SID_CHATEVENT user flags (operator/admin/...) for this user
    // The client's SID_ENTERCHAT statstring — for D2 it encodes the character
    // (name/class/level/gear) the channel user-list draws via
    // COMCALLBACK_FormatChannelUserData. Replayed in EID_SHOWUSER/EID_JOIN.
    stat: [max_stat]u8 = [_]u8{0} ** max_stat,
    stat_len: u8 = 0,
    // How this user is NAMED in chat events, as opposed to how they are looked up. The
    // 1.14d client splits a channel username on '*' — the part after it is the character
    // it draws, the part before is the clan (COMCALLBACK_FormatChannelUserData @0x4471b0).
    // A bare account name has no '*', so the client shows the account where the character
    // should be. `name` stays the account so whispers and /ignore keep working.
    display: [max_name]u8 = [_]u8{0} ** max_name,
    display_len: u8 = 0,
    // Social state, visible cross-connection (whisper auto-reply + message filtering).
    away: [max_status]u8 = [_]u8{0} ** max_status,
    away_len: u8 = 0, // 0 = not away
    dnd: [max_status]u8 = [_]u8{0} ** max_status,
    dnd_len: u8 = 0, // 0 = not in Do-Not-Disturb
    ignores: [max_ignores][max_name]u8 = [_][max_name]u8{[_]u8{0} ** max_name} ** max_ignores,
    ignore_lens: [max_ignores]u8 = [_]u8{0} ** max_ignores,
    ignore_count: u8 = 0,
    send_lock: Lock = .{},

    pub fn nameSlice(m: *const Member) []const u8 {
        return m.name[0..m.name_len];
    }
    pub fn channelSlice(m: *const Member) []const u8 {
        return m.channel[0..m.channel_len];
    }
    pub fn gameSlice(m: *const Member) []const u8 {
        return m.game[0..m.game_len];
    }
    pub fn statSlice(m: *const Member) []const u8 {
        return m.stat[0..m.stat_len];
    }
    /// The name to put in chat events; falls back to the account when the client never
    /// told us a character (a chat-only client, or one that entered before selecting one).
    pub fn displaySlice(m: *const Member) []const u8 {
        return if (m.display_len > 0) m.display[0..m.display_len] else m.nameSlice();
    }
    pub fn awaySlice(m: *const Member) []const u8 {
        return m.away[0..m.away_len];
    }
    pub fn dndSlice(m: *const Member) []const u8 {
        return m.dnd[0..m.dnd_len];
    }
    /// Does this member squelch `name` (case-insensitive)?
    pub fn ignoresName(m: *const Member, name: []const u8) bool {
        var i: usize = 0;
        while (i < m.ignore_count) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(m.ignores[i][0..m.ignore_lens[i]], name)) return true;
        }
        return false;
    }
};

/// Count members currently in `channel` (excluding `exclude_fd`). Caller must NOT
/// hold the registry lock. Used to decide channel-operator on join.
pub fn countInChannel(channel: []const u8, exclude_fd: net.Socket) usize {
    reg.lock.lock();
    defer reg.lock.unlock();
    var n: usize = 0;
    for (&reg.members) |*m| {
        if (m.in_use and m.fd != exclude_fd and std.mem.eql(u8, m.channelSlice(), channel)) n += 1;
    }
    return n;
}

const Registry = struct {
    lock: Lock = .{},
    members: [1024]Member = [_]Member{.{}} ** 1024,
};

var reg: Registry = .{};

/// Claim (or reuse, by fd) a slot for this connection and set its name+channel.
/// Returns the member, or null if the table is full.
pub fn join(fd: net.Socket, name: []const u8, display: []const u8, channel: []const u8, flags: u32, stat: []const u8) ?*Member {
    reg.lock.lock();
    defer reg.lock.unlock();
    var slot: ?*Member = null;
    for (&reg.members) |*m| {
        if (m.in_use and m.fd == fd) {
            slot = m;
            break;
        }
        if (slot == null and !m.in_use) slot = m;
    }
    const m = slot orelse return null;
    m.fd = fd;
    const nn: u8 = @intCast(@min(name.len, max_name));
    @memcpy(m.name[0..nn], name[0..nn]);
    m.name_len = nn;
    const cn: u8 = @intCast(@min(channel.len, max_channel));
    @memcpy(m.channel[0..cn], channel[0..cn]);
    m.channel_len = cn;
    m.flags = flags;
    const sn: u8 = @intCast(@min(stat.len, max_stat));
    @memcpy(m.stat[0..sn], stat[0..sn]);
    m.stat_len = sn;
    const dn: u8 = @intCast(@min(display.len, max_name));
    @memcpy(m.display[0..dn], display[0..dn]);
    m.display_len = dn;
    m.in_use = true;
    return m;
}

/// Join, and publish into the shared room so the other instances can see them.
///
/// Separate from `join` because publishing is a store round trip and `join` is called under the
/// registry lock by tests and by paths that publish themselves afterwards.
pub fn joinShared(fd: net.Socket, name: []const u8, display: []const u8, channel: []const u8, flags: u32, stat: []const u8) ?*Member {
    const m = join(fd, name, display, channel, flags, stat) orelse return null;
    publishByFd(fd);
    return m;
}

/// Free this connection's slot (on disconnect), and take them out of the shared room.
pub fn leave(fd: net.Socket) void {
    var chan: [max_channel]u8 = undefined;
    var chan_len: usize = 0;
    var name: [max_name]u8 = undefined;
    var name_len: usize = 0;
    {
        reg.lock.lock();
        defer reg.lock.unlock();
        for (&reg.members) |*m| {
            if (m.in_use and m.fd == fd) {
                chan_len = m.channel_len;
                @memcpy(chan[0..chan_len], m.channelSlice());
                name_len = m.name_len;
                @memcpy(name[0..name_len], m.nameSlice());
                m.in_use = false;
                m.fd = -1;
                m.name_len = 0;
                m.channel_len = 0;
                break;
            }
        }
    }
    // Outside the lock: a disconnect must not hold up the channel it is leaving. `gone` — the
    // connection is over, so the by-name index goes too and a whisper stops finding them.
    if (name_len > 0) unpublish(chan[0..chan_len], name[0..name_len], true);
}

/// Write bytes to a member under its send_lock.
pub fn sendTo(m: *Member, bytes: []const u8) void {
    m.send_lock.lock();
    defer m.send_lock.unlock();
    _ = net.writeAll(m.fd, bytes);
}

/// Call `cb(ctx, member)` for each OTHER member in `channel` (skip exclude_fd).
/// The registry lock is held across iteration; cb sends under each member's
/// send_lock (via sendTo), never re-entering the registry lock.
pub fn forEachInChannel(
    channel: []const u8,
    exclude_fd: net.Socket,
    ctx: anytype,
    cb: *const fn (@TypeOf(ctx), *Member) void,
) void {
    reg.lock.lock();
    defer reg.lock.unlock();
    for (&reg.members) |*m| {
        if (!m.in_use) continue;
        if (m.fd == exclude_fd) continue;
        if (!std.mem.eql(u8, m.channelSlice(), channel)) continue;
        cb(ctx, m);
    }
}

// ── social helpers (caller must NOT hold reg.lock) ───────────────────────────

/// The character part of a `clan*charname` chat identity, or the whole string when there
/// is no '*'. This is the part the channel list draws, so it is the part a player sees and
/// therefore the part they type.
fn charPart(display: []const u8) []const u8 {
    const star = std.mem.indexOfScalar(u8, display, '*') orelse return display;
    return display[star + 1 ..];
}

/// Whether `name` refers to this member. A user is reachable by any of the names they are
/// known by: the account (what scripts and the admin API use), the full chat identity, and
/// the character alone — which is what the channel list shows, and so what someone typing
/// a whisper will actually have in front of them. Matching only the account meant the one
/// name a player could see was the one name that did not work.
///
/// Ambiguity resolves to the first match; two accounts playing identically-named characters
/// is possible on a closed realm and there is no better answer than "whoever we find".
fn matchesName(m: *const Member, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(m.nameSlice(), name)) return true;
    const disp = m.displaySlice();
    if (std.ascii.eqlIgnoreCase(disp, name)) return true;
    return std.ascii.eqlIgnoreCase(charPart(disp), name);
}

fn findByNameLocked(name: []const u8) ?*Member {
    for (&reg.members) |*m| {
        if (m.in_use and matchesName(m, name)) return m;
    }
    return null;
}
fn findByFdLocked(fd: net.Socket) ?*Member {
    for (&reg.members) |*m| {
        if (m.in_use and m.fd == fd) return m;
    }
    return null;
}

/// Set (msg non-empty) or clear (msg empty) this connection's /away message.
pub fn setAway(fd: net.Socket, msg: []const u8) void {
    {
        reg.lock.lock();
        defer reg.lock.unlock();
        const m = findByFdLocked(fd) orelse return;
        const n: u8 = @intCast(@min(msg.len, max_status));
        @memcpy(m.away[0..n], msg[0..n]);
        m.away_len = n;
    }
    republish(fd, ""); // other instances answer /whois and auto-reply from this
}
/// Take this connection out of its channel while leaving it registered, so whispers and
/// friend lookups still find it.
pub fn clearChannel(fd: net.Socket) void {
    var old: [max_channel]u8 = undefined;
    var old_len: usize = 0;
    {
        reg.lock.lock();
        defer reg.lock.unlock();
        const m = findByFdLocked(fd) orelse return;
        old_len = m.channel_len;
        @memcpy(old[0..old_len], m.channelSlice());
        m.channel_len = 0;
    }
    republish(fd, old[0..old_len]);
}

/// Record that this connection went into a game (SID_NOTIFYJOIN) and left the channel
/// behind. Passing an empty name puts them back in the lobby.
pub fn setGame(fd: net.Socket, game_name: []const u8) void {
    var old: [max_channel]u8 = undefined;
    var old_len: usize = 0;
    var found = false;
    {
        reg.lock.lock();
        defer reg.lock.unlock();
        const m = findByFdLocked(fd) orelse return;
        found = true;
        const n: u8 = @intCast(@min(game_name.len, max_channel));
        @memcpy(m.game[0..n], game_name[0..n]);
        m.game_len = n;
        if (n > 0) {
            // Out of the channel: channel talk must stop reaching them, on every instance.
            old_len = m.channel_len;
            @memcpy(old[0..old_len], m.channelSlice());
            m.channel_len = 0;
        }
    }
    if (found) republish(fd, old[0..old_len]);
}

/// Set/clear this connection's /dnd (Do-Not-Disturb) message.
pub fn setDnd(fd: net.Socket, msg: []const u8) void {
    {
        reg.lock.lock();
        defer reg.lock.unlock();
        const m = findByFdLocked(fd) orelse return;
        const n: u8 = @intCast(@min(msg.len, max_status));
        @memcpy(m.dnd[0..n], msg[0..n]);
        m.dnd_len = n;
    }
    republish(fd, ""); // a whisper from another instance is refused on this
}

/// Copy the channel `name` is in into `out`, returning its length; null if offline.
pub fn whereIs(name: []const u8, out: []u8) ?usize {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByNameLocked(name) orelse return null;
    const ch = if (m.game_len > 0) m.gameSlice() else m.channelSlice();
    const n = @min(ch.len, out.len);
    @memcpy(out[0..n], ch[0..n]);
    return n;
}

/// Add `name` to this connection's squelch list. False if full / already present.
pub fn addIgnore(fd: net.Socket, name: []const u8) bool {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByFdLocked(fd) orelse return false;
    if (m.ignoresName(name) or m.ignore_count >= max_ignores) return false;
    const i = m.ignore_count;
    const n: u8 = @intCast(@min(name.len, max_name));
    @memcpy(m.ignores[i][0..n], name[0..n]);
    m.ignore_lens[i] = n;
    m.ignore_count += 1;
    return true;
}
/// Remove `name` from this connection's squelch list. False if it wasn't present.
pub fn removeIgnore(fd: net.Socket, name: []const u8) bool {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByFdLocked(fd) orelse return false;
    var i: usize = 0;
    while (i < m.ignore_count) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(m.ignores[i][0..m.ignore_lens[i]], name)) {
            const last = m.ignore_count - 1;
            if (i != last) {
                m.ignores[i] = m.ignores[last];
                m.ignore_lens[i] = m.ignore_lens[last];
            }
            m.ignore_count = last;
            return true;
        }
    }
    return false;
}

/// Does the member on `recipient_fd` squelch `sender`? Used by the talk broadcast.
pub fn recipientIgnores(recipient_fd: net.Socket, sender: []const u8) bool {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByFdLocked(recipient_fd) orelse return false;
    return m.ignoresName(sender);
}

/// Whisper that reports the target's presence so the caller can auto-reply.
/// Delivers unless the target is in DND.
pub const WhisperResult = struct {
    found: bool = false,
    dnd_len: u8 = 0,
    dnd: [max_status]u8 = undefined,
    away_len: u8 = 0,
    away: [max_status]u8 = undefined,
    pub fn dndSlice(w: *const WhisperResult) []const u8 {
        return w.dnd[0..w.dnd_len];
    }
    pub fn awaySlice(w: *const WhisperResult) []const u8 {
        return w.away[0..w.away_len];
    }
};
pub fn whisperEx(name: []const u8, bytes: []const u8) WhisperResult {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByNameLocked(name) orelse return .{};
    var res = WhisperResult{ .found = true, .dnd_len = m.dnd_len, .away_len = m.away_len };
    @memcpy(res.dnd[0..m.dnd_len], m.dndSlice());
    @memcpy(res.away[0..m.away_len], m.awaySlice());
    if (m.dnd_len == 0) sendTo(m, bytes); // DND suppresses delivery
    return res;
}

/// The fd of an online member by name (for ops /kick), or null. The caller acts on
/// the socket (e.g. send a kick event then close it).
/// Where a user is and how available they are, for the friends list. Null if they are
/// not in chat (offline, or in a game rather than the lobby).
pub const Presence = struct {
    /// Channel they are sitting in, empty when they are not in one.
    channel: [max_channel]u8 = [_]u8{0} ** max_channel,
    channel_len: u8 = 0,
    /// The game they went off to play, if any. A player in a game is still connected to
    /// bnetd — whispers must reach them — but they are no longer in the channel, so
    /// channel talk must not. Set from SID_NOTIFYJOIN, cleared when they rejoin a channel.
    game: [max_channel]u8 = [_]u8{0} ** max_channel,
    game_len: u8 = 0,
    away: bool = false,
    dnd: bool = false,
    /// True when `channel` is actually a game name.
    in_game: bool = false,

    pub fn channelSlice(p: *const Presence) []const u8 {
        return p.channel[0..p.channel_len];
    }
};

/// Where a user is, wherever they are. Local first — the common case, and free.
pub fn presenceOfAnywhere(name: []const u8) ?Presence {
    return presenceOf(name) orelse presenceOfRemote(name);
}

pub fn presenceOf(name: []const u8) ?Presence {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByNameLocked(name) orelse return null;
    // A game beats a channel: it is where the player actually is.
    const where = if (m.game_len > 0) m.gameSlice() else m.channelSlice();
    var p = Presence{ .away = m.away_len > 0, .dnd = m.dnd_len > 0, .in_game = m.game_len > 0 };
    p.channel_len = @intCast(where.len);
    @memcpy(p.channel[0..where.len], where);
    return p;
}

/// Resolve any of a user's names to the ACCOUNT they are registered under, copied into
/// `out`. Null when nobody online answers to that name.
///
/// The squelch list is keyed on the account because that is what the broadcast path has
/// cheaply to hand, but a player types the name they can SEE — which since the channel
/// list started showing characters is not the account. Resolving once, when the /ignore is
/// added, keeps the key and the check in the same vocabulary without putting a three-way
/// name comparison in the path every chat line takes.
pub fn resolveAccount(name: []const u8, out: []u8) ?[]const u8 {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByNameLocked(name) orelse return null;
    const acct = m.nameSlice();
    const n = @min(acct.len, out.len);
    @memcpy(out[0..n], acct[0..n]);
    return out[0..n];
}

pub fn fdOf(name: []const u8) ?net.Socket {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByNameLocked(name) orelse return null;
    return m.fd;
}

// ── across instances ─────────────────────────────────────────────────────────
//
// The registry above holds THIS instance's members, because it owns their sockets. The room they
// are in is bigger than that: with more than one realmd, a channel is the union of what every
// instance holds, and the failure of pretending otherwise is quiet — talk simply does not arrive,
// a whisper reports "that user is not logged on" about someone who plainly is, and the user list
// shows half the room. Nothing errors.
//
// So each member is also published into a shared roster, and anything that must reach a member
// held elsewhere is handed to that instance's inbox. Local delivery still goes straight down the
// socket: the common case — one channel, one instance — costs exactly what it did before.

const store = @import("store.zig");

/// This instance's id, from the same hash that keeps session and request ids apart.
/// Set by main() before any connection is served.
pub var instance: u32 = 0;

/// Wire tags for an inbox event. The payload is an already-encoded BNCS packet: chat has no
/// reason to re-derive on the receiving side what the sending side already built.
const EV_CHANNEL: u8 = 0; // deliver to every local member of `name`, except from `sender`
const EV_DIRECT: u8 = 1; // deliver to the local member called `name`

fn putLp(buf: []u8, pos: *usize, s: []const u8) bool {
    const n = @min(s.len, 255);
    if (pos.* + 1 + n > buf.len) return false;
    buf[pos.*] = @intCast(n);
    @memcpy(buf[pos.* + 1 ..][0..n], s[0..n]);
    pos.* += 1 + n;
    return true;
}

fn getLp(buf: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= buf.len) return null;
    const n = buf[pos.*];
    if (pos.* + 1 + n > buf.len) return null;
    const s = buf[pos.* + 1 ..][0..n];
    pos.* += 1 + n;
    return s;
}

/// A member as the rest of the realm sees them. Everything the other instances need to draw them
/// in a user list, route a whisper, or answer /whois — and nothing about a socket, which is the
/// one thing that cannot travel.
fn encodeMember(buf: []u8, m: *const Member) ?[]const u8 {
    var pos: usize = 0;
    if (buf.len < 8) return null;
    std.mem.writeInt(u32, buf[0..4], instance, .little);
    std.mem.writeInt(u32, buf[4..8], m.flags, .little);
    pos = 8;
    if (!putLp(buf, &pos, m.displaySlice())) return null;
    if (!putLp(buf, &pos, m.statSlice())) return null;
    if (!putLp(buf, &pos, m.gameSlice())) return null;
    if (!putLp(buf, &pos, m.awaySlice())) return null;
    if (!putLp(buf, &pos, m.dndSlice())) return null;
    return buf[0..pos];
}

pub const RemoteMember = struct {
    instance: u32,
    flags: u32,
    display: []const u8,
    stat: []const u8,
    game: []const u8,
    away: []const u8,
    dnd: []const u8,
};

fn decodeMember(rec: []const u8) ?RemoteMember {
    if (rec.len < 8) return null;
    var pos: usize = 8;
    return .{
        .instance = std.mem.readInt(u32, rec[0..4], .little),
        .flags = std.mem.readInt(u32, rec[4..8], .little),
        .display = getLp(rec, &pos) orelse return null,
        .stat = getLp(rec, &pos) orelse return null,
        .game = getLp(rec, &pos) orelse return null,
        .away = getLp(rec, &pos) orelse return null,
        .dnd = getLp(rec, &pos) orelse return null,
    };
}

/// Publish (or refresh) one of our members. Called whenever anything another instance can see
/// changes — the channel, the statstring, /away, /dnd, going off to a game.
fn publish(m: *const Member) void {
    if (m.channel_len == 0) return;
    var buf: [max_stat + max_status * 2 + max_name + max_channel + 16]u8 = undefined;
    const rec = encodeMember(&buf, m) orelse return;
    _ = store.chatPutMember(m.channelSlice(), m.nameSlice(), rec);
}

/// Re-publish after a change other instances can see. When the member has left the channel (a
/// game, or /leave) only the by-name index is written: they are still online and still
/// whisperable, just not in the room.
fn republish(fd: net.Socket, left_channel: []const u8) void {
    var buf: [max_stat + max_status * 2 + max_name + max_channel + 16]u8 = undefined;
    var rec: []const u8 = &.{};
    var name: [max_name]u8 = undefined;
    var name_len: usize = 0;
    var in_channel = false;
    var chan: [max_channel]u8 = undefined;
    var chan_len: usize = 0;
    {
        reg.lock.lock();
        defer reg.lock.unlock();
        const m = findByFdLocked(fd) orelse return;
        rec = encodeMember(&buf, m) orelse return;
        name_len = m.name_len;
        @memcpy(name[0..name_len], m.nameSlice());
        in_channel = m.channel_len > 0;
        chan_len = m.channel_len;
        @memcpy(chan[0..chan_len], m.channelSlice());
    }
    if (left_channel.len > 0) store.chatDelMember(left_channel, name[0..name_len], false);
    if (in_channel) {
        _ = store.chatPutMember(chan[0..chan_len], name[0..name_len], rec);
    } else {
        _ = store.chatPutIndex(name[0..name_len], rec);
    }
}

fn publishByFd(fd: net.Socket) void {
    var buf: [max_stat + max_status * 2 + max_name + max_channel + 16]u8 = undefined;
    var rec: []const u8 = &.{};
    var chan: [max_channel]u8 = undefined;
    var chan_len: usize = 0;
    var name: [max_name]u8 = undefined;
    var name_len: usize = 0;
    {
        reg.lock.lock();
        defer reg.lock.unlock();
        const m = findByFdLocked(fd) orelse return;
        if (m.channel_len == 0) return;
        rec = encodeMember(&buf, m) orelse return;
        chan_len = m.channel_len;
        @memcpy(chan[0..chan_len], m.channelSlice());
        name_len = m.name_len;
        @memcpy(name[0..name_len], m.nameSlice());
    }
    // Deliberately outside the registry lock: this is a store round trip, and holding the lock
    // across it would stall every broadcast on the instance for its duration.
    _ = store.chatPutMember(chan[0..chan_len], name[0..name_len], rec);
}

/// Take one of our members out of the shared room. `gone` distinguishes leaving a channel (still
/// online, still whisperable) from disconnecting.
fn unpublish(channel: []const u8, name: []const u8, gone: bool) void {
    if (channel.len == 0 or name.len == 0) return;
    store.chatDelMember(channel, name, gone);
}

/// Everyone in `channel` on OTHER instances. Ours are already in the registry, and listing them
/// twice would show every local user in the channel list twice over.
pub fn forEachRemoteInChannel(
    channel: []const u8,
    ctx: anytype,
    cb: *const fn (@TypeOf(ctx), RemoteMember) void,
) void {
    // The callback travels in the context rather than being captured: a nested function in Zig
    // closes over types, not values.
    const Ctx = @TypeOf(ctx);
    const Pair = struct { ctx: Ctx, cb: *const fn (Ctx, RemoteMember) void };
    var pair = Pair{ .ctx = ctx, .cb = cb };
    const Shim = struct {
        fn each(p: *Pair, _: []const u8, rec: []const u8) void {
            const rm = decodeMember(rec) orelse return;
            if (rm.instance == instance) return; // ours; the registry already has them
            p.cb(p.ctx, rm);
        }
    };
    _ = store.chatRoster(channel, &pair, Shim.each);
}

/// How many are in the channel across the whole realm. Used to decide channel-operator, which
/// must not hand the badge to everyone who happens to be first on their own instance.
pub fn countInChannelShared(channel: []const u8) usize {
    return store.chatChannelSize(channel);
}

/// Hand `bytes` to every OTHER instance holding a member of `channel`, once each. `sender` rides
/// along so the receiving side can apply its own members' /ignore lists — squelching is the
/// recipient's business and only they know it.
pub fn broadcastRemote(channel: []const u8, sender: []const u8, eid: u32, bytes: []const u8) void {
    // One event per INSTANCE, not per member: the packet is identical for everyone in the
    // channel, and the receiving instance fans it out to its own.
    const Instances = struct {
        ids: [16]u32 = undefined,
        n: usize = 0,
        fn each(self: *@This(), rm: RemoteMember) void {
            for (self.ids[0..self.n]) |id| {
                if (id == rm.instance) return;
            }
            if (self.n >= self.ids.len) return;
            self.ids[self.n] = rm.instance;
            self.n += 1;
        }
    };
    var inst = Instances{};
    forEachRemoteInChannel(channel, &inst, Instances.each);
    if (inst.n == 0) return; // nobody else holds anyone here — the common case, one read

    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = EV_CHANNEL;
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], eid, .little);
    pos += 4;
    if (!putLp(&buf, &pos, channel)) return;
    if (!putLp(&buf, &pos, sender)) return;
    if (pos + bytes.len > buf.len) return;
    @memcpy(buf[pos..][0..bytes.len], bytes);
    pos += bytes.len;
    for (inst.ids[0..inst.n]) |id| _ = store.chatPush(id, buf[0..pos]);
}

/// Try to whisper someone held by another instance. Returns their presence the same way the local
/// path does, so the caller answers the sender identically wherever the target happens to be.
pub fn whisperRemote(name: []const u8, sender: []const u8, bytes: []const u8) WhisperResult {
    var recbuf: [512]u8 = undefined;
    const n = store.chatFindMember(name, &recbuf) orelse return .{};
    const rm = decodeMember(recbuf[0..n]) orelse return .{};
    if (rm.instance == instance) return .{}; // ours and not found locally = gone
    var res = WhisperResult{ .found = true };
    res.dnd_len = @intCast(@min(rm.dnd.len, max_status));
    @memcpy(res.dnd[0..res.dnd_len], rm.dnd[0..res.dnd_len]);
    res.away_len = @intCast(@min(rm.away.len, max_status));
    @memcpy(res.away[0..res.away_len], rm.away[0..res.away_len]);
    if (res.dnd_len != 0) return res; // DND suppresses delivery, here as locally

    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = EV_DIRECT;
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .little);
    pos += 4;
    if (!putLp(&buf, &pos, name)) return .{};
    if (!putLp(&buf, &pos, sender)) return .{};
    if (pos + bytes.len > buf.len) return .{};
    @memcpy(buf[pos..][0..bytes.len], bytes);
    pos += bytes.len;
    _ = store.chatPush(rm.instance, buf[0..pos]);
    return res;
}

/// Where a user is, when no local member answers to that name.
pub fn presenceOfRemote(name: []const u8) ?Presence {
    var recbuf: [512]u8 = undefined;
    const n = store.chatFindMember(name, &recbuf) orelse return null;
    const rm = decodeMember(recbuf[0..n]) orelse return null;
    if (rm.instance == instance) return null;
    // The record is keyed by the channel the member is in, and `game` beats it for the same
    // reason it does locally: a game is where the player actually is.
    var p = Presence{ .away = rm.away.len > 0, .dnd = rm.dnd.len > 0, .in_game = rm.game.len > 0 };
    const where = if (rm.game.len > 0) rm.game else "";
    p.channel_len = @intCast(@min(where.len, max_channel));
    @memcpy(p.channel[0..p.channel_len], where[0..p.channel_len]);
    return p;
}

// ── the inbox ────────────────────────────────────────────────────────────────

const InboxCtx = struct { eid: u32, sender: []const u8, payload: []const u8 };

fn inboxDeliverCb(ctx: *const InboxCtx, m: *Member) void {
    // The recipient's squelch list, applied where it lives. The sending instance could not have
    // done this: an /ignore is a fact about the person receiving.
    if (ctx.eid == 1 and m.ignoresName(ctx.sender)) return; // EID_TALK
    sendTo(m, ctx.payload);
}

fn applyInbox(ev: []const u8) void {
    if (ev.len < 5) return;
    const kind = ev[0];
    const eid = std.mem.readInt(u32, ev[1..5], .little);
    var pos: usize = 5;
    const name = getLp(ev, &pos) orelse return;
    const sender = getLp(ev, &pos) orelse return;
    const payload = ev[pos..];
    if (payload.len == 0) return;
    switch (kind) {
        EV_CHANNEL => {
            const ctx = InboxCtx{ .eid = eid, .sender = sender, .payload = payload };
            forEachInChannel(name, -1, &ctx, inboxDeliverCb);
        },
        EV_DIRECT => {
            reg.lock.lock();
            defer reg.lock.unlock();
            const m = findByNameLocked(name) orelse return;
            sendTo(m, payload);
        },
        else => {},
    }
}

extern "c" fn usleep(usec: c_uint) c_int;

/// Drain this instance's inbox forever, and keep our published members alive.
///
/// One thread does both because they have the same shape and the same tolerance: chat is allowed
/// to be a few tens of milliseconds late, and a member record is allowed to be a fraction of its
/// TTL stale.
pub fn runInbox() void {
    var buf: [1024]u8 = undefined;
    var nap: c_uint = 2_000;
    var since_refresh: u64 = 0;
    while (true) {
        if (store.chatPop(instance, &buf)) |n| {
            applyInbox(buf[0..n]);
            nap = 2_000; // busy: come straight back
            continue;
        }
        _ = usleep(nap);
        since_refresh += nap;
        if (nap < 50_000) nap *= 2;
        // A third of the TTL, for the same reason the game servers refresh at a third of theirs.
        if (since_refresh >= @as(u64, store.chat_member_ttl_s) * 1_000_000 / 3) {
            since_refresh = 0;
            refreshAll();
        }
    }
}

fn refreshAll() void {
    var fds: [1024]net.Socket = undefined;
    var n: usize = 0;
    {
        reg.lock.lock();
        defer reg.lock.unlock();
        for (&reg.members) |*m| {
            if (!m.in_use or m.channel_len == 0) continue;
            if (n >= fds.len) break;
            fds[n] = m.fd;
            n += 1;
        }
    }
    // Snapshot first, then publish outside the lock: refreshing a busy channel would otherwise
    // hold every broadcast on this instance for one store round trip per member.
    for (fds[0..n]) |fd| publishByFd(fd);
}

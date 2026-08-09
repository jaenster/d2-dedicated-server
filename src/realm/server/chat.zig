//! Process-global chat-channel registry. BNCS connections that SID_JOINCHANNEL
//! register a Member here; talking/whispering broadcasts to other members in the
//! same channel. Broadcasts originate on arbitrary connection threads, so the
//! registry is guarded by a spinlock and each member has its own send_lock so a
//! slow/blocked peer can't tear a packet sent by another thread.
const std = @import("std");
const net = @import("realm_infra").net;
const Spinlock = @import("realm_infra").lock.Spinlock;

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
    send_lock: Spinlock = .{},

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
    lock: Spinlock = .{},
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

/// Free this connection's slot (on disconnect).
pub fn leave(fd: net.Socket) void {
    reg.lock.lock();
    defer reg.lock.unlock();
    for (&reg.members) |*m| {
        if (m.in_use and m.fd == fd) {
            m.in_use = false;
            m.fd = -1;
            m.name_len = 0;
            m.channel_len = 0;
            return;
        }
    }
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

fn findByNameLocked(name: []const u8) ?*Member {
    for (&reg.members) |*m| {
        if (m.in_use and std.ascii.eqlIgnoreCase(m.nameSlice(), name)) return m;
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
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByFdLocked(fd) orelse return;
    const n: u8 = @intCast(@min(msg.len, max_status));
    @memcpy(m.away[0..n], msg[0..n]);
    m.away_len = n;
}
/// Take this connection out of its channel while leaving it registered, so whispers and
/// friend lookups still find it.
pub fn clearChannel(fd: net.Socket) void {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByFdLocked(fd) orelse return;
    m.channel_len = 0;
}

/// Record that this connection went into a game (SID_NOTIFYJOIN) and left the channel
/// behind. Passing an empty name puts them back in the lobby.
pub fn setGame(fd: net.Socket, game_name: []const u8) void {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByFdLocked(fd) orelse return;
    const n: u8 = @intCast(@min(game_name.len, max_channel));
    @memcpy(m.game[0..n], game_name[0..n]);
    m.game_len = n;
    if (n > 0) m.channel_len = 0; // out of the channel: channel talk must stop reaching them
}

/// Set/clear this connection's /dnd (Do-Not-Disturb) message.
pub fn setDnd(fd: net.Socket, msg: []const u8) void {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByFdLocked(fd) orelse return;
    const n: u8 = @intCast(@min(msg.len, max_status));
    @memcpy(m.dnd[0..n], msg[0..n]);
    m.dnd_len = n;
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

pub fn fdOf(name: []const u8) ?net.Socket {
    reg.lock.lock();
    defer reg.lock.unlock();
    const m = findByNameLocked(name) orelse return null;
    return m.fd;
}

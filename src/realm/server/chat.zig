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

pub const Member = struct {
    fd: net.Socket = -1,
    in_use: bool = false,
    name: [max_name]u8 = [_]u8{0} ** max_name,
    name_len: u8 = 0,
    channel: [max_channel]u8 = [_]u8{0} ** max_channel,
    channel_len: u8 = 0,
    flags: u32 = 0, // SID_CHATEVENT user flags (operator/admin/...) for this user
    // The client's SID_ENTERCHAT statstring — for D2 it encodes the character
    // (name/class/level/gear) the channel user-list draws via
    // COMCALLBACK_FormatChannelUserData. Replayed in EID_SHOWUSER/EID_JOIN.
    stat: [max_stat]u8 = [_]u8{0} ** max_stat,
    stat_len: u8 = 0,
    send_lock: Spinlock = .{},

    pub fn nameSlice(m: *const Member) []const u8 {
        return m.name[0..m.name_len];
    }
    pub fn channelSlice(m: *const Member) []const u8 {
        return m.channel[0..m.channel_len];
    }
    pub fn statSlice(m: *const Member) []const u8 {
        return m.stat[0..m.stat_len];
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
pub fn join(fd: net.Socket, name: []const u8, channel: []const u8, flags: u32, stat: []const u8) ?*Member {
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

/// Deliver `bytes` to the member with this exact name (first match), if any.
/// Returns true if a recipient was found. Used for whispers.
pub fn whisper(name: []const u8, bytes: []const u8) bool {
    reg.lock.lock();
    defer reg.lock.unlock();
    for (&reg.members) |*m| {
        if (m.in_use and std.mem.eql(u8, m.nameSlice(), name)) {
            sendTo(m, bytes);
            return true;
        }
    }
    return false;
}

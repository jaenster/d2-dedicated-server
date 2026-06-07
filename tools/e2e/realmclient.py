"""Clientless wire-protocol clients for the realmd realm server.

Speaks the raw BNCS (bnetd), MCP (d2cs) and d2dbs/gs-link control framings
directly over TCP — no wine, no Game.exe. See README.md for the format notes.
"""
import socket
import struct
import threading


HOST = "127.0.0.1"

# Default realmd listener ports (see src/realm/server/config.zig).
BNET_PORT = 6112
D2CS_PORT = 6113
D2DBS_PORT = 6114
GS_PORT = 6115


# ---------------------------------------------------------------------------
# Low-level framings
# ---------------------------------------------------------------------------

def _bp(id_, body=b""):
    """BNCS packet: <BBH ff,id,len> + body."""
    return struct.pack("<BBH", 0xFF, id_, 4 + len(body)) + body


def _recvn(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("socket closed mid-packet")
        buf += chunk
    return buf


def _br(s):
    """Read a BNCS packet -> (id, body)."""
    ff, id_, ln = struct.unpack("<BBH", _recvn(s, 4))
    assert ff == 0xFF, f"bad bncs ff byte {ff:#x}"
    return id_, _recvn(s, ln - 4)


def _mp(id_, body=b""):
    """MCP/d2cs packet: <HB len,id> + body."""
    return struct.pack("<HB", 3 + len(body), id_) + body


def _mr(s):
    """Read an MCP packet -> (id, body)."""
    ln, id_ = struct.unpack("<HB", _recvn(s, 3))
    return id_, _recvn(s, ln - 3)


def _ctl(typ, body=b"", seq=1):
    """gs-link / d2dbs control frame: <HHI size,type,seq> + body."""
    return struct.pack("<HHI", 8 + len(body), typ, seq) + body


def _ctl_recv(s):
    """Read a control frame -> (type, seq, body)."""
    size, typ, seq = struct.unpack("<HHI", _recvn(s, 8))
    return typ, seq, _recvn(s, size - 8)


# BNCS opcodes
SID_LOGONRESPONSE2 = 0x3A
SID_CREATEACCOUNT2 = 0x3D
SID_LOGONREALMEX = 0x3E
SID_QUERYREALMS2 = 0x40
SID_AUTH_INFO = 0x50
SID_AUTH_CHECK = 0x51

# MCP opcodes
MCP_STARTUP = 0x01
MCP_CREATEGAME = 0x03
MCP_JOINGAME = 0x04
MCP_CHARLIST2 = 0x19

# d2dbs opcodes
DBS_SAVE = 0x30
DBS_GET = 0x31
DBS_DATATYPE_CHARSAVE = 0x01

# gs-link control opcodes
GS_AUTHREQ = 0x10
GS_AUTHREPLY = 0x11
GS_SETGSINFO = 0x12
GS_ADDRINFO = 0x24
GS_CREATEGAME = 0x20
GS_JOINGAME = 0x21

CLASS_NAMES = [
    "Amazon", "Sorceress", "Necromancer", "Paladin",
    "Barbarian", "Druid", "Assassin",
]


def _dec14(b0, b1):
    """Decode a 14-bit little-endian pair: high bit of each byte is a guard."""
    return (b1 & 0x7F) * 128 + (b0 & 0x7F)


def decode_statstring(ss):
    """Decode a CHARLIST2 statstring blob into {class, class_id, level, flags}.

    Layout (from the client reconstruction, CharSel.cpp):
      [0..2)  14-bit realm char count
      [2..13) equip slot1 (ignore)
      [13]    class byte -> class_id = byte - 1
      [14..25) equip slot2 (ignore)
      [25]    level (raw u8)
      [26..28) 14-bit flags (0x04 = expansion)
    """
    out = {}
    out["realm_char_count"] = _dec14(ss[0], ss[1]) if len(ss) >= 2 else None
    if len(ss) > 13:
        cid = ss[13] - 1
        out["class_id"] = cid
        out["class"] = CLASS_NAMES[cid] if 0 <= cid < len(CLASS_NAMES) else f"?{cid}"
    if len(ss) > 25:
        out["level"] = ss[25]
    if len(ss) >= 28:
        out["flags"] = _dec14(ss[26], ss[27])
    return out


# ---------------------------------------------------------------------------
# RealmClient: bnetd handshake -> d2cs session
# ---------------------------------------------------------------------------

class RealmClient:
    def __init__(self, host=HOST, bnet_port=BNET_PORT, d2cs_port=D2CS_PORT,
                 realm_name="TypeGuru", timeout=5):
        self.host = host
        self.bnet_port = bnet_port
        self.d2cs_port = d2cs_port
        self.realm_name = realm_name
        self.timeout = timeout
        self.bnet = None
        self.d2cs = None
        self.server_token = None
        self.session = None  # (cookie, status, lo, hi)

    # --- bnetd ---
    def connect_bnet(self):
        self.bnet = socket.create_connection(
            (self.host, self.bnet_port), timeout=self.timeout)
        self.bnet.sendall(b"\x01")  # protocol selector
        return self

    def auth(self):
        s = self.bnet
        body = (struct.pack("<IIII", 0, 0x49583836, 0x44325850, 0x0E)
                + struct.pack("<IIIII", 0, 0, 0, 0, 0) + b"US\x00US\x00")
        s.sendall(_bp(SID_AUTH_INFO, body))
        id_, b = _br(s)
        assert id_ == SID_AUTH_INFO, f"AUTH_INFO got {id_:#x}"
        logon_type, self.server_token = struct.unpack("<II", b[:8])
        assert logon_type == 0, f"unexpected logon_type {logon_type}"
        s.sendall(_bp(SID_AUTH_CHECK, struct.pack("<IIII", 1, 0, 0, 0) + b"\x00i\x00o\x00"))
        id_, b = _br(s)
        assert id_ == SID_AUTH_CHECK and struct.unpack("<I", b[:4])[0] == 0, "auth_check failed"
        return self

    def create_account(self, acct, password="x"):
        s = self.bnet
        s.sendall(_bp(SID_CREATEACCOUNT2, b"\x00" * 20 + acct.encode() + b"\x00"))
        id_, b = _br(s)
        assert id_ == SID_CREATEACCOUNT2, f"CREATEACCOUNT2 got {id_:#x}"
        return struct.unpack("<I", b[:4])[0]

    def login(self, acct, password="x"):
        """Full bnet handshake; stores account + leaves us ready to enter_realm()."""
        assert self.server_token is not None, "call auth() first"
        s = self.bnet
        s.sendall(_bp(SID_LOGONRESPONSE2,
                      struct.pack("<II", 1, self.server_token)
                      + b"\x00" * 20 + acct.encode() + b"\x00"))
        id_, b = _br(s)
        assert id_ == SID_LOGONRESPONSE2 and struct.unpack("<I", b[:4])[0] == 0, "logon failed"
        self.account = acct
        return self

    def enter_realm(self):
        """SID_LOGONREALMEX -> (cookie, status, lo, hi). Stores the session."""
        s = self.bnet
        s.sendall(_bp(SID_LOGONREALMEX,
                      struct.pack("<I", 1) + b"\x00" * 20 + self.realm_name.encode() + b"\x00"))
        id_, b = _br(s)
        assert id_ == SID_LOGONREALMEX, f"LOGONREALMEX got {id_:#x}"
        cookie, status, lo, hi = struct.unpack("<IIII", b[:16])
        self.session = (cookie, status, lo, hi)
        assert status == 0, f"realm logon status {status}"
        return self.session

    @property
    def session_id(self):
        _, _, lo, hi = self.session
        return lo | (hi << 32)

    # --- d2cs ---
    def connect_d2cs(self):
        self.d2cs = socket.create_connection(
            (self.host, self.d2cs_port), timeout=self.timeout)
        self.d2cs.sendall(b"\x01")
        return self

    def startup(self):
        """MCP_STARTUP with the stored session -> result (0 = identified)."""
        assert self.session is not None, "call enter_realm() first"
        cookie, status, lo, hi = self.session
        d = self.d2cs
        d.sendall(_mp(MCP_STARTUP,
                      struct.pack("<IIII", cookie, status, lo, hi)
                      + b"\x00" * 48 + self.account.encode() + b"\x00"))
        id_, b = _mr(d)
        assert id_ == MCP_STARTUP, f"STARTUP got {id_:#x}"
        return struct.unpack("<I", b[:4])[0]

    def char_list(self, want=64):
        """MCP_CHARLIST2 -> (total, [ {name, statstring, class, class_id, level, flags} ])."""
        d = self.d2cs
        d.sendall(_mp(MCP_CHARLIST2, struct.pack("<I", want)))
        id_, b = _mr(d)
        assert id_ == MCP_CHARLIST2, f"CHARLIST2 got {id_:#x}"
        req, total, ret = struct.unpack("<HIH", b[:8])
        off = 8
        chars = []
        for _ in range(ret):
            off += 4  # expiration u32
            e = b.index(0, off)
            name = b[off:e].decode("latin1")
            off = e + 1
            e = b.index(0, off)
            ss = b[off:e]
            off = e + 1
            entry = {"name": name, "statstring": ss}
            entry.update(decode_statstring(ss))
            chars.append(entry)
        return total, chars

    def create_game(self, name, password="", desc="e2e", max_players=8):
        """MCP_CREATEGAME -> (token, result)."""
        d = self.d2cs
        body = (struct.pack("<HIBBB", 7, 0, 1, 0, max_players)
                + name.encode() + b"\x00" + password.encode() + b"\x00"
                + desc.encode() + b"\x00")
        d.sendall(_mp(MCP_CREATEGAME, body))
        id_, b = _mr(d)
        assert id_ == MCP_CREATEGAME, f"CREATEGAME got {id_:#x}"
        reqid, token, unk, result = struct.unpack("<HHHI", b[:10])
        return token, result

    def join_game(self, name, password=""):
        """MCP_JOINGAME -> (token, gs_ip_str, result)."""
        d = self.d2cs
        body = struct.pack("<H", 8) + name.encode() + b"\x00" + password.encode() + b"\x00"
        d.sendall(_mp(MCP_JOINGAME, body))
        id_, b = _mr(d)
        assert id_ == MCP_JOINGAME, f"JOINGAME got {id_:#x}"
        reqid, token, unk, ip, gh, result = struct.unpack("<HHHIII", b[:18])
        ip_str = ".".join(str(x) for x in struct.pack("<I", ip))
        return token, ip_str, result

    def close(self):
        for s in (self.bnet, self.d2cs):
            try:
                if s:
                    s.close()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# D2dbsClient: character save store
# ---------------------------------------------------------------------------

class D2dbsClient:
    def __init__(self, host=HOST, port=D2DBS_PORT, timeout=5):
        self.host = host
        self.port = port
        self.timeout = timeout

    def _conn(self):
        return socket.create_connection((self.host, self.port), timeout=self.timeout)

    def save_char(self, acct, char, d2s_bytes):
        """SAVE_DATA 0x30 -> result (0 = ok)."""
        s = self._conn()
        try:
            body = (struct.pack("<H", DBS_DATATYPE_CHARSAVE)
                    + acct.encode() + b"\x00" + char.encode() + b"\x00"
                    + struct.pack("<H", len(d2s_bytes)) + d2s_bytes)
            s.sendall(_ctl(DBS_SAVE, body))
            typ, seq, b = _ctl_recv(s)
            assert typ == DBS_SAVE, f"SAVE reply type {typ:#x}"
            return struct.unpack("<I", b[:4])[0]
        finally:
            s.close()

    def get_char(self, acct, char):
        """GET_DATA 0x31 -> (result, save_bytes).

        Reply: result u32, createtime u32, allowladder u32, datatype u16,
               datalen u16, char\\0, <save bytes>
        """
        s = self._conn()
        try:
            body = (struct.pack("<H", DBS_DATATYPE_CHARSAVE)
                    + acct.encode() + b"\x00" + char.encode() + b"\x00")
            s.sendall(_ctl(DBS_GET, body))
            typ, seq, b = _ctl_recv(s)
            assert typ == DBS_GET, f"GET reply type {typ:#x}"
            result = struct.unpack("<I", b[:4])[0]
            datalen = struct.unpack("<H", b[14:16])[0]
            off = 16
            while off < len(b) and b[off] != 0:
                off += 1
            off += 1  # past char NUL
            return result, b[off:off + datalen]
        finally:
            s.close()


# ---------------------------------------------------------------------------
# FakeGS: a stand-in game server that registers over the gs-link and answers
# CREATEGAME / JOINGAME requests.
# ---------------------------------------------------------------------------

class FakeGS:
    def __init__(self, host=HOST, port=GS_PORT, gsid=0xABCD, ip=(127, 0, 0, 1),
                 gs_port=4000, maxgame=100, gameid=42, next_gameid=None,
                 timeout=5):
        self.host = host
        self.port = port
        self.gsid = gsid
        self.ip = ip
        self.gs_port = gs_port
        self.maxgame = maxgame
        self.gameid = gameid
        self._next = next_gameid  # if set, hand out incrementing ids
        self.timeout = timeout
        self.registered = threading.Event()
        self.creates = 0
        self.joins = 0
        self._sock = None
        self._thread = None
        self._stop = False

    def _addrinfo(self):
        return (struct.pack("<II", self.maxgame, self.gsid)
                + bytes(self.ip) + struct.pack("<H", self.gs_port))

    def _run(self):
        try:
            s = socket.create_connection((self.host, self.port), timeout=self.timeout)
        except OSError:
            return
        self._sock = s
        while not self._stop:
            try:
                typ, seq, b = _ctl_recv(s)
            except (OSError, ConnectionError):
                break
            if typ == GS_AUTHREQ:
                s.sendall(_ctl(GS_AUTHREPLY))
                s.sendall(_ctl(GS_SETGSINFO, struct.pack("<II", self.maxgame, 0)))
                s.sendall(_ctl(GS_ADDRINFO, self._addrinfo()))
                self.registered.set()
            elif typ == GS_CREATEGAME:
                self.creates += 1
                gid = self.gameid
                if self._next is not None:
                    gid = self._next
                    self._next += 1
                s.sendall(_ctl(GS_CREATEGAME, struct.pack("<II", 0, gid)))
            elif typ == GS_JOINGAME:
                self.joins += 1
                s.sendall(_ctl(GS_JOINGAME, struct.pack("<II", 0, self.gameid)))

    def start(self, wait=2.0):
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        self.registered.wait(timeout=wait)
        return self

    def stop(self):
        self._stop = True
        try:
            if self._sock:
                self._sock.close()
        except OSError:
            pass

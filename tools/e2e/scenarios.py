"""Named end-to-end scenarios for the realmd realm server.

Each scenario is a function returning a Result. A scenario either runs and
asserts on live behaviour, or returns SKIP for a not-yet-implemented feature.
"""
from realmclient import RealmClient, D2dbsClient, FakeGS
from crafts import minimal_d2s


class Result:
    def __init__(self, name, status, message=""):
        self.name = name
        self.status = status  # "PASS" | "FAIL" | "SKIP"
        self.message = message

    def __str__(self):
        return f"[{self.status:4}] {self.name}: {self.message}"


def _pass(name, msg=""):
    return Result(name, "PASS", msg)


def _skip(name, msg):
    return Result(name, "SKIP", msg)


def _run_asserts(name, fn):
    try:
        return _pass(name, fn())
    except AssertionError as e:
        return Result(name, "FAIL", str(e) or "assertion failed")
    except Exception as e:  # noqa: BLE001 - surface any wire/connection error
        return Result(name, "FAIL", f"{type(e).__name__}: {e}")


# ---------------------------------------------------------------------------
# Implemented scenarios
# ---------------------------------------------------------------------------

def sc_login():
    def body():
        c = RealmClient()
        try:
            c.connect_bnet().auth().login("LoginGuy")
            cookie, status, lo, hi = c.enter_realm()
            assert status == 0, f"realm status={status}"
            assert c.session_id >= 1, f"session id not minted ({c.session_id})"
            return f"session minted id={c.session_id} cookie={cookie:#x}"
        finally:
            c.close()
    return _run_asserts("login", body)


def sc_char_list_statstring():
    """SAVE a crafted Sorceress/level-42 then list it and decode the statstring."""
    def body():
        acct = "EpicAma"
        char = "StatSorc"
        dbs = D2dbsClient()
        blob = minimal_d2s(char, class_id=1, level=42)  # 1 = Sorceress
        r = dbs.save_char(acct, char, blob)
        assert r == 0, f"d2dbs save result={r}"

        c = RealmClient()
        try:
            c.connect_bnet().auth().login(acct).enter_realm()
            c.connect_d2cs()
            su = c.startup()
            assert su == 0, f"d2cs startup result={su:#x}"
            total, chars = c.char_list()
            names = [ch["name"] for ch in chars]
            assert char in names, f"char {char!r} not in list {names}"
            ch = next(x for x in chars if x["name"] == char)
            assert ch.get("class") == "Sorceress", \
                f"decoded class={ch.get('class')!r} (id={ch.get('class_id')}), want Sorceress"
            assert ch.get("level") == 42, f"decoded level={ch.get('level')}, want 42"
            return (f"listed {char!r}: statstring decodes class={ch['class']} "
                    f"level={ch['level']} flags={ch.get('flags')} (total chars={total})")
        finally:
            c.close()
    return _run_asserts("char_list_statstring", body)


def sc_create_join_game():
    """A FakeGS registers; create a game then join it; verify GS saw 1+1."""
    def body():
        gs = FakeGS(gsid=0xABCD, ip=(127, 0, 0, 1), maxgame=100, gameid=42)
        gs.start(wait=2.0)
        assert gs.registered.is_set(), "FakeGS did not register over gs-link"
        c = RealmClient()
        try:
            c.connect_bnet().auth().login("GameGuy").enter_realm()
            c.connect_d2cs()
            assert c.startup() == 0, "d2cs startup failed"
            token, result = c.create_game("mygame", desc="d")
            assert result == 0, f"create result={result}"
            assert token == 42, f"create token={token} want 42"
            jtoken, gs_ip, jresult = c.join_game("mygame")
            assert jresult == 0, f"join result={jresult}"
            assert jtoken == 42, f"join token={jtoken} want 42"
            assert gs_ip == "127.0.0.1", f"join gs_ip={gs_ip} want 127.0.0.1"
            assert gs.creates == 1 and gs.joins == 1, \
                f"FakeGS saw creates={gs.creates} joins={gs.joins}, want 1/1"
            return (f"create+join ok token={token} gs_ip={gs_ip} "
                    f"(GS creates={gs.creates} joins={gs.joins})")
        finally:
            c.close()
            gs.stop()
    return _run_asserts("create_join_game", body)


def sc_fleet_capacity():
    """Two FakeGS with maxgame=1: 2 creates spread one-each, 3rd fails."""
    def body():
        gs_a = FakeGS(gsid=0xAAA, ip=(127, 0, 0, 2), maxgame=1, next_gameid=100)
        gs_b = FakeGS(gsid=0xBBB, ip=(127, 0, 0, 3), maxgame=1, next_gameid=200)
        gs_a.start(wait=2.0)
        gs_b.start(wait=2.0)
        assert gs_a.registered.is_set() and gs_b.registered.is_set(), \
            "both FakeGS must register"
        c = RealmClient()
        try:
            c.connect_bnet().auth().login("FleetGuy").enter_realm()
            c.connect_d2cs()
            assert c.startup() == 0, "d2cs startup failed"
            _, r1 = c.create_game("game1", desc="d")
            _, r2 = c.create_game("game2", desc="d")
            assert r1 == 0 and r2 == 0, f"first two creates must pass (r1={r1} r2={r2})"
            assert gs_a.creates == 1 and gs_b.creates == 1, \
                f"creates must spread one-each (a={gs_a.creates} b={gs_b.creates})"
            _, r3 = c.create_game("game3", desc="d")
            assert r3 != 0, "third create must fail (fleet full)"
            assert gs_a.creates == 1 and gs_b.creates == 1, \
                "no extra creates sent when full"
            return (f"routing spread a={gs_a.creates} b={gs_b.creates}, "
                    f"3rd create rejected (result={r3})")
        finally:
            c.close()
            gs_a.stop()
            gs_b.stop()
    return _run_asserts("fleet_capacity", body)


# ---------------------------------------------------------------------------
# Stubs for features not built yet
# ---------------------------------------------------------------------------

def sc_create_account_real_auth():
    return _skip("create_account_real_auth",
                 "SKIP: not implemented yet — bnetd accepts any password "
                 "(no real credential verification)")


def sc_delete_char():
    return _skip("delete_char",
                 "SKIP: not implemented yet — MCP_DELETECHARACTER (0x0a) "
                 "has no handler in d2cs.zig")


def sc_lobby_chat_a_to_b():
    return _skip("lobby_chat_a_to_b",
                 "SKIP: not implemented yet — realm lobby is intentionally "
                 "not a chat channel; no A->B message relay exists")


SCENARIOS = [
    sc_login,
    sc_char_list_statstring,
    sc_create_join_game,
    sc_fleet_capacity,
    sc_create_account_real_auth,
    sc_delete_char,
    sc_lobby_chat_a_to_b,
]

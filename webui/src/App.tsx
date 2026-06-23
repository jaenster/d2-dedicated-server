import { useCallback, useEffect, useState } from "react";
import {
  api,
  ApiError,
  type Account,
  type Game,
  type GameServer,
  type Me,
  type Status,
} from "./api.ts";

type Tab = "overview" | "gameservers" | "games" | "accounts";

export function App() {
  const [me, setMe] = useState<Me | null>(null);
  const [checking, setChecking] = useState(true);
  const [disabled, setDisabled] = useState(false);

  const check = useCallback(async () => {
    try {
      setMe(await api.me());
    } catch (e) {
      setMe(null);
      if (e instanceof ApiError && e.status === 403) setDisabled(true);
    } finally {
      setChecking(false);
    }
  }, []);

  useEffect(() => {
    check();
  }, [check]);

  if (checking) return <div className="login" />;
  if (disabled)
    return (
      <div className="login">
        <div className="card">
          <h1>realmd admin</h1>
          <p className="muted">
            The admin API is disabled. Set <code>REALMD_ADMINS</code> (account login)
            or <code>REALMD_TRUSTED_AUTH_HEADER</code> (SSO) on the server.
          </p>
        </div>
      </div>
    );
  if (!me) return <Login onLoggedIn={check} />;
  return (
    <Dashboard
      me={me}
      onLogout={async () => {
        await api.logout().catch(() => {});
        setMe(null);
      }}
    />
  );
}

function Login(props: { onLoggedIn: () => void }) {
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    setBusy(true);
    setErr(null);
    try {
      await api.login(name.trim(), password);
      props.onLoggedIn();
    } catch (e) {
      setErr(
        e instanceof ApiError
          ? e.status === 401
            ? "Invalid credentials, or that account isn't an admin."
            : e.message
          : String(e),
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="login">
      <div className="card">
        <h1>realmd admin</h1>
        <p className="muted">Sign in with your realm admin account.</p>
        <input
          placeholder="account"
          value={name}
          autoFocus
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submit()}
        />
        <input
          type="password"
          placeholder="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submit()}
        />
        <button disabled={busy || !name.trim() || !password} onClick={submit}>
          {busy ? "Signing in…" : "Sign in"}
        </button>
        {err && <p className="error">{err}</p>}
      </div>
    </div>
  );
}

function Dashboard(props: { me: Me; onLogout: () => void }) {
  const [tab, setTab] = useState<Tab>("overview");
  const tabs: [Tab, string][] = [
    ["overview", "Overview"],
    ["gameservers", "Game Servers"],
    ["games", "Games"],
    ["accounts", "Accounts"],
  ];
  return (
    <div className="app">
      <header>
        <span className="brand">realmd admin</span>
        <nav>
          {tabs.map(([t, label]) => (
            <button
              key={t}
              className={t === tab ? "tab active" : "tab"}
              onClick={() => setTab(t)}
            >
              {label}
            </button>
          ))}
        </nav>
        <span className="who" title={`authenticated via ${props.me.via}`}>
          {props.me.name}
          <span className={`via via-${props.me.via}`}>{props.me.via}</span>
        </span>
        {props.me.via !== "sso" && (
          <button className="logout" onClick={props.onLogout}>
            Log out
          </button>
        )}
      </header>
      <main>
        {tab === "overview" && <Overview />}
        {tab === "gameservers" && <GameServers />}
        {tab === "games" && <Games />}
        {tab === "accounts" && <Accounts me={props.me} />}
      </main>
    </div>
  );
}

// Generic polling hook: re-fetches `fn` every `ms` and on demand.
function usePoll<T>(fn: () => Promise<T>, ms = 5000) {
  const [data, setData] = useState<T | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const load = useCallback(async () => {
    try {
      setData(await fn());
      setErr(null);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
    // fn identity is stable enough for this admin tool
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    load();
    const id = setInterval(load, ms);
    return () => clearInterval(id);
  }, [load, ms]);
  return { data, err, reload: load };
}

function Overview() {
  const { data, err } = usePoll<Status>(api.status);
  if (err) return <Banner msg={err} />;
  if (!data) return <p className="muted">Loading…</p>;
  return (
    <section>
      <div className="stats">
        <Stat label="Sessions" value={data.sessions} />
        <Stat label="Games" value={data.games} />
        <Stat label="Game Servers" value={data.gameservers} />
      </div>
      <dl className="kv">
        <dt>Instance</dt>
        <dd>{data.instance}</dd>
        <dt>Durable store</dt>
        <dd>{data.durable}</dd>
        <dt>Ephemeral store</dt>
        <dd>{data.ephemeral}</dd>
      </dl>
    </section>
  );
}

function Stat(props: { label: string; value: number }) {
  return (
    <div className="stat">
      <div className="num">{props.value}</div>
      <div className="lbl">{props.label}</div>
    </div>
  );
}

function GameServers() {
  const { data, err } = usePoll<GameServer[]>(api.gameservers);
  if (err) return <Banner msg={err} />;
  if (!data) return <p className="muted">Loading…</p>;
  if (data.length === 0) return <Empty msg="No game servers registered." />;
  return (
    <table>
      <thead>
        <tr>
          <th>GS ID</th>
          <th>Address</th>
          <th>Live games</th>
          <th>Max games</th>
        </tr>
      </thead>
      <tbody>
        {data.map((g) => (
          <tr key={g.gsid}>
            <td className="mono">{g.gsid}</td>
            <td className="mono">{g.addr}</td>
            <td>{g.live_games}</td>
            <td>{g.maxgame}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function Games() {
  const { data, err, reload } = usePoll<Game[]>(api.games);
  const [busy, setBusy] = useState<string | null>(null);
  const close = async (name: string) => {
    if (!confirm(`Close game "${name}"?`)) return;
    setBusy(name);
    try {
      await api.closeGame(name);
      await reload();
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };
  if (err) return <Banner msg={err} />;
  if (!data) return <p className="muted">Loading…</p>;
  if (data.length === 0) return <Empty msg="No active games." />;
  return (
    <table>
      <thead>
        <tr>
          <th>Name</th>
          <th>Game ID</th>
          <th>GS ID</th>
          <th>Address</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        {data.map((g) => (
          <tr key={`${g.gsid}:${g.gameid}`}>
            <td>{g.name}</td>
            <td>{g.gameid}</td>
            <td className="mono">{g.gsid}</td>
            <td className="mono">{g.ip}</td>
            <td>
              <button
                className="danger"
                disabled={busy === g.name}
                onClick={() => close(g.name)}
              >
                {busy === g.name ? "Closing…" : "Close"}
              </button>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function Accounts(props: { me: Me }) {
  const { data, err, reload } = usePoll<{ accounts: Account[] }>(api.accounts);
  const [busy, setBusy] = useState<string | null>(null);

  const toggle = async (a: Account) => {
    setBusy(a.name);
    try {
      await api.setAdmin(a.name, !a.admin);
      await reload();
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className="cols">
      <div>
        <h2>Accounts</h2>
        {err ? (
          <Banner msg={err} />
        ) : !data ? (
          <p className="muted">Loading…</p>
        ) : data.accounts.length === 0 ? (
          <Empty msg="No accounts." />
        ) : (
          <ul className="list">
            {data.accounts.map((a) => {
              const isSelf =
                a.name.toLowerCase() === props.me.name.toLowerCase();
              return (
                <li key={a.name} className="acct">
                  <span>
                    {a.name}
                    {a.admin && <span className="via via-sso">admin</span>}
                  </span>
                  <button
                    className={a.admin ? "ghost" : ""}
                    disabled={busy === a.name || (a.admin && isSelf)}
                    title={
                      a.admin && isSelf ? "you can't demote yourself" : undefined
                    }
                    onClick={() => toggle(a)}
                  >
                    {busy === a.name
                      ? "…"
                      : a.admin
                        ? "Demote"
                        : "Make admin"}
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </div>
      <div className="forms">
        <CreateAccount onDone={reload} />
        <CopyChar />
      </div>
    </section>
  );
}

function CreateAccount(props: { onDone: () => void }) {
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [admin, setAdmin] = useState(false);
  return (
    <ActionForm
      title="Create account"
      submitLabel="Create"
      disabled={!name.trim() || !password}
      onSubmit={async () => {
        await api.createAccount(name.trim(), password, admin);
        setName("");
        setPassword("");
        setAdmin(false);
        props.onDone();
        return admin ? "Admin account created." : "Account created.";
      }}
    >
      <input
        placeholder="account name"
        value={name}
        onChange={(e) => setName(e.target.value)}
      />
      <input
        type="password"
        placeholder="password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />
      <label className="check">
        <input
          type="checkbox"
          checked={admin}
          onChange={(e) => setAdmin(e.target.checked)}
        />
        web-UI admin
      </label>
    </ActionForm>
  );
}

function CopyChar() {
  const [f, setF] = useState({
    src_account: "",
    src_char: "",
    dst_char: "",
    dst_account: "",
  });
  const upd = (k: keyof typeof f) => (e: { target: { value: string } }) =>
    setF({ ...f, [k]: e.target.value });
  return (
    <ActionForm
      title="Copy character"
      submitLabel="Copy"
      disabled={!f.src_account.trim() || !f.src_char.trim() || !f.dst_char.trim()}
      onSubmit={async () => {
        await api.copyChar({
          src_account: f.src_account.trim(),
          src_char: f.src_char.trim(),
          dst_char: f.dst_char.trim(),
          dst_account: f.dst_account.trim() || undefined,
        });
        setF({ src_account: "", src_char: "", dst_char: "", dst_account: "" });
        return "Character copied.";
      }}
    >
      <input placeholder="source account" value={f.src_account} onChange={upd("src_account")} />
      <input placeholder="source character" value={f.src_char} onChange={upd("src_char")} />
      <input placeholder="new character name" value={f.dst_char} onChange={upd("dst_char")} />
      <input
        placeholder="dest account (optional)"
        value={f.dst_account}
        onChange={upd("dst_account")}
      />
    </ActionForm>
  );
}

function ActionForm(props: {
  title: string;
  submitLabel: string;
  disabled?: boolean;
  onSubmit: () => Promise<string>;
  children: React.ReactNode;
}) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setMsg(null);
    try {
      setMsg({ ok: true, text: await props.onSubmit() });
    } catch (err) {
      setMsg({ ok: false, text: err instanceof Error ? err.message : String(err) });
    } finally {
      setBusy(false);
    }
  };
  return (
    <form className="card form" onSubmit={submit}>
      <h3>{props.title}</h3>
      {props.children}
      <button disabled={busy || props.disabled}>
        {busy ? "Working…" : props.submitLabel}
      </button>
      {msg && <p className={msg.ok ? "ok" : "error"}>{msg.text}</p>}
    </form>
  );
}

function Banner(props: { msg: string }) {
  return <div className="error banner">{props.msg}</div>;
}
function Empty(props: { msg: string }) {
  return <p className="muted">{props.msg}</p>;
}

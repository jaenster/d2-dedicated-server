// Typed client over realmd's /admin/* JSON API (see src/realm/server/admin.zig).
// Auth is cookie-based: POST /admin/login sets an HMAC-signed session cookie; every
// request rides on it (credentials: same-origin). When realmd is behind an SSO
// forward-auth proxy, /admin/me is already authenticated upstream and no login form
// is shown.

export interface Status {
  sessions: number;
  games: number;
  gameservers: number;
  instance: string;
  durable: string;
  ephemeral: string;
}

export interface GameServer {
  gsid: string;
  addr: string;
  maxgame: number;
  live_games: number;
}

export interface Game {
  name: string;
  gameid: number;
  gsid: string;
  ip: string;
}

export interface Me {
  name: string;
  via: "session" | "sso" | "token";
}

export interface Account {
  name: string;
  admin: boolean;
}

export class ApiError extends Error {
  constructor(
    public status: number,
    public detail: string,
  ) {
    super(detail || `HTTP ${status}`);
  }
}

async function req<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method,
    credentials: "same-origin",
    headers: body !== undefined ? { "Content-Type": "application/json" } : {},
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data: unknown = undefined;
  try {
    data = text ? JSON.parse(text) : undefined;
  } catch {
    /* non-JSON body (shouldn't happen on /admin) */
  }
  if (!res.ok) {
    const detail =
      (data as { error?: string } | undefined)?.error ?? text ?? res.statusText;
    throw new ApiError(res.status, detail);
  }
  return data as T;
}

export const api = {
  me: () => req<Me>("GET", "/admin/me"),
  login: (name: string, password: string) =>
    req<Me>("POST", "/admin/login", { name, password }),
  logout: () => req<{ ok: boolean }>("POST", "/admin/logout"),

  status: () => req<Status>("GET", "/admin/status"),
  gameservers: () => req<GameServer[]>("GET", "/admin/gameservers"),
  games: () => req<Game[]>("GET", "/admin/games"),
  accounts: () => req<{ accounts: Account[] }>("GET", "/admin/accounts"),

  createAccount: (name: string, password: string, admin = false) =>
    req<{ created: boolean }>("POST", "/admin/accounts", { name, password, admin }),
  setAdmin: (name: string, admin: boolean) =>
    req<{ name: string; admin: boolean }>("POST", "/admin/accounts/admin", {
      name,
      admin,
    }),
  closeGame: (name: string) =>
    req<{ closed: boolean }>("POST", "/admin/games/close", { name }),
  copyChar: (p: {
    src_account: string;
    src_char: string;
    dst_char: string;
    dst_account?: string;
  }) => req<{ copied: boolean }>("POST", "/admin/chars/copy", p),
};

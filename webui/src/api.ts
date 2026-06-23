// Typed client over realmd's /admin/* JSON API (see src/realm/server/admin.zig).
// Every call carries the bearer token (REALMD_ADMIN_TOKEN); the API is 403 when
// admin is disabled and 401 on a wrong token.

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

export class ApiError extends Error {
  constructor(
    public status: number,
    public detail: string,
  ) {
    super(detail || `HTTP ${status}`);
  }
}

const TOKEN_KEY = "realmd.admin.token";

export function getToken(): string {
  return sessionStorage.getItem(TOKEN_KEY) ?? "";
}
export function setToken(t: string): void {
  if (t) sessionStorage.setItem(TOKEN_KEY, t);
  else sessionStorage.removeItem(TOKEN_KEY);
}

async function req<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method,
    headers: {
      Authorization: `Bearer ${getToken()}`,
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
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
  status: () => req<Status>("GET", "/admin/status"),
  gameservers: () => req<GameServer[]>("GET", "/admin/gameservers"),
  games: () => req<Game[]>("GET", "/admin/games"),
  accounts: () => req<{ accounts: string[] }>("GET", "/admin/accounts"),

  createAccount: (name: string, password: string) =>
    req<{ created: boolean }>("POST", "/admin/accounts", { name, password }),
  closeGame: (name: string) =>
    req<{ closed: boolean }>("POST", "/admin/games/close", { name }),
  copyChar: (p: {
    src_account: string;
    src_char: string;
    dst_char: string;
    dst_account?: string;
  }) => req<{ copied: boolean }>("POST", "/admin/chars/copy", p),
};

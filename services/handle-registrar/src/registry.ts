// HandleRegistry Durable Object: the single source of truth for handle
// bindings plus per-IP rate counters, backed by DO SQLite.
//
// One named instance serves the whole domain. That serializes every
// registration, which is exactly what first-come-first-served needs: no
// two requests can race the same handle, and the DNS write happens inside
// the same single-threaded critical section as the row commit, so we never
// persist a binding whose DNS state we don't know.
//
// The FCFS/idempotency rules live in the pure `decideRegistration` below so
// they stay unit-testable without the Workers runtime; the DO only wires
// them to storage and DNS.

import type { Env } from "./index";
import { upsertTxtRecord } from "./dns";

/** One pubkey may squat at most this many handles. */
export const MAX_HANDLES_PER_PUBKEY = 3;

export const RATE_LIMIT_MAX = 5;
export const RATE_LIMIT_WINDOW_S = 60;

export interface ExistingBinding {
  pubkey: string;
  /** created_at of the last accepted registration event (monotonic anchor). */
  createdAt: number;
}

export interface IncomingRegistration {
  pubkey: string;
  createdAt: number;
  /** Handles this pubkey already owns (excluding the one being registered). */
  ownedHandleCount: number;
}

export type RegistrationDecision =
  | { ok: true; action: "create" | "update" }
  | { ok: false; error: "handle_taken" | "replayed_event" | "too_many_handles"; status: 409 | 400 };

/**
 * FCFS + idempotent-update + replay rules:
 * - unclaimed handle -> create (unless the pubkey is at its handle cap)
 * - claimed by someone else -> handle_taken
 * - claimed by the same pubkey -> update, but only with a strictly newer
 *   created_at, so a captured register event can never be replayed to
 *   restore a stale offer.
 */
export function decideRegistration(
  existing: ExistingBinding | null,
  incoming: IncomingRegistration,
): RegistrationDecision {
  if (existing === null) {
    if (incoming.ownedHandleCount >= MAX_HANDLES_PER_PUBKEY) {
      return { ok: false, error: "too_many_handles", status: 400 };
    }
    return { ok: true, action: "create" };
  }
  if (existing.pubkey !== incoming.pubkey) {
    return { ok: false, error: "handle_taken", status: 409 };
  }
  if (incoming.createdAt <= existing.createdAt) {
    return { ok: false, error: "replayed_event", status: 400 };
  }
  return { ok: true, action: "update" };
}

// --- Internal worker<->DO wire types (never exposed publicly) ---

export interface DoRegisterRequest {
  handle: string;
  pubkey: string;
  createdAt: number;
  offer: string | null;
}

export interface DoRegisterResponse {
  created: boolean;
  /** True when the stored record now carries an offer (DNS record exists). */
  hasOffer: boolean;
}

export interface DoRateLimitResponse {
  allowed: boolean;
  retryAfterSeconds: number;
}

export interface DoLookupResponse {
  found: boolean;
  pubkey: string | null;
  offer: string | null;
}

// A `type` (not interface) so it satisfies SqlStorage's Record constraint
// via TypeScript's implicit index signature for anonymous object types.
type HandleRow = {
  pubkey: string;
  offer: string | null;
  created_at: number;
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export class HandleRegistry implements DurableObject {
  private readonly sql: SqlStorage;

  constructor(state: DurableObjectState, private readonly env: Env) {
    this.sql = state.storage.sql;
    // created_at mirrors the latest accepted event's created_at (the
    // monotonic replay anchor); updated_at is server wall-clock seconds.
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS handles (
        handle TEXT PRIMARY KEY,
        pubkey TEXT NOT NULL,
        offer TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_handles_pubkey ON handles(pubkey);
      CREATE TABLE IF NOT EXISTS rate (
        ip TEXT PRIMARY KEY,
        window_start INTEGER NOT NULL,
        count INTEGER NOT NULL,
        prev_count INTEGER NOT NULL DEFAULT 0
      );
    `);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (request.method === "POST" && url.pathname === "/rate-limit") {
        return this.handleRateLimit(await request.json<{ ip: string }>());
      }
      if (request.method === "POST" && url.pathname === "/register") {
        return await this.handleRegister(await request.json<DoRegisterRequest>());
      }
      if (request.method === "GET" && url.pathname.startsWith("/lookup/")) {
        return this.handleLookup(decodeURIComponent(url.pathname.slice("/lookup/".length)));
      }
      return json({ error: "not_found" }, 404);
    } catch {
      return json({ error: "internal_error" }, 500);
    }
  }

  private handleRateLimit(body: { ip: string }): Response {
    const ip = String(body.ip ?? "unknown").slice(0, 64);
    const now = Math.floor(Date.now() / 1000);

    // Windows two generations old are dead weight.
    this.sql.exec("DELETE FROM rate WHERE window_start < ?", now - 2 * RATE_LIMIT_WINDOW_S);

    const row = this.sql
      .exec<{ window_start: number; count: number; prev_count: number }>(
        "SELECT window_start, count, prev_count FROM rate WHERE ip = ?",
        ip,
      )
      .toArray()[0];

    // Sliding-window approximation over two adjacent fixed windows: weight the
    // previous window by how much of it still overlaps the trailing 60s. A
    // plain fixed window would allow a 2x burst across the boundary (5 at the
    // end of one window + 5 at the start of the next).
    let windowStart = now;
    let count = 0;
    let prevCount = 0;
    if (row) {
      const age = now - row.window_start;
      if (age < RATE_LIMIT_WINDOW_S) {
        windowStart = row.window_start;
        count = row.count;
        prevCount = row.prev_count;
      } else if (age < 2 * RATE_LIMIT_WINDOW_S) {
        // Rolled into the next window: current becomes previous.
        prevCount = row.count;
      }
    }
    const overlap = 1 - (now - windowStart) / RATE_LIMIT_WINDOW_S;
    const effective = count + prevCount * overlap;

    if (effective >= RATE_LIMIT_MAX) {
      const retryAfterSeconds = Math.max(1, windowStart + RATE_LIMIT_WINDOW_S - now);
      return json({ allowed: false, retryAfterSeconds } satisfies DoRateLimitResponse);
    }

    this.sql.exec(
      "INSERT INTO rate (ip, window_start, count, prev_count) VALUES (?, ?, ?, ?) " +
        "ON CONFLICT(ip) DO UPDATE SET window_start = excluded.window_start, " +
        "count = excluded.count, prev_count = excluded.prev_count",
      ip,
      windowStart,
      count + 1,
      prevCount,
    );
    return json({ allowed: true, retryAfterSeconds: 0 } satisfies DoRateLimitResponse);
  }

  private async handleRegister(body: DoRegisterRequest): Promise<Response> {
    const { handle, pubkey, createdAt, offer } = body;

    const existingRow = this.sql
      .exec<HandleRow>("SELECT pubkey, offer, created_at FROM handles WHERE handle = ?", handle)
      .toArray()[0];

    const ownedHandleCount = Number(
      this.sql
        .exec<{ n: number }>("SELECT COUNT(*) AS n FROM handles WHERE pubkey = ?", pubkey)
        .one().n,
    );

    const decision = decideRegistration(
      existingRow ? { pubkey: existingRow.pubkey, createdAt: existingRow.created_at } : null,
      { pubkey, createdAt, ownedHandleCount },
    );
    if (!decision.ok) {
      return json({ error: decision.error }, decision.status);
    }

    // DNS first, persist second: if the upstream write fails we return 502
    // and leave the record exactly as it was, so the registry never claims
    // an offer that DNS doesn't serve. (For a first-time claim that also
    // means the handle stays unclaimed — the client simply retries.)
    if (offer !== null) {
      // Defense-in-depth: the Worker already ran OFFER_RE, but the DNS TXT
      // write is the one irreversible fund-relevant side effect — re-assert
      // the offer shape here so a future caller of this DO can't skip it.
      if (!/^lno1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{12,2044}$/.test(offer)) {
        return json({ error: "invalid_offer" }, 400);
      }
      if (!this.env.CF_DNS_TOKEN) {
        return json({ error: "dns_not_configured" }, 502);
      }
      const recordName = `${handle}.user._bitcoin-payment.${this.env.BIP353_DOMAIN}`;
      const dns = await upsertTxtRecord({
        zoneId: this.env.ZONE_ID,
        apiToken: this.env.CF_DNS_TOKEN,
        name: recordName,
        content: `bitcoin:?lno=${offer}`,
      });
      if (!dns.ok) {
        return json({ error: "dns_update_failed", detail: dns.error }, 502);
      }
    }

    const now = Math.floor(Date.now() / 1000);
    if (decision.action === "create") {
      this.sql.exec(
        "INSERT INTO handles (handle, pubkey, offer, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        handle,
        pubkey,
        offer,
        createdAt,
        now,
      );
    } else {
      // COALESCE keeps an existing offer alive when a re-register (e.g. a
      // chat-only refresh) arrives without one.
      this.sql.exec(
        "UPDATE handles SET offer = COALESCE(?, offer), created_at = ?, updated_at = ? WHERE handle = ?",
        offer,
        createdAt,
        now,
        handle,
      );
    }

    const hasOffer = offer !== null || (existingRow?.offer ?? null) !== null;
    return json({ created: decision.action === "create", hasOffer } satisfies DoRegisterResponse);
  }

  private handleLookup(handle: string): Response {
    const row = this.sql
      .exec<HandleRow>("SELECT pubkey, offer, created_at FROM handles WHERE handle = ?", handle)
      .toArray()[0];
    if (!row) {
      return json({ found: false, pubkey: null, offer: null } satisfies DoLookupResponse);
    }
    return json({ found: true, pubkey: row.pubkey, offer: row.offer } satisfies DoLookupResponse);
  }
}

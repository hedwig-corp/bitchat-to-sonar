// Cloudflare DNS API client: TXT upsert for BIP-353 records.
//
// fetch is injectable so the module is testable without the Workers runtime
// and so the Durable Object can pass its own fetch if it ever needs to.

export interface TxtUpsertParams {
  zoneId: string;
  apiToken: string;
  /** Fully-qualified record name, e.g. alice.user._bitcoin-payment.sonarprivacy.xyz */
  name: string;
  /** Unquoted TXT payload, e.g. bitcoin:?lno=lno1... (quoting is applied here). */
  content: string;
  ttl?: number;
  fetchImpl?: typeof fetch;
}

export type TxtUpsertResult =
  | { ok: true; recordId: string }
  | { ok: false; error: string };

const API_BASE = "https://api.cloudflare.com/client/v4";
const DEFAULT_TTL = 300;

interface CfApiEnvelope {
  success?: boolean;
  result?: unknown;
  errors?: Array<{ code?: number; message?: string }>;
}

// Never echo the response body wholesale: keep only the first structured
// Cloudflare error so a misconfigured upstream can't reflect junk (or leak
// anything sensitive) into our own error responses.
function summarizeFailure(status: number, body: CfApiEnvelope | null): string {
  const first = body?.errors?.[0];
  if (first) return `cloudflare_api_${status}: [${first.code ?? 0}] ${String(first.message ?? "").slice(0, 200)}`;
  return `cloudflare_api_${status}`;
}

async function readEnvelope(res: Response): Promise<CfApiEnvelope | null> {
  try {
    return (await res.json()) as CfApiEnvelope;
  } catch {
    return null;
  }
}

export interface TxtDeleteParams {
  zoneId: string;
  apiToken: string;
  name: string;
  fetchImpl?: typeof fetch;
}

export type TxtDeleteResult = { ok: true; deleted: number } | { ok: false; error: string };

async function listTxtRecordIds(
  f: typeof fetch,
  base: string,
  name: string,
  headers: Record<string, string>,
): Promise<{ ok: true; ids: string[] } | { ok: false; error: string }> {
  // Paginate so sibling TXT RRs (manual edits / prior bugs) are never left
  // behind — BIP-353 allows exactly one payment-instruction record.
  const ids: string[] = [];
  let page = 1;
  for (;;) {
    let listRes: Response;
    let listBody: CfApiEnvelope | null;
    try {
      listRes = await f(
        `${base}?type=TXT&name=${encodeURIComponent(name)}&per_page=100&page=${page}`,
        { headers },
      );
      listBody = await readEnvelope(listRes);
    } catch {
      return { ok: false, error: "cloudflare_api_unreachable" };
    }
    if (!listRes.ok || listBody?.success !== true) {
      return { ok: false, error: summarizeFailure(listRes.status, listBody) };
    }
    const results = Array.isArray(listBody.result) ? listBody.result : [];
    for (const row of results) {
      const id = (row as { id?: unknown })?.id;
      if (typeof id === "string") ids.push(id);
    }
    if (results.length < 100) break;
    page += 1;
    if (page > 20) break; // hard stop — a payment name should never need this
  }
  return { ok: true, ids };
}

/**
 * Find-existing-then-update-else-create for a single TXT record. BIP-353
 * allows exactly one TXT record at the payment-instruction name, so an
 * existing record is always overwritten rather than appended to. Extra
 * sibling TXT RRs at the same name are deleted after the write.
 */
export async function upsertTxtRecord(params: TxtUpsertParams): Promise<TxtUpsertResult> {
  const f = params.fetchImpl ?? fetch;
  const base = `${API_BASE}/zones/${encodeURIComponent(params.zoneId)}/dns_records`;
  const headers = {
    authorization: `Bearer ${params.apiToken}`,
    "content-type": "application/json",
  };
  // The DNS API expects TXT content in quoted (zone-file) form. Offers are
  // bech32 so the payload can never contain quotes or backslashes itself.
  const record = {
    type: "TXT",
    name: params.name,
    content: `"${params.content}"`,
    ttl: params.ttl ?? DEFAULT_TTL,
  };

  const listed = await listTxtRecordIds(f, base, params.name, headers);
  if (!listed.ok) return listed;
  const existingId = listed.ids[0] ?? null;
  const siblingIds = listed.ids.slice(1);

  try {
    const writeRes = await f(existingId ? `${base}/${existingId}` : base, {
      method: existingId ? "PUT" : "POST",
      headers,
      body: JSON.stringify(record),
    });
    const writeBody = await readEnvelope(writeRes);
    if (!writeRes.ok || writeBody?.success !== true) {
      return { ok: false, error: summarizeFailure(writeRes.status, writeBody) };
    }
    // Drop any leftover siblings so resolvers can't pick a stale offer.
    for (const id of siblingIds) {
      try {
        await f(`${base}/${id}`, { method: "DELETE", headers });
      } catch {
        // Best-effort: the primary record already has the new content.
      }
    }
    const result = writeBody.result as { id?: unknown } | undefined;
    return { ok: true, recordId: typeof result?.id === "string" ? result.id : existingId ?? "" };
  } catch {
    return { ok: false, error: "cloudflare_api_unreachable" };
  }
}

/**
 * Delete every TXT record at `name`. Used to compensate when a DNS write
 * landed but the registry row commit failed — otherwise an unclaimed handle
 * can keep serving a payable BIP-353 destination.
 */
export async function deleteTxtRecords(params: TxtDeleteParams): Promise<TxtDeleteResult> {
  const f = params.fetchImpl ?? fetch;
  const base = `${API_BASE}/zones/${encodeURIComponent(params.zoneId)}/dns_records`;
  const headers = {
    authorization: `Bearer ${params.apiToken}`,
    "content-type": "application/json",
  };
  const listed = await listTxtRecordIds(f, base, params.name, headers);
  if (!listed.ok) return listed;
  let deleted = 0;
  for (const id of listed.ids) {
    try {
      const res = await f(`${base}/${id}`, { method: "DELETE", headers });
      const body = await readEnvelope(res);
      if (!res.ok || body?.success !== true) {
        return { ok: false, error: summarizeFailure(res.status, body) };
      }
      deleted += 1;
    } catch {
      return { ok: false, error: "cloudflare_api_unreachable" };
    }
  }
  return { ok: true, deleted };
}

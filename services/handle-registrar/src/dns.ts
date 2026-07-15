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

/**
 * Find-existing-then-update-else-create for a single TXT record. BIP-353
 * allows exactly one TXT record at the payment-instruction name, so an
 * existing record is always overwritten rather than appended to.
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

  let existingId: string | null = null;
  try {
    const listRes = await f(
      `${base}?type=TXT&name=${encodeURIComponent(params.name)}&per_page=1`,
      { headers },
    );
    const listBody = await readEnvelope(listRes);
    if (!listRes.ok || listBody?.success !== true) {
      return { ok: false, error: summarizeFailure(listRes.status, listBody) };
    }
    const results = Array.isArray(listBody.result) ? listBody.result : [];
    const first = results[0] as { id?: unknown } | undefined;
    if (first && typeof first.id === "string") existingId = first.id;
  } catch {
    return { ok: false, error: "cloudflare_api_unreachable" };
  }

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
    const result = writeBody.result as { id?: unknown } | undefined;
    return { ok: true, recordId: typeof result?.id === "string" ? result.id : "" };
  } catch {
    return { ok: false, error: "cloudflare_api_unreachable" };
  }
}

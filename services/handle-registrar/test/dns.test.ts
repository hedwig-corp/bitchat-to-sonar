// Tests the Cloudflare TXT upsert branching (find -> update vs create) and
// failure summarization with an injected fetch — no network, no runtime.

import { describe, expect, it } from "vitest";
import { upsertTxtRecord } from "../src/dns";

const PARAMS = {
  zoneId: "zone123",
  apiToken: "token-never-logged",
  name: "alice.user._bitcoin-payment.sonarprivacy.xyz",
  content: "bitcoin:?lno=lno1pgx9getnw",
};

function cfJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status });
}

interface Call {
  url: string;
  method: string;
  body: string | null;
}

function fakeFetch(responses: Response[], calls: Call[]): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({
      url: String(input),
      method: init?.method ?? "GET",
      body: typeof init?.body === "string" ? init.body : null,
    });
    const next = responses.shift();
    if (!next) throw new Error("unexpected extra fetch");
    return next;
  }) as typeof fetch;
}

describe("upsertTxtRecord", () => {
  it("creates when no record exists (POST, quoted content, ttl 300)", async () => {
    const calls: Call[] = [];
    const result = await upsertTxtRecord({
      ...PARAMS,
      fetchImpl: fakeFetch(
        [cfJson({ success: true, result: [] }), cfJson({ success: true, result: { id: "rec1" } })],
        calls,
      ),
    });
    expect(result).toEqual({ ok: true, recordId: "rec1" });
    expect(calls[0]?.method).toBe("GET");
    expect(calls[0]?.url).toContain("type=TXT");
    expect(calls[1]?.method).toBe("POST");
    const payload = JSON.parse(calls[1]?.body ?? "{}") as Record<string, unknown>;
    expect(payload.content).toBe('"bitcoin:?lno=lno1pgx9getnw"');
    expect(payload.ttl).toBe(300);
    expect(payload.name).toBe(PARAMS.name);
  });

  it("updates in place when a record already exists (PUT to its id)", async () => {
    const calls: Call[] = [];
    const result = await upsertTxtRecord({
      ...PARAMS,
      fetchImpl: fakeFetch(
        [
          cfJson({ success: true, result: [{ id: "existing42" }] }),
          cfJson({ success: true, result: { id: "existing42" } }),
        ],
        calls,
      ),
    });
    expect(result).toEqual({ ok: true, recordId: "existing42" });
    expect(calls[1]?.method).toBe("PUT");
    expect(calls[1]?.url).toContain("/dns_records/existing42");
  });

  it("summarizes API failures without echoing the response wholesale", async () => {
    const result = await upsertTxtRecord({
      ...PARAMS,
      fetchImpl: fakeFetch(
        [cfJson({ success: false, errors: [{ code: 9109, message: "Invalid access token" }] }, 403)],
        [],
      ),
    });
    expect(result).toEqual({ ok: false, error: "cloudflare_api_403: [9109] Invalid access token" });
  });

  it("maps network failures to a stable error code", async () => {
    const failingFetch = (async () => {
      throw new Error("getaddrinfo ENOTFOUND");
    }) as unknown as typeof fetch;
    const result = await upsertTxtRecord({ ...PARAMS, fetchImpl: failingFetch });
    expect(result).toEqual({ ok: false, error: "cloudflare_api_unreachable" });
  });
});

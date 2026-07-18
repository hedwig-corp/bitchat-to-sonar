// Sonar handle registrar — Worker entry point.
//
// One claimed handle serves both identities:
//   - BIP-353 payment address: <handle>@<domain> resolved via the DNS TXT
//     record <handle>.user._bitcoin-payment.<domain> (bitcoin:?lno=<offer>)
//   - NIP-05 Nostr identity: GET /.well-known/nostr.json?name=<handle>
//
// The Worker does all request-shaped validation (signature, freshness,
// handle/domain rules, secret gate); the HandleRegistry Durable Object owns
// state, FCFS arbitration, rate counters, and the DNS write.

import {
  HANDLE_REGEX,
  MAX_BODY_BYTES,
  normalizeHandle,
  parseRegistrationContent,
  timingSafeEqual,
  validateHandle,
  verifyRegistrationEvent,
} from "./nostr";
import type {
  DoLookupResponse,
  DoRateLimitResponse,
  DoRegisterRequest,
  DoRegisterResponse,
} from "./registry";
import { HandleRegistry } from "./registry";

export { HandleRegistry };

export interface Env {
  HANDLE_REGISTRY: DurableObjectNamespace;
  /** Domain handles are claimed under (e.g. sonarprivacy.xyz). */
  BIP353_DOMAIN: string;
  /** Cloudflare zone id for BIP353_DOMAIN — must be filled in wrangler.jsonc. */
  ZONE_ID: string;
  /** Secret: API token with Zone.DNS:Edit on the zone (wrangler secret put CF_DNS_TOKEN). */
  CF_DNS_TOKEN?: string;
  /** Optional secret: when set, /v1/register requires a matching x-register-secret header. */
  REGISTER_SECRET?: string;
  /** Optional: pubkey served for the NIP-05 root identity (name=_). */
  ROOT_PUBKEY?: string;
}

// NIP-05 requires Access-Control-Allow-Origin: * so browser clients can
// verify identities; the /v1 API gets the same treatment for web callers.
const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "content-type, x-register-secret",
  "access-control-max-age": "86400",
};

function json(body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      ...CORS_HEADERS,
      ...extraHeaders,
    },
  });
}

// All handles for the domain live in one named DO instance: that single
// thread is what makes first-come-first-served race-free.
function registryStub(env: Env): DurableObjectStub {
  return env.HANDLE_REGISTRY.get(env.HANDLE_REGISTRY.idFromName("registry:v1"));
}

async function doPost<T>(env: Env, path: string, body: unknown): Promise<{ status: number; body: T }> {
  const res = await registryStub(env).fetch(`https://registry.internal${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: (await res.json()) as T };
}

async function doLookup(env: Env, handle: string): Promise<DoLookupResponse> {
  const res = await registryStub(env).fetch(
    `https://registry.internal/lookup/${encodeURIComponent(handle)}`,
  );
  return (await res.json()) as DoLookupResponse;
}

async function handleRegister(request: Request, env: Env): Promise<Response> {
  // Secret gate first: during a closed pilot nothing else should be
  // observable (not even rate-limit behavior) without the secret.
  if (env.REGISTER_SECRET) {
    const provided = request.headers.get("x-register-secret") ?? "";
    if (!timingSafeEqual(provided, env.REGISTER_SECRET)) {
      return json({ error: "unauthorized" }, 401);
    }
  }

  // Rate-limit before signature verification so a flood can't buy free
  // schnorr work.
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const rl = await doPost<DoRateLimitResponse>(env, "/rate-limit", { ip });
  if (!rl.body.allowed) {
    return json({ error: "rate_limited" }, 429, {
      "retry-after": String(rl.body.retryAfterSeconds),
    });
  }

  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_BODY_BYTES) {
    return json({ error: "body_too_large" }, 400);
  }
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) {
    return json({ error: "body_too_large" }, 400);
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const verified = verifyRegistrationEvent(raw, nowSeconds);
  if (!verified.ok) {
    return json({ error: verified.error }, 400);
  }
  const event = verified.value;

  const parsedContent = parseRegistrationContent(event.content);
  if (!parsedContent.ok) {
    return json({ error: parsedContent.error }, 400);
  }
  const content = parsedContent.value;

  if (content.domain !== env.BIP353_DOMAIN.toLowerCase()) {
    return json({ error: "domain_mismatch" }, 403);
  }

  const validatedHandle = validateHandle(content.handle);
  if (!validatedHandle.ok) {
    return json({ error: validatedHandle.error }, 400);
  }
  const handle = validatedHandle.value;

  const registerBody: DoRegisterRequest = {
    handle,
    pubkey: event.pubkey,
    createdAt: event.created_at,
    offer: content.offer,
  };
  const result = await doPost<DoRegisterResponse | { error: string }>(
    env,
    "/register",
    registerBody,
  );
  if (result.status !== 200) {
    return json(result.body, result.status);
  }
  const registered = result.body as DoRegisterResponse;

  // record/dnssec are only meaningful once an offer exists: a chat-only
  // claim has no DNS record yet, so we report null instead of pretending.
  const record = `${handle}.user._bitcoin-payment.${env.BIP353_DOMAIN}`;
  return json({
    address: `${handle}@${env.BIP353_DOMAIN}`,
    record: registered.hasOffer ? record : null,
    owner_pubkey: event.pubkey,
    nip05: true,
    dnssec: registered.hasOffer ? { enabled: true } : null,
  });
}

async function handleNostrJson(url: URL, env: Env): Promise<Response> {
  // Positive hits may be edge-cached briefly; empty maps must not — a
  // pre-claim miss cached for 60s would make a just-registered handle look
  // unregistered to verify_nip05 / resolve_handle.
  const positiveHeaders = { "cache-control": "public, max-age=60" };
  const negativeHeaders = { "cache-control": "no-store" };
  const name = normalizeHandle(url.searchParams.get("name") ?? "");

  if (name === "") {
    return json({ names: {} }, 200, negativeHeaders);
  }
  // "_" is the NIP-05 root identity for the bare domain; only serve it when
  // the operator explicitly configured one.
  if (name === "_") {
    return env.ROOT_PUBKEY
      ? json({ names: { _: env.ROOT_PUBKEY } }, 200, positiveHeaders)
      : json({ names: {} }, 200, negativeHeaders);
  }
  // Unknown or malformed names are an empty map, not an error — NIP-05
  // clients treat any non-200 as a hard failure.
  if (!HANDLE_REGEX.test(name)) {
    return json({ names: {} }, 200, negativeHeaders);
  }

  const lookup = await doLookup(env, name);
  if (!lookup.found || lookup.pubkey === null) {
    return json({ names: {} }, 200, negativeHeaders);
  }
  return json({ names: { [name]: lookup.pubkey } }, 200, positiveHeaders);
}

async function handleResolve(rawHandle: string, env: Env): Promise<Response> {
  const validated = validateHandle(decodeURIComponent(rawHandle));
  if (!validated.ok) {
    // Reserved names can never be registered, so for resolution they are
    // simply "not found" rather than an input error.
    if (validated.error === "reserved_handle") {
      return json({
        address: `${normalizeHandle(decodeURIComponent(rawHandle))}@${env.BIP353_DOMAIN}`,
        found: false,
        pubkey: null,
        uri: null,
      });
    }
    return json({ error: "invalid_handle" }, 400);
  }
  const handle = validated.value;

  const lookup = await doLookup(env, handle);
  return json({
    address: `${handle}@${env.BIP353_DOMAIN}`,
    found: lookup.found,
    pubkey: lookup.pubkey,
    uri: lookup.offer !== null ? `bitcoin:?lno=${lookup.offer}` : null,
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (path === "/.well-known/nostr.json") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      return handleNostrJson(url, env);
    }

    if (path === "/v1/health" || path === "/v1" || path === "/v1/") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      return json({ ok: true, domain: env.BIP353_DOMAIN });
    }

    if (path === "/v1/register") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      return handleRegister(request, env);
    }

    if (path.startsWith("/v1/resolve/")) {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      const rawHandle = path.slice("/v1/resolve/".length);
      if (rawHandle === "" || rawHandle.includes("/")) return json({ error: "not_found" }, 404);
      return handleResolve(rawHandle, env);
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;

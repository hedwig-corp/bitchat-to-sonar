// Pure Nostr event verification + registration-content validation.
//
// Deliberately free of any Workers runtime import so the entire trust
// boundary (signature check, id recomputation, handle/offer validation)
// is unit-testable under plain vitest on Node.

import { schnorr } from "@noble/curves/secp256k1";
import { sha256 } from "@noble/hashes/sha256";
import { bytesToHex, hexToBytes, utf8ToBytes } from "@noble/hashes/utils";

/** Kind reserved for handle registration (ephemeral range, see docs/bip353-registration.md). */
export const REGISTRATION_KIND = 23353;

/** `created_at` must be within this many seconds of server time. */
export const FRESHNESS_WINDOW_S = 600;

/** Request bodies larger than this are rejected before any parsing. */
export const MAX_BODY_BYTES = 8192;

// BOLT12 offers are bech32 ("lno1" + data). Real offers are a few hundred
// chars; the bounds only exist to keep garbage out of DNS, not to parse
// the offer. Charset is the exact bech32 data alphabet.
const OFFER_MIN_LEN = 16;
const OFFER_MAX_LEN = 2048;
const OFFER_RE = /^lno1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]+$/;

// Handle shape mandated by the registrar spec: 1..64 chars, lowercase
// alphanumeric edges, [a-z0-9._-] interior.
export const HANDLE_REGEX = /^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$/;

// Names that would collide with operational mailboxes, the BIP-353 DNS
// namespace itself, or that impersonate the product/operator.
export const RESERVED_HANDLES: ReadonlySet<string> = new Set([
  "admin",
  "administrator",
  "root",
  "support",
  "help",
  "info",
  "sonar",
  "hedwig",
  "www",
  "mail",
  "email",
  "postmaster",
  "hostmaster",
  "webmaster",
  "abuse",
  "security",
  "noreply",
  "no-reply",
  "contact",
  "billing",
  "payments",
  "pay",
  "wallet",
  "bitcoin",
  "lightning",
  "nostr",
  "_bitcoin-payment",
  "bitcoin-payment",
  "wellknown",
  "well-known",
  "user",
  "users",
  "api",
  "registrar",
  "register",
  "official",
  "team",
  "staff",
  "moderator",
  "mod",
  "owner",
  "system",
]);

export interface NostrEvent {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
}

export interface RegistrationContent {
  domain: string;
  handle: string;
  /** null = chat-only claim; a later re-register from the same key adds it. */
  offer: string | null;
}

export type Result<T> = { ok: true; value: T } | { ok: false; error: string };

const ok = <T>(value: T): Result<T> => ({ ok: true, value });
const err = <T>(error: string): Result<T> => ({ ok: false, error });

const HEX_RE = /^[0-9a-f]+$/;

function isHex(s: unknown, len: number): s is string {
  return typeof s === "string" && s.length === len && HEX_RE.test(s);
}

/** NIP-01 event id: sha256 of the canonical [0, pubkey, created_at, kind, tags, content] array. */
export function computeEventId(
  ev: Pick<NostrEvent, "pubkey" | "created_at" | "kind" | "tags" | "content">,
): string {
  const serialized = JSON.stringify([0, ev.pubkey, ev.created_at, ev.kind, ev.tags, ev.content]);
  return bytesToHex(sha256(utf8ToBytes(serialized)));
}

/** BIP-340 schnorr verification of the event id under the x-only pubkey. */
export function verifyEventSignature(ev: NostrEvent): boolean {
  try {
    return schnorr.verify(hexToBytes(ev.sig), hexToBytes(ev.id), hexToBytes(ev.pubkey));
  } catch {
    // hexToBytes throws on odd input; a signature we cannot even parse is
    // just an invalid signature, never a 500.
    return false;
  }
}

/** Structural parse of an untrusted request body into a NostrEvent. */
export function parseEvent(raw: string): Result<NostrEvent> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return err("invalid_json");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return err("invalid_event");
  }
  const obj = parsed as Record<string, unknown>;

  // Hex fields are compared byte-for-byte against a recomputed sha256, so
  // normalize case once here instead of being lenient downstream.
  const id = typeof obj.id === "string" ? obj.id.toLowerCase() : "";
  const pubkey = typeof obj.pubkey === "string" ? obj.pubkey.toLowerCase() : "";
  const sig = typeof obj.sig === "string" ? obj.sig.toLowerCase() : "";
  if (!isHex(id, 64)) return err("invalid_id");
  if (!isHex(pubkey, 64)) return err("invalid_pubkey");
  if (!isHex(sig, 128)) return err("invalid_sig");

  const createdAt = obj.created_at;
  if (typeof createdAt !== "number" || !Number.isSafeInteger(createdAt) || createdAt < 0) {
    return err("invalid_created_at");
  }
  const kind = obj.kind;
  if (typeof kind !== "number" || !Number.isSafeInteger(kind)) return err("invalid_kind");

  const tags = obj.tags;
  if (
    !Array.isArray(tags) ||
    tags.length > 32 ||
    !tags.every(
      (t) => Array.isArray(t) && t.length <= 16 && t.every((v) => typeof v === "string"),
    )
  ) {
    return err("invalid_tags");
  }

  if (typeof obj.content !== "string") return err("invalid_content");

  return ok({
    id,
    pubkey,
    created_at: createdAt,
    kind,
    tags: tags as string[][],
    content: obj.content,
    sig,
  });
}

/**
 * Full verification pipeline for a registration event: structure, kind,
 * freshness window, recomputed id, BIP-340 signature. Monotonic replay
 * protection is per-handle state and therefore lives in the registry.
 */
export function verifyRegistrationEvent(raw: string, nowSeconds: number): Result<NostrEvent> {
  const parsed = parseEvent(raw);
  if (!parsed.ok) return parsed;
  const ev = parsed.value;

  if (ev.kind !== REGISTRATION_KIND) return err("wrong_kind");
  if (Math.abs(nowSeconds - ev.created_at) > FRESHNESS_WINDOW_S) return err("stale_created_at");
  if (computeEventId(ev) !== ev.id) return err("bad_event_id");
  if (!verifyEventSignature(ev)) return err("bad_signature");

  return ok(ev);
}

/** Parse the event `content` payload ({domain, handle, offer?}). */
export function parseRegistrationContent(content: string): Result<RegistrationContent> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    return err("invalid_content_json");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return err("invalid_content_json");
  }
  const obj = parsed as Record<string, unknown>;

  if (typeof obj.domain !== "string" || obj.domain.length === 0 || obj.domain.length > 253) {
    return err("invalid_domain");
  }
  if (typeof obj.handle !== "string" || obj.handle.length === 0 || obj.handle.length > 128) {
    return err("invalid_handle");
  }

  // offer is optional: a user may claim a chat-only handle before the wallet
  // exists. When present it must at least look like a BOLT12 offer, because
  // whatever passes here ends up in a public DNS TXT record.
  let offer: string | null = null;
  if (obj.offer !== undefined && obj.offer !== null && obj.offer !== "") {
    if (typeof obj.offer !== "string") return err("invalid_offer");
    const candidate = obj.offer.trim().toLowerCase();
    if (
      candidate.length < OFFER_MIN_LEN ||
      candidate.length > OFFER_MAX_LEN ||
      !OFFER_RE.test(candidate)
    ) {
      return err("invalid_offer");
    }
    offer = candidate;
  }

  return ok({
    domain: obj.domain.trim().toLowerCase(),
    handle: obj.handle,
    offer,
  });
}

export function normalizeHandle(raw: string): string {
  return raw.trim().toLowerCase();
}

/** Normalize then validate a handle: shape, DNS-label sanity, reserved list. */
export function validateHandle(raw: string): Result<string> {
  const handle = normalizeHandle(raw);
  if (!HANDLE_REGEX.test(handle)) return err("invalid_handle");
  // The handle becomes DNS labels under user._bitcoin-payment.<domain>:
  // empty labels ("a..b") or labels over 63 octets would produce a record
  // the resolver side can never serve, so reject them up front.
  const labels = handle.split(".");
  if (labels.some((l) => l.length === 0 || l.length > 63)) return err("invalid_handle");
  if (RESERVED_HANDLES.has(handle)) return err("reserved_handle");
  return ok(handle);
}

/**
 * Constant-time-ish string comparison for the pilot secret. Hashing both
 * sides first makes the XOR loop length-independent, so neither length nor
 * prefix match leaks through timing.
 */
export function timingSafeEqual(a: string, b: string): boolean {
  const ha = sha256(utf8ToBytes(a));
  const hb = sha256(utf8ToBytes(b));
  let diff = 0;
  for (let i = 0; i < ha.length; i++) diff |= (ha[i] ?? 0) ^ (hb[i] ?? 0);
  return diff === 0;
}

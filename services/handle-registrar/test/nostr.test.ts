// Unit tests for the pure verification/validation surface. Real BIP-340
// keypairs and signatures (no mocks) so a broken serialization or verify
// call cannot pass silently.

import { describe, expect, it } from "vitest";
import { schnorr } from "@noble/curves/secp256k1";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils";
import {
  computeEventId,
  FRESHNESS_WINDOW_S,
  parseEvent,
  parseRegistrationContent,
  REGISTRATION_KIND,
  timingSafeEqual,
  validateHandle,
  verifyEventSignature,
  verifyRegistrationEvent,
  type NostrEvent,
} from "../src/nostr";

const NOW = 1_752_000_000;
// Sample from the BOLT12 spec: only bech32 data-alphabet chars after "lno1".
const OFFER =
  "lno1pgx9getnwss8vetrw3hhyuckyypwa3eyt44h6txtxquqh7lz5djge4afgfjn7k4rgrkuag0jsd5xvxg";

interface SignOptions {
  kind?: number;
  createdAt?: number;
  content?: string;
  tags?: string[][];
}

function makeSignedEvent(opts: SignOptions = {}): { event: NostrEvent; raw: string } {
  const priv = schnorr.utils.randomPrivateKey();
  const pubkey = bytesToHex(schnorr.getPublicKey(priv));
  const base = {
    pubkey,
    created_at: opts.createdAt ?? NOW,
    kind: opts.kind ?? REGISTRATION_KIND,
    tags: opts.tags ?? [],
    content:
      opts.content ??
      JSON.stringify({ domain: "sonarprivacy.xyz", handle: "alice", offer: OFFER }),
  };
  const id = computeEventId(base);
  const sig = bytesToHex(schnorr.sign(hexToBytes(id), priv));
  const event: NostrEvent = { ...base, id, sig };
  return { event, raw: JSON.stringify(event) };
}

describe("verifyRegistrationEvent", () => {
  it("accepts a well-formed, freshly signed event", () => {
    const { raw, event } = makeSignedEvent();
    const result = verifyRegistrationEvent(raw, NOW);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.value.pubkey).toBe(event.pubkey);
      expect(result.value.id).toBe(event.id);
    }
  });

  it("rejects tampered content (id no longer matches)", () => {
    const { event } = makeSignedEvent();
    const tampered = {
      ...event,
      content: JSON.stringify({ domain: "sonarprivacy.xyz", handle: "mallory", offer: OFFER }),
    };
    const result = verifyRegistrationEvent(JSON.stringify(tampered), NOW);
    expect(result).toEqual({ ok: false, error: "bad_event_id" });
  });

  it("rejects a bad signature even when the id is consistent", () => {
    const { event } = makeSignedEvent();
    // Flip one nibble of the signature; id stays valid so this must fail
    // at the schnorr step, not the id step.
    const corrupted = event.sig.slice(0, -1) + (event.sig.endsWith("0") ? "1" : "0");
    const result = verifyRegistrationEvent(JSON.stringify({ ...event, sig: corrupted }), NOW);
    expect(result).toEqual({ ok: false, error: "bad_signature" });
  });

  it("rejects a signature from a different key", () => {
    const { event } = makeSignedEvent();
    const otherPriv = schnorr.utils.randomPrivateKey();
    const forgedSig = bytesToHex(schnorr.sign(hexToBytes(event.id), otherPriv));
    const result = verifyRegistrationEvent(JSON.stringify({ ...event, sig: forgedSig }), NOW);
    expect(result).toEqual({ ok: false, error: "bad_signature" });
  });

  it("rejects stale created_at (older than the freshness window)", () => {
    const { raw } = makeSignedEvent({ createdAt: NOW - FRESHNESS_WINDOW_S - 1 });
    expect(verifyRegistrationEvent(raw, NOW)).toEqual({ ok: false, error: "stale_created_at" });
  });

  it("rejects created_at too far in the future", () => {
    const { raw } = makeSignedEvent({ createdAt: NOW + FRESHNESS_WINDOW_S + 1 });
    expect(verifyRegistrationEvent(raw, NOW)).toEqual({ ok: false, error: "stale_created_at" });
  });

  it("accepts created_at at the edge of the freshness window", () => {
    const { raw } = makeSignedEvent({ createdAt: NOW - FRESHNESS_WINDOW_S });
    expect(verifyRegistrationEvent(raw, NOW).ok).toBe(true);
  });

  it("rejects the wrong kind", () => {
    const { raw } = makeSignedEvent({ kind: 1 });
    expect(verifyRegistrationEvent(raw, NOW)).toEqual({ ok: false, error: "wrong_kind" });
  });

  it("rejects non-JSON bodies", () => {
    expect(verifyRegistrationEvent("not json {", NOW)).toEqual({ ok: false, error: "invalid_json" });
  });
});

describe("parseEvent field validation", () => {
  it("rejects malformed hex lengths", () => {
    const { event } = makeSignedEvent();
    expect(parseEvent(JSON.stringify({ ...event, pubkey: event.pubkey.slice(0, 63) }))).toEqual({
      ok: false,
      error: "invalid_pubkey",
    });
    expect(parseEvent(JSON.stringify({ ...event, id: event.id + "00" }))).toEqual({
      ok: false,
      error: "invalid_id",
    });
    expect(parseEvent(JSON.stringify({ ...event, sig: "zz".repeat(64) }))).toEqual({
      ok: false,
      error: "invalid_sig",
    });
  });

  it("rejects non-integer created_at and malformed tags", () => {
    const { event } = makeSignedEvent();
    expect(parseEvent(JSON.stringify({ ...event, created_at: 1.5 }))).toEqual({
      ok: false,
      error: "invalid_created_at",
    });
    expect(parseEvent(JSON.stringify({ ...event, tags: [["ok"], "nope"] }))).toEqual({
      ok: false,
      error: "invalid_tags",
    });
  });

  it("normalizes uppercase hex and still verifies", () => {
    const { event } = makeSignedEvent();
    const upper = JSON.stringify({
      ...event,
      id: event.id.toUpperCase(),
      pubkey: event.pubkey.toUpperCase(),
      sig: event.sig.toUpperCase(),
    });
    const parsed = parseEvent(upper);
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.value.id).toBe(event.id);
      expect(verifyEventSignature(parsed.value)).toBe(true);
    }
  });
});

describe("parseRegistrationContent", () => {
  it("accepts content without an offer (chat-only claim)", () => {
    const result = parseRegistrationContent(
      JSON.stringify({ domain: "sonarprivacy.xyz", handle: "alice" }),
    );
    expect(result).toEqual({
      ok: true,
      value: { domain: "sonarprivacy.xyz", handle: "alice", offer: null },
    });
  });

  it("accepts a valid offer and normalizes case", () => {
    const result = parseRegistrationContent(
      JSON.stringify({ domain: "SonarPrivacy.xyz", handle: "alice", offer: OFFER.toUpperCase() }),
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.value.domain).toBe("sonarprivacy.xyz");
      expect(result.value.offer).toBe(OFFER);
    }
  });

  it("rejects offers that are not BOLT12 bech32", () => {
    for (const bad of ["lnbc1abcdef1234567890", "lno1", "lno1 with spaces", "x".repeat(3000)]) {
      const result = parseRegistrationContent(
        JSON.stringify({ domain: "sonarprivacy.xyz", handle: "alice", offer: bad }),
      );
      expect(result).toEqual({ ok: false, error: "invalid_offer" });
    }
  });

  it("rejects missing handle or domain", () => {
    expect(parseRegistrationContent(JSON.stringify({ handle: "alice" }))).toEqual({
      ok: false,
      error: "invalid_domain",
    });
    expect(parseRegistrationContent(JSON.stringify({ domain: "sonarprivacy.xyz" }))).toEqual({
      ok: false,
      error: "invalid_handle",
    });
    expect(parseRegistrationContent("not json")).toEqual({ ok: false, error: "invalid_content_json" });
  });
});

describe("validateHandle", () => {
  it("accepts valid handles", () => {
    const max64WithDot = `${"a".repeat(32)}.${"a".repeat(31)}`;
    for (const h of ["alice", "a", "a1", "a.b", "a_b-c.d", "0x9", "a".repeat(63), max64WithDot]) {
      expect(validateHandle(h)).toEqual({ ok: true, value: h });
    }
  });

  it("rejects a 64-char undotted handle (DNS label limit is 63)", () => {
    expect(validateHandle("a".repeat(64))).toEqual({ ok: false, error: "invalid_handle" });
  });

  it("normalizes case and surrounding whitespace", () => {
    expect(validateHandle("  Alice ")).toEqual({ ok: true, value: "alice" });
  });

  it("rejects bad shapes", () => {
    for (const h of [
      "",
      "-alice",
      "alice-",
      ".alice",
      "alice.",
      "_alice",
      "a..b",
      "al!ce",
      "al ice",
      "a".repeat(65),
      "alice@sonarprivacy.xyz",
    ]) {
      expect(validateHandle(h)).toEqual({ ok: false, error: "invalid_handle" });
    }
  });

  it("rejects reserved names, including after normalization", () => {
    for (const h of ["admin", "ADMIN", "root", "sonar", "hedwig", "postmaster", " Support "]) {
      expect(validateHandle(h)).toEqual({ ok: false, error: "reserved_handle" });
    }
  });
});

describe("timingSafeEqual", () => {
  it("matches equal strings and rejects different ones regardless of length", () => {
    expect(timingSafeEqual("pilot-secret", "pilot-secret")).toBe(true);
    expect(timingSafeEqual("pilot-secret", "pilot-secreT")).toBe(false);
    expect(timingSafeEqual("short", "much-longer-value")).toBe(false);
    expect(timingSafeEqual("", "")).toBe(true);
  });
});

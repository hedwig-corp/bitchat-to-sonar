// Tests for the pure FCFS/idempotency decision the Durable Object executes.
// The DO itself is a thin storage/DNS wiring layer around this function.

import { describe, expect, it } from "vitest";
import { decideRegistration, MAX_HANDLES_PER_PUBKEY } from "../src/registry";

const ALICE = "a".repeat(64);
const MALLORY = "b".repeat(64);
const T = 1_752_000_000;

describe("decideRegistration", () => {
  it("creates when the handle is unclaimed", () => {
    expect(
      decideRegistration(null, { pubkey: ALICE, createdAt: T, ownedHandleCount: 0 }),
    ).toEqual({ ok: true, action: "create" });
  });

  it("enforces the per-pubkey handle cap on create only", () => {
    expect(
      decideRegistration(null, {
        pubkey: ALICE,
        createdAt: T,
        ownedHandleCount: MAX_HANDLES_PER_PUBKEY,
      }),
    ).toEqual({ ok: false, error: "too_many_handles", status: 400 });

    // Updating an owned handle must keep working even at the cap.
    expect(
      decideRegistration(
        { pubkey: ALICE, createdAt: T },
        { pubkey: ALICE, createdAt: T + 1, ownedHandleCount: MAX_HANDLES_PER_PUBKEY },
      ),
    ).toEqual({ ok: true, action: "update" });
  });

  it("rejects a different pubkey with handle_taken (409)", () => {
    expect(
      decideRegistration(
        { pubkey: ALICE, createdAt: T },
        { pubkey: MALLORY, createdAt: T + 100, ownedHandleCount: 0 },
      ),
    ).toEqual({ ok: false, error: "handle_taken", status: 409 });
  });

  it("allows the owner to update with a strictly newer created_at", () => {
    expect(
      decideRegistration(
        { pubkey: ALICE, createdAt: T },
        { pubkey: ALICE, createdAt: T + 1, ownedHandleCount: 1 },
      ),
    ).toEqual({ ok: true, action: "update" });
  });

  it("rejects replayed or reordered events (created_at <= last accepted)", () => {
    for (const createdAt of [T, T - 1]) {
      expect(
        decideRegistration(
          { pubkey: ALICE, createdAt: T },
          { pubkey: ALICE, createdAt, ownedHandleCount: 1 },
        ),
      ).toEqual({ ok: false, error: "replayed_event", status: 400 });
    }
  });
});

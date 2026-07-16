# Group-scale simulation (`sonar-sim`)

A multi-agent swarm that stress-tests the Marmot/MLS group protocol to find the
real group-size ceiling and protocol bugs, using the exact `MarmotEngine` code
the apps ship. No relay I/O: agents hand events to each other in process, in the
order a relay would serialize them, so any failure here is a protocol failure,
not a network flake.

```sh
cargo run -p sonar-sim --release -- group-scale \
  --ramp 2,5,10,25,50,100,130,150 --mode incremental --chaos --out /tmp/scale.json
```

- `--mode incremental` (default): create small, then `add_members` in `--batch`
  chunks — the path real clients take. `--mode create-all` puts every member in
  one creation commit.
- `--chaos`: at each size, race two same-epoch `add_members` commits (two admins
  adding someone at the same instant) and report whether the group converges.
- `--ramp` stops at the first hard failure. Exit code `2` if any step failed.
- NIP-11 `max_message_length` is fetched from the bootstrap + White Noise relays
  to compute a per-relay ceiling (skip with `--no-nip11`).

## What it measures

For each group size N: welcome size (the gift-wrapped kind-1059 the joiner must
receive), evolution/commit size (kind-445), a text-message size, build and
fan-out timings, member-set convergence across all agents, and message delivery
to every member.

## Findings (2026-07, MDK rev `e8cd584`)

### 1. Hard ceiling ≈ 130 members, gated by the welcome — not the relay

`gift_wrap_welcome` fails with `nip44 encryption error: message too long` once a
joining member's welcome plaintext crosses NIP-44's 65535-byte cap. The welcome
carries the full MLS ratchet tree, so it grows ~1 KB per existing member and hits
the cap around 130 members. Past that, **new members cannot be added at all** —
the welcome cannot be sealed, so it never reaches them.

The exact crossing lands in the ~130–150 range and shifts with the add pattern
(`--batch 25` fails adding member ~101; `--batch 5` still succeeds at 135),
because the MLS tree shape — and thus the welcome size — depends on how members
were batched. Treat ~130 as the safe ceiling, not a precise constant.

This is well below every relay limit: the smallest advertised
`max_message_length` across our relays is 131072 B (nos.lol, offchain.pub, both
White Noise relays), which the wrapped welcome (~77 KB) never exceeds. **The
binding constraint is the NIP-44 seal on the welcome, not relay message size.**

| N   | welcome (wrapped) | evolution | build   | result |
| --- | ----------------- | --------- | ------- | ------ |
| 25  | 27.8 KB           | —         | 105 ms  | ok     |
| 50  | 55.1 KB           | 14.3 KB   | 378 ms  | ok     |
| 100 | 77.0 KB           | 19.8 KB   | 1.5 s   | ok     |
| 130 | 77.0 KB           | 16.8 KB   | 7.2 s   | ok     |
| 150 | —                 | —         | —       | welcome too long |

(Wrapped welcome plateaus at ~77 KB because the failing larger welcomes are not
counted; the *plaintext* is what crosses NIP-44's 65535 limit.)

### 2. Concurrent same-epoch add commits fork the group

With `--chaos`, two members each add someone in the same epoch before either
commit is delivered. The relay serializes them: the first commit applies
everywhere; the second is now stale. Result:

- The stale commit is rejected (`Incoming::Failed`) or applied on a divergent
  branch, and the group **forks** — members split into branches with different
  rosters (e.g. populations `[2, 23]` at N=25). Member counts can stay equal
  while the *sets* differ, which is why the sim compares rosters, not counts.
- Members on the losing branch then hit `Failed to decrypt message with any
  exporter secret from epochs 0 to N` — they can no longer read the group.
- This is the expected shape of an MLS epoch fork; the raw engine does **not**
  self-heal. Whatever recovery exists must live in the app/relay-sync layer
  (commit ordering, single-committer election, or re-add of forked members).
  The sim demonstrates the engine alone will not converge, so that recovery
  path needs its own coverage. Filed as a follow-up.

## Caveats

- Deterministic swarm, not LLM-driven agents. The MLS protocol is content-
  agnostic, so scripted sends exercise every protocol path an LLM would; an LLM
  layer would add behavioral realism (who sends what, when) but would not surface
  additional protocol bugs. Kept deterministic for reproducibility and speed.
- In-process delivery models an ideal relay (no drops, no reordering beyond the
  serialization we impose). Real relays add loss and latency on top of these
  limits, so production ceilings are a lower bound of what is measured here.
- Timings are single-machine and indicative, not a device benchmark.

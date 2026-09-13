# Group-scale simulation (`sonar-sim`)

A multi-agent swarm that stress-tests the Marmot/MLS group protocol to find the
real group-size ceiling and protocol bugs, using the exact `MarmotEngine` code
the apps ship. No relay I/O: agents hand events to each other in process, in the
order a relay would serialize them, so any failure here is a protocol failure,
not a network flake.

Part of the benchmark suite — the **protocol scale** track alongside the device
latency harness in [`PERFORMANCE.md`](PERFORMANCE.md). Unlike the phone
benchmarks, this one is **machine-independent**: the ratchet-tree and NIP-44
sizes it measures are the same on any box, so it does not run on a device. Run it
when you **bump the MDK rev** or touch the welcome/commit path.

```sh
cargo run -p sonar-sim --release -- group-scale \
  --ramp 2,5,10,25,50,100,110,120,130 --mode incremental --batch 25 --chaos --out /tmp/scale.json
```

- `--mode incremental` (default): create small, then `add_members` in `--batch`
  chunks — the path real clients take. `--mode create-all` puts every member in
  one creation commit.
- `--batch 25` (the default) is the canonical config the baseline below was
  produced with. The ceiling shifts with batch size (see Findings), so pin it
  when comparing runs.
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

## How to reproduce

No device, no relay account, no secrets. Any machine with the Rust toolchain.

```sh
# 1. The canonical baseline run: ceiling + convergence + live relay limits.
#    Same command and --batch as the baseline table below, so the numbers are
#    directly comparable. Stops at the first hard failure; the last `ok` N is
#    the ceiling.
cargo run -p sonar-sim --release -- group-scale \
  --ramp 2,5,10,25,50,100,110,120,130 \
  --mode incremental --batch 25 --chaos --out /tmp/scale.json

# 2. Explore how the ceiling shifts with the add pattern (offline).
#    Smaller batches reshape the MLS tree and reach a few members higher.
cargo run -p sonar-sim --release -- group-scale \
  --ramp 120,125,130,135,140 --batch 5 --no-nip11

# 3. Unit tests for the pure logic (ceiling math, outcome summary):
cargo test -p sonar-sim
```

Reading the output:

- The per-N table prints `welcome(B)`, `evolution(B)`, `message(B)`,
  `build(ms)`, `fanout(ms)`, and `ok`. The **largest N with `ok=true` is the
  ceiling**; the first failing N prints its reason first (`gift_wrap_welcome:
  … message too long`), ahead of the derivative `never became active` lines.
- With `--chaos`, each N also prints `converged=` and `post_race_fanout_ok=`.
  Both are **expected to be false** on the current engine: two same-epoch adds
  strand the losing invitee, so the swarm forks and the winner's message cannot
  reach the stranded member (see Finding 2). The finding line reports the branch
  populations and how many recipients broke.
- The `relay ceilings` block cross-checks each relay's NIP-11
  `max_message_length` against the measured welcome sizes.
- `--out` writes the full JSON (every error string, all sizes) for diffing.

Interpreting a run against a previous one (the "numbers when updating" case):

- **Structural regressions are what matter** and are deterministic: the ceiling
  N dropped, a previously-`ok` size now fails, `converged` flipped to `false`, or
  welcome bytes/member grew. These are safe to assert on / gate CI with.
- **Timings (`build`, `fanout`) are machine-bound** — compare them only on the
  same box, and treat them as report-only, never a CI gate.
- A moved ceiling after an **MDK rev bump** is the signal to watch: it means the
  wire format changed, which is exactly what can break White Noise interop.

**Current pin: MDK v0.9.14 (`235c8ade`, wire `0xf2f1`).** The live baseline is
[Findings (2026-09-13)](#findings-2026-09-13-mdk-v0914-235c8ade). The 0.8
table under [Findings (2026-07)](#findings-2026-07-mdk-rev-e8cd584) is
historical only.

Reproduce the current baseline (`--no-nip11` keeps the run machine-local;
`--chaos` is expected not to stage on 0.9.14 — see Finding 2):

```sh
cargo run -p sonar-sim --release -- group-scale \
  --ramp 2,5,10,25,50,100,110,120,130 \
  --mode incremental --batch 25 --chaos --no-nip11 \
  --out /tmp/scale-mdk09.json
```

MDK 0.9 leaves kind-445 commits `Buffered` until the MIP-03 quiescence
window (~1.1s). The sim now sleeps that window and calls
`advance_group_convergence` after each `add_members` fan-out. Without
that drain the roster freezes at the founding batch (N=25) and N=50
looks like a false ceiling.

## Reproduce with an agent (prompt)

Paste this to a coding agent (Claude Code / equivalent) in a checkout to
re-measure and report:

> Run the Marmot/MLS group-scale protocol benchmark and tell me if anything
> regressed. Steps:
> 1. `cargo build -p sonar-sim --release` from `core/`.
> 2. Run `cargo run -p sonar-sim --release -- group-scale --ramp
>    2,5,10,25,50,100,110,120,130 --mode incremental --batch 25 --chaos --out
>    /tmp/scale.json`.
> 3. Report: the group-size ceiling (largest N with `ok=true`) and the reason
>    the first failing N failed; the `--chaos` `converged`/`post_race_fanout_ok`
>    values and branch populations; and the welcome-bytes column.
> 4. Compare against the **current-rev** baseline table in
>    `docs/GROUP-SCALE-SIM.md` (v0.9.14 section). Flag structural outcomes
>    (ceiling N, `ok`, `converged`, welcome bytes). Ignore `build`/`fanout`
>    timings (machine-bound). Note the current MDK rev from `core/Cargo.toml`.

## Findings (2026-09-13, MDK v0.9.14 `235c8ade`)

Measured on this PR with `--batch 25 --mode incremental --no-nip11 --chaos`.
`sonar-sim` settles MIP-03 buffered commits after each add-batch.

### 1. Hard ceiling = 50 members, still gated by the welcome NIP-44 seal

The founding wave (N≤25) and the first `add_members` batch (N=50) converge
and fan out. Growing past 50 fails while wrapping the next welcome:

`add_members(at 50): wrap failed: nip44 encryption error: message too long`

Same binding constraint as 0.8 (NIP-44 65535-byte plaintext, not relay
`max_message_length`). The wrapped welcome is already 66 045 B at N=50.
0.8's welcome at N=25 was 27.8 KB; 0.9.14 is 38.7 KB — the `0xf2f1` tree
is heavier, so the ceiling moved **120 → 50**.

Baseline — `--batch 25`, MDK v0.9.14 `235c8ade`:

| N   | welcome (wrapped) | evolution | build    | result |
| --- | ----------------- | --------- | -------- | ------ |
| 2   | 5.3 KB            | —         | 0.45 s   | ok     |
| 5   | 11.4 KB           | —         | 0.52 s   | ok     |
| 10  | 16.9 KB           | —         | 0.83 s   | ok     |
| 25  | 38.7 KB           | —         | 2.4 s    | ok     |
| 50  | 66.0 KB           | 18.6 KB   | 16.8 s   | ok     |
| 100 | 66.0 KB           | 19.2 KB   | 17.4 s   | welcome too long |

Build timings are machine-bound. Treat 50 as the safe default-config
ceiling until a smaller `--batch` (or a welcome-format change) is
re-measured. Re-verify White Noise interop at N≈25 and N≈50 before
calling the ceiling a product limit.

### 2. Concurrent same-epoch add commits do not stage

`--chaos` could not create two in-flight `add_members` commits on the
same epoch (`concurrent add_members failed to stage` at every N). This
is **not** the 0.8 fork (`converged=false` with populations like
`[121, 1]`). 0.9.14 refuses the second staging instead of accepting a
rival commit. `converged` and `post_race_fanout_ok` stay `false`
because the race never starts. A future engine that stages both and
self-heals would flip those to `true`; an engine that stages both and
forks would look like the 0.8 finding again.

## Findings (2026-07, MDK rev `e8cd584` — 0.8 historical baseline)

> Historical only. **Do not treat this table as the v0.9.14 baseline.** The
> protocol profile and welcome/commit encoding changed with the MDK 0.9 port.

### 1. Hard ceiling ≈ 120 members, gated by the welcome — not the relay

`gift_wrap_welcome` fails with `nip44 encryption error: message too long` once a
joining member's welcome plaintext crosses NIP-44's 65535-byte cap. The welcome
carries the full MLS ratchet tree, so it grows ~1 KB per existing member. With
the canonical `--batch 25` config the group tops out at **120 members**; the very
next batch (adding members past ~120) can no longer seal its welcome, so **new
members cannot be added at all** — the welcome never reaches them.

The exact crossing shifts with the add pattern: `--batch 25` tops out at 120,
while smaller `--batch 5` reshapes the MLS tree and reaches ~135. Treat ~120 as
the safe ceiling for the default config, not a precise constant.

This is well below every relay limit: the smallest advertised
`max_message_length` across our relays is 131072 B (nos.lol, offchain.pub, both
White Noise relays), which the wrapped welcome (~77 KB) never exceeds. **The
binding constraint is the NIP-44 seal on the welcome, not relay message size.**

Baseline — `--batch 25`, MDK rev `e8cd584`:

| N   | welcome (wrapped) | evolution | build   | result |
| --- | ----------------- | --------- | ------- | ------ |
| 25  | 27.8 KB           | —         | 0.35 s  | ok     |
| 50  | 55.1 KB           | 14.3 KB   | 2.1 s   | ok     |
| 100 | 77.0 KB           | 19.8 KB   | 5.0 s   | ok     |
| 110 | 77.0 KB           | 20.2 KB   | 3.8 s   | ok     |
| 120 | 77.0 KB           | 20.4 KB   | 2.9 s   | ok     |
| 130 | —                 | 23.0 KB   | 3.6 s   | welcome too long |

(Wrapped welcome plateaus at ~77 KB because the failing larger welcomes are not
counted; the *plaintext* is what crosses NIP-44's 65535 limit. Build timings are
machine-bound — compare only on the same box.)

### 2. Concurrent same-epoch add commits fork the group

With `--chaos`, two members each add a fresh invitee in the same epoch before
either commit is delivered. The relay serializes them: the first commit applies
everywhere; the second is now stale. The sim delivers **both** invitees' welcomes
and folds them into the swarm, so the losing invitee is measured, not dropped.
Result (deterministic on the current engine):

- The winning commit's invitee joins the surviving branch; the losing commit's
  invitee joins an **orphan branch** of its own, so the swarm **forks** —
  populations like `[121, 1]` at N=120 (121 on the surviving branch, the stranded
  invitee alone). Member counts can stay equal while the *sets* differ, which is
  why the sim compares rosters, not counts.
- The stranded invitee then hits `Failed to decrypt message with any exporter
  secret …` when the winner sends — it can no longer read the group. `converged`
  and `post_race_fanout_ok` are therefore both `false` every run; a future engine
  that self-heals would flip them to `true`, which is the regression signal.
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

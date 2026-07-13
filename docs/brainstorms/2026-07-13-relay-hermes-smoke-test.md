# Daily relay smoke test: Hermes + sonar-cli against hedwig

Date: 2026-07-13
Status: decided — **Approach A (deterministic daily gate) + Approach B (Hermes exploratory layer)**

## Context findings (research, July 2026)

1. **Hermes is not built into Sonar.** It is an external agent runtime (Nous Research)
   that drives the headless **`sonar-cli`** binary in this repo (`core/sonar-cli`).
   Integration is a thin JSON-lines contract. Three run modes: **A** gateway plugin,
   **B** Python bridge, **C** cron + `listen --once` (`docs/HERMES-AGENT.md`,
   `core/sonar-cli/hermes/SKILL.md`). Transport is **relay-only** — no BLE.
2. **`sonar-cli` is DM-only today.** `send --to <npub>` creates/finds a *1:1* group
   (`start_dm`). There is **no command to create or message multi-member MLS
   groups**. So "a sequence of groups" maps cleanly to **pairwise 1:1 chats**.
   True multi-member groups are a separate CLI feature change (see Follow-ups).
3. **Forcing a single relay** = pass `--relay wss://nostr.relay.hedwig.sh` on every
   command (overrides config). CLI defaults are damus/nos.lol/primal
   (`core/sonar-cli/src/main.rs:DEFAULT_RELAYS`). `nostr.relay.hedwig.sh` is already
   in the `sonar-status` probe set, so it is a known-good target.
4. **"Report with sonar at the npub"** = the test owns a **persistent sender/reporter
   identity** (an `nsec`, gitignored / CI secret — Local Secrets Rule), publishes a
   KeyPackage, and DMs `npub10srglj0rdsmtehwlflxptwz74c955c2y7jrhdmjm5gr6gycpsp5sg3fm3c`
   a summary via `sonar-cli send --to`. **Prerequisite:** the report recipient must
   have a KeyPackage published to `wss://nostr.relay.hedwig.sh` so the MLS 1:1 group
   can be created (else the DM cannot land).
5. **Existing perf infra is app-cold-start** (`scripts/bench/`, `SONAR_BENCH` markers,
   `docs/PERFORMANCE.md`). A *relay* smoke test measures different signals (EOSE,
   send→deliver latency, loss, ordering) and is a separate concern — do not fold them
   together.
6. **No daily smoke workflow exists yet.** `.github/workflows/` has core-tests /
   pages / pr-review only. `scripts/smoke/conversation-regressions.sh` is app-UI
   regression, not relay health.

## Decisions taken (user)

- **A + B together.** Approach A is the daily deterministic regression gate;
  Approach B is an optional, on-demand Hermes-driven exploratory layer stacked on
  top (triage + qualitative probing), **not** the gate itself.
- **Groups = pairwise 1:1 DMs.** Multi-member MLS groups are out of scope here
  (needs a new `sonar-cli` command — tracked as a follow-up).
- **Orchestrator for the gate is a deterministic script** over `sonar-cli`, not the
  LLM. Hermes is reserved for the adaptive/expploratory path (B).
- **Runs on GitHub Actions** (scheduled cron) for A; B runs on an operator host with
  Hermes installed.

## Clarified Problem Statement

**Goal:** A daily automated smoke test that exercises Sonar/Marmot messaging against
`wss://nostr.relay.hedwig.sh` with a random (but seeded-reproducible) set of
identities chatting in pairwise groups, measures relay delivery/performance, DMs a
report to `npub10srglj…`, and opens a GitHub issue on regression — plus an optional
Hermes-driven exploratory layer for adaptive triage.

**Constraints**
- Relay-only transport (Marmot/MLS over Nostr); single relay pinned for the whole run.
- Sender / reporter `nsec` stays in a CI secret or gitignored config — **never
  committed** (Local Secrets Rule).
- This is background tooling, not a chat-path change; it must not weaken
  Signal-comparable local-first assumptions in the apps.
- Determinism: the gate uses a **seeded RNG** so a given seed reproduces the exact
  topology/message set (cheap to rerun a failure).
- Hermes (B) never blocks or invalidates the A gate.

**Non-goals**
- App cold-start benchmark (already covered by `scripts/bench/` + `docs/PERFORMANCE.md`).
- BLE mesh transport.
- Multi-relay fanout (single relay only).
- App UI tests (covered by `scripts/smoke/conversation-regressions.sh`).
- Multi-member MLS groups (out of scope; see Follow-ups).

**Success criteria**
- Green daily GitHub Actions workflow that completes end-to-end.
- Report DM lands at `npub10srglj…` each run (verified by `sent` JSON).
- A GitHub issue opens **only** when a measured signal crosses a threshold.
- Per-run metrics JSON uploaded as a workflow artifact for trend tracking.
- Low flake rate so the gate is trustworthy (retry-on-transient, thresholds with
  headroom, seeded reproducibility).
- B can be triggered by an operator and posts a human-readable triage DM + (optional)
  issue comment.

## Approach A — Deterministic harness over `sonar-cli` (the gate)

A new harness provisions N ephemeral identities, builds a random pairwise-DM graph,
exchanges a seeded message set — all pinned to `wss://nostr.relay.hedwig.sh` —
measures, reports, and files issues. Implemented as a bash orchestrator (matches
`scripts/smoke/conversation-regressions.sh` style) driving the `sonar-cli` binary.

### Run flow (per scheduled invocation)

1. **Build/cache** `sonar-cli` release binary (GH Action caches `cargo`).
2. **Provision N ephemeral identities** (default N=5, seeded): for each, a fresh temp
   `SONAR_CLI_HOME`; `sonar-cli init` (generates a fresh `nsec`); `sonar-cli publish`
   (publish KeyPackage to hedwig); capture `npub` via `sonar-cli identity`.
3. **Establish pairwise DM graph:** a seeded-random subset of pairs; for each pair
   (A,B) A runs `sonar-cli send --to B --text "hello"` (creates the 1:1 group). Every
   command passes `--relay wss://nostr.relay.hedwig.sh`.
4. **Exchange a seeded-random message set:** each scheduled message's sender does
   `send --to <peer> --text "<seq:payload>"`, recording send timestamp; each receiver
   drains with `sonar-cli listen --once` and records inbound `created_at_secs`.
5. **Measure:**
   - relay connect RTT + publish→EOSE timing
   - send→deliver latency (`send_ts` vs received `created_at_secs`)
   - delivery rate (received / sent) and **loss %**
   - ordering (monotonic `seq` in payloads)
   - relay errors (non-zero exits, `sonar-cli: <error>` on stderr, error JSON)
6. **Compare** against configurable thresholds (a `relay-smoke.config.json`) and,
   optionally, the previous run's metrics artifact (regression detection).
7. **Report:** the persistent **reporter identity** (CI secret nsec) re-`init`s each
   run, `publish`es, and DMs `npub10srglj…` a one-line pass/fail + metrics summary via
   `sonar-cli send --to npub10srglj... --text "<summary>"`.
8. **On regression/failure:** `gh issue create` with title, body (config + metrics +
   breached thresholds + the seed for repro), labels (`smoke`, `relay`, `regression`).
9. **Upload** a metrics JSON artifact (`relay-smoke-<date>.json`) for trends.

### Secrets / identity

- Reporter `nsec` → GitHub Actions secret `SONAR_SMOKE_REPORTER_NSEC`. Provisioned once
  locally (`sonar-cli init` → capture nsec to a `0600` file → store as secret).
- Ephemeral test identities are generated fresh each run and discarded (no secret
  storage).
- **Operational prerequisite:** the report recipient `npub10srglj…` must have a
  KeyPackage published to `wss://nostr.relay.hedwig.sh`. Verify before first run.

### Affected files (A)

- `scripts/smoke/relay-smoke.sh` (new) — main harness orchestrator.
- `scripts/smoke/relay-smoke.config.json` (new) — thresholds + scale params (N,
  messages-per-pair, seed handling).
- `.github/workflows/relay-smoke.yml` (new) — `schedule: cron` daily + `workflow_dispatch`.
- `docs/PERFORMANCE.md` — new "Relay smoke test" section (purpose, metrics, how to run
  locally with `workflow_dispatch`, how thresholds are set).
- CI secret `SONAR_SMOKE_REPORTER_NSEC`.
- `docs/HERMES-AGENT.md` or new `docs/RELAY-SMOKE.md` — reporter-identity provisioning
  runbook (one-time, no nsec printed).

**Effort:** M.

## Approach B — Hermes exploratory layer (on-demand triage)

A non-gating layer where an operator triggers Hermes (Mode C: cron + terminal, or a
one-off `hermes run`) to do adaptive/qualitative work on top of A's data:

- read recent smoke metrics / open failures (the metrics artifact + open issues),
- spawn a small number of identities and do **adaptive** probing (varied payloads,
  back-to-back sends, reconnect storms) that the deterministic gate does not cover,
- narrate findings as a natural-language DM to `npub10srglj…`,
- optionally comment on an open regression issue with a hypothesis.

Implemented as a Hermes skill; runs on a host with Hermes + a model provider
installed (not GitHub Actions).

### Affected files (B)

- `core/sonar-cli/hermes/SKILL.md` (extend) — add an exploratory `relay-smoke` capability.
- `docs/HERMES-AGENT.md` (extend) — document the exploratory smoke mode + how it reads
  A's artifacts.
- (optional) host cron entry / `hermes` skill config snippet.

**Effort:** M.

## Recommendation / sequencing

Ship **A first** (it is the regression gate and is self-sufficient on GitHub Actions).
Layer **B** afterward as an operator tool — B depends on A's metrics artifact and
issue stream, so building A first gives B something concrete to read.

## Open questions (non-blocking, can be tuned post-ship)

- Default scale: N=5 identities, ~3 messages per pair, fresh ephemeral each run — tune
  after first week of trend data.
- Regression baseline: fixed thresholds vs "previous-run artifact" delta. Recommend
  fixed thresholds with headroom for v1, switch to delta once a stable baseline exists.
- Issue cadence: open on **failure only** (recommended) vs every run (would create
  noise). Recommend failure-only; always post the DM + artifact.

## Follow-ups (explicitly out of scope, tracked)

- **Multi-member MLS groups in `sonar-cli`**: add `create-group` / `invite` /
  `send-group` so the smoke test can exercise >2-member groups. Separate change; needed
  before "sequence of groups" can mean true multi-member groups.
- **Multi-relay fanout**: extend to a configurable relay set once single-relay is green.

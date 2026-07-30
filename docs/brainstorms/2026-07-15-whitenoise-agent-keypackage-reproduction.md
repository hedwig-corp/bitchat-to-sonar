# White Noise Agent KeyPackage Reproduction

## Clarified Problem Statement

**Goal:** Extend the AI relay-smoke simulation with one ephemeral upstream White Noise CLI participant, exercise Sonar-to-White-Noise and White-Noise-to-Sonar direct-message startup over the Hedwig relay, reproduce the screenshot's `no key package found on relays` failure, and fix the underlying shared Rust-core defect.

**Constraints:**

- Use the installed upstream `wn` and `wnd` binaries as an external process; do not link AGPL `whitenoise-rs` into Sonar.
- Use `wss://nostr.relay.hedwig.sh` and fresh ephemeral identities so the run covers real publication, propagation, discovery, welcome, and message paths.
- Exercise both initiation directions and capture enough timestamps and CLI output to distinguish publication races, relay-list mismatches, stale KeyPackages, and welcome-processing failures.
- Keep the product correction in `core/sonar-core`; `sonar-cli` and the simulator may gain diagnostics/orchestration support.
- Preserve local-first chat behavior: retries or relay repair must remain bounded and off chat-open/transcript critical paths.
- Verify the shared-core behavior and avoid platform-specific divergence; native Apple and Compose consume the same corrected core path.

**Non-goals:**

- Depending on the exact account shown in the screenshot for the initial reproduction.
- Linking or copying White Noise protocol implementation into Sonar.
- Changing the LLM/persona provider or making Hermes part of the transport.
- Masking the error only in the iOS or Compose UI.

**Success criteria:**

- `relay-smoke-agents.sh` can provision a White Noise participant, include it in a seeded conversation graph, and send messages in both directions.
- The harness records KeyPackage publication/readiness, group creation, send/receive outcomes, and the seed/work directory needed to diagnose a failure.
- The screenshot-equivalent failure is reproduced or the harness produces evidence that rules out the ephemeral-account path before escalation to the reported account.
- The root cause is fixed in the smallest shared Rust-core path and covered by a deterministic regression test where feasible.
- Relevant Rust tests pass, followed by an end-to-end Hedwig relay run with both directions succeeding.

## Approaches Considered

### Approach A: White Noise adapter inside the existing agent graph

- **Sketch:** Add a shell adapter for `wn`/`wnd` and let one node in `scripts/smoke/relay-smoke-agents.sh` use it while other nodes continue using `sonar-cli`. Normalize White Noise messages to the existing NDJSON shape so the persona/reply loop stays unchanged.
- **Affected files:** `scripts/smoke/relay-smoke-agents.sh`, new `scripts/smoke/lib/wn-peer.sh`, `docs/RELAY-SMOKE-AGENTS.md`; after reproduction, likely `core/sonar-core/src/client.rs` and its tests.
- **Tradeoffs:** Best match for the requested realistic simulation and catches interop lifecycle races. Shell orchestration must cope with a long-running daemon and evolving upstream JSON shapes.
- **Effort:** M.

### Approach B: Separate deterministic White Noise interop smoke test

- **Sketch:** Build a focused two-peer script with one `sonar-cli` identity and one `wn`/`wnd` identity. Assert KeyPackage readiness and one message in each direction without personas or a random graph.
- **Affected files:** new `scripts/smoke/whitenoise-interop.sh`, new helper library, smoke documentation, then shared-core code/tests.
- **Tradeoffs:** Fastest and most reproducible root-cause harness, but it does not itself extend the agent simulation and provides less realistic repeated-conversation load.
- **Effort:** S-M.

### Approach C: Rust-owned external-client integration test

- **Sketch:** Add an ignored Rust integration test that launches `wnd`, invokes `wn`, and coordinates it with `SonarClient` directly. Keep live-relay execution opt-in.
- **Affected files:** `core/sonar-core/tests/whitenoise_interop.rs`, test utilities, core implementation.
- **Tradeoffs:** Strong assertions close to the implementation, but external-daemon process management makes Cargo tests brittle and still needs a shell-level agent integration afterward.
- **Effort:** M-L.

## Recommendation

Use **Approach A**, borrowing Approach B's deterministic two-peer phase at the start of the run. This fulfills the agent-simulation request while making failures attributable: first prove KeyPackage and bidirectional DM startup with two peers, then include the White Noise node in the noisy seeded graph. Once reproduced, encode the smallest deterministic portion as a Rust regression test and fix `sonar-core`.

## Investigation outcome

- Current White Noise publishes KeyPackages on the account's NIP-65 write relays; Sonar previously queried only its own configured relays. A deterministic two-relay regression test reproduces that miss and verifies the bounded peer-relay fallback.
- The screenshot account currently advertises relay metadata but has no discoverable KeyPackage on either Sonar's bootstrap relays or its advertised NIP-65 relays, so the screenshot error is truthful for that account's current relay state.
- The later reverse-direction failure exposed missing standard account routing state: Sonar published neither NIP-65 kind `10002` nor inbox kind `10050`, and sent welcomes only to its own relays. The shared core now bootstraps both relay lists and publishes each welcome to a bounded recipient inbox set without growing the long-lived relay pool.
- The Sonar CLI polling listener now performs forced bounded catch-up, recovering relay-stored events missed by a live subscription. The White Noise adapter consumes its live notification stream through an unbuffered PTY and retains durable polling as a fallback.
- Deterministic relay tests cover off-relay KeyPackage discovery, account relay-list bootstrap, and distinct recipient-inbox welcome delivery. The full Rust workspace passes.
- A fresh Hedwig-primary run with one external White Noise account passed both directions in one attempt: Sonar→White Noise in 2.384 seconds and White Noise→Sonar in 9.958 seconds. Evidence is retained at `/tmp/relay-smoke-agents.Q2tQO8` for this development session.

## Open questions

- None blocking. If an ephemeral White Noise account cannot reproduce the failure, escalate to the reported account or its relay metadata as agreed.

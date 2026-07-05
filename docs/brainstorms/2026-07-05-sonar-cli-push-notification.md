## Clarified Problem Statement

**Goal:** let a headless `sonar-cli` agent alert its human operator in
near-real-time when a new inbound message arrives, so nobody has to poll a UI.

**Chosen approach:** Approach A — an operator-facing **notification bridge**
exposed as `listen --notify-command`. This is the *receive-side* gap: the CLI
already *sends* push wakeups via the shared `sonar-core` send path, but never
*receives* any alert of its own (it only drains via `listen`).

### The hard constraint

The transponder can only deliver to an APNs/FCM **device token** bound to the
app's bundle id. A headless CLI process has no such token and no always-on
push-receiving surface, so making the CLI identity a *literal* recipient of the
MIP-05/APNs system is infeasible without also building app-side multi-identity
watch (large, out of scope). The feasible, useful version is a **local alert
relay**: when `listen` drains a new message, run an operator-supplied command.

## Constraints

- Local-first: notification dispatch must not regress `listen`'s sync/drain
  latency. It runs after each drain cycle and is best-effort.
- No new secrets on the command line. `--notify-command` is captured in shell
  history / process listings just like `--nsec`; secrets inside it must come
  from env vars expanded by the shell.
- CLI-only surface — does **not** touch `ios/` or `apps/sonar/`, so the
  cross-platform parity rule does not apply.
- Keep the CLI dependency footprint minimal (today: clap, nostr-sdk, tokio,
  serde — no HTTP client). A native webhook flag would add a dep; a webhook is
  instead reachable via `--notify-command 'curl ...'`, so command-mode alone
  covers it with **zero new dependencies**.

## Non-goals

- Making the CLI a direct APNs/FCM recipient (infeasible — see constraint).
- Changing the MIP-05/transponder send path (already works via `sonar-core`).
- A native `--notify-webhook` flag (deferred; `curl` via `--notify-command`
  covers the use case without a dependency).

## Success criteria

- One operator alert per genuinely-new inbound message, idempotent off the
  existing `seen` cursor (no duplicates, no re-fires on rerun).
- `--notify-command` works with **zero new dependencies** on macOS/Linux/Windows.
- A cron `listen --once --notify-command ...` cycle persists the seen cursor
  **and** fires the alert before exit (so reruns are idempotent).
- Unit tests cover env-var templating; a unix integration test covers the
  drain → alert path end to end.

## Implementation plan (Phase 1 = this change)

1. New module `core/sonar-cli/src/notify.rs`:
   - `NotifyContext { msg_id, sender, group_id, group_name, content, created_at_secs }`
     built from a `ChatMessage` + group name.
   - `run_command(template, &ctx)`: run through the platform shell
     (`sh -c` / `cmd /C`) with `SONAR_*` env vars; `Stdio::null()` for
     stdio; best-effort, diagnostics to **stderr** (never stdout, to preserve
     the JSON-lines contract). Blocks via `status()` so `--once` finishes its
     alert before exit.
2. `core/sonar-cli/src/main.rs`:
   - `mod notify;`
   - `ListenArgs.notify_command: Option<String>`.
   - Refactor `emit_unseen_messages` to return the newly-emitted non-mine
     messages (`Vec<(ChatMessage, group_name)>`).
   - `listen` captures that vec and calls `fire_notify` after each drain cycle.
3. README: a **Notifications** section (env var table, cron pattern, the
   "local relay, not transponder" caveat, secret-in-env guidance).

## Approaches considered

### Approach A: operator-facing notification bridge (chosen)
Run an operator command per new message. Feasible, zero-dep, idempotent off the
seen cursor. **Effort S.**

### Approach B: send-side verification/hardening
`--trace-push` + an integration test that the CLI's `send` emits a kind-446.
Worthwhile follow-up; the send path already works. **Effort M.**

### Approach C: literal CLI-as-push-recipient
Register a real device token under the CLI identity. Infeasible for a headless
process (token bound to the app bundle id; push would wake the wrong identity's
app). **Effort L, not recommended.**

## Follow-ups

- Approach B (send-side trace/test) as a separate change.
- A native `--notify-webhook` flag if the `curl`-via-command pattern proves
  awkward for operators (would add `reqwest`/`ureq`).

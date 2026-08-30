# Sonar review rules

These rules are injected into the main review pass for every diff. They are
**additive** to the default correctness/code-quality pass — apply them on top of
it, and only flag issues that are actually present in the diff. Prefer precise,
file:line-specific findings with a concrete fix or a ```` ```suggestion ```` block.

Review the **whole diff**. Do not comment on pre-existing code unless the diff
materially changes its behavior.

## Project invariants (hard rules — a violation is HIGH or CRITICAL)

- **Local Secrets.** No payment, wallet, relay, signing, or API secrets committed.
  Flag any literal that looks like a key/seed/`nsec`/mnemonic/API token/Breez key,
  or any path that writes one into the repo. Secrets belong in gitignored config
  (`ios/Configs/Local.xcconfig`, CI secrets) — never in source.
- **Account Key Durability.** Identity/account key (`nsec` / `marmot-nsec`)
  persistence must never use delete-before-add, never regenerate on a keychain
  error, and must mark onboarding complete only after durable persistence. Flag
  any save/wipe path that can silently drop or replace the account key.
- **Signal-comparable local-first performance.** Opening/sending/scrolling a chat
  must paint from local storage first and must not block on relay connect, EOSE,
  full-history scan, watermark reconciliation, or key-package publish. Flag any
  change that moves network/relay work onto the chat-open or send critical path,
  or that pages unbounded local data on first paint.
- **XChat-style chat startup.** Starting/opening a chat or group must create a
  local pending conversation immediately; network setup (relay, key packages,
  profile/descriptor lookup) must reconcile later, never gate first paint or
  basic send.
- **Cross-platform parity.** A user-facing feature is expected on both `ios/` and
  `apps/sonar/` (Compose). Flag a feature added on only one surface with no
  documented platform gap. (Tooling/CI changes like this review are exempt.)

## Language-specific

- **Rust (`core/`).** Never `unwrap()`/`expect()`/`panic!()` on production paths;
  propagate `Result`/`?`. No silent error swallowing (mapping `Err` to a default
  `0`/`""`/`None` without logging). Watch integer overflow in size math, unbounded
  loops, and blocking I/O on async paths. Crypto/payment code (`bolt12`, offers,
  Breez) is high-stakes — flag any unsafe handling, key reuse, or missing idempotency.
- **Swift / Kotlin (Compose).** Missing `null`/optional handling, force-unwraps,
  retain cycles, main-thread blocking, and reactive-state bugs.

## Output

Emit one JSON object per finding (`severity`, `path`, `line_start`, `line_end`,
`summary`, `check`). If the diff is clean, emit `[]`. Severity guide:
- `critical` — secret leak, data loss, account-key loss, security hole, crash on
  a common path.
- `high` — likely correctness/security bug or a hard-rule violation.
- `medium` — probable bug or notable quality issue.
- `low` — style/nit/minor improvement.

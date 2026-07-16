# Execution Plan — Compose i18n parity (Approach A)

Implements: [2026-07-15-compose-i18n-parity.md](2026-07-15-compose-i18n-parity.md)
Approach: **A — build-time codegen, `Localizable.xcstrings` stays the single source of truth.**

## Orchestration loop (skills)

```
/ship  (implement Approach A) ──► open PR
        │
        ▼
/review-pr  (structured review, severity-labeled findings)
        │
        ▼  findings?
   ┌────┴────┐
  yes        no ──► production-ready ──► DONE
   │
   ▼
/review-feedback  (apply fixes, run CI, push, reply to threads)
        │
        └──► back to /review-pr   (repeat until clean)
```

Loop exit condition: `/review-pr` returns no blocking/major findings AND remote CI is green.

## Model / agent delegation

- **Fable** (this main loop): orchestration, skill invocation, judgment calls, review
  triage, anything requiring repo/session context.
- **"Non-Fable" heavy-lift tasks** (mechanical, well-scoped, high-volume): the user asked
  for "cursor with grok 4.5." That surface is NOT available in this session. Substitute
  options (DECISION PENDING — see chat):
  - (a) Subagent on `sonnet`/`opus` via the Agent tool.
  - (b) `codex:rescue` agent → Codex CLI (GPT‑5.4).
  - (c) I do it inline on the main model.
  Candidate tasks to offload: the 83-call `Text("…") → stringResource` mechanical refactor,
  and drafting the xcstrings→strings.xml generator.

## Work breakdown (Approach A)

### Phase 1 — /ship: implement
1. **Generator**: `scripts/i18n/xcstrings-to-compose.(py|kt)` — parse
   `ios/bitchat/Localizable.xcstrings`, emit `composeResources/values/strings.xml` +
   `values-<qualifier>/strings.xml` for all 29 locales. BCP‑47 → Android qualifier map
   (`zh-Hans`→`zh-rCN`/`b+zh+Hans`, `pt-BR`→`pt-rBR`, etc.). Stable key→resource-id map.
   Handle xcstrings `variations` → Android `plurals` if present (else flag).
2. **Gradle wiring**: task in `apps/sonar/composeApp/build.gradle.kts` that runs the
   generator before resource processing; generated files under `commonMain/composeResources`.
3. **Compose refactor**: replace the 83 hardcoded `Text("…")` in
   `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/…` with
   `stringResource(Res.string.…)`. No lookups on the render hot path (resolve/remember).
4. **Audit sweep — Compose**: grep for remaining user-facing literals; drive to zero
   (exclude non-localizable: keys, hex, npub, log text).
5. **Audit sweep — iOS**: confirm no user string bypasses NSLocalizedString/xcstrings.
6. **Verify**: build Android debug; launch under `ja` / `zh-Hans` / `ar`; confirm
   translated UI + no layout breakage (RTL sanity). Desktop JVM locale detection check.
7. Commit, push, open PR (PR body: Signal-first notes, cross-platform coverage, tracked gaps).

### Phase 2 — /review-pr
- Structured review of the PR diff; severity-labeled findings. Watch for: locale-map
  correctness, missing plurals, perf on render path, untranslated leftovers, generator
  determinism/reproducibility, CI wiring.

### Phase 3 — /review-feedback
- Apply fixes for each finding, run local CI, push, reply to each thread. Return to Phase 2.

## Success criteria (from brainstorm)
- All Compose user-facing strings via resource ids; audit grep clean on both apps.
- Android under a supported locale renders translated UI matching iOS wording.
- Adding a string = edit one source catalog + regenerate (not 29 files).
- `/review-pr` clean + remote CI green.

## Open questions carried from brainstorm
- xcstrings `variations`/plurals present? → generator scope.
- Compose resource-id naming scheme (slug vs explicit map).
- Share-extension catalog: fold in or leave separate (likely separate).
- Desktop/JVM `Locale.getDefault()` resolution parity with Android.

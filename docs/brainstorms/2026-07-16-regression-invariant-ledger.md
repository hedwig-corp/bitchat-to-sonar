# Regression Invariant Ledger

## Clarified Problem Statement

**Goal:** Keep a repo-resident ledger of fixed-bug *invariants* — each anchored to a regression test, to both platform call sites, and to the approaches already rejected — so a fix cannot be silently undone, a ported platform cannot drift, and a diagnosis is not paid for twice.

**Why now (evidence from PR #290, 2026-07-16):**

- **Reintroduction:** #215 fixed duplicate send echoes. #273 made echo cleanup conditional on a heuristic and brought the duplicate back. Tests existed and passed — they encoded the *code*, not the *invariant*.
- **Cross-platform drift:** iOS `reconciledOptimisticMessages` takes `freshCanonical` and documents the exact failure ("the echo stays 'Sending' forever"). The Compose port copied the matcher **without** that argument. That omission *is* the bug.
- **Re-diagnosis cost:** hours lost, plus one wrong PR shipped, because the trace stopped at `SonarAppStore.sendDm -> marmot.send` and assumed iOS had no echo. It does — in `MarmotChatModel.send`.
- **Wrong turns repeat:** "just remove the optimistic echo" is superficially attractive and wrong (breaks retry-on-failure and first paint). Nothing in the repo records that.

**Structural driver — fix-commit hotspots on `main`:**

| File | `fix:` commits |
|---|---|
| `apps/sonar/.../SonarAppState.kt` (Compose) | 32 |
| `ios/bitchat/Views/Sonar/SonarAppStore.swift` (iOS) | 30 |
| `ios/bitchat/Views/MarmotChatView.swift` (iOS) | 21 |
| `core/sonar-core/src/client.rs` | 21 |

The top two are a **mirror pair**: the same conversation logic written twice and fixed ~60 times between them. Entries must therefore be keyed to invariants that span both platforms, not to per-platform bugs.

**Constraints:**

- Every entry names a regression test that **fails without the fix**. No test, no entry.
- Lives in `docs/` with a short pointer rule in `CLAUDE.md` (auto-loaded each agent session). `CLAUDE.md` is already 245 lines / 14 rules — the ledger must not bloat it.
- Every entry carries **both** platform call sites (iOS + Compose), since drift is the top structural risk.
- Every entry records **rejected approaches** with the reason.
- Test homes already exist: `ConversationRegressionSmokeTest.kt`, `TranscriptDisplayPolicyTest.kt` (Compose), `SonarConversationRegressionSmokeTests.swift` (iOS).

**Non-goals:**

- Not a changelog or bug tracker — GitHub issues/PRs keep the narrative.
- Not a postmortem archive. Entries are *invariants*, ~10 lines, not stories.
- Not a replacement for `CLAUDE.md`'s forward-looking design rules.
- Not auto-mined from git history without human judgment.

**Success criteria:**

- A later "fix" that would undo an invariant fails a named test in CI.
- An agent about to touch a hotspot file is told to read the ledger *before* editing.
- Each entry answers: what must hold / where both platforms implement it / which test guards it / what was already tried and rejected.
- A renamed or deleted test cannot leave a stale `Guarded by:` reference rotting unnoticed.

## Entry format (proposed)

```markdown
### R-007 — Send echoes must reconcile against out-of-window canonical rows
**Invariant:** Echo matching searches the freshly-read local page, not only the bounded render window.
**Breaks as:** Pinned/full window admits no new rows -> echo never fulfilled -> duplicate bubble stuck "Sending".
**Call sites:** iOS `MarmotChatView.swift::reconciledOptimisticMessages(freshCanonical:)`;
                Compose `SonarAppState.withSendEchoes` -> `reconcileSendEchoes(freshCanonical=)`
**Guarded by:** `TranscriptDisplayPolicyTest.outOfWindowCanonicalRowFulfillsEchoAndIsAdmitted`
**History:** #215 fixed -> #273 regressed -> #290 fixed properly
**Rejected:** Removing the optimistic echo for established groups — breaks retry-on-failed-send and
              first paint (blocks on `membership_gate`); premise "iOS has no echo" is false.
```

One entry covers all four failure modes: invariant (reintroduction), call sites (drift), breaks-as + history (re-diagnosis), rejected (wrong turns).

## Approaches Considered

### Approach A: Hand-curated ledger + CLAUDE.md pointer rule
- **Sketch:** Write `docs/REGRESSIONS.md` by hand. Add a short "Regression Invariant Rule" to `CLAUDE.md`: before changing a hotspot file, read the ledger; when fixing a recurring bug, add/update an entry with a test.
- **Affected files:** `docs/REGRESSIONS.md` (new), `CLAUDE.md` (+8 lines).
- **Tradeoffs:** Cheapest, immediately useful, full expressive freedom for rejected-approach prose. But `Guarded by:` references rot silently when tests are renamed, and nothing forces an entry on a new fix.
- **Effort:** S

### Approach B: Ledger + CI linkage check  (recommended)
- **Sketch:** Approach A, plus a small CI step that greps every `Guarded by:` symbol out of `docs/REGRESSIONS.md` and asserts it exists in the test sources. Fails the build on a stale reference.
- **Affected files:** `docs/REGRESSIONS.md`, `CLAUDE.md`, `scripts/check-regression-ledger.sh` (new), one job in `.github/workflows/`.
- **Tradeoffs:** Keeps doc-side judgment (rejected approaches, call sites) while making the test link non-rotting — the one part a machine can check cheaply. Does not force *new* fixes to add entries (that stays a review-time norm). ~30 lines of shell.
- **Effort:** S/M

### Approach C: Generate the ledger from structured test doc comments
- **Sketch:** Each regression test carries `@invariant / @platforms / @prs / @rejected` in a doc comment; a script generates `docs/REGRESSIONS.md`. Test is the single source of truth.
- **Affected files:** every regression test, plus a generator script.
- **Tradeoffs:** Cannot drift by construction — but an invariant spanning iOS + Compose has no single home, so the generator must merge Kotlin and Swift comment sets and pick a canonical owner. Cross-platform entries are precisely the important ones, so the hardest case is the common case. Also pushes prose into comments, where "rejected approaches" reads poorly.
- **Effort:** L

## Recommendation

**Approach B.** The content that prevents these bugs is judgment — which invariant matters, where both platforms implement it, what was already tried and rejected — and judgment does not generate. Keep it hand-written. But the one mechanically checkable part, "the cited test exists", is exactly what rots first, and a ~30-line grep in CI fixes that permanently. Approach C inverts the cost: it automates the easy half and makes the cross-platform half (the whole point) the hardest to express.

**Seed sweep — hotspot-driven, not chronological.** Do not walk the 166 dedup/regress commits in order; most are one-offs. Instead take the mirror pair (`SonarAppState.kt` / `SonarAppStore.swift`, ~60 fixes) plus `MarmotChatView.swift` and `client.rs`, cluster their `fix:` commits by area, and keep only clusters with **two or more independent fixes to the same behavior** — that repetition is the definition of "reintroduced". Everything else is noise. Expected first-pass yield: the dedup/echo family (#164, #215, #273, #290 + the iOS stuck-Sending fix), notification dedup (#276, #288), sync-watermark pinning (#177), conversation identity folding (#164 / "Fix What We Break Rule").

Entries whose invariant has no test yet should be listed in a `## Unguarded` section rather than silently dropped — that section is then a concrete backlog.

## Open questions

- Should the CLAUDE.md rule name the hotspot files explicitly (highest signal, needs occasional updating) or point at the ledger generically?
- Do iOS entries need a Swift-side test today, or is Compose-side coverage plus a documented iOS call site enough for the first pass? (iOS test infra is thinner.)
- Does an entry get retired once the mirror pair is deduplicated into shared logic, or does it stay as history?
- Is `docs/REGRESSIONS.md` the right name, or should it be `docs/INVARIANTS.md`? The content is invariants; the motivation is regressions.

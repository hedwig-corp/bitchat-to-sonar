# Plan: Close NO-GO → public full transcript engine

**Context:** PR #343 merged Sonar-as-first-consumer dogfood (policy KMP + SPM, Compose host). Self-review verdict: **GO for Sonar**, **NO-GO as a public full engine** until the gaps below close.

**Goal:** Ship a twin-host library surface other chat apps can drop in without Sonar types, with buildable samples that prove it.

## Gaps to close

| Gap | Today | Done when |
|---|---|---|
| UIKit host still in Sonar | `SNTranscriptCollectionHost` + `SNMessage` cells | Generic `TranscriptCollectionHost` in SPM; Sonar is thin adapter |
| Samples not modules | Sketch files under `packages/transcript-engine/samples/` | Runnable `:transcript-engine-sample` + SPM Example app in CI |
| Contract drift | Kotlin golden JSON; Swift tests hand-written | Shared golden cases consumed by both (or CI diff) |
| Packaging | Monorepo path deps only | Optional: version tags + publish recipe (Maven local / SPM git tag) — after hosts stabilize |

## Recommended sequence (2 PRs)

### PR A — Generic UIKit host (large, must not regress R-009)

1. **Invent the public host API** (no `SNMessage`):
   - `TranscriptMessage` protocol / struct: `id: String`, `date: Date?`, optional height fingerprint inputs
   - Cell factory: `(UICollectionView, IndexPath, id) -> UICollectionViewCell` or SwiftUI `View` builder for rows
   - Composer: generic `View` overlay + owned bottom inset (keep viewport-space inset math)
   - Sticky day headers via existing `transcriptDaySections` + `TranscriptRowHeightCache`
   - Open / pin / lockstep already in `TranscriptScrollPolicy` — host only applies

2. **Move / rewrite** from `ios/bitchat/Views/Sonar/SNTranscriptCollectionHost.swift`:
   - Keep in library: collection VC, inset ownership, height cache wiring, day sections, keyboardLayoutGuide attachment, kill-switch flags as optional host config
   - Leave in Sonar: bubble chrome, media/sticker pipeline, money formatters, Marmot types

3. **Sonar adapter:**
   ```swift
   SNTranscriptCollectionHost(...) // thin wrapper
     → TranscriptCollectionHost(messages: msgs.map(adapt), cell: { … SN bubble … })
   ```
   Kill switches stay Sonar-owned (`SONAR_TRANSCRIPT_COLLECTION_HOST`).

4. **Tests to move/add:**
   - Port `SNCollectionHostInsetTests` against library inset helpers (must keep viewport-space invariant)
   - Day section / height cache already in SPM — keep
   - Device smoke still merge gate for keyboard pin (R-009)

5. **Mac gap:** Document AppKit / Catalyst lag; do not claim Mac host parity in v1 of the UIKit module.

**Effort:** L  
**Risk:** High (production iOS path) — ship behind existing kill switch until device smoke on Pixel-class + Vincenzo iPhone.

### PR B — Buildable samples + CI proof (medium)

1. **Compose sample module** `packages/transcript-engine-sample` (or `apps/transcript-engine-sample`):
   - Depends on `:transcript-engine-compose` + `:transcript-engine-policy`
   - Fake `List<String>` / demo rows, LiveEdge + UnreadDivider modes, IME composer
   - `./gradlew :transcript-engine-sample:compileKotlinJvm` (and optional `:run`)
   - Wire into `compose-tests.yml` path filters + compile step

2. **SPM Example** under `ios/localPackages/TranscriptEngine/Examples/SampleChat/`:
   - Fake string rows + generic UIKit host (after PR A) or policy-only demo until A lands
   - `swift build` / Xcode scheme in CI if feasible; otherwise document `xcodebuild` local check

3. **Shared golden contract:**
   - Expand `packages/transcript-engine-policy/golden/open-action.json`
   - Add a tiny CI script or Swift resource load so both languages assert the same cases

4. **Docs:** Update `packages/transcript-engine/README.md` + `INTEGRATION.md` — remove “tracked gap” once A+B land; state Sonar remains first production consumer.

**Effort:** M  
**Risk:** Low

## Success criteria (flip NO-GO → GO for public engine narrative)

- [ ] Third-party-shaped sample apps compile in CI with **zero** `chat.bitchat` / `SNMessage` imports
- [ ] Sonar production iOS path uses library host via adapter; kill switch still works
- [ ] R-009 ledger call sites updated; inset + latch tests still cite real paths
- [ ] Cross-platform OpenAction / insetFollow semantics still mirrored (golden)
- [ ] README can say “full twin-host engine (Compose + UIKit)” without an asterisk for UIKit

## Non-goals (still later)

- Maven Central / separate GitHub org publish
- AppKit Mac host parity
- Extracting send pipeline, media decode, or conversation list
- Renaming Sonar `SN*` shims out of existence (compat can linger in Sonar app)

## Suggested ship commands

```text
/ship --from-brainstorm docs/brainstorms/2026-07-18-transcript-engine-full-public-plan.md
# or plan-only first:
/ship --plan-only extract generic UIKit TranscriptCollectionHost into TranscriptEngine SPM
```

Prefer **PR A then PR B** so the sample can use the real UIKit host, not a second sketch.

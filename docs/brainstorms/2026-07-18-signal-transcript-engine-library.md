# Clarified Problem Statement

**Goal:** Extract Sonar’s Signal-shaped transcript engine into twin releasable libraries (KMP + SPM) with a shared policy contract so other chat apps — and Hedwig products — can ship Signal-comparable open / scroll / keyboard / media-list performance without reinventing the host.

**Answers locked:**
1. Consumers: internal Hedwig + public OSS from day one (C)
2. Platforms: twin packages, shared contracts — KMP (Android/JVM) + SPM (iOS/macOS) (C)
3. Boundary: full engine — hosts, height cache, sticky days, media reserved-size helpers (C)
4. App-owned vs library: library owns the Signal-like engine surface; apps supply message identity, row content, and local DB paging
5. Packaging: undecided — design for clean extraction later (C)

**Constraints:**
- Must not regress Sonar’s local-first open / pin / lockstep / owned-chrome invariants (R-009, `docs/SIGNAL-TRANSCRIPT-PATTERNS.md`, PR #338)
- Cross-platform feature rule: policy contracts stay identical across KMP and SPM; platform hosts may differ in shell (chronological UIKit vs Compose LazyColumn) but not in OpenAction / wasAtTail semantics
- No Sonar/Marmot/Nostr types in the public API — generic message identity + measure callbacks
- Library must not force a network or crypto stack; DB paging stays app-owned
- Public release implies clear license, semver, and a demo app or sample that proves drop-in use outside Sonar
- Mac AppKit parity may lag iOS UIKit host (document as tracked gap if needed)

**Non-goals:**
- Extracting Marmot/MLS, relay sync, wallet, mesh, or Sonar UI chrome/branding
- Replacing Signal’s own clients or claiming Signal trademark affinity in the product name
- A single binary that runs both UIKit and Compose
- Shipping a full chat product (composer UX, reactions, send pipeline) — only the transcript list engine
- Deciding final public brand / separate GitHub org in this brainstorm

**Success criteria:**
- Shared policy module (OpenAction, pin|lockstep|ignore, continuity, coalesce) has golden tests consumed by both packages
- SPM package builds a sample iOS chat with fake messages; KMP package builds a sample Android/Compose chat the same way
- Sonar consumes the libraries (or in-monorepo modules that match the public API) with no behavioral regression vs post-#338 hosts
- Documented integration guide: app provides `MessageId`, row measure, sticky day key, composer height source; library owns list host + insets + open settle
- First public-shaped release can be monorepo modules or a split repo without API rewrite

## Approaches Considered

### Approach A: Monorepo modules first, extract later
- Sketch: Carve `packages/transcript-engine-policy/` (pure Kotlin + mirrored Swift, or Kotlin-only policy with Swift port), `packages/transcript-engine-compose/`, `packages/transcript-engine-uikit/` inside this repo. Sonar depends on them via project/SPM local path. Public release = copy or subtree-split when API stabilizes.
- Affected files: move/refactor from `SNTranscriptCollectionHost.swift`, `SNTranscriptScrollPolicy.swift`, `SNTranscriptRowHeightCache`, day sections; Compose `TranscriptPolicyHostScaffold.kt`, `TranscriptScrollPolicy.kt`, sticky headers in `ChatFeedList` / related; new samples under `packages/*/samples`; docs under `docs/SIGNAL-TRANSCRIPT-PATTERNS.md`
- Tradeoffs: Fastest for Sonar dogfooding; lowest risk of dual-write. Harder for external discoverability until split. Discipline required so Sonar types don’t leak back into modules.
- Effort: M

### Approach B: Separate repo + packages from day one
- Sketch: New repo (e.g. `hedwig-transcript-engine`) with three crates/packages: `policy`, `compose`, `uikit`. CI publishes Maven + Swift Package. Sonar vendors via git tag / SPM / Maven coordinates immediately.
- Affected files: greenfield extraction of the same sources; Sonar wiring changes in `ios/` and `apps/sonar/`; new CI for dual publish
- Tradeoffs: Cleanest public story and license boundary. Highest coordination cost (version bumps block Sonar). API mistakes are expensive once published.
- Effort: L

### Approach C: Policy crate first, hosts in phase 2
- Sketch: Publish only the pure policy + height/measure protocols first (small, testable, language-portable). Keep hosts inside Sonar until the contract is proven by a third-party sample that brings its own LazyColumn/UICollectionView.
- Affected files: mostly `*ScrollPolicy*` + protocol docs; hosts stay in Sonar until later PRs
- Tradeoffs: Smallest v1 and easiest OSS review. Contradicts the user’s “full Signal-like engine” (3C/4) for the first ship — only a stepping stone.
- Effort: S (then M–L for hosts)

## Recommendation

**Approach A (monorepo modules first, extract later).** It matches 5C (packaging undecided), still allows 1C (internal + public-shaped API from day one via samples + docs), and lands 2C/3C without freezing a public Maven/SPM version before Sonar has dogfooded the extracted boundary. Approach B is the right *second* move once the API survives one Sonar release cycle. Approach C under-delivers vs the chosen full-engine scope unless used only as an internal sequencing tactic inside A (policy module merges first, hosts next, still in-monorepo).

## Suggested library surface (full engine)

**Policy (shared contract):**
- `OpenAction`: LiveEdge | UnreadDivider | Jump(id)
- `InsetDecision`: pin | lockstep(delta) | ignore from wasAtTail + Δinset
- Continuity token / distance-from-bottom
- Coalesce window (~10ms) for inset thrash
- Sticky day section model (day key from timestamp; header pin policy)

**Hosts:**
- UIKit: full-height collection, pre-measure height cache, sticky day headers, owned bottom inset, keyboardLayoutGuide-friendly composer attachment, settled open
- Compose: owned chrome pad + IME, Pin/Lockstep, sticky sticky headers, LazyColumn host scaffold

**App supplies:**
- Stable message ids + equality for diff
- Row content composable / cell configure
- Preferred size / media reserved height fingerprint inputs
- Composer height (or layout guide binding)
- Bounded page of messages (library does not own DB)

**Out of library:** send pipeline, encryption, network, conversation list, full composer UX

## Open questions

- Public name/brand (avoid “Signal” in package name; candidates TBD)
- License (Apache-2.0 vs MIT) and whether Hedwig Corp retains trademark on the name
- Whether macOS gets UIKit-Catalyst / AppKit host in v1 or documented gap
- Kotlin policy as single source with Swift port vs dual-maintained policy with shared golden JSON fixtures
- How aggressive to strip Sonar DEBUG kill switches from the library vs keep as optional host flags

## Next

Run `/ship --from-brainstorm docs/brainstorms/2026-07-18-signal-transcript-engine-library.md` after confirming Approach A (or B), or `/ship --plan-only …` for a detailed extraction plan first.

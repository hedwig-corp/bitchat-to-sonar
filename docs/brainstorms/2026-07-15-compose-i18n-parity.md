# Multi-language support (i18n) — Compose parity with iOS

## Clarified Problem Statement

**Goal:** Make the Compose Multiplatform app (Android + Desktop) render in the user's
system language using the same translations iOS already ships, and audit both apps so no
user-facing string is left hardcoded.

**Current state (grounded):**
- iOS: `ios/bitchat/Localizable.xcstrings` — 296 strings × 29 languages
  (ar, bn, de, es, fil, fr, he, hi, id, it, ja, ko, ms, ne, nl, pl, pt, pt-BR, ru, sv,
  ta, th, tr, uk, ur, vi, zh-Hans, zh-Hant, en). Follows system locale; no in-app picker.
  A second catalog exists for the share extension (`ios/bitchatShareExtension/…`).
- Compose: zero i18n. No `values/strings.xml`, 0 `stringResource` calls, 83 hardcoded
  `Text("…")` across ~21 UI files. `compose.components.resources` is already a dependency
  (used today only for drawables), so the Compose Resources i18n path is available.

**Decisions locked (user):**
- Target: both apps, full re-audit (iOS coverage audited too, not assumed complete).
- Translation source: reuse the iOS xcstrings as the single source of truth.
- Selection: follow system locale on Compose (match iOS — no in-app language picker).

**Constraints:**
- Cross-Platform Feature Rule: ship the mechanism on iOS and Compose together.
- Keep one source of truth for translations — do not fork 29 language catalogs.
- Locale-code mapping is non-trivial: xcstrings uses BCP-47 (`zh-Hans`, `pt-BR`);
  Android resource qualifiers use `values-zh-rCN` / `values-b+zh+Hans`, `values-pt-rBR`.
- Signal-Comparable Performance Rule: string resolution must not add work on the Compose
  render path — resolve via `stringResource`/precomputed, no per-frame lookups or I/O.

**Non-goals:**
- No in-app language override picker (system locale only, per decision).
- No machine-translation of new strings in this change; new keys get English + flagged
  for human translation.
- No RTL layout rework beyond what the frameworks give for free (ar/he/ur exist in the
  catalog — verify but don't redesign screens here).

**Tracked Compose 1.7.3 locale gap:**
- Compose resources accept language and region qualifiers but reject BCP-47 script
  qualifiers. The generator therefore emits Simplified Chinese for `zh`, CN, and SG,
  and Traditional Chinese for TW, HK, and MO. A regionless `zh-Hant` locale cannot be
  distinguished from `zh-Hans` by this Compose version and falls back to the
  language-only Simplified resource. Re-evaluate script-qualified directories when
  upgrading Compose Multiplatform; the JVM locale tests cover every supported alias.

**Success criteria:**
- Every user-facing Compose string goes through a resource id; grep for `Text("` /
  literal user strings in `commonMain` UI returns only non-localizable cases.
- Launching the Android app under a supported locale (e.g. `ja`, `zh-Hans`, `ar`) renders
  translated UI matching iOS wording for shared strings.
- Adding one new string requires editing one source catalog and regenerating, not editing
  29 files by hand.
- iOS audit: no hardcoded English user string bypassing the xcstrings catalog.

## Approaches Considered

### Approach A: Build-time codegen, xcstrings stays the source (recommended)
- Sketch: A generator parses `Localizable.xcstrings`, emits Compose
  `composeResources/values/strings.xml` + `values-<qualifier>/strings.xml` for all 29
  locales (with a BCP-47→Android-qualifier map), and a stable key→resource-id mapping.
  Wired as a Gradle task so translations flow automatically from the iOS catalog.
- Affected files: new `scripts/i18n/xcstrings-to-compose.(py|kt)`; Gradle task in
  `apps/sonar/composeApp/build.gradle.kts`; generated `composeResources/values*/strings.xml`;
  refactor 83 `Text("…")` → `stringResource(Res.string.…)` across ~21 files in
  `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/…`.
- Tradeoffs: keeps a true single source of truth with the least disruption to iOS;
  cost is the key-reconciliation + locale-map + a generator to maintain. Handles plurals
  only if the generator emits them (xcstrings variations → Android `plurals`).
- Effort: M–L.

### Approach B: One-time import, catalogs diverge after
- Sketch: Run the xcstrings→strings.xml conversion once, commit the generated files, then
  iOS and Compose each own their catalog going forward.
- Affected files: throwaway import script; committed `values*/strings.xml`; same 83-call
  refactor.
- Tradeoffs: simplest tooling, no build coupling — but violates the single-source-of-truth
  intent: every new/changed string must be entered and translated twice, and the catalogs
  drift. Cheap now, expensive per-string forever.
- Effort: M.

### Approach C: Neutral canonical catalog, both platforms generate
- Sketch: Extract the source of truth out of xcstrings into a platform-neutral catalog
  (per-key JSON, CSV, or gettext `.po`) and generate BOTH the iOS `.xcstrings` and the
  Compose `strings.xml` from it. Truest cross-platform single source for a 2-platform
  product, and the cleanest home for the "full re-audit" mandate.
- Affected files: new `i18n/` canonical catalog + two generators; changes to the iOS build
  to consume generated xcstrings; Gradle task on Compose; the 83-call refactor.
- Tradeoffs: best long-term ergonomics and symmetry; highest upfront cost and it perturbs
  the working iOS pipeline — risk against a currently-shipping localization setup.
- Effort: L.

## Recommendation

**Approach A.** It honors the locked decision (xcstrings stays the single source of truth),
ships the mechanism on Compose with the smallest blast radius, and leaves iOS's working
pipeline untouched. Do the "full re-audit" as two grep-driven sweeps inside A: (1) Compose —
replace all 83 hardcoded strings with resource ids; (2) iOS — confirm no user string bypasses
NSLocalizedString/xcstrings. Note Approach C as the eventual direction if a third platform or
heavy translation churn ever makes the neutral catalog worth the migration; A does not
preclude it (the generator input can later switch from xcstrings to a neutral catalog).

## Open questions
- Plurals/variations: does the current xcstrings use `variations` (plural/device)? If so the
  generator must emit Android `plurals` and Compose plural APIs — confirm before scoping.
- Key naming: xcstrings keys are often the English source text; decide stable Compose
  resource ids (slug from key vs explicit map) before the 83-call refactor.
- Share extension catalog: fold `bitchatShareExtension/Localization` into the same source or
  leave separate? (Likely separate — different string set.)
- Desktop (JVM) locale detection: confirm Compose Resources resolves `Locale.getDefault()`
  on the JVM target the same way it does on Android.

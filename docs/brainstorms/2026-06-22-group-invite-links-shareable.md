# Make group invite links shareable & joinable

Date: 2026-06-22
Source: `/brainstorm "the group link are a little bit unusable"`

## Clarified Problem Statement

**Goal:** Make group invite links genuinely shareable and joinable — easy to hand to
someone nearby (QR) *and* to send through another app as a link that linkifies, survives
copy-paste, and can be acted on by pasting.

### What's broken today (as built in PR #89)
- **Format:** `sonar://invite/sinvite1{hex(json)}` — a custom URL scheme.
- **Share UX:** the group-info invite row only **copies** the `sonar://…` string to the
  clipboard. No native share sheet, no QR. The preview shown is
  `sonar://invite/sinvite1…{last 8 chars}` — a meaningless tail.
- **Join UX:** the *only* way in is opening the `sonar://` deep link. There is **no
  paste-to-join** — pasting the token into search/chat does nothing. People without the
  app installed get a dead link (no web fallback).
- **No universal-link infra exists:** Android registers only the `sonar://` custom scheme
  (no `autoVerify` App Links); iOS has no `apple-app-site-association` / associated-domains
  entitlement; no Sonar https domain appears in the codebase.

### Decisions captured from brainstorm Q&A
- **Pain points in scope:** sharing is clumsy; can't paste to join; link doesn't travel.
- **Scenario:** *both* in-person (QR) **and** remote (a real shareable link) equally.
- **Explicitly OUT of scope:** single-admin approval reliability / multi-admin fallback;
  link expiry; revocation UI; rate limiting. (Core has `revoke_link()` but no UI — leave it.)

## Constraints
- Cross-platform parity: iOS (`ios/`) and Compose (`apps/sonar/`) ship together (CLAUDE.md).
- **Follow the Signal pattern:** Signal uses `https://signal.group/#…` with the invite
  payload in the URL **fragment** (after `#`), which the host never receives — linkifies
  everywhere while keeping the payload client-side. Adopt this; do not reinvent.
- Don't regress already-issued `sonar://invite/sinvite1…` links — keep accepting them.
- Local-first ethos: the in-person path must not require a server round-trip.
- Performance rule: no work on the Compose render path; resolve in background.

## Non-goals
- Multi-admin / offline-admin approval fallback.
- Link expiration, revocation UI, rate limiting.
- In-app camera QR **scanning** is optional for v1 (render + paste covers the need).

## Success criteria
- Creating an invite offers **QR + native share sheet + copy** (not copy-only).
- The shared link **linkifies and auto-opens the app** when installed; shows a sane
  landing when not. (Auto-open activates once a domain + association files are live.)
- A recipient can **paste the link/token** (or scan QR) and land in the join flow — with
  no dependence on the OS routing a custom scheme.
- The invite row shows something meaningful (group name / "Tap to share"), not
  `sinvite1…last8chars`.
- Parser accepts all of: `https://<host>/join#sinvite1…`, `sonar://invite/sinvite1…`,
  and a bare `sinvite1…` token.

## Chosen approach: A — Signal-style universal link + QR + share sheet (client-only)

Token stays the existing `sinvite1{hex(json)}` payload. We wrap it for sharing as
`https://<host>/join#sinvite1…` so the payload lives in the **fragment** (never sent to
the host — same privacy property as today's local token). The host only needs a **static
page + two static association files** (`/.well-known/apple-app-site-association`,
`/.well-known/assetlinks.json`) — no backend logic, since the fragment isn't sent to it.

**Domain resolution (the one open blocker):** the universal-link host is a single
**configurable constant** (e.g. `JOIN_LINK_HOST`). All client-side behavior ships and works
immediately regardless of whether a domain is live. "Point DNS + host the two association
files + drop in the App Store / Play Store IDs" is a **documented activation step**, not a
code blocker. Until activated, the shared https link still copy-pastes and the QR/paste/
`sonar://` paths all work; only browser auto-open of the https link waits on the domain.

### Work breakdown
- **Core (`core/sonar-core`):**
  - `invite_link.rs` / `client.rs::request_join_via_link`: accept `https://<host>/join#…`,
    `sonar://invite/…`, and bare `sinvite1…`. Strip wrapper → existing `sinvite1` decode.
    Add an encode helper that emits the https form given a configurable host.
- **iOS (`ios/`):**
  - `BitchatApp.swift`: handle Universal Link `https://<host>/join#…` (and keep `sonar://`).
  - Associated-domains entitlement (`applinks:<host>`) — gated on domain, scaffolded.
  - `SonarGroupInfoScreen.swift`: QR via `CIQRCodeGenerator`, native share sheet
    (`UIActivityViewController`), fix the preview text, add a paste box on the join side.
- **Android / Compose (`apps/sonar/`):**
  - `AndroidManifest.xml`: add `autoVerify` App Links intent filter for `https://<host>/join`
    (keep the `sonar://invite` filter). `MainActivity.kt`: route the https intent.
  - `SonarGroupInfoScreen.kt`: QR (multiplatform QR lib or `expect/actual` — iOS
    `CIQRCodeGenerator`, Android `zxing`), share via `ACTION_SEND`, fix preview, paste box.
  - `SonarAppState.kt` / `SonarCore.kt`: route pasted text/token → `requestJoinViaLink`.
- **Static assets (new):** landing page + `apple-app-site-association` + `assetlinks.json`
  templates under a `web/` or `docs/` dir, with a README for the activation step.

### Why A over the alternatives
- **vs B (QR + paste, no web infra):** B ships fast with no domain blocker, but doesn't give
  a tappable link in other apps or a web fallback for non-installers — under-delivers the
  "remote / both equally" half the user asked for. B's work is a strict **subset** of A, so
  A is not throwaway if the domain slips: the client-side subset ships now either way.
- **vs C (hosted short-link + smart landing):** best onboarding for non-installers, but
  introduces a **stateful server** into a privacy/local-first product, and short-coding the
  payload would force storing group metadata server-side (loses the fragment privacy
  property). Heaviest to build and operate. Not justified for v1.

## Open questions (resolved / deferred)
- **Domain for the universal link?** → Deferred to a configurable `JOIN_LINK_HOST` constant +
  documented activation step. Not a code blocker.
- **Keep `sonar://invite/…` permanently?** → Yes, as a backward-compat alias (links from
  PR #89 are already in the wild).
- **QR scanning (camera) in v1?** → No; render + paste only. Camera scanning is a follow-up.
- **Compose QR rendering lib?** → Decide during implementation: multiplatform QR lib vs
  `expect/actual` (iOS `CIQRCodeGenerator`, Android `zxing`).

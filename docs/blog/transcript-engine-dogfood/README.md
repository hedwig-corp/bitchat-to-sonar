---
title: Dogfooding a Signal-shaped transcript engine — patterns first, packages later
cat: Engineering
date: 2026-07-19
summary: We extracted Signal’s open / pin / owned-inset patterns into monorepo twin packages so Sonar can ship Signal-comparable chat performance without cloning Signal chrome — and without freezing a public Maven/SPM API before a second consumer forces semver.
author: The Sonar team
read: 8 min read
feature: false
---

# Dogfooding a Signal-shaped transcript engine — patterns first, packages later

Chat open feels slow when the list waits on the network, rebuilds on every keyboard frame, or treats scroll continuity as a best-effort `scrollTo`. Signal solved those problems years ago. Sonar needed the same *performance contract* — not Signal’s chrome, brand, or full client architecture.

This post records the packaging decision we made after extracting that contract: **dogfood twin packages inside the Sonar monorepo first** (Approach A). We are deliberately **not** publishing a separately versioned Maven + SPM family until a second consumer forces semver.

## The goal is performance policy, not a Signal clone

Signal-iOS and Signal-Android disagree on shell details — chronological UICollectionView vs reverse RecyclerView — but they share the same DNA for what makes a transcript feel instant:

- Open paints from a **bounded local window**; relay sync updates the DB later
- Bottom chrome (composer + IME) is **owned by the list’s inset math**, not by shrinking the list frame
- Before an inset change, capture **was-at-tail** → **pin** to the live edge, **lockstep** by Δinset, or **ignore** while dragging
- Open is declarative: **LiveEdge | UnreadDivider | Jump(id)**
- Media in the list stays thumbnail-first; full-res belongs in the viewer

Sonar’s map of those patterns — what we adopt, what we deliberately skip, and what each platform still owns — lives in [`docs/SIGNAL-TRANSCRIPT-PATTERNS.md`](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SIGNAL-TRANSCRIPT-PATTERNS.md). The product rule underneath is the same as the rest of Sonar: **local-first first paint**. Opening an existing chat must not wait on relay connect, full-history scans, or unrelated groups.

We want Signal-comparable open / keyboard / scroll behavior. We do **not** want Signal’s visual language, reverse-layout dogma, or a drop-in replacement for their collection stack.

## What we extracted: shared goldens, then hosts

The extraction landed as monorepo twin surfaces:

| Module | Role |
| --- | --- |
| `packages/transcript-engine-policy/` | Pure KMP policy + golden JSON fixtures |
| `packages/transcript-engine-compose/` | Compose host scaffold (owned pad, pin/lockstep, open actions) |
| `ios/localPackages/TranscriptEngine/` | SPM policy mirror + generic UIKit `TranscriptCollectionHostView` |
| Sample apps on both sides | Fake-message demos that prove the boundary without Marmot |

The important split is **policy vs host**.

**Shared policy** is small and language-portable: open action, inset follow (`pin` / `lockstep` / `ignore`), continuity shape, coalesce window. Both Kotlin and Swift consume the same golden fixtures (`open-action.json`, `inset-follow.json`). CI diffs KMP goldens against the SPM test resources so the two ports cannot drift silently. That is the contract that must stay identical across apps — R-009 territory.

**Hosts** are platform shells. Compose gets a LazyColumn scaffold; iOS gets a UIKit collection host with pre-measure height cache, sticky day headers, and settled open. The shells may differ; `OpenAction` and was-at-tail semantics may not.

[PR #355](https://github.com/hedwig-corp/bitchat-to-sonar/pull/355) completed the generic UIKit host extract and buildable samples: Sonar wraps the library via an adapter; cells and media measure stay out of the package.

## Why not Approach B (publish from day one)

Approach B is the clean public story: a separate repo, Maven coordinates, SPM tags, semver from commit one. We rejected it as the *first* move for three engineering reasons:

1. **API mistakes get expensive once published.** Open/inset policy looks stable in a design doc and then shifts under real keyboard thrash, short feeds, and unread opens. Dogfooding in Sonar is cheaper than a 0.x churn tax on external consumers we do not have yet.
2. **Version bumps would block Sonar.** The transcript path is on the critical UX surface. Coupling every lockstep tweak to a publish pipeline and a dependency bump is the wrong latency for the team that still owns the only production consumer.
3. **A second consumer is the real semver trigger.** Until another Hedwig product (or an external app) integrates the modules, “public package” is ceremony. Samples + integration docs already force a clean boundary; Maven/SPM release can wait for demand.

Approach A keeps the modules shaped like a future public API — no Sonar/Marmot/Nostr types in the library surface — without freezing coordinates. Approach B remains the right *second* move after one Sonar release cycle survives the extracted boundary.

## What stays Sonar-owned

The libraries own list mechanics. The app still owns product chrome:

- **Bubble cells and row content** — message identity, configure/bind, read-more expansion state that must survive reuse
- **Media** — thumbnail decode paths, transfer progress overlays, file-backed large payloads; the host only needs reserved-size / measure inputs
- **Kill switches** — `SONAR_TRANSCRIPT_COLLECTION_HOST` / Compose phase-host flags stay app-owned so production can fall back without forking the library
- **DB paging and send pipeline** — bounded local pages, Marmot/mesh send, encryption, conversation list

That boundary is intentional. A transcript engine that swallows Sonar cells cannot be reused; an engine that refuses to own inset math cannot match Signal’s keyboard behavior. We drew the line where Signal draws it: engine owns scroll policy and host geometry; app owns identity, content, and storage.

## Dogfood criteria

Success for this phase is boring on purpose:

- Sonar iOS and Compose both consume the monorepo modules (or local SPM path) with no regression vs the post-extract hosts
- Golden tests for open action and inset follow stay green on both ports
- Sample apps compile in CI without a Sonar account or relay
- macOS AppKit collection-host parity remains a documented non-goal — policy can still compile there; the UIKit host is iOS-first

When a second consumer shows up, we split or publish. Until then, the engineering blog-worthy claim is narrower and more useful: **Signal patterns, shared goldens, Sonar dogfood — packages when semver has someone to protect.**

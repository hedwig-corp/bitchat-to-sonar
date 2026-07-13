# Clarified Problem Statement — Sonar Status page over Nostr

**Goal:** Ship a pixel-faithful `/status` page on the Sonar website that matches `Sonar Status.html`, with live browser WebSocket relay benchmarks, seed service/incident data ready to be replaced by a signed Nostr status feed, and Status entry points in both the main nav and footer.

## Decisions (from brainstorm answers)

| # | Choice | Meaning |
| --- | --- | --- |
| 1 | **C** | Live browser WebSocket pings **and** a path for a signed Nostr status feed (services/incidents) |
| 2 | **A + C** | v1 ships with design seed data; structure the page so a Nostr feed can replace/override seed when available |
| 3 | **A** | **Website only** — no probe worker, no deploy service, no native app work in this change |
| 4 | **C** | Entry points: **nav + footer** on the main site |
| 5 | **B** | "Subscribe to updates" → link to a Nostr feed / npub (not email/RSS) |

## Constraints

- Visual 1:1 with `design/handoff` (or the imported handoff) `Sonar Status.html` + `sonar/status-data.js` — same pattern as Landing/Docs/Stickers.
- Stay inside `web/` SvelteKit static site (`prerender = true`, `trailingSlash = 'always'`).
- Relay latency is measured **client-side** over live WebSocket (design behavior); do not invent a server ping API in this change.
- No secrets, payment keys, or private nsec in the repo. Public npub / event filters only.
- Cross-platform app rule does **not** apply — this is marketing-site only (documented non-goal for native surfaces).
- Preserve existing routes: `/`, `/docs`, `/stickers`, `/join`.

## Non-goals

- Probe worker / cron that publishes health events (deferred; page should tolerate its absence).
- Historical uptime DB or synthetic 90-day bars backed by real telemetry (v1 keeps design-seeded / deterministic bars).
- Email/RSS subscribe, statuspage.io, or third-party status hosts.
- iOS / Android / desktop in-app status screens.
- Changing relay lists in `core` or production infra.
- Perfect CORS/WebSocket reachability for every relay from every browser (design already falls back on blocked sockets).

## Success criteria

1. `/status` (with trailing slash per site config) renders the Status design: hero, service rows + 90-day bars, relay network with live ping + re-run, past incidents.
2. Main nav and footer both link to `/status`.
3. Relay section pings the design’s public `wss://` relays from the visitor’s browser and shows ms / timeout / summary line.
4. Services + incidents load from local seed (`status-data` equivalent) on first paint; optional Nostr query can refresh/override without blocking first paint.
5. Subscribe control points at a documented Nostr npub / naddr / filter (placeholder OK if the publishing key is not yet chosen — must be one clear constant, not a dead `#`).
6. Pixel-level match to the handoff (colors, layout, badges, bars, mono pings) consistent with how Docs/Stickers were ported.
7. Static build still works (`npm run build` in `web/`); no SSR dependency for core content.

## Context (repo)

- Website: `web/` SvelteKit static (`web/README.md`).
- Existing routes: `web/src/routes/+page.svelte`, `docs/`, `stickers/`.
- Shared chrome: `web/src/lib/components/Nav.svelte`, `Footer.svelte`.
- Design source (user handoff, 2026-07-13): `Sonar Status.html`, `sonar/status-data.js` (services, relays, incidents). Repo `design/handoff/` may lag until handoff is imported.
- Stickers page already does browser Nostr over WebSocket — reuse patterns from `web/src/routes/stickers/+page.svelte` for feed reads if needed.
- Footer already shows a truncated project `npub` — status subscribe may use a dedicated status npub or the same project identity (open until ops picks).

## Approaches considered

### Approach A: Static port + client pings + optional Nostr overlay

- **Sketch:** Port `Sonar Status.html` into `web/src/routes/status/+page.svelte` (+ scoped CSS or shared tokens). Seed data in `web/src/lib/status-data.js`. On mount: (1) paint seed immediately, (2) WebSocket-ping relays, (3) optionally query Nostr for replaceable status events from a configured author; if events parse, override services/incidents. Nav + Footer add Status links. Subscribe → `nostr:` / njump / naddr URL from `links.js`.
- **Affected files:** `web/src/routes/status/+page.svelte` (new), `web/src/lib/status-data.js` (new), optional `web/src/lib/status-nostr.js`, `web/src/lib/components/Nav.svelte`, `Footer.svelte`, `web/src/lib/links.js`, maybe `web/src/app.css` only if shared tokens needed; docs resolve-link map if Status is cross-linked from Docs.
- **Tradeoffs:** Matches 1C/2A+C/3A without backend. Nostr feed is best-effort; empty feed = seed still looks good. Risk: defining event kind/schema without a publisher yet (document a provisional schema + filter).
- **Effort:** M

### Approach B: Pure static design port (seed only, no Nostr read)

- **Sketch:** Faithful Svelte port of HTML + seed JS + live relay pings only. Subscribe links to a hardcoded npub profile URL. No client query for service health events.
- **Affected files:** Same route/nav/footer/data files; no Nostr status client module.
- **Tradeoffs:** Fastest pixel ship; fails the spirit of 1C/2C (Nostr only as subscribe link, not as status source). Easy follow-up to add overlay later.
- **Effort:** S

### Approach C: Website + deferred Nostr publisher contract only

- **Sketch:** Like A, but also land a short `docs/` or `web` markdown contract for the status event schema (kind, tags, JSON content for services/incidents) and a `just`/script stub that *could* publish — without running infra in this PR. Page implements the reader side fully.
- **Affected files:** Approach A files + e.g. `docs/SONAR-STATUS.md` (schema + npub placeholder + filter).
- **Tradeoffs:** Best long-term 1C/2C story under 3A constraint; slightly more design-up-front; still no live publisher until a later change.
- **Effort:** M (+ small docs)

## Recommendation

**Approach A**, with a thin schema note in-code (or one short section in the status module README comment) so 2C is real, not vapor:

1. Pixel-port `/status` from the handoff.
2. Seed-first paint for services/incidents/uptime bars.
3. Live browser relay WebSocket benchmarks (design logic).
4. Optional Nostr read on mount (non-blocking) using a constant author/filter in `links.js` / `status-data.js`; merge when valid events arrive.
5. Nav + footer Status links; subscribe → Nostr profile/feed URL.

Prefer **not** B if 1C is a real requirement. Prefer **not** full C unless you want a public ops doc in the same PR — can be a fast follow-up.

**Inferred defaults (correct me if wrong):**

- Import/copy latest handoff Status assets into `design/handoff/` only if needed for repo source-of-truth parity; implementation can read from the unzipped handoff as reference either way.
- Status npub may be placeholder until chosen; use one named constant.
- Provisional Nostr content: replaceable event (e.g. kind `30078` or project-chosen) with JSON `{ services, incidents, updated_at }` from a Sonar ops key — exact kind open until publisher exists.
- 90-day bars stay deterministic/synthetic from seed (or from feed if feed supplies history later).

## Open questions (non-blocking for `/ship`)

- Exact status publisher npub / kind / `d` tag.
- Whether Docs should link to Status (resolveLink map).
- Whether to vendor the new Status.html into `design/handoff/project/` in the same PR.
- njump.me vs nostr.com vs raw `nostr:` for Subscribe UX.

## Next

```
/ship --from-brainstorm docs/brainstorms/2026-07-13-nostr-status-page.md
```

Or: `/ship --plan-only` with the Goal line above for a detailed plan first.

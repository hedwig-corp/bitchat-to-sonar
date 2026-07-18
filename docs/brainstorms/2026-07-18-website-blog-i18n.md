# Website + blog translation (i18n)

## Clarified Problem Statement

**Goal:** Serve the full public Sonar website (`/`, `/blog`, `/docs`, `/status`, `/stickers`) in IT, DE, ES, PT, and FR by detecting the device locale, with English as the source of truth — including AI-translating blog post bodies after they are fetched from Nostr (never publishing translations to relays).

**Constraints:**
- Static SvelteKit site (`adapter-static`, `prerender = true`, GitHub Pages) — no per-request SSR locale negotiation.
- Locale selection is **dynamic from the device** (`navigator.language` / `navigator.languages`), not URL-prefixed (`/it/…`) for v1.
- Priority locales: `it`, `de`, `es`, `pt`, `fr` (+ `en` fallback).
- Translations are **machine-only** (accept lower quality; no human review gate in v1).
- Blog source of truth stays English NIP-23 events (`sonarblogpost`); translations are site-only overlays.
- AI runs **after** Nostr fetch (bake path), keyed so re-fetch of the same content does not re-translate forever.
- Do not put AI API secrets in the client bundle or in committed site config.
- Keep landing visual 1:1 with the design handoff; i18n must not restyle `app.css`.

**Non-goals:**
- URL/SEO locale prefixes (`/de/blog/…`) and `hreflang` clusters.
- Publishing translated posts as separate NIP-23 events.
- Matching the full ~29 app locales from `Localizable.xcstrings`.
- Human translation workflow / community PRs for copy.
- Translating the native apps.

**Success criteria:**
- Device locale IT/DE/ES/PT/FR shows translated chrome + landing copy without a manual picker.
- English / unsupported locales keep today’s English experience.
- Blog list/article bodies appear in the active locale when overlays exist; English Nostr unchanged.
- Live Nostr refresh must not wipe overlays (merge by post id).
- No AI keys in the browser or git; bake uses env secret when present, otherwise keeps committed overlays.
- `npm run build` still produces a fully static `web/build`.

## Recommendation

**Approach B** — static UI message catalogs + bake-time AI blog overlays, device-locale switch at runtime.

# Sonar design handoff — vendored

The complete design handoff bundle lives in `design/handoff/`. It is **vendored**
(checked in) so agents read it from disk instead of re-fetching every time.

- **Source share:** https://api.anthropic.com/v1/design/h/UQethAMsRlMNd4xMzNISTA?open_file=Sonar+Prototype.html (Claude Design / claude.ai/design)
- **Blog refresh (2026-07-14)** — Claude Design project
  `c6936a45-1fde-470e-9d0b-56b04428e60b`
  ([open](https://claude.ai/design/p/c6936a45-1fde-470e-9d0b-56b04428e60b?file=Sonar+Blog.html)):
  ADDS the blog. New files vendored here: `project/Sonar Blog.html` (list view
  with kicker + featured post + 3-col grid, hash-routed article view with the
  same tiny markdown renderer as Docs, per-category glyphs/colors — Policy gold,
  Design indigo, default cyan — article CTA card and "More from the blog") and
  `project/sonar/blog-content.js` (three sample posts; kept as reference only).
  Implemented in the marketing site at `web/src/routes/blog/` reusing
  `$lib/markdown.js`; the site ships with an **empty post list**
  (`web/src/lib/blog-content.js`) by request — the design's sample posts are not
  published. A **Blog** link was added to the site Nav.
  The same refresh also UPDATES `project/Sonar Landing.html`: the nav gains
  `Blog` + `Fight Chat Control` links (the latter points at a
  `Fight Chat Control.html` page that does not exist in the design project yet),
  and a new **"From the blog"** teaser section (`section#blog` / `.blogteaser`)
  sits before the download band. Implemented on the site landing
  (`web/src/routes/+page.svelte` + `.blogteaser`/`.bt` styles in
  `web/src/app.css`): the teaser is driven by the same `SONAR_BLOG.posts` and
  the whole section is omitted while the post list is empty (no dead links); the
  `Fight Chat Control` nav link is intentionally NOT added yet — no such page
  exists. The vendored landing HTML was also brought up to date (it had drifted
  to an old "Open the prototype" nav).
- **Docs refresh (2026-07-07)** — Claude Design project
  `c6936a45-1fde-470e-9d0b-56b04428e60b`
  ([open](https://claude.ai/design/p/c6936a45-1fde-470e-9d0b-56b04428e60b?file=Sonar+Docs.html)):
  ADDS the documentation site. New files vendored here:
  `project/Sonar Docs.html` (the docs shell — sticky top bar with a `docs` tag,
  left sidebar nav + search, markdown article, sticky on-this-page TOC with
  scroll-spy, prev/next, mobile drawer) and `project/sonar/docs-content.js`
  (the doc corpus: `SONAR_DOCS.groups` + `SONAR_DOCS.docs`, markdown mirroring
  the repo `docs/` folder — Discovery, Payments, BIP-353, Stickers). Implemented in the marketing site at `web/src/routes/docs/`
  (`+page.svelte` + `$lib/docs-content.js` + `$lib/markdown.js`); the Nav
  "Open the prototype" link was replaced by a **Docs** link. The same project
  also carries a newer Stickers directory (`Sonar Stickers.html`,
  `sonar/stickers/*`) that is out of scope for this refresh.
- **Last synced:** 2026-06-16. Three design refreshes landed this day, all vendored here:
  - **Profile key-management** (`UQethAMsRlMNd4xMzNISTA`): reworks the profile view key
    management. ADDS a `KeyShareCard` in `project/sonar/settings.jsx` (QR + tap-to-expand
    full key + "Copy key"/"Share" buttons); renames the "Keys" section to **Safety** with the
    fingerprint row gaining a "Read this aloud to verify in person" subtitle; new `copy`/`share`
    icons in `icons.jsx`; `.keyshare*` styles in `theme.css`; and image-based app-icon tiles +
    a new `project/sonar/brand/` asset folder (brand chip in onboarding/header).
  - **Sonar Desktop** (`LiZ0wCa-wc3TUfTpZosL3w`): the desktop split view, implemented in the
    Compose Multiplatform app (`apps/sonar`). Project files matched the prior vendoring
    byte-for-byte — only the bundle README changed.
  - **Voice & video calls** (`eERbS8ypP834YQPtpCPcqw`): ADDS `project/sonar/call.jsx`
    (`CallView` full-screen voice/video + `CallLog` in-chat record + `fmtCall`), the `.call*`
    styles in `theme.css`, the DM-header **phone + videocam** buttons (`screens.jsx` DMScreen
    trailing → `push('call', {kind})`), `app.jsx` `endCall`, `components.jsx` MsgList
    `if (m.call) <CallLog>`, and new icons (phone/videocam/phoneDown/micOff/videoOff/speaker/
    cameraFlip). Mocked in the prototype (ringing→connected after 2s); real P2P (iroh /
    n0-computer `callme`, issue #21) is the implementation.
- **Prior source shares:** `LiZ0wCa-wc3TUfTpZosL3w` (2026-06-16), `A6e-y7WFkbHYzGBYedgCxw`
  (2026-06-16), `H5tEQgWekwCuHihJuEYcxw` (2026-06-14), earlier 2026-06-12.

## What's the source of truth

Per the bundle README (`design/handoff/README.md`) and the repo DESIGN RULE
(reproduce 1:1, do NOT reskin):

- **App design** = `design/handoff/project/Sonar Prototype.html` + its imports in
  `design/handoff/project/sonar/*` (`app.jsx`, `screens.jsx`, `components.jsx`,
  `data.js`, `icons.jsx`, `pay.jsx`, `settings.jsx`, `theme.css`).
- **Desktop** = `Sonar Desktop.html` + `sonar/desktop*.{jsx,css}`.
- **Marketing site** (NOT the app) = `Sonar Landing.html`.
- **Intent / back-and-forth** = `design/handoff/chats/chat1.md` (read this for what the user wanted).

## To refresh

Re-fetch the share URL (it returns a gzipped tar), extract, and `cp -R` the
`bitchat-review/.` over `design/handoff/`. Update the "Last synced" date above.

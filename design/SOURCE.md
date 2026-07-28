# Sonar design handoff — vendored

The complete design handoff bundle lives in `design/handoff/`. It is **vendored**
(checked in) so agents read it from disk instead of re-fetching every time.

- **Source share:** https://api.anthropic.com/v1/design/h/UQethAMsRlMNd4xMzNISTA?open_file=Sonar+Prototype.html (Claude Design / claude.ai/design) — **dead (404)**; refresh through the `DesignSync` MCP tool against the project id below instead.
- **Payment-status refresh (2026-07-28)** — Claude Design project
  `c6936a45-1fde-470e-9d0b-56b04428e60b`
  ([open](https://claude.ai/design/p/c6936a45-1fde-470e-9d0b-56b04428e60b?file=Sonar+Payment+Status.html)):
  ADDS the **external payment status** explorations. New files vendored here:
  `project/Sonar Payment Status.html` (the exploration page — its own `<style>`
  block carries every `.rs-*` / `.stp-*` / `.jr-*` / `.one-*` / `.hp-*` rule, so
  `theme.css` is untouched) and `project/sonar/paystatus.jsx` (one shared
  7-state machine — `resolving · paying · slow · sent · failed_safe · refunded ·
  unknown` — rendered four ways: **A** stepped ledger, **B** one sentence, **C**
  journey rail, **D** resumable status; plus three home surfaces **H1** pinned
  strip / **H2** list row / **H3** slim bar).
  The page does not pick a direction. **D + H1 shipped** (owner's call):
  `ios/bitchat/Views/Sonar/SonarPaymentStatus{,Screen}.swift` and
  `apps/sonar/.../wallet/PaymentStatus.kt` +
  `apps/sonar/.../screens/SonarPaymentStatusScreen.kt`, reached from
  `Send payment → Pay` on an external destination. H1 is shown only while the
  payment is live. Deviations, unreachable states and the copy-table contract
  are written up in [`docs/SONAR-PAYMENTS.md`](../docs/SONAR-PAYMENTS.md).
  Nothing else in the project changed for this refresh.
- **Send-payment refresh (2026-07-27)** — Claude Design project
  `c6936a45-1fde-470e-9d0b-56b04428e60b`
  ([open](https://claude.ai/design/p/c6936a45-1fde-470e-9d0b-56b04428e60b?file=Sonar+Prototype.html)):
  ADDS a **standalone send-payment flow** reachable from the new-chat sheet —
  `Start a chat → “Send a payment” → SendPaymentScreen → PaySheet`. Changes
  vendored here:
  - `project/sonar/pay.jsx` — new `SendPaymentScreen` (recipient picker: search
    field, “Scan a QR code” row, a “Pay ‘…’” external row that appears when the
    query looks like `@user` / `name@domain` / `lno1…` / `npub1…`, and a
    “People you can pay” list filtered to peers whose `caps` include
    `payments`), new `ScanQrSheet` (viewfinder + three sample codes: Lightning
    invoice with a **fixed** amount, on-chain address, Bolt12 offer), new
    `PayDetailSheet` (plain summary + mono proof block), new `WalletActivity`
    log. `PaySheet` gained a `fixed` prop (skips chips + keypad when the code
    carries an amount). `PayBubble` moved from **sealed/claim ecash** to a
    **direct BOLT12 payment**: `pending → paid → confirmed | failed`, incoming
    is `received` and lands straight in the wallet — there is no claim step
    anymore.
  - `project/sonar/screens.jsx` — `StartChatSheet` takes `onPay`; its rows are
    now *People nearby · Find by username · **Send a payment** · New group*
    ("New discussion" was renamed "Find by username").
  - `project/sonar/app.jsx` — `pay` and `backup` routes, `payExternal()`.
  - `project/sonar/data.js` — peers gained `npub` / `bip353` / `caps` /
    `media` / `met` / `supporter`; new `txns` seed list.
  - `project/sonar/icons.jsx` — `qr`, `backup`, `heart`, `nudge`, `link`,
    `leaf`, `cup`, `ball`, `car`, `bulb`, `grid`, `flag`, `keyboard`, `bellOff`.
  - `project/sonar/settings.jsx` — `BackupScreen` + `BackupSetupSheet` (Signal
    style encrypted backup with a 12-word recovery key) and the Data & storage
    “Chat backup” row.
  - `project/sonar/theme.css` — `.sp-*` (send-payment picker), `.scan-*`
    (scan to pay), `.bk-*` (backup).
  Not re-vendored because they matched byte-for-byte: `Sonar Prototype.html`,
  `sonar/components.jsx`. Out of scope for this refresh: the newer
  `Sonar Stickers.html`, `Sonar Design System.html` and `Fight Chat Control.html`
  pages that also live in the project.
  One divergence from the remote source: the remote `pay.jsx` puts a JS escape
  sequence (backslash-u-2026) in JSX *text* position for the pending label, and
  JSX text does not process escapes — React would render those six characters
  verbatim instead of an ellipsis. The vendored copy uses the real `…`.
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
- **External payment status** = `Sonar Payment Status.html` + `sonar/paystatus.jsx`
  (an exploration page, not a shipped screen — Direction **D** and home surface
  **H1** are the ones implemented).
- **Desktop** = `Sonar Desktop.html` + `sonar/desktop*.{jsx,css}`.
- **Marketing site** (NOT the app) = `Sonar Landing.html`.
- **Intent / back-and-forth** = `design/handoff/chats/chat1.md` (read this for what the user wanted).

## To refresh

Re-fetch the share URL (it returns a gzipped tar), extract, and `cp -R` the
`bitchat-review/.` over `design/handoff/`. Update the "Last synced" date above.

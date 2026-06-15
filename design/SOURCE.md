# Sonar design handoff — vendored

The complete design handoff bundle lives in `design/handoff/`. It is **vendored**
(checked in) so agents read it from disk instead of re-fetching every time.

- **Source share:** https://api.anthropic.com/v1/design/h/LiZ0wCa-wc3TUfTpZosL3w?open_file=Sonar+Desktop.html (Claude Design / claude.ai/design)
- **Last synced:** 2026-06-16 (re-fetched for the **Sonar Desktop** implementation. The user opened
  `Sonar Desktop.html` when triggering this handoff; the project files matched the prior vendoring
  byte-for-byte — only the bundle README changed — so no design content shifted. The desktop split
  view was implemented in the Compose Multiplatform app this refresh; see `apps/sonar`.)
- **Prior source share:** https://api.anthropic.com/v1/design/h/H5tEQgWekwCuHihJuEYcxw (synced 2026-06-14).

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

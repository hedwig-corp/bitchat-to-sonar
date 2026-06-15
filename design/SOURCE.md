# Sonar design handoff — vendored

The complete design handoff bundle lives in `design/handoff/`. It is **vendored**
(checked in) so agents read it from disk instead of re-fetching every time.

- **Source share:** https://api.anthropic.com/v1/design/h/A6e-y7WFkbHYzGBYedgCxw (Claude Design / claude.ai/design)
  - prior shares: `H5tEQgWekwCuHihJuEYcxw` (2026-06-14), earlier 2026-06-12.
- **Last synced:** 2026-06-16 (re-fetched the new share; the bundle is **byte-identical** to the
  2026-06-14 vendoring — `diff -rq` is empty. So the design has NOT changed; the home "around me"
  radar, chat media, and the **send-audio / voice-note** affordances (`AttachActions` Audio note +
  the `bc-sendbtn mic` hold-to-record button + `bcVoiceMedia` waveform notes in
  `project/sonar/components.jsx`) are already in the design but NOT yet implemented in the apps —
  voice/video were deferred during the media Phase-1 (images-only) work. This refresh implements
  those design aspects in both apps.)

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

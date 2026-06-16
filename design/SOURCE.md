# Sonar design handoff — vendored

The complete design handoff bundle lives in `design/handoff/`. It is **vendored**
(checked in) so agents read it from disk instead of re-fetching every time.

- **Source share:** https://api.anthropic.com/v1/design/h/eERbS8ypP834YQPtpCPcqw (Claude Design / claude.ai/design)
  - prior shares: `A6e-y7WFkbHYzGBYedgCxw` (2026-06-16), `H5tEQgWekwCuHihJuEYcxw` (2026-06-14), earlier 2026-06-12.
- **Last synced:** 2026-06-16 (re-fetched the new share — it ADDS **voice & video calls**:
  `project/sonar/call.jsx` (`CallView` full-screen voice/video + `CallLog` in-chat record + `fmtCall`),
  the `.call*` styles in `theme.css`, the DM-header **phone + videocam** call buttons (`screens.jsx`
  DMScreen trailing → `push('call', {kind})`), `app.jsx` `endCall` (appends a call record to the DM),
  `components.jsx` MsgList `if (m.call) <CallLog>`, and new icons (`icons.jsx`: phone/videocam/
  phoneDown/micOff/videoOff/speaker/cameraFlip). The calls are MOCKED in the prototype
  (ringing→connected after 2s, a timer) — implemented mocked in the apps first; real P2P (iroh /
  n0-computer `callme`, issue #21) is the follow-up.)

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

# Sonar design handoff — vendored

The complete design handoff bundle lives in `design/handoff/`. It is **vendored**
(checked in) so agents read it from disk instead of re-fetching every time.

- **Source share:** https://api.anthropic.com/v1/design/h/LiZ0wCa-wc3TUfTpZosL3w?open_file=Sonar+Desktop.html (Claude Design / claude.ai/design)
- **Last synced:** 2026-06-16. Two design refreshes landed this day, both vendored here:
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
- **Prior source shares:** `A6e-y7WFkbHYzGBYedgCxw` (2026-06-16), `H5tEQgWekwCuHihJuEYcxw`
  (2026-06-14), earlier 2026-06-12.

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

# Sonar landing page

A static [SvelteKit](https://svelte.dev/docs/kit) site that reproduces the Sonar
marketing landing page **1:1** from the Claude Design handoff.

> Sense who's nearby before you see them.

## Source of truth

The visual reference lives in the repo so you never need to re-open the design
tool to make changes:

| What | Where |
| --- | --- |
| Original prototype | [`design/handoff/project/Sonar Landing.html`](../design/handoff/project/Sonar%20Landing.html) |
| Reference screenshots | [`design/handoff/project/screenshots/`](../design/handoff/project/screenshots) (`01-landing.jpg` … `04-landing.jpg`) |
| Design intent / chat log | [`design/handoff/chats/chat1.md`](../design/handoff/chats/chat1.md) |

When you change the landing page, diff against `Sonar Landing.html` and the
screenshots. The global stylesheet (`src/app.css`) is a verbatim copy of the
prototype's `<style>` block — keep it in lockstep; don't restyle.

## Layout

```
web/
├── src/
│   ├── app.html              # document shell + Google Fonts (Figtree, IBM Plex Mono)
│   ├── app.css               # global styles, copied 1:1 from the prototype
│   ├── lib/
│   │   ├── links.js          # outward links (repo / download placeholders)
│   │   └── components/
│   │       ├── SonarMark.svelte  # concentric-rings wordmark glyph
│   │       ├── Nav.svelte
│   │       ├── Radar.svelte       # hero radar (dotted rings computed at build time)
│   │       └── Footer.svelte
│   └── routes/
│       ├── +layout.js        # prerender = true (fully static)
│       ├── +layout.svelte    # imports app.css
│       └── +page.svelte      # the landing page sections
└── static/                   # favicon, .nojekyll
```

## Develop

```sh
cd web
npm install
npm run dev      # http://localhost:5173
```

## Build & preview

```sh
npm run build    # static output in build/
npm run preview
npm run check    # svelte-check (type + a11y)
```

The build uses `@sveltejs/adapter-static` with relative asset paths, so the
output works whether it is served from a domain root or a project subpath such
as `https://<org>.github.io/bitchat-to-sonar/`.

## Deploy

Pushing to `main` triggers `.github/workflows/pages.yml`, which builds this
directory and publishes `web/build` to GitHub Pages. `BASE_PATH` is set to the
repo name for the production build.

## Notes

- The "Open the prototype" / "Try the interactive demo" buttons point at the
  project repository until a hosted interactive demo exists. The `#download`
  links are placeholders pending real App Store URLs (see the chat log).
- Radar sweeps and pulses respect `prefers-reduced-motion`.

## Group invite links (App Links / Universal Links)

Group invites are shared as a Signal-style universal link with the payload in the
URL **fragment** (never sent to the server):

```
https://sonarprivacy.xyz/join#sinvite1<hex>
```

The host (`JOIN_LINK_HOST`) is set in both clients — `InviteShare.kt`
(`apps/sonar/...`) and `InviteShare.swift` (`ios/...`). **Every client surface
works before the host is live**: QR codes, copy, share, paste/share-to-join, and
the legacy `sonar://invite/…` scheme all function offline. Hosting only adds the
convenience of the https link auto-opening the app.

Three static files ship under `static/` so they deploy to the site root (the
`.nojekyll` marker lets GitHub Pages serve the dot-folder):

| URL | File |
|-----|------|
| `/.well-known/apple-app-site-association` | `static/.well-known/apple-app-site-association` |
| `/.well-known/assetlinks.json` | `static/.well-known/assetlinks.json` |
| `/join` | `static/join/index.html` (landing + `sonar://` fallback) |

These require the site to be served at the **domain root** (`sonarprivacy.xyz`),
not the GitHub Pages project subpath — `sonarprivacy.xyz` already points at this
Pages site, so the files go live at the root once this branch lands on `main` and
Pages redeploys.

Status of the three activation inputs:

1. **iOS — AASA**: filled with `ZQB239SHCM.sh.hedwig.sonar`
   (`<DEVELOPMENT_TEAM>.<bundle id>`). Apple's CDN fetches AASA tolerantly, so the
   extensionless file served by GitHub Pages works without a custom content-type.
2. **iOS — entitlement**: committed — `applinks:sonarprivacy.xyz` is in
   `ios/bitchat/bitchat.entitlements`, and the `.onContinueUserActivity` handler in
   `BitchatApp.swift` consumes it. Verified: device builds still sign (Xcode
   auto-provisions the Associated Domains capability under automatic signing).
3. **Android — assetlinks**: filled with the **debug** keystore SHA-256 so App
   Links verify for the current alpha/debug installs. **Before a Play release, add
   the release / Play App Signing fingerprint** to the `sha256_cert_fingerprints`
   array (`keytool -list -v -keystore <release.keystore> | grep SHA256`). The
   `autoVerify` intent-filter is already in `AndroidManifest.xml`.

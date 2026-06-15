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

import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

// On GitHub Pages a project site is served from /<repo>, so the build needs a
// matching base path. CI sets BASE_PATH=/bitchat-to-sonar; local dev keeps ''.
const base = process.env.BASE_PATH ?? '';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter({
      // SPA-safe fallback so unknown routes still resolve on Pages.
      fallback: '404.html'
    }),
    paths: { base },
    prerender: { entries: ['*'] }
  }
};

export default config;

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
    prerender: {
      entries: ['*'],
      // The /docs page uses URL-hash fragments (#index, #SONAR-DISCOVERY, …) as
      // client-side router keys, not as in-page scroll targets, so those ids do
      // not exist as elements at prerender time. Don't fail the build on them.
      handleMissingId: 'ignore'
    }
  }
};

export default config;

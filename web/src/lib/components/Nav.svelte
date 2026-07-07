<script>
  import { base } from '$app/paths';
  import SonarMark from './SonarMark.svelte';
  import { DOWNLOAD_HREF } from '$lib/links.js';

  const downloadHref = `${base}/${DOWNLOAD_HREF}`;
  const stickersHref = `${base}/stickers`;
  const docsHref = `${base}/docs`;
</script>

<nav>
  <div class="navin">
    <a class="wordmark" href="{base}/">
      <SonarMark size={22} />
      sonar
    </a>
    <div class="navlinks">
      <a class="btn ghost small" href={stickersHref}>Stickers</a>
      <a class="btn ghost small docs-link" href={docsHref}>Docs</a>
      <a class="btn primary small" href={downloadHref}>Get the app</a>
    </div>
  </div>
</nav>

<script>
  import { base } from '$app/paths';
  import SonarMark from './SonarMark.svelte';
  import { DEMO_URL, DOWNLOAD_HREF } from '$lib/links.js';
</script>

<nav>
  <div class="navin">
    <a class="wordmark" href="{base}/">
      <SonarMark size={22} />
      sonar
    </a>
    <div class="navlinks">
      <a class="btn ghost small" href={DEMO_URL}>Open the prototype</a>
      <a class="btn primary small" href={DOWNLOAD_HREF}>Get the app</a>
    </div>
  </div>
</nav>

<script>
  import { base } from '$app/paths';
  import SonarMark from './SonarMark.svelte';
</script>

<footer>
  <div class="wrap footin">
    <a class="wordmark" href="{base}/" style="font-size: 17px;">
      <SonarMark size={18} />
      sonar
    </a>
    <span class="fine">Open protocols — Bluetooth mesh + Nostr · <code>npub1w4j8mc7…q4k9dj</code></span>
  </div>
</footer>

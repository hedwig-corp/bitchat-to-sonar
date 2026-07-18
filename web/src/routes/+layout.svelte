<script>
  import { onMount } from 'svelte';
  import { initI18n } from '$lib/i18n/i18n.svelte.js';
  import '../app.css';

  let { children } = $props();

  onMount(() => {
    initI18n();
  });
</script>

{@render children()}

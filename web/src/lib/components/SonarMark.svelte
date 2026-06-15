<script>
  /**
   * The concentric-rings "sonar" glyph used in the nav, footer and desktop mock.
   * @type {{ size?: number, stroke?: string }}
   */
  let { size = 22, stroke = 'currentColor' } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" {stroke} stroke-width="1.8">
  <circle cx="12" cy="12" r="2" fill={stroke} stroke="none" />
  <circle cx="12" cy="12" r="5.8" />
  <circle cx="12" cy="12" r="9.4" />
</svg>

<script>
  // Dotted texture rings for the hero radar. The design generated these in an
  // inline script; here we compute them at module load so they prerender into
  // the static HTML (identical math: rings at r=52/109/167/206, one dot per
  // ~19px of circumference, around centre 210,210).
  const dots = [52, 109, 167, 206].flatMap((r) => {
    const n = Math.floor((2 * Math.PI * r) / 19);
    return Array.from({ length: n }, (_, i) => {
      const a = (i / n) * 2 * Math.PI;
      return {
        cx: (210 + r * Math.cos(a)).toFixed(1),
        cy: (210 + r * Math.sin(a)).toFixed(1)
      };
    });
  });
</script>

<div class="radarbox">
  <div class="radar" aria-hidden="true">
    <svg class="grid" viewBox="0 0 420 420">
      <circle cx="210" cy="210" r="80" fill="none" stroke="rgba(34,211,238,0.22)" />
      <circle cx="210" cy="210" r="138" fill="none" stroke="rgba(34,211,238,0.22)" />
      <circle cx="210" cy="210" r="196" fill="none" stroke="rgba(34,211,238,0.22)" />
      {#each dots as dot}
        <circle cx={dot.cx} cy={dot.cy} r="1.3" fill="rgba(140,210,230,0.15)" />
      {/each}
    </svg>
    <div class="sweep"></div>
    <div class="pulse"></div>
    <div class="pulse d2"></div>

    <div class="node" style="left: 210px; top: 210px;">
      <span class="avwrap">
        <svg width="58" height="58" viewBox="0 0 66 66"><rect width="66" height="66" fill="hsl(192 40% 36%)" /><rect x="8" y="8" width="10" height="10" fill="hsl(192 70% 76%)" /><rect x="48" y="8" width="10" height="10" fill="hsl(192 70% 76%)" /><rect x="28" y="18" width="10" height="10" fill="hsl(192 64% 68%)" /><rect x="18" y="28" width="10" height="10" fill="hsl(192 70% 76%)" /><rect x="38" y="28" width="10" height="10" fill="hsl(192 70% 76%)" /><rect x="28" y="38" width="10" height="10" fill="hsl(192 64% 68%)" /><rect x="8" y="48" width="10" height="10" fill="hsl(192 64% 68%)" /><rect x="48" y="48" width="10" height="10" fill="hsl(192 64% 68%)" /></svg>
      </span>
      <span class="name">you</span>
    </div>

    <div class="node" style="left: 138px; top: 168px;">
      <span class="avwrap">
        <svg width="48" height="48" viewBox="0 0 66 66"><rect width="66" height="66" fill="hsl(330 40% 38%)" /><rect x="18" y="8" width="10" height="10" fill="hsl(330 70% 78%)" /><rect x="38" y="8" width="10" height="10" fill="hsl(330 70% 78%)" /><rect x="8" y="28" width="10" height="10" fill="hsl(330 64% 70%)" /><rect x="48" y="28" width="10" height="10" fill="hsl(330 64% 70%)" /><rect x="28" y="28" width="10" height="10" fill="hsl(330 70% 78%)" /><rect x="18" y="48" width="10" height="10" fill="hsl(330 64% 70%)" /><rect x="38" y="48" width="10" height="10" fill="hsl(330 64% 70%)" /></svg>
        <span class="presence"></span>
      </span>
      <span class="name">Maya</span>
    </div>

    <div class="node" style="left: 300px; top: 130px;">
      <span class="avwrap">
        <svg width="44" height="44" viewBox="0 0 66 66"><rect width="66" height="66" fill="hsl(150 40% 34%)" /><rect x="8" y="8" width="10" height="10" fill="hsl(150 64% 68%)" /><rect x="48" y="8" width="10" height="10" fill="hsl(150 64% 68%)" /><rect x="28" y="18" width="10" height="10" fill="hsl(150 70% 78%)" /><rect x="8" y="38" width="10" height="10" fill="hsl(150 70% 78%)" /><rect x="48" y="38" width="10" height="10" fill="hsl(150 70% 78%)" /><rect x="28" y="48" width="10" height="10" fill="hsl(150 64% 68%)" /></svg>
        <span class="presence"></span>
      </span>
      <span class="name">Luca</span>
    </div>

    <div class="node" style="left: 256px; top: 318px;">
      <span class="avwrap">
        <svg width="44" height="44" viewBox="0 0 66 66"><rect width="66" height="66" fill="hsl(48 42% 36%)" /><rect x="18" y="18" width="10" height="10" fill="hsl(48 70% 74%)" /><rect x="38" y="18" width="10" height="10" fill="hsl(48 70% 74%)" /><rect x="8" y="38" width="10" height="10" fill="hsl(48 64% 66%)" /><rect x="48" y="38" width="10" height="10" fill="hsl(48 64% 66%)" /><rect x="28" y="38" width="10" height="10" fill="hsl(48 70% 74%)" /></svg>
        <span class="presence"></span>
      </span>
      <span class="name">nettle</span>
    </div>

    <div class="node ghost" style="left: 84px; top: 320px;">
      <span class="avwrap">
        <svg width="38" height="38" viewBox="0 0 66 66"><rect width="66" height="66" fill="hsl(265 38% 40%)" /><rect x="28" y="8" width="10" height="10" fill="hsl(265 66% 78%)" /><rect x="8" y="28" width="10" height="10" fill="hsl(265 66% 78%)" /><rect x="48" y="28" width="10" height="10" fill="hsl(265 66% 78%)" /><rect x="28" y="48" width="10" height="10" fill="hsl(265 60% 70%)" /></svg>
        <span class="netbadge"><svg width="9" height="9" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6"><circle cx="12" cy="12" r="8.2" /><path d="M3.8 12h16.4M12 3.8c-2.7 2.5-4.1 5.2-4.1 8.2s1.4 5.7 4.1 8.2c2.7-2.5 4.1-5.2 4.1-8.2S14.7 6.3 12 3.8z" /></svg></span>
      </span>
      <span class="name">Sofia</span>
    </div>
  </div>
</div>

<script>
  import { onMount } from 'svelte';
  import { browser } from '$app/environment';
  import { base } from '$app/paths';
  import SonarMark from '$lib/components/SonarMark.svelte';
  import { SONAR_DOCS } from '$lib/docs-content.js';
  import { renderMarkdown } from '$lib/markdown.js';
  import { DOWNLOAD_HREF } from '$lib/links.js';

  // Reproduced 1:1 from the Claude Design handoff:
  //   design/handoff/project/Sonar Docs.html + design/handoff/project/sonar/docs-content.js
  // The design routes docs with the URL hash (#doc-id) and uses hash anchors for
  // headings within a doc. We keep that, but only switch documents on a hash that
  // names a doc — a heading anchor scrolls in place instead of resetting to the
  // first page (the prototype's fromHash reset any non-doc hash to Introduction).

  const { groups, docs } = SONAR_DOCS;
  const order = groups.flatMap((g) => g.items).filter((id) => docs[id]);

  let currentId = $state(order[0]);
  let query = $state('');
  let sidebarOpen = $state(false);
  let activeHeading = $state('');

  // Marketing-site link targets for the relative links baked into the doc prose.
  /** @param {string} href */
  function resolveLink(href) {
    /** @type {Record<string, string>} */
    const map = {
      'Sonar Stickers.html': `${base}/stickers`,
      'Sonar%20Stickers.html': `${base}/stickers`,
      'Sonar Landing.html': `${base}/`,
      'Sonar%20Landing.html': `${base}/`
    };
    return map[href] ?? href;
  }

  const doc = $derived(docs[currentId] ?? docs[order[0]]);
  const groupName = $derived(groups.find((g) => g.items.includes(currentId))?.name ?? '');
  const idx = $derived(order.indexOf(currentId));
  const prev = $derived(idx > 0 ? { id: order[idx - 1], ...docs[order[idx - 1]] } : null);
  const next = $derived(idx < order.length - 1 ? { id: order[idx + 1], ...docs[order[idx + 1]] } : null);

  const h1text = $derived(doc.md.match(/^#\s+(.*)$/m)?.[1] ?? doc.title);
  const rendered = $derived(renderMarkdown(doc.md.replace(/^#\s+.*\r?\n?/, ''), { resolveLink }));
  const contentHtml = $derived(rendered.html);
  const toc = $derived(rendered.toc);
  const pills = $derived(
    /** @type {{ cls: string, text: string }[]} */ ([
      doc.status ? { cls: 'gold', text: doc.status } : null,
      doc.kind ? { cls: 'mono', text: doc.kind } : null
    ].filter(Boolean))
  );

  const q = $derived(query.trim().toLowerCase());
  /** @param {string} id */
  function matches(id) {
    const d = docs[id];
    return !q || (d.title + ' ' + (d.blurb || '')).toLowerCase().includes(q);
  }
  /** @param {{ name: string, items: string[] }} g */
  function groupVisible(g) {
    return g.items.some((id) => docs[id] && matches(id));
  }

  function syncFromHash() {
    const id = decodeURIComponent(location.hash.slice(1));
    if (docs[id]) {
      currentId = id;
      sidebarOpen = false;
      window.scrollTo(0, 0);
    }
    // otherwise the hash is a heading anchor — let the browser scroll to it.
  }

  onMount(() => {
    syncFromHash();
    const onHash = () => syncFromHash();
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  });

  // scroll-spy: highlight the on-this-page entry for the heading nearest the top.
  $effect(() => {
    currentId; // re-arm when the document changes
    const entries = toc;
    if (!browser || entries.length < 2) {
      activeHeading = '';
      return;
    }
    const onScroll = () => {
      const heads = /** @type {HTMLElement[]} */ (
        entries.map((t) => document.getElementById(t.id)).filter((el) => el)
      );
      if (!heads.length) return;
      const top = window.scrollY + 90;
      let cur = heads[0];
      heads.forEach((h) => {
        if (h.offsetTop <= top) cur = h;
      });
      activeHeading = cur ? cur.id : '';
    };
    window.addEventListener('scroll', onScroll);
    onScroll();
    return () => window.removeEventListener('scroll', onScroll);
  });
</script>

<svelte:head>
  <title>Sonar Docs — protocol &amp; design</title>
  <meta
    name="description"
    content="Protocol and design documentation for Sonar: BLE + Nostr discovery, the notification envelope, direct Bolt12 payments, BIP-353 addresses, and open sticker packs."
  />
</svelte:head>

<div class="docs">
  <nav>
    <div class="navin">
      <button class="menubtn" aria-label="Menu" onclick={() => (sidebarOpen = !sidebarOpen)}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M4 7h16M4 12h16M4 17h16" />
        </svg>
      </button>
      <a class="wordmark" href="{base}/">
        <SonarMark size={22} />
        sonar<span class="tag">docs</span>
      </a>
      <div class="navsp"></div>
      <div class="navlinks">
        <a class="btn ghost" href="{base}/">Home</a>
        <a class="btn primary" href="{base}/{DOWNLOAD_HREF}">Get the app</a>
      </div>
    </div>
  </nav>

  <div class="scrim" class:open={sidebarOpen} onclick={() => (sidebarOpen = false)} aria-hidden="true"></div>
  <div class="layout">
    <aside class:open={sidebarOpen}>
      <div class="docsearch">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="6" />
          <path d="M15.5 15.5 20 20" />
        </svg>
        <input type="text" placeholder="Search docs…" autocomplete="off" bind:value={query} />
      </div>
      <div class="navtree">
        {#each groups as g}
          {#if groupVisible(g)}
            <div class="navgroup">
              <h4>{g.name}</h4>
              {#each g.items as id}
                {#if docs[id]}
                  <a class="navitem" class:on={id === currentId} class:hidden={!matches(id)} href="#{id}">
                    {docs[id].title}
                  </a>
                {/if}
              {/each}
            </div>
          {/if}
        {/each}
      </div>
    </aside>

    <main>
      <article>
        <div class="crumbs">
          <span>Docs · {groupName}</span>
          <a class="gh" href={doc.gh} target="_blank" rel="noopener">View on GitHub ↗</a>
        </div>
        <div class="md">
          <h1>{h1text}</h1>
          {#if pills.length}
            <div class="doc-meta">
              {#each pills as p}<span class="pill {p.cls}">{p.text}</span>{/each}
            </div>
          {/if}
          {@html contentHtml}
        </div>
        <div class="docnav">
          {#if prev}
            <a class="prev" href="#{prev.id}">
              <span class="lbl">← Previous</span><span class="ttl">{prev.title}</span>
            </a>
          {:else}
            <span></span>
          {/if}
          {#if next}
            <a class="next" href="#{next.id}">
              <span class="lbl">Next →</span><span class="ttl">{next.title}</span>
            </a>
          {/if}
        </div>
      </article>

      {#if toc.length > 1}
        <nav class="toc" aria-label="On this page">
          <h5>On this page</h5>
          {#each toc as t}
            <a class:sub={t.lvl === 3} class:active={activeHeading === t.id} href="#{t.id}">{t.txt}</a>
          {/each}
        </nav>
      {/if}
    </main>
  </div>
</div>

<style>
  /* Reproduced 1:1 from design/handoff/project/Sonar Docs.html. Scoped to the
     .docs wrapper so it does not collide with the landing page's global nav/btn
     styles; the markdown body (injected via {@html}) is styled with :global. */
  .docs {
    --bg: #060809;
    --panel: #0c1013;
    --card: #12171b;
    --card2: #171d22;
    --text: #eff3f4;
    --text2: #9aa6ab;
    --text3: #65717a;
    --hairline: rgba(255, 255, 255, 0.08);
    --hairline2: rgba(255, 255, 255, 0.05);
    --cyan: #22d3ee;
    --cyan-deep: #67e2f4;
    --cyan-fill: #1fc0de;
    --on-cyan: #04222b;
    --cyan-soft: rgba(34, 211, 238, 0.12);
    --gold: #f0b03a;
    --mono: 'IBM Plex Mono', ui-monospace, monospace;
    --sidebar: 268px;
    line-height: 1.6;
  }

  /* top bar */
  .docs nav {
    position: sticky;
    top: 0;
    z-index: 40;
    height: 61px;
    background: rgba(6, 8, 9, 0.85);
    backdrop-filter: blur(12px);
    border-bottom: 1px solid var(--hairline);
  }
  .navin {
    display: flex;
    align-items: center;
    gap: 16px;
    height: 100%;
    padding: 0 22px;
  }
  .wordmark {
    display: flex;
    align-items: center;
    gap: 9px;
    font-size: 19px;
    font-weight: 800;
    letter-spacing: -0.02em;
    color: var(--text);
    text-decoration: none;
  }
  .wordmark:hover {
    text-decoration: none;
  }
  .wordmark :global(svg) {
    color: var(--cyan);
  }
  .tag {
    font-size: 12px;
    font-weight: 600;
    color: var(--text3);
    background: var(--panel);
    border-radius: 6px;
    padding: 2px 8px;
    margin-left: 2px;
  }
  .navsp {
    flex: 1;
  }
  .navlinks {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 8px 15px;
    border-radius: 999px;
    border: none;
    font-family: inherit;
    font-size: 13.5px;
    font-weight: 700;
    text-decoration: none;
    cursor: pointer;
  }
  .btn.ghost {
    background: transparent;
    color: var(--text2);
    box-shadow: inset 0 0 0 1px var(--hairline);
  }
  .btn.ghost:hover {
    color: var(--text);
    text-decoration: none;
  }
  .btn.primary {
    background: var(--cyan-fill);
    color: var(--on-cyan);
  }
  .btn.primary:hover {
    background: var(--cyan);
    text-decoration: none;
  }
  .menubtn {
    display: none;
    width: 38px;
    height: 38px;
    border-radius: 9px;
    border: none;
    background: var(--card);
    color: var(--text);
    cursor: pointer;
    align-items: center;
    justify-content: center;
  }

  .layout {
    display: flex;
    align-items: flex-start;
    max-width: 1400px;
    margin: 0 auto;
  }

  /* sidebar */
  aside {
    width: var(--sidebar);
    flex: none;
    position: sticky;
    top: 61px;
    height: calc(100vh - 61px);
    overflow-y: auto;
    border-right: 1px solid var(--hairline);
    padding: 20px 12px 60px;
  }
  aside::-webkit-scrollbar {
    width: 8px;
  }
  aside::-webkit-scrollbar-thumb {
    background: var(--hairline);
    border-radius: 4px;
  }
  .docsearch {
    display: flex;
    align-items: center;
    gap: 8px;
    background: var(--card);
    border: 1px solid var(--hairline);
    border-radius: 10px;
    padding: 9px 12px;
    margin: 0 6px 16px;
  }
  .docsearch input {
    flex: 1;
    min-width: 0;
    background: none;
    border: none;
    outline: none;
    color: var(--text);
    font-family: inherit;
    font-size: 14px;
  }
  .docsearch input::placeholder {
    color: var(--text3);
  }
  .docsearch svg {
    color: var(--text3);
    flex: none;
  }
  .navgroup {
    margin-bottom: 18px;
  }
  .navgroup h4 {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    color: var(--text3);
    margin: 0 0 6px;
    padding: 0 12px;
  }
  .navitem {
    display: block;
    width: 100%;
    text-align: left;
    border: none;
    background: none;
    cursor: pointer;
    font-family: inherit;
    font-size: 14px;
    font-weight: 550;
    color: var(--text2);
    padding: 8px 12px;
    border-radius: 9px;
    line-height: 1.35;
    text-decoration: none;
  }
  .navitem:hover {
    background: var(--hairline2);
    color: var(--text);
    text-decoration: none;
  }
  .navitem.on {
    background: var(--cyan-soft);
    color: var(--cyan-deep);
    font-weight: 700;
  }
  .navitem.hidden {
    display: none;
  }

  /* content */
  main {
    flex: 1;
    min-width: 0;
    display: flex;
  }
  article {
    flex: 1;
    min-width: 0;
    max-width: 780px;
    padding: 42px 52px 120px;
  }
  .crumbs {
    font-size: 13px;
    color: var(--text3);
    margin-bottom: 8px;
  }
  .crumbs .gh {
    float: right;
    color: var(--cyan-deep);
  }
  .doc-meta {
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 0 0 26px;
    padding-bottom: 18px;
    border-bottom: 1px solid var(--hairline);
    flex-wrap: wrap;
  }
  .pill {
    font-size: 12px;
    font-weight: 650;
    padding: 4px 11px;
    border-radius: 999px;
  }
  .pill.gold {
    background: rgba(240, 176, 58, 0.14);
    color: var(--gold);
  }
  .pill.mono {
    font-family: var(--mono);
    background: var(--panel);
    color: var(--text2);
  }

  /* markdown body (injected html) */
  :global(.docs a) {
    color: var(--cyan-deep);
    text-decoration: none;
  }
  :global(.docs a:hover) {
    text-decoration: underline;
  }
  :global(.docs .md h1) {
    font-size: 33px;
    font-weight: 800;
    letter-spacing: -0.025em;
    line-height: 1.12;
    margin: 0 0 8px;
  }
  :global(.docs .md h2) {
    font-size: 23px;
    font-weight: 750;
    letter-spacing: -0.015em;
    margin: 40px 0 12px;
    padding-top: 8px;
    scroll-margin-top: 74px;
  }
  :global(.docs .md h3) {
    font-size: 18px;
    font-weight: 700;
    margin: 28px 0 8px;
    scroll-margin-top: 74px;
  }
  :global(.docs .md h2 .anchor),
  :global(.docs .md h3 .anchor) {
    opacity: 0;
    color: var(--text3);
    font-weight: 400;
    margin-left: 8px;
  }
  :global(.docs .md h2:hover .anchor),
  :global(.docs .md h3:hover .anchor) {
    opacity: 1;
  }
  :global(.docs .md p) {
    margin: 0 0 15px;
    color: #dde3e5;
  }
  :global(.docs .md ul),
  :global(.docs .md ol) {
    margin: 0 0 15px;
    padding-left: 24px;
    color: #dde3e5;
  }
  :global(.docs .md li) {
    margin: 5px 0;
  }
  :global(.docs .md li::marker) {
    color: var(--text3);
  }
  :global(.docs .md strong) {
    color: var(--text);
    font-weight: 700;
  }
  :global(.docs .md a) {
    font-weight: 600;
  }
  :global(.docs .md code) {
    font-family: var(--mono);
    font-size: 0.86em;
    background: var(--panel);
    border: 1px solid var(--hairline);
    border-radius: 5px;
    padding: 1px 6px;
    color: var(--cyan-deep);
  }
  :global(.docs .md pre) {
    background: #0a0d0f;
    border: 1px solid var(--hairline);
    border-radius: 14px;
    padding: 16px 18px;
    overflow-x: auto;
    margin: 0 0 18px;
  }
  :global(.docs .md pre code) {
    background: none;
    border: none;
    padding: 0;
    color: #c4cdd1;
    font-size: 13px;
    line-height: 1.65;
    display: block;
  }
  :global(.docs .md blockquote) {
    margin: 0 0 16px;
    padding: 4px 16px;
    border-left: 3px solid var(--cyan);
    background: var(--cyan-soft);
    border-radius: 0 10px 10px 0;
    color: var(--text2);
  }
  :global(.docs .md blockquote p:last-child) {
    margin-bottom: 0;
  }
  :global(.docs .md hr) {
    border: none;
    border-top: 1px solid var(--hairline);
    margin: 30px 0;
  }
  :global(.docs .md table) {
    width: 100%;
    border-collapse: collapse;
    margin: 0 0 20px;
    font-size: 14px;
    display: block;
    overflow-x: auto;
  }
  :global(.docs .md th),
  :global(.docs .md td) {
    text-align: left;
    padding: 9px 13px;
    border: 1px solid var(--hairline);
    vertical-align: top;
  }
  :global(.docs .md th) {
    background: var(--panel);
    font-weight: 700;
    color: var(--text);
    white-space: nowrap;
  }
  :global(.docs .md td) {
    color: var(--text2);
  }
  :global(.docs .md tr:nth-child(even) td) {
    background: var(--hairline2);
  }
  :global(.docs .md td code),
  :global(.docs .md th code) {
    white-space: nowrap;
  }

  /* on-this-page */
  .toc {
    width: 210px;
    flex: none;
    position: sticky;
    top: 61px;
    align-self: flex-start;
    max-height: calc(100vh - 61px);
    overflow-y: auto;
    padding: 46px 22px 60px;
  }
  .toc h5 {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    color: var(--text3);
    margin: 0 0 12px;
  }
  .toc a {
    display: block;
    font-size: 13px;
    color: var(--text3);
    padding: 5px 0 5px 12px;
    border-left: 2px solid var(--hairline);
    line-height: 1.4;
    text-decoration: none;
  }
  .toc a:hover {
    color: var(--text);
    text-decoration: none;
  }
  .toc a.sub {
    padding-left: 24px;
    font-size: 12.5px;
  }
  .toc a.active {
    color: var(--cyan-deep);
    border-left-color: var(--cyan);
  }

  .docnav {
    display: flex;
    justify-content: space-between;
    gap: 16px;
    margin-top: 50px;
    padding-top: 22px;
    border-top: 1px solid var(--hairline);
  }
  .docnav a {
    flex: 1;
    padding: 14px 16px;
    border: 1px solid var(--hairline);
    border-radius: 14px;
    background: var(--card);
    text-decoration: none;
  }
  .docnav a:hover {
    border-color: rgba(34, 211, 238, 0.4);
    text-decoration: none;
  }
  .docnav .lbl {
    font-size: 12px;
    color: var(--text3);
    display: block;
  }
  .docnav .ttl {
    font-size: 15px;
    font-weight: 700;
    color: var(--text);
    display: block;
    margin-top: 2px;
  }
  .docnav a.next {
    text-align: right;
  }

  .scrim {
    display: none;
  }
  @media (max-width: 1100px) {
    .toc {
      display: none;
    }
    article {
      max-width: none;
    }
  }
  @media (max-width: 820px) {
    aside {
      position: fixed;
      top: 61px;
      left: 0;
      z-index: 35;
      background: var(--bg);
      transform: translateX(-100%);
      transition: transform 0.2s;
      width: 300px;
    }
    aside.open {
      transform: translateX(0);
    }
    .menubtn {
      display: flex;
    }
    article {
      padding: 28px 22px 100px;
    }
    .scrim.open {
      display: block;
      position: fixed;
      inset: 61px 0 0;
      z-index: 34;
      background: rgba(0, 0, 0, 0.5);
    }
  }
</style>

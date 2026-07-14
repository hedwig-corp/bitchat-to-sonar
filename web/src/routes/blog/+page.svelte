<script>
  import { onMount } from 'svelte';
  import { base } from '$app/paths';
  import SonarMark from '$lib/components/SonarMark.svelte';
  import { SONAR_BLOG, SONAR_BLOG_AUTHOR } from '$lib/blog-content.js';
  import { fetchPostsFromNostr } from '$lib/blog-nostr.js';
  import { fetchAuthorProfile } from '$lib/blog-author.js';
  import { renderMarkdown } from '$lib/markdown.js';
  import { DOWNLOAD_HREF } from '$lib/links.js';

  // Reproduced 1:1 from the Claude Design handoff:
  //   design/handoff/project/Sonar Blog.html + design/handoff/project/sonar/blog-content.js
  // The design routes posts with the URL hash (#post-id): list view when the
  // hash names no post, article view otherwise. Posts ship empty on launch
  // (web/src/lib/blog-content.js), so the list renders an empty-state card the
  // design does not need — same card/hairline language as the post grid.

  // Posts render from the static list first (instant, offline-safe), then the
  // live NIP-23 feed replaces them on mount if it delivers anything. Reactive so
  // the list/article views update once relays answer.
  let posts = $state(SONAR_BLOG.posts);
  const feature = $derived(posts.find((p) => p.feature) ?? posts[0] ?? null);
  const rest = $derived(posts.filter((p) => p !== feature));

  // Author byline (Nostr kind-0 profile): baked-in copy first, refreshed live.
  let author = $state(SONAR_BLOG_AUTHOR);
  let avatarBroken = $state(false);

  let currentId = $state('');

  // Marketing-site link targets for the design-relative links in post prose.
  /** @param {string} href */
  function resolveLink(href) {
    /** @type {Record<string, string>} */
    const map = {
      'Sonar Docs.html': `${base}/docs`,
      'Sonar%20Docs.html': `${base}/docs`,
      'Sonar Landing.html': `${base}/`,
      'Sonar%20Landing.html': `${base}/`,
      'Sonar Prototype.html': `${base}/${DOWNLOAD_HREF}`,
      'Sonar%20Prototype.html': `${base}/${DOWNLOAD_HREF}`,
      'Sonar Status.html': `${base}/status`,
      'Sonar%20Status.html': `${base}/status`,
      'Sonar Stickers.html': `${base}/stickers`,
      'Sonar%20Stickers.html': `${base}/stickers`
    };
    return map[href] ?? href;
  }

  /** @param {string} cat */
  function glyph(cat) {
    if (cat === 'Policy')
      return '<svg width="60" height="60" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M12 3.2l7 2.6v5.1c0 4.3-2.9 7.3-7 8.9-4.1-1.6-7-4.6-7-8.9V5.8z"></path><path d="M9 11.5l2 2 4-4.2"></path></svg>';
    if (cat === 'Design')
      return '<svg width="60" height="60" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="12" cy="12" r="2" fill="currentColor" stroke="none"></circle><circle cx="12" cy="12" r="6"></circle><circle cx="12" cy="12" r="9.6"></circle></svg>';
    return '<svg width="60" height="60" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none"></circle><path d="M8.7 8.7a4.7 4.7 0 000 6.6M15.3 8.7a4.7 4.7 0 010 6.6M6.2 6.2a8.2 8.2 0 000 11.6M17.8 6.2a8.2 8.2 0 010 11.6"></path></svg>';
  }
  /** @param {string} c */
  function catClass(c) {
    return c.toLowerCase();
  }

  const post = $derived(posts.find((p) => p.id === currentId) ?? null);
  const artHtml = $derived(post ? renderMarkdown(post.md, { resolveLink }).html : '');
  const more = $derived(post ? posts.filter((p) => p.id !== post.id).slice(0, 2) : []);

  // Byline name: profile display name, else the post's author tag.
  const authorName = $derived(author?.name || post?.author || 'The Sonar team');
  const avatarUrl = $derived(!avatarBroken ? (author?.picture ?? '') : '');
  const authorInitial = $derived((authorName.trim()[0] ?? 'S').toUpperCase());

  function syncFromHash() {
    const id = decodeURIComponent(location.hash.slice(1));
    if (!id) {
      currentId = '';
      window.scrollTo(0, 0);
    } else if (posts.some((p) => p.id === id)) {
      currentId = id;
      window.scrollTo(0, 0);
    }
    // otherwise the hash is a heading anchor within the article — let the
    // browser scroll to it instead of resetting to the list view.
  }

  onMount(() => {
    syncFromHash();
    const onHash = () => syncFromHash();
    window.addEventListener('hashchange', onHash);

    // Live feed: NIP-23 posts win; static posts fill in any id the feed omits.
    fetchPostsFromNostr()
      .then(({ posts: live, source }) => {
        if (source !== 'nostr' || live.length === 0) return;
        const liveIds = new Set(live.map((p) => p.id));
        const fallback = SONAR_BLOG.posts.filter((p) => !liveIds.has(p.id));
        posts = [...live, ...fallback];
        // A hash that named a post only present in the live feed can now resolve.
        syncFromHash();
      })
      .catch(() => {
        /* keep the static fallback on any failure */
      });

    // Refresh the author byline (name + avatar) from the live kind-0 profile.
    fetchAuthorProfile()
      .then((profile) => {
        if (profile) {
          author = profile;
          avatarBroken = false;
        }
      })
      .catch(() => {
        /* keep the baked-in profile on any failure */
      });

    return () => window.removeEventListener('hashchange', onHash);
  });
</script>

<svelte:head>
  <title>Sonar Blog — notes on privacy, policy &amp; the network</title>
  <meta
    name="description"
    content="Why private, decentralized communication matters more every month — and how we're building it. Notes from the people building Sonar."
  />
</svelte:head>

<div class="blog">
  <nav>
    <div class="navin">
      <a class="wordmark" href="{base}/">
        <SonarMark size={22} />
        sonar<span class="tag">blog</span>
      </a>
      <div class="navlinks">
        <a class="btn ghost" href="{base}/docs">Docs</a>
        <a class="btn ghost home-link" href="{base}/">Home</a>
        <a class="btn primary" href="{base}/{DOWNLOAD_HREF}">Get the app</a>
      </div>
    </div>
  </nav>

  <div class="wrap">
    {#if !post}
      <!-- LIST VIEW -->
      <div class="head">
        <span class="kicker"><span class="dot"></span>Notes on privacy, policy &amp; the network</span>
        <h1 class="page">The Sonar blog</h1>
        <p class="pagesub">
          Why private, decentralized communication matters more every month — and how we&rsquo;re
          building it.
        </p>
      </div>

      {#if feature}
        <a class="feature" href="#{feature.id}">
          <div class="ftext">
            <span class="cat {catClass(feature.cat)}">{feature.cat}</span>
            <h2>{feature.title}</h2>
            <p>{feature.excerpt}</p>
            <div class="meta"><b>{feature.author}</b> · {feature.date} · {feature.read}</div>
          </div>
          <div class="fart"><span class="glyph">{@html glyph(feature.cat)}</span></div>
        </a>
        <div class="grid">
          {#each rest as p (p.id)}
            <a class="post" href="#{p.id}">
              <div class="part"><span class="glyph">{@html glyph(p.cat)}</span></div>
              <div class="pbody">
                <span class="cat {catClass(p.cat)}">{p.cat}</span>
                <h3>{p.title}</h3>
                <p>{p.excerpt}</p>
                <div class="meta">{p.date} · {p.read}</div>
              </div>
            </a>
          {/each}
        </div>
      {:else}
        <div class="empty">
          <span class="eglyph">{@html glyph('')}</span>
          <h2>No posts yet</h2>
          <p>
            The first post is being written. In the meantime, the
            <a href="{base}/docs">docs</a> cover how Sonar works under the hood.
          </p>
        </div>
      {/if}
    {:else}
      <!-- ARTICLE VIEW -->
      <a class="backlink" href="#top" onclick={(e) => { e.preventDefault(); history.replaceState(null, '', '#'); syncFromHash(); }}>← All posts</a>
      <div class="arthead">
        <div class="artmeta">
          <span class="cat {catClass(post.cat)}">{post.cat}</span>
          <span class="byline">
            <span class="avatar" aria-hidden="true">
              {#if avatarUrl}
                <img src={avatarUrl} alt="" loading="lazy" referrerpolicy="no-referrer" onerror={() => (avatarBroken = true)} />
              {:else}
                {authorInitial}
              {/if}
            </span>
            <b>{authorName}</b>
          </span>
          <span class="sep">·</span>{post.date}
          <span class="sep">·</span>{post.read}
        </div>
      </div>
      <div class="md">{@html artHtml}</div>
      <div class="artcta">
        <div class="t">
          <h4>Private by architecture, not by promise</h4>
          <p>Sonar is free and open source — no accounts, no servers, no scanning.</p>
        </div>
        <a class="btn primary" href="{base}/{DOWNLOAD_HREF}">Get Sonar</a>
        <a class="btn ghost" href="{base}/docs">Read the docs</a>
      </div>
      {#if more.length}
        <div class="more">
          <h4>More from the blog</h4>
          <div class="grid">
            {#each more as o (o.id)}
              <a class="post" href="#{o.id}">
                <div class="part"><span class="glyph">{@html glyph(o.cat)}</span></div>
                <div class="pbody">
                  <span class="cat {catClass(o.cat)}">{o.cat}</span>
                  <h3>{o.title}</h3>
                  <p>{o.excerpt}</p>
                  <div class="meta">{o.date}</div>
                </div>
              </a>
            {/each}
          </div>
        </div>
      {/if}
    {/if}
  </div>

  <footer>
    <div class="wrap footin">
      <a class="wordmark foot" href="{base}/">
        <SonarMark size={18} />
        sonar
      </a>
      <span>Written by the people building Sonar · <a href="{base}/">sonar.app</a></span>
    </div>
  </footer>
</div>

<style>
  /* Reproduced 1:1 from design/handoff/project/Sonar Blog.html. Scoped to the
     .blog wrapper so it does not collide with the landing page's global nav/btn
     styles; the article body (injected via {@html}) is styled with :global. */
  .blog {
    --bg: #060809;
    --panel: #0c1013;
    --card: #12171b;
    --card2: #171d22;
    --text: #eff3f4;
    --text2: #9aa6ab;
    --text3: #65717a;
    --hairline: rgba(255, 255, 255, 0.08);
    --cyan: #22d3ee;
    --cyan-deep: #67e2f4;
    --cyan-fill: #1fc0de;
    --on-cyan: #04222b;
    --cyan-soft: rgba(34, 211, 238, 0.12);
    --indigo: #7b79f7;
    --gold: #f0b03a;
    --mono: 'IBM Plex Mono', ui-monospace, monospace;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    line-height: 1.6;
  }
  .blog > .wrap {
    flex: 1;
  }
  .wrap {
    width: 100%;
    max-width: 1080px;
    margin: 0 auto;
    padding: 0 24px;
  }

  nav {
    position: sticky;
    top: 0;
    z-index: 40;
    background: rgba(6, 8, 9, 0.85);
    backdrop-filter: blur(12px);
    border-bottom: 1px solid var(--hairline);
  }
  .navin {
    display: flex;
    align-items: center;
    justify-content: space-between;
    max-width: 1080px;
    margin: 0 auto;
    padding: 16px 24px;
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
  .wordmark.foot {
    font-size: 17px;
  }
  .tag {
    font-size: 12px;
    font-weight: 600;
    color: var(--text3);
    background: var(--panel);
    border-radius: 6px;
    padding: 2px 8px;
  }
  .navlinks {
    display: flex;
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
    cursor: pointer;
    text-decoration: none;
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

  /* ── list view ── */
  .head {
    padding: 52px 0 8px;
  }
  .kicker {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    font-weight: 700;
    color: var(--cyan-deep);
    background: var(--cyan-soft);
    border-radius: 999px;
    padding: 6px 13px;
    margin-bottom: 18px;
  }
  .kicker .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--cyan);
  }
  h1.page {
    font-size: clamp(32px, 4.5vw, 46px);
    font-weight: 800;
    letter-spacing: -0.03em;
    margin: 0 0 12px;
  }
  .pagesub {
    font-size: 17px;
    color: var(--text2);
    max-width: 54ch;
  }

  .feature {
    display: grid;
    grid-template-columns: 1.2fr 1fr;
    gap: 28px;
    align-items: stretch;
    margin: 34px 0 14px;
    background: var(--card);
    border: 1px solid var(--hairline);
    border-radius: 22px;
    overflow: hidden;
    cursor: pointer;
    transition: border-color 0.16s, transform 0.16s;
    color: inherit;
    text-decoration: none;
  }
  .feature:hover {
    border-color: rgba(34, 211, 238, 0.4);
    transform: translateY(-2px);
    text-decoration: none;
  }
  .feature .ftext {
    padding: 30px 30px 28px;
    display: flex;
    flex-direction: column;
  }
  .feature .fart {
    position: relative;
    background:
      radial-gradient(120% 90% at 80% 10%, rgba(34, 211, 238, 0.16), transparent 60%),
      radial-gradient(90% 80% at 10% 90%, rgba(123, 121, 247, 0.18), transparent 60%),
      var(--panel);
    min-height: 220px;
    overflow: hidden;
  }
  .cat {
    font-size: 11.5px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--cyan-deep);
  }
  .cat.policy {
    color: var(--gold);
  }
  .cat.design {
    color: var(--indigo);
  }
  .feature h2 {
    font-size: 27px;
    font-weight: 800;
    letter-spacing: -0.02em;
    line-height: 1.14;
    margin: 10px 0 12px;
  }
  .feature p {
    font-size: 15px;
    color: var(--text2);
    margin: 0 0 18px;
  }
  .meta {
    margin-top: auto;
    font-size: 13px;
    color: var(--text3);
  }
  .meta b {
    color: var(--text2);
    font-weight: 600;
  }

  .grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 20px;
    margin: 22px 0 40px;
  }
  .post {
    display: flex;
    flex-direction: column;
    background: var(--card);
    border: 1px solid var(--hairline);
    border-radius: 18px;
    overflow: hidden;
    cursor: pointer;
    transition: border-color 0.16s, transform 0.16s;
    color: inherit;
    text-decoration: none;
  }
  .post:hover {
    border-color: rgba(34, 211, 238, 0.4);
    transform: translateY(-2px);
    text-decoration: none;
  }
  .post .part {
    height: 118px;
    background:
      radial-gradient(110% 90% at 75% 15%, rgba(34, 211, 238, 0.14), transparent 62%),
      var(--panel);
    border-bottom: 1px solid var(--hairline);
    position: relative;
    overflow: hidden;
  }
  .post .pbody {
    padding: 18px 18px 20px;
    display: flex;
    flex-direction: column;
    flex: 1;
  }
  .post h3 {
    font-size: 17px;
    font-weight: 750;
    letter-spacing: -0.01em;
    line-height: 1.25;
    margin: 9px 0 8px;
  }
  .post p {
    font-size: 13.5px;
    color: var(--text2);
    margin: 0 0 14px;
    flex: 1;
  }
  .post .meta {
    font-size: 12px;
  }
  .glyph {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: rgba(34, 211, 238, 0.32);
  }
  .feature .glyph {
    color: rgba(34, 211, 238, 0.28);
  }

  /* empty state — not in the design (it always has posts); reuses the same
     card/hairline/glyph language so a postless launch still looks intentional. */
  .empty {
    margin: 34px 0 40px;
    padding: 72px 24px 68px;
    background: var(--card);
    border: 1px solid var(--hairline);
    border-radius: 22px;
    text-align: center;
  }
  .empty .eglyph {
    display: inline-flex;
    color: rgba(34, 211, 238, 0.32);
    margin-bottom: 14px;
  }
  .empty h2 {
    font-size: 22px;
    font-weight: 800;
    letter-spacing: -0.02em;
    margin: 0 0 8px;
  }
  .empty p {
    font-size: 15px;
    color: var(--text2);
    margin: 0 auto;
    max-width: 44ch;
  }
  .empty a {
    color: var(--cyan-deep);
    font-weight: 600;
    text-decoration: none;
  }
  .empty a:hover {
    text-decoration: underline;
  }

  /* ── article view ── */
  .backlink {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 14px;
    font-weight: 600;
    color: var(--text2);
    margin: 32px 0 22px;
    cursor: pointer;
    text-decoration: none;
  }
  .backlink:hover {
    color: var(--text);
    text-decoration: none;
  }
  .arthead {
    max-width: 720px;
    margin: 0 auto;
  }
  .artmeta {
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: 13px;
    color: var(--text3);
    margin-bottom: 22px;
    flex-wrap: wrap;
  }
  .artmeta b {
    color: var(--text2);
    font-weight: 600;
  }
  .artmeta .byline {
    display: inline-flex;
    align-items: center;
    gap: 8px;
  }
  .artmeta .avatar {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    overflow: hidden;
    flex: none;
    display: grid;
    place-items: center;
    font-size: 12px;
    font-weight: 700;
    color: var(--text2);
    background: var(--surface2, rgba(255, 255, 255, 0.06));
    border: 1px solid var(--hair, rgba(255, 255, 255, 0.1));
  }
  .artmeta .avatar img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
  .artmeta .sep {
    color: var(--text3);
    opacity: 0.6;
  }
  .md {
    max-width: 720px;
    margin: 0 auto;
  }
  :global(.blog .md h1) {
    font-size: clamp(30px, 4vw, 40px);
    font-weight: 800;
    letter-spacing: -0.025em;
    line-height: 1.12;
    margin: 0 0 20px;
  }
  :global(.blog .md h2) {
    font-size: 24px;
    font-weight: 750;
    letter-spacing: -0.015em;
    margin: 40px 0 12px;
    scroll-margin-top: 74px;
  }
  :global(.blog .md h3) {
    font-size: 19px;
    font-weight: 700;
    margin: 30px 0 8px;
    scroll-margin-top: 74px;
  }
  :global(.blog .md h2 .anchor),
  :global(.blog .md h3 .anchor) {
    opacity: 0;
    color: var(--text3);
    font-weight: 400;
    margin-left: 8px;
    text-decoration: none;
  }
  :global(.blog .md h2:hover .anchor),
  :global(.blog .md h3:hover .anchor) {
    opacity: 1;
  }
  :global(.blog .md p) {
    margin: 0 0 17px;
    font-size: 17px;
    color: #dce2e4;
    line-height: 1.72;
  }
  :global(.blog .md ul),
  :global(.blog .md ol) {
    margin: 0 0 17px;
    padding-left: 24px;
    font-size: 17px;
    color: #dce2e4;
  }
  :global(.blog .md li) {
    margin: 8px 0;
    line-height: 1.6;
  }
  :global(.blog .md li::marker) {
    color: var(--text3);
  }
  :global(.blog .md strong) {
    color: var(--text);
    font-weight: 700;
  }
  :global(.blog .md a) {
    color: var(--cyan-deep);
    font-weight: 600;
    text-decoration: none;
  }
  :global(.blog .md a:hover) {
    text-decoration: underline;
  }
  :global(.blog .md em) {
    color: var(--text);
    font-style: italic;
  }
  :global(.blog .md code) {
    font-family: var(--mono);
    font-size: 0.85em;
    background: var(--panel);
    border: 1px solid var(--hairline);
    border-radius: 5px;
    padding: 1px 6px;
    color: var(--cyan-deep);
  }
  :global(.blog .md pre) {
    background: #0a0d0f;
    border: 1px solid var(--hairline);
    border-radius: 14px;
    padding: 16px 18px;
    overflow-x: auto;
    margin: 0 0 20px;
  }
  :global(.blog .md pre code) {
    background: none;
    border: none;
    padding: 0;
    color: #c4cdd1;
    font-size: 13.5px;
    line-height: 1.7;
    display: block;
  }
  :global(.blog .md blockquote) {
    margin: 24px 0;
    padding: 4px 22px;
    border-left: 3px solid var(--cyan);
    background: var(--cyan-soft);
    border-radius: 0 12px 12px 0;
  }
  :global(.blog .md blockquote p) {
    font-size: 18px;
    color: var(--text);
    font-style: italic;
    margin: 12px 0;
  }
  :global(.blog .md hr) {
    border: none;
    border-top: 1px solid var(--hairline);
    margin: 34px 0;
  }
  .artcta {
    max-width: 720px;
    margin: 44px auto 0;
    padding: 24px;
    background: var(--card);
    border: 1px solid var(--hairline);
    border-radius: 18px;
    display: flex;
    align-items: center;
    gap: 18px;
    flex-wrap: wrap;
  }
  .artcta .t {
    flex: 1;
    min-width: 200px;
  }
  .artcta h4 {
    margin: 0 0 3px;
    font-size: 17px;
    font-weight: 750;
  }
  .artcta p {
    margin: 0;
    font-size: 13.5px;
    color: var(--text2);
  }
  .more {
    max-width: 720px;
    margin: 40px auto 0;
  }
  .more h4 {
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text3);
    margin: 0 0 14px;
  }

  footer {
    border-top: 1px solid var(--hairline);
    margin-top: 60px;
    padding: 26px 0 44px;
  }
  .footin {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    flex-wrap: wrap;
    font-size: 13px;
    color: var(--text3);
  }
  .footin a {
    color: var(--cyan-deep);
    text-decoration: none;
  }
  .footin a:hover {
    text-decoration: underline;
  }
  .footin .wordmark {
    color: var(--text);
  }
  .footin .wordmark:hover {
    text-decoration: none;
  }

  @media (max-width: 560px) {
    /* Collapse the Home ghost link so wordmark + Docs + CTA fit a ~320px
       viewport (the wordmark already links home) — mirrors the app.css nav. */
    .home-link {
      display: none;
    }
  }
  @media (max-width: 820px) {
    .feature {
      grid-template-columns: 1fr;
    }
    .feature .fart {
      min-height: 150px;
      order: -1;
    }
    .grid {
      grid-template-columns: 1fr;
    }
  }
</style>

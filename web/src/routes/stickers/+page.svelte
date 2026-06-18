<script>
  import { onMount } from 'svelte';
  import { base } from '$app/paths';
  import Nav from '$lib/components/Nav.svelte';
  import Footer from '$lib/components/Footer.svelte';

  const PACK_KIND = 30030;
  const PACK_FORMAT = 'sonar-sticker-pack-v1';
  const DEFAULT_RELAYS = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];
  const QUERY_TIMEOUT_MS = 8000;

  /**
   * @typedef {string[]} NostrTag
   * @typedef {{ id: string, pubkey: string, created_at?: number, kind: number, tags: NostrTag[] }} NostrEvent
   * @typedef {{ kinds: number[], authors?: string[], '#d'?: string[], '#t'?: string[], limit: number }} NostrFilter
   * @typedef {{ width: number, height: number }} StickerDim
   * @typedef {{ shortcode: string, url: string, sha256: string, mime: string, width?: number, height?: number, alt: string, emoji: string }} StickerItem
   * @typedef {{ id: string, pubkey: string, shortPubkey: string, createdAt: number, address: string, title: string, description: string, license: string, cover: StickerItem, stickers: StickerItem[] }} StickerPackView
   * @typedef {{ relay: string, state: string, message: string, events: NostrEvent[] }} RelayResponse
   * @typedef {{ relay: string, state: string, message: string }} RelayState
   */

  let address = '';
  let relays = DEFAULT_RELAYS.join('\n');
  /** @type {StickerPackView[]} */
  let packs = [];
  let selectedAddress = '';
  /** @type {RelayState[]} */
  let relayStates = [];
  let status = 'idle';
  let statusText = 'Ready';
  let copied = false;

  /** @type {StickerPackView | null} */
  let selectedPack = null;
  $: selectedPack = packs.find((pack) => pack.address === selectedAddress) ?? packs[0] ?? null;

  onMount(() => {
    const params = new URLSearchParams(window.location.search);
    const queryAddress = params.get('a') ?? '';
    const queryRelays = params.getAll('relay').filter(isRelayUrl);
    address = queryAddress;
    selectedAddress = queryAddress;
    if (queryRelays.length > 0) {
      relays = queryRelays.join('\n');
    }
    loadPacks();
  });

  async function loadPacks() {
    const relayList = parseRelayList(relays);
    if (relayList.length === 0) {
      status = 'error';
      statusText = 'Add at least one wss relay.';
      relayStates = [];
      packs = [];
      return;
    }

    const filter = buildFilter(address.trim());
    if (!filter) {
      status = 'error';
      statusText = 'Pack address must use 30030:<pubkey>:<identifier>.';
      relayStates = [];
      packs = [];
      return;
    }

    status = 'loading';
    statusText = 'Loading sticker packs';
    relayStates = relayList.map((relay) => ({ relay, state: 'loading', message: 'connecting' }));
    copied = false;

    const responses = await Promise.all(relayList.map((relay) => queryRelay(relay, filter)));
    relayStates = responses.map(({ relay, state, message, events }) => ({
      relay,
      state,
      message: message || `${events.length} event${events.length === 1 ? '' : 's'}`
    }));

    const byId = new Map();
    for (const response of responses) {
      for (const event of response.events) {
        if (!byId.has(event.id)) {
          byId.set(event.id, event);
        }
      }
    }

    /** @type {StickerPackView[]} */
    const parsedPacks = [];
    for (const event of byId.values()) {
      const pack = parsePackEvent(event);
      if (pack) {
        parsedPacks.push(pack);
      }
    }
    packs = parsedPacks.sort((a, b) => b.createdAt - a.createdAt);

    if (packs.length === 0) {
      status = 'empty';
      statusText = 'No sticker packs found.';
      selectedAddress = '';
    } else {
      status = 'ready';
      statusText = `${packs.length} sticker pack${packs.length === 1 ? '' : 's'} found`;
      selectedAddress = address.trim() || packs[0].address;
    }
  }

  /**
   * @param {string} rawAddress
   * @returns {NostrFilter | null}
   */
  function buildFilter(rawAddress) {
    if (!rawAddress) {
      return {
        kinds: [PACK_KIND],
        '#t': [PACK_FORMAT],
        limit: 30
      };
    }
    const parsed = parseAddress(rawAddress);
    if (!parsed) {
      return null;
    }
    return {
      kinds: [PACK_KIND],
      authors: [parsed.pubkey],
      '#d': [parsed.identifier],
      limit: 1
    };
  }

  /**
   * @param {string} value
   * @returns {{ pubkey: string, identifier: string } | null}
   */
  function parseAddress(value) {
    const parts = value.split(':');
    if (parts.length !== 3 || parts[0] !== String(PACK_KIND)) {
      return null;
    }
    const [, pubkey, identifier] = parts;
    if (!/^[0-9a-fA-F]{64}$/.test(pubkey) || !/^[A-Za-z0-9._-]{1,80}$/.test(identifier)) {
      return null;
    }
    return { pubkey: pubkey.toLowerCase(), identifier };
  }

  /**
   * @param {string} value
   * @returns {string[]}
   */
  function parseRelayList(value) {
    return Array.from(new Set(value.split(/\s+/).map((relay) => relay.trim()).filter(isRelayUrl)));
  }

  /**
   * @param {string} value
   */
  function isRelayUrl(value) {
    try {
      const url = new URL(value);
      return url.protocol === 'wss:';
    } catch {
      return false;
    }
  }

  /**
   * @param {string} relay
   * @param {NostrFilter} filter
   * @returns {Promise<RelayResponse>}
   */
  function queryRelay(relay, filter) {
    return new Promise((resolve) => {
      const subId = `sonar-stickers-${Math.random().toString(36).slice(2)}`;
      /** @type {NostrEvent[]} */
      const events = [];
      let settled = false;
      /** @type {WebSocket | undefined} */
      let socket;
      /** @type {ReturnType<typeof setTimeout> | undefined} */
      let timer;

      /**
       * @param {string} state
       * @param {string} message
       */
      const finish = (state, message) => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer) {
          clearTimeout(timer);
        }
        if (socket && socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify(['CLOSE', subId]));
        }
        if (socket && socket.readyState < WebSocket.CLOSING) {
          socket.close();
        }
        resolve({ relay, state, message, events });
      };

      try {
        socket = new WebSocket(relay);
      } catch (error) {
        finish('error', error instanceof Error ? error.message : String(error));
        return;
      }

      timer = setTimeout(() => {
        finish(events.length > 0 ? 'partial' : 'timeout', 'timeout');
      }, QUERY_TIMEOUT_MS);

      socket.addEventListener('open', () => {
        socket.send(JSON.stringify(['REQ', subId, filter]));
      });
      socket.addEventListener('message', (messageEvent) => {
        let payload;
        try {
          payload = JSON.parse(messageEvent.data);
        } catch {
          return;
        }
        if (!Array.isArray(payload) || payload.length < 2) {
          return;
        }
        const [type, id, body] = payload;
        if (id !== subId) {
          return;
        }
        if (type === 'EVENT' && isNostrEvent(body) && body.kind === PACK_KIND) {
          events.push(body);
        }
        if (type === 'EOSE') {
          finish('ok', `${events.length} event${events.length === 1 ? '' : 's'}`);
        }
        if (type === 'CLOSED') {
          finish(events.length > 0 ? 'partial' : 'closed', String(body ?? 'closed'));
        }
        if (type === 'NOTICE') {
          finish(events.length > 0 ? 'partial' : 'error', String(body ?? 'relay notice'));
        }
      });
      socket.addEventListener('error', () => finish('error', 'connection failed'));
      socket.addEventListener('close', () => finish(events.length > 0 ? 'partial' : 'closed', 'closed'));
    });
  }

  /**
   * @param {unknown} value
   * @returns {value is NostrEvent}
   */
  function isNostrEvent(value) {
    return (
      typeof value === 'object' &&
      value !== null &&
      'id' in value &&
      'pubkey' in value &&
      'kind' in value &&
      'tags' in value &&
      typeof value.id === 'string' &&
      typeof value.pubkey === 'string' &&
      value.kind === PACK_KIND &&
      Array.isArray(value.tags)
    );
  }

  /**
   * @param {NostrEvent} event
   * @returns {StickerPackView | null}
   */
  function parsePackEvent(event) {
    if (
      !event ||
      event.kind !== PACK_KIND ||
      typeof event.pubkey !== 'string' ||
      !/^[0-9a-fA-F]{64}$/.test(event.pubkey)
    ) {
      return null;
    }
    if (!hasTagValue(event.tags, 'pack_format', PACK_FORMAT)) {
      return null;
    }
    const identifier = firstTagValue(event.tags, 'd');
    if (!identifier) {
      return null;
    }
    const address = `${PACK_KIND}:${event.pubkey}:${identifier}`;
    /** @type {StickerItem[]} */
    const stickers = [];
    for (const tag of event.tags) {
      if (tag?.[0] !== 'sticker') {
        continue;
      }
      const sticker = parseStickerTag(tag);
      if (sticker) {
        stickers.push(sticker);
      }
    }
    if (stickers.length === 0) {
      return null;
    }
    const cover = parseCoverTag(event.tags) ?? stickers[0];
    return {
      id: event.id,
      pubkey: event.pubkey,
      shortPubkey: `${event.pubkey.slice(0, 8)}...${event.pubkey.slice(-8)}`,
      createdAt: Number(event.created_at ?? 0),
      address,
      title: firstTagValue(event.tags, 'title') || 'Untitled sticker pack',
      description: firstTagValue(event.tags, 'description') || '',
      license: firstTagValue(event.tags, 'license') || '',
      cover,
      stickers
    };
  }

  /**
   * @param {NostrTag} tag
   * @returns {StickerItem | null}
   */
  function parseStickerTag(tag) {
    const [, shortcode, url, sha256, mime, dim, alt, emoji] = tag;
    if (
      !shortcode ||
      !isSafeStickerUrl(url, sha256) ||
      !/^[0-9a-fA-F]{64}$/.test(sha256 ?? '') ||
      !isAllowedMime(mime)
    ) {
      return null;
    }
    const parsedDim = parseDim(dim);
    return {
      shortcode,
      url,
      sha256: sha256.toLowerCase(),
      mime,
      width: parsedDim?.width,
      height: parsedDim?.height,
      alt: alt || `${shortcode} sticker`,
      emoji: emoji || ''
    };
  }

  /**
   * @param {NostrTag[]} tags
   * @returns {StickerItem | null}
   */
  function parseCoverTag(tags) {
    const tag = tags.find((candidate) => candidate?.[0] === 'image');
    if (!tag) {
      return null;
    }
    const [, url, sha256, dim] = tag;
    if (!isSafeStickerUrl(url, sha256) || !/^[0-9a-fA-F]{64}$/.test(sha256 ?? '')) {
      return null;
    }
    const parsedDim = parseDim(dim);
    return {
      shortcode: 'cover',
      url,
      sha256: sha256.toLowerCase(),
      mime: 'image/webp',
      width: parsedDim?.width,
      height: parsedDim?.height,
      alt: 'Sticker pack cover',
      emoji: ''
    };
  }

  /**
   * @param {NostrTag[]} tags
   * @param {string} name
   */
  function firstTagValue(tags, name) {
    return tags.find((tag) => tag?.[0] === name)?.[1] ?? '';
  }

  /**
   * @param {NostrTag[]} tags
   * @param {string} name
   * @param {string} value
   */
  function hasTagValue(tags, name, value) {
    return tags.some((tag) => tag?.[0] === name && tag.includes(value));
  }

  /**
   * @param {string | undefined} value
   * @param {string | undefined} sha256
   */
  function isSafeStickerUrl(value, sha256) {
    if (!value || !sha256) {
      return false;
    }
    try {
      const url = new URL(value);
      return url.protocol === 'https:' && url.href.toLowerCase().includes(String(sha256).toLowerCase());
    } catch {
      return false;
    }
  }

  /**
   * @param {string | undefined} value
   */
  function isAllowedMime(value) {
    return typeof value === 'string' && ['image/webp', 'image/png', 'image/apng', 'image/gif'].includes(value);
  }

  /**
   * @param {string | undefined} value
   * @returns {StickerDim | null}
   */
  function parseDim(value) {
    if (!value) {
      return null;
    }
    const match = /^([1-9][0-9]{0,3})x([1-9][0-9]{0,3})$/.exec(value);
    if (!match) {
      return null;
    }
    const width = Number(match[1]);
    const height = Number(match[2]);
    if (width > 4096 || height > 4096) {
      return null;
    }
    return { width, height };
  }

  /**
   * @param {StickerPackView} pack
   */
  function selectPack(pack) {
    selectedAddress = pack.address;
    address = pack.address;
  }

  async function copyPackLink() {
    if (!selectedPack || typeof navigator === 'undefined' || !navigator.clipboard) {
      return;
    }
    const relayParams = parseRelayList(relays).map((relay) => `relay=${encodeURIComponent(relay)}`);
    const query = [`a=${encodeURIComponent(selectedPack.address)}`, ...relayParams].join('&');
    try {
      await navigator.clipboard.writeText(`${window.location.origin}${base}/stickers?${query}`);
      copied = true;
      setTimeout(() => {
        copied = false;
      }, 1600);
    } catch {
      copied = false;
    }
  }
</script>

<svelte:head>
  <title>Sonar Stickers</title>
  <meta
    name="description"
    content="Browse Sonar sticker packs published on Nostr and hosted by Blossom."
  />
</svelte:head>

<Nav />

<main class="stickers-page">
  <section class="wrap stickers-head">
    <div>
      <p class="label">Sonar Stickers</p>
      <h1>Sticker packs over Nostr.</h1>
      <p class="lede">
        Signal-compatible packs are imported by the CLI, stored on Blossom, and published as
        addressable Sonar sticker events.
      </p>
    </div>
    <div class="statusbar" data-state={status}>
      <span class="status-dot"></span>
      <span>{statusText}</span>
    </div>
  </section>

  <section class="wrap sticker-tool">
    <div class="controls" aria-label="Sticker pack query controls">
      <label>
        <span>Pack address</span>
        <input bind:value={address} placeholder="30030:<pubkey>:signal-..." />
      </label>
      <label>
        <span>Relays</span>
        <textarea bind:value={relays} rows="3"></textarea>
      </label>
      <button class="btn primary" type="button" onclick={loadPacks}>Load</button>
    </div>

    <div class="relay-strip" aria-label="Relay query status">
      {#each relayStates as relay}
        <span class="relay-chip" data-state={relay.state}>
          <span>{relay.relay.replace('wss://', '')}</span>
          <b>{relay.message}</b>
        </span>
      {/each}
    </div>

    <div class="sticker-layout">
      <aside class="pack-list" aria-label="Sticker packs">
        {#if packs.length === 0}
          <div class="empty">No packs loaded.</div>
        {:else}
          {#each packs as pack}
            <button
              class:selected={pack.address === selectedPack?.address}
              class="pack-row"
              type="button"
              onclick={() => selectPack(pack)}
            >
              <img src={pack.cover.url} alt={pack.cover.alt} loading="lazy" />
              <span>
                <strong>{pack.title}</strong>
                <small>{pack.stickers.length} stickers - {pack.shortPubkey}</small>
              </span>
            </button>
          {/each}
        {/if}
      </aside>

      <article class="pack-detail" aria-live="polite">
        {#if selectedPack}
          <header class="detail-head">
            <img src={selectedPack.cover.url} alt={selectedPack.cover.alt} loading="lazy" />
            <div>
              <p class="label">Pack</p>
              <h2>{selectedPack.title}</h2>
              {#if selectedPack.description}
                <p>{selectedPack.description}</p>
              {/if}
              <div class="meta-line">
                <code>{selectedPack.address}</code>
                {#if selectedPack.license}
                  <span>{selectedPack.license}</span>
                {/if}
              </div>
            </div>
            <button class="btn ghost small copy" type="button" onclick={copyPackLink}>
              {copied ? 'Copied' : 'Copy link'}
            </button>
          </header>

          <div class="sticker-grid">
            {#each selectedPack.stickers as sticker}
              <figure>
                <img src={sticker.url} alt={sticker.alt} loading="lazy" />
                <figcaption>
                  <span>{sticker.emoji || ':'}</span>
                  <code>{sticker.shortcode}</code>
                </figcaption>
              </figure>
            {/each}
          </div>
        {:else}
          <div class="empty detail-empty">No sticker pack selected.</div>
        {/if}
      </article>
    </div>
  </section>
</main>

<Footer />

<style>
  .stickers-page {
    min-height: 78vh;
  }

  .stickers-head {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    align-items: end;
    gap: 24px;
    padding-top: 58px;
    padding-bottom: 28px;
  }

  .stickers-head h1 {
    max-width: 720px;
    margin-bottom: 14px;
  }

  .statusbar {
    display: inline-flex;
    align-items: center;
    gap: 9px;
    min-height: 40px;
    padding: 9px 13px;
    border: 1px solid var(--hairline);
    border-radius: 999px;
    color: var(--text2);
    background: var(--card);
    font-size: 13px;
    font-weight: 700;
    white-space: nowrap;
  }

  .status-dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--green);
  }

  .statusbar[data-state='loading'] .status-dot {
    background: var(--gold-fill);
  }

  .statusbar[data-state='error'] .status-dot,
  .statusbar[data-state='empty'] .status-dot {
    background: #ff6b6b;
  }

  .sticker-tool {
    padding-top: 0;
    padding-bottom: 74px;
  }

  .controls {
    display: grid;
    grid-template-columns: minmax(260px, 1fr) minmax(220px, 0.7fr) auto;
    gap: 12px;
    align-items: end;
    padding: 16px;
    border: 1px solid var(--hairline);
    border-radius: 18px;
    background: var(--panel);
  }

  label {
    display: grid;
    gap: 7px;
    min-width: 0;
  }

  label span {
    color: var(--text3);
    font-size: 12px;
    font-weight: 800;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }

  input,
  textarea {
    width: 100%;
    min-width: 0;
    border: 1px solid var(--hairline);
    border-radius: 12px;
    background: #090c0f;
    color: var(--text);
    font: 13px var(--mono);
    outline: none;
  }

  input {
    height: 44px;
    padding: 0 12px;
  }

  textarea {
    resize: vertical;
    min-height: 44px;
    max-height: 120px;
    padding: 10px 12px;
    line-height: 1.45;
  }

  input:focus,
  textarea:focus {
    border-color: rgba(34, 211, 238, 0.55);
    box-shadow: 0 0 0 3px var(--cyan-soft);
  }

  .relay-strip {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    min-height: 32px;
    margin: 14px 0 18px;
  }

  .relay-chip {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 7px 10px;
    border: 1px solid var(--hairline);
    border-radius: 999px;
    background: var(--card);
    color: var(--text2);
    font-size: 12px;
  }

  .relay-chip b {
    color: var(--text3);
    font-weight: 700;
  }

  .relay-chip[data-state='ok'] b,
  .relay-chip[data-state='partial'] b {
    color: var(--green);
  }

  .relay-chip[data-state='error'] b,
  .relay-chip[data-state='timeout'] b {
    color: #ff8a8a;
  }

  .sticker-layout {
    display: grid;
    grid-template-columns: 300px minmax(0, 1fr);
    gap: 18px;
    align-items: start;
  }

  .pack-list {
    display: grid;
    gap: 10px;
  }

  .pack-row {
    display: grid;
    grid-template-columns: 54px minmax(0, 1fr);
    gap: 12px;
    align-items: center;
    width: 100%;
    min-height: 74px;
    padding: 10px;
    border: 1px solid var(--hairline);
    border-radius: 14px;
    background: var(--card);
    color: var(--text);
    text-align: left;
    font: inherit;
    cursor: pointer;
  }

  .pack-row.selected,
  .pack-row:hover {
    border-color: rgba(34, 211, 238, 0.48);
    background: rgba(34, 211, 238, 0.08);
  }

  .pack-row img {
    width: 54px;
    height: 54px;
    border-radius: 12px;
    object-fit: contain;
    background: #080b0d;
  }

  .pack-row strong,
  .pack-row small {
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .pack-row strong {
    font-size: 14px;
    font-weight: 800;
  }

  .pack-row small {
    color: var(--text3);
    font-size: 12px;
    margin-top: 2px;
  }

  .pack-detail {
    min-width: 0;
    border: 1px solid var(--hairline);
    border-radius: 18px;
    background: var(--panel);
    overflow: hidden;
  }

  .detail-head {
    display: grid;
    grid-template-columns: 92px minmax(0, 1fr) auto;
    gap: 18px;
    align-items: center;
    padding: 20px;
    border-bottom: 1px solid var(--hairline);
  }

  .detail-head > img {
    width: 92px;
    height: 92px;
    border-radius: 18px;
    object-fit: contain;
    background: #080b0d;
  }

  .detail-head h2 {
    font-size: 28px;
    margin-bottom: 6px;
  }

  .detail-head p:not(.label) {
    max-width: 70ch;
    margin: 0;
    color: var(--text2);
  }

  .copy {
    align-self: start;
  }

  .meta-line {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
    margin-top: 10px;
    color: var(--text3);
    font-size: 12px;
  }

  code {
    max-width: 100%;
    overflow-wrap: anywhere;
    font-family: var(--mono);
    font-size: 11.5px;
    color: var(--text3);
  }

  .sticker-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(108px, 1fr));
    gap: 12px;
    padding: 18px;
  }

  figure {
    display: grid;
    gap: 10px;
    min-height: 148px;
    margin: 0;
    padding: 12px;
    border: 1px solid var(--hairline);
    border-radius: 14px;
    background: var(--card);
  }

  figure img {
    width: 100%;
    aspect-ratio: 1;
    object-fit: contain;
  }

  figcaption {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    min-width: 0;
    color: var(--text2);
    font-size: 13px;
  }

  figcaption span {
    min-width: 18px;
  }

  figcaption code {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .empty {
    min-height: 110px;
    display: grid;
    place-items: center;
    border: 1px solid var(--hairline);
    border-radius: 14px;
    background: var(--card);
    color: var(--text3);
    font-weight: 700;
    text-align: center;
    padding: 18px;
  }

  .detail-empty {
    min-height: 420px;
    border: none;
    border-radius: 0;
    background: transparent;
  }

  @media (max-width: 900px) {
    .stickers-head,
    .sticker-layout,
    .controls {
      grid-template-columns: 1fr;
    }

    .statusbar {
      justify-self: start;
    }

    .detail-head {
      grid-template-columns: 76px minmax(0, 1fr);
    }

    .detail-head > img {
      width: 76px;
      height: 76px;
      border-radius: 16px;
    }

    .copy {
      grid-column: 1 / -1;
      justify-self: start;
    }
  }

  @media (max-width: 520px) {
    .stickers-head {
      padding-top: 38px;
    }

    .controls,
    .detail-head,
    .sticker-grid {
      padding: 14px;
    }

    .detail-head {
      grid-template-columns: 1fr;
    }

    .detail-head > img {
      width: 86px;
      height: 86px;
    }

    .sticker-grid {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }
</style>

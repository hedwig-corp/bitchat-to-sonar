<script>
	// Reproduced 1:1 from the Claude Design handoff:
	//   design/handoff/project/Sonar Status.html
	//   design/handoff/project/sonar/status-data.js
	// Live relay RTT is measured in the browser over WebSocket. Services and
	// incidents paint from seed first; optional Nostr overlay merges when a
	// publisher pubkey is configured (see status-data.js / status-nostr.js).

	import { onMount } from 'svelte';
	import { base } from '$app/paths';
	import SonarMark from '$lib/components/SonarMark.svelte';
	import { STATUS_SUBSCRIBE_URL } from '$lib/links.js';
	import {
		STATUS_NPUB,
		syntheticHistory,
		worstServiceState
	} from '$lib/status-data.js';
	import { fetchStatusFromNostr, isStatusFeedConfigured } from '$lib/status-nostr.js';
	import { fetchIncidentsFromNostr } from '$lib/status-incidents.js';

	/** @typedef {import('$lib/status-data.js').StatusService} StatusService */
	/** @typedef {import('$lib/status-data.js').StatusIncident} StatusIncident */
	/** @typedef {import('$lib/status-data.js').StatusRelay} StatusRelay */

	const homeHref = `${base}/`;
	const docsHref = `${base}/docs`;
	const subscribeHref =
		STATUS_NPUB && STATUS_NPUB.startsWith('npub1')
			? `https://njump.me/${STATUS_NPUB}`
			: STATUS_SUBSCRIBE_URL;

	/** @type {StatusService[]} */
	let services = [];
	/** @type {StatusRelay[]} */
	let relays = [];
	/** @type {StatusIncident[]} */
	let incidents = [];

	const INCIDENT_DAYS = 2;

	/** @type {'waiting' | 'nostr'} */
	let dataSource = 'waiting';
	let updatedLabel = 'waiting for status feed';

	/** @type {Array<{ url: string, region: string, ms: number | null, pending: boolean }>} */
	let relayRows = relays.map((r) => ({
		url: r.url,
		region: r.region,
		ms: null,
		pending: true
	}));

	let pinging = true;
	let pingNote = 'Pinging relays over live WebSocket connections…';
	/** @type {number} */
	let pingGeneration = 0;

	$: worst = worstServiceState(services);
	$: heroTitle =
		worst === 'ok'
			? 'All systems operational'
			: worst === 'down'
				? 'Major outage'
				: 'Some systems degraded';
	$: heroSubDetail =
		worst === 'ok'
			? ''
			: worst === 'down'
				? 'One or more services are unavailable · '
				: 'Some services are degraded · ';

	/**
	 * @param {StatusService} s
	 * @returns {'ok' | 'warn' | 'down'}
	 */
	function serviceBadge(s) {
		const st = s.state ?? 'ok';
		if (st === 'down') return 'down';
		if (st === 'degraded') return 'warn';
		return 'ok';
	}

	/**
	 * @param {'ok' | 'warn' | 'down'} state
	 */
	function serviceLabel(state) {
		if (state === 'down') return 'Outage';
		if (state === 'warn') return 'Degraded';
		return 'Operational';
	}

	/**
	 * @param {number | null} ms
	 * @param {boolean} pending
	 * @returns {'ok' | 'warn' | 'down' | 'pending'}
	 */
	function classForMs(ms, pending) {
		if (pending || ms === null) return 'pending';
		if (ms < 0) return 'down';
		if (ms > 450) return 'warn';
		return 'ok';
	}

	/**
	 * @param {number | null} ms
	 * @param {boolean} pending
	 */
	function formatMs(ms, pending) {
		if (pending || ms === null) return '…';
		if (ms < 0) return 'timeout';
		return `${Math.round(ms)} ms`;
	}

	/**
	 * @param {number | null} ms
	 */
	function barWidth(ms) {
		if (ms === null || ms < 0) return '100%';
		return `${Math.min(100, Math.max(8, ms / 6))}%`;
	}

	/**
	 * Honest WebSocket open RTT. Error and timeout both report unreachable
	 * (ms = -1) — never synthesize fake latency like the design demo did.
	 * @param {string} url
	 * @param {number} gen
	 * @returns {Promise<number>}
	 */
	function pingRelay(url, gen) {
		return new Promise((resolve) => {
			let done = false;
			/** @type {WebSocket | undefined} */
			let ws;
			const t0 = performance.now();
			const to = setTimeout(() => {
				if (done) return;
				done = true;
				try {
					ws?.close();
				} catch {
					/* ignore */
				}
				resolve(-1);
			}, 4000);

			const finish = (/** @type {number} */ ms) => {
				if (done) return;
				done = true;
				clearTimeout(to);
				try {
					ws?.close();
				} catch {
					/* ignore */
				}
				resolve(ms);
			};

			try {
				const parsed = new URL(url);
				if (parsed.protocol !== 'wss:') {
					finish(-1);
					return;
				}
				ws = new WebSocket(url);
				ws.onopen = () => {
					if (gen !== pingGeneration) {
						finish(-1);
						return;
					}
					finish(performance.now() - t0);
				};
				ws.onerror = () => finish(-1);
			} catch {
				finish(-1);
			}
		});
	}

	async function runPings() {
		const gen = ++pingGeneration;
		pinging = true;
		pingNote = 'Pinging relays over live WebSocket connections…';
		relayRows = relayRows.map((r) => ({ ...r, pending: true, ms: null }));

		const results = await Promise.all(
			relayRows.map(async (row, i) => {
				const ms = await pingRelay(row.url, gen);
				if (gen !== pingGeneration) return ms;
				relayRows[i] = { ...relayRows[i], ms, pending: false };
				relayRows = relayRows;
				return ms;
			})
		);

		if (gen !== pingGeneration) return;

		const ok = results.filter((m) => m >= 0).sort((a, b) => a - b);
		const reachable = ok.length;
		const median = ok.length ? ok[Math.floor(ok.length / 2)] : 0;
		pinging = false;
		pingNote =
			reachable === 0
				? `0/${relayRows.length} relays reachable from your browser just now`
				: `${reachable}/${relayRows.length} relays reachable · median ${Math.round(median)} ms · measured from your browser just now`;
	}

	function refreshUpdatedLabel() {
		const now = new Date().toUTCString().replace('GMT', 'UTC');
		// v1 does not verify schnorr — say "status feed", not "signed feed".
		if (dataSource === 'nostr') {
			updatedLabel = `status feed · updated ${now}`;
		} else {
			updatedLabel = 'waiting for status feed';
		}
	}

	onMount(() => {
		refreshUpdatedLabel();
		runPings();

		if (!isStatusFeedConfigured()) return;

		fetchStatusFromNostr().then(({ payload, source }) => {
			if (!payload || source !== 'nostr') return;
			// Feed data replaces empty state directly.
			const prevRelayKey = relays.map((r) => r.url).join('|');
			services = payload.services;
			incidents = payload.incidents;
			relays = payload.relays;
			const nextRelayKey = relays.map((r) => r.url).join('|');
			if (nextRelayKey !== prevRelayKey) {
				relayRows = relays.map((r) => ({
					url: r.url,
					region: r.region,
					ms: null,
					pending: true
				}));
				runPings();
			}
			dataSource = 'nostr';
			refreshUpdatedLabel();
		});
		fetchIncidentsFromNostr(INCIDENT_DAYS).then((/** @type {StatusIncident[]} */ hist) => {
			if (hist.length > 0) {
				incidents = hist;
				refreshUpdatedLabel();
			}
		});
	});
</script>

<svelte:head>
	<title>Sonar Status</title>
	<meta
		name="description"
		content="Live Sonar service status, public Nostr relay latency from your browser, and past incidents."
	/>
</svelte:head>

<div class="status-page">
	<nav>
		<div class="navin">
			<a class="wordmark" href={homeHref}>
				<SonarMark size={27} />
				sonar<span class="tag">status</span>
			</a>
			<div class="navlinks">
				<a class="btn ghost" href={docsHref}>Docs</a>
				<a class="btn ghost" href={homeHref}>Home</a>
			</div>
		</div>
	</nav>

	<div class="wrap">
		<div class="hero" class:warn={worst === 'warn'} class:down={worst === 'down'}>
			<div class="heroic" aria-hidden="true">
				{#if worst === 'ok'}
					<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6"
						><path d="M5 12.5l4.5 4.5L19 7"></path></svg
					>
				{:else}
					<svg
						width="26"
						height="26"
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="2.6"
						stroke-linecap="round"
						><path d="M12 7v7"></path><path d="M12 17.4v.1"></path></svg
					>
				{/if}
			</div>
			<div class="herotext">
				<div class="herotitle">{heroTitle}</div>
				<div class="herosub">
					<span class="live">●</span>
					{heroSubDetail}{updatedLabel}
				</div>
			</div>
		</div>

		<h2>Sonar services <span class="rt">{services.length} services</span></h2>
		<div class="svc">
			{#if services.length === 0}
			<p class="waiting-state">Waiting for status feed data…</p>
		{:else}
		{#each services as s (s.id)}
				{@const state = serviceBadge(s)}
				{@const hist = syntheticHistory(s.id, s.state ?? 'ok')}
				<div class="row">
					<div class="rowtop">
						<span class="dot {state}"></span>
						<span class="rowname">{s.name}</span>
						<span class="rowdesc">{s.desc}</span>
						<span class="badge {state}">{serviceLabel(state)}</span>
					</div>
					<div class="bars" aria-hidden="true">
						{#each hist as c, i (i)}
							<i class={c === 'ok' ? '' : c} title={c}></i>
						{/each}
					</div>
					<div class="barsmeta">
						<span>90 days ago</span>
						<span>{s.uptime.toFixed(2)}% uptime</span>
						<span>today</span>
					</div>
				</div>
			{/each}
			{/if}
		</div>
		<div class="legend">
			<span><span class="dot ok"></span>Operational</span>
			<span><span class="dot warn"></span>Degraded performance</span>
			<span><span class="dot down"></span>Outage</span>
			<span class="legend-note">Each bar = 1 day · last 90 days (illustrative; live state from status feed when configured)</span>
		</div>

		<h2>
			Relay network
			<span class="rt">
				<button type="button" class="btn ghost rebtn" onclick={runPings} disabled={pinging}
					>Re-run ping</button
				>
			</span>
		</h2>
		<div class="svc">
			{#each relayRows as rl (rl.url)}
				{@const cls = classForMs(rl.ms, rl.pending)}
				<div class="relay">
					<div class="relaymain">
						<div class="relayurl">{rl.url}</div>
						<div class="relayregion">{rl.region}</div>
					</div>
					<div class="ping">
						<div class="pingbar">
							<i
								class={cls === 'ok' || cls === 'pending' ? '' : cls}
								style:width={rl.pending ? '0%' : barWidth(rl.ms)}
							></i>
						</div>
						<span class="pingval" class:pending={cls === 'pending'} class:warn={cls === 'warn'} class:down={cls === 'down'}
							>{formatMs(rl.ms, rl.pending)}</span
						>
					</div>
				</div>
			{/each}
		</div>
		<div class="relaynote">
			{#if pinging}
				<span class="spin"></span>
			{:else}
				<span class="dot ok note-dot"></span>
			{/if}
			{pingNote}
		</div>
		<p class="relay-disclaimer">
			These are Sonar’s client bootstrap relays (iOS + Android defaults). RTT is WebSocket open
			latency from <em>your</em> browser. Geohash channels use a separate GPS relay directory.
		</p>

		<h2>Past incidents</h2>
		{#if incidents.length === 0}
			<p class="empty-incidents">No incidents reported.</p>
		{:else}
			{#each incidents as inc, idx (idx)}
				<div class="inc">
					<div class="incdate">{inc.date}</div>
					<div class="inctitle">
						{inc.title}<span class="itag {inc.level}">{inc.level}</span>
					</div>
					{#each inc.updates as u, uidx (uidx)}
						<div class="upd">
							<span class="updt">{u.t}</span>
							<span
								class="upds"
								class:ok={u.s === 'Resolved' || u.s === 'Completed'}
								class:warn={u.s === 'Monitoring' || u.s === 'Identified'}
								class:down={u.s === 'Investigating'}>{u.s}</span
							>
							<span class="updb">{u.b}</span>
						</div>
					{/each}
				</div>
			{/each}
		{/if}
	</div>

	<footer>
		<div class="wrap footin">
			<span>Sonar Status · all times UTC</span>
			<span class="subscribe"
				><a href={subscribeHref} target="_blank" rel="noopener">Subscribe to updates</a> ·
				<a href={docsHref}>Read the docs</a></span
			>
		</div>
	</footer>
</div>

<style>
	.status-page {
		--bg: #060809;
		--panel: #0c1013;
		--card: #12171b;
		--text: #eff3f4;
		--text2: #9aa6ab;
		--text3: #65717a;
		--hairline: rgba(255, 255, 255, 0.08);
		--cyan-deep: #67e2f4;
		--ok: #41bc76;
		--ok-soft: rgba(65, 188, 118, 0.14);
		--warn: #f0b03a;
		--warn-soft: rgba(240, 176, 58, 0.14);
		--down: #f16a6a;
		--down-soft: rgba(241, 106, 106, 0.14);
		--info: #7b79f7;
		--info-soft: rgba(123, 121, 247, 0.14);
		--mono: 'IBM Plex Mono', ui-monospace, monospace;
		--cyan: #22d3ee;

		background: var(--bg);
		color: var(--text);
		font-family: 'Figtree', system-ui, sans-serif;
		-webkit-font-smoothing: antialiased;
		line-height: 1.55;
		min-height: 100vh;
	}

	.status-page :global(a) {
		color: var(--cyan-deep);
		text-decoration: none;
	}
	.status-page :global(a:hover) {
		text-decoration: underline;
	}

	.wrap {
		max-width: 860px;
		margin: 0 auto;
		padding: 0 24px;
	}

	nav {
		border-bottom: 1px solid var(--hairline);
		position: relative;
		background: transparent;
		backdrop-filter: none;
	}
	.navin {
		display: flex;
		align-items: center;
		justify-content: space-between;
		max-width: 860px;
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
	}
	.wordmark:hover {
		text-decoration: none;
	}
	.wordmark .tag {
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
	.btn:disabled {
		opacity: 0.55;
		cursor: default;
	}

	.hero {
		display: flex;
		align-items: center;
		gap: 18px;
		margin: 34px 0 8px;
		padding: 22px 24px;
		border-radius: 18px;
		background: var(--ok-soft);
		box-shadow: inset 0 0 0 1px rgba(65, 188, 118, 0.25);
		/* Override global landing .hero grid */
		grid-template-columns: unset;
	}
	.hero.warn {
		background: var(--warn-soft);
		box-shadow: inset 0 0 0 1px rgba(240, 176, 58, 0.25);
	}
	.hero.down {
		background: var(--down-soft);
		box-shadow: inset 0 0 0 1px rgba(241, 106, 106, 0.25);
	}
	.heroic {
		width: 48px;
		height: 48px;
		border-radius: 50%;
		flex: none;
		display: flex;
		align-items: center;
		justify-content: center;
		background: var(--ok);
		color: #04140b;
	}
	.hero.warn .heroic {
		background: var(--warn);
		color: #241500;
	}
	.hero.down .heroic {
		background: var(--down);
		color: #2a0808;
	}
	.herotext {
		flex: 1;
		min-width: 0;
	}
	.herotitle {
		font-size: 22px;
		font-weight: 800;
		letter-spacing: -0.02em;
	}
	.herosub {
		font-size: 13.5px;
		color: var(--text2);
		margin-top: 2px;
	}
	.herosub .live {
		color: var(--ok);
		font-weight: 600;
	}

	h2 {
		font-size: 15px;
		font-weight: 700;
		letter-spacing: 0.02em;
		margin: 34px 0 12px;
		display: flex;
		align-items: center;
		gap: 10px;
	}
	h2 .rt {
		margin-left: auto;
		font-size: 12px;
		font-weight: 500;
		color: var(--text3);
	}

	.svc {
		background: var(--card);
		border: 1px solid var(--hairline);
		border-radius: 14px;
		overflow: hidden;
	}
	.row {
		padding: 15px 18px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.05);
	}
	.svc .row:last-child {
		border-bottom: none;
	}
	.rowtop {
		display: flex;
		align-items: center;
		gap: 10px;
	}
	.rowname {
		font-size: 15px;
		font-weight: 650;
	}
	.rowdesc {
		font-size: 12.5px;
		color: var(--text3);
		font-weight: 400;
		margin-left: 2px;
	}
	.badge {
		margin-left: auto;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font-size: 12.5px;
		font-weight: 650;
	}
	.dot {
		width: 9px;
		height: 9px;
		border-radius: 50%;
		flex: none;
		display: inline-block;
	}
	.dot.ok {
		background: var(--ok);
	}
	.dot.warn {
		background: var(--warn);
	}
	.dot.down {
		background: var(--down);
	}
	.badge.ok {
		color: var(--ok);
	}
	.badge.warn {
		color: var(--warn);
	}
	.badge.down {
		color: var(--down);
	}

	.bars {
		display: flex;
		flex-direction: row;
		gap: 2px;
		margin-top: 11px;
		height: 30px;
		align-items: stretch;
		flex: unset;
	}
	.bars i {
		flex: 1;
		border-radius: 2px;
		background: var(--ok);
		opacity: 0.85;
		transition: opacity 0.1s;
		cursor: pointer;
		display: block;
	}
	.bars i.warn {
		background: var(--warn);
	}
	.bars i.down {
		background: var(--down);
	}
	.bars i:hover {
		opacity: 1;
	}
	.barsmeta {
		display: flex;
		justify-content: space-between;
		font-size: 11.5px;
		color: var(--text3);
		margin-top: 7px;
	}

	.relay {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 13px 18px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.05);
	}
	.relay:last-child {
		border-bottom: none;
	}
	.relayurl {
		font-family: var(--mono);
		font-size: 13px;
		font-weight: 500;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.relayregion {
		font-size: 12px;
		color: var(--text3);
		margin-top: 1px;
	}
	.relaymain {
		flex: 1;
		min-width: 0;
	}
	.ping {
		display: flex;
		align-items: center;
		gap: 10px;
		flex: none;
	}
	.pingbar {
		width: 92px;
		height: 6px;
		border-radius: 3px;
		background: var(--panel);
		overflow: hidden;
	}
	.pingbar i {
		display: block;
		height: 100%;
		border-radius: 3px;
		background: var(--ok);
		transition: width 0.5s;
	}
	.pingbar i.warn {
		background: var(--warn);
	}
	.pingbar i.down {
		background: var(--down);
	}
	.pingval {
		font-family: var(--mono);
		font-size: 13px;
		font-weight: 600;
		min-width: 62px;
		text-align: right;
	}
	.pingval.pending {
		color: var(--text3);
	}
	.pingval.warn {
		color: var(--warn);
	}
	.pingval.down {
		color: var(--down);
	}
	.relaynote {
		font-size: 12px;
		color: var(--text3);
		margin-top: 10px;
		display: flex;
		align-items: center;
		gap: 7px;
	}
	.note-dot {
		width: 8px;
		height: 8px;
	}
	.relay-disclaimer {
		font-size: 12px;
		color: var(--text3);
		margin: 8px 0 0;
	}
	.spin {
		width: 12px;
		height: 12px;
		border: 2px solid var(--hairline);
		border-top-color: var(--cyan);
		border-radius: 50%;
		animation: sp 0.7s linear infinite;
		flex: none;
	}
	@keyframes sp {
		to {
			transform: rotate(360deg);
		}
	}
	.rebtn {
		margin-left: auto;
	}

	.waiting-state {
		font-size: 14px;
		color: var(--text3);
		margin: 0 0 26px;
	}
	.empty-incidents {
		font-size: 13.5px;
		color: var(--text3);
		margin: 0 0 26px;
	}
	.inc {
		border-left: 2px solid var(--hairline);
		padding: 2px 0 2px 18px;
		margin-bottom: 26px;
	}
	.incdate {
		font-size: 12.5px;
		color: var(--text3);
		font-weight: 600;
	}
	.inctitle {
		font-size: 16px;
		font-weight: 700;
		margin: 2px 0 12px;
		display: flex;
		align-items: center;
		gap: 9px;
	}
	.itag {
		font-size: 11px;
		font-weight: 700;
		padding: 3px 9px;
		border-radius: 999px;
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}
	.itag.degraded {
		background: var(--warn-soft);
		color: var(--warn);
	}
	.itag.maintenance {
		background: var(--info-soft);
		color: var(--info);
	}
	.itag.down {
		background: var(--down-soft);
		color: var(--down);
	}
	.upd {
		display: flex;
		gap: 12px;
		margin-bottom: 11px;
	}
	.updt {
		font-family: var(--mono);
		font-size: 11.5px;
		color: var(--text3);
		flex: none;
		width: 74px;
		padding-top: 1px;
	}
	.upds {
		font-size: 13.5px;
		font-weight: 700;
		flex: none;
		width: 92px;
	}
	.upds.ok {
		color: var(--ok);
	}
	.upds.warn {
		color: var(--warn);
	}
	.upds.down {
		color: var(--down);
	}
	.updb {
		font-size: 13.5px;
		color: var(--text2);
		flex: 1;
	}

	.legend {
		display: flex;
		gap: 18px;
		flex-wrap: wrap;
		font-size: 12px;
		color: var(--text3);
		margin-top: 12px;
	}
	.legend span {
		display: flex;
		align-items: center;
		gap: 6px;
	}
	.legend-note {
		margin-left: auto;
	}

	footer {
		border-top: 1px solid var(--hairline);
		margin-top: 50px;
		padding: 26px 0 44px;
		background: transparent;
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
	.subscribe {
		font-size: 13px;
	}

	@media (max-width: 620px) {
		.rowdesc {
			display: none;
		}
		.relayregion {
			display: none;
		}
		.pingbar {
			width: 60px;
		}
		.legend-note {
			margin-left: 0;
		}
	}
</style>

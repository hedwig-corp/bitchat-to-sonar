// Sonar status — service + relay definitions and seed incidents.
// Reproduced from design/handoff/project/sonar/status-data.js with plain-text
// fields (no HTML entities). Relay RTT is measured live in the browser;
// history bars are deterministic illustrations until a signed feed supplies
// real history. Optional Nostr overlay constants live here so the page and
// status-nostr helper share one source of truth.

/** @typedef {'ok' | 'degraded' | 'down'} ServiceState */
/** @typedef {'degraded' | 'maintenance' | 'down'} IncidentLevel */
/** @typedef {'Investigating' | 'Identified' | 'Monitoring' | 'Resolved' | 'Completed'} UpdateStatus */

/**
 * @typedef {{
 *   id: string,
 *   name: string,
 *   desc: string,
 *   uptime: number,
 *   state?: ServiceState
 * }} StatusService
 */

/**
 * @typedef {{ url: string, region: string }} StatusRelay
 */

/**
 * @typedef {{ t: string, s: UpdateStatus, b: string }} IncidentUpdate
 */

/**
 * @typedef {{
 *   date: string,
 *   title: string,
 *   level: IncidentLevel,
 *   updates: IncidentUpdate[]
 * }} StatusIncident
 */

/**
 * @typedef {{
 *   services: StatusService[],
 *   relays: StatusRelay[],
 *   incidents: StatusIncident[]
 * }} StatusPayload
 */

/** Replaceable status document kind (provisional until ops publisher lands). */
export const STATUS_EVENT_KIND = 30078;

/** `d` tag for the replaceable status event. */
export const STATUS_EVENT_D = 'sonar-status';

/**
 * Hex pubkey of the ops status publisher. Empty = do not query Nostr (seed only).
 * When set, status-nostr filters `authors: [STATUS_PUBKEY_HEX]`.
 * @type {string}
 */
export const STATUS_PUBKEY_HEX = 'e11b61c2a0e8b48159bb9991dc20fa03054e87eeb1da8f0f8b310580b940f428';

/**
 * Public npub for “Subscribe to updates” (bech32). Empty hides a real profile link
 * and falls back to STATUS_SUBSCRIBE_URL.
 * @type {string}
 */
export const STATUS_NPUB = 'npub1uydkrs4qaz6gzkdmnxgacg86qvz5aplwk8dg7rutxyzcpw2q7s5qr5c90c';

/** Relays used for the optional status-feed query (subset of public network). */
export const STATUS_FEED_RELAYS = [
	'wss://relay.damus.io',
	'wss://nos.lol',
	'wss://relay.primal.net',
	'wss://nostr.relay.hedwig.sh'
];

/** Seed payload — first paint only.
 * Services start as "unknown/operational skeleton" with empty incidents.
 * Live state comes from sonar-status → kind 30078 (see docs/SONAR-STATUS.md).
 * Relay list matches Sonar client bootstrap defaults (iOS + Android/JVM union).
 */
export const SONAR_STATUS_SEED = /** @type {StatusPayload} */ ({
	services: [
		{
			id: 'dm',
			name: 'Encrypted DMs (Marmot)',
			desc: 'End-to-end encrypted direct messages',
			uptime: 100
		},
		{
			id: 'groups',
			name: 'Group chats (White Noise)',
			desc: 'MLS-over-Nostr encrypted groups',
			uptime: 100
		},
		{
			id: 'media',
			name: 'Media messages',
			desc: 'Image, video & file delivery',
			uptime: 100
		},
		{
			id: 'voice',
			name: 'Voice messages',
			desc: 'Push-to-talk voice notes',
			uptime: 100
		},
		{
			id: 'calls',
			name: 'Voice & video calls',
			desc: 'Iroh transport, Marmot signaling',
			uptime: 100
		},
		{
			id: 'payments',
			name: 'Payments (Bolt12)',
			desc: 'Direct Lightning wallet payments',
			uptime: 100
		},
		{
			id: 'push',
			name: 'Push notifications',
			desc: 'Encrypted push envelopes',
			uptime: 100
		},
		{
			id: 'stickers',
			name: 'Stickers directory',
			desc: 'Nostr sticker-pack index',
			uptime: 100
		}
	],
	// Sonar client bootstrap relays (union of iOS NostrRelayManager + Android/JVM SonarCore).
	// Geo-channel relays are chosen dynamically from relays_gps.csv and are not listed here.
	relays: [
		{ url: 'wss://relay.damus.io', region: 'Global · CDN' },
		{ url: 'wss://nos.lol', region: 'EU · Germany' },
		{ url: 'wss://relay.primal.net', region: 'US · East' },
		{ url: 'wss://offchain.pub', region: 'Global · iOS default' },
		{ url: 'wss://nostr21.com', region: 'Global · iOS default' },
		{ url: 'wss://relay.kaleidoswap.com', region: 'Global · client default' },
		{ url: 'wss://nostr.relay.hedwig.sh', region: 'Hedwig · Sonar' }
	],
	// No mock history — incidents appear only from the status feed / operator notes.
	incidents: []
});

/**
 * Deterministic 90-day illustration bars (FNV + LCG), matching the handoff.
 * Not telemetry — visual continuity until a feed supplies real history.
 * @param {string} id
 * @param {ServiceState} [state]
 * @returns {Array<'ok' | 'warn' | 'down'>}
 */

/**
 * Merge a live feed payload onto the seed skeleton.
 * - services: upsert by id (feed wins); seed-only rows stay as placeholders
 * - incidents: feed replaces entirely (seed is empty by design)
 * - relays: non-empty feed list replaces seed; otherwise keep seed defaults
 * @param {StatusPayload} seed
 * @param {StatusPayload} feed
 * @returns {StatusPayload}
 */
export function mergeStatusPayload(seed, feed) {
	/** @type {Map<string, StatusService>} */
	const byId = new Map();
	for (const s of seed.services) {
		byId.set(s.id, { ...s });
	}
	for (const s of feed.services) {
		byId.set(s.id, { ...s });
	}
	return {
		services: Array.from(byId.values()),
		relays: feed.relays && feed.relays.length > 0 ? feed.relays.slice() : seed.relays.slice(),
		incidents: Array.isArray(feed.incidents) ? feed.incidents.slice() : []
	};
}

/**
 * Placeholder 90-day bars until real daily samples exist.
 * @param {string} id
 * @param {ServiceState} [state]
 * @returns {Array<'ok' | 'warn' | 'down'>}
 */
export function syntheticHistory(id, state = 'ok') {
	/** @type {Array<'ok' | 'warn' | 'down'>} */
	const out = [];
	// Placeholder bars until real daily samples exist. Operational services stay green;
	// only current degraded/down states tint the most recent days (no random mock outages).
	for (let d = 0; d < 90; d++) {
		/** @type {'ok' | 'warn' | 'down'} */
		let cls = 'ok';
		if (state === 'degraded' && d > 85) cls = 'warn';
		else if (state === 'down' && d > 87) cls = 'down';
		out.push(cls);
	}
	// keep id referenced so call sites stay stable when we switch to real history
	void id;
	return out;
}

/**
 * Worst aggregate state among services for the hero banner.
 * @param {StatusService[]} services
 * @returns {'ok' | 'warn' | 'down'}
 */
export function worstServiceState(services) {
	let worst = /** @type {'ok' | 'warn' | 'down'} */ ('ok');
	for (const s of services) {
		const st = s.state ?? 'ok';
		if (st === 'down') return 'down';
		if (st === 'degraded') worst = 'warn';
	}
	return worst;
}

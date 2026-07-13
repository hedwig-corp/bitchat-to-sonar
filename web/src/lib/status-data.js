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
export const STATUS_PUBKEY_HEX = '';

/**
 * Public npub for “Subscribe to updates” (bech32). Empty hides a real profile link
 * and falls back to STATUS_SUBSCRIBE_URL.
 * @type {string}
 */
export const STATUS_NPUB = '';

/** Relays used for the optional status-feed query (subset of public network). */
export const STATUS_FEED_RELAYS = [
	'wss://relay.damus.io',
	'wss://nos.lol',
	'wss://relay.primal.net'
];

/** Seed payload — first paint; optional Nostr overlay may replace services/incidents. */
export const SONAR_STATUS_SEED = /** @type {StatusPayload} */ ({
	services: [
		{
			id: 'dm',
			name: 'Encrypted DMs (Marmot)',
			desc: 'End-to-end encrypted direct messages',
			uptime: 99.95
		},
		{
			id: 'groups',
			name: 'Group chats (White Noise)',
			desc: 'MLS-over-Nostr encrypted groups',
			uptime: 99.91
		},
		{
			id: 'media',
			name: 'Media messages',
			desc: 'Image, video & file delivery',
			uptime: 99.9
		},
		{
			id: 'voice',
			name: 'Voice messages',
			desc: 'Push-to-talk voice notes',
			uptime: 99.93
		},
		{
			id: 'calls',
			name: 'Voice & video calls',
			desc: 'Iroh transport, Marmot signaling',
			uptime: 99.72,
			state: 'degraded'
		},
		{
			id: 'payments',
			name: 'Payments (Bolt12)',
			desc: 'Direct Lightning wallet payments',
			uptime: 99.94
		},
		{
			id: 'push',
			name: 'Push notifications',
			desc: 'Encrypted push envelopes',
			uptime: 99.88
		},
		{
			id: 'stickers',
			name: 'Stickers directory',
			desc: 'Nostr sticker-pack index',
			uptime: 100
		}
	],
	// Common public relays Sonar clients can use (not a full geo-directory dump).
	relays: [
		{ url: 'wss://relay.damus.io', region: 'Global · CDN' },
		{ url: 'wss://nos.lol', region: 'EU · Germany' },
		{ url: 'wss://relay.primal.net', region: 'US · East' },
		{ url: 'wss://relay.snort.social', region: 'EU · UK' },
		{ url: 'wss://nostr.wine', region: 'US · Central' },
		{ url: 'wss://relay.nostr.band', region: 'Global · Anycast' }
	],
	incidents: [
		{
			date: 'Jul 9, 2026',
			title: 'Elevated call setup latency',
			level: 'degraded',
			updates: [
				{
					t: '14:02 UTC',
					s: 'Resolved',
					b: 'Iroh relay capacity restored. Call setup times back to normal.'
				},
				{
					t: '13:20 UTC',
					s: 'Monitoring',
					b: 'Added relay capacity in US-East; setup times improving.'
				},
				{
					t: '12:41 UTC',
					s: 'Investigating',
					b: 'Some voice/video calls are slow to connect. Messaging is unaffected.'
				}
			]
		},
		{
			date: 'Jun 28, 2026',
			title: 'Push notification delays (Android)',
			level: 'degraded',
			updates: [
				{
					t: '09:15 UTC',
					s: 'Resolved',
					b: 'FCM delivery normalized after upstream provider recovery.'
				},
				{
					t: '07:50 UTC',
					s: 'Identified',
					b: 'Upstream push provider degradation. Foreground/nearby delivery unaffected.'
				}
			]
		},
		{
			date: 'Jun 14, 2026',
			title: 'Scheduled relay maintenance',
			level: 'maintenance',
			updates: [
				{
					t: '03:00 UTC',
					s: 'Completed',
					b: 'Relay pool upgraded with no user-visible downtime.'
				}
			]
		}
	]
});

/**
 * Deterministic 90-day illustration bars (FNV + LCG), matching the handoff.
 * Not telemetry — visual continuity until a feed supplies real history.
 * @param {string} id
 * @param {ServiceState} [state]
 * @returns {Array<'ok' | 'warn' | 'down'>}
 */
export function syntheticHistory(id, state = 'ok') {
	/** @type {Array<'ok' | 'warn' | 'down'>} */
	const out = [];
	let r = fnv1a(id);
	for (let d = 0; d < 90; d++) {
		r = (Math.imul(r, 1664525) + 1013904223) >>> 0;
		const v = r / 4294967296;
		/** @type {'ok' | 'warn' | 'down'} */
		let cls = 'ok';
		if (state === 'degraded' && d > 85) cls = v < 0.5 ? 'warn' : 'ok';
		else if (state === 'down' && d > 88) cls = 'down';
		else if (v > 0.985) cls = 'down';
		else if (v > 0.955) cls = 'warn';
		out.push(cls);
	}
	return out;
}

/**
 * @param {string} s
 * @returns {number}
 */
function fnv1a(s) {
	let h = 2166136261;
	for (let i = 0; i < s.length; i++) {
		h ^= s.charCodeAt(i);
		h = Math.imul(h, 16777619);
	}
	return h >>> 0;
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

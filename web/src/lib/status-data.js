/**
 * Sonar status feed configuration.
 *
 * When STATUS_PUBKEY_HEX is set, the website REQs kind 30078 (d=sonar-status)
 * from STATUS_FEED_RELAYS and renders the live status document.
 *
 * There is NO static seed fallback — the page shows a "waiting" state until
 * the feed delivers data. This ensures only measured data is shown.
 */

/** @typedef {'ok' | 'degraded' | 'down'} ServiceState */

/**
 * @typedef {Object} StatusService
 * @property {string} id
 * @property {string} name
 * @property {string} desc
 * @property {number} uptime
 * @property {ServiceState} [state]
 */

/**
 * @typedef {Object} StatusRelay
 * @property {string} url
 * @property {string} region
 */

/**
 * @typedef {Object} IncidentUpdate
 * @property {string} t
 * @property {string} s
 * @property {string} b
 */

/**
 * @typedef {Object} StatusIncident
 * @property {string} date
 * @property {string} title
 * @property {'degraded' | 'maintenance' | 'down'} level
 * @property {IncidentUpdate[]} updates
 */

/** @typedef {StatusIncident & {_created_at?: number}} InternalIncident */

/**
 * @typedef {Object} StatusPayload
 * @property {StatusService[]} services
 * @property {StatusRelay[]} relays
 * @property {StatusIncident[]} incidents
 */

/** Replaceable status document kind. */
export const STATUS_EVENT_KIND = 30078;

/** `d` tag for the replaceable status event. */
export const STATUS_EVENT_D = 'sonar-status';

/** Hex pubkey of the ops status publisher. */
export const STATUS_PUBKEY_HEX = 'e11b61c2a0e8b48159bb9991dc20fa03054e87eeb1da8f0f8b310580b940f428';

/** Public npub for "Subscribe to updates". */
export const STATUS_NPUB = 'npub1uydkrs4qaz6gzkdmnxgacg86qvz5aplwk8dg7rutxyzcpw2q7s5qr5c90c';

/** Relays used for the status-feed query. */
export const STATUS_FEED_RELAYS = [
	'wss://relay.damus.io',
	'wss://nos.lol',
	'wss://relay.primal.net',
	'wss://nostr.relay.hedwig.sh'
];

/**
 * Placeholder 90-day bars until real daily samples exist.
 * @param {string} id
 * @param {ServiceState} [state]
 * @returns {Array<'ok' | 'warn' | 'down'>}
 */
export function syntheticHistory(id, state = 'ok') {
	/** @type {Array<'ok' | 'warn' | 'down'>} */
	const out = [];
	for (let d = 0; d < 90; d++) {
		/** @type {'ok' | 'warn' | 'down'} */
		let cls = 'ok';
		if (state === 'degraded' && d > 85) cls = 'warn';
		else if (state === 'down' && d > 87) cls = 'down';
		out.push(cls);
	}
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

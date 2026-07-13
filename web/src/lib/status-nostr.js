// Optional best-effort reader for a signed Sonar status document on Nostr.
// Pattern mirrors web/src/routes/stickers/+page.svelte (browser WebSocket REQ).
//
// Trust model (v1):
// - Requires STATUS_PUBKEY_HEX (authors filter). Empty pubkey → no query.
// - Does NOT verify schnorr signatures (same as stickers page; no crypto dep).
// - Schema-validates content before returning; invalid events are ignored.
// - Newest created_at among valid events wins.

import {
	STATUS_EVENT_D,
	STATUS_EVENT_KIND,
	STATUS_FEED_RELAYS,
	STATUS_PUBKEY_HEX
} from './status-data.js';

const QUERY_TIMEOUT_MS = 8000;
const MAX_CONTENT_BYTES = 64_000;

/** @typedef {import('./status-data.js').StatusPayload} StatusPayload */
/** @typedef {import('./status-data.js').StatusService} StatusService */
/** @typedef {import('./status-data.js').StatusIncident} StatusIncident */
/** @typedef {import('./status-data.js').IncidentUpdate} IncidentUpdate */

/**
 * @typedef {{
 *   id: string,
 *   pubkey: string,
 *   created_at?: number,
 *   kind: number,
 *   tags: string[][],
 *   content?: string
 * }} NostrEvent
 */

/**
 * @returns {boolean}
 */
export function isStatusFeedConfigured() {
	return /^[0-9a-fA-F]{64}$/.test(STATUS_PUBKEY_HEX);
}

/**
 * Query STATUS_FEED_RELAYS for the latest valid status document.
 * @returns {Promise<{ payload: StatusPayload | null, source: string }>}
 */
export async function fetchStatusFromNostr() {
	if (!isStatusFeedConfigured()) {
		return { payload: null, source: 'seed' };
	}

	const author = STATUS_PUBKEY_HEX.toLowerCase();
	/** @type {{ kinds: number[], authors: string[], '#d': string[], limit: number }} */
	const filter = {
		kinds: [STATUS_EVENT_KIND],
		authors: [author],
		'#d': [STATUS_EVENT_D],
		limit: 1
	};

	const relays = STATUS_FEED_RELAYS.filter(isWssUrl);
	if (relays.length === 0) {
		return { payload: null, source: 'seed' };
	}

	const responses = await Promise.all(relays.map((relay) => queryRelay(relay, filter)));
	/** @type {NostrEvent[]} */
	const events = [];
	for (const res of responses) {
		for (const ev of res.events) {
			if (
				ev.kind === STATUS_EVENT_KIND &&
				typeof ev.pubkey === 'string' &&
				ev.pubkey.toLowerCase() === author
			) {
				events.push(ev);
			}
		}
	}

	if (events.length === 0) {
		return { payload: null, source: 'seed' };
	}

	events.sort((a, b) => (b.created_at ?? 0) - (a.created_at ?? 0));
	for (const event of events) {
		const payload = parseStatusContent(event.content);
		if (payload) {
			return { payload, source: 'nostr' };
		}
	}
	return { payload: null, source: 'seed' };
}

/**
 * @param {string | undefined} content
 * @returns {StatusPayload | null}
 */
export function parseStatusContent(content) {
	if (typeof content !== 'string' || content.length === 0 || content.length > MAX_CONTENT_BYTES) {
		return null;
	}
	let raw;
	try {
		raw = JSON.parse(content);
	} catch {
		return null;
	}
	if (!raw || typeof raw !== 'object') return null;

	const services = parseServices(/** @type {Record<string, unknown>} */ (raw).services);
	const incidents = parseIncidents(/** @type {Record<string, unknown>} */ (raw).incidents);
	if (!services || !incidents) return null;

	// Relays stay client-local (browser ping list); feed may omit them.
	const relaysRaw = /** @type {Record<string, unknown>} */ (raw).relays;
	const relays = Array.isArray(relaysRaw) ? parseRelays(relaysRaw) : null;

	return {
		services,
		incidents,
		relays: relays && relays.length > 0 ? relays : []
	};
}

/**
 * @param {unknown} value
 * @returns {StatusService[] | null}
 */
function parseServices(value) {
	if (!Array.isArray(value) || value.length === 0 || value.length > 32) return null;
	/** @type {StatusService[]} */
	const out = [];
	for (const item of value) {
		if (!item || typeof item !== 'object') return null;
		const o = /** @type {Record<string, unknown>} */ (item);
		if (typeof o.id !== 'string' || !/^[A-Za-z0-9._-]{1,40}$/.test(o.id)) return null;
		if (typeof o.name !== 'string' || o.name.length === 0 || o.name.length > 80) return null;
		if (typeof o.desc !== 'string' || o.desc.length > 200) return null;
		if (typeof o.uptime !== 'number' || !Number.isFinite(o.uptime) || o.uptime < 0 || o.uptime > 100) {
			return null;
		}
		/** @type {StatusService} */
		const svc = {
			id: o.id,
			name: o.name,
			desc: o.desc,
			uptime: o.uptime
		};
		if (o.state !== undefined) {
			if (o.state !== 'ok' && o.state !== 'degraded' && o.state !== 'down') return null;
			if (o.state !== 'ok') svc.state = o.state;
		}
		out.push(svc);
	}
	return out;
}

/**
 * @param {unknown} value
 * @returns {StatusIncident[] | null}
 */
function parseIncidents(value) {
	if (!Array.isArray(value) || value.length > 40) return null;
	/** @type {StatusIncident[]} */
	const out = [];
	for (const item of value) {
		if (!item || typeof item !== 'object') return null;
		const o = /** @type {Record<string, unknown>} */ (item);
		if (typeof o.date !== 'string' || o.date.length > 40) return null;
		if (typeof o.title !== 'string' || o.title.length === 0 || o.title.length > 160) return null;
		if (o.level !== 'degraded' && o.level !== 'maintenance' && o.level !== 'down') return null;
		if (!Array.isArray(o.updates) || o.updates.length === 0 || o.updates.length > 20) return null;
		/** @type {IncidentUpdate[]} */
		const updates = [];
		for (const u of o.updates) {
			if (!u || typeof u !== 'object') return null;
			const uu = /** @type {Record<string, unknown>} */ (u);
			if (typeof uu.t !== 'string' || uu.t.length > 32) return null;
			if (
				uu.s !== 'Investigating' &&
				uu.s !== 'Identified' &&
				uu.s !== 'Monitoring' &&
				uu.s !== 'Resolved' &&
				uu.s !== 'Completed'
			) {
				return null;
			}
			if (typeof uu.b !== 'string' || uu.b.length === 0 || uu.b.length > 500) return null;
			updates.push({ t: uu.t, s: uu.s, b: uu.b });
		}
		out.push({ date: o.date, title: o.title, level: o.level, updates });
	}
	return out;
}

/**
 * @param {unknown[]} value
 * @returns {{ url: string, region: string }[] | null}
 */
function parseRelays(value) {
	if (value.length > 24) return null;
	/** @type {{ url: string, region: string }[]} */
	const out = [];
	for (const item of value) {
		if (!item || typeof item !== 'object') return null;
		const o = /** @type {Record<string, unknown>} */ (item);
		if (typeof o.url !== 'string' || !isWssUrl(o.url)) return null;
		if (typeof o.region !== 'string' || o.region.length > 80) return null;
		out.push({ url: o.url, region: o.region });
	}
	return out;
}

/**
 * @param {string} value
 */
function isWssUrl(value) {
	try {
		const url = new URL(value);
		return url.protocol === 'wss:';
	} catch {
		return false;
	}
}

/**
 * @param {string} relay
 * @param {{ kinds: number[], authors: string[], '#d': string[], limit: number }} filter
 * @returns {Promise<{ relay: string, events: NostrEvent[] }>}
 */
function queryRelay(relay, filter) {
	return new Promise((resolve) => {
		const subId = `sonar-status-${Math.random().toString(36).slice(2)}`;
		/** @type {NostrEvent[]} */
		const events = [];
		let settled = false;
		/** @type {WebSocket | undefined} */
		let socket;
		/** @type {ReturnType<typeof setTimeout> | undefined} */
		let timer;

		const finish = () => {
			if (settled) return;
			settled = true;
			if (timer) clearTimeout(timer);
			try {
				if (socket && socket.readyState === WebSocket.OPEN) {
					socket.send(JSON.stringify(['CLOSE', subId]));
				}
				if (socket && socket.readyState < WebSocket.CLOSING) socket.close();
			} catch {
				/* ignore */
			}
			resolve({ relay, events });
		};

		try {
			socket = new WebSocket(relay);
		} catch {
			finish();
			return;
		}

		timer = setTimeout(finish, QUERY_TIMEOUT_MS);

		socket.addEventListener('open', () => {
			try {
				socket?.send(JSON.stringify(['REQ', subId, filter]));
			} catch {
				finish();
			}
		});
		socket.addEventListener('message', (messageEvent) => {
			let payload;
			try {
				payload = JSON.parse(String(messageEvent.data));
			} catch {
				return;
			}
			if (!Array.isArray(payload) || payload.length < 2) return;
			const [type, id, body] = payload;
			if (id !== subId) return;
			if (type === 'EVENT' && body && typeof body === 'object') {
				events.push(/** @type {NostrEvent} */ (body));
			}
			if (type === 'EOSE' || type === 'CLOSED' || type === 'NOTICE') {
				finish();
			}
		});
		socket.addEventListener('error', finish);
		socket.addEventListener('close', finish);
	});
}

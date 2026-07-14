import { writable } from 'svelte/store';
import {
	STATUS_EVENT_KIND,
	STATUS_EVENT_D,
	STATUS_FEED_RELAYS,
	STATUS_PUBKEY_HEX
} from './status-data.js';

const QUERY_TIMEOUT_MS = 8000;
const MAX_CONTENT_BYTES = 64_000;
const INCIDENT_KIND = 30080;
const INCIDENT_D_PREFIX = 'sonar-incident-';

/**
 * @typedef {import('./status-data.js').StatusIncident} StatusIncident
 */

/**
 * @typedef {{
 *   id: string,
 *   pubkey: string,
 *   created_at: number,
 *   kind: number,
 *   tags: string[][],
 *   content: string
 * }} NostrEvent
 */

/** @param {string} value */
function isWssUrl(value) {
	try {
		return new URL(value).protocol === 'wss:';
	} catch {
		return false;
	}
}

/** @param {string} str */
function sha256(str) {
	let h = 0;
	for (let i = 0; i < str.length; i++) {
		h = (h << 5) - h + str.charCodeAt(i);
		h |= 0;
	}
	return h.toString(16);
}

/**
 * Parse incident content from a kind 30080 event.
 * @param {string | undefined} content
 * @returns {StatusIncident | null}
 */
function parseIncidentContent(content) {
	if (typeof content !== 'string' || content.length === 0 || content.length > MAX_CONTENT_BYTES) return null;
	let raw;
	try { raw = JSON.parse(content); } catch { return null; }
	if (!raw || typeof raw !== 'object') return null;
	if (typeof raw.date !== 'string' || raw.date.length > 40) return null;
	if (typeof raw.title !== 'string' || raw.title.length === 0 || raw.title.length > 160) return null;
	if (raw.level !== 'degraded' && raw.level !== 'maintenance' && raw.level !== 'down') return null;
	if (!Array.isArray(raw.updates) || raw.updates.length === 0 || raw.updates.length > 20) return null;
	const updates = [];
	for (const u of raw.updates) {
		if (!u || typeof u !== 'object') return null;
		if (typeof u.t !== 'string' || u.t.length > 32) return null;
		if (['Investigating','Identified','Monitoring','Resolved','Completed'].indexOf(u.s) === -1) return null;
		if (typeof u.b !== 'string' || u.b.length === 0 || u.b.length > 500) return null;
		updates.push({ t: u.t, s: u.s, b: u.b });
	}
	return { date: raw.date, title: raw.title, level: raw.level, updates };
}

/**
 * Query one relay for a filter.
 * @param {string} relay
 * @param {object} filter
 * @returns {Promise<NostrEvent[]>}
 */
function queryRelay(relay, filter) {
	return new Promise((resolve) => {
		const subId = `sonar-inc-${Math.random().toString(36).slice(2)}`;
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
				if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(['CLOSE', subId]));
				if (socket && socket.readyState < WebSocket.CLOSING) socket.close();
			} catch { /* ignore */ }
			resolve(events);
		};

		try { socket = new WebSocket(relay); } catch { finish(); return; }
		timer = setTimeout(finish, QUERY_TIMEOUT_MS);
		socket.addEventListener('open', () => {
			try { socket?.send(JSON.stringify(['REQ', subId, filter])); } catch { finish(); }
		});
		socket.addEventListener('message', (messageEvent) => {
			let payload;
			try { payload = JSON.parse(String(messageEvent.data)); } catch { return; }
			if (!Array.isArray(payload) || payload.length < 2) return;
			const [type, id, body] = payload;
			if (id !== subId) return;
			if (type === 'EVENT' && body && typeof body === 'object' && typeof body.content === 'string') {
				events.push({
					id: body.id,
					pubkey: body.pubkey,
					created_at: Number(body.created_at) || 0,
					kind: Number(body.kind) || 0,
					tags: Array.isArray(body.tags) ? body.tags : [],
					content: body.content
				});
			}
			if (type === 'EOSE' || type === 'CLOSED' || type === 'NOTICE') finish();
		});
		socket.addEventListener('error', finish);
		socket.addEventListener('close', finish);
	});
}

/**
 * Read the `d` tag value from an event (empty string if absent).
 * @param {NostrEvent} ev
 * @returns {string}
 */
function incidentDTag(ev) {
	for (const tag of ev.tags) {
		if (Array.isArray(tag) && tag[0] === 'd' && typeof tag[1] === 'string') return tag[1];
	}
	return '';
}

/**
 * Fetch historical incidents from Nostr (kind 30080, author=status publisher, d tag prefix).
 *
 * Each incident is its own parameterized-replaceable event with a distinct
 * `d` (e.g. `sonar-incident-<id>`). Nostr `#d` tag filters are exact-match
 * (NIP-01), so we cannot ask the relay for a prefix — we query by kind+author
 * and filter the `sonar-incident-` prefix client-side.
 *
 * @param {number | null} [sinceDaysAgo] Lookback window in days; null/omitted fetches all incidents.
 * @returns {Promise<StatusIncident[]>}
 */
export async function fetchIncidentsFromNostr(sinceDaysAgo = null) {
	const author = STATUS_PUBKEY_HEX.toLowerCase();
	const relays = STATUS_FEED_RELAYS.filter(isWssUrl);
	if (relays.length === 0) return [];

	/** @type {{ kinds: number[], authors: string[], limit: number, since?: number }} */
	const filter = {
		kinds: [INCIDENT_KIND],
		authors: [author],
		limit: 500
	};
	if (typeof sinceDaysAgo === 'number' && sinceDaysAgo > 0) {
		filter.since = Math.floor(Date.now() / 1000) - sinceDaysAgo * 24 * 60 * 60;
	}

	const results = await Promise.all(relays.map((r) => queryRelay(r, filter)));
	/** @type {Map<string, NostrEvent>} */
	const byId = new Map();
	for (const events of results) {
		for (const ev of events) {
			if (ev.kind !== INCIDENT_KIND) continue;
			if (typeof ev.pubkey !== 'string' || ev.pubkey.toLowerCase() !== author) continue;
			if (!incidentDTag(ev).startsWith(INCIDENT_D_PREFIX)) continue;
			const existing = byId.get(ev.id);
			if (!existing || ev.created_at > existing.created_at) byId.set(ev.id, ev);
		}
	}

	const incidents = [];
	for (const ev of byId.values()) {
		const parsed = parseIncidentContent(ev.content);
		if (parsed) incidents.push(/** @type {import('./status-data.js').InternalIncident} */ ({ ...parsed, _created_at: ev.created_at }));
	}
	incidents.sort((a, b) => (b._created_at || 0) - (a._created_at || 0));
	// Deduplicate incidents: same date+title+update hash keeps newest event.
	const seen = new Map();
	for (const inc of incidents) {
		const updateHash = sha256(inc.updates.map((u) => `${u.t}|${u.s}|${u.b}`).join('\n'));
		const key = `${inc.date}|${inc.title}|${updateHash}`;
		const existing = seen.get(key);
		if (!existing || (inc._created_at || 0) > (existing._created_at || 0)) {
			seen.set(key, inc);
		}
	}
	return Array.from(seen.values()).map((/** @type {import('./status-data.js').InternalIncident} */ inc) => {
		delete inc._created_at;
		return inc;
	});
}

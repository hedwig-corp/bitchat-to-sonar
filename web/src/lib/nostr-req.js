// Minimal browser-side Nostr reader: open a WebSocket, send one REQ, collect
// EVENTs until EOSE (or timeout), then CLOSE. No signature verification and no
// crypto dependency — callers schema-validate event content before trusting it.
//
// Extracted from the status feed reader (web/src/lib/status-nostr.js), which in
// turn mirrors the stickers page. Shared here so the blog feed can reuse it.

const QUERY_TIMEOUT_MS = 8000;

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
 * @typedef {{
 *   kinds: number[],
 *   authors: string[],
 *   limit: number,
 *   [key: `#${string}`]: string[]
 * }} NostrFilter
 */

/**
 * @param {string} value
 * @returns {boolean}
 */
export function isWssUrl(value) {
	try {
		const url = new URL(value);
		return url.protocol === 'wss:';
	} catch {
		return false;
	}
}

/**
 * Open one REQ against a single relay and resolve with whatever EVENTs arrive
 * before EOSE or the timeout. Never rejects — a dead relay resolves empty.
 * @param {string} relay
 * @param {NostrFilter} filter
 * @param {number} [timeoutMs]
 * @returns {Promise<{ relay: string, events: NostrEvent[] }>}
 */
export function queryRelay(relay, filter, timeoutMs = QUERY_TIMEOUT_MS) {
	return new Promise((resolve) => {
		const subId = `sonar-${Math.random().toString(36).slice(2)}`;
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

		timer = setTimeout(finish, timeoutMs);

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

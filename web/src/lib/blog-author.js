// Best-effort reader for the blog author's Nostr profile (kind 0 / NIP-01
// metadata): display name + avatar, shown as the byline on posts. Mirrors the
// trust model of blog-nostr.js — authors filter + pubkey check, no signature
// verification, content schema-checked. Newest kind-0 wins.

import { BLOG_FEED_RELAYS, BLOG_PUBKEY_HEX, isBlogFeedConfigured } from './blog-data.js';
import { isWssUrl, queryRelay } from './nostr-req.js';

/** @typedef {{ name: string, picture: string, nip05: string }} AuthorProfile */
/** @typedef {import('./nostr-req.js').NostrEvent} NostrEvent */

const MAX_PROFILE_BYTES = 8_000;

/**
 * Fetch the blog author's latest kind-0 profile from the feed relays.
 * @returns {Promise<AuthorProfile | null>}
 */
export async function fetchAuthorProfile() {
	if (!isBlogFeedConfigured()) return null;
	const author = BLOG_PUBKEY_HEX.toLowerCase();
	const relays = BLOG_FEED_RELAYS.filter(isWssUrl);
	if (relays.length === 0) return null;

	/** @type {import('./nostr-req.js').NostrFilter} */
	const filter = { kinds: [0], authors: [author], limit: 1 };
	const responses = await Promise.all(relays.map((relay) => queryRelay(relay, filter)));

	/** @type {NostrEvent | null} */
	let latest = null;
	for (const res of responses) {
		for (const ev of res.events) {
			if (ev.kind !== 0) continue;
			if (typeof ev.pubkey !== 'string' || ev.pubkey.toLowerCase() !== author) continue;
			if (!latest || (ev.created_at ?? 0) > (latest.created_at ?? 0)) latest = ev;
		}
	}
	return latest ? parseProfileEvent(latest) : null;
}

/**
 * Validate a kind-0 event and extract the byline fields. Returns null if there
 * is neither a name nor a usable avatar.
 * @param {NostrEvent} ev
 * @returns {AuthorProfile | null}
 */
export function parseProfileEvent(ev) {
	if (!ev || ev.kind !== 0) return null;
	const content = ev.content;
	if (typeof content !== 'string' || content.length === 0 || content.length > MAX_PROFILE_BYTES) {
		return null;
	}
	let meta;
	try {
		meta = JSON.parse(content);
	} catch {
		return null;
	}
	if (!meta || typeof meta !== 'object') return null;
	const o = /** @type {Record<string, unknown>} */ (meta);

	const name = clampStr(o.display_name) || clampStr(o.name);
	const picture = httpUrl(o.picture);
	const nip05 = clampStr(o.nip05);
	if (!name && !picture) return null;

	return { name, picture, nip05 };
}

/**
 * @param {unknown} value
 * @returns {string}
 */
function clampStr(value) {
	if (typeof value !== 'string') return '';
	const v = value.trim();
	return v.length > 120 ? v.slice(0, 120) : v;
}

/**
 * @param {unknown} value
 * @returns {string} http(s) URL or ''
 */
function httpUrl(value) {
	if (typeof value !== 'string') return '';
	try {
		const url = new URL(value.trim());
		return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : '';
	} catch {
		return '';
	}
}

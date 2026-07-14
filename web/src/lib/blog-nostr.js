// Best-effort reader for Sonar blog posts published as NIP-23 long-form events.
//
// Trust model (v1), mirroring web/src/lib/status-nostr.js:
// - Requires BLOG_PUBKEY_HEX (authors filter). Empty ⇒ no query.
// - Does NOT verify schnorr signatures (no crypto dep); the authors filter plus
//   a pubkey equality check are the trust boundary. Content is schema-checked.
// - NIP-23 events are addressable (kind:pubkey:d), so the newest created_at per
//   `d` tag wins; older revisions are ignored.

import {
	BLOG_EVENT_KIND,
	BLOG_FEATURED_TAG,
	BLOG_FEED_RELAYS,
	BLOG_MAX_CONTENT_BYTES,
	BLOG_PUBKEY_HEX,
	categoryFromTopics,
	estimateReadTime,
	formatBlogDate,
	isBlogFeedConfigured
} from './blog-data.js';
import { isWssUrl, queryRelay } from './nostr-req.js';

/** @typedef {import('./blog-content.js').BlogPost} BlogPost */
/** @typedef {import('./nostr-req.js').NostrEvent} NostrEvent */

const FETCH_LIMIT = 50;

/**
 * Query BLOG_FEED_RELAYS for the author's NIP-23 posts, newest first.
 * @returns {Promise<{ posts: BlogPost[], source: 'nostr' | 'seed' }>}
 */
export async function fetchPostsFromNostr() {
	if (!isBlogFeedConfigured()) {
		return { posts: [], source: 'seed' };
	}

	const author = BLOG_PUBKEY_HEX.toLowerCase();
	const relays = BLOG_FEED_RELAYS.filter(isWssUrl);
	if (relays.length === 0) {
		return { posts: [], source: 'seed' };
	}

	/** @type {import('./nostr-req.js').NostrFilter} */
	const filter = { kinds: [BLOG_EVENT_KIND], authors: [author], limit: FETCH_LIMIT };

	const responses = await Promise.all(relays.map((relay) => queryRelay(relay, filter)));
	const posts = postsFromEvents(responses.flatMap((r) => r.events), author);

	if (posts.length === 0) {
		return { posts: [], source: 'seed' };
	}
	return { posts, source: 'nostr' };
}

/**
 * Project raw NIP-23 events onto sorted BlogPosts: filter to the author, keep
 * the newest event per `d` tag (addressable-replaceable), parse, and sort newest
 * first. Shared by the runtime fetch and the build-time bake (web/scripts/fetch-blog.mjs).
 * @param {NostrEvent[]} events
 * @param {string} author lowercased hex pubkey
 * @returns {(BlogPost & { _ts: number })[]}
 */
export function postsFromEvents(events, author) {
	/** @type {Map<string, NostrEvent>} */
	const latestByD = new Map();
	for (const ev of events) {
		if (ev.kind !== BLOG_EVENT_KIND) continue;
		if (typeof ev.pubkey !== 'string' || ev.pubkey.toLowerCase() !== author) continue;
		const d = tagValue(ev.tags, 'd');
		if (!d) continue;
		const prev = latestByD.get(d);
		if (!prev || (ev.created_at ?? 0) > (prev.created_at ?? 0)) {
			latestByD.set(d, ev);
		}
	}

	/** @type {(BlogPost & { _ts: number })[]} */
	const posts = [];
	for (const ev of latestByD.values()) {
		const post = parseArticleEvent(ev);
		if (post) posts.push(post);
	}

	// Newest first by published_at (falls back to created_at via _ts).
	posts.sort((a, b) => (b._ts ?? 0) - (a._ts ?? 0));
	return posts;
}

/**
 * Validate a NIP-23 event and project it onto the BlogPost shape the page
 * renders. Returns null if the event is missing required fields or too large.
 * @param {NostrEvent} ev
 * @returns {(BlogPost & { _ts: number }) | null}
 */
export function parseArticleEvent(ev) {
	if (!ev || ev.kind !== BLOG_EVENT_KIND) return null;
	if (!Array.isArray(ev.tags)) return null;

	const id = tagValue(ev.tags, 'd');
	if (!id || !/^[A-Za-z0-9._-]{1,80}$/.test(id)) return null;

	const md = typeof ev.content === 'string' ? ev.content : '';
	if (md.length === 0 || md.length > BLOG_MAX_CONTENT_BYTES) return null;

	const title = tagValue(ev.tags, 'title');
	if (!title || title.length > 300) return null;

	const topics = ev.tags
		.filter((t) => t[0] === 't' && typeof t[1] === 'string')
		.map((t) => t[1].toLowerCase());

	const publishedAt = Number.parseInt(tagValue(ev.tags, 'published_at') ?? '', 10);
	const ts = Number.isFinite(publishedAt) && publishedAt > 0 ? publishedAt : (ev.created_at ?? 0);

	const summary = tagValue(ev.tags, 'summary') ?? firstParagraph(md);
	const author = tagValue(ev.tags, 'author') ?? 'The Sonar team';
	const read = tagValue(ev.tags, 'read') ?? estimateReadTime(md);

	/** @type {BlogPost & { _ts: number }} */
	const post = {
		id,
		title,
		cat: categoryFromTopics(topics),
		date: formatBlogDate(ts),
		read,
		author,
		excerpt: clamp(summary, 400),
		md,
		_ts: ts
	};
	if (topics.includes(BLOG_FEATURED_TAG)) post.feature = true;
	return post;
}

/**
 * @param {string[][]} tags
 * @param {string} name
 * @returns {string | undefined}
 */
function tagValue(tags, name) {
	for (const t of tags) {
		if (Array.isArray(t) && t[0] === name && typeof t[1] === 'string' && t[1].length > 0) {
			return t[1];
		}
	}
	return undefined;
}

/**
 * @param {string} md
 * @returns {string}
 */
function firstParagraph(md) {
	for (const block of md.split(/\n\s*\n/)) {
		const line = block.trim();
		// Skip front-matter fences, headings, and blockquotes for the teaser.
		if (!line || line.startsWith('#') || line.startsWith('>') || line === '---') continue;
		return line.replace(/\s+/g, ' ');
	}
	return '';
}

/**
 * @param {string} value
 * @param {number} max
 * @returns {string}
 */
function clamp(value, max) {
	const v = value.trim();
	return v.length > max ? `${v.slice(0, max - 1).trimEnd()}…` : v;
}

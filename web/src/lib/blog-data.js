// Sonar blog feed configuration.
//
// The blog list/article view (web/src/routes/blog/+page.svelte) renders the
// static SONAR_BLOG.posts (web/src/lib/blog-content.js) first, then — when
// BLOG_PUBKEY_HEX is set — REQs NIP-23 long-form events (kind 30023) authored
// by that pubkey from BLOG_FEED_RELAYS and replaces the list with the live
// feed. An unset/empty pubkey disables the query and keeps the static fallback,
// so the site never hard-depends on relays being reachable.
//
// Posts are published from docs/blog/<slug>/README.md via scripts/blog/publish.sh.

/** NIP-23 long-form content kind. */
export const BLOG_EVENT_KIND = 30023;

/**
 * Hex pubkey of the blog author. Empty string ⇒ no relay query (static-only).
 *
 * This is the Sonar blog account (npub1h0hcmfe3nadcrrkqtpsyst07345w79e0lccfwv7yekpgka3d6e4qj3zn70),
 * signed via the NIP-46 bunker in scripts/blog/publish.sh. It MUST equal the
 * pubkey the bunker signs as, or the reader will filter the posts out.
 */
export const BLOG_PUBKEY_HEX = 'bbef8da7319f5b818ec05860482dfe8d68ef172ffe309733c4cd828b762dd66a';

/** Relays queried for the blog feed. Same public set the status feed uses. */
export const BLOG_FEED_RELAYS = [
	'wss://relay.damus.io',
	'wss://nos.lol',
	'wss://relay.primal.net',
	'wss://nostr.relay.hedwig.sh'
];

/** Max markdown body size accepted from a relay event (defensive bound). */
export const BLOG_MAX_CONTENT_BYTES = 200_000;

/** Topic (`t` tag) that marks a post as the featured card. */
export const BLOG_FEATURED_TAG = 'featured';

/** @returns {boolean} whether a live query is configured. */
export function isBlogFeedConfigured() {
	return /^[0-9a-fA-F]{64}$/.test(BLOG_PUBKEY_HEX);
}

/**
 * Map lowercase `t` topics to the display category used by the design
 * (Policy = gold, Design = indigo, else Engineering = cyan).
 * @param {string[]} topics lowercased topic tags
 * @returns {'Policy' | 'Design' | 'Engineering'}
 */
export function categoryFromTopics(topics) {
	if (topics.includes('policy')) return 'Policy';
	if (topics.includes('design')) return 'Design';
	return 'Engineering';
}

/**
 * Format a unix timestamp (seconds) as the design's date string, e.g.
 * "July 14, 2026". Falls back to an empty string on bad input.
 * @param {number} unixSeconds
 * @returns {string}
 */
export function formatBlogDate(unixSeconds) {
	if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) return '';
	try {
		return new Date(unixSeconds * 1000).toLocaleDateString('en-US', {
			month: 'long',
			day: 'numeric',
			year: 'numeric',
			timeZone: 'UTC'
		});
	} catch {
		return '';
	}
}

/**
 * Estimate reading time from markdown body at ~200 words/min, min 1 minute.
 * @param {string} md
 * @returns {string} e.g. "8 min read"
 */
export function estimateReadTime(md) {
	const words = md.trim().split(/\s+/).filter(Boolean).length;
	const minutes = Math.max(1, Math.round(words / 200));
	return `${minutes} min read`;
}

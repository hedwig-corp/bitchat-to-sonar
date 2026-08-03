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
 * This is the Sonar blog author account
 * (npub1wg2m9ku823y5l5699dlj6294dc3cvwu4g34ldrtelxq20t27clxsd7dzaw). It MUST
 * equal the pubkey the posts are signed with (scripts/blog/publish.sh), or the
 * reader will filter the posts out.
 */
export const BLOG_PUBKEY_HEX = '1745b4c2aab2851f2d2511f25da0e78a6eda475b72d45d7de727a4f5f316152e';

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

/**
 * Required `t` tag that marks a NIP-23 event as a Sonar website blog post. The
 * reader only loads events carrying this tag, so other long-form content the
 * author publishes from the same key never shows up on the site. Publishers add
 * it via scripts/blog/publish.sh.
 */
export const BLOG_MARKER_TAG = 'sonarblogpost';

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
 * Format a unix timestamp (seconds) as a locale date string, e.g.
 * "July 14, 2026". Falls back to an empty string on bad input.
 * @param {number} unixSeconds
 * @param {string} [locale='en'] BCP-47 or site locale (`it`, `de`, …)
 * @returns {string}
 */
export function formatBlogDate(unixSeconds, locale = 'en') {
	if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) return '';
	try {
		const tag =
			locale === 'it'
				? 'it-IT'
				: locale === 'de'
					? 'de-DE'
					: locale === 'es'
						? 'es-ES'
						: locale === 'pt'
							? 'pt-BR'
							: locale === 'fr'
								? 'fr-FR'
								: 'en-US';
		return new Date(unixSeconds * 1000).toLocaleDateString(tag, {
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
 * @param {string} [locale='en']
 * @returns {string} e.g. "8 min read"
 */
export function estimateReadTime(md, locale = 'en') {
	const words = md.trim().split(/\s+/).filter(Boolean).length;
	const minutes = Math.max(1, Math.round(words / 200));
	switch (locale) {
		case 'it':
			return `${minutes} min di lettura`;
		case 'de':
			return `${minutes} Min. Lesezeit`;
		case 'es':
			return `${minutes} min de lectura`;
		case 'pt':
			return `${minutes} min de leitura`;
		case 'fr':
			return `${minutes} min de lecture`;
		default:
			return `${minutes} min read`;
	}
}

import { BLOG_TRANSLATIONS } from '../blog-translations.js';
import { estimateReadTime, formatBlogDate } from '../blog-data.js';
import { blogContentHash } from '../blog-hash.js';

/**
 * @typedef {import('../blog-content.js').BlogPost} BlogPost
 * @typedef {import('./locales.js').SiteLocale} SiteLocale
 */

/**
 * Overlay site-only translations onto English posts (from bake or live Nostr).
 * Missing overlays leave English fields in place. Overlays whose contentHash
 * does not match the current English title/excerpt/md are ignored (stale after
 * a NIP-23 replace under the same slug).
 *
 * @param {BlogPost[]} posts
 * @param {SiteLocale | string} locale
 * @param {typeof BLOG_TRANSLATIONS} [translations]
 * @returns {BlogPost[]}
 */
export function localizePosts(posts, locale, translations = BLOG_TRANSLATIONS) {
	if (!locale || locale === 'en' || !Array.isArray(posts)) return posts;
	return posts.map((post) => {
		const date = localizedPostDate(/** @type {BlogPost & { _ts?: number }} */ (post), locale);
		const overlay = translations?.[post.id]?.[locale];
		if (!overlay) {
			return date === post.date ? post : { ...post, date };
		}
		const expected = blogContentHash(post.title, post.excerpt, post.md);
		if (overlay.contentHash !== expected) {
			// Missing or mismatched hash ⇒ fall back to English fields (date still localized).
			return date === post.date ? post : { ...post, date };
		}
		const md = typeof overlay.md === 'string' && overlay.md.trim() ? overlay.md : post.md;
		const read =
			typeof overlay.read === 'string' && overlay.read.trim()
				? overlay.read
				: estimateReadTime(md, locale);
		return {
			...post,
			title: overlay.title?.trim() || post.title,
			excerpt: overlay.excerpt?.trim() || post.excerpt,
			md,
			read,
			date
		};
	});
}

/**
 * Format a blog date string for the active locale when we have a unix timestamp
 * on the live post; otherwise leave the baked English date string.
 *
 * @param {BlogPost & { _ts?: number }} post
 * @param {SiteLocale | string} locale
 * @returns {string}
 */
export function localizedPostDate(post, locale) {
	if (typeof post._ts === 'number' && post._ts > 0) {
		return formatBlogDate(post._ts, locale);
	}
	return post.date;
}

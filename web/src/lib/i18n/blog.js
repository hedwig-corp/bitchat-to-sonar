import { BLOG_TRANSLATIONS } from '../blog-translations.js';
import { estimateReadTime, formatBlogDate } from '../blog-data.js';

/**
 * @typedef {import('../blog-content.js').BlogPost} BlogPost
 * @typedef {import('./locales.js').SiteLocale} SiteLocale
 */

/**
 * Overlay site-only translations onto English posts (from bake or live Nostr).
 * Missing overlays leave English fields in place.
 *
 * @param {BlogPost[]} posts
 * @param {SiteLocale | string} locale
 * @returns {BlogPost[]}
 */
export function localizePosts(posts, locale) {
	if (!locale || locale === 'en' || !Array.isArray(posts)) return posts;
	return posts.map((post) => {
		const overlay = BLOG_TRANSLATIONS?.[post.id]?.[locale];
		if (!overlay) return post;
		const md = typeof overlay.md === 'string' && overlay.md.trim() ? overlay.md : post.md;
		const read =
			typeof overlay.read === 'string' && overlay.read.trim()
				? overlay.read
				: estimateReadTime(md);
		return {
			...post,
			title: overlay.title?.trim() || post.title,
			excerpt: overlay.excerpt?.trim() || post.excerpt,
			md,
			read
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

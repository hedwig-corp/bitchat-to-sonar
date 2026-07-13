// Sonar blog posts — rendered by web/src/routes/blog/+page.svelte.
//
// The blog launches with no posts on purpose; add entries here as they are
// written. The design reference with sample posts lives in
// design/handoff/project/sonar/blog-content.js.

/**
 * @typedef {Object} BlogPost
 * @property {string} id        url-hash slug, e.g. 'why-no-accounts'
 * @property {string} title
 * @property {'Policy' | 'Design' | 'Engineering'} cat  Policy = gold, Design = indigo, else cyan
 * @property {string} date      e.g. 'July 12, 2026'
 * @property {string} read      e.g. '6 min read'
 * @property {string} author    e.g. 'The Sonar team'
 * @property {boolean} [feature] pinned as the featured card
 * @property {string} excerpt   one-paragraph teaser shown on the cards
 * @property {string} md        body in markdown — same parser as Docs ($lib/markdown.js)
 */

/** @type {{ posts: BlogPost[] }} */
export const SONAR_BLOG = {
	posts: []
};

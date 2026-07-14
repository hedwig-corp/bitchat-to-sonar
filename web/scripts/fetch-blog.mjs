#!/usr/bin/env node
// Fetch the published NIP-23 blog posts from Nostr and bake them into
// web/src/lib/blog-content.js, so the static build ships the posts locally and
// URLs like /blog/#chat-control-explained resolve without a network round-trip.
// The page still refreshes from the live feed at runtime (blog-nostr.js).
//
// Run: `npm run fetch-blog` (from web/). Commit the regenerated blog-content.js.
// nak is invoked via `go run` by default; override with NAK="nak".
//
// If the fetch returns nothing (relays unreachable, post unpublished), the
// existing blog-content.js is left untouched — the build never loses content.

import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { writeFileSync } from 'node:fs';
import {
	BLOG_EVENT_KIND,
	BLOG_FEED_RELAYS,
	BLOG_MARKER_TAG,
	BLOG_PUBKEY_HEX
} from '../src/lib/blog-data.js';
import { postsFromEvents } from '../src/lib/blog-nostr.js';
import { parseProfileEvent } from '../src/lib/blog-author.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(HERE, '../src/lib/blog-content.js');

if (!/^[0-9a-fA-F]{64}$/.test(BLOG_PUBKEY_HEX)) {
	console.error('fetch-blog: BLOG_PUBKEY_HEX is not set in blog-data.js — nothing to fetch.');
	process.exit(1);
}

const relays = BLOG_FEED_RELAYS.filter((r) => r.startsWith('wss://'));
const nak = (process.env.NAK ?? 'go run github.com/fiatjaf/nak@latest').split(/\s+/);
const author = BLOG_PUBKEY_HEX.toLowerCase();

/**
 * Run `nak req -k <kind> -a <author> [extra…] <relays…>` and return the parsed events.
 * @param {number} kind
 * @param {string[]} [extra] extra nak req args (e.g. tag filters)
 * @returns {import('../src/lib/nostr-req.js').NostrEvent[]}
 */
function reqEvents(kind, extra = []) {
	const args = [...nak.slice(1), 'req', '-k', String(kind), '-a', author, ...extra, ...relays];
	const res = spawnSync(nak[0], args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 60_000 });
	if (res.error) {
		console.error(`fetch-blog: failed to run ${nak[0]}: ${res.error.message}`);
		process.exit(1);
	}
	/** @type {import('../src/lib/nostr-req.js').NostrEvent[]} */
	const events = [];
	for (const line of (res.stdout || '').split('\n')) {
		const t = line.trim();
		if (!t) continue;
		try {
			events.push(JSON.parse(t));
		} catch {
			/* ignore non-JSON log lines */
		}
	}
	return events;
}

console.error(`fetch-blog: querying ${relays.length} relays for kind ${BLOG_EVENT_KIND} (#t=${BLOG_MARKER_TAG}) + profile by ${BLOG_PUBKEY_HEX.slice(0, 12)}…`);
const postEvents = reqEvents(BLOG_EVENT_KIND, ['-t', `t=${BLOG_MARKER_TAG}`]);
const posts = postsFromEvents(postEvents, author).map(({ _ts, ...p }) => p);

if (posts.length === 0) {
	console.error('fetch-blog: no posts returned — leaving blog-content.js unchanged.');
	process.exit(0);
}

// Author byline profile (kind 0): newest wins.
const profileEvents = reqEvents(0).filter((e) => e.kind === 0 && e.pubkey?.toLowerCase() === author);
profileEvents.sort((a, b) => (b.created_at ?? 0) - (a.created_at ?? 0));
const author_profile = profileEvents.length ? parseProfileEvent(profileEvents[0]) : null;

writeFileSync(OUT, render(posts, author_profile), 'utf8');
console.error(`fetch-blog: wrote ${posts.length} post(s) to src/lib/blog-content.js:`);
for (const p of posts) console.error(`  • ${p.id} — ${p.title.slice(0, 60)}`);
console.error(
	author_profile
		? `  author: ${author_profile.name || '(no name)'}${author_profile.picture ? ' + avatar' : ''}`
		: '  author: no kind-0 profile found'
);

/**
 * @param {object[]} posts
 * @param {{ name: string, picture: string, nip05: string } | null} authorProfile
 * @returns {string}
 */
function render(posts, authorProfile) {
	const body = posts.map((p) => '\t\t' + JSON.stringify(p)).join(',\n');
	return `// Sonar blog posts — GENERATED from Nostr by web/scripts/fetch-blog.mjs.
// Do not edit by hand; re-run \`npm run fetch-blog\` to refresh, then commit.
// These are the local/offline copy baked into the build; the blog page also
// refreshes from the live NIP-23 feed + author profile at runtime
// (web/src/lib/blog-nostr.js, web/src/lib/blog-author.js).

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
\tposts: [
${body}
\t]
};

/**
 * Author byline profile (Nostr kind 0), or null if none was found.
 * @type {import('./blog-author.js').AuthorProfile | null}
 */
export const SONAR_BLOG_AUTHOR = ${JSON.stringify(authorProfile)};
`;
}

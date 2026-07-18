#!/usr/bin/env node
// Fetch the published NIP-23 blog posts (+ author profile) from Nostr and bake
// them into web/src/lib/blog-content.js, so the static build ships them locally
// and URLs like /blog/#chat-control-explained resolve without a network
// round-trip. The page still refreshes from the live feed at runtime.
//
// Reuses the exact browser reader (blog-nostr.js / blog-author.js) over Node's
// global WebSocket (Node >= 22) — no nak/Go needed, so it runs in the Pages CI
// build with only Node. Marker-gated: only events tagged `sonarblogpost` load.
//
// Run: `npm run fetch-blog` (from web/). Commit the regenerated blog-content.js.
//
// Best-effort: on any error, or if the feed returns nothing (relays
// unreachable, post unpublished), the existing blog-content.js is left
// untouched and the script still exits 0, so a deploy never fails or loses
// content over a transient relay hiccup.

import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { writeFileSync } from 'node:fs';
import { BLOG_PUBKEY_HEX, isBlogFeedConfigured } from '../src/lib/blog-data.js';
import { fetchPostsFromNostr } from '../src/lib/blog-nostr.js';
import { fetchAuthorProfile } from '../src/lib/blog-author.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(HERE, '../src/lib/blog-content.js');

const BAKE_DEADLINE_MS = 45_000;

/**
 * @template T
 * @param {Promise<T>} promise
 * @param {number} ms
 * @param {string} label
 * @returns {Promise<T>}
 */
function withTimeout(promise, ms, label) {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
		promise.then(
			(value) => {
				clearTimeout(timer);
				resolve(value);
			},
			(err) => {
				clearTimeout(timer);
				reject(err);
			}
		);
	});
}

async function main() {
	if (!isBlogFeedConfigured()) {
		console.error('fetch-blog: BLOG_PUBKEY_HEX is not set in blog-data.js — skipping.');
		return;
	}

	console.error(`fetch-blog: querying the blog feed (marker-gated) for ${BLOG_PUBKEY_HEX.slice(0, 12)}…`);
	const { posts: raw, source } = await withTimeout(
		fetchPostsFromNostr(),
		BAKE_DEADLINE_MS,
		'fetchPostsFromNostr'
	);
	if (source !== 'nostr' || raw.length === 0) {
		console.error('fetch-blog: no marked posts returned — leaving blog-content.js unchanged.');
		return;
	}
	// Keep `_ts` so the site can localize dates without re-parsing English strings.
	const posts = raw;
	const author = await withTimeout(fetchAuthorProfile(), 15_000, 'fetchAuthorProfile').catch(
		() => null
	);

	writeFileSync(OUT, render(posts, author), 'utf8');
	console.error(`fetch-blog: wrote ${posts.length} post(s) to src/lib/blog-content.js:`);
	for (const p of posts) console.error(`  • ${p.id} — ${p.title.slice(0, 60)}`);
	console.error(
		author
			? `  author: ${author.name || '(no name)'}${author.picture ? ' + avatar' : ''}`
			: '  author: no kind-0 profile found'
	);

	// Site-only locale overlays (AI when SONAR_BLOG_TRANSLATE_API_KEY is set).
	// Best-effort; never fails the bake. Use spawn (async) so a stuck child
	// cannot pin the Node process the way spawnSync would.
	try {
		const { spawn } = await import('node:child_process');
		await new Promise((resolve) => {
			const child = spawn(process.execPath, [resolve(HERE, 'translate-blog.mjs')], {
				cwd: resolve(HERE, '..'),
				stdio: 'inherit',
				env: process.env
			});
			const killTimer = setTimeout(() => {
				console.error('fetch-blog: translate-blog exceeded 60s — killing child.');
				child.kill('SIGKILL');
			}, 60_000);
			child.on('exit', (code) => {
				clearTimeout(killTimer);
				if (code !== 0 && code !== null) {
					console.error('fetch-blog: translate-blog exited non-zero — keeping prior overlays.');
				}
				resolve(undefined);
			});
			child.on('error', (err) => {
				clearTimeout(killTimer);
				console.error(`fetch-blog: translate step skipped (${err?.message ?? err})`);
				resolve(undefined);
			});
		});
	} catch (err) {
		console.error(`fetch-blog: translate step skipped (${err?.message ?? err})`);
	}
}

main()
	.catch((err) => {
		// Never fail the build over a relay/network hiccup — keep the committed copy.
		console.error(
			`fetch-blog: fetch failed (${err?.message ?? err}) — leaving blog-content.js unchanged.`
		);
	})
	.finally(() => {
		// Hung WebSockets can keep the event loop alive after our deadline; exit
		// explicitly so CI/Pages never sit on this script.
		process.exit(0);
	});

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
// (web/src/lib/blog-nostr.js, web/src/lib/blog-author.js). The Pages CI build
// also re-bakes on deploy, so production always reflects the latest posts.

/**
 * @typedef {Object} BlogPost
 * @property {string} id        url-hash slug, e.g. 'why-no-accounts'
 * @property {string} title
 * @property {'Policy' | 'Design' | 'Engineering'} cat  Policy = gold, Design = indigo, else cyan
 * @property {string} date      e.g. 'July 12, 2026' (English bake; UI re-formats via _ts)
 * @property {string} read      e.g. '6 min read'
 * @property {string} author    e.g. 'The Sonar team'
 * @property {boolean} [feature] pinned as the featured card
 * @property {string} excerpt   one-paragraph teaser shown on the cards
 * @property {string} md        body in markdown — same parser as Docs ($lib/markdown.js)
 * @property {number} [_ts]     unix seconds for locale-aware date formatting
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

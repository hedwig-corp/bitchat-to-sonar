#!/usr/bin/env node
// Machine-translate English blog posts into site-only locale overlays after
// Nostr fetch. Never publishes translations to relays.
//
// Env (optional — script no-ops when unset so CI/forks stay green):
//   SONAR_BLOG_TRANSLATE_API_KEY  — OpenAI-compatible API key
//   SONAR_BLOG_TRANSLATE_BASE_URL — default https://api.openai.com/v1
//   SONAR_BLOG_TRANSLATE_MODEL    — default gpt-4o-mini
//
// Skips a locale when the stored contentHash still matches the English body.
// Best-effort: never exits non-zero.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SONAR_BLOG } from '../src/lib/blog-content.js';
import { estimateReadTime } from '../src/lib/blog-data.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(HERE, '../src/lib/blog-translations.js');
const LOCALES = ['it', 'de', 'es', 'pt', 'fr'];

const API_KEY = process.env.SONAR_BLOG_TRANSLATE_API_KEY || process.env.OPENAI_API_KEY || '';
const BASE_URL = (process.env.SONAR_BLOG_TRANSLATE_BASE_URL || 'https://api.openai.com/v1').replace(
	/\/$/,
	''
);
const MODEL = process.env.SONAR_BLOG_TRANSLATE_MODEL || 'gpt-4o-mini';

/**
 * @param {string} title
 * @param {string} excerpt
 * @param {string} md
 */
function contentHash(title, excerpt, md) {
	return createHash('sha256').update(`${title}\n${excerpt}\n${md}`).digest('hex').slice(0, 16);
}

/** @returns {Record<string, Record<string, object>>} */
function loadExisting() {
	if (!existsSync(OUT)) return {};
	try {
		const src = readFileSync(OUT, 'utf8');
		const marker = 'export const BLOG_TRANSLATIONS = ';
		const idx = src.indexOf(marker);
		if (idx < 0) return {};
		// Evaluate the object literal safely via Function (file is ours).
		const body = src.slice(idx + marker.length).replace(/;\s*$/, '');
		return Function(`"use strict"; return (${body})`)();
	} catch {
		return {};
	}
}

/**
 * @param {string} locale
 * @param {{ title: string, excerpt: string, md: string }} en
 */
async function translatePost(locale, en) {
	const system = `You are a machine translator for the Sonar marketing site.
Translate the JSON fields title, excerpt, and md from English into locale "${locale}".
Preserve ALL markdown structure (headings, lists, links, bold, blockquotes, hr).
Keep URLs and markdown link targets unchanged.
Keep product/proper names: Sonar, Nostr, White Noise, Marmot, Signal, WhatsApp, Chat Control, CSAM, CSAR, MLS, Bluetooth, TestFlight, Zapstore, Fight Chat Control.
Return ONLY valid JSON: {"title":"...","excerpt":"...","md":"..."}`;

	const user = JSON.stringify({
		title: en.title,
		excerpt: en.excerpt,
		md: en.md
	});

	const res = await fetch(`${BASE_URL}/chat/completions`, {
		method: 'POST',
		headers: {
			Authorization: `Bearer ${API_KEY}`,
			'Content-Type': 'application/json'
		},
		body: JSON.stringify({
			model: MODEL,
			temperature: 0.2,
			response_format: { type: 'json_object' },
			messages: [
				{ role: 'system', content: system },
				{ role: 'user', content: user }
			]
		})
	});
	if (!res.ok) {
		const text = await res.text().catch(() => '');
		throw new Error(`translate API ${res.status}: ${text.slice(0, 200)}`);
	}
	const data = await res.json();
	const raw = data?.choices?.[0]?.message?.content;
	if (typeof raw !== 'string') throw new Error('empty translate response');
	const parsed = JSON.parse(raw);
	if (!parsed?.title || !parsed?.excerpt || !parsed?.md) {
		throw new Error('translate response missing fields');
	}
	return {
		title: String(parsed.title),
		excerpt: String(parsed.excerpt),
		md: String(parsed.md),
		read: estimateReadTime(String(parsed.md), locale)
	};
}

function render(map) {
	return `// Site-only blog overlays (never published to Nostr).
// Generated / refreshed by web/scripts/translate-blog.mjs after fetch-blog.
// Keyed by post id → locale → { title, excerpt, md?, read?, contentHash }.
//
// English remains the NIP-23 source of truth in blog-content.js / relays.
// When an overlay is missing for a locale, the UI keeps the English fields.

/**
 * @typedef {Object} BlogLocaleOverlay
 * @property {string} title
 * @property {string} excerpt
 * @property {string} [md]
 * @property {string} [read]
 * @property {string} [contentHash]
 */

/**
 * @type {Record<string, Record<string, BlogLocaleOverlay>>}
 */
export const BLOG_TRANSLATIONS = ${JSON.stringify(map, null, '\t')};
`;
}

async function main() {
	const existing = loadExisting();
	const posts = SONAR_BLOG?.posts ?? [];
	if (posts.length === 0) {
		console.error('translate-blog: no English posts in blog-content.js — skipping.');
		return;
	}

	if (!API_KEY) {
		console.error(
			'translate-blog: SONAR_BLOG_TRANSLATE_API_KEY unset — keeping committed overlays.'
		);
		return;
	}

	/** @type {Record<string, Record<string, object>>} */
	const next = { ...existing };
	let wrote = 0;

	for (const post of posts) {
		const hash = contentHash(post.title, post.excerpt, post.md);
		if (!next[post.id]) next[post.id] = {};
		for (const locale of LOCALES) {
			const prev = next[post.id][locale];
			if (prev?.contentHash === hash && prev?.md && prev?.title) {
				console.error(`translate-blog: ${post.id}/${locale} up to date (${hash})`);
				continue;
			}
			console.error(`translate-blog: translating ${post.id} → ${locale}…`);
			try {
				const tr = await translatePost(locale, {
					title: post.title,
					excerpt: post.excerpt,
					md: post.md
				});
				next[post.id][locale] = { ...tr, contentHash: hash };
				wrote += 1;
			} catch (err) {
				console.error(
					`translate-blog: ${post.id}/${locale} failed (${err?.message ?? err}) — keeping previous`
				);
			}
		}
	}

	if (wrote === 0) {
		console.error('translate-blog: nothing new to write.');
		return;
	}
	writeFileSync(OUT, render(next), 'utf8');
	console.error(`translate-blog: wrote ${wrote} overlay(s) to src/lib/blog-translations.js`);
}

main().catch((err) => {
	console.error(`translate-blog: failed (${err?.message ?? err}) — leaving overlays unchanged.`);
});

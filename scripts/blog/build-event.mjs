#!/usr/bin/env node
// Turn a docs/blog/<slug>/README.md into a NIP-23 (kind 30023) event skeleton.
//
// Usage: node build-event.mjs <README.md> <body-out-path>
//   - prints the unsigned event JSON (kind, created_at, tags, placeholder
//     content) to stdout
//   - writes the front-matter-stripped markdown body to <body-out-path>
//
// scripts/blog/publish.sh pipes the JSON into `nak event -c @<body-out-path>`,
// which replaces the placeholder content with the body file and signs+publishes.
// Tags flow through stdin as real JSON, so values may safely contain commas,
// semicolons, and em-dashes (unlike nak's `-t k=v;w` shorthand).
//
// The tag schema is the contract the site reader relies on
// (web/src/lib/blog-nostr.js):
//   d           = slug (directory name)          → BlogPost.id
//   title       = front-matter title             → BlogPost.title
//   summary     = front-matter summary           → BlogPost.excerpt
//   published_at= unix seconds from `date`       → BlogPost.date
//   t           = lowercased category            → BlogPost.cat
//   t=featured  = present when feature: true     → BlogPost.feature
//   author      = front-matter author            → BlogPost.author
//   read        = front-matter read              → BlogPost.read

import { readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname } from 'node:path';

const [readmePath, bodyOutPath] = process.argv.slice(2);
if (!readmePath || !bodyOutPath) {
	console.error('usage: build-event.mjs <README.md> <body-out-path>');
	process.exit(2);
}

const raw = readFileSync(readmePath, 'utf8');

// Split leading `---` front-matter from the body.
const fmMatch = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
if (!fmMatch) {
	console.error(`${readmePath}: missing YAML front-matter (--- ... ---)`);
	process.exit(1);
}
const [, fmBlock, body] = fmMatch;

/** @type {Record<string,string>} */
const fm = {};
for (const line of fmBlock.split(/\r?\n/)) {
	if (!line.trim() || /^\s*#/.test(line)) continue;
	const idx = line.indexOf(':');
	if (idx === -1) continue;
	const key = line.slice(0, idx).trim();
	let value = line.slice(idx + 1).trim();
	// Strip matching surrounding quotes if present.
	if (
		(value.startsWith('"') && value.endsWith('"')) ||
		(value.startsWith("'") && value.endsWith("'"))
	) {
		value = value.slice(1, -1);
	}
	fm[key] = value;
}

const slug = basename(dirname(readmePath));
if (!/^[A-Za-z0-9._-]{1,80}$/.test(slug)) {
	console.error(`${readmePath}: slug "${slug}" must match [A-Za-z0-9._-]{1,80}`);
	process.exit(1);
}

const title = fm.title;
if (!title) {
	console.error(`${readmePath}: front-matter needs a title`);
	process.exit(1);
}

// `date` (YYYY-MM-DD) → UTC-midnight unix seconds. Used for both created_at and
// the published_at tag so the addressable event and its display date agree.
const dateMs = Date.parse(`${fm.date ?? ''}T00:00:00Z`);
if (!Number.isFinite(dateMs)) {
	console.error(`${readmePath}: front-matter needs a valid date (YYYY-MM-DD)`);
	process.exit(1);
}
const publishedAt = Math.floor(dateMs / 1000);

const topic = (fm.cat ?? 'Engineering').toLowerCase();

/** @type {string[][]} */
const tags = [
	['d', slug],
	['title', title],
	['published_at', String(publishedAt)],
	['t', topic]
];
if (fm.summary) tags.push(['summary', fm.summary]);
if (fm.author) tags.push(['author', fm.author]);
if (fm.read) tags.push(['read', fm.read]);
if (String(fm.feature).toLowerCase() === 'true') tags.push(['t', 'featured']);
tags.push(['client', 'sonar-blog']);

const event = {
	kind: 30023,
	created_at: publishedAt,
	tags,
	content: 'placeholder-replaced-by-nak'
};

writeFileSync(bodyOutPath, body.replace(/^\s+/, ''), 'utf8');
process.stdout.write(JSON.stringify(event));

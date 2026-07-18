import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveLocale, intlLocale, SUPPORTED_LOCALES } from '../src/lib/i18n/locales.js';
import { CATALOG } from '../src/lib/i18n/catalog.js';
import { localizePosts } from '../src/lib/i18n/blog.js';
import { BLOG_TRANSLATIONS } from '../src/lib/blog-translations.js';

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
	const en = [
		{
			id: 'chat-control-explained',
			title: 'English title',
			excerpt: 'English excerpt',
			md: '# English',
			cat: 'Policy',
			date: 'July 14, 2026',
			read: '8 min read',
			author: 'The Sonar team'
		}
	];
	const it = localizePosts(en, 'it');
	assert.notEqual(it[0].title, 'English title');
	assert.ok(BLOG_TRANSLATIONS['chat-control-explained']?.it?.md?.length > 100);
	assert.equal(localizePosts(en, 'en')[0].title, 'English title');
});

import { browser } from '$app/environment';
import { CATALOG } from './catalog.js';
import { resolveLocale } from './locales.js';

/** @typedef {import('./locales.js').SiteLocale} SiteLocale */

/** @type {SiteLocale} */
let locale = $state('en');

/** @returns {SiteLocale} */
export function getLocale() {
	return locale;
}

/**
 * @param {SiteLocale | string} next
 * @returns {SiteLocale}
 */
export function setLocale(next) {
	const resolved = resolveLocale([next]);
	locale = resolved;
	if (browser && typeof document !== 'undefined') {
		document.documentElement.lang = resolved;
	}
	return resolved;
}

/** Resolve from the device and apply. Safe to call on the server (stays `en`). */
export function initI18n() {
	if (!browser) return locale;
	const languages =
		typeof navigator !== 'undefined'
			? navigator.languages?.length
				? [...navigator.languages]
				: navigator.language
					? [navigator.language]
					: ['en']
			: ['en'];
	return setLocale(resolveLocale(languages));
}

/**
 * Translate a catalog key. Falls back to English, then the key itself.
 * @param {string} key
 * @param {Record<string, string | number>} [vars]
 * @returns {string}
 */
export function t(key, vars) {
	const table = CATALOG[locale] ?? CATALOG.en;
	let out = table[key] ?? CATALOG.en[key] ?? key;
	if (vars) {
		for (const [name, value] of Object.entries(vars)) {
			out = out.replaceAll(`{${name}}`, String(value));
		}
	}
	return out;
}

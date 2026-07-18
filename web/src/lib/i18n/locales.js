/** Locales shipped for the marketing site (device-locale selection). */
export const SUPPORTED_LOCALES = Object.freeze(['en', 'it', 'de', 'es', 'pt', 'fr']);

/** @typedef {(typeof SUPPORTED_LOCALES)[number]} SiteLocale */

/**
 * Map BCP-47 tags (e.g. `pt-BR`, `es-MX`) to a supported base locale.
 * @param {readonly string[] | string | undefined | null} languages
 * @returns {SiteLocale}
 */
export function resolveLocale(languages) {
	const list = Array.isArray(languages)
		? languages
		: typeof languages === 'string' && languages
			? [languages]
			: [];
	for (const raw of list) {
		const tag = String(raw || '')
			.trim()
			.toLowerCase()
			.replace('_', '-');
		if (!tag) continue;
		const base = tag.split('-')[0];
		if (SUPPORTED_LOCALES.includes(/** @type {SiteLocale} */ (base))) {
			return /** @type {SiteLocale} */ (base);
		}
	}
	return 'en';
}

/**
 * BCP-47 tag for `Intl` / `toLocaleDateString` (prefer regional defaults).
 * @param {SiteLocale | string} locale
 * @returns {string}
 */
export function intlLocale(locale) {
	switch (locale) {
		case 'it':
			return 'it-IT';
		case 'de':
			return 'de-DE';
		case 'es':
			return 'es-ES';
		case 'pt':
			return 'pt-BR';
		case 'fr':
			return 'fr-FR';
		default:
			return 'en-US';
	}
}

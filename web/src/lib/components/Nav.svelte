<script>
	import { base } from '$app/paths';
	import SonarMark from './SonarMark.svelte';
	import { DOWNLOAD_HREF } from '$lib/links.js';
	import { t } from '$lib/i18n/i18n.svelte.js';

	const downloadHref = `${base}/${DOWNLOAD_HREF}`;
	const stickersHref = `${base}/stickers`;
	const docsHref = `${base}/docs`;
	const blogHref = `${base}/blog`;
	const statusHref = `${base}/status`;
</script>

<nav>
	<div class="navin">
		<a class="wordmark" href="{base}/">
			<SonarMark size={22} />
			sonar
		</a>
		<div class="navlinks">
			<a class="btn ghost small status-link" href={statusHref}>{t('nav.status')}</a>
			<a class="btn ghost small" href={stickersHref}>{t('nav.stickers')}</a>
			<a class="btn ghost small blog-link" href={blogHref}>{t('nav.blog')}</a>
			<a class="btn ghost small docs-link" href={docsHref}>{t('nav.docs')}</a>
			<a class="btn primary small" href={downloadHref}>{t('nav.getApp')}</a>
		</div>
	</div>
</nav>

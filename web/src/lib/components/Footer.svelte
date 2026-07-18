<script>
	import { base } from '$app/paths';
	import SonarMark from './SonarMark.svelte';
	import { t } from '$lib/i18n/i18n.svelte.js';

	const statusHref = `${base}/status`;
</script>

<footer>
	<div class="wrap footin">
		<a class="wordmark" href="{base}/" style="font-size: 17px;">
			<SonarMark size={18} />
			sonar
		</a>
		<span class="fine"
			>{t('footer.protocols')} · <code>npub1w4j8mc7…q4k9dj</code> ·
			<a href={statusHref}>{t('footer.status')}</a></span
		>
	</div>
</footer>

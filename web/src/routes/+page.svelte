<script>
  import Nav from '$lib/components/Nav.svelte';
  import Radar from '$lib/components/Radar.svelte';
  import Footer from '$lib/components/Footer.svelte';
  import {
    DOWNLOAD_HREF,
    TESTFLIGHT_URL,
    TESTFLIGHT_MACOS_URL,
    ANDROID_APK_URL,
    LINUX_RELEASES_URL,
    ZAPSTORE_URL
  } from '$lib/links.js';
  import { t } from '$lib/i18n/i18n.svelte.js';
</script>

<svelte:head>
  <title>{t('home.title')}</title>
  <meta name="description" content={t('home.description')} />
</svelte:head>

<Nav />

<header class="wrap hero">
  <div>
    <span class="kicker"><span class="dot"></span>{t('home.kicker')}</span>
    <h1>{t('home.h1.before')}<em>{t('home.h1.em')}</em></h1>
    <p class="sub">{t('home.sub')}</p>
    <div class="ctas">
      <a class="btn primary" href={TESTFLIGHT_URL} target="_blank" rel="noopener">{t('home.cta.testflight')}</a>
      <a class="btn primary" href={ZAPSTORE_URL} target="_blank" rel="noopener">{t('home.cta.zapstore')}</a>
      <a class="btn ghost" href={ANDROID_APK_URL}>{t('home.cta.apk')}</a>
      <a class="btn ghost" href={DOWNLOAD_HREF}>{t('home.cta.allDownloads')}</a>
    </div>
    <p class="heronote">{t('home.heronote')} · <code>a3f9 2c41 770e 5b2d</code></p>
  </div>

  <Radar />
</header>

<section class="alt">
  <div class="wrap twocol">
    <div>
      <p class="label">{t('home.twoNetworks.label')}</p>
      <h2>{t('home.twoNetworks.h2')}</h2>
      <p class="lede">{t('home.twoNetworks.lede')}</p>
      <div class="legend">
        <span><i class="ldot c"></i>{t('home.legend.nearby')}</span>
        <span><i class="ldot i"></i>{t('home.legend.far')}</span>
      </div>
    </div>
    <div class="chatcard">
      <div class="bub them">{t('home.demo.m1')}<span class="meta">18:02</span></div>
      <div class="bub ble">{t('home.demo.m2')}<span class="meta">18:04 · {t('home.demo.m2.meta')}</span></div>
      <div class="chatdivider">{t('home.demo.divider')}</div>
      <div class="bub net">{t('home.demo.m3')}<span class="meta">22:31 · {t('home.demo.m3.meta')}</span></div>
      <div class="bub them">{t('home.demo.m4')}<span class="meta">22:33</span></div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="label">{t('home.why.label')}</p>
    <h2>{t('home.why.h2')}</h2>
    <div class="grid3">
      <div class="feat">
        <span class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none" /><path d="M8.7 8.7a4.7 4.7 0 0 0 0 6.6M15.3 8.7a4.7 4.7 0 0 1 0 6.6M6.2 6.2a8.2 8.2 0 0 0 0 11.6M17.8 6.2a8.2 8.2 0 0 1 0 11.6" /></svg></span>
        <h3>{t('home.feat.offline.h3')}</h3>
        <p>{t('home.feat.offline.p')}</p>
      </div>
      <div class="feat">
        <span class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="8.2" /><path d="M3.8 12h16.4M12 3.8c-2.7 2.5-4.1 5.2-4.1 8.2s1.4 5.7 4.1 8.2c2.7-2.5 4.1-5.2 4.1-8.2S14.7 6.3 12 3.8z" /></svg></span>
        <h3>{t('home.feat.reach.h3')}</h3>
        <p>{t('home.feat.reach.p')}</p>
      </div>
      <div class="feat">
        <span class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="5.5" y="10.5" width="13" height="9.5" rx="2.6" /><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" /></svg></span>
        <h3>{t('home.feat.private.h3')}</h3>
        <p>{t('home.feat.private.p')}</p>
      </div>
    </div>
  </div>
</section>

<section class="alt">
  <div class="wrap twocol">
    <div>
      <p class="label">{t('home.pay.label')}</p>
      <h2>{t('home.pay.h2')}</h2>
      <p class="lede">{t('home.pay.lede')}</p>
      <div class="modechip">
        <span class="modeswitch"></span>
        <span><b>{t('home.pay.mode.bold')}</b> {t('home.pay.mode.rest')}</span>
      </div>
    </div>
    <div class="chatcard">
      <div class="bub them">{t('home.pay.demo')}<span class="meta">20:14</span></div>
      <div class="paycard">
        <span class="paycoin">€</span>
        <span class="payamt">€18.00</span>
      </div>
      <div class="paystate"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none" /><path d="M8.7 8.7a4.7 4.7 0 0 0 0 6.6M15.3 8.7a4.7 4.7 0 0 1 0 6.6" /></svg>{t('home.pay.sealed')}</div>
    </div>
  </div>
</section>

<section>
  <div class="wrap twocol">
    <div class="chanrows">
      <div class="chanrow">
        <span class="pintile"><svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 20.8s-6.3-5.3-6.3-10.2a6.3 6.3 0 0 1 12.6 0c0 4.9-6.3 10.2-6.3 10.2z" /><circle cx="12" cy="10.4" r="2.2" /></svg></span>
        <span><span class="t">{t('home.geo.luganoCentro')}</span><br /><span class="d">{t('home.geo.blockNow')}</span></span>
        <span class="geo">{t('home.geo.block')}</span>
      </div>
      <div class="chanrow">
        <span class="pintile"><svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 20.8s-6.3-5.3-6.3-10.2a6.3 6.3 0 0 1 12.6 0c0 4.9-6.3 10.2-6.3 10.2z" /><circle cx="12" cy="10.4" r="2.2" /></svg></span>
        <span><span class="t">{t('home.geo.lugano')}</span><br /><span class="d">{t('home.geo.cityToday')}</span></span>
        <span class="geo">{t('home.geo.city')}</span>
      </div>
    </div>
    <div>
      <p class="label">{t('home.geo.label')}</p>
      <h2>{t('home.geo.h2')}</h2>
      <p class="lede">{t('home.geo.lede')}</p>
    </div>
  </div>
</section>

<section class="alt">
  <div class="wrap" style="text-align: center;">
    <p class="label" style="color: var(--cyan-deep);">{t('home.every.label')}</p>
    <h2>{t('home.every.h2')}</h2>
    <p class="lede" style="margin: 0 auto;">{t('home.every.lede')}</p>
    <div class="devstage">
      <div class="win" aria-hidden="true">
        <div class="wintop">
          <span class="tl" style="background: #FF5F57;"></span>
          <span class="tl" style="background: #FEBC2E;"></span>
          <span class="tl" style="background: #28C840;"></span>
          <span class="winmark"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--cyan)" stroke-width="1.8"><circle cx="12" cy="12" r="2" fill="var(--cyan)" stroke="none" /><circle cx="12" cy="12" r="5.8" /><circle cx="12" cy="12" r="9.4" /></svg>sonar</span>
        </div>
        <div class="win-body">
          <div class="win-side">
            <span class="statuspill"><span style="width: 7px; height: 7px; border-radius: 50%; background: var(--green);"></span>{t('home.every.online')}</span>
            <div class="siderow"><span class="dot-av" style="background: hsl(330 40% 45%);"></span><span class="bars"><span class="barline" style="width: 68%;"></span><span class="barline" style="width: 46%; background: #1A2024;"></span></span></div>
            <div class="siderow sel"><span class="dot-av" style="background: hsl(150 40% 42%);"></span><span class="bars"><span class="barline" style="width: 60%;"></span><span class="barline" style="width: 50%; background: #1A2024;"></span></span></div>
            <div class="siderow"><span class="dot-av" style="background: hsl(265 38% 48%);"></span><span class="bars"><span class="barline" style="width: 72%;"></span><span class="barline" style="width: 40%; background: #1A2024;"></span></span></div>
          </div>
          <div class="win-main">
            <div class="bub them" style="font-size: 13px; max-width: none; white-space: nowrap;">{t('home.every.lake')}</div>
            <div class="bub ble" style="font-size: 13px; max-width: none; white-space: nowrap; align-self: flex-end;">{t('home.every.way')}</div>
            <div class="paycard" style="min-width: 0; padding: 8px 13px 8px 8px; border-radius: 15px; border-bottom-right-radius: 6px;"><span class="paycoin" style="width: 30px; height: 30px; font-size: 15px;">€</span><span class="payamt" style="font-size: 15px;">€12.00</span></div>
          </div>
        </div>
      </div>

      <div class="phone-sm" aria-hidden="true">
        <div class="phone-notch"></div>
        <div class="psm-head">sonar</div>
        <div class="psm-radar">
          <span class="ring r3"></span><span class="ring r2"></span><span class="ring r1"></span>
          <span class="psm-sweep"></span>
          <span class="pdot" style="left: 50%; top: 50%; width: 30px; height: 30px; background: hsl(192 50% 52%);"></span>
          <span class="pdot" style="left: 31%; top: 37%; background: hsl(330 55% 62%);"></span>
          <span class="pdot" style="left: 71%; top: 43%; background: hsl(150 50% 50%);"></span>
          <span class="pdot" style="left: 60%; top: 73%; background: hsl(48 60% 56%);"></span>
        </div>
        <div class="psm-cap">{t('home.every.nearby')}</div>
      </div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="label">{t('home.quiet.label')}</p>
    <h2>{t('home.quiet.h2')}</h2>
    <p class="lede">{t('home.quiet.lede')}</p>
    <span class="mono-card">$ accounts found: 0 &nbsp;·&nbsp; servers contacted: 0</span>
  </div>
</section>

<section class="alt band" id="download">
  <div class="wrap">
    <h2>{t('home.download.h2')}</h2>
    <p class="lede">{t('home.download.lede')}</p>
    <div class="ctas">
      <a class="btn primary" href={TESTFLIGHT_URL} target="_blank" rel="noopener">{t('home.download.iphone')}</a>
      <a class="btn primary" href={TESTFLIGHT_MACOS_URL} target="_blank" rel="noopener">{t('home.download.mac')}</a>
      <a class="btn primary" href={ZAPSTORE_URL} target="_blank" rel="noopener">{t('home.download.zapstore')}</a>
      <a class="btn primary" href={ANDROID_APK_URL}>{t('home.download.apk')}</a>
      <a class="btn primary" href={LINUX_RELEASES_URL} target="_blank" rel="noopener">{t('home.download.linux')}</a>
    </div>
    <p class="heronote">{t('home.download.note')}</p>
  </div>
</section>

<Footer />

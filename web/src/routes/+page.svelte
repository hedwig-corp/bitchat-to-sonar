<script>
  import Nav from '$lib/components/Nav.svelte';
  import Radar from '$lib/components/Radar.svelte';
  import Footer from '$lib/components/Footer.svelte';
  import { DEMO_URL, DOWNLOAD_HREF, TESTFLIGHT_URL, ANDROID_APK_URL } from '$lib/links.js';
</script>

<svelte:head>
  <title>Sonar — sense who's nearby</title>
  <meta
    name="description"
    content="Sonar is a private messenger that works two ways at once: Bluetooth finds the people around you — even with no internet — and the open Nostr network reaches everyone else. Your phone is the only account you need."
  />
</svelte:head>

<Nav />

<header class="wrap hero">
  <div>
    <span class="kicker"><span class="dot"></span>No phone number · no account · no servers</span>
    <h1>Sense who&rsquo;s nearby <em>before you see them.</em></h1>
    <p class="sub">Sonar is a private messenger that works two ways at once: Bluetooth finds the people around you — even with no internet — and the open Nostr network reaches everyone else. Your phone is the only account you need.</p>
    <div class="ctas">
      <a class="btn primary" href={DOWNLOAD_HREF}>Download</a>
      <a class="btn ghost" href={DEMO_URL}>Try the interactive demo</a>
    </div>
    <p class="heronote">End-to-end encrypted · your key never leaves the phone · <code>a3f9 2c41 770e 5b2d</code></p>
  </div>

  <Radar />
</header>

<section class="alt">
  <div class="wrap twocol">
    <div>
      <p class="label">Two networks, one chat</p>
      <h2>You always know how a message traveled.</h2>
      <p class="lede">Sonar routes every message automatically: Bluetooth when your friend is in range, the encrypted open internet when they are not. The bubble color tells you which — like iMessage, but for distance instead of platform.</p>
      <div class="legend">
        <span><i class="ldot c"></i>nearby · over Bluetooth</span>
        <span><i class="ldot i"></i>far · over the internet</span>
      </div>
    </div>
    <div class="chatcard">
      <div class="bub them">did you make it to the meetup?<span class="meta">18:02</span></div>
      <div class="bub ble">just got here — it&rsquo;s packed<span class="meta">18:04 · bluetooth</span></div>
      <div class="chatdivider">later, from across town</div>
      <div class="bub net">home safe! same time next week?<span class="meta">22:31 · internet</span></div>
      <div class="bub them">wouldn&rsquo;t miss it<span class="meta">22:33</span></div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="label">Why Sonar</p>
    <h2>A messenger that treats the network as a feature.</h2>
    <div class="grid3">
      <div class="feat">
        <span class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none" /><path d="M8.7 8.7a4.7 4.7 0 0 0 0 6.6M15.3 8.7a4.7 4.7 0 0 1 0 6.6M6.2 6.2a8.2 8.2 0 0 0 0 11.6M17.8 6.2a8.2 8.2 0 0 1 0 11.6" /></svg></span>
        <h3>Works without internet</h3>
        <p>Bluetooth mesh relays messages phone-to-phone. Festivals, flights, blackouts, protests — if people are around, Sonar works.</p>
      </div>
      <div class="feat">
        <span class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="8.2" /><path d="M3.8 12h16.4M12 3.8c-2.7 2.5-4.1 5.2-4.1 8.2s1.4 5.7 4.1 8.2c2.7-2.5 4.1-5.2 4.1-8.2S14.7 6.3 12 3.8z" /></svg></span>
        <h3>Reaches anyone, anywhere</h3>
        <p>Out of range? Messages travel over Nostr — an open relay network nobody owns. No company server sits between you and your friends.</p>
      </div>
      <div class="feat">
        <span class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="5.5" y="10.5" width="13" height="9.5" rx="2.6" /><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" /></svg></span>
        <h3>Private by design</h3>
        <p>Direct messages are end-to-end encrypted, always. Your identity is a key created on your phone — verify friends in person with a safety number.</p>
      </div>
    </div>
  </div>
</section>

<section class="alt">
  <div class="wrap twocol">
    <div>
      <p class="label">Pay a friend</p>
      <h2>Send money as easily as a message.</h2>
      <p class="lede">Settle a dinner across the table or send cash across the world. The payment takes the same path your message would — phone-to-phone over Bluetooth when they&rsquo;re near, over the internet when they&rsquo;re not. It arrives sealed; they tap to open.</p>
      <div class="modechip">
        <span class="modeswitch"></span>
        <span><b>Bitcoin mode is off by default.</b> You see amounts in your own currency. Flip it on for sats, Lightning and ecash — your call.</span>
      </div>
    </div>
    <div class="chatcard">
      <div class="bub them">that&rsquo;s dinner sorted — you got me next time<span class="meta">20:14</span></div>
      <div class="paycard">
        <span class="paycoin">€</span>
        <span class="payamt">€18.00</span>
      </div>
      <div class="paystate"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none" /><path d="M8.7 8.7a4.7 4.7 0 0 0 0 6.6M15.3 8.7a4.7 4.7 0 0 1 0 6.6" /></svg>Sealed · Maya taps to open · over Bluetooth</div>
    </div>
  </div>
</section>

<section>
  <div class="wrap twocol">
    <div class="chanrows">
      <div class="chanrow">
        <span class="pintile"><svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 20.8s-6.3-5.3-6.3-10.2a6.3 6.3 0 0 1 12.6 0c0 4.9-6.3 10.2-6.3 10.2z" /><circle cx="12" cy="10.4" r="2.2" /></svg></span>
        <span><span class="t">Lugano · Centro</span><br /><span class="d">Public · 12 here now</span></span>
        <span class="geo">block</span>
      </div>
      <div class="chanrow">
        <span class="pintile"><svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 20.8s-6.3-5.3-6.3-10.2a6.3 6.3 0 0 1 12.6 0c0 4.9-6.3 10.2-6.3 10.2z" /><circle cx="12" cy="10.4" r="2.2" /></svg></span>
        <span><span class="t">Lugano</span><br /><span class="d">Public · 48 in range today</span></span>
        <span class="geo">city</span>
      </div>
    </div>
    <div>
      <p class="label">Location channels</p>
      <h2>Places, not coordinates.</h2>
      <p class="lede">Wherever you stand, Sonar shows one &ldquo;Around you&rdquo; place — zoom from your block to the whole region with a single tap. Real place names, never raw coordinates, and never an endless list of empty rooms.</p>
    </div>
  </div>
</section>

<section class="alt">
  <div class="wrap" style="text-align: center;">
    <p class="label" style="color: var(--cyan-deep);">Everywhere you are</p>
    <h2>One private network, on every screen.</h2>
    <p class="lede" style="margin: 0 auto;">Built for iPhone, iPad and Mac. The same nearby radar, the same encrypted chats, the same key in your pocket — your conversations follow you, and nothing lives on a server.</p>
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
            <span class="statuspill"><span style="width: 7px; height: 7px; border-radius: 50%; background: var(--green);"></span>Online · reaches anyone</span>
            <div class="siderow"><span class="dot-av" style="background: hsl(330 40% 45%);"></span><span class="bars"><span class="barline" style="width: 68%;"></span><span class="barline" style="width: 46%; background: #1A2024;"></span></span></div>
            <div class="siderow sel"><span class="dot-av" style="background: hsl(150 40% 42%);"></span><span class="bars"><span class="barline" style="width: 60%;"></span><span class="barline" style="width: 50%; background: #1A2024;"></span></span></div>
            <div class="siderow"><span class="dot-av" style="background: hsl(265 38% 48%);"></span><span class="bars"><span class="barline" style="width: 72%;"></span><span class="barline" style="width: 40%; background: #1A2024;"></span></span></div>
          </div>
          <div class="win-main">
            <div class="bub them" style="font-size: 13px; max-width: none; white-space: nowrap;">see you at the lake?</div>
            <div class="bub ble" style="font-size: 13px; max-width: none; white-space: nowrap; align-self: flex-end;">on my way</div>
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
        <div class="psm-cap">4 people nearby</div>
      </div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="label">Quiet, dependable privacy</p>
    <h2>Nothing to leak, nothing to subpoena.</h2>
    <p class="lede">There is no signup, no contact upload, no cloud backup of your conversations. And if you ever need it: triple-tap to wipe everything — key, chats, nickname — instantly.</p>
    <span class="mono-card">$ accounts found: 0 &nbsp;·&nbsp; servers contacted: 0</span>
  </div>
</section>

<section class="alt band" id="download">
  <div class="wrap">
    <h2>Hear the room before you enter it.</h2>
    <p class="lede">Free, open source, end-to-end encrypted. iPhone beta on TestFlight — Android alpha APK available now.</p>
    <div class="ctas">
      <a class="btn primary" href={TESTFLIGHT_URL} target="_blank" rel="noopener">Join the iPhone beta (TestFlight)</a>
      <a class="btn primary" href={ANDROID_APK_URL}>Download for Android (APK)</a>
      <a class="btn ghost" href={DEMO_URL}>Try the interactive demo</a>
    </div>
    <p class="heronote">Android APK is an arm64 alpha · sideload on 64-bit phones</p>
  </div>
</section>

<Footer />

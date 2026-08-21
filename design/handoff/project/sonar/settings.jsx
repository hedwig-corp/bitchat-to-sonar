// Sonar — full Settings + Profile (Signal/XChat-inspired)
// Loaded AFTER screens.jsx: overrides the basic SettingsScreen export.

const PF_REQUEST = { name: 'driftwood', note: 'Met on mesh · wants to message you' };

function StSwitch({ on }) {
  return <span className={'st-switch' + (on ? ' on' : '')}></span>;
}

function StRow({ icon, tone = '', label, sub, value, danger, onClick, toggle, trail = 'chevron' }) {
  return (
    <button className={'st-row' + (danger ? ' danger' : '')} onClick={onClick}>
      <span className={'st-icon ' + tone}><BCIcon name={icon} size={17} /></span>
      <span className="st-label">
        {label}
        {sub ? <small>{sub}</small> : null}
      </span>
      {value ? <span className="st-value">{value}</span> : null}
      {typeof toggle !== 'undefined'
        ? <StSwitch on={toggle} />
        : (trail ? <BCIcon name={trail} size={14} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} /> : null)}
    </button>
  );
}

/* ── Deterministic share code (QR-style, generated from the pubkey) ── */
function ShareCode({ seed, size = 164 }) {
  const N = 11, cs = 4;
  const rects = [];
  const isFinder = (r, c) => (r < 3 && c < 3) || (r < 3 && c >= N - 3) || (r >= N - 3 && c < 3);
  for (let r = 0; r < N; r++) {
    const rh = bcHash(seed + ':' + r);
    for (let c = 0; c < N; c++) {
      let on;
      if (isFinder(r, c)) {
        const lr = r < 3 ? r : r - (N - 3);
        const lc = c < 3 ? c : c - (N - 3);
        on = !(lr === 1 && lc === 1);
      } else {
        on = ((rh >>> c) & 1) === 1;
      }
      if (on) rects.push(<rect key={r + '-' + c} x={c * cs + 0.3} y={r * cs + 0.3} width={cs - 0.6} height={cs - 0.6} rx="0.9" fill="var(--text)" />);
    }
  }
  return (
    <svg width={size} height={size} viewBox={`0 0 ${N * cs} ${N * cs}`} aria-hidden="true">{rects}</svg>
  );
}

/* ── Key sharing: QR to scan + one-tap copy/share — used on mobile & desktop ── */
function KeyShareCard({ compact }) {
  const [copied, setCopied] = React.useState(false);
  const [full, setFull] = React.useState(false);
  const key = BC_DATA.pubkey;
  const shortKey = key.slice(0, 18) + '\u2026' + key.slice(-8);
  const copy = () => {
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(key);
      } else {
        const ta = document.createElement('textarea');
        ta.value = key; ta.style.position = 'fixed'; ta.style.opacity = '0';
        document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); } catch (e) { /* ignore */ }
        document.body.removeChild(ta);
      }
    } catch (e) { /* ignore */ }
    setCopied(true);
    clearTimeout(window.__bcCopyT);
    window.__bcCopyT = setTimeout(() => setCopied(false), 1700);
  };
  const share = () => {
    try {
      if (navigator.share) { navigator.share({ title: 'My Sonar key', text: key }); return; }
    } catch (e) { /* ignore */ }
    copy();
  };
  return (
    <div className={'keyshare' + (compact ? ' compact' : '')}>
      <div className="keyshare-qr">
        <ShareCode seed={key} size={compact ? 150 : 184} />
      </div>
      <div className="keyshare-caption">Let someone scan this to add you — keys are exchanged directly, never through a server.</div>
      <button className="keyshare-keyrow" onClick={() => setFull(!full)} title="Tap to expand">
        <span className={'keyshare-key' + (full ? ' full' : '')}>{full ? key : shortKey}</span>
      </button>
      <div className="keyshare-btns">
        <button className={'keyshare-btn primary' + (copied ? ' done' : '')} onClick={copy}>
          <BCIcon name={copied ? 'check' : 'copy'} size={17} weight={2.2} />
          {copied ? 'Copied' : 'Copy key'}
        </button>
        <button className="keyshare-btn" onClick={share}>
          <BCIcon name="share" size={17} weight={2} />
          Share
        </button>
      </div>
    </div>
  );
}

/* ── Export private key (nsec) — self-custody escape hatch, reused everywhere ── */
function ExportKeySheet({ onClose }) {
  const [revealed, setRevealed] = React.useState(false);
  const [copied, setCopied] = React.useState(false);
  const nsec = BC_DATA.nsec;
  const masked = nsec.slice(0, 5) + ' ' + '\u2022'.repeat(28);
  const copy = () => {
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(nsec);
      else {
        const ta = document.createElement('textarea');
        ta.value = nsec; ta.style.position = 'fixed'; ta.style.opacity = '0';
        document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); } catch (e) { /* ignore */ }
        document.body.removeChild(ta);
      }
    } catch (e) { /* ignore */ }
    setCopied(true);
    clearTimeout(window.__bcNsecT);
    window.__bcNsecT = setTimeout(() => setCopied(false), 1700);
  };
  return (
    <Sheet onClose={onClose} title="Export private key">
      <div className="nsec-warn">
        <BCIcon name="shield" size={18} weight={2} />
        <span>This <b>nsec</b> key <b>is</b> your account. Anyone who has it can read your messages and spend your balance. Paste it into another Nostr app to move in — never share it with a person.</span>
      </div>
      <button className={'nsec-field' + (revealed ? ' on' : '')} onClick={() => setRevealed(!revealed)}>
        <span className="nsec-value">{revealed ? nsec : masked}</span>
        <span className="nsec-eye"><BCIcon name={revealed ? 'eyeOff' : 'eye'} size={17} weight={2} /></span>
      </button>
      <div className="keyshare-btns" style={{ padding: '0 8px' }}>
        <button className={'keyshare-btn primary' + (copied ? ' done' : '')} onClick={copy}>
          <BCIcon name={copied ? 'check' : 'copy'} size={17} weight={2.2} />
          {copied ? 'Copied' : 'Copy private key'}
        </button>
      </div>
      <p className="bc-note" style={{ textAlign: 'center', padding: '12px 18px 4px' }}>
        Tip: store it in a password manager. Sonar can’t recover it for you.
      </p>
    </Sheet>
  );
}

/* ── Profile screen ── */
function ProfileScreen({ app, nav, pop, onRename }) {
  const prefs = app.prefs || {};
  const [editing, setEditing] = React.useState(false);
  const [draft, setDraft] = React.useState(app.nick || '');
  const shortKey = BC_DATA.pubkey.slice(0, 14) + '\u2026' + BC_DATA.pubkey.slice(-6);
  const save = () => {
    if (draft.trim().length >= 2) onRename(draft.trim());
    setEditing(false);
  };
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Profile">
      <NavHeader onBack={pop} hairline={false}>
        <div className="bc-hname"><span>Profile</span></div>
      </NavHeader>
      <div className="bc-scroll">
        <div className="pf-head">
          <Avatar name={(editing ? draft.trim() : app.nick) || 'you'} size={96} />
          {editing ? (
            <div className="pf-editrow">
              <input
                className="bc-nickinput" style={{ fontSize: 18, padding: '11px 14px' }}
                type="text" value={draft} maxLength={20} placeholder="nickname"
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') save(); }}
              />
              <button className="pf-smallbtn primary" onClick={save}>Save</button>
            </div>
          ) : (
            <div className="pf-name">
              {app.nick || 'you'}
              <button className="bc-iconbtn" style={{ width: 30, height: 30 }} onClick={() => { setDraft(app.nick || ''); setEditing(true); }} aria-label="Edit nickname">
                <BCIcon name="pencil" size={15} weight={2} />
              </button>
            </div>
          )}
          <span className="pf-key">{prefs.pubkeyUI ? shortKey : '@' + (app.nick || 'you')}</span>
        </div>

        <SectionLabel>Your key</SectionLabel>
        <div className="st-card" style={{ padding: '4px 4px 10px' }}>
          <KeyShareCard />
        </div>
        <SectionLabel>Safety</SectionLabel>
        <div className="st-card">
          <StRow
            icon="key" tone="cyan" label="Fingerprint" sub="Read this aloud to verify in person"
            value={<span style={{ fontFamily: 'var(--mono)', fontSize: 12.5 }}>{BC_DATA.myFingerprint}</span>}
            trail={null} onClick={() => {}}
          />
        </div>
        <p className="st-note">Your nickname is just what people see — your key never leaves this phone.</p>
      </div>
    </div>
  );
}

/* ── Sheets ── */
function NotifSheet({ onClose, prefs, onPref, muted, onUnmute }) {
  const mutedIds = Object.keys(muted || {});
  const allPeers = BC_DATA.peers || [];
  const allGroups = BC_DATA.groups || [];
  const allChannels = [...(BC_DATA.channels || []), ...(BC_DATA.here || [])];
  function mutedName(id) {
    if (id.startsWith('g-')) { const g = allGroups.find((x) => 'g-' + x.id === id); return g ? g.name : id; }
    const p = allPeers.find((x) => x.id === id); if (p) return p.name;
    const ch = allChannels.find((x) => x.id === id); if (ch) return ch.name;
    return id;
  }
  return (
    <Sheet onClose={onClose} title="Notifications">
      <StRow icon="bell" label="Allow notifications" onClick={() => onPref('notifs', !prefs.notifs)} toggle={prefs.notifs} />
      <StRow icon="people" label="Show names" sub="Hide to keep the lock screen private" onClick={() => onPref('names', !prefs.names)} toggle={prefs.names && prefs.notifs} />
      <StRow icon="list" label="Show message preview" onClick={() => onPref('preview', !prefs.preview)} toggle={prefs.preview && prefs.notifs} />
      {mutedIds.length > 0 && (
        <React.Fragment>
          <div className="bc-sect" style={{ paddingTop: 14 }}>Muted conversations · {mutedIds.length}</div>
          {mutedIds.map((id) => (
            <button key={id} className="bc-actionrow" onClick={() => onUnmute(id)}>
              <span className="bc-actionicon" style={{ background: 'var(--surface2)', color: 'var(--text3)' }}><BCIcon name="bellOff" size={18} /></span>
              <span className="bc-actionmain">
                <span className="bc-actionlabel">{mutedName(id)}</span>
                <div className="bc-actiondesc">{muted[id] === 'forever' ? 'Muted permanently' : 'Muted for ' + muted[id]}</div>
              </span>
              <span className="cp-copybtn">Unmute</span>
            </button>
          ))}
        </React.Fragment>
      )}
      <div className="bc-sheetactions">
        <button className="bc-ghost" onClick={onClose}>Done</button>
      </div>
    </Sheet>
  );
}

function RequestsSheet({ onClose, onResolve }) {
  return (
    <Sheet onClose={onClose} title="Message requests">
      <div className="pf-request">
        <Avatar name={PF_REQUEST.name} size={46} />
        <span className="pf-reqmain">
          <span className="pf-reqname">{PF_REQUEST.name}</span>
          <span className="pf-reqnote">{PF_REQUEST.note}</span>
        </span>
      </div>
      <div className="pf-reqbtns">
        <button className="pf-smallbtn primary" onClick={() => { onResolve(); onClose(); }}>Accept</button>
        <button className="pf-smallbtn" onClick={() => { onResolve(); onClose(); }}>Decline</button>
      </div>
    </Sheet>
  );
}

const SN_APP_ICONS = [
  { id: 'default', src: 'sonar/brand/sonar-icon.png', label: 'Default' },
  { id: 'square', src: 'sonar/brand/sonar-square.png', label: 'Square' },
];

function AppIconSheet({ onClose, current, onPick }) {
  return (
    <Sheet onClose={onClose} title="App icon">
      <div className="ai-row">
        {SN_APP_ICONS.map((ic) => (
          <button
            key={ic.id}
            className={'ai-tile img' + ((current || 'default') === ic.id ? ' on' : '')}
            onClick={() => { onPick(ic.id); onClose(); }}
            aria-label={'App icon ' + ic.label}
          >
            <img src={ic.src} alt={ic.label} />
          </button>
        ))}
      </div>
      <p className="bc-verifycopy" style={{ paddingTop: 0 }}>The Sonar mark — quiet, no badges.</p>
      <div className="bc-sheetactions">
        <button className="bc-ghost" onClick={onClose}>Done</button>
      </div>
    </Sheet>
  );
}

/* ── Settings screen (full) ── */
function SettingsScreen({ app, nav, pop, push, mode, onToggleMode, toggleNetwork, onWipe, onPref, onUnmute }) {
  const [notif, setNotif] = React.useState(false);
  const [requests, setRequests] = React.useState(false);
  const [appicon, setAppicon] = React.useState(false);
  const [wipeAsk, setWipeAsk] = React.useState(false);
  const [curSheet, setCurSheet] = React.useState(false);
  const [exportKey, setExportKey] = React.useState(false);
  const prefs = app.prefs || {};
  const verifiedCount = Object.keys(app.verified).length;
  const shortKey = BC_DATA.pubkey.slice(0, 14) + '\u2026' + BC_DATA.pubkey.slice(-6);
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Settings">
      <NavHeader onBack={pop} hairline={false}>
        <div className="bc-hname"><span>Settings</span></div>
      </NavHeader>
      <div className="bc-scroll">
        <button className="st-prof" onClick={() => push('profile')}>
          <Avatar name={app.nick || 'you'} size={56} />
          <span className="st-profmain">
            <div className="st-profname">{app.nick || 'you'}</div>
            <div className="st-profkey">{prefs.pubkeyUI ? shortKey : '@' + (app.nick || 'you') + ' · tap to view key'}</div>
          </span>
          <BCIcon name="chevron" size={15} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
        </button>

        <SectionLabel>App</SectionLabel>
        <div className="st-card">
          <StRow icon="moon" label="Appearance" value={mode === 'dark' ? 'Dark' : 'Light'} onClick={onToggleMode} />
          <StRow icon="rings" label="App icon" value={(prefs.icon || 'default') === 'square' ? 'Square' : 'Default'} onClick={() => setAppicon(true)} />
          <StRow icon="bell" label="Notifications" value={prefs.notifs ? (Object.keys(app.muted || {}).length ? Object.keys(app.muted).length + ' muted' : 'On') : 'Off'} onClick={() => setNotif(true)} />
        </div>

        <SectionLabel>Network</SectionLabel>
        <div className="st-card">
          <StRow
            icon="mesh" tone="cyan" label="Connection"
            sub={app.network === 'online' ? 'Bluetooth + internet' : 'Nearby only, no internet'}
            value={app.network === 'online' ? 'Online' : 'Bluetooth only'}
            onClick={toggleNetwork}
          />
        </div>

        <SectionLabel>Wallet</SectionLabel>
        <div className="st-card">
          <StRow icon="coin" tone="gold" label="Balance" value={walletStr(app)} chevron={false} onClick={() => {}} />
          <StRow icon="list" label="Activity" sub="All payments in & out" onClick={() => push('wallet')} />
          <StRow icon="globe" label="Currency" value={(prefs.currency || 'EUR')} onClick={() => setCurSheet(true)} />
          <StRow icon="bolt" label="Bitcoin mode" sub="Show sats and bitcoin networks" onClick={() => onPref('btcMode', !prefs.btcMode)} toggle={!!prefs.btcMode} />
        </div>
        <p className="st-note">Off by default — amounts show in your currency. Turn on to see sats, Lightning and ecash.</p>
        <SectionLabel>Privacy &amp; safety</SectionLabel>
        <div className="st-card">
          <StRow icon="globe" label="Share local time" sub="Default for encrypted chats. You can also turn it on or off in each chat." onClick={() => onPref('shareLocalTime', !prefs.shareLocalTime)} toggle={!!prefs.shareLocalTime} />
          <StRow icon="faceid" label="App lock" sub="Require Face ID to open Sonar" onClick={() => onPref('appLock', !prefs.appLock)} toggle={!!prefs.appLock} />
          <StRow icon="check" label="Read receipts" onClick={() => onPref('readReceipts', !prefs.readReceipts)} toggle={!!prefs.readReceipts} />
          <StRow icon="key" label="Show public keys" sub={prefs.pubkeyUI ? 'Raw npub shown under every name' : 'Nicknames everywhere — keys on tap'} onClick={() => onPref('pubkeyUI', !prefs.pubkeyUI)} toggle={!!prefs.pubkeyUI} />
          <StRow icon="inbox" label="Message requests" value={prefs.requests > 0 ? String(prefs.requests) : ''} onClick={() => setRequests(true)} />
          <StRow icon="shieldCheck" tone="cyan" label="Verified people" value={String(verifiedCount)} onClick={() => push('nearby')} />
          <StRow icon="importKey" label="Export private key" sub="Move your account to another wallet" onClick={() => setExportKey(true)} />
          <StRow icon="trash" tone="red" danger label="Emergency wipe" sub="Deletes your key, chats and nickname" onClick={() => setWipeAsk(true)} />
        </div>
        <p className="st-note">Tip: triple-tap the sonar title on the home screen to wipe instantly.</p>

        <SectionLabel>Data &amp; storage</SectionLabel>
        <div className="st-card">
          <StRow icon="backup" tone="cyan" label="Chat backup" sub={prefs.backupOn ? 'On · last backup today' : 'Off'} value={prefs.backupOn ? '' : 'Set up'} onClick={() => push('backup')} />
          <StRow icon="drive" label="Storage" value="124 MB" onClick={() => {}} />
          <StRow icon="data" label="Data usage" value="Wi-Fi only" onClick={() => {}} />
        </div>

        <SectionLabel>Support Sonar</SectionLabel>
        <button className="st-donate" onClick={() => push('donate')}>
          <span className="st-donateic"><BCIcon name="heart" size={20} /></span>
          <span className="st-donatemain">
            <span className="st-donatetitle">
              {prefs.supporter ? 'You\u2019re a Sonar supporter' : 'Become a supporter'}
              {prefs.supporter ? <SupporterBadge size={15} /> : null}
            </span>
            <span className="st-donatesub">{prefs.supporter ? 'Thank you for keeping Sonar independent' : 'Fund development \u00b7 get a badge \u00b7 no ads, ever'}</span>
          </span>
          <BCIcon name="chevron" size={15} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
        </button>

        <SectionLabel>About</SectionLabel>
        <div className="st-card">
          <StRow icon="info" label="About Sonar" sub="Open protocols — Bluetooth mesh + Nostr" onClick={() => {}} />
          <StRow icon="smile" label="Help" trail="arrowOut" onClick={() => {}} />
        </div>
        <div style={{ height: 16 }}></div>
      </div>

      {notif && <NotifSheet onClose={() => setNotif(false)} prefs={prefs} onPref={onPref} muted={app.muted || {}} onUnmute={onUnmute} />}
      {requests && <RequestsSheet onClose={() => setRequests(false)} onResolve={() => onPref('requests', 0)} />}
      {appicon && <AppIconSheet onClose={() => setAppicon(false)} current={prefs.icon || 'cyan'} onPick={(id) => onPref('icon', id)} />}
      {curSheet && (
        <Sheet onClose={() => setCurSheet(false)} title="Currency">
          {PAY_CURRENCIES.map((c) => (
            <StRow key={c} icon="globe" label={c} sub={PAY_NAMES[c]} value={PAY_SYM[c].trim()} trail={(prefs.currency || 'EUR') === c ? 'check' : null} onClick={() => { onPref('currency', c); setCurSheet(false); }} />
          ))}
          <div className="bc-sheetactions"><button className="bc-ghost" onClick={() => setCurSheet(false)}>Done</button></div>
        </Sheet>
      )}
      {wipeAsk && <WipeSheet onClose={() => setWipeAsk(false)} onWipe={onWipe} />}
      {exportKey && <ExportKeySheet onClose={() => setExportKey(false)} />}
    </div>
  );
}

/* ── Donate / become a supporter (Bolt12) ── */
const DONATE_TIERS = {
  once: [
    { sats: 2100, fiat: '€1.20', label: 'Tip' },
    { sats: 10000, fiat: '€5.80', label: 'Coffee' },
    { sats: 50000, fiat: '€29', label: 'Generous' },
  ],
  monthly: [
    { sats: 2100, fiat: '€1.20/mo', label: 'Friend', badge: true },
    { sats: 8400, fiat: '€4.90/mo', label: 'Sustainer', badge: true },
    { sats: 21000, fiat: '€12/mo', label: 'Patron', badge: true },
  ],
};
const BOLT12_OFFER = 'lno1pg257enxv4ezqcneype82um50ynhxgrwdajx283qfwdpl28qqmc78ymlvhmxcsywdk5wrjnj36jryg488qwlrnzyjczlqsp9nyu4phcg6dqhlhzgxagfu7zh';

function DonateScreen({ app, nav, pop, onBecomeSupporter, overlay }) {
  const isSupporter = !!(app.prefs && app.prefs.supporter);
  const [mode, setMode] = React.useState('monthly');
  const [pick, setPick] = React.useState(1);
  const [paid, setPaid] = React.useState(isSupporter);
  const [copied, setCopied] = React.useState(false);
  const tiers = DONATE_TIERS[mode];
  const tier = tiers[pick] || tiers[0];
  const copy = () => {
    try { navigator.clipboard && navigator.clipboard.writeText(BOLT12_OFFER); } catch (e) {}
    setCopied(true); setTimeout(() => setCopied(false), 1500);
  };
  const pay = () => { setPaid(true); if (mode === 'monthly') onBecomeSupporter(); };

  if (paid && mode === 'monthly') {
    return (
      <div className={'bc-screen' + (overlay ? ' dk-overlay' : '')} data-nav={nav} data-screen-label="Donate — thank you">
        <NavHeader onBack={pop} hairline={false}><div className="bc-hname"><span>Support Sonar</span></div></NavHeader>
        <div className="bc-scroll">
          <div className="dn-thanks">
            <span className="dn-thanksbadge"><BCIcon name="heart" size={40} /></span>
            <h2 className="dn-thankstitle">You’re a supporter</h2>
            <p className="dn-thankssub">Your badge is now visible on your profile and in group chats. Thank you for keeping Sonar independent, open, and ad-free.</p>
            <div className="dn-namepreview">
              <Avatar name={app.nick || 'you'} size={34} />
              <span>{app.nick || 'you'}</span>
              <SupporterBadge size={16} />
            </div>
            <p className="dn-renew">{tier.fiat + ' · renews automatically over Lightning · cancel anytime in Wallet.'}</p>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className={'bc-screen' + (overlay ? ' dk-overlay' : '')} data-nav={nav} data-screen-label="Donate">
      <NavHeader onBack={pop} hairline={false}><div className="bc-hname"><span>Support Sonar</span></div></NavHeader>
      <div className="bc-scroll">
        <div className="dn-hero">
          <span className="dn-heroic"><BCIcon name="heart" size={32} /></span>
          <h2 className="dn-herotitle">Sonar runs on bitcoin, not ads</h2>
          <p className="dn-herosub">No investors, no tracking, no data to sell. Donations pay for development and relays — and keep the app free for everyone.</p>
        </div>

        <div className="dn-seg">
          <button className={mode === 'once' ? 'on' : ''} onClick={() => { setMode('once'); setPick(1); setPaid(false); }}>One-time</button>
          <button className={mode === 'monthly' ? 'on' : ''} onClick={() => { setMode('monthly'); setPick(1); setPaid(false); }}>Monthly</button>
        </div>

        <div className="dn-tiers">
          {tiers.map((t, i) => (
            <button key={i} className={'dn-tier' + (pick === i ? ' on' : '')} onClick={() => setPick(i)}>
              <span className="dn-tierlabel">{t.label}{t.badge ? <SupporterBadge size={13} /> : null}</span>
              <span className="dn-tiersats">{t.sats.toLocaleString('en-US')} <small>sats</small></span>
              <span className="dn-tierfiat">{t.fiat}</span>
            </button>
          ))}
        </div>

        {mode === 'monthly' ? (
          <div className="dn-perk">
            <BCIcon name="shieldCheck" size={16} weight={2.1} />
            <span>Supporters get a <b>badge</b> shown on their profile and in every group chat.</span>
          </div>
        ) : (
          <div className="dn-perk subtle">
            <BCIcon name="heart" size={15} />
            <span>One-time gifts help too — the supporter badge comes with a monthly plan.</span>
          </div>
        )}

        <div className="dn-offer">
          <span className="dn-offerlabel">Bolt12 offer</span>
          <button className="dn-offerrow" onClick={copy}>
            <BCIcon name="bolt" size={15} weight={2.2} style={{ color: 'var(--net)', flex: 'none' }} />
            <span className="dn-offerval">{BOLT12_OFFER.slice(0, 22) + '…' + BOLT12_OFFER.slice(-6)}</span>
            <span className="dn-offercopy">{copied ? 'Copied' : 'Copy'}</span>
          </button>
        </div>
      </div>
      <div className="bc-composerwrap">
        <div style={{ padding: '10px 14px 30px' }}>
          <button className="bc-primary net" onClick={pay}>
            {mode === 'monthly'
              ? 'Subscribe · ' + tier.fiat
              : 'Donate ' + tier.sats.toLocaleString('en-US') + ' sats'}
          </button>
          <p className="dn-paynote">Pays over Lightning to Sonar’s Bolt12 offer. Your name and key are never shared.</p>
        </div>
      </div>
    </div>
  );
}

/* ── Backup: encrypted by default with your identity key — no separate passphrase ── */
function BackupSetupSheet({ onClose, onDone }) {
  return (
    <Sheet onClose={onClose} title="Turn on backup">
      <div className="bk-donehead">
        <span className="bk-doneic"><BCIcon name="backup" size={34} /></span>
        <div className="bk-donetitle">Encrypted automatically</div>
        <p className="bk-donesub">Your backup is locked with the key already on this phone — there’s nothing extra to write down. Sonar’s servers only ever see ciphertext.</p>
      </div>
      <div className="st-card" style={{ margin: '10px 8px 0' }}>
        <div className="bk-feat"><span className="bk-featic"><BCIcon name="lock" size={17} /></span><span className="bk-featmain"><b>No passphrase to lose</b><span>Sealed with your existing identity key.</span></span></div>
        <div className="bk-feat"><span className="bk-featic"><BCIcon name="importKey" size={17} /></span><span className="bk-featmain"><b>Restores itself</b><span>Sign in on a new phone and it recovers in the background.</span></span></div>
      </div>
      <div className="bc-sheetactions">
        <button className="bc-primary" onClick={() => { onDone(); onClose(); }}>Turn on backup</button>
        <button className="bc-ghost" onClick={onClose}>Not now</button>
      </div>
    </Sheet>
  );
}

/* Restore runs automatically. The button is a dry run — a preview of what would come back. */
const DRY_CHATS = [
  { n: 'Lake crew', k: 'group', c: 412, t: 'Maya: bringing the speaker' },
  { n: 'Maya', k: 'dm', c: 286, t: 'find me by the coffee table' },
  { n: 'Weekend trip', k: 'group', c: 173, t: 'Sofia: booked the cabin!' },
  { n: 'Sofia', k: 'dm', c: 158, t: 'done! check your downloads' },
  { n: 'Luca', k: 'dm', c: 121, t: 'see you tomorrow' },
  { n: 'Lugano · Centro', k: 'place', c: 54, t: 'public channel history' },
];

function BackupRestoreSheet({ onClose }) {
  const [phase, setPhase] = React.useState('scan');
  const [step, setStep] = React.useState(0);
  React.useEffect(() => {
    if (phase !== 'scan') return;
    const id = setInterval(() => setStep((s) => {
      if (s >= DRY_CHATS.length) { clearInterval(id); setPhase('preview'); return s; }
      return s + 1;
    }), 420);
    return () => clearInterval(id);
  }, [phase]);
  const found = DRY_CHATS.slice(0, step);
  const msgs = found.reduce((a, c) => a + c.c, 0);
  const ic = (k) => k === 'group' ? 'people' : k === 'place' ? 'pin' : 'lock';
  return (
    <Sheet onClose={onClose} title="Dry run · restore preview">
      <div className="bk-dryhead">
        <span className="bk-drytag">Nothing is changed on your device</span>
        <div className="bk-donetitle">{phase === 'scan' ? 'Reading your backup…' : 'This is what would come back'}</div>
        <p className="bk-donesub">{phase === 'scan'
          ? 'Decrypting the index to show you exactly what a restore would bring back.'
          : found.length + ' conversations · ' + msgs.toLocaleString('en-US') + ' messages · from Today, 04:12'}</p>
      </div>
      <div className="bk-drylist">
        {found.map((c) => (
          <div className="bk-dryrow" key={c.n}>
            <span className="bk-dryic"><BCIcon name={ic(c.k)} size={16} weight={2.1} /></span>
            <span className="bk-drymain">
              <b>{c.n}</b>
              <span>{c.t}</span>
            </span>
            <span className="bk-drycount">{c.c.toLocaleString('en-US')}</span>
          </div>
        ))}
        {phase === 'scan' ? (
          <div className="bk-dryrow scanning">
            <span className="bk-dryic"><svg width="16" height="16" viewBox="0 0 16 16"><circle className="ps-spin" cx="8" cy="8" r="6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeDasharray="12 26" /></svg></span>
            <span className="bk-drymain"><b>Scanning…</b></span>
          </div>
        ) : null}
      </div>
      <div className="bc-sheetactions">
        <button className="bc-ghost" onClick={onClose}>Close preview</button>
      </div>
    </Sheet>
  );
}

function BackupScreen({ app, nav, pop, onPref }) {
  const prefs = app.prefs || {};
  const on = !!prefs.backupOn;
  const [setup, setSetup] = React.useState(false);
  const [freqSheet, setFreqSheet] = React.useState(false);
  const [restore, setRestore] = React.useState(false);
  const freq = prefs.backupFreq || 'Daily';
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Chat backup">
      <NavHeader onBack={pop} hairline={false}><div className="bc-hname"><span>Chat backup</span></div></NavHeader>
      <div className="bc-scroll">
        <div className="bk-hero">
          <span className={'bk-heroic' + (on ? ' on' : '')}><BCIcon name="backup" size={34} /></span>
          <h2 className="bk-herotitle">{on ? 'Backups are on' : 'Back up your chats'}</h2>
          <p className="bk-herosub">{on
            ? 'Your history is encrypted with the key on this phone — nothing extra to remember.'
            : 'Keep an encrypted copy of your messages, groups and settings so you can restore on a new phone.'}</p>
        </div>

        {on ? (
          <React.Fragment>
            <div className="st-card">
              <StRow icon="backup" tone="cyan" label="Backup" value="On" onClick={() => onPref('backupOn', false)} toggle={true} />
              <StRow icon="data" label="Frequency" value={freq} onClick={() => setFreqSheet(true)} />
              <StRow icon="drive" label="Last backup" sub="Restores automatically · tap for a dry run" value="Today, 04:12" onClick={() => setRestore(true)} />
            </div>
            <div className="bk-stats">
              <div className="bk-stat"><b>128 MB</b><span>backup size</span></div>
              <div className="bk-stat"><b>End-to-end</b><span>encrypted</span></div>
              <div className="bk-stat"><b>1,204</b><span>messages</span></div>
            </div>
            <p className="st-note">Backups are encrypted on this device before upload. Sonar’s servers only ever see ciphertext.</p>
            <div className="st-card" style={{ marginTop: 8 }}>
              <StRow icon="importKey" label="Dry run a restore" sub="Preview what would come back — changes nothing" onClick={() => setRestore(true)} />
            </div>
          </React.Fragment>
        ) : (
          <React.Fragment>
            <div className="st-card">
              <div className="bk-feat"><span className="bk-featic"><BCIcon name="lock" size={17} /></span><span className="bk-featmain"><b>Encrypted by default</b><span>Sealed with the key already on this phone.</span></span></div>
              <div className="bk-feat"><span className="bk-featic"><BCIcon name="data" size={17} /></span><span className="bk-featmain"><b>Automatic</b><span>Runs quietly in the background, on your schedule.</span></span></div>
              <div className="bk-feat"><span className="bk-featic"><BCIcon name="importKey" size={17} /></span><span className="bk-featmain"><b>Restores automatically</b><span>Sign in on a new phone and your history comes back on its own.</span></span></div>
            </div>
            <div className="st-card" style={{ marginTop: 8 }}>
              <StRow icon="importKey" label="Dry run a restore" sub="Preview what would come back — changes nothing" onClick={() => setRestore(true)} />
            </div>
          </React.Fragment>
        )}
        <div style={{ height: 16 }}></div>
      </div>

      {!on && (
        <div className="bc-composerwrap">
          <div style={{ padding: '10px 14px 30px' }}>
            <button className="bc-primary" onClick={() => setSetup(true)}>Turn on backup</button>
            <p className="dn-paynote">Encrypted with the key already on this phone — nothing to write down.</p>
          </div>
        </div>
      )}

      {setup && <BackupSetupSheet onClose={() => setSetup(false)} onDone={() => onPref('backupOn', true)} />}
      {freqSheet && (
        <Sheet onClose={() => setFreqSheet(false)} title="Backup frequency">
          {['Daily', 'Weekly', 'Manual only'].map((f) => (
            <StRow key={f} icon="data" label={f} trail={freq === f ? 'check' : null} onClick={() => { onPref('backupFreq', f); setFreqSheet(false); }} />
          ))}
          <div className="bc-sheetactions"><button className="bc-ghost" onClick={() => setFreqSheet(false)}>Done</button></div>
        </Sheet>
      )}
      {restore && <BackupRestoreSheet onClose={() => setRestore(false)} />}
    </div>
  );
}

/* ── Wallet activity screen ── */
function WalletScreen({ app, nav, pop }) {
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Wallet activity">
      <NavHeader onBack={pop} hairline={false}>
        <div className="bc-hname"><span>Wallet</span></div>
      </NavHeader>
      <div className="bc-scroll">
        <div className="wallet-balance">
          <span className="wallet-balnum">{walletStr(app)}</span>
          <span className="wallet-ballabel">Balance · pays directly, no claim step</span>
        </div>
        <SectionLabel>Activity</SectionLabel>
        <WalletActivity app={app} txns={app.txns} />
      </div>
    </div>
  );
}

Object.assign(window, { SettingsScreen, WalletScreen, ProfileScreen, DonateScreen, BackupScreen, ShareCode, KeyShareCard, ExportKeySheet, StRow, StSwitch });

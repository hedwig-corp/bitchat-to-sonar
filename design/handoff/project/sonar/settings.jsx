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

/* ── Profile screen ── */
function ProfileScreen({ app, nav, pop, onRename }) {
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
          <span className="pf-key">{shortKey}</span>
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
function NotifSheet({ onClose, prefs, onPref }) {
  return (
    <Sheet onClose={onClose} title="Notifications">
      <StRow icon="bell" label="Allow notifications" onClick={() => onPref('notifs', !prefs.notifs)} toggle={prefs.notifs} />
      <StRow icon="people" label="Show names" sub="Hide to keep the lock screen private" onClick={() => onPref('names', !prefs.names)} toggle={prefs.names && prefs.notifs} />
      <StRow icon="list" label="Show message preview" onClick={() => onPref('preview', !prefs.preview)} toggle={prefs.preview && prefs.notifs} />
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
function SettingsScreen({ app, nav, pop, push, mode, onToggleMode, toggleNetwork, onWipe, onPref }) {
  const [notif, setNotif] = React.useState(false);
  const [requests, setRequests] = React.useState(false);
  const [appicon, setAppicon] = React.useState(false);
  const [wipeAsk, setWipeAsk] = React.useState(false);
  const [curSheet, setCurSheet] = React.useState(false);
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
            <div className="st-profkey">{shortKey}</div>
          </span>
          <BCIcon name="chevron" size={15} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
        </button>

        <SectionLabel>App</SectionLabel>
        <div className="st-card">
          <StRow icon="moon" label="Appearance" value={mode === 'dark' ? 'Dark' : 'Light'} onClick={onToggleMode} />
          <StRow icon="rings" label="App icon" value={(prefs.icon || 'default') === 'square' ? 'Square' : 'Default'} onClick={() => setAppicon(true)} />
          <StRow icon="bell" label="Notifications" value={prefs.notifs ? 'On' : 'Off'} onClick={() => setNotif(true)} />
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
          <StRow icon="globe" label="Currency" value={(prefs.currency || 'EUR')} onClick={() => setCurSheet(true)} />
          <StRow icon="bolt" label="Bitcoin mode" sub="Show sats and bitcoin networks" onClick={() => onPref('btcMode', !prefs.btcMode)} toggle={!!prefs.btcMode} />
        </div>
        <p className="st-note">Off by default — amounts show in your currency. Turn on to see sats, Lightning and ecash.</p>

        <SectionLabel>Privacy &amp; safety</SectionLabel>
        <div className="st-card">
          <StRow icon="faceid" label="App lock" sub="Require Face ID to open Sonar" onClick={() => onPref('appLock', !prefs.appLock)} toggle={!!prefs.appLock} />
          <StRow icon="check" label="Read receipts" onClick={() => onPref('readReceipts', !prefs.readReceipts)} toggle={!!prefs.readReceipts} />
          <StRow icon="inbox" label="Message requests" value={prefs.requests > 0 ? String(prefs.requests) : ''} onClick={() => setRequests(true)} />
          <StRow icon="shieldCheck" tone="cyan" label="Verified people" value={String(verifiedCount)} onClick={() => push('nearby')} />
          <StRow icon="trash" tone="red" danger label="Emergency wipe" sub="Deletes your key, chats and nickname" onClick={() => setWipeAsk(true)} />
        </div>
        <p className="st-note">Tip: triple-tap the sonar title on the home screen to wipe instantly.</p>

        <SectionLabel>Data &amp; storage</SectionLabel>
        <div className="st-card">
          <StRow icon="drive" label="Storage" value="124 MB" onClick={() => {}} />
          <StRow icon="data" label="Data usage" value="Wi-Fi only" onClick={() => {}} />
        </div>

        <SectionLabel>About</SectionLabel>
        <div className="st-card">
          <StRow icon="info" label="About Sonar" sub="Open protocols — Bluetooth mesh + Nostr" onClick={() => {}} />
          <StRow icon="smile" label="Help" trail="arrowOut" onClick={() => {}} />
        </div>
        <div style={{ height: 16 }}></div>
      </div>

      {notif && <NotifSheet onClose={() => setNotif(false)} prefs={prefs} onPref={onPref} />}
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
    </div>
  );
}

Object.assign(window, { SettingsScreen, ProfileScreen, ShareCode, KeyShareCard, StRow, StSwitch });

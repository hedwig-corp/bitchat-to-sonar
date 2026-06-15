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

/* ── Profile screen ── */
function ProfileScreen({ app, nav, pop, onRename }) {
  const [editing, setEditing] = React.useState(false);
  const [draft, setDraft] = React.useState(app.nick || '');
  const [showKey, setShowKey] = React.useState(false);
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

        <div className="pf-codecard">
          <ShareCode seed={BC_DATA.pubkey} />
          <span className="pf-codecaption">Show this code to someone nearby to start an encrypted chat.</span>
        </div>

        <SectionLabel>Keys</SectionLabel>
        <div className="st-card">
          <StRow
            icon="key" tone="cyan" label="Key fingerprint"
            value={<span style={{ fontFamily: 'var(--mono)', fontSize: 12.5 }}>{BC_DATA.myFingerprint}</span>}
            trail={null} onClick={() => {}}
          />
          <StRow
            icon="lock" label="Public key" sub={showKey ? null : 'Tap to reveal'}
            onClick={() => setShowKey(!showKey)}
          />
        </div>
        {showKey ? <div className="bc-pubkey" style={{ textAlign: 'left', padding: '2px 26px 8px' }}>{BC_DATA.pubkey}</div> : null}
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
  { id: 'cyan', bg: 'var(--accent-fill)', fg: 'var(--on-accent)' },
  { id: 'midnight', bg: '#0B0E10', fg: '#22D3EE' },
  { id: 'paper', bg: '#F2F6F7', fg: '#0891B2' },
];

function AppIconSheet({ onClose, current, onPick }) {
  return (
    <Sheet onClose={onClose} title="App icon">
      <div className="ai-row">
        {SN_APP_ICONS.map((ic) => (
          <button
            key={ic.id}
            className={'ai-tile' + (current === ic.id ? ' on' : '')}
            style={{ background: ic.bg, color: ic.fg }}
            onClick={() => { onPick(ic.id); onClose(); }}
            aria-label={'App icon ' + ic.id}
          >
            <BCIcon name="rings" size={30} weight={1.7} />
          </button>
        ))}
      </div>
      <p className="bc-verifycopy" style={{ paddingTop: 0 }}>Quiet options only — no badges, no noise.</p>
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
          <StRow icon="rings" label="App icon" value={prefs.icon === 'cyan' ? 'Cyan' : prefs.icon === 'midnight' ? 'Midnight' : 'Paper'} onClick={() => setAppicon(true)} />
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

Object.assign(window, { SettingsScreen, ProfileScreen, ShareCode, StRow, StSwitch });

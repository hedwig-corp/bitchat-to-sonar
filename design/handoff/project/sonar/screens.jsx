// Sonar — screens: Onboarding, Home, Channel, DM, Sonar (radar), Settings
// Depends on: components.jsx exports + BC_DATA.

/* ── Onboarding (3 steps) ── */
function Onboarding({ initialNick, onDone }) {
  const [step, setStep] = React.useState(0);
  const [nick, setNick] = React.useState(initialNick || '');
  const can = nick.trim().length >= 2;
  const surprise = () => {
    const list = BC_DATA.nicknames;
    setNick(list[Math.floor(Math.random() * list.length)]);
  };
  return (
    <div className="bc-onboard" data-screen-label={'Onboarding step ' + (step + 1)}>
      <div className="bc-obtop">
        {step > 0 && (
          <button className="bc-iconbtn" onClick={() => setStep(step - 1)} aria-label="Back">
            <BCIcon name="back" size={21} weight={2.1} />
          </button>
        )}
      </div>

      {step === 0 && (
        <div className="bc-obbody" key="s0">
          <div className="bc-obmark"><BCIcon name="rings" size={40} weight={1.5} /></div>
          <h1 className="bc-obtitle">Sense who’s nearby before you see them.</h1>
          <p className="bc-obsub">Sonar connects phones directly — no phone number, no account, no servers.</p>
          <div className="bc-obrow">
            <span className="bc-obrowicon"><BCIcon name="mesh" size={20} /></span>
            <span>
              <div className="bc-obrowtitle">Works without internet</div>
              <div className="bc-obrowdesc">Bluetooth finds people around you, even offline.</div>
            </span>
          </div>
          <div className="bc-obrow">
            <span className="bc-obrowicon"><BCIcon name="globe" size={20} /></span>
            <span>
              <div className="bc-obrowtitle">Out of range? Still reachable</div>
              <div className="bc-obrowdesc">Messages travel encrypted over the open internet instead.</div>
            </span>
          </div>
          <div className="bc-obrow">
            <span className="bc-obrowicon"><BCIcon name="lock" size={20} /></span>
            <span>
              <div className="bc-obrowtitle">Private by design</div>
              <div className="bc-obrowdesc">Direct messages are end-to-end encrypted. Always.</div>
            </span>
          </div>
        </div>
      )}

      {step === 1 && (
        <div className="bc-obbody" key="s1">
          <h1 className="bc-obtitle">Pick a nickname</h1>
          <p className="bc-obsub">It’s just what people see — change it anytime.</p>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 18 }}>
            <Avatar name={nick.trim() || '?'} size={72} />
            <div style={{ flex: 1 }}>
              <input
                className="bc-nickinput" type="text" value={nick} maxLength={20}
                placeholder="nickname"
                onChange={(e) => setNick(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter' && can) setStep(2); }}
              />
            </div>
          </div>
          <button className="bc-suggest" onClick={surprise}>
            <BCIcon name="dice" size={16} weight={2} />
            Surprise me
          </button>
          <p className="bc-note">No signup. Your identity is a private key created on this phone — nobody else ever sees it.</p>
        </div>
      )}

      {step === 2 && (
        <div className="bc-obbody" key="s2">
          <Avatar name={nick.trim()} size={92} style={{ marginBottom: 22 }} />
          <h1 className="bc-obtitle">You’re in, {nick.trim()}.</h1>
          <p className="bc-obsub">No account was created anywhere — your identity lives on this phone.</p>
          <div className="bc-fpcard">
            <span className="bc-fplabel">Your key fingerprint</span>
            <span className="bc-fp">{BC_DATA.myFingerprint}</span>
          </div>
          <p className="bc-note">Friends can verify this fingerprint in person to be sure it’s really you.</p>
        </div>
      )}

      <div className="bc-obfooter">
        <div className="bc-dots">
          <span className={step === 0 ? 'on' : ''}></span>
          <span className={step === 1 ? 'on' : ''}></span>
          <span className={step === 2 ? 'on' : ''}></span>
        </div>
        {step === 0 && <button className="bc-primary" onClick={() => setStep(1)}>Get started</button>}
        {step === 1 && <button className="bc-primary" disabled={!can} onClick={() => setStep(2)}>Continue</button>}
        {step === 2 && <button className="bc-primary" onClick={() => onDone(nick.trim())}>Start chatting</button>}
      </div>
    </div>
  );
}

/* ── Wipe confirmation (shared by Home triple-tap + Settings) ── */
function WipeSheet({ onClose, onWipe }) {
  return (
    <Sheet onClose={onClose} title="Emergency wipe">
      <p className="bc-verifycopy">
        This deletes your key, your nickname and every conversation from this phone.
        There is no account to recover — gone is gone.
      </p>
      <div className="bc-sheetactions">
        <button className="bc-primary danger" onClick={onWipe}>Wipe everything</button>
        <button className="bc-ghost" onClick={onClose}>Cancel</button>
      </div>
    </Sheet>
  );
}

/* ── "Around you": collapses the whole precision ladder into ONE row ── */
function HereCard({ onEnter }) {
  const ladder = BC_DATA.here || [];
  const def = (() => {
    for (let i = 0; i < ladder.length; i++) if (ladder[i].count > 0) return i;
    return Math.max(0, ladder.length - 1);
  })();
  const [idx, setIdx] = React.useState(def);
  const lv = ladder[idx];
  if (!lv) return null;
  return (
    <div className="here-card">
      <button className="here-main" onClick={() => onEnter(lv)}>
        <PlaceTile size={52} />
        <span className="here-text">
          <span className="here-name">{lv.name}</span>
          <span className="here-sub">{lv.tier} · {lv.count} here now</span>
        </span>
        <BCIcon name="chevron" size={15} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
      </button>
      <div className="here-scale" role="group" aria-label="Precision">
        {ladder.map((l, i) => (
          <button key={l.id} className={'here-tick' + (i === idx ? ' on' : '')} onClick={() => setIdx(i)}>
            {l.short}{l.count > 0 ? <i className="here-live"></i> : null}
          </button>
        ))}
      </div>
    </div>
  );
}

/* ── Home ── */
function HomeScreen({ app, t, nav, push, toggleNetwork, onWipe }) {
  const meshCount = BC_DATA.peers.filter((p) => p.inRange).length;
  const [wipeAsk, setWipeAsk] = React.useState(false);
  const taps = React.useRef([]);
  const titleTap = () => {
    const now = Date.now();
    taps.current = taps.current.filter((x) => now - x < 1200);
    taps.current.push(now);
    if (taps.current.length >= 3) { taps.current = []; setWipeAsk(true); }
  };
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Home">
      <div className="bc-header">
        <button className="bc-iconbtn" onClick={() => push('settings')} aria-label="Settings">
          <Avatar name={app.nick || 'you'} size={32} />
        </button>
        <div className="bc-htitle" style={{ textAlign: 'center', paddingLeft: 0 }} onClick={titleTap} title="Triple-tap to wipe">sonar</div>
        <button className="bc-iconbtn" onClick={() => push('nearby')} aria-label="People nearby">
          <BCIcon name="rings" size={22} />
        </button>
      </div>
      <StatusChip network={app.network} meshCount={meshCount} variant={t.chip} onToggle={toggleNetwork} />
      <div className="bc-scroll" style={{ paddingBottom: 120 }}>
        <SectionLabel>Around you</SectionLabel>
        <HereCard onEnter={(lv) => push('channel', { id: lv.id })} />
        <SectionLabel>Saved channels</SectionLabel>
        <div className="bc-list">
          {BC_DATA.channels.map((ch) => (
            <ConvRow
              key={ch.id}
              av={<PlaceTile size={52} />}
              title={<span>{ch.name}</span>}
              sub={<span>{ch.preview}</span>}
              time={ch.time}
              unread={app.read[ch.id] ? 0 : ch.unread}
              onClick={() => push('channel', { id: ch.id })}
            />
          ))}
        </div>
        <SectionLabel>Messages</SectionLabel>
        <div className="bc-list">
          {BC_DATA.homeDMs.map((d) => {
            const peer = BC_DATA.peers.find((p) => p.id === d.peer);
            const msgs = app.dmMsgs[d.peer];
            const last = msgs && msgs.length ? msgs[msgs.length - 1] : null;
            const preview = last && !last.action ? last.text : d.preview;
            return (
              <ConvRow
                key={d.peer}
                av={<Avatar name={peer.name} size={52} presence={peer.inRange} />}
                title={<span>{peer.name}</span>}
                extra={app.verified[d.peer]
                  ? <BCIcon name="shieldCheck" size={14} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
                  : null}
                sub={<><BCIcon name="lock" size={12} weight={2.2} style={{ flex: 'none', color: 'var(--text3)' }} /><span>{preview}</span></>}
                time={d.time}
                unread={app.read[d.peer] ? 0 : d.unread}
                onClick={() => push('dm', { id: d.peer })}
              />
            );
          })}
        </div>
      </div>
      <div className="sn-fab">
        <button className="sn-search">
          <BCIcon name="search" size={17} weight={2} />
          Search
        </button>
        <button className="sn-compose" onClick={() => push('nearby')} aria-label="Discover people nearby">
          <BCIcon name="rings" size={23} weight={1.9} />
        </button>
      </div>
      {wipeAsk && <WipeSheet onClose={() => setWipeAsk(false)} onWipe={onWipe} />}
    </div>
  );
}

/* ── Location channel (public) ── */
function ChannelScreen({ app, nav, pop, push, chId, onSend, onCommand }) {
  const ch = BC_DATA.channels.find((c) => c.id === chId) || (BC_DATA.here || []).find((c) => c.id === chId) || BC_DATA.channels[0];
  const msgs = app.chMsgs[ch.id] || [];
  const [sheet, setSheet] = React.useState(false);
  const transport = app.network === 'online' ? 'internet' : 'mesh';
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label={'Channel: ' + ch.name}>
      <NavHeader
        onBack={pop}
        trailing={
          <button className="bc-iconbtn" onClick={() => push('nearby')} aria-label="People nearby">
            <BCIcon name="rings" size={20} />
          </button>
        }
      >
        <PlaceTile size={36} />
        <div style={{ minWidth: 0 }}>
          <div className="bc-hname"><span>{ch.name}</span></div>
          <div className="bc-hsub"><span className="bc-dot g sm"></span>{ch.sub}</div>
        </div>
      </NavHeader>
      <Banner icon="people" tone="public">
        <b>Public channel</b> — anyone nearby can read
      </Banner>
      {msgs.length === 0 ? (
        <div className="bc-empty">
          <span className="bc-emptyicon amber"><BCIcon name="pin" size={26} /></span>
          <div className="bc-emptytitle">Quiet in {ch.name} right now</div>
          <div className="bc-emptydesc">{ch.count} people are in range of this channel today. Say hi.</div>
        </div>
      ) : (
        <MsgList msgs={msgs} showAuthors />
      )}
      <Composer
        placeholder={'Message ' + ch.name}
        transport={transport}
        onSend={(tx) => onSend(ch.id, tx)}
        onPlus={() => setSheet(true)}
        onCommand={(c) => onCommand({ type: 'ch', id: ch.id, target: 'Luca' }, c)}
      />
      {sheet && (
        <Sheet onClose={() => setSheet(false)} title="Add to your message">
          <ActionRow icon="navArrow" label="Share location" desc="Drop a pin for people in this channel" onClick={() => setSheet(false)} />
          <ActionRow icon="people" label="People nearby" desc="See who can hear you over Bluetooth" onClick={() => { setSheet(false); push('nearby'); }} />
          <ActionRow icon="smile" label="Reactions" desc="A little fun, no noise" onClick={() => setSheet(false)} />
        </Sheet>
      )}
    </div>
  );
}

/* ── Direct message (encrypted, transport-aware) ── */
function DMScreen({ app, nav, pop, push, peerId, onSend, onCommand, onVerify, onPay, onClaimPay, openPay }) {
  const peer = BC_DATA.peers.find((p) => p.id === peerId) || BC_DATA.peers[0];
  const msgs = app.dmMsgs[peer.id] || [];
  const [sheet, setSheet] = React.useState(false);
  const [verify, setVerify] = React.useState(false);
  const [showKey, setShowKey] = React.useState(false);
  const [pay, setPay] = React.useState(!!openPay);
  const verified = !!app.verified[peer.id];
  const transport = peer.inRange ? 'mesh' : 'internet';
  const offlineFar = !peer.inRange && app.network !== 'online';
  const sub = verified ? 'Verified · ' : '';
  const subTransport = peer.inRange
    ? 'Nearby · Bluetooth'
    : (offlineFar ? 'Offline — will send later' : 'Via internet');
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label={'DM: ' + peer.name}>
      <NavHeader onBack={pop}>
        <Avatar name={peer.name} size={36} presence={peer.inRange} />
        <div style={{ minWidth: 0 }}>
          <div className="bc-hname">
            <span>{peer.name}</span>
            {verified
              ? <BCIcon name="shieldCheck" size={15} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
              : null}
          </div>
          <div className="bc-hsub">
            <BCIcon name="lock" size={11} weight={2.4} />
            {sub}{subTransport}
          </div>
        </div>
      </NavHeader>
      {verified ? (
        <Banner icon="shieldCheck" tone="enc">
          <b>Verified</b> — you confirmed {peer.name}’s safety number
        </Banner>
      ) : peer.inRange ? (
        <Banner
          icon="lock" tone="enc"
          action={<button className="bc-bannerbtn" onClick={() => setVerify(true)}>Verify</button>}
        >
          <b>End-to-end encrypted</b> — only you and {peer.name} can read this
        </Banner>
      ) : (
        <Banner
          icon="globe" tone="net"
          action={<button className="bc-bannerbtn" onClick={() => setVerify(true)}>Verify</button>}
        >
          <b>Out of Bluetooth range</b> — encrypted over the internet instead
        </Banner>
      )}
      {msgs.length === 0 ? (
        <div className="bc-empty">
          <span className="bc-emptyicon"><BCIcon name="lock" size={24} /></span>
          <div className="bc-emptytitle">Say hi to {peer.name}</div>
          <div className="bc-emptydesc">Messages here are end-to-end encrypted. Only the two of you can read them.</div>
        </div>
      ) : (
        <MsgList msgs={msgs} showAuthors={false} peerName={peer.name} onClaim={(i) => onClaimPay(peer.id, i)} />
      )}
      <Composer
        placeholder={'Message ' + peer.name + (peer.inRange ? '' : ' · via internet')}
        transport={transport}
        onSend={(tx) => onSend(peer.id, tx)}
        onPlus={() => setSheet(true)}
        onCommand={(c) => onCommand({ type: 'dm', id: peer.id, target: peer.name }, c)}
      />
      {sheet && (
        <Sheet onClose={() => setSheet(false)} title="Add to your message">
          <ActionRow icon="coin" label="Send bitcoin" desc={peer.inRange ? 'Travels over Bluetooth as ecash' : 'Instant over Lightning'} onClick={() => { setSheet(false); setPay(true); }} />
          <ActionRow icon="navArrow" label="Share location" desc={'Only ' + peer.name + ' will see it'} onClick={() => setSheet(false)} />
          <ActionRow icon="shield" label="Verify safety number" desc="Confirm this chat is secure" onClick={() => { setSheet(false); setVerify(true); }} />
          <ActionRow icon="smile" label="Reactions" desc="A little fun, no noise" onClick={() => setSheet(false)} />
        </Sheet>
      )}
      {verify && (
        <Sheet onClose={() => { setVerify(false); setShowKey(false); }} title={'Verify ' + peer.name}>
          <div className="bc-verifyheads">
            <span className="bc-verifyhead"><Avatar name={app.nick || 'you'} size={48} />you</span>
            <span className="bc-verifyhead"><Avatar name={peer.name} size={48} />{peer.name}</span>
          </div>
          <p className="bc-verifycopy">
            Compare these numbers with {peer.name} in person or on a call.
            If they match, this chat is end-to-end encrypted and nobody is in the middle.
          </p>
          <div className="bc-safety">
            {[0, 4, 8].map((row) => (
              <div key={row}>{BC_DATA.safety.slice(row, row + 4).join('\u2002')}</div>
            ))}
          </div>
          {showKey
            ? <div className="bc-pubkey">{BC_DATA.pubkey}</div>
            : null}
          <div className="bc-sheetactions">
            <button className="bc-primary" onClick={() => { onVerify(peer.id); setVerify(false); setShowKey(false); }}>
              They match — mark as verified
            </button>
            <button className="bc-ghost" onClick={() => setShowKey(!showKey)}>
              {showKey ? 'Hide public key' : 'Show public key'}
            </button>
          </div>
        </Sheet>
      )}
      {pay && (
        <PaySheet
          peer={peer} balance={app.balance || 0} transport={transport}
          onClose={() => setPay(false)} onSend={(sats) => onPay(sats)}
        />
      )}
    </div>
  );
}

/* ── Sonar discovery: radar + list ── */
function SonarScreen({ app, nav, pop, push }) {
  const [view, setView] = React.useState('radar');
  const [psel, setPsel] = React.useState(null);
  const inRange = BC_DATA.peers.filter((p) => p.inRange);
  const far = BC_DATA.peers.filter((p) => !p.inRange);
  const C = 174; // radar center
  const pos = (p) => {
    const a = (p.angle * Math.PI) / 180;
    return { left: C + p.r * Math.cos(a), top: C + p.r * Math.sin(a) };
  };
  const dots = [];
  [40, 88, 134, 170].forEach((r) => {
    const n = Math.floor((2 * Math.PI * r) / 17);
    for (let i = 0; i < n; i++) {
      const a = (i / n) * 2 * Math.PI;
      dots.push(<circle key={r + '-' + i} cx={C + r * Math.cos(a)} cy={C + r * Math.sin(a)} r="1.2" fill="var(--radar-dot)" />);
    }
  });
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Sonar discovery">
      <NavHeader onBack={pop} hairline={false}>
        <div style={{ minWidth: 0 }}>
          <div className="bc-hname"><span>Sonar</span></div>
          <div className="bc-hsub"><span className="bc-dot g sm"></span>{inRange.length} in range · scanning</div>
        </div>
      </NavHeader>
      <div className="sn-seg">
        <button className={view === 'radar' ? 'on' : ''} onClick={() => setView('radar')}>
          <BCIcon name="rings" size={15} weight={2} />Radar
        </button>
        <button className={view === 'list' ? 'on' : ''} onClick={() => setView('list')}>
          <BCIcon name="list" size={15} weight={2} />List
        </button>
      </div>

      {view === 'radar' ? (
        <div className="sn-radarwrap">
          <div className="sn-radar">
            <svg width="348" height="348" viewBox="0 0 348 348" style={{ position: 'absolute', inset: 0 }}>
              <circle cx={C} cy={C} r="66" fill="none" stroke="var(--radar-ring)" />
              <circle cx={C} cy={C} r="112" fill="none" stroke="var(--radar-ring)" />
              <circle cx={C} cy={C} r="158" fill="none" stroke="var(--radar-ring)" />
              {dots}
            </svg>
            <div className="sn-sweep"></div>
            <div className="sn-pulse"></div>
            <div className="sn-pulse d2"></div>
            <div className="sn-node you" style={{ left: C, top: C }}>
              <Avatar name={app.nick || 'you'} size={52} />
              <span className="sn-nodename">you</span>
            </div>
            {inRange.map((p) => (
              <button key={p.id} className="sn-node" style={pos(p)} onClick={() => setPsel(p)}>
                <Avatar name={p.name} size={44} presence />
                <span className="sn-nodename">{p.name}</span>
              </button>
            ))}
            {far.map((p) => (
              <button key={p.id} className="sn-node ghost" style={pos(p)} onClick={() => setPsel(p)}>
                <span style={{ position: 'relative', display: 'inline-block' }}>
                  <Avatar name={p.name} size={34} />
                  <span className="sn-ghostbadge"><BCIcon name="globe" size={9} weight={2.4} /></span>
                </span>
                <span className="sn-nodename">{p.name}</span>
              </button>
            ))}
          </div>
          <div className="sn-caption">Tap someone to chat</div>
          <div className="sn-legend">
            <span><i className="sn-ldot ble"></i>nearby · Bluetooth</span>
            <span><i className="sn-ldot net"></i>far · internet</span>
          </div>
          {psel && (
            <div className="sn-peercard">
              <Avatar name={psel.name} size={44} presence={psel.inRange} />
              <span className="pcmain">
                <div className="pcname">{psel.name}</div>
                <div className="pchint">{psel.inRange ? psel.hint + ' · over Bluetooth' : 'Out of range · over the internet'}</div>
              </span>
              <button className="pf-smallbtn" onClick={() => push('dm', { id: psel.id })}>Message</button>
              <button className="pf-smallbtn primary" onClick={() => push('dm', { id: psel.id, pay: 1 })}>Send sats</button>
            </div>
          )}
        </div>
      ) : (
        <div className="bc-scroll">
          <SectionLabel>In range · Bluetooth</SectionLabel>
          <div className="bc-list">
            {inRange.map((p) => (
              <ConvRow
                key={p.id}
                av={<Avatar name={p.name} size={44} presence />}
                title={<span>{p.name}</span>}
                extra={app.verified[p.id]
                  ? <BCIcon name="shieldCheck" size={14} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
                  : null}
                sub={<span className="bc-signal"><Bars n={p.bars} />{p.hint} · {p.detail}</span>}
                onClick={() => push('dm', { id: p.id })}
              />
            ))}
          </div>
          <SectionLabel>Out of range · internet</SectionLabel>
          <div className="bc-list">
            {far.map((p) => (
              <ConvRow
                key={p.id}
                av={<Avatar name={p.name} size={44} />}
                title={<span>{p.name}</span>}
                sub={<span className="bc-signal"><BCIcon name="globe" size={12} weight={2.2} style={{ color: 'var(--net)', flex: 'none' }} />{p.detail}</span>}
                onClick={() => push('dm', { id: p.id })}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

/* ── Settings (XChat-inspired: profile card + grouped sections) ── */
function SettingsScreen({ app, nav, pop, push, mode, onToggleMode, toggleNetwork, onWipe }) {
  const [identity, setIdentity] = React.useState(false);
  const [wipeAsk, setWipeAsk] = React.useState(false);
  const verifiedCount = Object.keys(app.verified).length;
  const shortKey = BC_DATA.pubkey.slice(0, 14) + '\u2026' + BC_DATA.pubkey.slice(-6);
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Settings">
      <NavHeader onBack={pop} hairline={false}>
        <div className="bc-hname"><span>Settings</span></div>
      </NavHeader>
      <div className="bc-scroll">
        <button className="st-prof" onClick={() => setIdentity(true)}>
          <Avatar name={app.nick || 'you'} size={56} />
          <span className="st-profmain">
            <div className="st-profname">{app.nick || 'you'}</div>
            <div className="st-profkey">{shortKey}</div>
          </span>
          <BCIcon name="chevron" size={15} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
        </button>

        <SectionLabel>App</SectionLabel>
        <SettingsCard>
          <SettingsRow icon="moon" label="Appearance" value={mode === 'dark' ? 'Dark' : 'Light'} onClick={onToggleMode} />
          <SettingsRow icon="bell" label="Notifications" onClick={() => {}} />
        </SettingsCard>

        <SectionLabel>Network</SectionLabel>
        <SettingsCard>
          <SettingsRow
            icon="mesh" tone="cyan" label="Connection"
            value={app.network === 'online' ? 'Online' : 'Bluetooth only'}
            onClick={toggleNetwork}
          />
        </SettingsCard>

        <SectionLabel>Privacy</SectionLabel>
        <SettingsCard>
          <SettingsRow
            icon="shieldCheck" tone="cyan" label="Verified people"
            value={String(verifiedCount)}
            onClick={() => push('nearby')}
          />
          <SettingsRow
            icon="trash" tone="red" danger label="Emergency wipe"
            sub="Deletes your key, chats and nickname"
            onClick={() => setWipeAsk(true)}
          />
        </SettingsCard>
        <p className="st-note">Tip: triple-tap the sonar title on the home screen to wipe instantly.</p>

        <SectionLabel>About</SectionLabel>
        <SettingsCard>
          <SettingsRow icon="info" label="About Sonar" sub="Open protocols — Bluetooth mesh + Nostr" onClick={() => {}} />
        </SettingsCard>
      </div>

      {identity && (
        <Sheet onClose={() => setIdentity(false)} title="Your identity">
          <div className="bc-verifyheads">
            <span className="bc-verifyhead"><Avatar name={app.nick || 'you'} size={56} />{app.nick || 'you'}</span>
          </div>
          <p className="bc-verifycopy">
            Your identity is a key that lives only on this phone.
            Share your fingerprint in person so friends can verify it’s really you.
          </p>
          <div className="bc-fpcard" style={{ margin: '4px 8px 10px' }}>
            <span className="bc-fplabel">Key fingerprint</span>
            <span className="bc-fp">{BC_DATA.myFingerprint}</span>
          </div>
          <div className="bc-pubkey">{BC_DATA.pubkey}</div>
          <div className="bc-sheetactions">
            <button className="bc-ghost" onClick={() => setIdentity(false)}>Done</button>
          </div>
        </Sheet>
      )}
      {wipeAsk && <WipeSheet onClose={() => setWipeAsk(false)} onWipe={onWipe} />}
    </div>
  );
}

Object.assign(window, { Onboarding, HomeScreen, ChannelScreen, DMScreen, SonarScreen, SettingsScreen, WipeSheet });

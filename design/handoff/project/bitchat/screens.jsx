// bitchat — screens: Onboarding, Home, Channel, DM, Nearby
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
          <div className="bc-obmark"><BCIcon name="mesh" size={38} weight={1.6} /></div>
          <h1 className="bc-obtitle">Chat with anyone nearby. Or anywhere.</h1>
          <p className="bc-obsub">bitchat connects phones directly — no phone number, no account, no servers.</p>
          <div className="bc-obrow">
            <span className="bc-obrowicon"><BCIcon name="mesh" size={20} /></span>
            <span>
              <div className="bc-obrowtitle">Works without internet</div>
              <div className="bc-obrowdesc">Bluetooth mesh reaches people around you, even offline.</div>
            </span>
          </div>
          <div className="bc-obrow">
            <span className="bc-obrowicon"><BCIcon name="globe" size={20} /></span>
            <span>
              <div className="bc-obrowtitle">Reaches anyone, anywhere</div>
              <div className="bc-obrowdesc">Open relays carry your messages across the internet.</div>
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
          <p className="bc-obsub">Nothing left behind — no account was created anywhere.</p>
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

/* ── Home ── */
function HomeScreen({ app, t, nav, push, toggleNetwork }) {
  const meshCount = BC_DATA.peers.length;
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Home">
      <div className="bc-header">
        <div className="bc-htitle">bitchat</div>
        <button className="bc-iconbtn" onClick={() => push('nearby')} aria-label="People nearby">
          <BCIcon name="people" size={21} />
        </button>
      </div>
      <StatusChip network={app.network} meshCount={meshCount} variant={t.chip} onToggle={toggleNetwork} />
      <div className="bc-scroll">
        <SectionLabel>Nearby channels</SectionLabel>
        <div className="bc-list">
          {BC_DATA.channels.map((ch) => (
            <ConvRow
              key={ch.id}
              av={<PlaceTile />}
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
                av={<Avatar name={peer.name} size={44} presence />}
                title={<span>{peer.name}</span>}
                extra={d.peer === 'maya' && app.verified
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
    </div>
  );
}

/* ── Location channel (public) ── */
function ChannelScreen({ app, nav, pop, push, chId, onSend, onCommand }) {
  const ch = BC_DATA.channels.find((c) => c.id === chId) || BC_DATA.channels[0];
  const msgs = app.chMsgs[ch.id] || [];
  const [sheet, setSheet] = React.useState(false);
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label={'Channel: ' + ch.name}>
      <NavHeader
        onBack={pop}
        trailing={
          <button className="bc-iconbtn" onClick={() => push('nearby')} aria-label="People nearby">
            <BCIcon name="people" size={20} />
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
        onSend={(tx) => onSend(ch.id, tx)}
        onPlus={() => setSheet(true)}
        onCommand={(c) => onCommand({ type: 'ch', id: ch.id, target: 'Luca' }, c)}
      />
      {sheet && (
        <Sheet onClose={() => setSheet(false)} title="Add to your message">
          <ActionRow icon="navArrow" label="Share location" desc="Drop a pin for people in this channel" onClick={() => setSheet(false)} />
          <ActionRow icon="people" label="People nearby" desc="See who can hear you on mesh" onClick={() => { setSheet(false); push('nearby'); }} />
          <ActionRow icon="smile" label="Reactions" desc="A little fun, no noise" onClick={() => setSheet(false)} />
        </Sheet>
      )}
    </div>
  );
}

/* ── Direct message (encrypted) ── */
function DMScreen({ app, nav, pop, push, peerId, onSend, onCommand, onVerify }) {
  const peer = BC_DATA.peers.find((p) => p.id === peerId) || BC_DATA.peers[0];
  const msgs = app.dmMsgs[peer.id] || [];
  const [sheet, setSheet] = React.useState(false);
  const [verify, setVerify] = React.useState(false);
  const [showKey, setShowKey] = React.useState(false);
  const verified = app.verified && peer.id === 'maya';
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label={'DM: ' + peer.name}>
      <NavHeader onBack={pop}>
        <Avatar name={peer.name} size={36} presence />
        <div style={{ minWidth: 0 }}>
          <div className="bc-hname">
            <span>{peer.name}</span>
            {verified
              ? <BCIcon name="shieldCheck" size={15} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
              : null}
          </div>
          <div className="bc-hsub">
            <BCIcon name="lock" size={11} weight={2.4} />
            {verified ? 'Verified · End-to-end encrypted' : 'End-to-end encrypted'}
          </div>
        </div>
      </NavHeader>
      {verified ? (
        <Banner icon="shieldCheck" tone="enc">
          <b>Verified</b> — you confirmed {peer.name}’s safety number
        </Banner>
      ) : (
        <Banner
          icon="lock" tone="enc"
          action={<button className="bc-bannerbtn" onClick={() => setVerify(true)}>Verify</button>}
        >
          <b>End-to-end encrypted</b> — only you and {peer.name} can read this
        </Banner>
      )}
      {msgs.length === 0 ? (
        <div className="bc-empty">
          <span className="bc-emptyicon"><BCIcon name="lock" size={24} /></span>
          <div className="bc-emptytitle">Say hi to {peer.name}</div>
          <div className="bc-emptydesc">Messages here are end-to-end encrypted. Only the two of you can read them.</div>
        </div>
      ) : (
        <MsgList msgs={msgs} showAuthors={false} />
      )}
      <Composer
        placeholder={'Message ' + peer.name}
        onSend={(tx) => onSend(peer.id, tx)}
        onPlus={() => setSheet(true)}
        onCommand={(c) => onCommand({ type: 'dm', id: peer.id, target: peer.name }, c)}
      />
      {sheet && (
        <Sheet onClose={() => setSheet(false)} title="Add to your message">
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
            <button className="bc-primary" onClick={() => { onVerify(); setVerify(false); setShowKey(false); }}>
              They match — mark as verified
            </button>
            <button className="bc-ghost" onClick={() => setShowKey(!showKey)}>
              {showKey ? 'Hide public key' : 'Show public key'}
            </button>
          </div>
        </Sheet>
      )}
    </div>
  );
}

/* ── People nearby (mesh) ── */
function NearbyScreen({ app, nav, pop, push }) {
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="People nearby">
      <NavHeader onBack={pop}>
        <div style={{ minWidth: 0 }}>
          <div className="bc-hname"><span>People nearby</span></div>
          <div className="bc-hsub"><span className="bc-dot g sm"></span>{BC_DATA.peers.length} reachable on mesh</div>
        </div>
      </NavHeader>
      <div className="bc-scroll">
        <p className="bc-meshnote" style={{ paddingTop: 10 }}>
          Messages hop phone-to-phone over Bluetooth — no internet needed.
        </p>
        <div className="bc-list">
          {BC_DATA.peers.map((p) => (
            <ConvRow
              key={p.id}
              av={<Avatar name={p.name} size={44} presence />}
              title={<span>{p.name}</span>}
              extra={p.id === 'maya' && app.verified
                ? <BCIcon name="shieldCheck" size={14} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
                : null}
              sub={
                <span className="bc-signal">
                  <Bars n={p.bars} />
                  {p.hint} · {p.detail}
                </span>
              }
              onClick={() => push('dm', { id: p.id })}
            />
          ))}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { Onboarding, HomeScreen, ChannelScreen, DMScreen, NearbyScreen });

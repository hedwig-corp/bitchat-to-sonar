// Sonar — screens: Onboarding, Home, Channel, DM, Sonar (radar), Settings
// Depends on: components.jsx exports + BC_DATA.

/* ── Onboarding (3 steps) ── */
function Onboarding({ initialNick, onDone, onRestore }) {
  const [step, setStep] = React.useState(0);
  const [nick, setNick] = React.useState(initialNick || '');
  const [restoring, setRestoring] = React.useState(false);
  const [nsec, setNsec] = React.useState('');
  const can = nick.trim().length >= 2;
  const nsecOk = /^nsec1[0-9a-z]{20,}$/.test(nsec.trim());
  const surprise = () => {
    const list = BC_DATA.nicknames;
    setNick(list[Math.floor(Math.random() * list.length)]);
  };
  return (
    <div className="bc-onboard" data-screen-label={restoring ? 'Onboarding restore' : 'Onboarding step ' + (step + 1)}>
      <div className="bc-obtop">
        {(step > 0 || restoring) && (
          <button className="bc-iconbtn" onClick={() => { if (restoring) setRestoring(false); else setStep(step - 1); }} aria-label="Back">
            <BCIcon name="back" size={21} weight={2.1} />
          </button>
        )}
      </div>

      {restoring && (
        <div className="bc-obbody" key="restore">
          <div className="bc-obmark"><BCIcon name="importKey" size={34} weight={1.7} /></div>
          <h1 className="bc-obtitle">Restore your account</h1>
          <p className="bc-obsub">Paste the <b>nsec</b> private key from your old device or another Nostr app. Your nickname, contacts and balance come back with it.</p>
          <textarea
            className="bc-nsecinput" value={nsec} rows={3}
            placeholder="nsec1…"
            spellCheck={false} autoCapitalize="none" autoCorrect="off"
            onChange={(e) => setNsec(e.target.value)}
          ></textarea>
          <button className="bc-suggest" onClick={() => setNsec(BC_DATA.nsec)}>
            <BCIcon name="copy" size={15} weight={2} />
            Paste from clipboard
          </button>
          <p className="bc-note">Sonar never sends this key anywhere — it’s decoded on this phone to unlock your identity.</p>
        </div>
      )}

      {!restoring && step === 0 && (
        <div className="bc-obbody" key="s0">
          <div className="bc-obmark brand"><img src="sonar/brand/sonar-icon.png" alt="Sonar" /></div>
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

      {!restoring && step === 1 && (
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

      {!restoring && step === 2 && (
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
        {!restoring && (
          <div className="bc-dots">
            <span className={step === 0 ? 'on' : ''}></span>
            <span className={step === 1 ? 'on' : ''}></span>
            <span className={step === 2 ? 'on' : ''}></span>
          </div>
        )}
        {restoring && (
          <button className="bc-primary" disabled={!nsecOk} onClick={() => onRestore(nsec.trim())}>Restore account</button>
        )}
        {!restoring && step === 0 && (
          <React.Fragment>
            <button className="bc-primary" onClick={() => setStep(1)}>Get started</button>
            <button className="bc-ghost" onClick={() => { setNsec(''); setRestoring(true); }}>I already have a key</button>
          </React.Fragment>
        )}
        {!restoring && step === 1 && <button className="bc-primary" disabled={!can} onClick={() => setStep(2)}>Continue</button>}
        {!restoring && step === 2 && <button className="bc-primary" onClick={() => onDone(nick.trim())}>Start chatting</button>}
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

/* ── Start-a-chat sheet (opened from the compose button) ── */
// Address resolution (NIP-05 style). Bare name → name@sonarprivacy.xyz (Sonar's home domain).
const SONAR_HOME = 'sonarprivacy.xyz';
function normalizeHandle(raw) {
  const v = raw.trim().toLowerCase().replace(/^@/, '');
  if (!v) return null;
  if (/^npub1[0-9a-z]{20,}$/.test(v)) return { kind: 'npub', npub: v };
  // bare username → home domain
  const full = v.includes('@') ? v : v + '@' + SONAR_HOME;
  const m = /^([a-z0-9_.-]{2,})@([a-z0-9.-]+\.[a-z]{2,})$/.exec(full);
  if (!m) return null;
  return { kind: 'address', name: m[1], domain: m[2], address: full, native: m[2] === SONAR_HOME };
}

function StartChatSheet({ onClose, onDM, onRadar, onNewGroup, onSecure }) {
  const [find, setFind] = React.useState(false);
  const [val, setVal] = React.useState('');
  const [state, setState] = React.useState('idle'); // idle · resolving · found · notfound
  const near = BC_DATA.peers.filter((p) => p.inRange).slice(0, 3);
  const parsed = normalizeHandle(val);
  const timer = React.useRef(null);

  const resolve = () => {
    if (!parsed) return;
    setState('resolving');
    clearTimeout(timer.current);
    // demo: known handles resolve; an obviously-fake one fails
    timer.current = setTimeout(() => {
      const bad = parsed.kind === 'address' && /^(unknown|nobody|test)$/.test(parsed.name);
      setState(bad ? 'notfound' : 'found');
    }, 850);
  };
  React.useEffect(() => () => clearTimeout(timer.current), []);

  const display = parsed
    ? (parsed.kind === 'npub' ? parsed.npub.slice(0, 12) + '…' : parsed.name)
    : '';
  const npubShort = 'npub1' + (parsed && parsed.name ? parsed.name : 'w4j8mc7') + '…q4k9dj';

  if (find) {
    return (
      <Sheet onClose={onClose} title="New discussion">
        <p className="bc-verifycopy" style={{ paddingTop: 2 }}>
          Type a Sonar username — just <b>vincenzo</b> for a @{SONAR_HOME} account, or a full address like <b>vincenzo@stacker.news</b> for another provider. You can also paste a raw npub.
        </p>
        <div className="addr-field">
          <BCIcon name="key" size={16} weight={2} style={{ color: 'var(--text3)', flex: 'none' }} />
          <input
            className="addr-input" value={val} placeholder="vincenzo"
            spellCheck={false} autoCapitalize="none" autoCorrect="off"
            onChange={(e) => { setVal(e.target.value); setState('idle'); }}
            onKeyDown={(e) => { if (e.key === 'Enter') resolve(); }}
          />
          {parsed && parsed.kind === 'address' && !val.includes('@') && (
            <span className="addr-suffix">@{SONAR_HOME}</span>
          )}
        </div>

        {state === 'resolving' && (
          <div className="addr-status"><span className="addr-spin"></span>Looking up {parsed ? parsed.address || 'key' : ''}…</div>
        )}
        {state === 'notfound' && (
          <div className="addr-status err"><BCIcon name="x" size={14} weight={2.4} />No Sonar user found at that address.</div>
        )}
        {state === 'found' && (
          <button className="addr-result" onClick={() => onSecure()}>
            <Avatar name={parsed.name || 'user'} size={46} />
            <span className="addr-resmain">
              <span className="addr-resname">
                {parsed.name || 'user'}
                {parsed.native ? <BCIcon name="shieldCheck" size={14} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} /> : null}
              </span>
              <span className="addr-resaddr">{parsed.kind === 'npub' ? parsed.npub.slice(0, 22) + '…' : parsed.address}</span>
              <span className="addr-resnpub">{npubShort}</span>
            </span>
            <span className="addr-go"><BCIcon name="chevron" size={16} weight={2.4} /></span>
          </button>
        )}

        <div className="bc-sheetactions">
          {state === 'found'
            ? <button className="bc-primary net" onClick={() => onSecure()}>Start encrypted chat</button>
            : <button className="bc-primary net" disabled={!parsed || state === 'resolving'} onClick={resolve}>Look up</button>}
          <button className="bc-ghost" onClick={() => { setFind(false); setState('idle'); }}>Back</button>
        </div>
      </Sheet>
    );
  }
  return (
    <Sheet onClose={onClose} title="Start a chat">
      {near.map((p) => (
        <button key={p.id} className="bc-actionrow" onClick={() => onDM(p.id)}>
          <Avatar name={p.name} size={44} presence />
          <span className="bc-actionmain">
            <span className="bc-actionlabel">{p.name}</span>
            <div className="bc-actiondesc"><span className="bc-signal" style={{ marginTop: 0 }}><Bars n={p.bars} />{p.hint} · {p.detail.split(' · ')[0]}</span></div>
          </span>
        </button>
      ))}
      <div style={{ height: 1, background: 'var(--hairline)', margin: '6px 12px' }}></div>
      <ActionRow icon="people" label="People nearby" desc="Open the radar to see everyone in range" onClick={onRadar} />
      <ActionRow icon="key" label="New discussion" desc={'Username, name@domain, or paste a key — reaches anywhere'} onClick={() => setFind(true)} />
      <ActionRow icon="plus" label="New group" desc="Invite contacts or paste keys" onClick={onNewGroup} />
    </Sheet>
  );
}

/* ── Home ── */
function HomeScreen({ app, t, nav, push, toggleNetwork, onWipe, onMute, onUnmute }) {
  const meshCount = BC_DATA.peers.filter((p) => p.inRange).length;
  const [wipeAsk, setWipeAsk] = React.useState(false);
  const [startChat, setStartChat] = React.useState(false);
  const [muteTarget, setMuteTarget] = React.useState(null); // { id, name }
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
        <div className="bc-htitle sn-wordmark" style={{ paddingLeft: 0 }} onClick={titleTap} title="Triple-tap to wipe">
          <img className="sn-brandchip lg" src="sonar/brand/sonar-icon.png" alt="" />
          sonar
        </div>
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
              muted={!!app.muted[ch.id]}
              onClick={() => push('channel', { id: ch.id })}
              onLongPress={() => setMuteTarget({ id: ch.id, name: ch.name })}
            />
          ))}
        </div>
        <SectionLabel>Messages</SectionLabel>
        <div className="bc-list">
          {(BC_DATA.groups || []).map((g) => {
            const gm = app.groupMsgs && app.groupMsgs[g.id];
            const last = gm && gm.length ? gm[gm.length - 1] : null;
            const preview = last
              ? (last.media ? (last.mine ? 'You' : last.author) + ': ' + bcMediaWord(last.media)
                 : (last.mine ? 'You: ' : (last.author ? last.author + ': ' : '') ) + (last.text || ''))
              : g.preview;
            return (
              <ConvRow
                key={g.id}
                av={<GroupAvatar members={g.members} size={52} />}
                title={<span>{g.name}</span>}
                sub={<><BCIcon name="people" size={12} weight={2.2} style={{ flex: 'none', color: 'var(--text3)' }} /><span>{preview}</span></>}
                time={g.time}
                unread={app.read['g-' + g.id] ? 0 : g.unread}
                muted={!!app.muted['g-' + g.id]}
                onClick={() => push('group', { id: g.id })}
                onLongPress={() => setMuteTarget({ id: 'g-' + g.id, name: g.name })}
              />
            );
          })}
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
                extra={<>{peer.supporter ? <SupporterBadge size={14} /> : null}{app.verified[d.peer]
                  ? <BCIcon name="shieldCheck" size={14} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
                  : null}</>}
                sub={<><BCIcon name="lock" size={12} weight={2.2} style={{ flex: 'none', color: 'var(--text3)' }} /><span>{preview}</span></>}
                time={d.time}
                unread={app.read[d.peer] ? 0 : d.unread}
                muted={!!app.muted[d.peer]}
                onClick={() => push('dm', { id: d.peer })}
                onLongPress={() => setMuteTarget({ id: d.peer, name: peer.name })}
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
        <button className="sn-compose" onClick={() => setStartChat(true)} aria-label="Start a chat">
          <BCIcon name="compose" size={22} weight={1.9} />
        </button>
      </div>
      {startChat && (
        <StartChatSheet
          onClose={() => setStartChat(false)}
          onDM={(id) => { setStartChat(false); push('dm', { id }); }}
          onRadar={() => { setStartChat(false); push('nearby'); }}
          onNewGroup={() => { setStartChat(false); push('newgroup'); }}
          onSecure={() => { setStartChat(false); push('dm', { id: 'sofia' }); }}
        />
      )}
      {muteTarget && (
        <MuteSheet
          name={muteTarget.name}
          isMuted={!!app.muted[muteTarget.id]}
          onMute={(dur) => onMute(muteTarget.id, dur)}
          onUnmute={() => onUnmute(muteTarget.id)}
          onClose={() => setMuteTarget(null)}
        />
      )}
      {wipeAsk && <WipeSheet onClose={() => setWipeAsk(false)} onWipe={onWipe} />}
    </div>
  );
}

/* ── Location channel (public) ── */
function ChannelScreen({ app, nav, pop, push, chId, onSend, onCommand, onMedia, onVoice }) {
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
        onVoice={(sec) => onVoice(ch.id, sec)}
        onSticker={(s) => onMedia(ch.id, s)}
        onCommand={(c) => onCommand({ type: 'ch', id: ch.id, target: 'Luca' }, c)}
      />
      {sheet && (
        <Sheet onClose={() => setSheet(false)} title="Add to your message">
          <AttachActions transport={transport} onPick={(t) => { setSheet(false); onMedia(ch.id, t); }} />
          <ActionRow icon="navArrow" label="Share location" desc="Drop a pin for people in this channel" onClick={() => setSheet(false)} />
          <ActionRow icon="people" label="People nearby" desc="See who can hear you over Bluetooth" onClick={() => { setSheet(false); push('nearby'); }} />
          <ActionRow icon="smile" label="Reactions" desc="A little fun, no noise" onClick={() => setSheet(false)} />
        </Sheet>
      )}
    </div>
  );
}

function GroupScreen({ app, nav, pop, push, groupId, onSend, onCommand, onMedia, onVoice, onNudge }) {
  const group = (BC_DATA.groups || []).find((g) => g.id === groupId) || BC_DATA.groups[0];
  const msgs = (app.groupMsgs && app.groupMsgs[group.id]) || [];
  const [sheet, setSheet] = React.useState(false);
  const { mem, transport, label } = groupReach(group);
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label={'Group: ' + group.name}>
      <NavHeader
        onBack={pop}
        trailing={
          <button className="bc-iconbtn" onClick={() => push('groupinfo', { id: group.id })} aria-label="Group info">
            <BCIcon name="info" size={20} />
          </button>
        }
      >
        <button className="bc-headtap" onClick={() => push('groupinfo', { id: group.id })}>
          <GroupAvatar members={group.members} size={36} />
          <div style={{ minWidth: 0 }}>
            <div className="bc-hname"><span>{group.name}</span></div>
            <div className="bc-hsub">{mem.length + 1} members · {label}</div>
          </div>
        </button>
      </NavHeader>
      <Banner icon="globe" tone="net">
        <b>Group · end-to-end encrypted</b> — over the internet with White Noise
      </Banner>
      {msgs.length === 0 ? (
        <div className="bc-empty">
          <span className="bc-emptyicon"><BCIcon name="people" size={24} /></span>
          <div className="bc-emptytitle">{group.name}</div>
          <div className="bc-emptydesc">Say hi to the group. Messages are end-to-end encrypted for all {mem.length + 1} members.</div>
        </div>
      ) : (
        <MsgList msgs={msgs} showAuthors />
      )}
      <Composer
        placeholder={'Message ' + group.name}
        transport={transport}
        onSend={(tx) => onSend(group.id, tx)}
        onPlus={() => setSheet(true)}
        onVoice={(sec) => onVoice(group.id, sec)}
        onSticker={(s) => onMedia(group.id, s)}
        onCommand={(c) => onCommand({ type: 'group', id: group.id, target: mem[0] ? mem[0].name : 'everyone' }, c)}
      />
      {sheet && (
        <Sheet onClose={() => setSheet(false)} title="Add to your message">
          <AttachActions transport={transport} onPick={(t) => { setSheet(false); onMedia(group.id, t); }} />
          <ActionRow icon="nudge" label="Nudge" desc="Buzz everyone to get their attention" onClick={() => { setSheet(false); onNudge && onNudge(group.id); }} />
          <ActionRow icon="navArrow" label="Share location" desc="Show the group where you are" onClick={() => setSheet(false)} />
          <ActionRow icon="smile" label="Reactions" desc="A little fun, no noise" onClick={() => setSheet(false)} />
        </Sheet>
      )}
    </div>
  );
}

/* ── Group info: members, invite links, add people, encryption, leave ── */

const SAMPLE_INVITE = 'sinvite1qyf8wctjv4s86q0denc6a5wqf3ehmgjrlvd3j8getnw3kxzumc…';

function InviteLinkSheet({ group, onClose }) {
  const [link, setLink] = React.useState(null);
  const [copied, setCopied] = React.useState(false);
  const [revoking, setRevoking] = React.useState(false);
  const gen = () => setLink(SAMPLE_INVITE);
  const copy = () => {
    try { navigator.clipboard && navigator.clipboard.writeText('sonar://invite/' + (link || SAMPLE_INVITE)); } catch (e) {}
    setCopied(true); setTimeout(() => setCopied(false), 1500);
  };
  const share = () => {
    try { navigator.share && navigator.share({ title: 'Join ' + group.name + ' on Sonar', text: 'sonar://invite/' + (link || SAMPLE_INVITE) }); } catch (e) {}
    copy();
  };
  const revoke = () => { setLink(null); setRevoking(false); };
  return (
    <Sheet onClose={onClose} title={'Invite to ' + group.name}>
      {!link ? (
        <React.Fragment>
          <p className="bc-verifycopy">Generate a link anyone can use to request to join this group. You'll approve each person before they're added.</p>
          <div className="inv-how">
            <div className="inv-step"><span className="inv-num">1</span><span>You share the link</span></div>
            <div className="inv-step"><span className="inv-num">2</span><span>They tap it and request to join</span></div>
            <div className="inv-step"><span className="inv-num">3</span><span>You approve — they're in</span></div>
          </div>
          <div className="bc-sheetactions">
            <button className="bc-primary" onClick={gen}>Generate invite link</button>
          </div>
        </React.Fragment>
      ) : revoking ? (
        <React.Fragment>
          <p className="bc-verifycopy">Revoke this link? Anyone who already has it won't be able to join. You can always create a new one.</p>
          <div className="bc-sheetactions">
            <button className="bc-primary danger" onClick={revoke}>Revoke link</button>
            <button className="bc-ghost" onClick={() => setRevoking(false)}>Keep it active</button>
          </div>
        </React.Fragment>
      ) : (
        <React.Fragment>
          <div className="inv-card">
            <div className="inv-qr"><ShareCode seed={link} size={140} /></div>
            <div className="inv-token">
              <span className="inv-tokenlabel">Invite link</span>
              <span className="inv-tokenval">sonar://invite/{link.slice(0, 24)}…</span>
            </div>
          </div>
          <div className="inv-btns">
            <button className={'inv-btn primary' + (copied ? ' done' : '')} onClick={copy}>
              <BCIcon name={copied ? 'check' : 'copy'} size={17} weight={2.2} />{copied ? 'Copied' : 'Copy link'}
            </button>
            <button className="inv-btn" onClick={share}>
              <BCIcon name="share" size={17} weight={2} />Share
            </button>
          </div>
          <p className="inv-note">Only you can approve join requests from this link. If you revoke it, pending requests are declined automatically.</p>
          <button className="bc-ghost" style={{ color: 'var(--danger)' }} onClick={() => setRevoking(true)}>Revoke this link</button>
        </React.Fragment>
      )}
    </Sheet>
  );
}

const SAMPLE_REQUESTS = [
  { id: 'req1', name: 'driftwood', npub: 'npub1dr1ft…a4k9', time: '2 min ago' },
  { id: 'req2', name: 'wavepool', npub: 'npub1wav3p…m2hd', time: '14 min ago' },
];

function PendingRequestsSheet({ group, onClose, onApprove, onDecline }) {
  const [reqs, setReqs] = React.useState(SAMPLE_REQUESTS);
  const approve = (r) => { setReqs((rs) => rs.filter((x) => x.id !== r.id)); onApprove && onApprove(r); };
  const decline = (r) => { setReqs((rs) => rs.filter((x) => x.id !== r.id)); onDecline && onDecline(r); };
  return (
    <Sheet onClose={onClose} title={'Join requests · ' + group.name}>
      {reqs.length === 0 ? (
        <div className="bc-empty" style={{ padding: '30px 20px' }}>
          <span className="bc-emptyicon"><BCIcon name="check" size={24} /></span>
          <div className="bc-emptytitle">All clear</div>
          <div className="bc-emptydesc">No pending join requests right now.</div>
        </div>
      ) : (
        <React.Fragment>
          <p className="bc-verifycopy" style={{ paddingTop: 0 }}>These people tapped your invite link and want to join. Approve to add them to the group's encrypted session.</p>
          {reqs.map((r) => (
            <div key={r.id} className="inv-req">
              <Avatar name={r.name} size={44} />
              <span className="inv-reqmain">
                <span className="inv-reqname">{r.name}</span>
                <span className="inv-reqsub">{r.time} · <span style={{ fontFamily: 'var(--mono)', fontSize: 11 }}>{r.npub}</span></span>
              </span>
              <button className="pf-smallbtn primary" onClick={() => approve(r)}>Approve</button>
              <button className="pf-smallbtn" onClick={() => decline(r)}>Decline</button>
            </div>
          ))}
        </React.Fragment>
      )}
    </Sheet>
  );
}

function JoinViaLinkSheet({ onClose, onJoin }) {
  const [step, setStep] = React.useState('confirm');
  const [sent, setSent] = React.useState(false);
  const doJoin = () => { setSent(true); setStep('waiting'); onJoin && onJoin(); };
  return (
    <Sheet onClose={onClose} title="Join group">
      {step === 'confirm' ? (
        <React.Fragment>
          <div className="inv-joinhead">
            <GroupAvatar members={['driftwood', 'wavepool']} size={72} />
            <div className="inv-joinname">Lake crew</div>
            <span className="inv-joinsub">4 members · encrypted with White Noise</span>
          </div>
          <p className="bc-verifycopy">You were invited to join this group. Tapping "Request to join" sends your request to the admin — they'll approve you before you're added.</p>
          <div className="bc-sheetactions">
            <button className="bc-primary net" onClick={doJoin}>Request to join</button>
            <button className="bc-ghost" onClick={onClose}>Cancel</button>
          </div>
        </React.Fragment>
      ) : (
        <React.Fragment>
          <div className="inv-joinhead">
            <span className="bc-emptyicon" style={{ marginBottom: 0 }}><BCIcon name="check" size={26} /></span>
            <div className="inv-joinname">Request sent</div>
            <span className="inv-joinsub">The admin will review your request. You'll be notified when you're approved.</span>
          </div>
          <div className="bc-sheetactions">
            <button className="bc-ghost" onClick={onClose}>Done</button>
          </div>
        </React.Fragment>
      )}
    </Sheet>
  );
}

function GroupInfoScreen({ app, nav, pop, push, groupId, onLeave }) {
  const group = (BC_DATA.groups || []).find((g) => g.id === groupId) || BC_DATA.groups[0];
  const { mem, label } = groupReach(group);
  const [inviteSheet, setInviteSheet] = React.useState(false);
  const [reqSheet, setReqSheet] = React.useState(false);
  const pendingCount = SAMPLE_REQUESTS.length;
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label={'Group info: ' + group.name}>
      <NavHeader onBack={pop} hairline={false}>
        <div className="bc-hname"><span>Group info</span></div>
      </NavHeader>
      <div className="bc-scroll">
        <div className="pf-head">
          <GroupAvatar members={group.members} size={92} />
          <div className="pf-name">{group.name}</div>
          <span className="pf-key" style={{ fontFamily: 'inherit' }}>{mem.length + 1} members · {label}</span>
        </div>
        <Banner icon="globe" tone="net">
          <b>End-to-end encrypted</b> — group messages travel over the internet, secured by White Noise
        </Banner>

        <SectionLabel>Invite</SectionLabel>
        <div className="bc-list">
          <button className="bc-row" onClick={() => setInviteSheet(true)}>
            <span className="bc-actionicon"><BCIcon name="link" size={19} /></span>
            <span className="bc-rowmain">
              <span className="bc-rowtitle">Invite link</span>
              <span className="bc-rowsub"><span>Share a link · you approve who joins</span></span>
            </span>
            <BCIcon name="chevron" size={14} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
          </button>
          <button className="bc-row" onClick={() => setReqSheet(true)}>
            <span className="bc-actionicon" style={{ background: pendingCount ? 'var(--accent-soft)' : undefined, color: pendingCount ? 'var(--accent-deep)' : undefined }}>
              <BCIcon name="people" size={18} />
            </span>
            <span className="bc-rowmain">
              <span className="bc-rowtitle">Join requests</span>
              <span className="bc-rowsub"><span>{pendingCount ? pendingCount + ' pending' : 'None right now'}</span></span>
            </span>
            {pendingCount ? <span className="bc-unread" style={{ minWidth: 22 }}>{pendingCount}</span> : null}
          </button>
        </div>

        <SectionLabel>{mem.length + 1} members</SectionLabel>
        <div className="bc-list">
          <ConvRow
            av={<Avatar name={app.nick || 'you'} size={44} />}
            title={<span>You</span>}
            sub={<span>Admin</span>}
            onClick={() => {}}
          />
          {mem.map((p) => (
            <ConvRow
              key={p.id}
              av={<Avatar name={p.name} size={44} presence={p.inRange} />}
              title={<span>{p.name}</span>}
              extra={<>{p.supporter ? <SupporterBadge size={14} /> : null}{app.verified[p.id]
                ? <BCIcon name="shieldCheck" size={14} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
                : null}</>}
              sub={<span className="bc-signal">{p.inRange ? <><Bars n={p.bars} />{p.hint}</> : <><BCIcon name="globe" size={12} weight={2.2} style={{ color: 'var(--net)', flex: 'none' }} />Out of range · internet</>}</span>}
              onClick={() => push('dm', { id: p.id })}
            />
          ))}
        </div>
        <div className="bc-list" style={{ marginTop: 10 }}>
          <button className="bc-row" onClick={() => push('nearby')}>
            <span className="bc-actionicon"><BCIcon name="plus" size={19} /></span>
            <span className="bc-rowmain"><span className="bc-rowtitle" style={{ color: 'var(--accent-deep)' }}>Add people</span></span>
          </button>
          <button className="bc-row" onClick={() => { onLeave(group.id); }}>
            <span className="bc-actionicon" style={{ background: 'rgba(212,58,62,0.12)', color: 'var(--danger)' }}><BCIcon name="back" size={18} /></span>
            <span className="bc-rowmain"><span className="bc-rowtitle" style={{ color: 'var(--danger)' }}>Leave group</span></span>
          </button>
        </div>
      </div>
      {inviteSheet && <InviteLinkSheet group={group} onClose={() => setInviteSheet(false)} />}
      {reqSheet && <PendingRequestsSheet group={group} onClose={() => setReqSheet(false)} />}
    </div>
  );
}

/* ── New group: pick members + name ── */
function NewGroupScreen({ app, nav, pop, onCreate }) {
  const [picked, setPicked] = React.useState([]);
  const [name, setName] = React.useState('');
  const toggle = (id) => setPicked((p) => p.includes(id) ? p.filter((x) => x !== id) : [...p, id]);
  const can = name.trim().length >= 2 && picked.length >= 1;
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="New group">
      <NavHeader onBack={pop} hairline={false}>
        <div className="bc-hname"><span>New group</span></div>
      </NavHeader>
      <div className="bc-scroll" style={{ paddingBottom: 110 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '8px 18px 6px' }}>
          <span className="bc-placetile" style={{ width: 56, height: 56 }}><BCIcon name="people" size={26} /></span>
          <input
            className="bc-nickinput" style={{ fontSize: 18, padding: '12px 14px', flex: 1 }}
            type="text" value={name} maxLength={28} placeholder="Group name"
            onChange={(e) => setName(e.target.value)}
          />
        </div>
        {picked.length > 0 && (
          <div className="ng-chiprow">
            {picked.map((id) => {
              const p = BC_DATA.peers.find((x) => x.id === id);
              return (
                <button key={id} className="ng-chip" onClick={() => toggle(id)}>
                  <Avatar name={p.name} size={22} />{p.name}
                  <BCIcon name="x" size={12} weight={2.4} />
                </button>
              );
            })}
          </div>
        )}
        <SectionLabel>Add members</SectionLabel>
        <div className="bc-list">
          {BC_DATA.peers.map((p) => {
            const on = picked.includes(p.id);
            return (
              <button key={p.id} className="bc-row" onClick={() => toggle(p.id)}>
                <Avatar name={p.name} size={44} presence={p.inRange} />
                <span className="bc-rowmain">
                  <span className="bc-rowtitle">{p.name}</span>
                  <span className="bc-rowsub"><span>{p.inRange ? 'Nearby · Bluetooth' : 'Out of range · internet'}</span></span>
                </span>
                <span className={'ng-check' + (on ? ' on' : '')}>
                  {on ? <BCIcon name="check" size={14} weight={2.6} /> : null}
                </span>
              </button>
            );
          })}
        </div>
      </div>
      <div className="sn-fab" style={{ justifyContent: 'flex-end' }}>
        <button className="bc-primary" style={{ width: 'auto', padding: '15px 26px', whiteSpace: 'nowrap', opacity: can ? 1 : 0.4 }} disabled={!can} onClick={() => onCreate(name.trim(), picked)}>
          Create group
        </button>
      </div>
    </div>
  );
}

/* ── Group transport helper — groups run over the internet, secured by White Noise ── */
function groupReach(group) {
  const mem = (group.members || []).map((id) => BC_DATA.peers.find((p) => p.id === id)).filter(Boolean);
  return { mem, transport: 'internet', label: 'White Noise · internet' };
}

/* ── Contact profile: discovery-derived identity, capabilities & safety ── */
const CAP_INFO = {
  'marmot-dm': { icon: 'lock', label: 'Encrypted messages', desc: 'End-to-end encrypted DMs (Marmot)' },
  'calls': { icon: 'phone', label: 'Voice & video calls', desc: 'Can take encrypted calls' },
  'payments': { icon: 'coin', label: 'Bitcoin payments', desc: 'Accepts bitcoin' },
};

function PeerProfileScreen({ app, nav, pop, push, peerId, onVerify }) {
  const peer = BC_DATA.peers.find((p) => p.id === peerId) || BC_DATA.peers[0];
  const [verify, setVerify] = React.useState(false);
  const [showKey, setShowKey] = React.useState(false);
  const [tech, setTech] = React.useState(false);
  const [copied, setCopied] = React.useState('');
  const verified = !!app.verified[peer.id];
  const caps = peer.caps || ['marmot-dm'];
  const canCall = caps.includes('calls');
  const canPay = caps.includes('payments');
  const npub = peer.npub || BC_DATA.pubkey;
  const pubkeyUI = !!(app.prefs && app.prefs.pubkeyUI);
  const shortNpub = npub.slice(0, 16) + '…' + npub.slice(-8);
  const copy = (text, tag) => {
    try { navigator.clipboard && navigator.clipboard.writeText(text); } catch (e) { /* ignore */ }
    setCopied(tag); clearTimeout(window.__bcCopyT2); window.__bcCopyT2 = setTimeout(() => setCopied(''), 1500);
  };
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label={'Contact: ' + peer.name}>
      <NavHeader onBack={pop} hairline={false}>
        <div className="bc-hname"><span>Contact</span></div>
      </NavHeader>
      <div className="bc-scroll">
        <div className="pf-head">
          <Avatar name={peer.name} size={96} presence={peer.inRange} />
          <div className="pf-name">
            {peer.name}
            {peer.supporter ? <SupporterBadge size={17} /> : null}
            {verified ? <BCIcon name="shieldCheck" size={18} weight={2.1} style={{ color: 'var(--green)' }} /> : null}
          </div>
          <span className={'cp-discover' + (peer.inRange ? ' near' : ' far')}>
            <BCIcon name={peer.inRange ? 'mesh' : 'globe'} size={13} weight={2.2} />
            {peer.inRange ? 'Nearby · found over Bluetooth' : 'Reached over the internet'}
          </span>
        </div>

        {/* quick actions */}
        <div className="cp-actions">
          <button className="cp-action" onClick={() => push('dm', { id: peer.id })}>
            <span className="cp-actionic"><BCIcon name="compose" size={20} /></span>Message
          </button>
          <button className={'cp-action' + (canCall ? '' : ' off')} disabled={!canCall} onClick={() => canCall && push('call', { id: peer.id, kind: 'voice' })}>
            <span className="cp-actionic"><BCIcon name="phone" size={19} /></span>Call
          </button>
          <button className={'cp-action' + (canCall ? '' : ' off')} disabled={!canCall} onClick={() => canCall && push('call', { id: peer.id, kind: 'video' })}>
            <span className="cp-actionic"><BCIcon name="videocam" size={20} /></span>Video
          </button>
          <button className={'cp-action' + (canPay ? '' : ' off')} disabled={!canPay} onClick={() => canPay && push('dm', { id: peer.id, pay: 1 })}>
            <span className="cp-actionic"><BCIcon name="coin" size={19} /></span>Pay
          </button>
        </div>

        {/* safety */}
        {verified ? (
          <Banner icon="shieldCheck" tone="enc"><b>Verified</b> — you confirmed {peer.name}’s safety number</Banner>
        ) : (
          <Banner icon="lock" tone={peer.inRange ? 'enc' : 'net'} action={<button className="bc-bannerbtn" onClick={() => setVerify(true)}>Verify</button>}>
            {peer.inRange
              ? <span><b>Identity bound on mesh</b> — verify the safety number to confirm</span>
              : <span><b>Encrypted</b> — verify {peer.name}’s safety number in person</span>}
          </Banner>
        )}

        <SectionLabel>What you can do together</SectionLabel>
        <div className="bc-list">
          {['marmot-dm', 'calls', 'payments'].map((c) => {
            const on = caps.includes(c);
            const info = CAP_INFO[c];
            return (
              <div key={c} className={'cp-cap' + (on ? '' : ' off')}>
                <span className="cp-capic"><BCIcon name={info.icon} size={18} /></span>
                <span className="cp-capmain">
                  <span className="cp-caplabel">{info.label}</span>
                  <span className="cp-capdesc">{c === 'payments' && on && peer.bip353 ? peer.bip353 : info.desc}</span>
                </span>
                {on
                  ? <BCIcon name="check" size={16} weight={2.6} style={{ color: 'var(--green)', flex: 'none' }} />
                  : <span className="cp-capno">unavailable</span>}
              </div>
            );
          })}
        </div>
        {!canCall ? <p className="st-note">{peer.name} hasn’t published call support — you can still message and they’ll get it over White Noise.</p> : null}

        {canPay && peer.bip353 ? (
          <React.Fragment>
            <SectionLabel>Payment address</SectionLabel>
            <button className="cp-copyrow" onClick={() => copy(peer.bip353, 'bip')}>
              <span className="cp-copyic"><BCIcon name="coin" size={17} /></span>
              <span className="cp-copyval">{peer.bip353}</span>
              <span className="cp-copybtn">{copied === 'bip' ? 'Copied' : 'Copy'}</span>
            </button>
          </React.Fragment>
        ) : null}

        <SectionLabel>Identity</SectionLabel>
        <div className="bc-list">
          <button className="bc-row cp-keyrow" onClick={() => setShowKey(!showKey)}>
            <span className="bc-actionicon"><BCIcon name="key" size={18} /></span>
            <span className="bc-rowmain">
              <span className="bc-rowtitle">Public key</span>
              <span className="bc-rowsub"><span style={{ fontFamily: 'var(--mono)', fontSize: 12, wordBreak: 'break-all' }}>{showKey || pubkeyUI ? (showKey ? npub : shortNpub) : 'Tap to reveal'}</span></span>
            </span>
            <span className="cp-copybtn" onClick={(e) => { e.stopPropagation(); copy(npub, 'npub'); }}>{copied === 'npub' ? 'Copied' : 'Copy'}</span>
          </button>
          <button className="bc-row" onClick={() => setVerify(true)}>
            <span className="bc-actionicon"><BCIcon name="shield" size={18} /></span>
            <span className="bc-rowmain">
              <span className="bc-rowtitle">Safety number</span>
              <span className="bc-rowsub"><span>{verified ? 'Verified' : 'Tap to verify in person'}</span></span>
            </span>
            {verified ? <BCIcon name="shieldCheck" size={16} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} /> : <BCIcon name="chevron" size={14} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />}
          </button>
        </div>

        <SectionLabel>Met</SectionLabel>
        <p className="st-note" style={{ marginTop: 0 }}>{peer.met || 'on the mesh'}.</p>

        {/* technical descriptor, on demand */}
        <button className="cp-techtoggle" onClick={() => setTech(!tech)}>
          <BCIcon name="info" size={15} weight={2} />
          {tech ? 'Hide technical details' : 'Show technical details'}
          <BCIcon name="chevron" size={13} weight={2.2} style={{ transform: tech ? 'rotate(90deg)' : 'none', transition: 'transform 0.18s', marginLeft: 'auto' }} />
        </button>
        {tech && (
          <div className="cp-tech">
            <div><span>discovered via</span>{peer.inRange ? 'BLE 0x53 · v1 (signed)' : 'Nostr descriptor'}</div>
            <div><span>descriptor</span>kind:30078 · d=sonar.call.v1</div>
            <div><span>capabilities</span>{caps.join(', ')}</div>
            <div><span>media</span>{(peer.media && peer.media.length) ? peer.media.join(', ') : '—'}</div>
            <div><span>signaling</span>marmot</div>
            <div><span>transport</span>iroh</div>
            <div className="muted"><span>npub</span>{npub}</div>
          </div>
        )}
        <p className="cp-technote">Discovery shares only what {peer.name} chose to publish — never their private key, live addresses, or presence.</p>
        <div style={{ height: 20 }}></div>
      </div>

      {verify && (
        <Sheet onClose={() => { setVerify(false); }} title={'Verify ' + peer.name}>
          <div className="bc-verifyheads">
            <span className="bc-verifyhead"><Avatar name={app.nick || 'you'} size={48} />you</span>
            <span className="bc-verifyhead"><Avatar name={peer.name} size={48} />{peer.name}</span>
          </div>
          <p className="bc-verifycopy">
            Compare these numbers with {peer.name} in person or on a call. If they match, this chat is end-to-end encrypted and nobody is in the middle.
          </p>
          <div className="bc-safety">
            {[0, 4, 8].map((row) => (
              <div key={row}>{BC_DATA.safety.slice(row, row + 4).join('\u2002')}</div>
            ))}
          </div>
          <div className="bc-sheetactions">
            <button className="bc-primary" onClick={() => { onVerify(peer.id); setVerify(false); }}>They match — mark as verified</button>
          </div>
        </Sheet>
      )}
    </div>
  );
}

/* ── Direct message (encrypted, transport-aware) ── */
function DMScreen({ app, nav, pop, push, peerId, onSend, onCommand, onVerify, onPay, onClaimPay, openPay, onMedia, onVoice, onMute, onUnmute, onNudge }) {
  const peer = BC_DATA.peers.find((p) => p.id === peerId) || BC_DATA.peers[0];
  const msgs = app.dmMsgs[peer.id] || [];
  const [sheet, setSheet] = React.useState(false);
  const [verify, setVerify] = React.useState(false);
  const [showKey, setShowKey] = React.useState(false);
  const [pay, setPay] = React.useState(!!openPay);
  const [payDetail, setPayDetail] = React.useState(null);
  const verified = !!app.verified[peer.id];
  const isMuted = !!app.muted[peer.id];
  const transport = peer.inRange ? 'mesh' : 'internet';
  const btc = !!(app.prefs && app.prefs.btcMode);
  const pp = payPrefs(app);
  const offlineFar = !peer.inRange && app.network !== 'online';
  const sub = verified ? 'Verified · ' : '';
  const subTransport = peer.inRange
    ? 'Nearby · Bluetooth'
    : (offlineFar ? 'Offline — will send later' : 'Via internet');
  return (
    <div className="bc-screen" data-nav={nav} data-screen-label={'DM: ' + peer.name}>
      <NavHeader
        onBack={pop}
        trailing={
          <React.Fragment>
            <button className="bc-iconbtn" onClick={() => isMuted ? onUnmute(peer.id) : onMute(peer.id, 'forever')} aria-label={isMuted ? 'Unmute' : 'Mute'} title={isMuted ? 'Unmute' : 'Mute'}>
              <BCIcon name={isMuted ? 'bellOff' : 'bell'} size={19} />
            </button>
            <button className="bc-iconbtn" onClick={() => push('call', { id: peer.id, kind: 'voice' })} aria-label="Voice call">
              <BCIcon name="phone" size={20} />
            </button>
            <button className="bc-iconbtn" onClick={() => push('call', { id: peer.id, kind: 'video' })} aria-label="Video call">
              <BCIcon name="videocam" size={21} />
            </button>
          </React.Fragment>
        }
      >
        <button className="bc-headtap" onClick={() => push('peer', { id: peer.id })}>
          <Avatar name={peer.name} size={36} presence={peer.inRange} />
          <div style={{ minWidth: 0 }}>
            <div className="bc-hname">
              <span>{peer.name}</span>
              {peer.supporter ? <SupporterBadge size={15} /> : null}
              {verified
                ? <BCIcon name="shieldCheck" size={15} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
                : null}
            </div>
            <div className="bc-hsub">
              <BCIcon name="lock" size={11} weight={2.4} />
              {sub}{subTransport}
            </div>
          </div>
        </button>
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
        <MsgList msgs={msgs} showAuthors={false} peerName={peer.name} onClaim={(i) => setPayDetail(msgs[i])} pay={pp} />
      )}
      <Composer
        placeholder={'Message ' + peer.name + (peer.inRange ? '' : ' · via internet')}
        transport={transport}
        onSend={(tx) => onSend(peer.id, tx)}
        onPlus={() => setSheet(true)}
        onVoice={(sec) => onVoice(peer.id, sec)}
        onSticker={(s) => onMedia(peer.id, s)}
        onCommand={(c) => onCommand({ type: 'dm', id: peer.id, target: peer.name }, c)}
      />
      {sheet && (
        <Sheet onClose={() => setSheet(false)} title="Add to your message">
          <AttachActions transport={transport} onPick={(t) => { setSheet(false); onMedia(peer.id, t); }} />
          <ActionRow icon="coin" label={btc ? 'Send bitcoin' : 'Send money'} desc={btc ? (peer.inRange ? 'Travels over Bluetooth as ecash' : 'Instant over Lightning') : (peer.inRange ? 'Privately, phone-to-phone over Bluetooth' : 'Privately over the internet')} onClick={() => { setSheet(false); setPay(true); }} />
          <ActionRow icon="navArrow" label="Share location" desc={'Only ' + peer.name + ' will see it'} onClick={() => setSheet(false)} />
          <ActionRow icon="nudge" label="Nudge" desc={'Buzz ' + peer.name + '\u2019s screen to get their attention'} onClick={() => { setSheet(false); onNudge && onNudge(peer.id); }} />
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
          peer={peer} balance={app.balance || 0} transport={transport} pay={pp}
          onClose={() => setPay(false)} onSend={(sats) => onPay(sats)}
        />
      )}
      {payDetail && (
        <PayDetailSheet m={payDetail} peerName={peer.name} pay={pp} onClose={() => setPayDetail(null)} />
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

Object.assign(window, { Onboarding, HomeScreen, ChannelScreen, GroupScreen, GroupInfoScreen, NewGroupScreen, StartChatSheet, PeerProfileScreen, InviteLinkSheet, PendingRequestsSheet, JoinViaLinkSheet, DMScreen, SonarScreen, SettingsScreen, WipeSheet });

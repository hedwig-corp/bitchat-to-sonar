// Sonar Desktop — sidebar, chat pane, radar pane, detail rail, settings modal
// Depends on: icons.jsx, components.jsx, settings.jsx (StRow/StSwitch/ShareCode), BC_DATA.

/* ── "Around you": same collapsed precision ladder as mobile, sidebar-tuned ── */
function DkHereRow({ sel, onSelect }) {
  const ladder = BC_DATA.here || [];
  const def = (() => {
    for (let i = 0; i < ladder.length; i++) if (ladder[i].count > 0) return i;
    return Math.max(0, ladder.length - 1);
  })();
  const [idx, setIdx] = React.useState(def);
  const lv = ladder[idx];
  if (!lv) return null;
  const active = sel.type === 'channel' && ladder.some((l) => l.id === sel.id);
  return (
    <div className={'here-card' + (active ? ' sel' : '')}>
      <button className="here-main" onClick={() => onSelect('channel', lv.id)}>
        <PlaceTile size={40} />
        <span className="here-text">
          <span className="here-name">{lv.name}</span>
          <span className="here-sub">{lv.tier} · {lv.count} here now</span>
        </span>
        <BCIcon name="chevron" size={14} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
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

/* ── Sidebar ── */
function DkSidebar({ app, sel, onSelect, toggleNetwork, onSettings }) {
  const meshCount = BC_DATA.peers.filter((p) => p.inRange).length;
  const shortKey = BC_DATA.pubkey.slice(0, 12) + '\u2026';
  const isSel = (type, id) => sel.type === type && sel.id === id;
  return (
    <div className="dk-side">
      <div className="dk-titlebar">
        <MacTrafficLights />
        <button className="dk-iconbtn" onClick={() => onSelect('radar')} title="New chat — discover people nearby">
          <BCIcon name="compose" size={17} />
        </button>
      </div>
      <div className="dk-brand">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8">
          <circle cx="12" cy="12" r="2" fill="currentColor" stroke="none"></circle>
          <circle cx="12" cy="12" r="5.8"></circle>
          <circle cx="12" cy="12" r="9.4"></circle>
        </svg>
        sonar
      </div>
      <StatusChip network={app.network} meshCount={meshCount} variant="banner" onToggle={toggleNetwork} />
      <div className="dk-search">
        <BCIcon name="search" size={14} weight={2.2} />
        Search
        <span className="kbd">⌘K</span>
      </div>
      <div className="dk-list">
        <button className={'dk-discover' + (sel.type === 'radar' ? ' sel' : '')} onClick={() => onSelect('radar')}>
          <span className="tile"><BCIcon name="rings" size={18} /></span>
          <span className="dk-rowmain">
            <span className="dk-rowtitle">Sonar</span>
            <span className="dk-rowsub">{meshCount} people in range</span>
          </span>
        </button>
        <SectionLabel>Around you</SectionLabel>
        <DkHereRow sel={sel} onSelect={onSelect} />
        <button className="dk-morebtn" onClick={() => onSelect('radar')}>
          <BCIcon name="pin" size={15} weight={2} />
          More places nearby
        </button>
        <SectionLabel>Saved channels</SectionLabel>
        {BC_DATA.channels.map((ch) => (
          <button key={ch.id} className={'dk-row' + (isSel('channel', ch.id) ? ' sel' : '')} onClick={() => onSelect('channel', ch.id)}>
            <PlaceTile size={40} />
            <span className="dk-rowmain">
              <span className="dk-rowtitle">{ch.name}</span>
              <span className="dk-rowsub">{ch.preview}</span>
            </span>
            <span className="dk-rowend">
              {ch.time ? <span className="dk-time">{ch.time}</span> : null}
              {!app.read[ch.id] && ch.unread ? <span className="bc-unreaddot"></span> : null}
            </span>
          </button>
        ))}
        <SectionLabel>Messages</SectionLabel>
        {BC_DATA.homeDMs.map((d) => {
          const peer = BC_DATA.peers.find((p) => p.id === d.peer);
          const msgs = app.dmMsgs[d.peer];
          const last = msgs && msgs.length ? msgs[msgs.length - 1] : null;
          const preview = last && !last.action ? last.text : d.preview;
          return (
            <button key={d.peer} className={'dk-row' + (isSel('dm', d.peer) ? ' sel' : '')} onClick={() => onSelect('dm', d.peer)}>
              <Avatar name={peer.name} size={40} presence={peer.inRange} />
              <span className="dk-rowmain">
                <span className="dk-rowtitle">
                  {peer.name}
                  {app.verified[d.peer]
                    ? <BCIcon name="shieldCheck" size={13} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} />
                    : null}
                </span>
                <span className="dk-rowsub">
                  <BCIcon name="lock" size={11} weight={2.2} style={{ flex: 'none', color: 'var(--text3)' }} />
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{preview}</span>
                </span>
              </span>
              <span className="dk-rowend">
                <span className="dk-time">{d.time}</span>
                {!app.read[d.peer] && d.unread ? <span className="bc-unreaddot"></span> : null}
              </span>
            </button>
          );
        })}
      </div>
      <div className="dk-me">
        <Avatar name={app.nick || 'you'} size={36} />
        <span className="dk-memain">
          <div className="dk-mename">{app.nick || 'you'}</div>
          <div className="dk-mekey">{shortKey}</div>
        </span>
        <button className="dk-iconbtn" onClick={onSettings} title="Settings">
          <BCIcon name="list" size={17} />
        </button>
      </div>
    </div>
  );
}

/* ── Chat pane (channel or DM) ── */
function DkChatPane({ app, sel, railOpen, onToggleRail, onSendCh, onSendDm, onCommand, onSelect, onPay, onClaimPay, openPay, onMedia, onVoice, onCall }) {
  const [pop, setPop] = React.useState(false);
  const [pay, setPay] = React.useState(false);
  React.useEffect(() => { setPay(!!openPay); }, [openPay, sel.id]);
  const isCh = sel.type === 'channel';
  const ch = isCh ? (BC_DATA.channels.find((c) => c.id === sel.id) || (BC_DATA.here || []).find((c) => c.id === sel.id) || BC_DATA.channels[0]) : null;
  const peer = !isCh ? (BC_DATA.peers.find((p) => p.id === sel.id) || BC_DATA.peers[0]) : null;
  const msgs = isCh ? (app.chMsgs[ch.id] || []) : (app.dmMsgs[peer.id] || []);
  const verified = !isCh && !!app.verified[peer.id];
  const transport = isCh
    ? (app.network === 'online' ? 'internet' : 'mesh')
    : (peer.inRange ? 'mesh' : 'internet');
  const sub = isCh
    ? ch.sub
    : (verified ? 'Verified · ' : '') + (peer.inRange
        ? 'Nearby · Bluetooth'
        : (app.network === 'online' ? 'Via internet' : 'Offline — will send later'));
  const btc = !!(app.prefs && app.prefs.btcMode);
  const pp = payPrefs(app);
  return (
    <div className="dk-main" data-screen-label={isCh ? 'Channel: ' + ch.name : 'DM: ' + peer.name}>
      <div className="dk-chathead">
        {isCh ? <PlaceTile size={38} /> : <Avatar name={peer.name} size={38} presence={peer.inRange} />}
        <span className="titles">
          <div className="bc-hname">
            <span>{isCh ? ch.name : peer.name}</span>
            {verified ? <BCIcon name="shieldCheck" size={15} weight={2.1} style={{ color: 'var(--green)', flex: 'none' }} /> : null}
          </div>
          <div className="bc-hsub">
            {isCh ? <span className="bc-dot g sm"></span> : <BCIcon name="lock" size={11} weight={2.4} />}
            {sub}
          </div>
        </span>
        <button className="dk-iconbtn" onClick={() => onSelect('radar')} title="People nearby">
          <BCIcon name="rings" size={18} />
        </button>
        {!isCh && (
          <React.Fragment>
            <button className="dk-iconbtn" onClick={() => onCall(peer.id, 'voice')} title="Voice call">
              <BCIcon name="phone" size={18} />
            </button>
            <button className="dk-iconbtn" onClick={() => onCall(peer.id, 'video')} title="Video call">
              <BCIcon name="videocam" size={19} />
            </button>
          </React.Fragment>
        )}
        <button className={'dk-iconbtn' + (railOpen ? ' on' : '')} onClick={onToggleRail} title="Details">
          <BCIcon name="info" size={18} />
        </button>
      </div>
      {isCh ? (
        <Banner icon="people" tone="public"><b>Public channel</b> — anyone nearby can read</Banner>
      ) : verified ? null : peer.inRange ? (
        <Banner icon="lock" tone="enc"><b>End-to-end encrypted</b> — only you and {peer.name} can read this</Banner>
      ) : (
        <Banner icon="globe" tone="net"><b>Out of Bluetooth range</b> — encrypted over the internet instead</Banner>
      )}
      {msgs.length === 0 ? (
        isCh ? (
          <div className="bc-empty">
            <span className="bc-emptyicon amber"><BCIcon name="pin" size={26} /></span>
            <div className="bc-emptytitle">Quiet in {ch.name} right now</div>
            <div className="bc-emptydesc">{ch.count} people are in range of this channel today. Say hi.</div>
          </div>
        ) : (
          <div className="bc-empty">
            <span className="bc-emptyicon"><BCIcon name="lock" size={24} /></span>
            <div className="bc-emptytitle">Say hi to {peer.name}</div>
            <div className="bc-emptydesc">Messages here are end-to-end encrypted. Only the two of you can read them.</div>
          </div>
        )
      ) : (
        <MsgList msgs={msgs} showAuthors={isCh} peerName={isCh ? undefined : peer.name} onClaim={isCh ? undefined : (i) => onClaimPay(peer.id, i)} pay={pp} />
      )}
      <div style={{ position: 'relative' }}>
        {pop && (
          <div className="dk-pop">
            <AttachActions transport={transport} onPick={(t) => { setPop(false); onMedia(isCh ? ch.id : peer.id, t); }} />
            {!isCh && (
              <ActionRow icon="coin" label={btc ? 'Send bitcoin' : 'Send money'} desc={btc ? (peer.inRange ? 'Travels over Bluetooth as ecash' : 'Instant over Lightning') : (peer.inRange ? 'Privately, phone-to-phone over Bluetooth' : 'Privately over the internet')} onClick={() => { setPop(false); setPay(true); }} />
            )}
            <ActionRow icon="navArrow" label="Share location" desc={isCh ? 'Drop a pin in this channel' : 'Only ' + peer.name + ' will see it'} onClick={() => setPop(false)} />
            <ActionRow icon="people" label="People nearby" desc="Open the radar" onClick={() => { setPop(false); onSelect('radar'); }} />
            <ActionRow icon="smile" label="Reactions" desc="A little fun, no noise" onClick={() => setPop(false)} />
          </div>
        )}
        <Composer
          placeholder={'Message ' + (isCh ? ch.name : peer.name) + (!isCh && !peer.inRange ? ' · via internet' : '')}
          transport={transport}
          onSend={(tx) => isCh ? onSendCh(ch.id, tx) : onSendDm(peer.id, tx)}
          onPlus={() => setPop(!pop)}
          onVoice={(sec) => onVoice(isCh ? ch.id : peer.id, sec)}
          onCommand={(c) => onCommand({ type: isCh ? 'ch' : 'dm', id: isCh ? ch.id : peer.id, target: isCh ? 'Luca' : peer.name }, c)}
        />
      </div>
      {pay && !isCh && (
        <PaySheet
          peer={peer} balance={app.balance || 0} transport={transport} pay={pp}
          onClose={() => setPay(false)} onSend={(sats) => onPay(peer.id, sats)}
        />
      )}
    </div>
  );
}

/* ── Radar pane ── */
function DkRadarPane({ app, onSelect }) {
  const [psel, setPsel] = React.useState(null);
  const inRange = BC_DATA.peers.filter((p) => p.inRange);
  const far = BC_DATA.peers.filter((p) => !p.inRange);
  const C = 174;
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
    <div className="dk-main" data-screen-label="Sonar discovery">
      <div className="dk-chathead">
        <span className="tile" style={{ width: 38, height: 38, borderRadius: 11, background: 'var(--accent-soft)', color: 'var(--accent-deep)', display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 'none' }}>
          <BCIcon name="rings" size={20} />
        </span>
        <span className="titles">
          <div className="bc-hname"><span>Sonar</span></div>
          <div className="bc-hsub"><span className="bc-dot g sm"></span>{inRange.length} in range · scanning</div>
        </span>
      </div>
      <div className="dk-radarpane">
        <div className="dk-radarside">
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
          <div className="sn-caption">{psel ? 'Choose what to do' : 'Click someone to chat or pay'}</div>
          <div className="sn-legend">
            <span><i className="sn-ldot ble"></i>nearby · Bluetooth</span>
            <span><i className="sn-ldot net"></i>far · internet</span>
          </div>
          {psel && (
            <div className="sn-peercard" style={{ position: 'static', margin: '16px 0 0', width: 330, maxWidth: '100%' }}>
              <Avatar name={psel.name} size={44} presence={psel.inRange} />
              <span className="pcmain">
                <div className="pcname">{psel.name}</div>
                <div className="pchint">{psel.inRange ? psel.hint + ' · over Bluetooth' : 'Out of range · over the internet'}</div>
              </span>
              <button className="pf-smallbtn" onClick={() => onSelect('dm', psel.id)}>Message</button>
              <button className="pf-smallbtn primary" onClick={() => onSelect('dm', psel.id, { pay: 1 })}>Send sats</button>
            </div>
          )}
        </div>
        <div className="dk-radarlist">
          <SectionLabel>In range · Bluetooth</SectionLabel>
          {inRange.map((p) => (
            <button key={p.id} className="dk-row" onClick={() => onSelect('dm', p.id)}>
              <Avatar name={p.name} size={40} presence />
              <span className="dk-rowmain">
                <span className="dk-rowtitle">{p.name}</span>
                <span className="dk-rowsub"><Bars n={p.bars} />{p.hint} · {p.detail}</span>
              </span>
            </button>
          ))}
          <SectionLabel>Out of range · internet</SectionLabel>
          {far.map((p) => (
            <button key={p.id} className="dk-row" onClick={() => onSelect('dm', p.id)}>
              <Avatar name={p.name} size={40} />
              <span className="dk-rowmain">
                <span className="dk-rowtitle">{p.name}</span>
                <span className="dk-rowsub">
                  <BCIcon name="globe" size={12} weight={2.2} style={{ color: 'var(--net)', flex: 'none' }} />
                  {p.detail}
                </span>
              </span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

/* ── Detail rail ── */
function DkRail({ app, sel, onVerify }) {
  const [showKey, setShowKey] = React.useState(false);
  const [precision, setPrecision] = React.useState('block');
  if (sel.type === 'channel') {
    const ch = BC_DATA.channels.find((c) => c.id === sel.id) || (BC_DATA.here || []).find((c) => c.id === sel.id) || BC_DATA.channels[0];
    return (
      <div className="dk-rail" data-screen-label="Channel details">
        <PlaceTile size={64} />
        <div className="dk-railname">{ch.name}</div>
        <div className="dk-railsub"><span className="bc-dot g sm"></span>{ch.sub}</div>
        <div className="dk-precision">
          {['block', 'neighborhood', 'city', 'region'].map((p) => (
            <button key={p} className={precision === p ? 'on' : ''} onClick={() => setPrecision(p)}>{p}</button>
          ))}
        </div>
        <p className="dk-railnote">Channels are tied to a place, not to you. Anyone in this area can read and write — nothing here is encrypted.</p>
      </div>
    );
  }
  const peer = BC_DATA.peers.find((p) => p.id === sel.id) || BC_DATA.peers[0];
  const verified = !!app.verified[peer.id];
  return (
    <div className="dk-rail" data-screen-label="Conversation details">
      <Avatar name={peer.name} size={84} presence={peer.inRange} />
      <div className="dk-railname">
        {peer.name}
        {verified ? <BCIcon name="shieldCheck" size={17} weight={2.1} style={{ color: 'var(--green)' }} /> : null}
      </div>
      <div className="dk-railsub">
        {peer.inRange
          ? <><span className="sn-ldot ble" style={{ width: 8, height: 8, borderRadius: '50%', display: 'inline-block' }}></span>{peer.hint} · over Bluetooth</>
          : <><span className="sn-ldot net" style={{ width: 8, height: 8, borderRadius: '50%', display: 'inline-block' }}></span>Out of range · over the internet</>}
      </div>
      {verified ? (
        <span className="dk-verifiedpill"><BCIcon name="shieldCheck" size={14} weight={2.2} />Safety number verified</span>
      ) : (
        <React.Fragment>
          <div className="bc-safety">
            {[0, 4, 8].map((row) => (
              <div key={row}>{BC_DATA.safety.slice(row, row + 4).join('\u2002')}</div>
            ))}
          </div>
          <p className="dk-railnote">Compare these numbers with {peer.name} in person or on a call. If they match, nobody is in the middle.</p>
          <button className="bc-primary" onClick={() => onVerify(peer.id)}>They match — mark as verified</button>
        </React.Fragment>
      )}
      <button className="bc-ghost" onClick={() => setShowKey(!showKey)}>
        {showKey ? 'Hide public key' : 'Show public key'}
      </button>
      {showKey ? <div className="bc-pubkey">{BC_DATA.pubkey}</div> : null}
    </div>
  );
}

/* ── Settings modal ── */
function DkSettingsModal({ app, mode, onToggleMode, toggleNetwork, onPref, onRename, onWipe, onClose }) {
  const [editing, setEditing] = React.useState(false);
  const [draft, setDraft] = React.useState(app.nick || '');
  const [wipeAsk, setWipeAsk] = React.useState(false);
  const [curOpen, setCurOpen] = React.useState(false);
  const prefs = app.prefs || {};
  const shortKey = BC_DATA.pubkey.slice(0, 14) + '\u2026' + BC_DATA.pubkey.slice(-6);
  const save = () => {
    if (draft.trim().length >= 2) onRename(draft.trim());
    setEditing(false);
  };
  return (
    <div className="dk-scrim" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="dk-modal">
        <div className="dk-modalhead">
          <h3>Settings</h3>
          <button className="dk-iconbtn" onClick={onClose} aria-label="Close">
            <BCIcon name="x" size={16} weight={2.2} />
          </button>
        </div>
        <div className="dk-profhead">
          <Avatar name={(editing ? draft.trim() : app.nick) || 'you'} size={72} />
          {editing ? (
            <div className="pf-editrow" style={{ padding: '0 24px' }}>
              <input
                className="bc-nickinput" style={{ fontSize: 17, padding: '10px 13px' }}
                type="text" value={draft} maxLength={20} placeholder="nickname"
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') save(); }}
              />
              <button className="pf-smallbtn primary" onClick={save}>Save</button>
            </div>
          ) : (
            <div className="pf-name">
              {app.nick || 'you'}
              <button className="bc-iconbtn" style={{ width: 28, height: 28 }} onClick={() => { setDraft(app.nick || ''); setEditing(true); }} aria-label="Edit nickname">
                <BCIcon name="pencil" size={14} weight={2} />
              </button>
            </div>
          )}
          <span className="pf-key">{shortKey}</span>
        </div>

        <SectionLabel>App</SectionLabel>
        <div className="st-card">
          <StRow icon="moon" label="Appearance" value={mode === 'dark' ? 'Dark' : 'Light'} onClick={onToggleMode} />
          <StRow icon="bell" label="Notifications" onClick={() => onPref('notifs', !prefs.notifs)} toggle={!!prefs.notifs} />
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
          <StRow icon="coin" tone="gold" label="Bitcoin" sub="Pays like you message — Bluetooth or Lightning" value={payFmt(app.balance || 0) + ' sats'} onClick={() => {}} />
        </div>

        <SectionLabel>Wallet</SectionLabel>
        <div className="st-card">
          <StRow icon="coin" tone="gold" label="Balance" value={walletStr(app)} trail={null} onClick={() => {}} />
          <StRow icon="globe" label="Currency" value={(prefs.currency || 'EUR')} onClick={() => setCurOpen(!curOpen)} />
          <StRow icon="bolt" label="Bitcoin mode" sub="Show sats and bitcoin networks" onClick={() => onPref('btcMode', !prefs.btcMode)} toggle={!!prefs.btcMode} />
        </div>
        {curOpen && (
          <div className="pf-reqbtns" style={{ padding: '0 16px 6px', flexWrap: 'wrap' }}>
            {PAY_CURRENCIES.map((c) => (
              <button key={c} className={'pay-chip' + ((prefs.currency || 'EUR') === c ? ' on' : '')} onClick={() => { onPref('currency', c); setCurOpen(false); }}>{c}</button>
            ))}
          </div>
        )}

        <SectionLabel>Privacy &amp; safety</SectionLabel>
        <div className="st-card">
          <StRow icon="faceid" label="App lock" sub="Require Touch ID to open Sonar" onClick={() => onPref('appLock', !prefs.appLock)} toggle={!!prefs.appLock} />
          <StRow icon="check" label="Read receipts" onClick={() => onPref('readReceipts', !prefs.readReceipts)} toggle={!!prefs.readReceipts} />
          <StRow icon="trash" tone="red" danger label="Emergency wipe" sub="Deletes your key, chats and nickname" onClick={() => setWipeAsk(!wipeAsk)} />
        </div>
        {wipeAsk && (
          <div className="pf-reqbtns" style={{ padding: '0 16px 6px' }}>
            <button className="pf-smallbtn" style={{ background: 'var(--danger)', color: '#FFF6F6', flex: 'none' }} onClick={onWipe}>Wipe everything</button>
            <button className="pf-smallbtn" onClick={() => setWipeAsk(false)}>Cancel</button>
          </div>
        )}

        <SectionLabel>About</SectionLabel>
        <div className="st-card">
          <StRow icon="info" label="About Sonar" sub="Open protocols — Bluetooth mesh + Nostr" onClick={() => {}} />
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { DkSidebar, DkChatPane, DkRadarPane, DkRail, DkSettingsModal });

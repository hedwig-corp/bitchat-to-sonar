// Sonar Desktop — app shell: state, selection, routing logic, tweaks, window frame

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "mode": "dark",
  "bubbles": "filled",
  "radius": 18,
  "density": "regular",
  "typeface": "Figtree",
  "windowWidth": 1240
}/*EDITMODE-END*/;

const BC_FONTS = {
  'Figtree': "'Figtree', system-ui, sans-serif",
  'Nunito Sans': "'Nunito Sans', system-ui, sans-serif",
  'System': "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', system-ui, sans-serif",
};

function bcNow() {
  const d = new Date();
  return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}

function dkFreshState() {
  return {
    v: 3,
    nick: 'quietfox',
    network: 'online',
    balance: 182400,
    verified: {},
    read: { maya: true },
    sel: { type: 'dm', id: 'maya' },
    rail: true,
    prefs: { appLock: false, readReceipts: true, notifs: true, btcMode: false, currency: 'EUR' },
    chMsgs: { centro: BC_DATA.chMsgs.slice(), city: [] },
    dmMsgs: { maya: BC_DATA.dmMsgs.slice(), sofia: BC_DATA.dmMsgsSofia.slice() },
    txns: BC_DATA.txns.slice(),
    groupMsgs: { lake: BC_DATA.groupMsgs.lake.slice(), trip: BC_DATA.groupMsgs.trip.slice() },
  };
}

function dkLoadState() {
  try {
    const s = JSON.parse(localStorage.getItem('sn_desk_v1'));
    if (s && s.v === 3) {
      const d = dkFreshState();
      return { ...d, ...s, prefs: { ...d.prefs, ...(s.prefs || {}) }, chMsgs: { ...d.chMsgs, ...(s.chMsgs || {}) }, dmMsgs: { ...d.dmMsgs, ...(s.dmMsgs || {}) }, groupMsgs: { ...d.groupMsgs, ...(s.groupMsgs || {}) }, txns: s.txns || d.txns };
    }
  } catch (e) { /* fall through */ }
  return dkFreshState();
}

function SonarDesktop() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [app, setApp] = React.useState(dkLoadState);
  const [settings, setSettings] = React.useState(false);
  const [donate, setDonate] = React.useState(false);
  const [scale, setScale] = React.useState(1);
  const winW = t.windowWidth;
  const winH = 780;

  React.useEffect(() => {
    try { localStorage.setItem('sn_desk_v1', JSON.stringify(app)); } catch (e) { /* ignore */ }
  }, [app]);

  React.useEffect(() => {
    document.body.dataset.mode = t.mode;
  }, [t.mode]);

  React.useEffect(() => {
    const fit = () => {
      const w = Math.max(640, window.innerWidth - 420);
      setScale(Math.min(1, (window.innerHeight - 64) / winH, w / winW));
    };
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, [winW]);

  const select = (type, id, extra) => setApp((a) => ({
    ...a,
    prevSel: (a.sel && a.sel.type !== 'newgroup') ? a.sel : a.prevSel,
    sel: { type, id, ...(extra || {}) },
    read: id ? { ...a.read, [id]: true, ['g-' + id]: true } : a.read,
  }));
  const toggleNetwork = () => setApp((a) => ({ ...a, network: a.network === 'online' ? 'offline' : 'online' }));
  const toggleRail = () => setApp((a) => ({ ...a, rail: !a.rail }));
  const setPref = (k, v) => setApp((a) => ({ ...a, prefs: { ...(a.prefs || {}), [k]: v } }));
  const wipe = () => { setSettings(false); setApp(dkFreshState()); };

  const appendCh = (chId, m) => setApp((a) => ({
    ...a, chMsgs: { ...a.chMsgs, [chId]: [...(a.chMsgs[chId] || []), m] },
  }));
  const appendDm = (peerId, m) => setApp((a) => ({
    ...a, dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), m] },
  }));

  const sendCh = (chId, text) => setApp((a) => ({
    ...a,
    chMsgs: {
      ...a.chMsgs,
      [chId]: [...(a.chMsgs[chId] || []), {
        mine: true, author: a.nick || 'you', text, time: bcNow(),
        via: a.network === 'online' ? 'internet' : 'mesh', state: 'Delivered',
      }],
    },
  }));
  const sendDm = (peerId, text) => setApp((a) => {
    const peer = BC_DATA.peers.find((p) => p.id === peerId);
    const inRange = peer && peer.inRange;
    const via = inRange ? 'mesh' : 'internet';
    const state = inRange ? 'Delivered' : (a.network === 'online' ? 'Delivered' : 'Waiting to send');
    return {
      ...a,
      dmMsgs: {
        ...a.dmMsgs,
        [peerId]: [...(a.dmMsgs[peerId] || []), { mine: true, text, time: bcNow(), via, state }],
      },
    };
  });

  const onCommand = (ctx, cmd) => {
    if (cmd === 'who' || cmd === 'msg') { select('radar'); return; }
    if (cmd === 'slap') {
      const m = { action: true, text: '* ' + (app.nick || 'you') + ' slaps ' + ctx.target + ' around a bit with a large trout', time: bcNow() };
      if (ctx.type === 'ch') appendCh(ctx.id, m);
      else if (ctx.type === 'group') setApp((a) => ({ ...a, groupMsgs: { ...a.groupMsgs, [ctx.id]: [...(a.groupMsgs[ctx.id] || []), m] } }));
      else appendDm(ctx.id, m);
    }
  };

  // Direct payment: pending → paid → confirmed (signed receipt); records a wallet txn
  const setPayState = (peerId, key, state) => setApp((a) => ({
    ...a,
    dmMsgs: { ...a.dmMsgs, [peerId]: (a.dmMsgs[peerId] || []).map((m) => (m.payKey === key ? { ...m, state } : m)) },
    txns: (a.txns || []).map((t) => (t.key === key ? { ...t, state } : t)),
  }));
  const sendPay = (peerId, sats) => {
    const key = 'tx' + Date.now();
    const peer = BC_DATA.peers.find((p) => p.id === peerId);
    const via = peer && peer.inRange ? 'mesh' : 'internet';
    const time = bcNow();
    setApp((a) => ({
      ...a,
      balance: Math.max(0, (a.balance || 0) - sats),
      dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), { pay: true, mine: true, amount: sats, via, state: 'pending', time, payKey: key }] },
      txns: [{ key, dir: 'out', who: peer ? peer.name : 'unknown', amount: sats, via, state: 'pending', time }, ...((a.txns) || [])],
    }));
    setTimeout(() => setPayState(peerId, key, 'paid'), 1400);
    setTimeout(() => setPayState(peerId, key, 'confirmed'), 3200);
  };
  const claimPay = () => {};

  const sendMediaCh = (chId, type) => setApp((a) => ({
    ...a,
    chMsgs: { ...a.chMsgs, [chId]: [...(a.chMsgs[chId] || []), {
      mine: true, author: a.nick || 'you', media: bcSampleMedia(type), time: bcNow(),
      via: a.network === 'online' ? 'internet' : 'mesh', state: 'Delivered',
    }] },
  }));
  const sendMediaDm = (peerId, type) => setApp((a) => {
    const peer = BC_DATA.peers.find((p) => p.id === peerId);
    const via = peer && peer.inRange ? 'mesh' : 'internet';
    return { ...a, dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), {
      mine: true, media: bcSampleMedia(type), time: bcNow(), via, state: 'Delivered',
    }] } };
  });
  const sendMedia = (id, type) => (app.sel.type === 'channel' ? sendMediaCh(id, type) : sendMediaDm(id, type));

  const sendVoiceCh = (chId, sec) => setApp((a) => ({
    ...a,
    chMsgs: { ...a.chMsgs, [chId]: [...(a.chMsgs[chId] || []), {
      mine: true, author: a.nick || 'you', media: bcVoiceMedia(sec), time: bcNow(),
      via: a.network === 'online' ? 'internet' : 'mesh', state: 'Delivered',
    }] },
  }));
  const sendVoiceDm = (peerId, sec) => setApp((a) => {
    const peer = BC_DATA.peers.find((p) => p.id === peerId);
    const via = peer && peer.inRange ? 'mesh' : 'internet';
    return { ...a, dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), {
      mine: true, media: bcVoiceMedia(sec), time: bcNow(), via, state: 'Delivered',
    }] } };
  });
  const sendVoice = (id, sec) => (app.sel.type === 'channel' ? sendVoiceCh(id, sec) : sendVoiceDm(id, sec));

  // Group chats (desktop) — internet only, secured by White Noise
  const groupVia = (groupId) => 'internet';
  const sendGroup = (groupId, text) => setApp((a) => ({
    ...a, groupMsgs: { ...a.groupMsgs, [groupId]: [...(a.groupMsgs[groupId] || []), {
      mine: true, text, time: bcNow(), via: groupVia(groupId), state: 'Delivered',
    }] },
  }));
  const sendMediaGroup = (groupId, type) => setApp((a) => ({
    ...a, groupMsgs: { ...a.groupMsgs, [groupId]: [...(a.groupMsgs[groupId] || []), {
      mine: true, media: bcSampleMedia(type), time: bcNow(), via: groupVia(groupId), state: 'Delivered',
    }] },
  }));
  const sendVoiceGroup = (groupId, sec) => setApp((a) => ({
    ...a, groupMsgs: { ...a.groupMsgs, [groupId]: [...(a.groupMsgs[groupId] || []), {
      mine: true, media: bcVoiceMedia(sec), time: bcNow(), via: groupVia(groupId), state: 'Delivered',
    }] },
  }));
  const createGroup = (name, memberIds) => {
    const id = 'g' + Date.now().toString(36);
    BC_DATA.groups = [{ id, name, members: memberIds, preview: 'New group', time: 'now', unread: 0 }, ...(BC_DATA.groups || [])];
    setApp((a) => ({ ...a, groupMsgs: { ...a.groupMsgs, [id]: [] }, sel: { type: 'group', id } }));
  };
  const leaveGroup = (groupId) => {
    BC_DATA.groups = (BC_DATA.groups || []).filter((g) => g.id !== groupId);
    setApp((a) => ({ ...a, sel: { type: 'dm', id: 'maya' } }));
  };

  const [call, setCall] = React.useState(null); // { id, kind }
  const endCall = (peerId, kind, sec) => {
    setCall(null);
    setApp((a) => ({
      ...a,
      dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), {
        call: true, kind, mine: true, dur: sec ? fmtCall(sec) : null, missed: !sec, time: bcNow(),
      }] },
    }));
  };

  const fontStack = BC_FONTS[t.typeface] || BC_FONTS.Figtree;
  const showRail = app.rail && app.sel.type !== 'radar' && app.sel.type !== 'newgroup';

  return (
    <React.Fragment>
      <div style={{ width: winW * scale, height: winH * scale }}>
        <div style={{ transform: 'scale(' + scale + ')', transformOrigin: 'top left' }}>
          <div
            className="bc-app dk-window"
            data-mode={t.mode}
            data-bubble={t.bubbles}
            data-density={t.density}
            style={{ width: winW, height: winH, '--r': t.radius + 'px', '--ui-font': fontStack, fontFamily: fontStack }}
          >
            <DkSidebar app={app} sel={app.sel} onSelect={select} toggleNetwork={toggleNetwork} onSettings={() => setSettings(true)} />
            {app.sel.type === 'radar'
              ? <DkRadarPane app={app} onSelect={select} />
              : app.sel.type === 'newgroup'
              ? <NewGroupScreen app={app} nav="" pop={() => select(app.prevSel ? app.prevSel.type : 'dm', app.prevSel ? app.prevSel.id : 'maya')} onCreate={createGroup} />
              : app.sel.type === 'group'
              ? <DkGroupPane
                  app={app} sel={app.sel}
                  railOpen={app.rail} onToggleRail={toggleRail}
                  onSendGroup={sendGroup} onMediaGroup={sendMediaGroup} onVoiceGroup={sendVoiceGroup}
                  onCommand={onCommand} onSelect={select}
                />
              : <DkChatPane
                  app={app} sel={app.sel}
                  railOpen={app.rail} onToggleRail={toggleRail}
                  onSendCh={sendCh} onSendDm={sendDm}
                  onCommand={onCommand} onSelect={select}
                  onPay={sendPay} onClaimPay={claimPay} openPay={!!app.sel.pay} onMedia={sendMedia} onVoice={sendVoice}
                  onCall={(id, kind) => setCall({ id, kind })}
                />}
            {showRail && (
              <DkRail
                app={app} sel={app.sel}
                onVerify={(pid) => setApp((a) => ({ ...a, verified: { ...a.verified, [pid]: true } }))}
                onSelect={select}
                onLeave={leaveGroup}
              />
            )}
            {settings && (
              <DkSettingsModal
                app={app} mode={t.mode}
                onToggleMode={() => setTweak('mode', t.mode === 'dark' ? 'light' : 'dark')}
                toggleNetwork={toggleNetwork}
                onPref={setPref}
                onRename={(n) => setApp((a) => ({ ...a, nick: n }))}
                onWipe={wipe}
                push={(s) => { if (s === 'donate') { setSettings(false); setDonate(true); } }}
                onClose={() => setSettings(false)}
              />
            )}
            {donate && (
              <DonateScreen
                app={app} nav="" overlay
                pop={() => setDonate(false)}
                onBecomeSupporter={() => setPref('supporter', true)}
              />
            )}
            {call && (() => {
              const cpeer = BC_DATA.peers.find((p) => p.id === call.id) || BC_DATA.peers[0];
              return (
                <CallView
                  peer={cpeer} kind={call.kind} nick={app.nick}
                  transport={cpeer.inRange ? 'mesh' : 'internet'}
                  onEnd={(sec) => endCall(call.id, call.kind, sec)}
                />
              );
            })()}
          </div>
        </div>
      </div>

      <TweaksPanel>
        <TweakSection label="Appearance" />
        <TweakRadio label="Mode" value={t.mode} options={['light', 'dark']} onChange={(v) => setTweak('mode', v)} />
        <TweakRadio label="My bubbles" value={t.bubbles} options={['filled', 'tinted']} onChange={(v) => setTweak('bubbles', v)} />
        <TweakSection label="Layout" />
        <TweakSlider label="Window width" value={t.windowWidth} min={980} max={1400} step={10} unit="px" onChange={(v) => setTweak('windowWidth', v)} />
        <TweakRadio label="Density" value={t.density} options={['compact', 'regular', 'cozy']} onChange={(v) => setTweak('density', v)} />
        <TweakSlider label="Bubble radius" value={t.radius} min={10} max={24} unit="px" onChange={(v) => setTweak('radius', v)} />
        <TweakSelect label="Typeface" value={t.typeface} options={['Figtree', 'Nunito Sans', 'System']} onChange={(v) => setTweak('typeface', v)} />
        <TweakSection label="Demo" />
        <TweakButton label="Reset demo data" secondary onClick={() => setApp(dkFreshState())} />
      </TweaksPanel>
    </React.Fragment>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<SonarDesktop />);

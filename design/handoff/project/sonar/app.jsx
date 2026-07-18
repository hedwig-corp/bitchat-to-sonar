// Sonar — app shell: state, navigation, routing logic, tweaks, device frame

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "mode": "dark",
  "direction": "quiet",
  "chip": "pill",
  "bubbles": "filled",
  "radius": 18,
  "density": "regular",
  "typeface": "Figtree"
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

function bcFreshState() {
  return {
    v: 3,
    onboarded: false,
    nick: '',
    network: 'online',
    balance: 182400,
    txns: BC_DATA.txns.slice(),
    verified: {},
    muted: {},
    read: {},
    stack: [{ s: 'home' }],
    nav: '',
    prefs: { appLock: false, readReceipts: true, preview: true, names: true, notifs: true, icon: 'default', requests: 1, btcMode: false, currency: 'EUR' },
    chMsgs: { centro: BC_DATA.chMsgs.slice(), city: [] },
    dmMsgs: { maya: BC_DATA.dmMsgs.slice(), sofia: BC_DATA.dmMsgsSofia.slice() },
    groupMsgs: { lake: BC_DATA.groupMsgs.lake.slice(), trip: BC_DATA.groupMsgs.trip.slice() },
  };
}

function bcLoadState() {
  try {
    const s = JSON.parse(localStorage.getItem('sn_proto_v1'));
    if (s && s.v === 3) {
      const d = bcFreshState();
      return { ...d, ...s, nav: '', prefs: { ...d.prefs, ...(s.prefs || {}) }, chMsgs: { ...d.chMsgs, ...(s.chMsgs || {}) }, dmMsgs: { ...d.dmMsgs, ...(s.dmMsgs || {}) }, groupMsgs: { ...d.groupMsgs, ...(s.groupMsgs || {}) }, txns: s.txns || d.txns };
    }
  } catch (e) { /* fall through */ }
  return bcFreshState();
}

function SonarApp() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [app, setApp] = React.useState(bcLoadState);
  const [scale, setScale] = React.useState(1);

  React.useEffect(() => {
    try { localStorage.setItem('sn_proto_v1', JSON.stringify(app)); } catch (e) { /* ignore */ }
  }, [app]);

  React.useEffect(() => {
    document.body.dataset.mode = t.mode;
  }, [t.mode]);

  React.useEffect(() => {
    const fit = () => setScale(Math.min(1, (window.innerHeight - 56) / 900));
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);

  const push = (s, params) => setApp((a) => ({
    ...a,
    stack: [...a.stack, { s, ...(params || {}) }],
    nav: 'push',
    read: params && params.id ? { ...a.read, [params.id]: true } : a.read,
  }));
  const pop = () => setApp((a) => ({ ...a, stack: a.stack.length > 1 ? a.stack.slice(0, -1) : a.stack, nav: 'pop' }));
  const toggleNetwork = () => setApp((a) => ({ ...a, network: a.network === 'online' ? 'offline' : 'online' }));
  const wipe = () => setApp(bcFreshState());
  const setPref = (k, v) => setApp((a) => ({ ...a, prefs: { ...(a.prefs || {}), [k]: v } }));
  const muteConv = (id, dur) => setApp((a) => ({ ...a, muted: { ...a.muted, [id]: dur || 'forever' } }));
  const unmuteConv = (id) => setApp((a) => { const m = { ...a.muted }; delete m[id]; return { ...a, muted: m }; });

  const appendCh = (chId, m) => setApp((a) => ({
    ...a, chMsgs: { ...a.chMsgs, [chId]: [...(a.chMsgs[chId] || []), m] },
  }));
  const appendDm = (peerId, m) => setApp((a) => ({
    ...a, dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), m] },
  }));

  // ── Nudge (MSN-style "trillo"): shake the frame + play a bell ──
  const [shake, setShake] = React.useState(0);
  const buzz = () => {
    setShake((n) => n + 1);
    try {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (AC) {
        const ctx = window.__bcAudio || (window.__bcAudio = new AC());
        if (ctx.state === 'suspended') ctx.resume();
        [0, 0.16].forEach((t0) => {
          const o = ctx.createOscillator(), g = ctx.createGain();
          o.type = 'sine'; o.frequency.setValueAtTime(880, ctx.currentTime + t0);
          o.frequency.exponentialRampToValueAtTime(660, ctx.currentTime + t0 + 0.12);
          g.gain.setValueAtTime(0.0001, ctx.currentTime + t0);
          g.gain.exponentialRampToValueAtTime(0.32, ctx.currentTime + t0 + 0.02);
          g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + t0 + 0.22);
          o.connect(g); g.connect(ctx.destination);
          o.start(ctx.currentTime + t0); o.stop(ctx.currentTime + t0 + 0.24);
        });
      }
    } catch (e) { /* audio optional */ }
    if (navigator.vibrate) { try { navigator.vibrate([40, 60, 40]); } catch (e) {} }
  };
  React.useEffect(() => {
    if (!shake) return;
    const el = document.querySelector('.bc-app');
    if (!el) return;
    el.setAttribute('data-shake', '1');
    const id = setTimeout(() => el.removeAttribute('data-shake'), 620);
    return () => clearTimeout(id);
  }, [shake]);
  const sendNudge = (peerId) => {
    setApp((a) => ({ ...a, dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), { nudge: true, mine: true, time: bcNow() }] } }));
    buzz();
  };
  const sendNudgeGroup = (groupId) => {
    setApp((a) => ({ ...a, groupMsgs: { ...a.groupMsgs, [groupId]: [...(a.groupMsgs[groupId] || []), { nudge: true, mine: true, author: a.nick || 'you', time: bcNow() }] } }));
    buzz();
  };

  // Channel routing: Nostr when online, Bluetooth mesh when offline
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

  // DM routing: Bluetooth if the peer is in range, otherwise Nostr over the internet
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

  // Direct payment to the peer's BOLT12 offer: pending → paid → confirmed (signed receipt)
  const pushTxn = (a, tx) => ({ ...a, txns: [tx, ...((a.txns) || [])] });
  const setPayState = (peerId, key, state) => setApp((a) => {
    const list = (a.dmMsgs[peerId] || []).map((m) => (m.payKey === key ? { ...m, state } : m));
    const txns = (a.txns || []).map((t) => (t.key === key ? { ...t, state } : t));
    return { ...a, dmMsgs: { ...a.dmMsgs, [peerId]: list }, txns };
  });
  const sendPay = (peerId, sats) => {
    const key = 'tx' + Date.now();
    const peer = BC_DATA.peers.find((p) => p.id === peerId);
    const via = peer && peer.inRange ? 'mesh' : 'internet';
    const time = bcNow();
    setApp((a) => {
      const withMsg = { ...a, balance: Math.max(0, (a.balance || 0) - sats),
        dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), { pay: true, mine: true, amount: sats, via, state: 'pending', time, payKey: key }] } };
      return pushTxn(withMsg, { key, dir: 'out', who: peer ? peer.name : 'unknown', amount: sats, via, state: 'pending', time });
    });
    setTimeout(() => setPayState(peerId, key, 'paid'), 1400);
    setTimeout(() => setPayState(peerId, key, 'confirmed'), 3200);
  };
  const claimPay = () => {};

  // Media rides the same rails as messages (Bluetooth in range, internet otherwise)
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
    return {
      ...a,
      dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), {
        mine: true, media: bcSampleMedia(type), time: bcNow(), via, state: 'Delivered',
      }] },
    };
  });

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
    return {
      ...a,
      dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), {
        mine: true, media: bcVoiceMedia(sec), time: bcNow(), via, state: 'Delivered',
      }] },
    };
  });

  const endCall = (peerId, kind, sec) => setApp((a) => ({
    ...a,
    stack: a.stack.length > 1 ? a.stack.slice(0, -1) : a.stack,
    nav: 'pop',
    dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), {
      call: true, kind, mine: true, dur: sec ? fmtCall(sec) : null, missed: !sec, time: bcNow(),
    }] },
  }));

  // Group chats: route to members in range over Bluetooth, the rest over internet
  const groupVia = (groupId) => 'internet';
  const sendGroup = (groupId, text) => setApp((a) => ({
    ...a,
    groupMsgs: { ...a.groupMsgs, [groupId]: [...(a.groupMsgs[groupId] || []), {
      mine: true, text, time: bcNow(), via: groupVia(groupId), state: 'Delivered',
    }] },
  }));
  const sendMediaGroup = (groupId, type) => setApp((a) => ({
    ...a,
    groupMsgs: { ...a.groupMsgs, [groupId]: [...(a.groupMsgs[groupId] || []), {
      mine: true, media: bcSampleMedia(type), time: bcNow(), via: groupVia(groupId), state: 'Delivered',
    }] },
  }));
  const sendVoiceGroup = (groupId, sec) => setApp((a) => ({
    ...a,
    groupMsgs: { ...a.groupMsgs, [groupId]: [...(a.groupMsgs[groupId] || []), {
      mine: true, media: bcVoiceMedia(sec), time: bcNow(), via: groupVia(groupId), state: 'Delivered',
    }] },
  }));
  const createGroup = (name, memberIds) => {
    const id = 'g' + Date.now().toString(36);
    BC_DATA.groups = [{ id, name, members: memberIds, preview: 'New group', time: 'now', unread: 0 }, ...(BC_DATA.groups || [])];
    setApp((a) => ({
      ...a,
      groupMsgs: { ...a.groupMsgs, [id]: [] },
      stack: [...a.stack.slice(0, -1), { s: 'group', id }],
      nav: 'push',
    }));
  };
  const leaveGroup = (groupId) => {
    BC_DATA.groups = (BC_DATA.groups || []).filter((g) => g.id !== groupId);
    setApp((a) => ({ ...a, stack: [{ s: 'home' }], nav: 'pop' }));
  };

  const onCommand = (ctx, cmd) => {
    if (cmd === 'who' || cmd === 'msg') { push('nearby'); return; }
    if (cmd === 'slap') {
      const m = { action: true, text: '* ' + (app.nick || 'you') + ' slaps ' + ctx.target + ' around a bit with a large trout', time: bcNow() };
      if (ctx.type === 'ch') appendCh(ctx.id, m);
      else if (ctx.type === 'group') setApp((a) => ({ ...a, groupMsgs: { ...a.groupMsgs, [ctx.id]: [...(a.groupMsgs[ctx.id] || []), m] } }));
      else appendDm(ctx.id, m);
    }
  };

  const top = app.stack[app.stack.length - 1];
  const screenKey = app.stack.length + '-' + top.s + '-' + (top.id || '');
  let screen = null;
  if (top.s === 'home') {
    screen = <HomeScreen key={screenKey} app={app} t={t} nav={app.nav} push={push} toggleNetwork={toggleNetwork} onWipe={wipe} onMute={muteConv} onUnmute={unmuteConv} />;
  } else if (top.s === 'channel') {
    screen = <ChannelScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} chId={top.id} onSend={sendCh} onCommand={onCommand} onMedia={sendMediaCh} onVoice={sendVoiceCh} />;
  } else if (top.s === 'dm') {
    screen = <DMScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} peerId={top.id} onSend={sendDm} onNudge={sendNudge} onCommand={onCommand} onVerify={(pid) => setApp((a) => ({ ...a, verified: { ...a.verified, [pid]: true } }))} onPay={(sats) => sendPay(top.id, sats)} onClaimPay={claimPay} openPay={!!top.pay} onMedia={sendMediaDm} onVoice={sendVoiceDm} onMute={muteConv} onUnmute={unmuteConv} />;
  } else if (top.s === 'nearby') {
    screen = <SonarScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} />;
  } else if (top.s === 'group') {
    screen = <GroupScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} groupId={top.id} onSend={sendGroup} onNudge={sendNudgeGroup} onCommand={onCommand} onMedia={sendMediaGroup} onVoice={sendVoiceGroup} />;
  } else if (top.s === 'groupinfo') {
    screen = <GroupInfoScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} groupId={top.id} onLeave={leaveGroup} />;
  } else if (top.s === 'newgroup') {
    screen = <NewGroupScreen key={screenKey} app={app} nav={app.nav} pop={pop} onCreate={createGroup} />;
  } else if (top.s === 'call') {
    const cpeer = BC_DATA.peers.find((p) => p.id === top.id) || BC_DATA.peers[0];
    screen = <CallView key={screenKey} peer={cpeer} kind={top.kind} nick={app.nick} transport={cpeer.inRange ? 'mesh' : 'internet'} onEnd={(sec) => endCall(top.id, top.kind, sec)} />;
  } else if (top.s === 'settings') {
    screen = <SettingsScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} mode={t.mode} onToggleMode={() => setTweak('mode', t.mode === 'dark' ? 'light' : 'dark')} toggleNetwork={toggleNetwork} onWipe={wipe} onPref={setPref} onUnmute={unmuteConv} />;
  } else if (top.s === 'profile') {
    screen = <ProfileScreen key={screenKey} app={app} nav={app.nav} pop={pop} onRename={(n) => setApp((a) => ({ ...a, nick: n }))} />;
  } else if (top.s === 'wallet') {
    screen = <WalletScreen key={screenKey} app={app} nav={app.nav} pop={pop} />;
  } else if (top.s === 'donate') {
    screen = <DonateScreen key={screenKey} app={app} nav={app.nav} pop={pop} onBecomeSupporter={() => setPref('supporter', true)} />;
  } else if (top.s === 'peer') {
    screen = <PeerProfileScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} peerId={top.id} onVerify={(pid) => setApp((a) => ({ ...a, verified: { ...a.verified, [pid]: true } }))} />;
  }

  const fontStack = BC_FONTS[t.typeface] || BC_FONTS.Figtree;

  return (
    <React.Fragment>
      <div style={{ width: 402 * scale, height: 880 * scale }}>
        <div style={{ transform: 'scale(' + scale + ')', transformOrigin: 'top left' }}>
          <IOSDevice dark={t.mode === 'dark'} width={402} height={874}>
            <div
              className="bc-app"
              data-mode={t.mode}
              data-direction={t.direction}
              data-chip={t.chip}
              data-bubble={t.bubbles}
              data-density={t.density}
              style={{ '--r': t.radius + 'px', '--ui-font': fontStack, fontFamily: fontStack }}
            >
              {app.onboarded
                ? screen
                : <Onboarding
                    initialNick={app.nick}
                    onDone={(n) => setApp((a) => ({ ...a, onboarded: true, nick: n, stack: [{ s: 'home' }], nav: '' }))}
                    onRestore={() => setApp((a) => ({ ...a, onboarded: true, nick: 'quietfox', restored: true, stack: [{ s: 'home' }], nav: '' }))}
                  />}
            </div>
          </IOSDevice>
        </div>
      </div>

      <TweaksPanel>
        <TweakSection label="Appearance" />
        <TweakRadio label="Mode" value={t.mode} options={['light', 'dark']} onChange={(v) => setTweak('mode', v)} />
        <TweakRadio label="Direction" value={t.direction} options={['quiet', 'warm', 'soft']} onChange={(v) => setTweak('direction', v)} />
        <TweakRadio label="Status chip" value={t.chip} options={['pill', 'banner']} onChange={(v) => setTweak('chip', v)} />
        <TweakRadio label="My bubbles" value={t.bubbles} options={['filled', 'tinted']} onChange={(v) => setTweak('bubbles', v)} />
        <TweakSection label="Shape &amp; type" />
        <TweakSlider label="Bubble radius" value={t.radius} min={10} max={24} unit="px" onChange={(v) => setTweak('radius', v)} />
        <TweakRadio label="Density" value={t.density} options={['compact', 'regular', 'cozy']} onChange={(v) => setTweak('density', v)} />
        <TweakSelect label="Typeface" value={t.typeface} options={['Figtree', 'Nunito Sans', 'System']} onChange={(v) => setTweak('typeface', v)} />
        <TweakSection label="Demo" />
        <TweakButton label="Replay onboarding" onClick={() => setApp((a) => ({ ...a, onboarded: false, stack: [{ s: 'home' }], nav: '' }))} />
        <TweakButton label="Reset demo data" secondary onClick={() => setApp(bcFreshState())} />
      </TweaksPanel>
    </React.Fragment>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<SonarApp />);

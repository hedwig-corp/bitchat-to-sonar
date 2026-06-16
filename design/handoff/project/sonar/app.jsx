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
    v: 2,
    onboarded: false,
    nick: '',
    network: 'online',
    balance: 182400,
    verified: {},
    read: {},
    stack: [{ s: 'home' }],
    nav: '',
    prefs: { appLock: false, readReceipts: true, preview: true, names: true, notifs: true, icon: 'default', requests: 1, btcMode: false, currency: 'EUR' },
    chMsgs: { centro: BC_DATA.chMsgs.slice(), city: [] },
    dmMsgs: { maya: BC_DATA.dmMsgs.slice(), sofia: BC_DATA.dmMsgsSofia.slice() },
  };
}

function bcLoadState() {
  try {
    const s = JSON.parse(localStorage.getItem('sn_proto_v1'));
    if (s && s.v === 2) {
      const d = bcFreshState();
      return { ...d, ...s, nav: '', prefs: { ...d.prefs, ...(s.prefs || {}) }, chMsgs: { ...d.chMsgs, ...(s.chMsgs || {}) }, dmMsgs: { ...d.dmMsgs, ...(s.dmMsgs || {}) } };
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

  const appendCh = (chId, m) => setApp((a) => ({
    ...a, chMsgs: { ...a.chMsgs, [chId]: [...(a.chMsgs[chId] || []), m] },
  }));
  const appendDm = (peerId, m) => setApp((a) => ({
    ...a, dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), m] },
  }));

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

  // Payments ride the same rails: ecash over Bluetooth in range, Lightning otherwise
  const sendPay = (peerId, sats) => {
    setApp((a) => {
      const peer = BC_DATA.peers.find((p) => p.id === peerId);
      const via = peer && peer.inRange ? 'mesh' : 'internet';
      return {
        ...a,
        balance: Math.max(0, (a.balance || 0) - sats),
        dmMsgs: { ...a.dmMsgs, [peerId]: [...(a.dmMsgs[peerId] || []), { pay: true, mine: true, amount: sats, via, state: 'sealed', time: bcNow() }] },
      };
    });
    setTimeout(() => setApp((a) => {
      const list = (a.dmMsgs[peerId] || []).slice();
      for (let i = list.length - 1; i >= 0; i--) {
        if (list[i].pay && list[i].mine && list[i].state === 'sealed') { list[i] = { ...list[i], state: 'claimed' }; break; }
      }
      return { ...a, dmMsgs: { ...a.dmMsgs, [peerId]: list } };
    }), 2600);
  };
  const claimPay = (peerId, idx) => setApp((a) => {
    const list = (a.dmMsgs[peerId] || []).slice();
    const m = list[idx];
    if (!m || !m.pay || m.mine || m.state !== 'sealed') return a;
    list[idx] = { ...m, state: 'claimed' };
    return { ...a, balance: (a.balance || 0) + m.amount, dmMsgs: { ...a.dmMsgs, [peerId]: list } };
  });

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

  const onCommand = (ctx, cmd) => {
    if (cmd === 'who' || cmd === 'msg') { push('nearby'); return; }
    if (cmd === 'slap') {
      const m = { action: true, text: '* ' + (app.nick || 'you') + ' slaps ' + ctx.target + ' around a bit with a large trout', time: bcNow() };
      if (ctx.type === 'ch') appendCh(ctx.id, m); else appendDm(ctx.id, m);
    }
  };

  const top = app.stack[app.stack.length - 1];
  const screenKey = app.stack.length + '-' + top.s + '-' + (top.id || '');
  let screen = null;
  if (top.s === 'home') {
    screen = <HomeScreen key={screenKey} app={app} t={t} nav={app.nav} push={push} toggleNetwork={toggleNetwork} onWipe={wipe} />;
  } else if (top.s === 'channel') {
    screen = <ChannelScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} chId={top.id} onSend={sendCh} onCommand={onCommand} onMedia={sendMediaCh} onVoice={sendVoiceCh} />;
  } else if (top.s === 'dm') {
    screen = <DMScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} peerId={top.id} onSend={sendDm} onCommand={onCommand} onVerify={(pid) => setApp((a) => ({ ...a, verified: { ...a.verified, [pid]: true } }))} onPay={(sats) => sendPay(top.id, sats)} onClaimPay={claimPay} openPay={!!top.pay} onMedia={sendMediaDm} onVoice={sendVoiceDm} />;
  } else if (top.s === 'nearby') {
    screen = <SonarScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} />;
  } else if (top.s === 'call') {
    const cpeer = BC_DATA.peers.find((p) => p.id === top.id) || BC_DATA.peers[0];
    screen = <CallView key={screenKey} peer={cpeer} kind={top.kind} nick={app.nick} transport={cpeer.inRange ? 'mesh' : 'internet'} onEnd={(sec) => endCall(top.id, top.kind, sec)} />;
  } else if (top.s === 'settings') {
    screen = <SettingsScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} mode={t.mode} onToggleMode={() => setTweak('mode', t.mode === 'dark' ? 'light' : 'dark')} toggleNetwork={toggleNetwork} onWipe={wipe} onPref={setPref} />;
  } else if (top.s === 'profile') {
    screen = <ProfileScreen key={screenKey} app={app} nav={app.nav} pop={pop} onRename={(n) => setApp((a) => ({ ...a, nick: n }))} />;
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

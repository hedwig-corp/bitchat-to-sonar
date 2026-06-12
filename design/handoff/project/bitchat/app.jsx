// bitchat — app shell: state, navigation, tweaks, device frame

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "mode": "light",
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
    v: 1,
    onboarded: false,
    nick: '',
    network: 'online',
    verified: false,
    read: {},
    stack: [{ s: 'home' }],
    nav: '',
    chMsgs: { centro: BC_DATA.chMsgs.slice(), city: [] },
    dmMsgs: { maya: BC_DATA.dmMsgs.slice() },
  };
}

function bcLoadState() {
  try {
    const s = JSON.parse(localStorage.getItem('bc_proto_v1'));
    if (s && s.v === 1) {
      const d = bcFreshState();
      return { ...d, ...s, nav: '', chMsgs: { ...d.chMsgs, ...(s.chMsgs || {}) }, dmMsgs: { ...d.dmMsgs, ...(s.dmMsgs || {}) } };
    }
  } catch (e) { /* fall through */ }
  return bcFreshState();
}

function BitchatApp() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [app, setApp] = React.useState(bcLoadState);
  const [scale, setScale] = React.useState(1);

  React.useEffect(() => {
    try { localStorage.setItem('bc_proto_v1', JSON.stringify(app)); } catch (e) { /* ignore */ }
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
  const sendDm = (peerId, text) => setApp((a) => ({
    ...a,
    dmMsgs: {
      ...a.dmMsgs,
      [peerId]: [...(a.dmMsgs[peerId] || []), {
        mine: true, text, time: bcNow(),
        via: a.network === 'online' ? 'internet' : 'mesh', state: 'Delivered',
      }],
    },
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
    screen = <HomeScreen key={screenKey} app={app} t={t} nav={app.nav} push={push} toggleNetwork={toggleNetwork} />;
  } else if (top.s === 'channel') {
    screen = <ChannelScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} chId={top.id} onSend={sendCh} onCommand={onCommand} />;
  } else if (top.s === 'dm') {
    screen = <DMScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} peerId={top.id} onSend={sendDm} onCommand={onCommand} onVerify={() => setApp((a) => ({ ...a, verified: true }))} />;
  } else if (top.s === 'nearby') {
    screen = <NearbyScreen key={screenKey} app={app} nav={app.nav} pop={pop} push={push} />;
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
                : <Onboarding initialNick={app.nick} onDone={(n) => setApp((a) => ({ ...a, onboarded: true, nick: n, stack: [{ s: 'home' }], nav: '' }))} />}
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

ReactDOM.createRoot(document.getElementById('root')).render(<BitchatApp />);

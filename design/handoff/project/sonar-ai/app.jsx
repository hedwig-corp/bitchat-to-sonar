// Sonar AI — app shell: state, routing, tweaks, device frame

const AI_TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "mode": "dark",
  "direction": "quiet",
  "bubbles": "filled",
  "radius": 18,
  "typeface": "Figtree"
}/*EDITMODE-END*/;

const AI_FONTS = {
  'Figtree': "'Figtree', system-ui, sans-serif",
  'Nunito Sans': "'Nunito Sans', system-ui, sans-serif",
  'System': "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', system-ui, sans-serif",
};

function aiFreshState() {
  return {
    v: 2,
    onboarded: false,
    nick: 'quietfox',
    balance: 182400,
    defaultModel: 'pocket',
    stack: [{ s: 'home' }],
    nav: '',
    prefs: { sync: true, backup: true, payper: false },
    msgs: { 'c-day': AI_DATA.msgs['c-day'].slice(), 'c-node': AI_DATA.msgs['c-node'].slice(), 'c-brief': AI_DATA.msgs['c-brief'].slice() },
    chatModel: {},
    grants: {},
    connected: { calendar: true, files: true, wallet: true, web: true, home: true },
    installed: { recap: true, translate: true, satbrief: true, packing: true },
    memory: AI_DATA.memory.slice(),
  };
}

function aiLoadState() {
  try {
    const s = JSON.parse(localStorage.getItem('sn_ai_proto_v1'));
    if (s && s.v === 2) {
      const d = aiFreshState();
      return { ...d, ...s, nav: '', prefs: { ...d.prefs, ...(s.prefs || {}) }, msgs: { ...d.msgs, ...(s.msgs || {}) } };
    }
  } catch (e) { /* fresh */ }
  return aiFreshState();
}

function SonarAIApp() {
  const [t, setTweak] = useTweaks(AI_TWEAK_DEFAULTS);
  const [app, setApp] = React.useState(aiLoadState);
  const [scale, setScale] = React.useState(1);

  React.useEffect(() => {
    try { localStorage.setItem('sn_ai_proto_v1', JSON.stringify(app)); } catch (e) { /* ignore */ }
  }, [app]);
  React.useEffect(() => { document.body.dataset.mode = t.mode; }, [t.mode]);
  React.useEffect(() => {
    const fit = () => setScale(Math.min(1, (window.innerHeight - 56) / 900));
    fit(); window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);

  const push = (s, params) => setApp((a) => ({ ...a, stack: [...a.stack, { s, ...(params || {}) }], nav: 'push' }));
  const pop = () => setApp((a) => ({ ...a, stack: a.stack.length > 1 ? a.stack.slice(0, -1) : a.stack, nav: 'pop' }));
  const setPref = (k, v) => setApp((a) => ({ ...a, prefs: { ...a.prefs, [k]: v } }));

  const appendMsg = (chatId, m) => setApp((a) => ({ ...a, msgs: { ...a.msgs, [chatId]: [...(a.msgs[chatId] || []), m] } }));
  const setChatModel = (chatId, id) => setApp((a) => ({ ...a, chatModel: { ...a.chatModel, [chatId]: id } }));
  const grant = (chatId, server, toggle) => setApp((a) => {
    const g = { ...(a.grants[chatId] || {}) };
    if (toggle) { if (g[server]) delete g[server]; else g[server] = true; }
    else g[server] = true;
    return { ...a, grants: { ...a.grants, [chatId]: g } };
  });
  const retitle = (chatId, title) => {
    const c = AI_DATA.chats.find((x) => x.id === chatId);
    if (c) { c.title = title; c.time = 'now'; }
    setApp((a) => ({ ...a }));
  };
  const spend = (sats) => setApp((a) => ({ ...a, balance: Math.max(0, a.balance - sats) }));
  const newChat = () => {
    const id = 'c' + Date.now().toString(36);
    AI_DATA.chats = [{ id, title: 'New chat', model: app.defaultModel, time: 'now', preview: '' }, ...AI_DATA.chats];
    setApp((a) => ({ ...a, msgs: { ...a.msgs, [id]: [] }, stack: [...a.stack, { s: 'chat', id }], nav: 'push' }));
  };
  const toggleConnector = (id) => setApp((a) => ({ ...a, connected: { ...a.connected, [id]: !a.connected[id] } }));
  const installSkill = (id) => setApp((a) => ({ ...a, installed: { ...a.installed, [id]: !a.installed[id] } }));
  const deleteMemory = (id) => setApp((a) => ({ ...a, memory: a.memory.filter((m) => m.id !== id) }));
  const wipe = () => { localStorage.removeItem('sn_ai_proto_v1'); AI_DATA.chats = AI_DATA.chats.filter((c) => ['c-day', 'c-node', 'c-brief'].includes(c.id)); setApp(aiFreshState()); };

  const top = app.stack[app.stack.length - 1];
  const key = app.stack.length + '-' + top.s + '-' + (top.id || '');
  let screen = null;
  if (top.s === 'home') screen = <AiHomeScreen key={key} app={app} nav={app.nav} push={push} onNewChat={newChat} />;
  else if (top.s === 'chat') screen = <AiChatScreen key={key} app={app} nav={app.nav} pop={pop} chatId={top.id} onAppend={appendMsg} onSetModel={setChatModel} onGrant={grant} onRetitle={retitle} onSpend={spend} />;
  else if (top.s === 'connectors') screen = <AiConnectorsScreen key={key} app={app} nav={app.nav} pop={pop} onToggle={toggleConnector} />;
  else if (top.s === 'skills') screen = <AiSkillsScreen key={key} app={app} nav={app.nav} pop={pop} onInstall={installSkill} />;
  else if (top.s === 'memory') screen = <AiMemoryScreen key={key} app={app} nav={app.nav} pop={pop} onDelete={deleteMemory} />;
  else if (top.s === 'settings') screen = <AiSettingsScreen key={key} app={app} nav={app.nav} pop={pop} push={push} mode={t.mode} onToggleMode={() => setTweak('mode', t.mode === 'dark' ? 'light' : 'dark')} onPref={setPref} />;
  else if (top.s === 'defaultmodel') screen = <AiDefaultModelScreen key={key} app={app} nav={app.nav} pop={pop} onPick={(id) => { setApp((a) => ({ ...a, defaultModel: id, stack: a.stack.slice(0, -1), nav: 'pop' })); }} />;
  else if (top.s === 'wipe') { screen = null; }

  const fontStack = AI_FONTS[t.typeface] || AI_FONTS.Figtree;

  return (
    <React.Fragment>
      <div style={{ width: 402 * scale, height: 880 * scale }}>
        <div style={{ transform: 'scale(' + scale + ')', transformOrigin: 'top left' }}>
          <IOSDevice dark={t.mode === 'dark'} width={402} height={874}>
            <div className="bc-app" data-mode={t.mode} data-direction={t.direction} data-bubble={t.bubbles}
              style={{ '--r': t.radius + 'px', fontFamily: fontStack }}>
              {!app.onboarded ?
                <SecretOnboarding onDone={(o) => setApp((a) => ({ ...a, onboarded: true, defaultModel: o.defaultModel, prefs: { ...a.prefs, payper: o.payper }, stack: [{ s: 'home' }], nav: '' }))} />
                : top.s === 'wipe' ?
                <div className="bc-screen" data-nav="push">
                  <NavHeader onBack={pop}><div className="bc-headcenter"><div className="bc-hname"><span>Wipe assistant data</span></div></div></NavHeader>
                  <div className="ai-hero">
                    <span className="ai-heromark" style={{ background: 'rgba(212,58,62,0.12)', color: 'var(--danger)' }}><BCIcon name="trash" size={26} /></span>
                    <span className="ai-herotitle">Erase everything?</span>
                    <span className="ai-herosub">Chats, memory and tool grants are deleted here and from your encrypted Nostr backup. This cannot be undone.</span>
                    <div style={{ width: '100%', marginTop: 22, display: 'flex', flexDirection: 'column', gap: 8 }}>
                      <button className="bc-primary danger" onClick={wipe}>Wipe everything</button>
                      <button className="bc-ghost" onClick={pop}>Cancel</button>
                    </div>
                  </div>
                </div>
                : screen}
            </div>
          </IOSDevice>
        </div>
      </div>
      <TweaksPanel>
        <TweakSection label="Appearance" />
        <TweakRadio label="Mode" value={t.mode} options={['light', 'dark']} onChange={(v) => setTweak('mode', v)} />
        <TweakRadio label="Direction" value={t.direction} options={['quiet', 'warm', 'soft']} onChange={(v) => setTweak('direction', v)} />
        <TweakRadio label="My bubbles" value={t.bubbles} options={['filled', 'tinted']} onChange={(v) => setTweak('bubbles', v)} />
        <TweakSlider label="Bubble radius" value={t.radius} min={10} max={24} unit="px" onChange={(v) => setTweak('radius', v)} />
        <TweakSelect label="Typeface" value={t.typeface} options={['Figtree', 'Nunito Sans', 'System']} onChange={(v) => setTweak('typeface', v)} />
        <TweakSection label="Demo" />
        <TweakButton label="Replay onboarding" onClick={() => setApp((a) => ({ ...a, onboarded: false, stack: [{ s: 'home' }], nav: '' }))} />
        <TweakButton label="Reset demo data" secondary onClick={wipe} />
      </TweaksPanel>
    </React.Fragment>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<SonarAIApp />);

// Sonar AI — settings + privacy dashboard

function AiSettingsScreen({ app, nav, pop, push, mode, onToggleMode, onPref }) {
  return (
    <div className="bc-screen" data-nav={nav}>
      <NavHeader onBack={pop}>
        <div className="bc-headcenter"><div className="bc-hname"><span>Settings</span></div></div>
      </NavHeader>
      <div className="bc-scroll" data-screen-label="Settings">
        <button className="st-prof" onClick={() => {}}>
          <Avatar name={app.nick || 'quietfox'} size={52} />
          <span className="st-profmain">
            <span className="st-profname">{app.nick || 'quietfox'}</span>
            <span className="st-profkey">{AI_DATA.npub}</span>
          </span>
          <BCIcon name="chevron" size={16} style={{ color: 'var(--text3)' }} />
        </button>
        <div className="st-note">Same identity as Sonar Messenger — one key, one name, every device.</div>

        <div className="bc-sect">Privacy — this week</div>
        <div className="st-card">
          <div className="bk-stats" style={{ padding: '12px 12px 4px' }}>
            <div className="bk-stat"><b>84</b><span>on-device</span></div>
            <div className="bk-stat"><b>12</b><span>to your node</span></div>
            <div className="bk-stat"><b>3</b><span>paid runs</span></div>
            <div className="bk-stat"><b>0</b><span>third parties</span></div>
          </div>
          <div className="pv-note" style={{ margin: '8px 12px 12px' }}><BCIcon name="shieldCheck" size={15} />No account, no server-side history. Every remote run was end-to-end encrypted to compute you chose.</div>
        </div>

        <div className="bc-sect">Assistant</div>
        <div className="st-card">
          <StRowX icon="cpu" tone="cyan" label="Default model" value={aiModel(app.defaultModel).name} onClick={() => push('defaultmodel')} />
          <StRowX icon="plug" tone="cyan" label="Connectors" value={AI_DATA.connectors.filter((c) => app.connected[c.id]).length + ' connected'} onClick={() => push('connectors')} />
          <StRowX icon="sparkle" tone="ai" label="Skills" value={AI_DATA.skills.filter((s) => app.installed[s.id]).length + ' installed'} onClick={() => push('skills')} />
          <StRowX icon="brain" label="Memory" value={app.memory.length + ' notes'} onClick={() => push('memory')} />
        </div>

        <div className="bc-sect">Sync &amp; backup</div>
        <div className="st-card">
          <StRowX icon="globe" label="History sync" small="Encrypted to your key · via Nostr relays" toggle on={app.prefs.sync} onClick={() => onPref('sync', !app.prefs.sync)} />
          <StRowX icon="backup" label="Encrypted backup" small="Automatic · relays see ciphertext only" toggle on={app.prefs.backup} onClick={() => onPref('backup', !app.prefs.backup)} />
        </div>

        <div className="bc-sect">Bitcoin</div>
        <div className="st-card">
          <StRowX icon="bolt" tone="gold" label="Wallet balance" value={(app.balance / 1000).toFixed(1).replace('.0', '') + 'k sats'} onClick={() => {}} />
          <StRowX icon="coin" tone="gold" label="Pay-per-request models" small="Anonymous Lightning payment per run" toggle on={app.prefs.payper} onClick={() => onPref('payper', !app.prefs.payper)} />
        </div>

        <div className="bc-sect">Appearance</div>
        <div className="st-card">
          <StRowX icon="moon" label="Dark mode" toggle on={mode === 'dark'} onClick={onToggleMode} />
        </div>

        <div className="st-card" style={{ marginTop: 14 }}>
          <StRowX icon="trash" tone="red" danger label="Wipe assistant data" small="Chats, memory and grants — gone everywhere" onClick={() => push('wipe')} />
        </div>
      </div>
    </div>);
}

function AiDefaultModelScreen({ app, nav, pop, onPick }) {
  return (
    <div className="bc-screen" data-nav={nav}>
      <NavHeader onBack={pop}>
        <div className="bc-headcenter"><div><div className="bc-hname"><span>Default model</span></div><div className="bc-hsub">Used for every new chat</div></div></div>
      </NavHeader>
      <div className="bc-scroll" data-screen-label="Default model">
        <div className="st-card" style={{ padding: '4px 6px' }}>
          {AI_DATA.models.filter((m) => app.prefs.payper || m.where !== 'dvm').map((m) =>
            <button key={m.id} className="md-row" onClick={() => onPick(m.id)}>
              <span className={'md-ic' + (aiRemote(m) ? ' remote' : '')}><AIIcon name={m.where === 'device' ? 'cpu' : m.where === 'node' ? 'drive' : 'sparkle'} size={18} /></span>
              <span className="md-main">
                <span className="md-name">{m.name}</span>
                <span className="md-sub">{m.sub}</span>
              </span>
              {m.price && <span className="md-price">{m.price} sats</span>}
              <span className={'ng-check' + (app.defaultModel === m.id ? ' on' : '')}>{app.defaultModel === m.id && <BCIcon name="check" size={13} weight={2.6} />}</span>
            </button>)}
        </div>
        {!app.prefs.payper && <div className="st-note" style={{ paddingTop: 8 }}>Paid pay-per-request models are hidden — turn them on under Bitcoin.</div>}
        <div className="st-note" style={{ paddingTop: 8 }}>You can switch models per chat any time from the chat header — the bubble color always tells you where a prompt went.</div>
      </div>
    </div>);
}

Object.assign(window, { AiSettingsScreen, AiDefaultModelScreen });

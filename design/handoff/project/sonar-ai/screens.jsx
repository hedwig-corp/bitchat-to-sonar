// Sonar AI — home, connectors, skills, memory screens

function AiHomeScreen({ app, nav, push, onNewChat }) {
  return (
    <div className="bc-screen" data-nav={nav}>
      <div className="bc-header">
        <button className="bc-iconbtn" onClick={() => push('settings')} style={{ width: 44 }}>
          <Avatar name={app.nick || 'quietfox'} size={34} />
        </button>
        <div className="bc-htitle" data-screen-label="Home">secret</div>
        <button className="bc-iconbtn" onClick={onNewChat}><AIIcon name="compose" size={21} /></button>
      </div>
      <div className="ai-sync">
        <button className="ai-syncchip" onClick={() => push('settings')}>
          <span className="bc-dot n sm"></span>
          <span><b>Synced</b> · 2 devices · encrypted over Nostr</span>
        </button>
      </div>
      <div className="bc-scroll">
        <div className="bc-list">
          {AI_DATA.chats.map((c) => {
            const model = aiModel(app.chatModel[c.id] || c.model);
            const msgs = app.msgs[c.id] || [];
            const last = msgs.length ? msgs[msgs.length - 1] : null;
            return (
              <ConvRow key={c.id}
                av={<span className={'md-ic' + (aiRemote(model) ? ' remote' : '')} style={{ width: 46, height: 46, borderRadius: 15 }}><AIIcon name={model.where === 'device' ? 'cpu' : model.where === 'node' ? 'drive' : 'sparkle'} size={20} /></span>}
                title={c.title}
                sub={<span>{(last && (last.text || (last.tool && 'Used ' + (aiConn(last.server) || {}).name))) || c.preview}</span>}
                time={c.time}
                onClick={() => push('chat', { id: c.id })} />);
          })}
        </div>
        <div className="bc-sect">Toolbox</div>
        <div className="st-card">
          <StRowX icon="plug" tone="cyan" label="Connectors" value={AI_DATA.connectors.filter((c) => app.connected[c.id]).length + ' connected'} onClick={() => push('connectors')} />
          <StRowX icon="sparkle" tone="ai" label="Skills" value={AI_DATA.skills.filter((s) => app.installed[s.id]).length + ' installed'} onClick={() => push('skills')} />
          <StRowX icon="brain" label="Memory" value={app.memory.length + ' notes'} onClick={() => push('memory')} />
        </div>
      </div>
      <div className="sn-fab">
        <button className="sn-search" onClick={onNewChat}><BCIcon name="search" size={17} />Ask anything…</button>
        <button className="sn-compose ai" onClick={onNewChat}><AIIcon name="sparkle" size={21} /></button>
      </div>
    </div>);
}

/* settings-style row (local clone; keeps sonar/settings.jsx out of the deps) */
function StRowX({ icon, tone = '', label, small, value, toggle, on, danger, onClick }) {
  return (
    <button className={'st-row' + (danger ? ' danger' : '')} onClick={onClick}>
      <span className={'st-icon ' + tone}><AIIcon name={icon} size={16} /></span>
      <span className="st-label">{label}{small && <small>{small}</small>}</span>
      {value && <span className="st-value">{value}</span>}
      {toggle ? <span className={'st-switch' + (on ? ' on' : '')}></span> : onClick && !toggle ? <BCIcon name="chevron" size={15} style={{ color: 'var(--text3)', flex: 'none' }} /> : null}
    </button>);
}

function AiConnectorsScreen({ app, nav, pop, onToggle }) {
  return (
    <div className="bc-screen" data-nav={nav}>
      <NavHeader onBack={pop}>
        <div className="bc-headcenter"><div><div className="bc-hname"><span>Connectors</span></div><div className="bc-hsub">MCP servers your assistant can use</div></div></div>
      </NavHeader>
      <div className="bc-scroll" data-screen-label="Connectors">
        {['device', 'node', 'web'].map((scope) =>
          <React.Fragment key={scope}>
            <div className="bc-sect">{scope === 'device' ? 'On this iPhone' : scope === 'node' ? 'On your node' : 'Goes out to the web'}</div>
            <div className="st-card">
              {AI_DATA.connectors.filter((c) => c.scope === scope).map((c) =>
                <div key={c.id} className="cp-cap" style={{ cursor: 'pointer' }} onClick={() => onToggle(c.id)}>
                  <span className={'cp-capic' + (scope !== 'device' ? '' : '')} style={scope !== 'device' ? { background: 'var(--net-soft)', color: 'var(--net-deep)' } : null}><AIIcon name={c.icon} size={16} /></span>
                  <span className="cp-capmain">
                    <span className="cp-caplabel" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>{c.name}{c.sensitive && <span className="cn-scope" style={{ background: 'var(--gold-soft)', color: 'var(--gold-deep)' }}>approval</span>}</span>
                    <span className="cp-capdesc">{c.desc}</span>
                    <span className="cn-tools">{c.tools.join(' · ')}</span>
                  </span>
                  <span className={'st-switch' + (app.connected[c.id] ? ' on' : '')}></span>
                </div>)}
            </div>
          </React.Fragment>)}
        <div className="st-note" style={{ paddingTop: 6 }}>Connectors speak MCP. Device connectors never leave the phone; node connectors are sealed to your node key; web connectors go out through a relay without your identity.</div>
      </div>
    </div>);
}

function AiSkillsScreen({ app, nav, pop, onInstall }) {
  const srcs = [
    { key: 'installed', label: 'Installed' },
    { key: 'mine', label: 'Made by you' },
    { key: 'nostr', label: 'Discovered on Nostr' },
  ];
  return (
    <div className="bc-screen" data-nav={nav}>
      <NavHeader onBack={pop}>
        <div className="bc-headcenter"><div><div className="bc-hname"><span>Skills</span></div><div className="bc-hsub">Reusable workflows for your assistant</div></div></div>
      </NavHeader>
      <div className="bc-scroll" data-screen-label="Skills">
        {srcs.map((s) =>
          <React.Fragment key={s.key}>
            <div className="bc-sect">{s.label}</div>
            <div className="st-card">
              {AI_DATA.skills.filter((k) => k.src === s.key).map((k) =>
                <div key={k.id} className="cp-cap">
                  <span className="cp-capic"><AIIcon name={k.icon} size={16} /></span>
                  <span className="cp-capmain">
                    <span className="cp-caplabel">{k.name}</span>
                    <span className="cp-capdesc">{k.desc}</span>
                    {k.src === 'nostr' && <span className="cn-tools">by {k.author} · <span className="sk-zaps"><BCIcon name="bolt" size={10} weight={2.4} />{k.zaps}</span></span>}
                    {k.uses.length > 0 && k.src !== 'nostr' && <span className="cn-tools">uses {k.uses.join(', ')}</span>}
                  </span>
                  {k.src === 'nostr' &&
                    <button className={'sk-get' + (app.installed[k.id] ? ' done' : '')} onClick={() => onInstall(k.id)}>{app.installed[k.id] ? 'Installed' : 'Install'}</button>}
                </div>)}
            </div>
          </React.Fragment>)}
        <div className="st-note" style={{ paddingTop: 6 }}>Skills are signed by their author and reviewed locally before first run. Zaps are how the community pays skill authors.</div>
      </div>
    </div>);
}

function AiMemoryScreen({ app, nav, pop, onDelete }) {
  return (
    <div className="bc-screen" data-nav={nav}>
      <NavHeader onBack={pop}>
        <div className="bc-headcenter"><div><div className="bc-hname"><span>Memory</span></div><div className="bc-hsub">What your assistant remembers — stored on-device</div></div></div>
      </NavHeader>
      <div className="bc-scroll" data-screen-label="Memory">
        <div className="bc-sect">Notes</div>
        <div className="st-card">
          {app.memory.length === 0 && <div className="wallet-empty">Nothing remembered yet.</div>}
          {app.memory.map((m) =>
            <div key={m.id} className="mm-row">
              <span className="cp-capic" style={{ width: 30, height: 30 }}><AIIcon name="brain" size={15} /></span>
              <span className="mm-text">{m.text}<span className="mm-time">learned {m.time}</span></span>
              <button className="mm-del" onClick={() => onDelete(m.id)}><BCIcon name="trash" size={15} /></button>
            </div>)}
        </div>
        <div className="st-note" style={{ paddingTop: 6 }}>Memory never syncs in plaintext. It travels inside your encrypted Nostr backup, sealed with your key.</div>
      </div>
    </div>);
}

Object.assign(window, { AiHomeScreen, AiConnectorsScreen, AiSkillsScreen, AiMemoryScreen, StRowX });

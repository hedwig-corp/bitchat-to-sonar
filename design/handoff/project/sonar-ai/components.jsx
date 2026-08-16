// Sonar AI — shared components. Depends on BCIcon, Avatar, Sheet (sonar/components.jsx)

const AI_XICONS = {
  sparkle: <path d="M12 3.5c.7 3.9 2.7 5.9 6.6 6.6-3.9.7-5.9 2.7-6.6 6.6-.7-3.9-2.7-5.9-6.6-6.6 3.9-.7 5.9-2.7 6.6-6.6zM18.5 14.8c.4 2 1.4 3 3.4 3.4-2 .4-3 1.4-3.4 3.4-.4-2-1.4-3-3.4-3.4 2-.4 3-1.4 3.4-3.4z" />,
  cpu: <><rect x="6.5" y="6.5" width="11" height="11" rx="2.5" /><rect x="10" y="10" width="4" height="4" rx="1" /><path d="M9 6.5V3.8M15 6.5V3.8M9 20.2v-2.7M15 20.2v-2.7M6.5 9H3.8M6.5 15H3.8M20.2 9h-2.7M20.2 15h-2.7" /></>,
  plug: <><path d="M9 3.8v4M15 3.8v4" /><path d="M7 7.8h10v3.4a5 5 0 0 1-5 5 5 5 0 0 1-5-5z" /><path d="M12 16.2v4" /></>,
  wrench: <path d="M20 6.5a4.6 4.6 0 0 1-6.3 5.6l-6.5 6.5a1.9 1.9 0 0 1-2.7-2.7l6.5-6.5A4.6 4.6 0 0 1 16.6 3l-2.8 2.8 3.5 3.5z" />,
  brain: <><path d="M9.5 4.5A2.8 2.8 0 0 0 6 7.3a3 3 0 0 0-1.5 5.2A3 3 0 0 0 6.3 17c.3 1.6 1.6 2.7 3.2 2.5 1.2-.1 2-.9 2.5-2V6.7a2.7 2.7 0 0 0-2.5-2.2z" /><path d="M14.5 4.5A2.8 2.8 0 0 1 18 7.3a3 3 0 0 1 1.5 5.2A3 3 0 0 1 17.7 17c-.3 1.6-1.6 2.7-3.2 2.5-1.2-.1-2-.9-2.5-2V6.7a2.7 2.7 0 0 1 2.5-2.2z" /></>,
};

function AIIcon({ name, size = 20, weight = 1.8, style, className }) {
  if (!AI_XICONS[name]) return <BCIcon name={name} size={size} weight={weight} style={style} className={className} />;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={weight} strokeLinecap="round" strokeLinejoin="round" style={style} className={className} aria-hidden="true">
      {AI_XICONS[name]}</svg>);
}

const aiModel = (id) => AI_DATA.models.find((m) => m.id === id) || AI_DATA.models[0];
const aiRemote = (m) => m.where !== 'device';
const aiConn = (id) => AI_DATA.connectors.find((c) => c.id === id);

function ModelDot({ model, size }) {
  return <span className={'ai-modeldot' + (aiRemote(model) ? ' remote' : '')} style={size ? { width: size, height: size } : null}></span>;
}

/* user message — bubble colored by where the prompt is going */
function AiUserMsg({ m }) {
  return (
    <div className="bc-msg mine" data-via={m.via === 'device' ? 'mesh' : 'internet'}>
      <div className="bc-bubble">{m.text}
        <span className="bc-meta">{m.time}</span>
      </div>
    </div>);
}

/* assistant turn — bubble-less text with model label */
function AiTurn({ m, streaming }) {
  const model = aiModel(m.model);
  return (
    <div className="ai-turn">
      <span className="ai-label"><ModelDot model={model} />{model.name}</span>
      <span className="ai-text">{m.text}{streaming && <span className={'ai-cursor' + (aiRemote(model) ? ' remote' : '')}></span>}</span>
    </div>);
}

function AiThinking({ model }) {
  return (
    <div className="ai-turn">
      <span className="ai-label"><ModelDot model={model} />{model.name}</span>
      <span className="ai-think"><i></i><i></i><i></i></span>
    </div>);
}

/* MCP tool-call card — tap to expand args/result */
function ToolCard({ m, running }) {
  const [open, setOpen] = React.useState(false);
  const c = aiConn(m.server) || { name: m.server, icon: 'wrench', scope: 'device' };
  return (
    <div className="ai-tool" data-scope={c.scope}>
      <button className="ai-toolhead" onClick={() => setOpen(!open)}>
        <span className="ai-toolic"><AIIcon name={c.icon} size={16} /></span>
        <span className="ai-toolmain">
          <span className="ai-toolname">{c.name}</span>
          <span className="ai-toolfn">{m.server}.{m.name}</span>
        </span>
        {running
          ? <span className="ai-toolstate"><span className="ai-toolspin"></span></span>
          : <span className="ai-toolstate ok"><BCIcon name="check" size={13} weight={2.4} />done</span>}
      </button>
      {open && !running &&
        <div className="ai-toolbody">
          <div><span>args&nbsp;&nbsp;&nbsp;</span>{m.args}</div>
          <div><span>result&nbsp;</span>{m.result}</div>
        </div>}
    </div>);
}

function AiReceipt({ m }) {
  return <span className="ai-receipt"><BCIcon name="bolt" size={12} weight={2.2} />{m.sats} sats · paid over Lightning</span>;
}

/* model picker sheet */
function ModelSheet({ current, onPick, onClose, paid = true }) {
  const groups = [
    { label: 'On this iPhone', ids: AI_DATA.models.filter((m) => m.where === 'device') },
    { label: 'Your node', ids: AI_DATA.models.filter((m) => m.where === 'node') },
    { label: 'Pay per request · Nostr DVM', ids: paid ? AI_DATA.models.filter((m) => m.where === 'dvm') : [] },
  ].filter((g) => g.ids.length);
  return (
    <Sheet onClose={onClose} title="Choose a model">
      {groups.map((g) =>
        <React.Fragment key={g.label}>
          <div className="bc-sect" style={{ padding: '10px 10px 4px' }}>{g.label}</div>
          {g.ids.map((m) =>
            <button key={m.id} className="md-row" onClick={() => { onPick(m.id); onClose(); }}>
              <span className={'md-ic' + (aiRemote(m) ? ' remote' : '')}><AIIcon name={m.where === 'device' ? 'cpu' : m.where === 'node' ? 'drive' : 'sparkle'} size={18} /></span>
              <span className="md-main">
                <span className="md-name">{m.name}</span>
                <span className="md-sub">{m.desc}</span>
              </span>
              {m.price && <span className="md-price">{m.price} sats</span>}
              <span className={'ng-check' + (current === m.id ? ' on' : '')}>{current === m.id && <BCIcon name="check" size={13} weight={2.6} />}</span>
            </button>)}
        </React.Fragment>)}
      {!paid && <div className="bc-note" style={{ padding: '8px 12px 0' }}>Paid pay-per-request models are off — enable them in Settings → Bitcoin.</div>}
      <div className="bc-note" style={{ padding: '10px 12px 2px' }}>Cyan runs stay on the device. Indigo runs are end-to-end encrypted to the compute you chose — relays only ever see ciphertext.</div>
    </Sheet>);
}

/* per-chat tool access sheet */
function ToolsSheet({ grants, onToggle, onClose }) {
  return (
    <Sheet onClose={onClose} title="Tools in this chat">
      {AI_DATA.connectors.map((c) =>
        <button key={c.id} className="md-row" onClick={() => onToggle(c.id)}>
          <span className={'md-ic' + (c.scope !== 'device' ? ' remote' : '')}><AIIcon name={c.icon} size={17} /></span>
          <span className="md-main">
            <span className="md-name">{c.name}{c.sensitive && <span className="cn-scope" style={{ background: 'var(--gold-soft)', color: 'var(--gold-deep)' }}>asks every time</span>}</span>
            <span className="md-sub">{c.desc}</span>
          </span>
          <span className={'st-switch' + (grants[c.id] ? ' on' : '')}></span>
        </button>)}
      <div className="bc-note" style={{ padding: '10px 12px 2px' }}>Tools run over MCP. The model only sees what a tool returns — never your whole account.</div>
    </Sheet>);
}

/* permission sheet — resolves a paused run */
function PermSheet({ req, onAnswer }) {
  const c = aiConn(req.server);
  const payment = c.sensitive && !!req.amount;
  const sensitive = c.sensitive;
  const leaves = c.scope === 'web';
  return (
    <Sheet onClose={() => onAnswer('deny')} title="Permission">
      <div className="ai-perm">
        <span className={'ai-permic ' + (sensitive ? 'gold' : c.scope)}><AIIcon name={payment ? 'bolt' : c.icon} size={24} /></span>
        <div className="ai-permtitle">{payment ? 'Approve this payment?' : sensitive ? 'Let the assistant check your wallet?' : 'Use ' + c.name + '?'}</div>
        <div className="ai-permsub">{payment ? 'The assistant wants to pay from your wallet. Nothing moves without your approval.' : sensitive ? 'Read-only — it can see the balance, not move funds. Wallet tools ask every time.' : 'The assistant wants to call a tool on ' + c.name + '.'}</div>
        <div className="ai-permfn">{req.server}.{req.name} {req.args}</div>
        {payment && <div className="ai-permamt">{req.amount}</div>}
        {leaves && <div className="ai-permnote"><BCIcon name="globe" size={14} />This query <b>leaves your device</b> — it goes out through a relay without your identity attached.</div>}
      </div>
      <div className="bc-sheetactions">
        <button className={'bc-primary' + (sensitive ? '' : c.scope !== 'device' ? ' net' : '')} onClick={() => onAnswer('once')}>{payment ? 'Approve payment' : sensitive ? 'Allow' : 'Allow once'}</button>
        {!sensitive && <button className="bc-ghost" onClick={() => onAnswer('always')}>Always allow in this chat</button>}
        <button className="bc-ghost" onClick={() => onAnswer('deny')} style={{ color: 'var(--danger)' }}>Don’t allow</button>
      </div>
    </Sheet>);
}

Object.assign(window, { AIIcon, aiModel, aiRemote, aiConn, ModelDot, AiUserMsg, AiTurn, AiThinking, ToolCard, AiReceipt, ModelSheet, ToolsSheet, PermSheet });

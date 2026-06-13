// bitchat — reusable components (avatars, chips, rows, bubbles, composer, sheets)
// Depends on: BCIcon (icons.jsx), React globals.

function bcHash(s) {
  let h = 2166136261 >>> 0;
  for (const ch of String(s)) {
    h = (h ^ ch.codePointAt(0)) >>> 0;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h;
}

/* ── Identicon avatar: deterministic hue + mirrored pixel grid ── */
function Avatar({ name, size = 44, presence, style }) {
  const h = bcHash(name || '?');
  const hue = h % 360;
  const lite = `hsl(${hue} 64% 70%)`;
  const liter = `hsl(${hue} 72% 82%)`;
  const cells = [];
  let any = false;
  for (let r = 0; r < 5; r++) {
    for (let c = 0; c < 3; c++) {
      if ((h >>> (r * 3 + c)) & 1) {
        any = true;
        const fill = ((h >>> (r + c + 4)) & 1) ? lite : liter;
        cells.push(<rect key={r + '.' + c} x={8 + c * 10} y={8 + r * 10} width="10" height="10" fill={fill} />);
        if (c < 2) cells.push(<rect key={r + 'm' + c} x={8 + (4 - c) * 10} y={8 + r * 10} width="10" height="10" fill={fill} />);
      }
    }
  }
  if (!any) cells.push(<rect key="f" x="28" y="8" width="10" height="50" fill={lite} />);
  return (
    <span className="bc-avwrap" style={{ width: size, height: size, ...style }}>
      <svg width={size} height={size} viewBox="0 0 66 66" style={{ borderRadius: Math.round(size * 0.31), display: 'block' }}>
        <rect width="66" height="66" fill={`hsl(${hue} 40% 36%)`} />
        {cells}
      </svg>
      {presence && <span className="bc-presence"></span>}
    </span>
  );
}

function PlaceTile({ size = 44, icon = 'pin' }) {
  return (
    <span className="bc-placetile" style={{ width: size, height: size }}>
      <BCIcon name={icon} size={Math.round(size * 0.5)} />
    </span>
  );
}

/* ── Network status chip — tap to simulate going offline/online ── */
function StatusChip({ network, meshCount, variant = 'pill', onToggle }) {
  const online = network === 'online';
  const label = online ? 'Online' : 'Offline';
  const desc = online ? 'reaches anyone' : `${meshCount} nearby on mesh`;
  const hint = 'Simulated — tap to switch';
  if (variant === 'banner') {
    return (
      <button className={'bc-chipbanner' + (online ? '' : ' off')} onClick={onToggle} title={hint}>
        <span className={'bc-dot ' + (online ? 'g' : 'a')}></span>
        <span className="bc-chiptext"><b>{label}</b> · {desc}</span>
        <span className="bc-chipvia"><BCIcon name={online ? 'globe' : 'mesh'} size={15} /></span>
      </button>
    );
  }
  return (
    <div className="bc-chiprow">
      <button className="bc-chip" onClick={onToggle} title={hint}>
        <span className={'bc-dot ' + (online ? 'g' : 'a')}></span>
        <span className="bc-chiptext"><b>{label}</b> · {desc}</span>
      </button>
    </div>
  );
}

/* ── Conversation / list row ── */
function ConvRow({ av, title, extra, sub, time, unread, onClick }) {
  return (
    <button className="bc-row" onClick={onClick}>
      {av}
      <span className="bc-rowmain">
        <span className="bc-rowtitle">{title}{extra}</span>
        <span className="bc-rowsub">{sub}</span>
      </span>
      <span className="bc-rowend">
        {time ? <span className="bc-time">{time}</span> : null}
        {unread ? <span className="bc-unread">{unread}</span> : null}
      </span>
    </button>
  );
}

function SectionLabel({ children }) {
  return <div className="bc-sect">{children}</div>;
}

/* ── Chat header ── */
function NavHeader({ onBack, children, trailing, hairline = true }) {
  return (
    <div className={'bc-header' + (hairline ? ' hl' : '')}>
      {onBack && (
        <button className="bc-iconbtn" onClick={onBack} aria-label="Back">
          <BCIcon name="back" size={21} weight={2.1} />
        </button>
      )}
      <div className="bc-headcenter">{children}</div>
      {trailing}
    </div>
  );
}

/* ── Privacy / public banners ── */
function Banner({ icon, tone = '', children, action }) {
  return (
    <div className={'bc-banner ' + tone}>
      <BCIcon name={icon} size={16} weight={2} />
      <span className="bc-bannertext">{children}</span>
      {action}
    </div>
  );
}

/* ── Message bubble + list ── */
function MsgBubble({ m, showAuthor, cont, showState }) {
  const hue = bcHash(m.author || '') % 360;
  return (
    <div className={'bc-msg' + (m.mine ? ' mine' : '') + (cont ? ' cont' : '')}>
      {showAuthor && (
        <div className="bc-author" style={{ color: `hsl(${hue} var(--author-s) var(--author-l))` }}>{m.author}</div>
      )}
      <div className="bc-bubble">
        {m.text}
        <span className="bc-meta">
          {m.time}
          {m.via ? <BCIcon name={m.via === 'mesh' ? 'mesh' : 'globe'} size={11} weight={2.2} /> : null}
        </span>
      </div>
      {showState && m.state ? (
        <div className="bc-state"><BCIcon name="check" size={11} weight={2.6} />{m.state} · {m.via}</div>
      ) : null}
    </div>
  );
}

function MsgList({ msgs, showAuthors }) {
  const ref = React.useRef(null);
  React.useEffect(() => {
    if (ref.current) ref.current.scrollTop = ref.current.scrollHeight;
  }, [msgs.length]);
  return (
    <div className="bc-msgs" ref={ref}>
      <div className="bc-datechip">Today</div>
      {msgs.map((m, i) => {
        if (m.action) return <div key={i} className="bc-action-msg">{m.text}</div>;
        const prev = msgs[i - 1];
        const cont = !!prev && !prev.action && prev.author === m.author && !!prev.mine === !!m.mine;
        return (
          <MsgBubble
            key={i} m={m} cont={cont}
            showAuthor={showAuthors && !m.mine && !cont}
            showState={!!m.mine && i === msgs.length - 1}
          />
        );
      })}
    </div>
  );
}

/* ── Composer with "+" actions and "/" command layer ── */
const BC_COMMANDS = [
  ['who', 'See who\u2019s nearby'],
  ['msg', 'Message someone'],
  ['slap', 'Classic IRC slap'],
];

function Composer({ placeholder, onSend, onPlus, onCommand }) {
  const [text, setText] = React.useState('');
  const slash = text.startsWith('/');
  const send = () => {
    const tx = text.trim();
    if (!tx) return;
    if (tx.startsWith('/')) {
      onCommand && onCommand(tx.slice(1).split(' ')[0].toLowerCase());
    } else {
      onSend(tx);
    }
    setText('');
  };
  return (
    <div className="bc-composerwrap">
      {slash && (
        <div className="bc-cmdstrip">
          {BC_COMMANDS.map(([c, d]) => (
            <button key={c} className="bc-cmd" onClick={() => { onCommand && onCommand(c); setText(''); }}>
              <span className="bc-cmdname">/{c}</span>
              <span className="bc-cmddesc">{d}</span>
            </button>
          ))}
        </div>
      )}
      <div className="bc-composer">
        <button className="bc-plusbtn" onClick={onPlus} aria-label="Actions">
          <BCIcon name="plus" size={19} weight={2.1} />
        </button>
        <div className="bc-fieldwrap">
          <input
            className="bc-input" type="text" value={text}
            placeholder={placeholder}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') send(); }}
          />
        </div>
        <button className={'bc-sendbtn' + (text.trim() ? ' on' : '')} onClick={send} aria-label="Send">
          <BCIcon name="send" size={17} weight={2.3} />
        </button>
      </div>
    </div>
  );
}

/* ── Bottom sheet ── */
function Sheet({ onClose, title, children }) {
  return (
    <div className="bc-scrim" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="bc-sheet">
        <div className="bc-grabber"></div>
        {title ? <div className="bc-sheettitle">{title}</div> : null}
        {children}
      </div>
    </div>
  );
}

function ActionRow({ icon, label, desc, onClick }) {
  return (
    <button className="bc-actionrow" onClick={onClick}>
      <span className="bc-actionicon"><BCIcon name={icon} size={19} /></span>
      <span className="bc-actionmain">
        <span className="bc-actionlabel">{label}</span>
        {desc ? <div className="bc-actiondesc">{desc}</div> : null}
      </span>
      <BCIcon name="chevron" size={14} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
    </button>
  );
}

function Bars({ n }) {
  return (
    <span className="bc-bars">
      <i className={n >= 1 ? 'on' : ''}></i>
      <i className={n >= 2 ? 'on' : ''}></i>
      <i className={n >= 3 ? 'on' : ''}></i>
    </span>
  );
}

Object.assign(window, {
  bcHash, Avatar, PlaceTile, StatusChip, ConvRow, SectionLabel,
  NavHeader, Banner, MsgBubble, MsgList, Composer, Sheet, ActionRow, Bars,
});

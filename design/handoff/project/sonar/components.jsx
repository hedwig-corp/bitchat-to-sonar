// Sonar — reusable components (avatars, chips, rows, bubbles, composer, sheets)
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
      if (h >>> r * 3 + c & 1) {
        any = true;
        const fill = h >>> r + c + 4 & 1 ? lite : liter;
        cells.push(<rect key={r + '.' + c} x={8 + c * 10} y={8 + r * 10} width="10" height="10" fill={fill} />);
        if (c < 2) cells.push(<rect key={r + 'm' + c} x={8 + (4 - c) * 10} y={8 + r * 10} width="10" height="10" fill={fill} />);
      }
    }
  }
  if (!any) cells.push(<rect key="f" x="28" y="8" width="10" height="50" fill={lite} />);
  return (
    <span className="bc-avwrap" style={{ width: size, height: size, ...style }}>
      <svg width={size} height={size} viewBox="0 0 66 66" style={{ borderRadius: '50%', display: 'block' }}>
        <rect width="66" height="66" fill={`hsl(${hue} 40% 36%)`} />
        {cells}
      </svg>
      {presence && <span className="bc-presence"></span>}
    </span>);

}

function PlaceTile({ size = 44, icon = 'pin' }) {
  return (
    <span className="bc-placetile" style={{ width: size, height: size }}>
      <BCIcon name={icon} size={Math.round(size * 0.46)} />
    </span>);

}

/* Supporter badge — shown next to the name of anyone who funds Sonar (Signal-style) */
function SupporterBadge({ size = 15, title = 'Sonar supporter' }) {
  return (
    <span className="bc-supporter" style={{ width: size, height: size }} title={title} aria-label={title}>
      <BCIcon name="heart" size={Math.round(size * 0.62)} />
    </span>);
}

/* Group avatar: two overlapping member identicons inside the avatar footprint */
function GroupAvatar({ members, size = 44 }) {
  const ids = (members || []).slice(0, 2);
  const inner = Math.round(size * 0.62);
  const ring = Math.max(2, Math.round(size * 0.05));
  return (
    <span className="bc-groupav" style={{ width: size, height: size }}>
      {ids[1] &&
      <span className="bc-groupav-a" style={{ top: 0, right: 0 }}>
          <Avatar name={ids[1]} size={inner} style={{ boxShadow: '0 0 0 ' + ring + 'px var(--ring, var(--bg))', borderRadius: '50%' }} />
        </span>
      }
      <span className="bc-groupav-a" style={{ bottom: 0, left: 0 }}>
        <Avatar name={ids[0] || '?'} size={inner} style={{ boxShadow: '0 0 0 ' + ring + 'px var(--ring, var(--bg))', borderRadius: '50%' }} />
      </span>
    </span>);

}

/* ── Network status chip — tap to simulate going offline/online ── */
function StatusChip({ network, meshCount, variant = 'pill', onToggle }) {
  const online = network === 'online';
  const label = online ? 'Online' : 'Offline';
  const desc = online ? 'reaches anyone' : `${meshCount} nearby on Bluetooth`;
  const hint = 'Simulated — tap to switch';
  if (variant === 'banner') {
    return (
      <button className={'bc-chipbanner' + (online ? '' : ' off')} onClick={onToggle} title={hint}>
        <span className={'bc-dot ' + (online ? 'g' : 'a')}></span>
        <span className="bc-chiptext"><b>{label}</b> · {desc}</span>
        <span className="bc-chipvia"><BCIcon name={online ? 'globe' : 'mesh'} size={15} /></span>
      </button>);

  }
  return (
    <div className="bc-chiprow">
      <button className="bc-chip" onClick={onToggle} title={hint}>
        <span className={'bc-dot ' + (online ? 'g' : 'a')}></span>
        <span className="bc-chiptext"><b>{label}</b> · {desc}</span>
      </button>
    </div>);

}

/* ── Conversation / list row — supports mute indicator + long-press ── */
function ConvRow({ av, title, extra, sub, time, unread, muted, onClick, onLongPress }) {
  const cancelled = React.useRef(false);
  const timer = React.useRef(null);
  const down = () => {
    if (!onLongPress) return;
    cancelled.current = false;
    timer.current = setTimeout(() => { cancelled.current = true; timer.current = null; onLongPress(); }, 500);
  };
  const up = () => { if (timer.current) { clearTimeout(timer.current); timer.current = null; } };
  return (
    <button className="bc-row" onClick={() => { if (!cancelled.current) onClick && onClick(); }} onMouseDown={down} onMouseUp={up} onMouseLeave={up} onTouchStart={down} onTouchEnd={up}>
      {av}
      <span className="bc-rowmain">
        <span className="bc-rowtitle">{title}{extra}</span>
        <span className="bc-rowsub">{sub}</span>
      </span>
      <span className="bc-rowend">
        {time ? <span className="bc-time">{time}</span> : null}
        {muted
          ? <span className="bc-mutedicon"><BCIcon name="bellOff" size={14} weight={2} /></span>
          : unread ? <span className="bc-unreaddot"></span> : null}
      </span>
    </button>);
}

/* ── Mute sheet: per-conversation mute with duration options ── */
const MUTE_DURATIONS = [
  { key: '1h', label: '1 hour' },
  { key: '8h', label: '8 hours' },
  { key: '1d', label: '1 day' },
  { key: '7d', label: '1 week' },
  { key: 'forever', label: 'Until I turn it back on' },
];

function MuteSheet({ name, isMuted, onMute, onUnmute, onClose }) {
  if (isMuted) {
    return (
      <Sheet onClose={onClose} title={name}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '10px 0 6px' }}>
          <span className="bc-emptyicon" style={{ width: 48, height: 48, borderRadius: 14 }}><BCIcon name="bellOff" size={22} /></span>
          <span style={{ fontSize: 15, fontWeight: 700 }}>Muted</span>
          <span style={{ fontSize: 13.5, color: 'var(--text2)', textAlign: 'center' }}>You won't get notifications for this conversation.</span>
        </div>
        <div className="bc-sheetactions">
          <button className="bc-primary" onClick={() => { onUnmute(); onClose(); }}>Unmute</button>
          <button className="bc-ghost" onClick={onClose}>Cancel</button>
        </div>
      </Sheet>
    );
  }
  return (
    <Sheet onClose={onClose} title={'Mute ' + name}>
      {MUTE_DURATIONS.map((d) => (
        <button key={d.key} className="bc-actionrow" onClick={() => { onMute(d.key); onClose(); }}>
          <span className="bc-actionicon"><BCIcon name={d.key === 'forever' ? 'bellOff' : 'clock'} size={19} /></span>
          <span className="bc-actionmain"><span className="bc-actionlabel">{d.label}</span></span>
        </button>
      ))}
    </Sheet>
  );
}

function SectionLabel({ children }) {
  return <div className="bc-sect">{children}</div>;
}

/* ── Chat header ── */
function NavHeader({ onBack, children, trailing, hairline = true }) {
  return (
    <div className={'bc-header' + (hairline ? ' hl' : '')}>
      {onBack &&
      <button className="bc-iconbtn" onClick={onBack} aria-label="Back">
          <BCIcon name="back" size={21} weight={2.1} />
        </button>
      }
      <div className="bc-headcenter">{children}</div>
      {trailing}
    </div>);

}

/* ── Privacy / public / transport banners ── */
function Banner({ icon, tone = '', children, action }) {
  return (
    <div className={'bc-banner ' + tone}>
      <BCIcon name={icon} size={16} weight={2} />
      <span className="bc-bannertext">{children}</span>
      {action}
    </div>);

}

function isSupporterAuthor(name) {
  if (!name) return false;
  const p = (window.BC_DATA && BC_DATA.peers || []).find((x) => x.name === name);
  return !!(p && p.supporter);
}

/* ── Reactions & replies ── */
const BC_REACTIONS = ['❤️', '👍', '😂', '😮', '😢', '🔥'];

/* render @mentions inside message text */
function bcRenderText(text) {
  if (!text || text.indexOf('@') === -1) return text;
  const out = [];
  let last = 0;
  const re = /@([A-Za-z0-9_]+)/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index));
    out.push(<span key={m.index} className="bc-mention">@{m[1]}</span>);
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}
const bcMentionsMe = (text, me) => !!text && new RegExp('@(' + (me || 'you') + '|you|everyone)\\b', 'i').test(text);

function bcReplyFrom(m, peerName) {
  return { author: m.mine ? 'You' : m.author || peerName || 'Them', text: m.text || bcMediaWord(m.media) };
}

/* long-press (or right-click) handlers for message bubbles */
function useBcPress(cb) {
  const t = React.useRef(null);
  const down = () => { if (!cb) return; t.current = setTimeout(() => { t.current = null; cb(); }, 420); };
  const up = () => { if (t.current) { clearTimeout(t.current); t.current = null; } };
  if (!cb) return {};
  return {
    onMouseDown: down, onMouseUp: up, onMouseLeave: up,
    onTouchStart: down, onTouchEnd: up, onTouchMove: up,
    onContextMenu: (e) => { e.preventDefault(); up(); cb(); },
  };
}

function ReplyQuote({ r }) {
  return (
    <div className="bc-quote">
      <span className="bc-quotename">{r.author}</span>
      <span className="bc-quotetext">{r.text}</span>
    </div>);
}

function ReactionRow({ m, me, onReact }) {
  if (!m.reactions || !m.reactions.length) return null;
  return (
    <div className="bc-reacts">
      {m.reactions.map((r) =>
      <button key={r.e} className={'bc-react' + (me && r.who.includes(me) ? ' mine' : '')} title={r.who.join(', ')} onClick={() => onReact && onReact(r.e)}>
          {r.e}{r.who.length > 1 ? <b>{r.who.length}</b> : null}
        </button>
      )}
    </div>);
}

/* ── Message bubble + list — bubble color encodes transport (BLE vs internet) ── */
function MsgBubble({ m, showAuthor, cont, showState, me, onPress, onReact }) {
  const hue = bcHash(m.author || '') % 360;
  const press = useBcPress(onPress);
  return (
    <div className={'bc-msg' + (m.mine ? ' mine' : '') + (cont ? ' cont' : '') + (bcMentionsMe(m.text, me) && !m.mine ? ' mention' : '')} data-via={m.via || null} {...press}>
      {showAuthor &&
      <div className="bc-author" style={{ color: `hsl(${hue} var(--author-s) var(--author-l))` }}>{m.author}{isSupporterAuthor(m.author) ? <SupporterBadge size={12} /> : null}</div>
      }
      <div className="bc-bubble">
        {m.replyTo ? <ReplyQuote r={m.replyTo} /> : null}
        {bcRenderText(m.text)}
        <span className="bc-meta">
          {m.time}
          {m.via ? <BCIcon name={m.via === 'mesh' ? 'mesh' : 'globe'} size={11} weight={2.2} /> : null}
        </span>
      </div>
      <ReactionRow m={m} me={me} onReact={onReact} />
      {showState && m.state ?
      <div className="bc-state"><BCIcon name="check" size={11} weight={2.6} />{m.state} · {m.via === 'mesh' ? 'Bluetooth' : 'internet'}</div> :
      null}
    </div>);

}

/* ── Media messages: image, video, audio note, file. Transport color carries to mine. ── */
const MEDIA_SHAPE = { landscape: [216, 150], portrait: [168, 222], square: [200, 200] };
const FILE_TONES = {
  PDF: ['#D9484C', 'rgba(212,58,62,0.15)'],
  ZIP: ['#D9941C', 'rgba(217,148,28,0.15)'],
  DOC: ['#3B7BD9', 'rgba(59,123,217,0.15)'],
  KEY: ['#1E9E5E', 'rgba(30,158,94,0.15)']
};
function fileTone(ext) {return FILE_TONES[ext] || ['var(--accent-deep)', 'var(--accent-soft)'];}

function MediaWave({ seed, n = 34 }) {
  const h = bcHash(seed || 'a');
  const bars = [];
  for (let i = 0; i < n; i++) {
    const v = (h >>> i % 28 ^ h * (i + 3)) & 15;
    const ht = 22 + v / 15 * 78;
    bars.push(<i key={i} style={{ height: ht + '%' }}></i>);
  }
  return <span className="media-wave">{bars}</span>;
}

function MetaChip({ m, glass }) {
  return (
    <span className={glass ? 'media-chip' : 'bc-meta'}>
      {m.time}
      {m.via ? <BCIcon name={m.via === 'mesh' ? 'mesh' : 'globe'} size={11} weight={2.2} /> : null}
    </span>);

}

function MediaBubble({ m, showAuthor, cont, showState, me, onPress, onReact }) {
  const md = m.media;
  const hue = bcHash(m.author || '') % 360;
  const phue = bcHash((md.name || '') + (md.shape || '')) % 360;
  const isVisual = md.type === 'image' || md.type === 'video';
  const [w, hgt] = MEDIA_SHAPE[md.shape || 'landscape'];
  const press = useBcPress(onPress);
  return (
    <div className={'bc-msg' + (m.mine ? ' mine' : '') + (cont ? ' cont' : '') + (md.type === 'sticker' || md.type === 'gif' ? ' mediabare' : '')} data-via={m.via || null} {...press}>
      {showAuthor &&
      <div className="bc-author" style={{ color: `hsl(${hue} var(--author-s) var(--author-l))` }}>{m.author}{isSupporterAuthor(m.author) ? <SupporterBadge size={12} /> : null}</div>
      }

      {isVisual &&
      <div className="media-visual" style={{ width: w, height: hgt }}>
          <span className="media-ph" style={{ '--ph': `hsl(${phue} 34% 52%)`, '--ph2': `hsl(${(phue + 36) % 360} 38% 42%)` }}>
            <BCIcon name={md.type === 'video' ? 'videocam' : 'photo'} size={26} weight={1.6} />
            <span className="media-phname">{md.name || (md.type === 'video' ? 'VID_0218.mp4' : 'IMG_0421.jpg')}</span>
          </span>
          {md.type === 'video' && <span className="media-play"><BCIcon name="play" size={22} /></span>}
          {md.type === 'video' && <span className="media-dur">{md.dur || '0:24'}</span>}
          <MetaChip m={m} glass />
        </div>
      }

      {md.type === 'audio' &&
      <div className="media-audio">
          <button className="media-playbtn" aria-label="Play voice message"><BCIcon name="play" size={16} /></button>
          <MediaWave seed={md.name || m.time} />
          <span className="media-audtime">{md.dur || '0:08'}</span>
        </div>
      }

      {md.type === 'file' &&
      <button className="media-file">
          <span className="media-fileicon" style={{ color: fileTone(md.ext)[0], background: fileTone(md.ext)[1] }}>
            <BCIcon name="doc" size={20} />
          </span>
          <span className="media-filemain">
            <span className="media-filename">{md.name || 'attachment'}</span>
            <span className="media-filemeta">{md.size || '—'} · {md.ext || 'File'}</span>
          </span>
          <span className="media-dl"><BCIcon name="download" size={17} weight={2} /></span>
        </button>
      }

      {md.type === 'sticker' &&
      <div className="media-sticker">
          <img src={md.src} alt="sticker" draggable="false" />
          <span className="media-stickertime">
            {m.time}
            {m.mine && m.state ? <BCIcon name="check" size={10} weight={2.8} /> : null}
          </span>
        </div>
      }

      {md.type === 'gif' &&
      <div className="media-visual gif" style={{ width: 168, height: 132 }}>
          <span className="media-ph" style={{ '--ph': `hsl(${phue} 44% 50%)`, '--ph2': `hsl(${(phue + 50) % 360} 48% 40%)` }}>
            <span className="media-gifword">{md.label || 'gif'}</span>
          </span>
          <span className="media-gifbadge">GIF</span>
          <MetaChip m={m} glass />
        </div>
      }

      {md.cap ? <div className="media-cap">{md.cap}</div> : null}
      {(md.type === 'audio' || md.type === 'file') && <MetaChip m={m} />}
      <ReactionRow m={m} me={me} onReact={onReact} />
      {showState && m.state && md.type !== 'sticker' && md.type !== 'gif' ?
      <div className="bc-state"><BCIcon name="check" size={11} weight={2.6} />{m.state} · {m.via === 'mesh' ? 'Bluetooth' : 'internet'}</div> :
      null}
    </div>);

}

function NudgeMsg({ m, peerName }) {
  return (
    <div className="bc-nudgemsg">
      <span className="bc-nudgeic"><BCIcon name="nudge" size={15} weight={2.1} /></span>
      {m.mine ? 'You sent a nudge' : (m.author || peerName || 'They') + ' nudged you — 👋'}
    </div>
  );
}

function MsgList({ msgs, showAuthors, peerName, onClaim, pay, me, onReact, onReply }) {
  const ref = React.useRef(null);
  const [menu, setMenu] = React.useState(null);
  React.useEffect(() => {
    if (ref.current) ref.current.scrollTop = ref.current.scrollHeight;
  }, [msgs.length]);
  const interactive = !!(onReact || onReply);
  const mm = menu != null ? msgs[menu] : null;
  return (
    <React.Fragment>
    <div className="bc-msgs" ref={ref}>
      <div className="bc-datechip">Today</div>
      {msgs.map((m, i) => {
        if (m.pay) return <PayBubble key={i} m={m} peerName={peerName} onTap={onClaim ? () => onClaim(i) : null} pay={pay} />;
        if (m.call) return <CallLog key={i} m={m} peerName={peerName} />;
        if (m.nudge) return <NudgeMsg key={i} m={m} peerName={peerName} />;
        if (m.action) return <div key={i} className="bc-action-msg">{m.text}</div>;
        const prev = msgs[i - 1];
        const cont = !!prev && !prev.action && !prev.pay && !prev.call && prev.author === m.author && !!prev.mine === !!m.mine;
        const press = interactive ? () => setMenu(i) : null;
        const react = onReact ? (e) => onReact(i, e) : null;
        if (m.media) {
          return (
            <MediaBubble
              key={i} m={m} cont={cont} me={me} onPress={press} onReact={react}
              showAuthor={showAuthors && !m.mine && !cont}
              showState={!!m.mine && i === msgs.length - 1} />);


        }
        return (
          <MsgBubble
            key={i} m={m} cont={cont} me={me} onPress={press} onReact={react}
            showAuthor={showAuthors && !m.mine && !cont}
            showState={!!m.mine && i === msgs.length - 1} />);


      })}
    </div>
    {mm ?
    <div className="bc-ctxwrap" onClick={(e) => { if (e.target === e.currentTarget) setMenu(null); }}>
        <div className={'bc-ctx' + (mm.mine ? ' mine' : '')}>
          <div className="bc-ctxpreview">{mm.text || bcMediaWord(mm.media)}</div>
          {onReact ?
        <div className="bc-ctxpicker">
            {BC_REACTIONS.map((e) => {
            const on = (mm.reactions || []).some((r) => r.e === e && me && r.who.includes(me));
            return <button key={e} className={on ? 'on' : ''} onClick={() => { onReact(menu, e); setMenu(null); }}>{e}</button>;
          })}
          </div> : null}
          <div className="bc-ctxmenu">
            {onReply ? <button onClick={() => { onReply(menu); setMenu(null); }}><BCIcon name="reply" size={17} />Reply</button> : null}
            <button onClick={() => setMenu(null)}><BCIcon name="copy" size={16} />Copy</button>
          </div>
        </div>
      </div> : null}
    </React.Fragment>);

}

/* ── Composer with "+" actions and "/" command layer ── */
const BC_COMMANDS = [
['who', 'See who\u2019s nearby'],
['msg', 'Message someone'],
['slap', 'Classic IRC slap']];


function fmtDur(sec) {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return m + ':' + ('0' + s).slice(-2);
}

/* Telegram/Signal-style voice recording overlay.
   Hold the mic to record; drag left past the threshold to cancel; swipe up (or
   tap the lock) to go hands-free, which reveals an explicit Send button. */
function VoiceRecorder({ transport, onSend, onCancel }) {
  const [secs, setSecs] = React.useState(0);
  const [locked, setLocked] = React.useState(false);
  const [dx, setDx] = React.useState(0); // horizontal drag (cancel)
  const [dy, setDy] = React.useState(0); // vertical drag (lock)
  const start = React.useRef(null);
  const lockedRef = React.useRef(false);
  const cancelRef = React.useRef(false);
  const net = transport === 'internet';

  React.useEffect(() => {
    const id = setInterval(() => setSecs((s) => s + 1), 1000);
    return () => clearInterval(id);
  }, []);

  const finish = () => {
    if (cancelRef.current) {onCancel();return;}
    onSend(Math.max(1, secs));
  };

  React.useEffect(() => {
    const move = (e) => {
      if (lockedRef.current || !start.current) return;
      const p = e.touches ? e.touches[0] : e;
      const ndx = Math.min(0, p.clientX - start.current.x);
      const ndy = Math.min(0, p.clientY - start.current.y);
      setDx(ndx);setDy(ndy);
      if (ndx < -110) {cancelRef.current = true;setLocked(false);lockedRef.current = false;cleanup();onCancel();} else
      if (ndy < -64) {lockedRef.current = true;setLocked(true);setDx(0);setDy(0);}
    };
    const up = () => {if (!lockedRef.current) {cleanup();finish();}};
    const cleanup = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      window.removeEventListener('touchmove', move);
      window.removeEventListener('touchend', up);
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
    window.addEventListener('touchmove', move, { passive: true });
    window.addEventListener('touchend', up);
    return cleanup;
  }, [secs]);

  const onDown = (e) => {
    const p = e.touches ? e.touches[0] : e;
    start.current = { x: p.clientX, y: p.clientY };
  };
  React.useEffect(() => {
    // capture the initial pointer position from the press that mounted us
    start.current = window.__bcVoiceStart || null;
  }, []);

  const cancelNow = () => {cancelRef.current = true;onCancel();};
  const sendNow = () => {onSend(Math.max(1, secs));};

  return (
    <div className="bc-composer voice">
      <button className="voice-trash" onClick={cancelNow} aria-label="Cancel recording">
        <BCIcon name="trash" size={19} weight={2} />
      </button>
      <div className="voice-bar">
        <span className="voice-rec"></span>
        <span className="voice-time">{fmtDur(secs)}</span>
        <span className="voice-live"><VoiceLive secs={secs} /></span>
        {locked ?
        <span className="voice-lockedtag">Tap send when done</span> :
        <span className="voice-slide" style={{ opacity: 1 + dx / 110 }}>
              <BCIcon name="chevron" size={13} weight={2.4} style={{ transform: 'rotate(180deg)' }} />
              slide to cancel
            </span>}
      </div>
      {locked ?
      <button className={'bc-sendbtn on' + (net ? ' net' : '')} onClick={sendNow} aria-label="Send voice note">
          <BCIcon name="send" size={17} weight={2.3} />
        </button> :

      <div className="voice-holdwrap" style={{ transform: `translate(${dx}px, ${Math.max(dy, -70)}px)` }}>
          <span className="voice-lockhint" style={{ opacity: Math.min(1, -dy / 64) }}>
            <BCIcon name="lock" size={13} weight={2.2} />
          </span>
          <span className={'voice-mic' + (net ? ' net' : '')}>
            <BCIcon name="mic" size={19} weight={2} />
          </span>
        </div>
      }
    </div>);

}

function VoiceLive({ secs }) {
  // a lively, deterministic-but-moving waveform while recording
  const bars = [];
  const n = 30;
  for (let i = 0; i < n; i++) {
    const phase = secs * 6 + i * 3;
    const v = (Math.sin(phase * 0.7) + Math.sin(phase * 1.9 + i)) * 0.5;
    const ht = 18 + Math.abs(v) * 80;
    bars.push(<i key={i} style={{ height: ht + '%' }}></i>);
  }
  return <span className="media-wave live">{bars}</span>;
}

/* ── Emoji · Stickers · GIFs keyboard (composer popover) ── */
const EMOJI_CATS = [
{ id: 'recent', icon: 'clock', label: 'Recently used', list: ['🤣', '😎', '🫠', '❤️', '🔥', '🫶', '😭', '🤔', '🙄', '✌️', '👀', '🎉'] },
{ id: 'smileys', icon: 'smile', label: 'Smileys & people', list: ['😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '🫠', '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '☺️', '😚', '😙', '🥲', '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🫢', '🤫', '🤔', '🫡', '🤐', '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '😮‍💨', '🤥', '😌', '😔', '😪', '🤤', '😴', '🥱', '😷', '🤒', '🤕', '🤢', '🤮', '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '🥸', '😎'] },
{ id: 'nature', icon: 'leaf', label: 'Animals & nature', list: ['🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🦆', '🦉', '🦄', '🐝', '🦋', '🐌', '🐞', '🌸', '💐', '🌹', '🌻', '🌳', '🌵', '🍀', '🌊', '🔥', '⭐', '🌙', '☀️', '⛅', '🌈'] },
{ id: 'food', icon: 'cup', label: 'Food & drink', list: ['🍎', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🥑', '🌽', '🥕', '🍞', '🧀', '🍕', '🍔', '🌮', '🌯', '🍣', '🍜', '🍫', '🍪', '🎂', '🍰', '☕', '🍵', '🍺', '🍷', '🥂', '🍸'] },
{ id: 'activity', icon: 'ball', label: 'Activity', list: ['⚽', '🏀', '🏈', '⚾', '🎾', '🏐', '🏓', '🏸', '🥊', '🎿', '🏂', '🏄', '🚴', '🧗', '🏆', '🥇', '🎯', '🎲', '🎮', '🎸', '🎹', '🎤', '🎧', '🎬', '🎨', '♟️', '🎳', '🛹'] },
{ id: 'travel', icon: 'car', label: 'Travel & places', list: ['🚗', '🚕', '🚌', '🚲', '🛵', '🏍️', '🚂', '✈️', '🚀', '🛸', '⛵', '🚤', '🗺️', '🏝️', '🏔️', '🌋', '🏕️', '🏙️', '🌃', '🗽', '🗼', '🎡', '🚏', '⛽'] },
{ id: 'objects', icon: 'bulb', label: 'Objects', list: ['💡', '🔦', '🔋', '📱', '💻', '⌨️', '🖥️', '🖨️', '📷', '🎥', '📺', '🔑', '🔒', '🔓', '💰', '💎', '🎁', '📦', '✏️', '📌', '📎', '✂️', '🔭', '🧲'] },
{ id: 'symbols', icon: 'grid', label: 'Symbols', list: ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💔', '❣️', '💕', '💞', '💯', '✅', '❌', '❓', '❗', '⚡', '♻️', '🔔', '✔️', '➕', '✨', '🟢'] },
{ id: 'flags', icon: 'flag', label: 'Flags', list: ['🏳️', '🏴', '🏁', '🚩', '🏳️‍🌈', '🇨🇭', '🇮🇹', '🇬🇧', '🇺🇸', '🇫🇷', '🇩🇪', '🇪🇸', '🇯🇵', '🇧🇷', '🇨🇦', '🇳🇱'] }];


const KB_STICKER_PACKS = [
{ id: 'mesh-mates', name: 'Mesh Mates', n: 6 },
{ id: 'night-signal', name: 'Night Signal', n: 6 },
{ id: 'sat-stack', name: 'Sat Stack', n: 6 },
{ id: 'lake-days', name: 'Lake Days', n: 6 }];


const KB_GIFS = ['nod', 'lol', 'wave', 'facepalm', 'clap', 'shrug', 'dance', 'mind blown', 'yes', 'nope', 'thumbs up', 'crying'];

function EmojiKeyboard({ onEmoji, onSticker, onGif, onClose }) {
  const [tab, setTab] = React.useState('emoji');
  const [q, setQ] = React.useState('');
  const scrollRef = React.useRef(null);
  const ql = q.trim().toLowerCase();

  const jump = (id) => {
    const el = scrollRef.current && scrollRef.current.querySelector('[data-cat="' + id + '"]');
    if (el && scrollRef.current) scrollRef.current.scrollTop = el.offsetTop - 4;
  };

  return (
    <div className="kb">
      <div className="kb-tabs">
        {[['emoji', 'Emoji'], ['stickers', 'Stickers'], ['gifs', 'GIFs']].map(([id, label]) =>
        <button key={id} className={'kb-tab' + (tab === id ? ' on' : '')} onClick={() => setTab(id)}>{label}</button>
        )}
        <button className="kb-x" onClick={onClose} aria-label="Close keyboard"><BCIcon name="chevron" size={15} weight={2.4} style={{ transform: 'rotate(90deg)' }} /></button>
      </div>

      {tab === 'emoji' &&
      <React.Fragment>
          <div className="kb-search">
            <BCIcon name="search" size={15} weight={2.2} />
            <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search emoji" />
          </div>
          <div className="kb-scroll" ref={scrollRef}>
            {EMOJI_CATS.map((cat) => {
            const list = ql ? cat.list.filter(() => false) : cat.list;
            if (ql && cat.id !== 'recent') return null;
            return (
              <div key={cat.id} data-cat={cat.id}>
                  <div className="kb-sect">{cat.label}</div>
                  <div className="kb-emojis">
                    {cat.list.map((e, i) =>
                  <button key={cat.id + i} className="kb-emoji" onClick={() => onEmoji(e)}>{e}</button>
                  )}
                  </div>
                </div>);

          })}
          </div>
          <div className="kb-catbar">
            {EMOJI_CATS.map((cat) =>
          <button key={cat.id} className="kb-caticon" onClick={() => jump(cat.id)} aria-label={cat.label}>
                <BCIcon name={cat.icon} size={17} />
              </button>
          )}
          </div>
        </React.Fragment>
      }

      {tab === 'stickers' &&
      <div className="kb-scroll stickers">
          {KB_STICKER_PACKS.map((pk) =>
        <div key={pk.id}>
              <div className="kb-sect">{pk.name}</div>
              <div className="kb-stickergrid">
                {Array.from({ length: pk.n }).map((_, i) =>
            <button key={pk.id + i} className="kb-sticker" onClick={() => onSticker({ pack: pk.id, idx: i, src: 'sonar/stickers/' + pk.id + '-' + i + '.png' })}>
                    <img src={'sonar/stickers/' + pk.id + '-' + i + '.png'} alt="" loading="lazy" />
                  </button>
            )}
              </div>
            </div>
        )}
          <a className="kb-getmore" href="Sonar Stickers.html" target="_blank" rel="noopener">
            <BCIcon name="plus" size={15} weight={2.2} />Browse sticker packs
          </a>
        </div>
      }

      {tab === 'gifs' &&
      <React.Fragment>
          <div className="kb-search">
            <BCIcon name="search" size={15} weight={2.2} />
            <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search GIFs" />
          </div>
          <div className="kb-scroll">
            <div className="kb-gifgrid">
              {KB_GIFS.filter((g) => !ql || g.includes(ql)).map((g, i) => {
              const h = bcHash(g) % 360;
              return (
                <button key={g} className="kb-gif" onClick={() => onGif(g)} style={{ '--g1': `hsl(${h} 46% 48%)`, '--g2': `hsl(${(h + 50) % 360} 50% 38%)` }}>
                    <span className="kb-gifword">{g}</span>
                    <span className="kb-gifbadge">GIF</span>
                  </button>);

            })}
            </div>
          </div>
        </React.Fragment>
      }
    </div>);

}

function Composer({ placeholder, transport, onSend, onPlus, onCommand, onVoice, onSticker, reply, onCancelReply, mentions }) {
  const [text, setText] = React.useState('');
  const [recording, setRecording] = React.useState(false);
  const [kbOpen, setKbOpen] = React.useState(false);
  const slash = text.startsWith('/');
  const mTok = mentions && mentions.length ? /(?:^|\s)@([A-Za-z0-9_]*)$/.exec(text) : null;
  const mQ = mTok ? mTok[1].toLowerCase() : null;
  const mHits = mTok ? mentions.filter((p) => p.name.toLowerCase().startsWith(mQ)) : [];
  const mAll = !!mTok && 'everyone'.startsWith(mQ);
  const pickMention = (name) => setText((t) => t.replace(/(?:^|\s)@([A-Za-z0-9_]*)$/, (s) => (s.startsWith(' ') ? ' ' : '') + '@' + name + ' '));
  const hasText = !!text.trim();
  const net = transport === 'internet';
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
  const micDown = (e) => {
    if (!onVoice) return;
    const p = e.touches ? e.touches[0] : e;
    window.__bcVoiceStart = { x: p.clientX, y: p.clientY };
    setRecording(true);
  };
  return (
    <div className="bc-composerwrap">
      {reply && !recording &&
      <div className="bc-replybar">
          <BCIcon name="reply" size={16} weight={2.1} />
          <span className="bc-replymain"><b>{reply.author}</b><span>{reply.text}</span></span>
          <button className="bc-replyx" onClick={onCancelReply} aria-label="Cancel reply"><BCIcon name="x" size={13} weight={2.4} /></button>
        </div>
      }
      {mTok && !recording && (mHits.length > 0 || mAll) &&
      <div className="bc-mentions">
          <div className="bc-mentionscroll">
            {mAll &&
          <button className="bc-mrow" onClick={() => pickMention('everyone')}>
                <span className="bc-mall"><BCIcon name="people" size={16} /></span>
                <span className="bc-mrowmain">
                  <span className="bc-mrowname">@everyone</span>
                  <span className="bc-mrowsub">Notifies all {mentions.length + 1} members, even on mute</span>
                </span>
              </button>
          }
            {mHits.map((p) =>
          <button key={p.id} className="bc-mrow" onClick={() => pickMention(p.name)}>
                <Avatar name={p.name} size={32} />
                <span className="bc-mrowmain">
                  <span className="bc-mrowname">{p.name}{p.supporter ? <SupporterBadge size={12} /> : null}</span>
                  <span className="bc-mrowsub">{p.inRange ? 'Right here · reachable over Bluetooth' : 'Out of range · gets it over the internet'}</span>
                </span>
                <span className={'bc-mrowvia' + (p.inRange ? '' : ' net')}>{p.inRange ? 'nearby' : 'internet'}</span>
              </button>
          )}
          </div>
          <div className="bc-mentionhint">Mentions stay inside the encryption — relays never learn who you tagged.</div>
        </div>
      }
      {slash && !recording &&
      <div className="bc-cmdstrip">
          {BC_COMMANDS.map(([c, d]) =>
        <button key={c} className="bc-cmd" onClick={() => {onCommand && onCommand(c);setText('');}}>
              <span className="bc-cmdname">/{c}</span>
              <span className="bc-cmddesc">{d}</span>
            </button>
        )}
        </div>
      }
      {kbOpen && !recording &&
      <EmojiKeyboard
        onEmoji={(e) => setText((t) => t + e)}
        onSticker={(s) => {onSticker && onSticker({ type: 'sticker', src: s.src, pack: s.pack, idx: s.idx });setKbOpen(false);}}
        onGif={(g) => {onSticker && onSticker({ type: 'gif', label: g });setKbOpen(false);}}
        onClose={() => setKbOpen(false)} />

      }
      {recording ?
      <VoiceRecorder
        transport={transport}
        onSend={(sec) => {setRecording(false);onVoice && onVoice(sec);}}
        onCancel={() => setRecording(false)} /> :


      <div className="bc-composer">
          <button className="bc-plusbtn" onClick={onPlus} aria-label="Actions">
            <BCIcon name="plus" size={19} weight={2.1} />
          </button>
          <div className="bc-fieldwrap">
            <input
            className="bc-input" type="text" value={text}
            placeholder={placeholder}
            onFocus={() => setKbOpen(false)}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {if (e.key === 'Enter') send();}} data-comment-anchor="9c6498dbec-input-596-13" />
          
            {onSticker ?
          <button
            className={'bc-emojibtn' + (kbOpen ? ' on' : '')}
            onClick={() => setKbOpen((v) => !v)}
            aria-label="Emoji, stickers and GIFs">
            
                <BCIcon name={kbOpen ? 'keyboard' : 'smile'} size={20} weight={1.9} />
              </button> :
          null}
          </div>
          {hasText || !onVoice ?
        <button
          className={'bc-sendbtn' + (hasText ? ' on' : '') + (net ? ' net' : '')}
          onClick={send} aria-label="Send">
          
              <BCIcon name="send" size={17} weight={2.3} />
            </button> :

        <button
          className="bc-sendbtn mic"
          onMouseDown={micDown} onTouchStart={micDown}
          aria-label="Hold to record a voice note">
          
              <BCIcon name="mic" size={18} weight={2} />
            </button>
        }
        </div>
      }
    </div>);

}

/* ── Bottom sheet ── */
function Sheet({ onClose, title, children }) {
  return (
    <div className="bc-scrim" onClick={(e) => {if (e.target === e.currentTarget) onClose();}}>
      <div className="bc-sheet">
        <div className="bc-grabber"></div>
        {title ? <div className="bc-sheettitle">{title}</div> : null}
        {children}
      </div>
    </div>);

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
    </button>);

}

/* shared media attach rows for composer "+" sheets */
function AttachActions({ transport, onPick }) {
  const wire = transport === 'mesh' ? 'Sends over Bluetooth' : 'Sends over the internet';
  return (
    <React.Fragment>
      <ActionRow icon="camera" label="Photo" desc={wire} onClick={() => onPick('photo')} />
      <ActionRow icon="videocam" label="Video" desc={wire} onClick={() => onPick('video')} />
      <ActionRow icon="mic" label="Audio note" desc="Hold to record \u00b7 hands-free" onClick={() => onPick('audio')} />
      <ActionRow icon="doc" label="File" desc="Any kind \u2014 docs, archives, anything" onClick={() => onPick('file')} />
    </React.Fragment>);

}

function Bars({ n }) {
  return (
    <span className="bc-bars">
      <i className={n >= 1 ? 'on' : ''}></i>
      <i className={n >= 2 ? 'on' : ''}></i>
      <i className={n >= 3 ? 'on' : ''}></i>
    </span>);

}

/* sample outgoing media for the prototype "+" actions */
function bcSampleMedia(type) {
  if (type && typeof type === 'object') return type;
  const r = Math.floor(Math.random() * 9000) + 1000;
  if (type === 'photo') return { type: 'image', shape: 'square', name: 'IMG_' + r + '.jpg' };
  if (type === 'video') return { type: 'video', shape: 'landscape', name: 'VID_' + r + '.mp4', dur: '0:' + (10 + r % 40) };
  if (type === 'audio') return { type: 'audio', name: 'vn-' + r, dur: '0:' + ('0' + (4 + r % 12)).slice(-2) };
  return { type: 'file', name: 'document-' + r + '.pdf', ext: 'PDF', size: 1 + r % 9 + '.' + r % 9 + ' MB' };
}

/* voice note built from a recorded duration (Telegram/Signal-style) */
function bcVoiceMedia(sec) {
  const r = Math.floor(Math.random() * 9000) + 1000;
  return { type: 'audio', voice: true, name: 'vn-' + r, dur: fmtDur(Math.max(1, sec || 1)) };
}

/* short word for a media item, for conversation previews */
function bcMediaWord(md) {
  if (!md) return '';
  if (md.voice) return 'Voice note';
  if (md.type === 'audio') return 'Audio';
  if (md.type === 'image') return 'Photo';
  if (md.type === 'video') return 'Video';
  if (md.type === 'file') return md.ext ? md.ext + ' file' : 'File';
  return 'Attachment';
}

/* ── Settings building blocks (XChat-inspired grouped cards) ── */
function SettingsCard({ children }) {
  return <div className="st-card">{children}</div>;
}

function SettingsRow({ icon, tone = '', label, sub, value, danger, onClick, chevron = true }) {
  return (
    <button className={'st-row' + (danger ? ' danger' : '')} onClick={onClick}>
      <span className={'st-icon ' + tone}><BCIcon name={icon} size={17} /></span>
      <span className="st-label">
        {label}
        {sub ? <small>{sub}</small> : null}
      </span>
      {value ? <span className="st-value">{value}</span> : null}
      {chevron ? <BCIcon name="chevron" size={14} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} /> : null}
    </button>);

}

Object.assign(window, {
  bcHash, Avatar, PlaceTile, GroupAvatar, SupporterBadge, StatusChip, ConvRow, MuteSheet, MUTE_DURATIONS, SectionLabel,
  NavHeader, Banner, MsgBubble, MediaBubble, NudgeMsg, MsgList, Composer, Sheet, ActionRow, AttachActions, Bars,
  BC_REACTIONS, bcReplyFrom, ReplyQuote, ReactionRow, useBcPress, bcRenderText, bcMentionsMe,
  SettingsCard, SettingsRow, bcSampleMedia, bcVoiceMedia, bcMediaWord, fmtDur
});
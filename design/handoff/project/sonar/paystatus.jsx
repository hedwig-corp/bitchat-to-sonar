// Sonar — external payment status explorations (4 directions, shared state machine)

const STATES = [
  { id: 'resolving', label: 'Resolving' },
  { id: 'paying', label: 'Paying' },
  { id: 'slow', label: 'Slow / stuck' },
  { id: 'sent', label: 'Sent ✓' },
  { id: 'failed_safe', label: 'Failed · not charged' },
  { id: 'refunded', label: 'Failed · refunded' },
  { id: 'unknown', label: 'Unknown / pending' },
];

const PAYEE = { name: 'Café Lumen', addr: 'lnbc21u1p3k9…q7f2n', sats: 2100, fiat: '€1.22' };
const PREIMAGE = '7c1f9ad3e0b45a82…c94e17';

/* money-truth copy — the single most important line in every direction */
const MONEY = {
  resolving: { tone: 'safe', text: 'Nothing sent yet — your sats are still yours' },
  paying:    { tone: 'flight', text: '2,100 sats in flight — not yet settled' },
  slow:      { tone: 'warn', text: 'Still in flight — held, not lost' },
  sent:      { tone: 'good', text: '2,100 sats delivered · proof received' },
  failed_safe: { tone: 'safe', text: 'Nothing left your wallet — balance unchanged' },
  refunded:  { tone: 'good', text: '2,100 sats returned to your balance' },
  unknown:   { tone: 'warn', text: 'Sats reserved — we’ll confirm or refund automatically' },
};

const HEAD = {
  resolving: ['Finding Café Lumen', 'Reading the code and checking the destination is payable.'],
  paying:    ['Sending 2,100 sats', 'Your payment is hopping through the Lightning network.'],
  slow:      ['Taking longer than usual', 'The first route didn’t answer. Trying another — this can take a minute.'],
  sent:      ['Paid Café Lumen', 'They received 2,100 sats. You have cryptographic proof of payment.'],
  failed_safe: ['Couldn’t send', 'No route to Café Lumen right now. You were not charged.'],
  refunded:  ['Payment came back', 'Café Lumen didn’t accept in time, so the sats returned to you.'],
  unknown:   ['Still confirming', 'We can’t see the result yet. Lightning settles or refunds on its own — we’ll tell you which.'],
};

const STEPS = [
  { id: 'resolve', t: 'Found Café Lumen', s: 'Invoice read · 2,100 sats requested' },
  { id: 'route',   t: 'Route found', s: '3 hops · fee 1 sat' },
  { id: 'flight',  t: 'Sending over Lightning', s: 'Funds locked in flight' },
  { id: 'settle',  t: 'Delivered', s: 'Proof: ' },
];

// per state: index reached, and status of the current step
const PROGRESS = {
  resolving:  { at: 0, cur: 'live' },
  paying:     { at: 2, cur: 'live' },
  slow:       { at: 2, cur: 'warn' },
  sent:       { at: 4, cur: 'done' },
  failed_safe:{ at: 1, cur: 'bad' },
  refunded:   { at: 3, cur: 'bad' },
  unknown:    { at: 3, cur: 'warn' },
};
const PCT = { resolving: 12, paying: 58, slow: 70, sent: 100, failed_safe: 0, refunded: 0, unknown: 72 };

function Money({ st, pill }) {
  const m = MONEY[st];
  const ic = m.tone === 'good' ? 'check' : m.tone === 'warn' ? 'shield' : m.tone === 'flight' ? 'bolt' : 'lock';
  if (pill) {
    const bg = { safe: 'var(--surface2)', flight: 'var(--net-soft)', good: 'var(--green-soft)', warn: 'var(--gold-soft)' }[m.tone];
    const fg = { safe: 'var(--text2)', flight: 'var(--net-deep)', good: 'var(--green-deep)', warn: 'var(--gold-deep)' }[m.tone];
    return <span className="one-money" style={{ background: bg, color: fg }}>{m.text}</span>;
  }
  return (
    <div className={'money ' + m.tone}>
      <BCIcon name={ic} size={16} weight={2.1} />
      <span>{m.text}</span>
    </div>
  );
}

function Recipient({ st }) {
  return (
    <div className="rc">
      <span className="rc-av"><BCIcon name="bolt" size={22} weight={2.2} /></span>
      <span className="rc-main">
        <span className="rc-name">{PAYEE.name}</span>
        <span className="rc-sub">{PAYEE.addr}</span>
      </span>
      <span className="rc-amt"><b>{PAYEE.sats.toLocaleString('en-US')}</b><span>sats · {PAYEE.fiat}</span></span>
    </div>
  );
}

function Frame({ title, children, foot }) {
  return (
    <React.Fragment>
      <div className="sc-head">
        <button className="bc-iconbtn"><BCIcon name="back" size={20} weight={2.1} /></button>
        <span className="sc-title">{title}</span>
      </div>
      <div className="sc-body">{children}</div>
      {foot ? <div className="sc-foot">{foot}</div> : null}
    </React.Fragment>
  );
}

/* ── A · stepped ledger ─────────────────────────────────────────────── */
function DirA({ st }) {
  const p = PROGRESS[st];
  return (
    <Frame title="Payment">
      <Recipient st={st} />
      <div className="stp">
        {STEPS.map((s, i) => {
          const done = i < p.at;
          const isCur = i === p.at || (p.at === 4 && i === 3);
          const cls = done && !(p.at === 4 && i === 3) ? 'done' : isCur ? p.cur : '';
          const idle = !done && !isCur;
          const ic = cls === 'done' ? 'check' : cls === 'bad' ? 'x' : cls === 'warn' ? 'shield' : cls === 'live' ? 'bolt' : null;
          return (
            <div className={'stp-i' + (idle ? ' idle' : '')} key={s.id}>
              <span className="stp-rail">
                <span className={'stp-dot ' + cls}>
                  {ic ? <BCIcon name={ic} size={12} weight={2.8} /> : <i style={{ width: 6, height: 6, borderRadius: 9, background: 'currentColor', display: 'block' }}></i>}
                </span>
                {i < STEPS.length - 1 ? <span className={'stp-line' + (done ? ' done' : '')}></span> : null}
              </span>
              <span className="stp-txt">
                <span className="stp-t">
                  {st === 'failed_safe' && i === 1 ? 'No route available' : st === 'refunded' && i === 3 ? 'Returned to you' : s.t}
                </span>
                {!idle ? (
                  <span className="stp-s">
                    {i === 3 && st === 'sent'
                      ? <>Proof: <span className="mono">{PREIMAGE}</span></>
                      : st === 'failed_safe' && i === 1 ? 'Tried 4 paths · none reachable'
                      : st === 'slow' && i === 2 ? 'Retrying a second route…'
                      : st === 'refunded' && i === 3 ? 'Not accepted in time'
                      : st === 'unknown' && i === 3 ? 'Waiting on the network…'
                      : s.s}
                  </span>
                ) : null}
              </span>
            </div>
          );
        })}
      </div>
      <Money st={st} />
    </Frame>
  );
}

/* ── B · one sentence ───────────────────────────────────────────────── */
function DirB({ st }) {
  const [open, setOpen] = React.useState(false);
  const pct = PCT[st];
  const bad = st === 'failed_safe' || st === 'refunded';
  const good = st === 'sent';
  const warn = st === 'slow' || st === 'unknown';
  const R = 58, C = 2 * Math.PI * R;
  const stroke = good ? 'var(--green)' : bad ? 'var(--danger)' : warn ? 'var(--gold-fill)' : 'var(--accent)';
  const glyph = good ? 'check' : bad ? 'x' : warn ? 'shield' : 'bolt';
  const [h, sub] = HEAD[st];
  return (
    <Frame title="Payment">
      <div className="one">
        <div className={'ring' + (good ? ' good' : bad ? ' bad' : warn ? ' warn' : '')}>
          <svg width="132" height="132">
            <circle cx="66" cy="66" r={R} fill="none" stroke="var(--surface2)" strokeWidth="7" />
            <circle cx="66" cy="66" r={R} fill="none" stroke={stroke} strokeWidth="7" strokeLinecap="round"
              strokeDasharray={C} strokeDashoffset={C * (1 - (bad ? 100 : pct) / 100)}
              className={!good && !bad && !warn ? 'spin' : ''} style={{ transition: 'stroke-dashoffset 0.7s ease' }} />
          </svg>
          <span className="glyph"><BCIcon name={glyph} size={34} weight={2.2} /></span>
        </div>
        <h2 className="one-h">{h}</h2>
        <p className="one-s">{sub}</p>
        <Money st={st} pill />
        <div className="disc">
          <button className="disc-btn" onClick={() => setOpen(!open)}>
            <BCIcon name="info" size={15} weight={2} />
            What’s happening?
            <BCIcon name="chevron" size={13} weight={2.2} style={{ marginLeft: 'auto', transform: open ? 'rotate(90deg)' : 'none', transition: 'transform 0.18s' }} />
          </button>
          {open && (
            <div className="disc-body">
              <div className="ok">✓ invoice parsed · 2,100 sats</div>
              <div className={PROGRESS[st].at > 1 ? 'ok' : ''}>{PROGRESS[st].at > 1 ? '✓' : '·'} route · 3 hops · fee 1</div>
              <div className={st === 'sent' ? 'ok' : ''}>{st === 'sent' ? '✓' : '·'} htlc {st === 'sent' ? 'settled' : bad ? 'cancelled' : 'in flight'}</div>
              <div>{st === 'sent' ? 'preimage ' + PREIMAGE.slice(0, 16) + '…' : 'preimage —'}</div>
            </div>
          )}
        </div>
      </div>
    </Frame>
  );
}

/* ── C · journey rail ───────────────────────────────────────────────── */
function DirC({ st }) {
  const pct = PCT[st];
  const good = st === 'sent';
  const bad = st === 'failed_safe' || st === 'refunded';
  const moving = st === 'paying' || st === 'slow' || st === 'unknown';
  const [h, sub] = HEAD[st];
  const left = 'calc(' + (bad ? 0 : pct) + '% * 0.78 + 26px)';
  return (
    <Frame title="Payment">
      <Recipient st={st} />
      <div className="jr">
        <div className="jr-track">
          <div className="jr-line">
            <span className={'jr-fill' + (good ? ' good' : bad ? ' bad' : '')} style={{ right: (100 - (bad ? 0 : pct)) + '%' }}></span>
          </div>
          <span className="jr-end me lit"><BCIcon name="people" size={16} weight={2.1} /></span>
          <span className={'jr-end them' + (good ? ' good' : bad ? '' : pct > 60 ? ' lit' : '')}><BCIcon name="bolt" size={16} weight={2.2} /></span>
          <span className={'jr-coin' + (moving ? ' pulse' : '')} style={{ left }}>₿</span>
        </div>
        <div className="jr-caps"><span>you</span><span>{PAYEE.name}</span></div>
        <div className="jr-mile">
          {[0, 1, 2, 3].map((i) => <i key={i} className={i < PROGRESS[st].at ? 'on' : ''}></i>)}
        </div>
        <div className="jr-stat">
          <h4>{h}</h4>
          <p>{sub}</p>
        </div>
      </div>
      <div style={{ marginTop: 22 }}><Money st={st} /></div>
    </Frame>
  );
}

/* ── D · resumable status ───────────────────────────────────────────── */
function DirD({ st }) {
  const pct = PCT[st];
  const good = st === 'sent';
  const bad = st === 'failed_safe' || st === 'refunded';
  const warn = st === 'slow' || st === 'unknown';
  const live = st === 'resolving' || st === 'paying' || warn;
  const [h, sub] = HEAD[st];
  const acts = {
    resolving: [['Cancel', 'dim']],
    paying: [['Hide — keeps sending', 'dim']],
    slow: [['Keep waiting', 'pri'], ['Cancel payment', 'dim']],
    sent: [['Copy proof', 'pri'], ['Done', '']],
    failed_safe: [['Try again', 'pri'], ['Not now', 'dim']],
    refunded: [['Try again', 'pri'], ['Done', '']],
    unknown: [['Hide — we’ll notify you', 'pri']],
  }[st];
  const rowIc = good ? 'good' : bad ? 'bad' : warn ? 'warn' : 'live';
  const rowTxt = {
    resolving: 'Resolving destination…', paying: 'Sending · 6s', slow: 'Still trying · 48s',
    sent: 'Sent · proof stored', failed_safe: 'Not sent · not charged', refunded: 'Refunded to balance', unknown: 'Confirming · 2m',
  }[st];
  return (
    <Frame title="Payment">
      <div className="rs-sheet">
        <div className="rs-top">
          <span className="rs-spin">
            {live ? (
              <svg width="38" height="38" viewBox="0 0 38 38"><circle cx="19" cy="19" r="15" fill="none" stroke="var(--surface2)" strokeWidth="4" /><circle className="spin" cx="19" cy="19" r="15" fill="none" stroke={warn ? 'var(--gold-fill)' : 'var(--accent)'} strokeWidth="4" strokeLinecap="round" strokeDasharray="30 64" /></svg>
            ) : (
              <span className={'rs-ric ' + rowIc} style={{ width: 38, height: 38, borderRadius: 12 }}>
                <BCIcon name={good ? 'check' : 'x'} size={19} weight={2.6} />
              </span>
            )}
          </span>
          <span className="rs-t"><b>{h}</b><span>{PAYEE.name + ' · ' + PAYEE.sats.toLocaleString('en-US') + ' sats'}</span></span>
          {live ? <button className="rs-x"><BCIcon name="x" size={14} weight={2.4} /></button> : null}
        </div>
        <div className="rs-bar"><i className={good ? 'good' : bad ? 'bad' : ''} style={{ width: (bad ? 100 : pct) + '%' }}></i></div>
        <p className="rs-hint">{sub}</p>
        <div className="rs-acts">
          {acts.map(([t, k]) => <button key={t} className={'rs-act ' + k}>{t}</button>)}
        </div>
      </div>

      <div className="rs-lbl">In your wallet</div>
      <div className="rs-row">
        <span className={'rs-ric ' + rowIc}><BCIcon name={good ? 'check' : bad ? 'x' : 'bolt'} size={17} weight={2.3} /></span>
        <span className="rs-rmain"><b>{PAYEE.name}</b><span>{rowTxt}</span></span>
        <span className="rs-ramt" style={{ color: good ? 'var(--text)' : bad ? 'var(--text3)' : 'var(--text2)' }}>
          {bad ? '—' : '−' + PAYEE.sats.toLocaleString('en-US')}
        </span>
      </div>
      <p className="rs-note">This row keeps updating even if you close the sheet, leave the wallet, or background the app — the payment is owned by the wallet, not the screen.</p>
      <Money st={st} />
    </Frame>
  );
}

/* ── home surfaces: where an external payment lives in the chat list ── */
const HOME = {
  resolving:  { t: 'Preparing payment', s: 'Café Lumen · checking destination', tone: '', bar: 'Preparing payment' },
  paying:     { t: 'Sending 2,100 sats', s: 'Café Lumen · tap for details', tone: '', bar: 'Sending 2,100 sats' },
  slow:       { t: 'Taking longer than usual', s: 'Café Lumen · still in flight', tone: 'warn', bar: 'Payment taking longer' },
  sent:       { t: 'Sent 2,100 sats', s: 'Café Lumen · proof stored', tone: 'good', bar: 'Sent 2,100 sats' },
  failed_safe:{ t: 'Payment didn’t go through', s: 'Café Lumen · you weren’t charged', tone: 'bad', bar: 'Not sent · not charged' },
  refunded:   { t: 'Payment refunded', s: 'Café Lumen · 2,100 sats returned', tone: 'bad', bar: 'Refunded to your balance' },
  unknown:    { t: 'Confirming payment', s: 'Café Lumen · we’ll notify you', tone: 'warn', bar: 'Confirming payment' },
};

function MiniRing({ st, size = 34 }) {
  const good = st === 'sent', bad = st === 'failed_safe' || st === 'refunded';
  const warn = st === 'slow' || st === 'unknown';
  if (good || bad) {
    return (
      <span className="rs-ric" style={{ width: size, height: size, borderRadius: 11, flex: 'none',
        background: good ? 'var(--green)' : 'var(--danger)', color: '#fff' }}>
        <BCIcon name={good ? 'check' : 'x'} size={17} weight={2.6} />
      </span>
    );
  }
  const col = warn ? 'var(--gold-fill)' : 'var(--accent)';
  return (
    <svg width={size} height={size} viewBox="0 0 34 34" style={{ flex: 'none' }}>
      <circle cx="17" cy="17" r="13" fill="none" stroke="var(--surface2)" strokeWidth="3.5" />
      <circle className="spin" cx="17" cy="17" r="13" fill="none" stroke={col} strokeWidth="3.5" strokeLinecap="round" strokeDasharray="26 56" />
    </svg>
  );
}

const HOME_STATES_OK = true;

function HomeShell({ st, variant }) {
  const H = HOME[st];
  const app = { nick: 'quietfox', network: 'online', read: {}, verified: {}, groupMsgs: {}, dmMsgs: {}, prefs: {} };
  const meshCount = (BC_DATA.peers || []).filter((p) => p.inRange).length;
  return (
    <div className="bc-screen">
      <div className="bc-header">
        <button className="bc-iconbtn"><Avatar name={app.nick} size={32} /></button>
        <div className="bc-htitle sn-wordmark" style={{ paddingLeft: 0 }}>
          <img className="sn-brandchip lg" src="sonar/brand/sonar-icon.png" alt="" />
          sonar
        </div>
        <button className="bc-iconbtn"><BCIcon name="rings" size={22} /></button>
      </div>
      {variant === 'bar' ? (
        <div className={'hp-bar ' + H.tone}>
          <BCIcon name="bolt" size={14} weight={2.4} />
          {H.bar}
          <b>View</b>
        </div>
      ) : null}
      <StatusChip network={app.network} meshCount={meshCount} variant="pill" onToggle={() => {}} />
      <div className="bc-scroll" style={{ paddingBottom: 120 }}>
        {variant === 'strip' ? (
          <button className={'hp-strip ' + H.tone}>
            <MiniRing st={st} />
            <span className="hp-sm"><b>{H.t}</b><span>{H.s}</span></span>
            <BCIcon name="chevron" size={14} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
          </button>
        ) : null}
        <SectionLabel>Around you</SectionLabel>
        <HereCard onEnter={() => {}} />
        <SectionLabel>Saved channels</SectionLabel>
        <div className="bc-list">
          {(BC_DATA.channels || []).slice(0, 1).map((ch) => (
            <ConvRow key={ch.id} av={<PlaceTile size={52} />} title={<span>{ch.name}</span>}
              sub={<span>{ch.preview}</span>} time={ch.time} onClick={() => {}} />
          ))}
        </div>
        <SectionLabel>Messages</SectionLabel>
        <div className="bc-list">
          {variant === 'row' ? (
            <ConvRow
              av={<span className="hp-av hp-coin">₿</span>}
              title={<span>{'Café Lumen'}</span>}
              sub={<span>{H.t}</span>}
              time={<span className="hp-pamt">{st === 'failed_safe' || st === 'refunded' ? '—' : '−2,100'}</span>}
              onClick={() => {}} />
          ) : null}
          {(BC_DATA.groups || []).slice(0, 1).map((g) => (
            <ConvRow key={g.id} av={<GroupAvatar members={g.members} size={52} />}
              title={<span>{g.name}</span>} sub={<span>{g.preview}</span>} time={g.time} onClick={() => {}} />
          ))}
          {(BC_DATA.homeDMs || []).slice(0, 2).map((d) => {
            const peer = (BC_DATA.peers || []).find((p) => p.id === d.peer) || { name: d.peer };
            return (
              <ConvRow key={d.peer} av={<Avatar name={peer.name} size={52} presence={peer.inRange} />}
                title={<span>{peer.name}</span>}
                sub={<><BCIcon name="lock" size={12} weight={2.2} style={{ flex: 'none', color: 'var(--text3)' }} /><span>{d.preview}</span></>}
                time={d.time} onClick={() => {}} />
            );
          })}
        </div>
      </div>
      <div className="sn-fab">
        <button className="sn-search"><BCIcon name="search" size={17} weight={2} />Search</button>
        <button className="sn-compose"><BCIcon name="compose" size={22} weight={1.9} /></button>
      </div>
    </div>
  );
}

/* ── shell ──────────────────────────────────────────────────────────── */
function Bar({ st, set, play }) {
  return (
    <React.Fragment>
      {STATES.map((s) => (
        <button key={s.id} className={'sbtn' + (st === s.id ? ' on' : '')} onClick={() => set(s.id)}>{s.label}</button>
      ))}
      <button className="sbtn play" onClick={play}>▶ Run live</button>
    </React.Fragment>
  );
}

// mount: bar + 4 frames share one state

(function mount() {
  const barEl = document.getElementById('bar');
  const holder = document.createElement('span');
  barEl.appendChild(holder);
  const roots = {
    A: ReactDOM.createRoot(document.getElementById('fA')),
    B: ReactDOM.createRoot(document.getElementById('fB')),
    C: ReactDOM.createRoot(document.getElementById('fC')),
    D: ReactDOM.createRoot(document.getElementById('fD')),
    H1: ReactDOM.createRoot(document.getElementById('fH1')),
    H2: ReactDOM.createRoot(document.getElementById('fH2')),
    H3: ReactDOM.createRoot(document.getElementById('fH3')),
    bar: ReactDOM.createRoot(holder),
  };
  let st = 'paying';
  let timers = [];
  function set(next) { st = next; draw(); }
  function play() {
    timers.forEach(clearTimeout); timers = [];
    const seq = [['resolving', 0], ['paying', 1500], ['slow', 4200], ['sent', 7200]];
    seq.forEach(([s, d]) => timers.push(setTimeout(() => set(s), d)));
  }
  function draw() {
    roots.bar.render(<Bar st={st} set={set} play={play} />);
    roots.A.render(<DirA st={st} />);
    roots.B.render(<DirB st={st} />);
    roots.C.render(<DirC st={st} />);
    roots.D.render(<DirD st={st} />);
    roots.H1.render(<HomeShell st={st} variant="strip" />);
    roots.H2.render(<HomeShell st={st} variant="row" />);
    roots.H3.render(<HomeShell st={st} variant="bar" />);
  }
  draw();
})();

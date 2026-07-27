// Sonar — payments. Amounts are ALWAYS stored in sats internally.
// Display adapts to prefs: fiat by default (bitcoin hidden), or sats when btcMode is on.

const PAY_RATES = { EUR: 0.00058, USD: 0.00063, GBP: 0.00049, CHF: 0.00057 }; // fiat per 1 sat
const PAY_SYM   = { EUR: '€', USD: '$', GBP: '£', CHF: 'CHF ' };
const PAY_COIN  = { EUR: '€', USD: '$', GBP: '£', CHF: 'Fr' };
const PAY_NAMES = { EUR: 'Euro', USD: 'US Dollar', GBP: 'British Pound', CHF: 'Swiss Franc' };
const PAY_CURRENCIES = ['EUR', 'USD', 'GBP', 'CHF'];

function payFmt(sats) { return (sats || 0).toLocaleString('en-US'); }
function payFiatVal(sats, cur) { return (sats || 0) * (PAY_RATES[cur] || PAY_RATES.EUR); }
function payFiatStr(sats, cur) { return (PAY_SYM[cur] || '€') + payFiatVal(sats, cur).toFixed(2); }
function satsFromFiat(fiat, cur) { return Math.round(fiat / (PAY_RATES[cur] || PAY_RATES.EUR)); }

// Pull display prefs off app state (defaults: fiat / EUR)
function payPrefs(app) {
  const p = (app && app.prefs) || {};
  return { btcMode: !!p.btcMode, currency: p.currency || 'EUR' };
}
// One-line wallet/balance string for settings rows
function walletStr(app) {
  const { btcMode, currency } = payPrefs(app);
  const bal = (app && app.balance) || 0;
  return btcMode ? payFmt(bal) + ' sats' : payFiatStr(bal, currency);
}

/* ── amount block inside a bubble ── */
function PayAmount({ sats, pay }) {
  if (pay && pay.btcMode) {
    return (
      <span className="pay-main">
        <span className="pay-amount">{payFmt(sats)} <small>sats</small></span>
        <span className="pay-fiat">{payFiatStr(sats, pay.currency)}</span>
      </span>
    );
  }
  return (
    <span className="pay-main">
      <span className="pay-amount">{payFiatStr(sats, (pay && pay.currency) || 'EUR')}</span>
    </span>
  );
}

/* ── Pay bubble: a DIRECT payment to the peer's BOLT12 offer.
   Outgoing: pending → paid → confirmed (signed receipt) | failed.
   Incoming: received (lands straight in the wallet, no claim step). ── */
function PayBubble({ m, peerName, onTap, pay }) {
  const btc = pay && pay.btcMode;
  const cur = (pay && pay.currency) || 'EUR';
  const coin = btc ? '₿' : (PAY_COIN[cur] || '€');
  const viaIcon = m.via === 'mesh' ? 'mesh' : (btc ? 'bolt' : 'globe');
  const st = m.state || (m.mine ? 'paid' : 'received');
  let stateEl;
  if (m.mine) {
    if (st === 'pending') stateEl = <><span className="pay-spin"></span>Sending…</>;
    else if (st === 'failed') stateEl = <><BCIcon name="x" size={11} weight={2.6} style={{ color: 'var(--danger)' }} />{'Couldn’t send · tap to retry'}</>;
    else if (st === 'confirmed') stateEl = <><BCIcon name="shieldCheck" size={11} weight={2.4} style={{ color: 'var(--green)' }} />{'Confirmed by ' + peerName + ' · ' + m.time}</>;
    else stateEl = <><BCIcon name={viaIcon} size={11} weight={2.4} />{'Sent · ' + m.time}</>;
  } else {
    stateEl = <><BCIcon name={viaIcon} size={11} weight={2.4} />{'Received · ' + m.time}</>;
  }
  return (
    <div className={'bc-msg' + (m.mine ? ' mine' : '')}>
      <button className={'pay-card' + (st === 'pending' ? ' pending' : '') + (st === 'failed' ? ' failed' : '')} onClick={onTap || undefined}>
        <span className="pay-coin">{m.mine ? coin : <BCIcon name="download" size={20} weight={2.2} />}</span>
        <PayAmount sats={m.amount} pay={pay} />
      </button>
      <div className={'bc-state' + (st === 'failed' ? ' danger' : '')}>{stateEl}</div>
    </div>
  );
}

/* ── Payment detail: plain summary up top, technical proof in mono below ── */
function PayDetailSheet({ m, peerName, pay, onClose }) {
  const cur = (pay && pay.currency) || 'EUR';
  const st = m.state || (m.mine ? 'paid' : 'received');
  const statusLabel = { pending: 'Sending', paid: 'Sent', confirmed: 'Confirmed', failed: 'Failed', received: 'Received' }[st] || st;
  const proven = st === 'confirmed' || st === 'received';
  return (
    <Sheet onClose={onClose} title="Payment details">
      <div className="pay-amountbox" style={{ paddingTop: 2 }}>
        <div className="pay-big">{payFiatStr(m.amount, cur)}</div>
        <div className="pay-fiatline">{payFmt(m.amount)} sats</div>
      </div>
      <div className="st-card" style={{ margin: '8px 8px 4px' }}>
        <div className="pd-row"><span>Status</span><b className={st === 'failed' ? 'danger' : (proven ? 'ok' : '')}>{statusLabel}</b></div>
        <div className="pd-row"><span>{m.mine ? 'To' : 'From'}</span><b>{peerName}</b></div>
        <div className="pd-row"><span>Route</span><b>{m.via === 'mesh' ? 'Bluetooth · ecash' : 'Lightning · BOLT12'}</b></div>
        <div className="pd-row"><span>Time</span><b>{m.time}</b></div>
      </div>
      <div className="bc-sect" style={{ paddingLeft: 18 }}>Proof</div>
      <div className="pay-proof">
        <div><span>offer</span>lno1qcp4256ypqpq86q2pucnq42ngs…f0vxj</div>
        {proven
          ? <div><span>preimage</span>a3f9b2c41770e5b2d9e7c0f12a8b34d6…</div>
          : <div className="muted"><span>preimage</span>— awaiting settlement</div>}
        {m.mine ? <div><span>to npub</span>npub1{peerName.toLowerCase()}…q4k9dj</div> : <div><span>from npub</span>npub1{peerName.toLowerCase()}…q4k9dj</div>}
      </div>
      <p className="pay-note" style={{ padding: '8px 18px 2px' }}>
        {proven
          ? 'Receipt signed by ' + peerName + '. Note: a receipt proves the sender trusts the signer — not cryptographic settlement, until BOLT12 payer proofs ship.'
          : 'Waiting for ' + peerName + '’s wallet to settle and post a signed receipt.'}
      </p>
    </Sheet>
  );
}

/* ── Scan QR: camera viewfinder for bitcoin / Lightning / Bolt12 codes ── */
const SCAN_SAMPLES = [
  { name: 'Café Lumen', kind: 'invoice', label: 'lnbc21u1p3k9…q7f2n', sub: 'Lightning invoice · 2,100 sats requested', fixed: 2100 },
  { name: 'bc1q…8fz4', kind: 'onchain', label: 'bitcoin:bc1q9x2v…8fz4', sub: 'Bitcoin address · on-chain' },
  { name: 'Nostrica', kind: 'offer', label: 'lno1pg257…rtsq4k', sub: 'Bolt12 offer · reusable' },
];

function ScanQrSheet({ onClose, onDetect }) {
  const [found, setFound] = React.useState(null);
  React.useEffect(() => {
    const t = setTimeout(() => setFound(SCAN_SAMPLES[0]), 2200);
    return () => clearTimeout(t);
  }, []);
  return (
    <Sheet onClose={onClose} title="Scan to pay">
      {!found ? (
        <React.Fragment>
          <div className="scan-view">
            <div className="scan-frame">
              <i className="c tl"></i><i className="c tr"></i><i className="c bl"></i><i className="c br"></i>
              <div className="scan-line"></div>
            </div>
            <span className="scan-hint">Point at a bitcoin, Lightning or Bolt12 QR code</span>
          </div>
          <div className="scan-alts">
            {SCAN_SAMPLES.map((s) => (
              <button key={s.kind} className="scan-alt" onClick={() => setFound(s)}>{s.kind === 'invoice' ? 'Invoice' : s.kind === 'onchain' ? 'On-chain' : 'Bolt12'}</button>
            ))}
          </div>
          <p className="pay-note">Demo: a code is detected automatically, or pick one above.</p>
        </React.Fragment>
      ) : (
        <React.Fragment>
          <div className="scan-found">
            <span className="scan-foundic"><BCIcon name={found.kind === 'onchain' ? 'coin' : 'bolt'} size={22} /></span>
            <span className="sp-exmain">
              <span className="sp-exname">{found.name}</span>
              <span className="sp-exsub" style={{ color: 'var(--text2)' }}>{found.sub}</span>
            </span>
          </div>
          <div className="scan-code">{found.label}</div>
          <div className="bc-sheetactions">
            <button className="bc-primary net" onClick={() => onDetect({ name: found.name, kind: found.kind, inRange: false, fixed: found.fixed })}>
              {found.fixed ? 'Continue · ' + payFmt(found.fixed) + ' sats' : 'Enter amount'}
            </button>
            <button className="bc-ghost" onClick={() => setFound(null)}>Scan again</button>
          </div>
        </React.Fragment>
      )}
    </Sheet>
  );
}

/* ── Send Payment screen: pick a recipient (contact / username / Bolt12), then pay ── */
function SendPaymentScreen({ app, nav, pop, onPaid }) {
  const [q, setQ] = React.useState('');
  const [target, setTarget] = React.useState(null); // { name, kind, inRange }
  const [scan, setScan] = React.useState(false);
  const payers = (BC_DATA.peers || []).filter((p) => (p.caps || []).includes('payments'));
  const ql = q.trim().toLowerCase();
  const list = ql ? payers.filter((p) => p.name.toLowerCase().includes(ql)) : payers;
  const looksAddr = /@|^lno1|^npub1/i.test(q.trim());
  const pp = payPrefs(app);

  const chooseExternal = () => {
    const raw = q.trim();
    const isOffer = /^lno1/i.test(raw);
    setTarget({ name: raw.split('@')[0] || 'recipient', kind: isOffer ? 'offer' : 'username', label: raw, inRange: false });
  };

  return (
    <div className="bc-screen" data-nav={nav} data-screen-label="Send payment">
      <NavHeader onBack={pop} hairline={false}><div className="bc-hname"><span>Send payment</span></div></NavHeader>
      <div className="bc-scroll">
        <div className="pay-balance" style={{ justifyContent: 'flex-start', padding: '4px 18px 10px', fontSize: 13 }}>
          <BCIcon name="coin" size={14} weight={2} />
          Your balance · {walletStr(app)}
        </div>
        <div className="sp-field">
          <BCIcon name="search" size={17} weight={2} style={{ color: 'var(--text3)', flex: 'none' }} />
          <input className="bc-input" value={q} placeholder="Name, @username, name@domain or Bolt12…"
            spellCheck={false} autoCapitalize="none" autoCorrect="off"
            onChange={(e) => setQ(e.target.value)} />
        </div>

        <button className="sp-scan" onClick={() => setScan(true)}>
          <span className="sp-scanic"><BCIcon name="qr" size={20} /></span>
          <span className="sp-exmain">
            <span className="sp-exname">Scan a QR code</span>
            <span className="sp-exsub" style={{ color: 'var(--accent-deep)' }}>Bitcoin, Lightning invoice or Bolt12 offer</span>
          </span>
          <BCIcon name="chevron" size={15} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
        </button>

        {looksAddr && (
          <button className="sp-external" onClick={chooseExternal}>
            <span className="sp-exic"><BCIcon name={/^lno1/i.test(q.trim()) ? 'bolt' : 'globe'} size={19} /></span>
            <span className="sp-exmain">
              <span className="sp-exname">Pay “{q.trim()}”</span>
              <span className="sp-exsub">{/^lno1/i.test(q.trim()) ? 'Bolt12 offer · over Lightning' : 'Resolve address · over the internet'}</span>
            </span>
            <BCIcon name="chevron" size={15} weight={2.2} style={{ color: 'var(--text3)', flex: 'none' }} />
          </button>
        )}

        <SectionLabel>People you can pay</SectionLabel>
        <div className="bc-list">
          {list.length === 0 ? (
            <div className="wallet-empty" style={{ padding: '24px 20px' }}>No matching contacts. Try a username or Bolt12 offer above.</div>
          ) : list.map((p) => (
            <ConvRow
              key={p.id}
              av={<Avatar name={p.name} size={44} presence={p.inRange} />}
              title={<span>{p.name}</span>}
              sub={<span className="bc-signal">{p.inRange
                ? <><span className="sn-ldot ble" style={{ width: 8, height: 8, borderRadius: '50%', display: 'inline-block' }}></span>Nearby · Bluetooth</>
                : <><BCIcon name="bolt" size={12} weight={2.2} style={{ color: 'var(--net)', flex: 'none' }} />{p.bip353 || 'over Lightning'}</>}</span>}
              onClick={() => setTarget({ name: p.name, kind: 'contact', inRange: p.inRange, id: p.id })}
            />
          ))}
        </div>
        <p className="st-note">Only people who publish a payment address appear here. Payments settle directly to their wallet — no claim step.</p>
      </div>

      {scan && (
        <ScanQrSheet
          onClose={() => setScan(false)}
          onDetect={(t) => { setScan(false); setTarget(t); }}
        />
      )}
      {target && (
        <PaySheet
          peer={{ name: target.name }}
          balance={app.balance || 0}
          transport={target.inRange ? 'mesh' : 'internet'}
          pay={pp}
          fixed={target.fixed}
          onClose={() => setTarget(null)}
          onSend={(sats) => { setTarget(null); onPaid(target, sats); }}
        />
      )}
    </div>
  );
}

/* ── Amount sheet: balance, big amount, quick chips, keypad, transport-aware send ── */
const PAY_KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '00', '0', 'del'];
const PAY_CHIPS_SATS = [1000, 10000, 21000];
const PAY_CHIPS_FIAT = [5, 10, 20]; // whole-currency units

function PaySheet({ peer, balance, transport, pay, fixed, onClose, onSend }) {
  const btc = pay && pay.btcMode;
  const cur = (pay && pay.currency) || 'EUR';
  const [v, setV] = React.useState(fixed ? String(fixed) : '');
  const mesh = transport === 'mesh';

  // Interpret keypad input per mode → resolve to sats (the stored unit)
  let sats, bigEl, subLine, sendLabel;
  if (fixed) {
    sats = fixed;
    bigEl = btc
      ? <>{payFmt(fixed)}<small>sats</small></>
      : <>{payFiatStr(fixed, cur)}</>;
  } else if (btc) {
    sats = parseInt(v || '0', 10);
    bigEl = <>{v ? payFmt(sats) : '0'}<small>sats</small></>;
  } else {
    const fiat = parseInt(v || '0', 10) / 100; // cents-style entry
    sats = satsFromFiat(fiat, cur);
    bigEl = <>{PAY_SYM[cur]}{fiat.toFixed(2)}</>;
  }
  const over = sats > balance;
  const can = sats > 0 && !over;
  if (btc) {
    subLine = over ? 'Not enough sats' : payFiatStr(sats, cur);
    sendLabel = mesh ? 'Send over Bluetooth' : 'Send over Lightning';
  } else {
    subLine = over ? 'Not enough balance' : ' ';
    sendLabel = can ? 'Send ' + payFiatStr(sats, cur) : 'Enter an amount';
  }

  const tap = (k) => {
    if (k === 'del') { setV(v.slice(0, -1)); return; }
    const nv = (v + k).replace(/^0+(?=\d)/, '');
    if (nv.length <= 8) setV(nv);
  };
  const send = () => { if (can) { onSend(sats); onClose(); } };

  const note = btc
    ? (mesh
        ? 'Sent directly, phone-to-phone as ecash over Bluetooth — works offline.'
        : 'Paid directly to ' + peer.name + '’s reusable Lightning offer (BOLT12).')
    : (mesh
        ? 'Sent directly over Bluetooth — lands straight in ' + peer.name + '’s wallet, even offline.'
        : 'Paid directly to ' + peer.name + ' over the internet — lands straight in their wallet.');

  return (
    <Sheet onClose={onClose} title={(btc ? 'Send bitcoin · ' : 'Send money · ') + peer.name}>
      <div className="pay-balance">
        <BCIcon name="coin" size={13} weight={2} />
        Balance · {btc ? payFmt(balance) + ' sats' : payFiatStr(balance, cur)}
      </div>
      <div className="pay-amountbox">
        <div className={'pay-big' + (over ? ' over' : '')}>{bigEl}</div>
        <div className="pay-fiatline">{subLine}</div>
      </div>
      {!fixed && (
        <React.Fragment>
          <div className="pay-chips">
            {btc
              ? PAY_CHIPS_SATS.map((c) => (
                  <button key={c} className="pay-chip" onClick={() => setV(String(c))}>{payFmt(c)}</button>
                ))
              : PAY_CHIPS_FIAT.map((c) => (
                  <button key={c} className="pay-chip" onClick={() => setV(String(c * 100))}>{PAY_SYM[cur]}{c}</button>
                ))}
          </div>
          <div className="pay-pad">
            {PAY_KEYS.map((k) => (
              <button key={k} className="pay-key" onClick={() => tap(k)} aria-label={k === 'del' ? 'Delete' : k}>
                {k === 'del' ? <BCIcon name="back" size={18} weight={2.2} /> : k}
              </button>
            ))}
          </div>
        </React.Fragment>
      )}
      <div className="bc-sheetactions">
        <button className={'bc-primary' + (mesh ? '' : ' net')} disabled={!can} onClick={send}>
          {sendLabel}
        </button>
        <p className="pay-note">{note}</p>
      </div>
    </Sheet>
  );
}

/* ── Wallet activity: every incoming/outgoing transaction, newest first ── */
function WalletActivity({ app, txns }) {
  const { btcMode, currency } = payPrefs(app);
  const amt = (sats) => btcMode ? payFmt(sats) + ' sats' : payFiatStr(sats, currency);
  if (!txns || !txns.length) {
    return <div className="wallet-empty">No transactions yet.</div>;
  }
  return (
    <div className="wallet-tx">
      {txns.map((tx, i) => {
        const out = tx.dir === 'out';
        const stLabel = { pending: 'Pending', paid: 'Sent', confirmed: 'Confirmed', failed: 'Failed', received: 'Received' }[tx.state] || tx.state;
        return (
          <div key={i} className="wallet-txrow">
            <span className={'wallet-txicon ' + (out ? 'out' : 'in')}>
              <BCIcon name={out ? 'send' : 'download'} size={16} weight={2.2} />
            </span>
            <span className="wallet-txmain">
              <span className="wallet-txwho">{out ? 'To ' : 'From '}{tx.who || 'unknown'}</span>
              <span className="wallet-txmeta">{stLabel} · {tx.via === 'mesh' ? 'Bluetooth' : 'Lightning'} · {tx.time}</span>
            </span>
            <span className={'wallet-txamt' + (out ? '' : ' in') + (tx.state === 'failed' ? ' failed' : '')}>
              {out ? '−' : '+'}{amt(tx.amount)}
            </span>
          </div>
        );
      })}
    </div>
  );
}

Object.assign(window, {
  PayBubble, PaySheet, PayAmount, PayDetailSheet, WalletActivity, SendPaymentScreen, ScanQrSheet,
  payFmt, payFiatStr, payFiatVal, satsFromFiat, payPrefs, walletStr,
  PAY_CURRENCIES, PAY_NAMES, PAY_SYM,
});

// Sonar — bitcoin payments: sealed-coin pay bubble + amount sheet
// Rails mirror the transport story: ecash over Bluetooth in range, Lightning otherwise.

const SAT_EUR = 0.00058;
function payFiat(sats) { return '\u20ac' + (sats * SAT_EUR).toFixed(2); }
function payFmt(sats) { return (sats || 0).toLocaleString('en-US'); }

/* ── Pay bubble: money as a message. Incoming arrives sealed — tap to claim. ── */
function PayBubble({ m, peerName, onClaim }) {
  const sealed = m.state === 'sealed';
  const viaIcon = m.via === 'mesh' ? 'mesh' : 'bolt';
  if (m.mine) {
    return (
      <div className="bc-msg mine">
        <div className="pay-card">
          <span className="pay-coin">{'\u20bf'}</span>
          <span className="pay-main">
            <span className="pay-amount">{payFmt(m.amount)} <small>sats</small></span>
            <span className="pay-fiat">{payFiat(m.amount)}</span>
          </span>
        </div>
        <div className="bc-state">
          <BCIcon name={viaIcon} size={11} weight={2.4} />
          {sealed ? 'Sealed — waiting for ' + peerName + ' to claim' : 'Claimed by ' + peerName} · {m.time}
        </div>
      </div>
    );
  }
  if (sealed) {
    return (
      <div className="bc-msg">
        <button className="pay-card sealed" onClick={onClaim || undefined}>
          <span className="pay-coin pulse">{'\u20bf'}</span>
          <span className="pay-main">
            <span className="pay-sealedtitle">Payment from {peerName}</span>
            <span className="pay-fiat">Tap to claim</span>
          </span>
        </button>
        <div className="bc-state"><BCIcon name={viaIcon} size={11} weight={2.4} />Sealed for you · {m.time}</div>
      </div>
    );
  }
  return (
    <div className="bc-msg">
      <div className="pay-card reveal">
        <span className="pay-coin">{'\u20bf'}</span>
        <span className="pay-main">
          <span className="pay-amount">{payFmt(m.amount)} <small>sats</small></span>
          <span className="pay-fiat">{payFiat(m.amount)}</span>
        </span>
      </div>
      <div className="bc-state"><BCIcon name={viaIcon} size={11} weight={2.4} />Added to your balance · {m.time}</div>
    </div>
  );
}

/* ── Amount sheet: balance, big amount, quick chips, keypad, transport-aware send ── */
const PAY_KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '00', '0', 'del'];
const PAY_CHIPS = [1000, 10000, 21000];

function PaySheet({ peer, balance, transport, onClose, onSend }) {
  const [v, setV] = React.useState('');
  const sats = parseInt(v || '0', 10);
  const over = sats > balance;
  const can = sats > 0 && !over;
  const tap = (k) => {
    if (k === 'del') { setV(v.slice(0, -1)); return; }
    const nv = (v + k).replace(/^0+(?=\d)/, '');
    if (nv.length <= 7) setV(nv);
  };
  const send = () => { if (can) { onSend(sats); onClose(); } };
  const mesh = transport === 'mesh';
  return (
    <Sheet onClose={onClose} title={'Send bitcoin · ' + peer.name}>
      <div className="pay-balance">
        <BCIcon name="coin" size={13} weight={2} />
        Balance · {payFmt(balance)} sats
      </div>
      <div className="pay-amountbox">
        <div className={'pay-big' + (over ? ' over' : '')}>
          {v ? payFmt(sats) : '0'}<small>sats</small>
        </div>
        <div className="pay-fiatline">{over ? 'Not enough sats' : payFiat(sats)}</div>
      </div>
      <div className="pay-chips">
        {PAY_CHIPS.map((c) => (
          <button key={c} className="pay-chip" onClick={() => setV(String(c))}>{payFmt(c)}</button>
        ))}
      </div>
      <div className="pay-pad">
        {PAY_KEYS.map((k) => (
          <button key={k} className="pay-key" onClick={() => tap(k)} aria-label={k === 'del' ? 'Delete' : k}>
            {k === 'del' ? <BCIcon name="back" size={18} weight={2.2} /> : k}
          </button>
        ))}
      </div>
      <div className="bc-sheetactions">
        <button className={'bc-primary' + (mesh ? '' : ' net')} disabled={!can} onClick={send}>
          {mesh ? 'Send over Bluetooth' : 'Send over Lightning'}
        </button>
        <p className="pay-note">
          {mesh
            ? 'Travels phone-to-phone as ecash — works offline. Sealed until ' + peer.name + ' claims it.'
            : 'Instant over the Lightning network. Sealed until ' + peer.name + ' claims it.'}
        </p>
      </div>
    </Sheet>
  );
}

Object.assign(window, { PayBubble, PaySheet, payFmt, payFiat });

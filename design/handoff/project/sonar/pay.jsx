// Sonar — payments. Amounts are ALWAYS stored in sats internally.
// Display adapts to prefs: fiat by default (bitcoin hidden), or sats when btcMode is on.

const PAY_RATES = { EUR: 0.00058, USD: 0.00063, GBP: 0.00049, CHF: 0.00057 }; // fiat per 1 sat
const PAY_SYM   = { EUR: '\u20ac', USD: '$', GBP: '\u00a3', CHF: 'CHF\u00a0' };
const PAY_COIN  = { EUR: '\u20ac', USD: '$', GBP: '\u00a3', CHF: 'Fr' };
const PAY_NAMES = { EUR: 'Euro', USD: 'US Dollar', GBP: 'British Pound', CHF: 'Swiss Franc' };
const PAY_CURRENCIES = ['EUR', 'USD', 'GBP', 'CHF'];

function payFmt(sats) { return (sats || 0).toLocaleString('en-US'); }
function payFiatVal(sats, cur) { return (sats || 0) * (PAY_RATES[cur] || PAY_RATES.EUR); }
function payFiatStr(sats, cur) { return (PAY_SYM[cur] || '\u20ac') + payFiatVal(sats, cur).toFixed(2); }
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

/* ── Pay bubble: money as a message. Incoming arrives sealed — tap to claim. ── */
function PayBubble({ m, peerName, onClaim, pay }) {
  const sealed = m.state === 'sealed';
  const btc = pay && pay.btcMode;
  const cur = (pay && pay.currency) || 'EUR';
  const coin = btc ? '\u20bf' : (PAY_COIN[cur] || '\u20ac');
  const viaIcon = m.via === 'mesh' ? 'mesh' : (btc ? 'bolt' : 'globe');
  if (m.mine) {
    return (
      <div className="bc-msg mine">
        <div className="pay-card">
          <span className="pay-coin">{coin}</span>
          <PayAmount sats={m.amount} pay={pay} />
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
          <span className="pay-coin pulse">{coin}</span>
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
        <span className="pay-coin">{coin}</span>
        <PayAmount sats={m.amount} pay={pay} />
      </div>
      <div className="bc-state"><BCIcon name={viaIcon} size={11} weight={2.4} />Added to your balance · {m.time}</div>
    </div>
  );
}

/* ── Amount sheet: balance, big amount, quick chips, keypad, transport-aware send ── */
const PAY_KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '00', '0', 'del'];
const PAY_CHIPS_SATS = [1000, 10000, 21000];
const PAY_CHIPS_FIAT = [5, 10, 20]; // whole-currency units

function PaySheet({ peer, balance, transport, pay, onClose, onSend }) {
  const btc = pay && pay.btcMode;
  const cur = (pay && pay.currency) || 'EUR';
  const [v, setV] = React.useState('');
  const mesh = transport === 'mesh';

  // Interpret keypad input per mode → resolve to sats (the stored unit)
  let sats, bigEl, subLine, sendLabel;
  if (btc) {
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
    subLine = over ? 'Not enough balance' : '\u00a0';
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
        ? 'Travels phone-to-phone as ecash — works offline. Sealed until ' + peer.name + ' claims it.'
        : 'Instant over the Lightning network. Sealed until ' + peer.name + ' claims it.')
    : (mesh
        ? 'Sent privately, phone-to-phone over Bluetooth — even offline. Held safely until ' + peer.name + ' opens it.'
        : 'Sent privately over the internet. Held safely until ' + peer.name + ' opens it.');

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
      <div className="bc-sheetactions">
        <button className={'bc-primary' + (mesh ? '' : ' net')} disabled={!can} onClick={send}>
          {sendLabel}
        </button>
        <p className="pay-note">{note}</p>
      </div>
    </Sheet>
  );
}

Object.assign(window, {
  PayBubble, PaySheet, PayAmount,
  payFmt, payFiatStr, payFiatVal, satsFromFiat, payPrefs, walletStr,
  PAY_CURRENCIES, PAY_NAMES, PAY_SYM,
});

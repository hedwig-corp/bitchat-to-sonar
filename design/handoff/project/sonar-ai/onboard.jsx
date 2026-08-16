// Secret — onboarding: brand intro → identity (Sonar key) → where your AI runs

function SecretOnboarding({ onDone }) {
  const [step, setStep] = React.useState(0);
  const [imp, setImp] = React.useState(false);
  const [nsec, setNsec] = React.useState('');
  const [where, setWhere] = React.useState('pocket');
  const [paid, setPaid] = React.useState(false);

  return (
    <div className="bc-onboard" data-screen-label={'Onboarding ' + (step + 1)}>
      <div className="bc-obtop">{step > 0 && <button className="bc-iconbtn" onClick={() => { setStep(step - 1); setImp(false); }}><BCIcon name="back" size={20} /></button>}</div>
      {step === 0 &&
        <div className="bc-obbody" key="s0">
          <div className="bc-obmark ai-brandmark"><AIIcon name="sparkle" size={34} /></div>
          <h1 className="bc-obtitle">secret</h1>
          <p className="bc-obsub">A private AI that answers only to you.</p>
          <div className="bc-obrow"><span className="bc-obrowicon"><BCIcon name="key" size={18} /></span><div><div className="bc-obrowtitle">No account</div><div className="bc-obrowdesc">Your Nostr key is the login. History syncs end-to-end encrypted across your devices.</div></div></div>
          <div className="bc-obrow"><span className="bc-obrowicon"><BCIcon name="shieldCheck" size={18} /></span><div><div className="bc-obrowtitle">Private by default</div><div className="bc-obrowdesc">Runs on this iPhone, or sealed with your key to compute you choose. Relays only ever see ciphertext.</div></div></div>
          <div className="bc-obrow"><span className="bc-obrowicon"><BCIcon name="bolt" size={18} /></span><div><div className="bc-obrowtitle">No subscription</div><div className="bc-obrowdesc">Optionally pay frontier models per request over Lightning — anonymous, a few sats each.</div></div></div>
        </div>}
      {step === 1 &&
        <div className="bc-obbody" key="s1">
          <div className="bc-obmark ai-brandmark"><BCIcon name="key" size={30} /></div>
          <h1 className="bc-obtitle">One identity</h1>
          <p className="bc-obsub">Secret found your Sonar key — same name, same npub, everywhere.</p>
          {!imp ? (
            <React.Fragment>
              <div className="st-prof" style={{ margin: 0, width: '100%', cursor: 'default' }}>
                <Avatar name="quietfox" size={48} />
                <span className="st-profmain">
                  <span className="st-profname">quietfox</span>
                  <span className="st-profkey">{AI_DATA.npub}</span>
                </span>
              </div>
              <p className="bc-note">Chats, memory and tool grants stay sealed with this key. Sonar Messenger contacts are never shared with models.</p>
            </React.Fragment>
          ) : (
            <React.Fragment>
              <textarea className="bc-nsecinput" rows={3} placeholder="nsec1…" value={nsec} onChange={(e) => setNsec(e.target.value)} />
              <p className="bc-note">Your secret key never leaves the device. It unlocks your existing encrypted history from relays.</p>
            </React.Fragment>
          )}
        </div>}
      {step === 2 &&
        <div className="bc-obbody" key="s2">
          <div className="bc-obmark ai-brandmark"><AIIcon name="cpu" size={30} /></div>
          <h1 className="bc-obtitle">Where should your AI run?</h1>
          <p className="bc-obsub">You can switch per chat — bubble colors always show where a prompt went.</p>
          {AI_DATA.models.filter((m) => m.where !== 'dvm').map((m) =>
            <button key={m.id} className="md-row" style={{ padding: '11px 4px' }} onClick={() => setWhere(m.id)}>
              <span className={'md-ic' + (aiRemote(m) ? ' remote' : '')}><AIIcon name={m.where === 'device' ? 'cpu' : 'drive'} size={18} /></span>
              <span className="md-main"><span className="md-name">{m.name}</span><span className="md-sub">{m.sub}</span></span>
              <span className={'ng-check' + (where === m.id ? ' on' : '')}>{where === m.id && <BCIcon name="check" size={13} weight={2.6} />}</span>
            </button>)}
          <button className="md-row" style={{ padding: '11px 4px' }} onClick={() => setPaid(!paid)}>
            <span className="md-ic" style={{ background: 'var(--gold-soft)', color: 'var(--gold-deep)' }}><BCIcon name="bolt" size={17} /></span>
            <span className="md-main"><span className="md-name">Enable paid models</span><span className="md-sub">Frontier models via Lightning · 3–21 sats per request</span></span>
            <span className={'st-switch' + (paid ? ' on' : '')}></span>
          </button>
        </div>}
      <div className="bc-obfooter">
        <div className="bc-dots">{[0, 1, 2].map((i) => <span key={i} className={i === step ? 'on' : ''}></span>)}</div>
        <button className="bc-primary ai-brandfill" onClick={() => {
          if (step < 2) setStep(step + 1);
          else onDone({ defaultModel: where, payper: paid });
        }}>{step === 0 ? 'Get started' : step === 1 ? (imp ? 'Import key' : 'Continue as quietfox') : 'Start chatting'}</button>
        {step === 1 && !imp && <button className="bc-ghost" onClick={() => setImp(true)}>Import a different key</button>}
      </div>
    </div>);
}

Object.assign(window, { SecretOnboarding });

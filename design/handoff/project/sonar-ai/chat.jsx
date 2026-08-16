// Sonar AI — chat thread: streaming, tool calls, permissions, model switching

function AiChatScreen({ app, nav, pop, chatId, onAppend, onSetModel, onGrant, onRetitle, onSpend }) {
  const chat = AI_DATA.chats.find((c) => c.id === chatId) || { id: chatId, title: 'New chat' };
  const modelId = app.chatModel[chatId] || chat.model || app.defaultModel;
  const model = aiModel(modelId);
  const remote = aiRemote(model);
  const msgs = app.msgs[chatId] || [];
  const grants = app.grants[chatId] || {};

  const [run, setRun] = React.useState(null); // {phase:'think'|'tool'|'stream', tool, text}
  const [perm, setPerm] = React.useState(null); // {server,name,args,amount,resolve}
  const [sheet, setSheet] = React.useState(null); // 'model' | 'tools'
  const alive = React.useRef(true);
  const once = React.useRef({});
  React.useEffect(() => () => { alive.current = false; }, []);

  const scroller = React.useRef(null);
  React.useEffect(() => {
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [msgs.length, run]);

  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const ask = (st) => new Promise((resolve) => setPerm({ server: st.server, name: st.name, args: st.args, amount: st.amount, resolve }));

  async function execute(steps, mdl) {
    for (const st of steps) {
      if (!alive.current) return;
      if (st.t === 'think') { setRun({ phase: 'think' }); await wait(st.ms || 900); }
      else if (st.t === 'tool') {
        const c = aiConn(st.server);
        const granted = !c.sensitive && ((app.grants[chatId] || {})[st.server] || once.current[st.server]);
        if (!granted) {
          const ans = await ask(st);
          setPerm(null);
          if (ans === 'deny') {
            setRun(null);
            onAppend(chatId, { role: 'ai', model: mdl.id, time: aiNow(), text: 'Okay — I stopped there. Nothing was shared with ' + c.name + '.' });
            return;
          }
          if (ans === 'always') onGrant(chatId, st.server);
          else once.current[st.server] = true;
        }
        setRun({ phase: 'tool', tool: st });
        await wait(st.ms || 1400);
        if (!alive.current) return;
        onAppend(chatId, { tool: true, server: st.server, name: st.name, args: st.args, result: st.result, time: aiNow() });
        setRun({ phase: 'think' });
        await wait(350);
      }
      else if (st.t === 'say') {
        const words = st.text.split(' ');
        let cur = '';
        for (let i = 0; i < words.length; i++) {
          if (!alive.current) return;
          cur += (i ? ' ' : '') + words[i];
          setRun({ phase: 'stream', text: cur });
          await wait(26);
        }
        await wait(200);
        onAppend(chatId, { role: 'ai', model: mdl.id, time: aiNow(), text: st.text });
        setRun(null);
      }
    }
    if (mdl.price) {
      onAppend(chatId, { receipt: true, sats: mdl.price, time: aiNow() });
      onSpend(mdl.price);
    }
    setRun(null);
  }

  const scenarioFor = (text) => {
    const s = AI_DATA.scenarios;
    if (/day|calendar|thursday|schedule/i.test(text)) return s.day;
    if (/pay|invoice|sats|wallet/i.test(text)) return s.pay;
    if (/marmot|search|web|news|spec/i.test(text)) return s.web;
    if (/note|meeting|summar/i.test(text)) return s.notes;
    return { steps: [{ t: 'think', ms: 1100 }, { t: 'say', text: AI_DATA.generic[(text.length) % AI_DATA.generic.length] }] };
  };

  const send = (text) => {
    if (run) return;
    onAppend(chatId, { role: 'user', text, via: model.where, time: aiNow() });
    if (msgs.length === 0 && chat.title === 'New chat') onRetitle(chatId, text.length > 30 ? text.slice(0, 30) + '…' : text);
    execute(scenarioFor(text).steps, model);
  };
  const sendChip = (key) => {
    if (run) return;
    const sc = AI_DATA.scenarios[key];
    onAppend(chatId, { role: 'user', text: sc.chip, via: model.where, time: aiNow() });
    if (chat.title === 'New chat') onRetitle(chatId, sc.chip);
    execute(sc.steps, model);
  };

  return (
    <div className="bc-screen" data-nav={nav}>
      <NavHeader onBack={pop} trailing={
        <button className="bc-iconbtn" onClick={() => setSheet('tools')} title="Tools in this chat"><AIIcon name="wrench" size={19} /></button>
      }>
        <button className="bc-headtap" onClick={() => setSheet('model')}>
          <span className={'md-ic' + (remote ? ' remote' : '')} style={{ width: 36, height: 36, borderRadius: 12 }}><AIIcon name={model.where === 'device' ? 'cpu' : model.where === 'node' ? 'drive' : 'sparkle'} size={17} /></span>
          <span style={{ minWidth: 0 }}>
            <span className="bc-hname"><span data-screen-label="Chat">{chat.title}</span></span>
            <span className="bc-hsub"><ModelDot model={model} size={7} />{model.name} · {model.where === 'device' ? 'on this iPhone' : model.where === 'node' ? 'your node' : model.price + ' sats/request'}<BCIcon name="chevron" size={11} style={{ transform: 'rotate(90deg)' }} /></span>
          </span>
        </button>
      </NavHeader>
      {msgs.length === 0 ?
        <div className="ai-hero" data-screen-label="New chat">
          <span className={'ai-heromark' + (remote ? ' remote' : '')}><AIIcon name="sparkle" size={28} /></span>
          <span className="ai-herotitle">{remote ? 'Private, even when remote' : 'Private by default'}</span>
          <span className="ai-herosub">{remote ? 'Prompts are sealed to ' + model.name + ' with your key. Relays carry only ciphertext.' : model.name + ' runs on this iPhone. Nothing you type leaves it.'}</span>
          <div className="ai-chips">
            {Object.entries(AI_DATA.scenarios).map(([key, sc]) =>
              <button key={key} className="ai-chip" onClick={() => sendChip(key)}>
                <AIIcon name={key === 'day' ? 'clock' : key === 'pay' ? 'bolt' : key === 'web' ? 'search' : 'doc'} size={16} />{sc.chip}
              </button>)}
          </div>
        </div>
        :
        <div className="bc-msgs" ref={scroller}>
          {msgs.map((m, i) =>
            m.tool ? <ToolCard key={i} m={m} /> :
            m.receipt ? <AiReceipt key={i} m={m} /> :
            m.role === 'user' ? <AiUserMsg key={i} m={m} /> :
            <AiTurn key={i} m={m} />)}
          {run && run.phase === 'think' && <AiThinking model={model} />}
          {run && run.phase === 'tool' && <ToolCard m={run.tool} running />}
          {run && run.phase === 'stream' && <AiTurn m={{ model: model.id, text: run.text }} streaming />}
        </div>}
      <Composer placeholder={'Ask ' + model.name + '…'} transport={remote ? 'internet' : 'mesh'} onSend={send} />
      {sheet === 'model' && <ModelSheet current={modelId} paid={app.prefs.payper} onPick={(id) => onSetModel(chatId, id)} onClose={() => setSheet(null)} />}
      {sheet === 'tools' && <ToolsSheet grants={grants} onToggle={(id) => onGrant(chatId, id, true)} onClose={() => setSheet(null)} />}
      {perm && <PermSheet req={perm} onAnswer={(ans) => perm.resolve(ans)} />}
    </div>);
}

Object.assign(window, { AiChatScreen });

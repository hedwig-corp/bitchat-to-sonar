// Sonar — voice & video calls. Encrypted, transport-aware (Bluetooth in range / internet otherwise).
// One <CallView> fills its container; mobile pushes it as a screen, desktop shows it as an overlay.

function fmtCall(sec) {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return m + ':' + ('0' + s).slice(-2);
}

function CallView({ peer, kind, transport, nick, onEnd }) {
  const video = kind === 'video';
  const mesh = transport === 'mesh';
  const [phase, setPhase] = React.useState('ringing'); // ringing → connected
  const [secs, setSecs] = React.useState(0);
  const [muted, setMuted] = React.useState(false);
  const [speaker, setSpeaker] = React.useState(video);
  const [camOn, setCamOn] = React.useState(true);
  const hue = bcHash(peer.name) % 360;

  React.useEffect(() => {
    const t = setTimeout(() => setPhase('connected'), 2000);
    return () => clearTimeout(t);
  }, []);
  React.useEffect(() => {
    if (phase !== 'connected') return;
    const id = setInterval(() => setSecs((s) => s + 1), 1000);
    return () => clearInterval(id);
  }, [phase]);

  const end = () => onEnd(phase === 'connected' ? secs : 0);
  const status = phase === 'ringing'
    ? (video ? 'Ringing…' : 'Calling…')
    : fmtCall(secs);
  const encLine = (mesh ? 'Bluetooth' : 'internet');

  return (
    <div className={'call' + (video ? ' video' : '')} data-screen-label={(video ? 'Video' : 'Voice') + ' call: ' + peer.name}>
      {video && (
        <div className="call-remote" style={{ '--rh': hue }}>
          {phase === 'connected' && camOn ? (
            <div className="call-feed"></div>
          ) : (
            <div className="call-remoteoff">
              <Avatar name={peer.name} size={120} />
            </div>
          )}
          <div className="call-vignette"></div>
        </div>
      )}

      <div className="call-top">
        <span className="call-enc">
          <BCIcon name="lock" size={12} weight={2.4} />
          End-to-end encrypted · {encLine}
        </span>
        {video && (
          <div className="call-topnames">
            <span className="call-topname">{peer.name}</span>
            <span className="call-toptime">{status}</span>
          </div>
        )}
      </div>

      {!video && (
        <div className="call-center">
          <span className={'call-avatar' + (phase === 'ringing' ? ' ringing' : '')}>
            <Avatar name={peer.name} size={132} presence={false} />
          </span>
          <div className="call-name">{peer.name}</div>
          <div className="call-sub">{status}</div>
        </div>
      )}

      {video && phase === 'connected' && camOn && (
        <div className="call-pip">
          <div className="call-pipfeed" style={{ '--sh': bcHash(nick || 'you') % 360 }}></div>
          <span className="call-piplabel">you</span>
        </div>
      )}

      <div className="call-controls">
        <button className={'call-btn' + (muted ? ' active' : '')} onClick={() => setMuted(!muted)} aria-label="Mute">
          <BCIcon name={muted ? 'micOff' : 'mic'} size={23} weight={1.9} />
          <span>{muted ? 'Unmute' : 'Mute'}</span>
        </button>
        {video ? (
          <button className={'call-btn' + (!camOn ? ' active' : '')} onClick={() => setCamOn(!camOn)} aria-label="Camera">
            <BCIcon name={camOn ? 'videocam' : 'videoOff'} size={23} weight={1.9} />
            <span>{camOn ? 'Stop video' : 'Start video'}</span>
          </button>
        ) : (
          <button className={'call-btn' + (speaker ? ' active' : '')} onClick={() => setSpeaker(!speaker)} aria-label="Speaker">
            <BCIcon name="speaker" size={23} weight={1.9} />
            <span>Speaker</span>
          </button>
        )}
        {video ? (
          <button className="call-btn" aria-label="Flip camera">
            <BCIcon name="cameraFlip" size={23} weight={1.9} />
            <span>Flip</span>
          </button>
        ) : (
          <button className="call-btn" onClick={() => { /* upgrade to video — demo */ }} aria-label="Add video">
            <BCIcon name="videocam" size={23} weight={1.9} />
            <span>Video</span>
          </button>
        )}
        <button className="call-btn end" onClick={end} aria-label="End call">
          <BCIcon name="phoneDown" size={23} weight={1.9} />
          <span>End</span>
        </button>
      </div>
    </div>
  );
}

/* Compact call-log row shown inside the message list after a call ends */
function CallLog({ m, peerName }) {
  const missed = m.missed;
  const icon = m.kind === 'video' ? 'videocam' : 'phone';
  const label = missed
    ? (m.kind === 'video' ? 'Missed video call' : 'Missed call')
    : (m.mine ? 'Outgoing ' : 'Incoming ') + (m.kind === 'video' ? 'video call' : 'call');
  return (
    <div className="call-log">
      <span className={'call-logicon' + (missed ? ' missed' : '')}><BCIcon name={icon} size={15} weight={2} /></span>
      <span className="call-logmain">
        <span className="call-loglabel">{label}</span>
        {!missed && m.dur ? <span className="call-logdur"> · {m.dur}</span> : null}
      </span>
      <span className="call-logtime">{m.time}</span>
    </div>
  );
}

Object.assign(window, { CallView, CallLog, fmtCall });

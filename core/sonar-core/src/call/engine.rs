//! `CallEngine` — the 1:1 P2P call state machine (plan §5.2).
//!
//! It orchestrates [`CallTransport`] (the iroh QUIC endpoint), the cpal/opus
//! media pipeline ([`super::media::run_audio_session`] + [`super::device`]), and
//! a small per-call state map, emitting [`CallEvent`]s the host parks for via
//! [`CallEngine::next_event`] (mirroring `SonarClient::wait_for_marmot_event`).
//!
//! It is **transport-agnostic about signaling**: it never sends a `☎CALL` line
//! itself. The host serializes OFFER/ANSWER/END (built from
//! [`CallEngine::local_addr_b64`]) over the existing Marmot/NIP-17 channels and
//! feeds inbound control lines back in via [`on_incoming_offer`]/[`on_answer`].
//! This keeps every Marmot send on the host's serialized engine queue — the call
//! subsystem touches **no** MLS state (the single-thread MLS invariant).
//!
//! Roles (plan §4.3): the **offerer** waits in the endpoint's accept loop and
//! admits only the inbound connection whose QUIC-authenticated id matches the
//! answerer it pinned from `ANSWER|accept`; the **answerer** dials the offerer in
//! [`accept`]. Either way, both ends run [`connect_media`] once connected.
//!
//! [`on_answer`]: CallEngine::on_answer
//! [`on_incoming_offer`]: CallEngine::on_incoming_offer
//! [`accept`]: CallEngine::accept

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use opus::Channels;
use tokio::sync::{mpsc, Mutex};

use iroh::endpoint::Connection;
use iroh::{EndpointAddr, EndpointId};

use crate::call::device::{self, AudioDevice};
use crate::call::media::run_audio_session;
use crate::call::signaling::{AnswerKind, CallMediaKind};
use crate::call::transport::{decode_addr, rtc_session, CallTransport};

/// How long the offerer's accept loop waits for an inbound connection's id to be
/// pinned by a still-arriving `ANSWER` before rejecting it (the answerer's dial
/// can beat its own ANSWER over a different transport).
const PIN_GRACE: Duration = Duration::from_secs(15);
/// Poll interval while waiting for the pin (above).
const PIN_POLL: Duration = Duration::from_millis(100);

/// Call audio is mono 48 kHz (matching [`device`]'s 20 ms frames).
const CALL_CHANNELS: Channels = Channels::Mono;

/// Public call state surfaced to the host UI (maps 1:1 to the FFI enum later).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallStateKind {
    /// Offer sent / received, not yet connected.
    Ringing,
    /// Dialing or accepting the iroh connection.
    Connecting,
    /// Media flowing.
    Connected,
    /// The call finished (see `duration_secs`).
    Ended,
    /// Setup failed (see `reason`).
    Failed,
    /// The answerer declined.
    Declined,
    /// The answerer was already in a call.
    Busy,
    /// An offer arrived too stale to ring (host-detected; surfaced for symmetry).
    Missed,
}

/// A state change for one call, drained by [`CallEngine::next_event`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallEvent {
    pub call_id: String,
    pub state: CallStateKind,
    /// Connected duration in seconds — only meaningful for [`CallStateKind::Ended`].
    pub duration_secs: u64,
    /// Human-readable reason for `Ended`/`Failed`/`Declined`/`Busy` (else empty).
    pub reason: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    Offerer,
    Answerer,
}

/// Per-call bookkeeping. Short-lived locks only — never held across `.await`.
struct CallSlot {
    role: Role,
    #[allow(dead_code)]
    media: CallMediaKind,
    state: CallStateKind,
    /// The pinned peer endpoint id: set from the OFFER (answerer) or the
    /// `ANSWER|accept` (offerer). Inbound media is admitted ONLY from this id.
    remote_id: Option<EndpointId>,
    /// The offerer's address, stored on the answerer so [`CallEngine::accept`]
    /// can dial it.
    dial_addr: Option<EndpointAddr>,
    local_muted: bool,
    connected_at: Option<Instant>,
    active: Option<ActiveCall>,
}

/// Live media resources for one connected call. Dropping it tears the call down:
/// closes the QUIC connection, ends the opus/RTP session, stops the close
/// watcher, and (via their own `Drop`) stops the cpal capture/playback threads.
struct ActiveCall {
    conn: Connection,
    _capture: Option<AudioDevice>,
    _playback: Option<AudioDevice>,
    /// Held mic sender so the session's send loop parks (instead of ending) when
    /// there is no capture device (hermetic/no-mic case); dropped on teardown.
    _mic_tx: mpsc::Sender<Vec<i16>>,
    muted: Arc<AtomicBool>,
    session: tokio::task::JoinHandle<()>,
    watch: tokio::task::JoinHandle<()>,
}

impl Drop for ActiveCall {
    fn drop(&mut self) {
        self.conn.close(0u32.into(), b"bye");
        self.session.abort();
        self.watch.abort();
    }
}

struct Inner {
    transport: CallTransport,
    calls: StdMutex<HashMap<String, CallSlot>>,
    events_tx: mpsc::UnboundedSender<CallEvent>,
}

impl Inner {
    fn emit(&self, call_id: &str, state: CallStateKind, duration_secs: u64, reason: &str) {
        let _ = self.events_tx.send(CallEvent {
            call_id: call_id.to_string(),
            state,
            duration_secs,
            reason: reason.to_string(),
        });
    }
}

/// Owns the iroh endpoint + the accept loop for one app session; drives every
/// 1:1 call. Created lazily inside `SonarNode` (it reuses that runtime).
pub struct CallEngine {
    inner: Arc<Inner>,
    events_rx: Mutex<mpsc::UnboundedReceiver<CallEvent>>,
    accept_task: tokio::task::JoinHandle<()>,
}

impl Drop for CallEngine {
    fn drop(&mut self) {
        self.accept_task.abort();
    }
}

impl CallEngine {
    /// Bind the iroh endpoint (with relays, for real NAT-traversing calls) and
    /// start the accept loop. `iroh_secret` is the host-persisted 32-byte key
    /// (derive it via [`super::identity::derive_iroh_secret`]).
    pub async fn start(iroh_secret: [u8; 32]) -> Result<Self> {
        Self::from_transport(CallTransport::bind(iroh_secret).await?)
    }

    /// Relay-less bind (direct addresses only) for hermetic same-host tests.
    #[cfg(test)]
    pub(crate) async fn start_relay_less(iroh_secret: [u8; 32]) -> Result<Self> {
        Self::from_transport(CallTransport::bind_relay_less(iroh_secret).await?)
    }

    fn from_transport(transport: CallTransport) -> Result<Self> {
        let (events_tx, events_rx) = mpsc::unbounded_channel();
        let inner = Arc::new(Inner {
            transport,
            calls: StdMutex::new(HashMap::new()),
            events_tx,
        });
        let accept_inner = inner.clone();
        let accept_task = tokio::spawn(accept_loop(accept_inner));
        Ok(Self {
            inner,
            events_rx: Mutex::new(events_rx),
            accept_task,
        })
    }

    /// Our dialable address as the `nodeAddrB64` token for an OFFER/ANSWER.
    pub fn local_addr_b64(&self) -> Result<String> {
        self.inner.transport.local_addr_b64()
    }

    /// Begin an OUTGOING call (offerer): register it `Ringing` and return at once.
    /// The host then sends the `☎CALL OFFER` (carrying [`local_addr_b64`]) over
    /// the peer's encrypted transport.
    ///
    /// [`local_addr_b64`]: CallEngine::local_addr_b64
    pub fn place(&self, call_id: &str, media: CallMediaKind) -> Result<()> {
        self.inner.calls.lock().unwrap().insert(
            call_id.to_string(),
            CallSlot {
                role: Role::Offerer,
                media,
                state: CallStateKind::Ringing,
                remote_id: None,
                dial_addr: None,
                local_muted: false,
                connected_at: None,
                active: None,
            },
        );
        self.inner.emit(call_id, CallStateKind::Ringing, 0, "");
        Ok(())
    }

    /// The offerer received the peer's `ANSWER` (host-parsed). On `accept`, pin
    /// the answerer's id (the accept loop then admits its inbound dial) and go
    /// `Connecting`; on `decline`/`busy`, end the call with the matching state.
    pub fn on_answer(
        &self,
        call_id: &str,
        answer: AnswerKind,
        remote_addr_b64: &str,
    ) -> Result<()> {
        match answer {
            AnswerKind::Decline => {
                self.end_call(call_id, CallStateKind::Declined, "declined");
                return Ok(());
            }
            AnswerKind::Busy => {
                self.end_call(call_id, CallStateKind::Busy, "busy");
                return Ok(());
            }
            AnswerKind::Accept => {}
        }
        let addr = decode_addr(remote_addr_b64).context("decode answerer address")?;
        {
            let mut calls = self.inner.calls.lock().unwrap();
            let slot = calls
                .get_mut(call_id)
                .ok_or_else(|| anyhow!("on_answer for unknown call {call_id}"))?;
            slot.remote_id = Some(addr.id);
            slot.state = CallStateKind::Connecting;
        }
        self.inner.emit(call_id, CallStateKind::Connecting, 0, "");
        Ok(())
    }

    /// The host parsed an inbound `☎CALL OFFER`. Register the incoming call
    /// (`Ringing`), pinning + storing the offerer's address so [`accept`] can dial.
    ///
    /// [`accept`]: CallEngine::accept
    pub fn on_incoming_offer(
        &self,
        call_id: &str,
        remote_addr_b64: &str,
        media: CallMediaKind,
    ) -> Result<()> {
        let addr = decode_addr(remote_addr_b64).context("decode offerer address")?;
        self.inner.calls.lock().unwrap().insert(
            call_id.to_string(),
            CallSlot {
                role: Role::Answerer,
                media,
                state: CallStateKind::Ringing,
                remote_id: Some(addr.id),
                dial_addr: Some(addr),
                local_muted: false,
                connected_at: None,
                active: None,
            },
        );
        self.inner.emit(call_id, CallStateKind::Ringing, 0, "");
        Ok(())
    }

    /// The user accepted an incoming call: we are the dialer (§4.3). Dial the
    /// offerer, verify the pinned id, and start media. The host also sends the
    /// `☎CALL ANSWER|accept` (carrying [`local_addr_b64`]).
    ///
    /// [`local_addr_b64`]: CallEngine::local_addr_b64
    pub async fn accept(&self, call_id: &str) -> Result<()> {
        let (addr, pinned) = {
            let calls = self.inner.calls.lock().unwrap();
            let slot = calls
                .get(call_id)
                .ok_or_else(|| anyhow!("accept for unknown call {call_id}"))?;
            let addr = slot
                .dial_addr
                .clone()
                .ok_or_else(|| anyhow!("accept for call {call_id} with no offerer address"))?;
            (addr, slot.remote_id)
        };
        self.set_state(call_id, CallStateKind::Connecting);
        let conn = self
            .inner
            .transport
            .connect(addr)
            .await
            .context("dial offerer")?;
        if let Some(pin) = pinned {
            if conn.remote_id() != pin {
                conn.close(0u32.into(), b"id mismatch");
                self.end_call(call_id, CallStateKind::Failed, "peer id mismatch");
                return Err(anyhow!("dialed peer id mismatch"));
            }
        }
        connect_media(self.inner.clone(), call_id.to_string(), conn).await
    }

    /// Hang up (or cancel) a call: tear down media + connection and emit `Ended`
    /// (with the connected duration).
    pub fn hangup(&self, call_id: &str) -> Result<()> {
        self.end_call(call_id, CallStateKind::Ended, "hangup");
        Ok(())
    }

    /// Toggle the local microphone without changing the media session. Muting
    /// sends silence frames on the existing RTP stream so the remote jitter
    /// buffer and timing stay stable.
    pub fn set_muted(&self, call_id: &str, muted: bool) -> Result<()> {
        let mut calls = self.inner.calls.lock().unwrap();
        let slot = calls
            .get_mut(call_id)
            .ok_or_else(|| anyhow!("set_muted for unknown call {call_id}"))?;
        slot.local_muted = muted;
        if let Some(active) = &slot.active {
            active.muted.store(muted, Ordering::Relaxed);
        }
        Ok(())
    }

    /// Park up to `timeout_secs` for the next call state change. The host polls
    /// this on a dedicated thread (like `waitForMarmotEvent`); it touches no MLS
    /// state. Returns `None` on timeout.
    pub async fn next_event(&self, timeout_secs: u64) -> Option<CallEvent> {
        let mut rx = self.events_rx.lock().await;
        match tokio::time::timeout(Duration::from_secs(timeout_secs), rx.recv()).await {
            Ok(ev) => ev,
            Err(_) => None,
        }
    }

    fn set_state(&self, call_id: &str, state: CallStateKind) {
        if let Some(slot) = self.inner.calls.lock().unwrap().get_mut(call_id) {
            slot.state = state;
        }
        self.inner.emit(call_id, state, 0, "");
    }

    /// Remove the call (tearing down its [`ActiveCall`]) and emit `state`.
    fn end_call(&self, call_id: &str, state: CallStateKind, reason: &str) {
        let removed = self.inner.calls.lock().unwrap().remove(call_id);
        let duration = removed
            .as_ref()
            .and_then(|s| s.connected_at)
            .map(|t| t.elapsed().as_secs())
            .unwrap_or(0);
        // Emit before dropping: dropping the ActiveCall aborts the watch task,
        // which is harmless here but keep the event ordering deterministic.
        self.inner.emit(call_id, state, duration, reason);
        drop(removed);
    }
}

/// Bring a connected call online: wrap the connection in an iroh-roq session,
/// start cpal capture/playback (best-effort — a missing device does NOT fail the
/// call, so this is hermetically testable), spawn the full-duplex opus/RTP loop +
/// a connection-close watcher, store the live resources, and emit `Connected`.
async fn connect_media(inner: Arc<Inner>, call_id: String, conn: Connection) -> Result<()> {
    let local_muted = inner
        .calls
        .lock()
        .unwrap()
        .get(&call_id)
        .map(|slot| slot.local_muted)
        .unwrap_or(false);
    let muted = Arc::new(AtomicBool::new(local_muted));
    let (mic_tx, mic_rx) = mpsc::channel::<Vec<i16>>(4);
    let (spk_tx, spk_rx) = mpsc::channel::<Vec<i16>>(4);

    let capture = match device::start_capture_with_mute(mic_tx.clone(), muted.clone()) {
        Ok(d) => Some(d),
        Err(e) => {
            tracing::warn!("call {call_id}: mic capture unavailable: {e}");
            None
        }
    };
    let playback = match device::start_playback(spk_rx) {
        Ok(d) => Some(d),
        Err(e) => {
            tracing::warn!("call {call_id}: speaker playback unavailable: {e}");
            None
        }
    };

    let session = rtc_session(conn.clone());
    let session_task = tokio::spawn(async move {
        if let Err(e) = run_audio_session(session, CALL_CHANNELS, mic_rx, spk_tx).await {
            tracing::warn!("call audio session ended: {e}");
        }
    });

    // Watch the connection: a remote hangup / network drop closes it → `Ended`.
    let watch_inner = inner.clone();
    let watch_id = call_id.clone();
    let watch_conn = conn.clone();
    let watch = tokio::spawn(async move {
        let _ = watch_conn.closed().await;
        let removed = watch_inner.calls.lock().unwrap().remove(&watch_id);
        if let Some(slot) = removed {
            let duration = slot
                .connected_at
                .map(|t| t.elapsed().as_secs())
                .unwrap_or(0);
            // Emit before dropping the slot (its ActiveCall::drop aborts THIS task).
            watch_inner.emit(&watch_id, CallStateKind::Ended, duration, "remote");
            drop(slot);
        }
    });

    let active = ActiveCall {
        conn,
        _capture: capture,
        _playback: playback,
        _mic_tx: mic_tx,
        muted,
        session: session_task,
        watch,
    };
    {
        let mut calls = inner.calls.lock().unwrap();
        match calls.get_mut(&call_id) {
            Some(slot) => {
                slot.state = CallStateKind::Connected;
                slot.connected_at = Some(Instant::now());
                slot.active = Some(active);
            }
            None => {
                // Torn down mid-connect (e.g. a local hangup raced us): clean up.
                drop(active);
                return Ok(());
            }
        }
    }
    inner.emit(&call_id, CallStateKind::Connected, 0, "");
    Ok(())
}

/// The offerer's inbound-connection handler: for each accepted call connection,
/// admit it ONLY if its QUIC-authenticated id matches a pinned offerer call still
/// waiting to connect (the answerer dialing back after `ANSWER|accept`), then
/// start its media. Unknown ids are dropped — the §3.1 pinning property.
async fn accept_loop(inner: Arc<Inner>) {
    loop {
        let conn = match inner.transport.accept().await {
            Ok(c) => c,
            Err(_) => break, // endpoint closed → session over
        };
        let inner = inner.clone();
        // Handle each inbound connection concurrently so one slow pin-wait does
        // not block another call from connecting.
        tokio::spawn(async move {
            let remote = conn.remote_id();
            let deadline = Instant::now() + PIN_GRACE;
            loop {
                let matched = {
                    let calls = inner.calls.lock().unwrap();
                    calls.iter().find_map(|(id, s)| {
                        let pinned = s.role == Role::Offerer
                            && s.active.is_none()
                            && s.remote_id == Some(remote);
                        pinned.then(|| id.clone())
                    })
                };
                if let Some(call_id) = matched {
                    if let Err(e) = connect_media(inner.clone(), call_id.clone(), conn).await {
                        tracing::warn!("call {call_id}: inbound media setup failed: {e}");
                    }
                    return;
                }
                if Instant::now() >= deadline {
                    tracing::warn!("dropping inbound call from unpinned peer {remote}");
                    conn.close(0u32.into(), b"unknown");
                    return;
                }
                tokio::time::sleep(PIN_POLL).await;
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Poll `engine`'s event stream until it reports `want` (skipping the
    /// intermediate states), or give up after a few timed waits.
    async fn wait_for(engine: &CallEngine, want: CallStateKind) -> bool {
        for _ in 0..40 {
            match engine.next_event(5).await {
                Some(ev) if ev.state == want => return true,
                Some(_) => continue,
                None => return false,
            }
        }
        false
    }

    /// End-to-end engine path, hermetic (relay-less, no audio devices): offerer
    /// `place`s, answerer takes the OFFER and `accept`s (dialing), the offerer's
    /// accept loop admits the pinned dial — BOTH reach `Connected`. Then the
    /// offerer hangs up and BOTH observe `Ended` (the answerer via the
    /// connection-close watcher). Proves transport + pinning + the media-session
    /// lifecycle + event delivery without touching a mic/speaker.
    #[tokio::test]
    async fn two_engines_connect_then_hang_up() -> Result<()> {
        tokio::time::timeout(Duration::from_secs(30), async {
            let offerer = CallEngine::start_relay_less([7u8; 32]).await?;
            let answerer = CallEngine::start_relay_less([8u8; 32]).await?;
            let call_id = "call-1";

            // Offerer places; host would now send OFFER(offerer.local_addr_b64).
            offerer.place(call_id, CallMediaKind::Voice)?;
            let offerer_addr = offerer.local_addr_b64()?;

            // Answerer receives the OFFER; offerer receives the ANSWER|accept.
            answerer.on_incoming_offer(call_id, &offerer_addr, CallMediaKind::Voice)?;
            let answerer_addr = answerer.local_addr_b64()?;
            offerer.on_answer(call_id, AnswerKind::Accept, &answerer_addr)?;

            // Answerer is the dialer.
            answerer.accept(call_id).await?;

            assert!(
                wait_for(&answerer, CallStateKind::Connected).await,
                "answerer connected"
            );
            assert!(
                wait_for(&offerer, CallStateKind::Connected).await,
                "offerer connected"
            );

            // Offerer hangs up; both sides end.
            offerer.hangup(call_id)?;
            assert!(
                wait_for(&offerer, CallStateKind::Ended).await,
                "offerer ended"
            );
            assert!(
                wait_for(&answerer, CallStateKind::Ended).await,
                "answerer ended"
            );

            anyhow::Ok(())
        })
        .await
        .map_err(|_| anyhow!("call engine test timed out"))??;
        Ok(())
    }

    /// A `decline` answer ends the offerer's call as `Declined` (no connection).
    #[tokio::test]
    async fn declined_answer_ends_the_call() -> Result<()> {
        let offerer = CallEngine::start_relay_less([11u8; 32]).await?;
        offerer.place("c", CallMediaKind::Voice)?;
        offerer.on_answer("c", AnswerKind::Decline, "")?;
        assert!(
            wait_for(&offerer, CallStateKind::Declined).await,
            "declined"
        );
        Ok(())
    }
}

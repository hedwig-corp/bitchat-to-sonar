//! Ephemeral typing indicators for Marmot chats.
//!
//! Wire format: Nostr EPHEMERAL event, kind [`TYPING_EVENT_KIND`] (20000-29999
//! range — relays forward to live subscriptions and never store), routed by the
//! group's public `#h` tag (the same tag kind-445 traffic already exposes),
//! content `"1"` = typing started/refresh, `"0"` = stopped.
//!
//! Each event is signed with a FRESH random key (the same anonymity model MDK
//! uses for kind-445): the payload carries no sender identity, so relays learn
//! nothing beyond "someone is composing in a group whose id they already see".
//! In a 2-member (direct) group the receiver names the typist locally — the
//! only other member. Multi-member groups render an anonymous indicator.
//!
//! Timer semantics follow Signal (`TypingStatusSender` / `TypingIndicatorsImpl`):
//! while the user keeps typing a STARTED refresh goes out every
//! [`TypingConfig::refresh`] (10s), a STOPPED after [`TypingConfig::pause`]
//! (3s) idle or on message send, and receivers auto-expire an indicator after
//! [`TypingConfig::expiry`] (15s) without a refresh.
//!
//! Nothing here is persisted: no transcript rows, no conversation index, no
//! sync watermark, no processed-event marks. Because payloads are not yet
//! authenticated to group membership (MDK does not expose the MLS
//! `exporter_secret`), a third party who knows a group's nostr id could spoof
//! the anonymous indicator; see docs/plans/2026-07-05-typing-indicators.md.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};

use nostr::prelude::*;
use tokio::sync::mpsc;
use tokio::time::{Duration, Instant};

/// Ephemeral Nostr kind for Marmot typing indicators.
pub const TYPING_EVENT_KIND: u16 = 20445;

/// Content markers.
const CONTENT_STARTED: &str = "1";
const CONTENT_STOPPED: &str = "0";

/// Remote events whose `created_at` deviates more than this from local time
/// are dropped (stale relay replays or broken clocks).
const STALE_SKEW_SECS: u64 = 120;

/// Cap on the remembered ids of events we published (own-echo suppression).
const PUBLISHED_ID_CAP: usize = 64;

/// Host callback: a group's aggregate remote typing state flipped.
/// `group_id_hex` is the MLS group id hex (the id the apps key chats by).
pub trait TypingListener: Send + Sync {
    fn on_typing_changed(&self, group_id_hex: String, typing: bool);
}

/// Publishes a signed typing event. Production wraps the nostr client;
/// tests record events in memory.
pub trait TypingPublisher: Send + Sync {
    fn publish(&self, event: Event);
}

/// Fire-and-forget relay publisher (same shape as the geohash presence path:
/// never block the caller on relay round-trips).
pub struct NostrTypingPublisher {
    pub nostr: nostr_sdk::Client,
}

impl TypingPublisher for NostrTypingPublisher {
    fn publish(&self, event: Event) {
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            let _ = nostr.send_event(&event).await;
        });
    }
}

/// Signal-equivalent timer constants, injectable for tests.
#[derive(Clone, Copy, Debug)]
pub struct TypingConfig {
    /// Re-send STARTED every this often while the user keeps typing.
    pub refresh: Duration,
    /// Send STOPPED after this long without local input.
    pub pause: Duration,
    /// Receiver forgets a typist after this long without a refresh.
    pub expiry: Duration,
    /// Once an indicator turns on it stays visible at least this long: a
    /// remote STOPPED inside the window is deferred to the window end (and
    /// cancelled by a new STARTED). This caps host-visible transitions at
    /// ~1/min_display no matter how fast forged events arrive — typing events
    /// carry fresh random ids by design, so the live-loop id dedup can never
    /// suppress a flood.
    pub min_display: Duration,
}

impl Default for TypingConfig {
    fn default() -> Self {
        Self {
            refresh: Duration::from_secs(10),
            pause: Duration::from_secs(3),
            expiry: Duration::from_secs(15),
            min_display: Duration::from_secs(1),
        }
    }
}

enum Command {
    LocalTyping { mls_hex: String, nostr_hex: String },
    LocalStopped { mls_hex: String, nostr_hex: String },
    RemoteStarted { mls_hex: String },
    RemoteStopped { mls_hex: String },
}

/// Cheap cloneable handle; the state machine runs on a dedicated tokio task.
#[derive(Clone)]
pub struct TypingManager {
    tx: mpsc::UnboundedSender<Command>,
    /// nostr_group_id hex -> mls_group_id hex (and reverse), refreshed by the
    /// client whenever it enumerates groups.
    nostr_to_mls: Arc<Mutex<HashMap<String, String>>>,
    mls_to_nostr: Arc<Mutex<HashMap<String, String>>>,
    /// Ids of events we published: relays echo subscriptions back to the
    /// sender, and we must not render our own typing.
    published_ids: Arc<Mutex<PublishedIds>>,
    listener: Arc<Mutex<Option<Arc<dyn TypingListener>>>>,
}

struct PublishedIds {
    set: HashSet<EventId>,
    order: VecDeque<EventId>,
}

impl PublishedIds {
    fn new() -> Self {
        Self {
            set: HashSet::new(),
            order: VecDeque::new(),
        }
    }

    fn insert(&mut self, id: EventId) {
        if self.set.insert(id) {
            self.order.push_back(id);
            while self.order.len() > PUBLISHED_ID_CAP {
                if let Some(old) = self.order.pop_front() {
                    self.set.remove(&old);
                }
            }
        }
    }

    fn contains(&self, id: &EventId) -> bool {
        self.set.contains(id)
    }
}

impl TypingManager {
    pub fn spawn(publisher: Arc<dyn TypingPublisher>, config: TypingConfig) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        let manager = Self {
            tx,
            nostr_to_mls: Arc::new(Mutex::new(HashMap::new())),
            mls_to_nostr: Arc::new(Mutex::new(HashMap::new())),
            published_ids: Arc::new(Mutex::new(PublishedIds::new())),
            listener: Arc::new(Mutex::new(None)),
        };
        let task = TypingTask {
            rx,
            publisher,
            config,
            published_ids: manager.published_ids.clone(),
            listener: manager.listener.clone(),
            sending: HashMap::new(),
            receiving: HashMap::new(),
        };
        tokio::spawn(task.run());
        manager
    }

    pub fn set_listener(&self, listener: Option<Arc<dyn TypingListener>>) {
        *self.listener.lock().unwrap() = listener;
    }

    /// Replace the group id mapping with the CURRENT engine group set.
    /// Authoritative (replace, not merge) so deleted/left groups are pruned
    /// instead of accumulating stale pairs for the lifetime of the session.
    /// Called by the client whenever it enumerates groups (subscription
    /// updates, delete/leave, lazy send-side misses).
    pub fn update_groups(&self, pairs: impl IntoIterator<Item = (String, String)>) {
        let mut new_mls_to_nostr = HashMap::new();
        let mut new_nostr_to_mls = HashMap::new();
        for (mls_hex, nostr_hex) in pairs {
            new_nostr_to_mls.insert(nostr_hex.clone(), mls_hex.clone());
            new_mls_to_nostr.insert(mls_hex, nostr_hex);
        }
        *self.mls_to_nostr.lock().unwrap() = new_mls_to_nostr;
        *self.nostr_to_mls.lock().unwrap() = new_nostr_to_mls;
    }

    pub fn nostr_hex_for_mls(&self, mls_hex: &str) -> Option<String> {
        self.mls_to_nostr.lock().unwrap().get(mls_hex).cloned()
    }

    /// Local composer input for a group. Idempotent and cheap: an unbounded
    /// channel send — timer logic runs on the manager task.
    pub fn local_typing(&self, mls_hex: String, nostr_hex: String) {
        let _ = self.tx.send(Command::LocalTyping { mls_hex, nostr_hex });
    }

    /// Local composer went idle/cleared, the chat closed, or a message was
    /// sent — emit STOPPED immediately if we were typing.
    pub fn local_stopped(&self, mls_hex: String, nostr_hex: String) {
        let _ = self.tx.send(Command::LocalStopped { mls_hex, nostr_hex });
    }

    /// Incoming kind-[`TYPING_EVENT_KIND`] relay event. Called from the live
    /// notification loop; must stay cheap and non-blocking.
    pub fn handle_remote_event(&self, event: &Event) {
        if event.kind.as_u16() != TYPING_EVENT_KIND {
            return;
        }
        if self.published_ids.lock().unwrap().contains(&event.id) {
            return; // our own echo
        }
        let now = Timestamp::now().as_secs();
        let created = event.created_at.as_secs();
        // saturating: created_at is attacker-controlled; a value near u64::MAX
        // must not overflow (debug-build panic) before the bound check drops it.
        if created.saturating_add(STALE_SKEW_SECS) < now
            || created > now.saturating_add(STALE_SKEW_SECS)
        {
            return;
        }
        let Some(nostr_hex) = typing_group_tag(event) else {
            return;
        };
        let Some(mls_hex) = self.nostr_to_mls.lock().unwrap().get(&nostr_hex).cloned() else {
            return; // not one of our groups
        };
        let cmd = match event.content.as_str() {
            CONTENT_STARTED => Command::RemoteStarted { mls_hex },
            CONTENT_STOPPED => Command::RemoteStopped { mls_hex },
            _ => return,
        };
        let _ = self.tx.send(cmd);
    }
}

fn typing_group_tag(event: &Event) -> Option<String> {
    event
        .tags
        .iter()
        .find(|t| t.single_letter_tag() == Some(SingleLetterTag::lowercase(Alphabet::H)))
        .and_then(|t| t.content().map(|s| s.to_string()))
}

/// Build a signed typing event: fresh random key, `#h` routing tag only.
fn build_typing_event(
    nostr_hex: &str,
    started: bool,
) -> Result<Event, nostr::event::builder::Error> {
    let keys = Keys::generate();
    let content = if started {
        CONTENT_STARTED
    } else {
        CONTENT_STOPPED
    };
    EventBuilder::new(Kind::Custom(TYPING_EVENT_KIND), content)
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [nostr_hex.to_string()],
        )])
        .sign_with_keys(&keys)
}

struct SendState {
    nostr_hex: String,
    /// STOPPED goes out when this passes without new local input.
    pause_deadline: Instant,
    /// STARTED refresh goes out when this passes while still typing.
    refresh_deadline: Instant,
}

struct RecvState {
    /// The indicator auto-clears when this passes without a refresh.
    expiry: Instant,
    /// When the indicator turned on: the anchor for the min-display window.
    shown_at: Instant,
    /// A STOPPED arrived inside the min-display window; clear at window end
    /// unless a STARTED lands first. This coalescing bounds host-visible
    /// flips at ~1 per min_display even under a forged-event flood.
    pending_stop: bool,
}

struct TypingTask {
    rx: mpsc::UnboundedReceiver<Command>,
    publisher: Arc<dyn TypingPublisher>,
    config: TypingConfig,
    published_ids: Arc<Mutex<PublishedIds>>,
    listener: Arc<Mutex<Option<Arc<dyn TypingListener>>>>,
    /// mls_hex -> local outgoing typing state.
    sending: HashMap<String, SendState>,
    /// mls_hex -> remote indicator state.
    receiving: HashMap<String, RecvState>,
}

impl TypingTask {
    async fn run(mut self) {
        loop {
            let deadline = self.next_deadline();
            tokio::select! {
                cmd = self.rx.recv() => match cmd {
                    Some(cmd) => self.apply(cmd),
                    None => break, // manager dropped; nothing left to do
                },
                _ = sleep_until_or_forever(deadline) => self.tick(),
            }
        }
    }

    fn next_deadline(&self) -> Option<Instant> {
        let min_display = self.config.min_display;
        let send = self
            .sending
            .values()
            .flat_map(|s| [s.pause_deadline, s.refresh_deadline]);
        let recv = self.receiving.values().flat_map(move |r| {
            let stop = r.pending_stop.then(|| r.shown_at + min_display);
            [Some(r.expiry), stop].into_iter().flatten()
        });
        send.chain(recv).min()
    }

    fn apply(&mut self, cmd: Command) {
        let now = Instant::now();
        match cmd {
            Command::LocalTyping { mls_hex, nostr_hex } => match self.sending.get_mut(&mls_hex) {
                Some(state) => {
                    // Keep typing: only the pause deadline moves; the refresh
                    // cadence stays anchored to the first keystroke, exactly
                    // like Signal's TypingStatusSender.
                    state.pause_deadline = now + self.config.pause;
                }
                None => {
                    self.publish(&nostr_hex, true);
                    self.sending.insert(
                        mls_hex,
                        SendState {
                            nostr_hex,
                            pause_deadline: now + self.config.pause,
                            refresh_deadline: now + self.config.refresh,
                        },
                    );
                }
            },
            Command::LocalStopped { mls_hex, nostr_hex } => {
                if self.sending.remove(&mls_hex).is_some() {
                    self.publish(&nostr_hex, false);
                }
            }
            Command::RemoteStarted { mls_hex } => match self.receiving.get_mut(&mls_hex) {
                Some(state) => {
                    // Refresh: extend expiry and cancel any deferred STOPPED.
                    // No re-notify — the indicator is already visible.
                    state.expiry = now + self.config.expiry;
                    state.pending_stop = false;
                }
                None => {
                    self.receiving.insert(
                        mls_hex.clone(),
                        RecvState {
                            expiry: now + self.config.expiry,
                            shown_at: now,
                            pending_stop: false,
                        },
                    );
                    self.notify(mls_hex, true);
                }
            },
            Command::RemoteStopped { mls_hex } => {
                if let Some(state) = self.receiving.get_mut(&mls_hex) {
                    if now >= state.shown_at + self.config.min_display {
                        self.receiving.remove(&mls_hex);
                        self.notify(mls_hex, false);
                    } else {
                        // Inside the min-display window: defer the clear so a
                        // forged 1/0 flood can't flicker the host UI.
                        state.pending_stop = true;
                    }
                }
            }
        }
    }

    fn tick(&mut self) {
        let now = Instant::now();

        // Outgoing: pause timeouts first (a due pause wins over a due refresh).
        let paused: Vec<String> = self
            .sending
            .iter()
            .filter(|(_, s)| s.pause_deadline <= now)
            .map(|(k, _)| k.clone())
            .collect();
        for mls_hex in paused {
            if let Some(state) = self.sending.remove(&mls_hex) {
                self.publish(&state.nostr_hex, false);
            }
        }
        let refresh = self.config.refresh;
        let mut refreshes: Vec<String> = Vec::new();
        for (mls_hex, state) in self.sending.iter_mut() {
            if state.refresh_deadline <= now {
                state.refresh_deadline = now + refresh;
                refreshes.push(mls_hex.clone());
            }
        }
        for mls_hex in refreshes {
            if let Some(nostr_hex) = self.sending.get(&mls_hex).map(|s| s.nostr_hex.clone()) {
                self.publish(&nostr_hex, true);
            }
        }

        // Incoming: expire silent typists and flush deferred STOPPEDs whose
        // min-display window has passed.
        let min_display = self.config.min_display;
        let expired: Vec<String> = self
            .receiving
            .iter()
            .filter(|(_, r)| r.expiry <= now || (r.pending_stop && r.shown_at + min_display <= now))
            .map(|(k, _)| k.clone())
            .collect();
        for mls_hex in expired {
            self.receiving.remove(&mls_hex);
            self.notify(mls_hex, false);
        }
    }

    fn publish(&self, nostr_hex: &str, started: bool) {
        match build_typing_event(nostr_hex, started) {
            Ok(event) => {
                self.published_ids.lock().unwrap().insert(event.id);
                self.publisher.publish(event);
            }
            Err(err) => tracing::debug!(%err, "typing event build failed"),
        }
    }

    fn notify(&self, mls_hex: String, typing: bool) {
        let listener = self.listener.lock().unwrap().clone();
        if let Some(l) = listener {
            l.on_typing_changed(mls_hex, typing);
        }
    }
}

async fn sleep_until_or_forever(deadline: Option<Instant>) {
    match deadline {
        Some(t) => tokio::time::sleep_until(t).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    struct RecordingPublisher {
        events: StdMutex<Vec<Event>>,
    }

    impl RecordingPublisher {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                events: StdMutex::new(Vec::new()),
            })
        }

        fn drain(&self) -> Vec<Event> {
            std::mem::take(&mut *self.events.lock().unwrap())
        }
    }

    impl TypingPublisher for RecordingPublisher {
        fn publish(&self, event: Event) {
            self.events.lock().unwrap().push(event);
        }
    }

    struct RecordingListener {
        changes: StdMutex<Vec<(String, bool)>>,
    }

    impl RecordingListener {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                changes: StdMutex::new(Vec::new()),
            })
        }

        fn drain(&self) -> Vec<(String, bool)> {
            std::mem::take(&mut *self.changes.lock().unwrap())
        }
    }

    impl TypingListener for RecordingListener {
        fn on_typing_changed(&self, group_id_hex: String, typing: bool) {
            self.changes.lock().unwrap().push((group_id_hex, typing));
        }
    }

    fn test_config() -> TypingConfig {
        TypingConfig::default()
    }

    fn contents(events: &[Event]) -> Vec<&str> {
        events.iter().map(|e| e.content.as_str()).collect()
    }

    /// Let the manager task absorb pending commands / due timers under a
    /// paused clock: yield a few times so the task's select loop runs.
    async fn settle() {
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
    }

    async fn advance(d: Duration) {
        tokio::time::advance(d).await;
        settle().await;
    }

    #[tokio::test(start_paused = true)]
    async fn started_once_then_refresh_every_10s() {
        let publisher = RecordingPublisher::new();
        let manager = TypingManager::spawn(publisher.clone(), test_config());
        manager.local_typing("mls1".into(), "nostr1".into());
        settle().await;
        assert_eq!(contents(&publisher.drain()), vec!["1"]);

        // Keep typing: repeated input inside the window publishes nothing new.
        for _ in 0..4 {
            advance(Duration::from_secs(2)).await;
            manager.local_typing("mls1".into(), "nostr1".into());
        }
        settle().await;
        let refreshed = publisher.drain();
        // 8s elapsed: still before the 10s refresh.
        assert!(refreshed.is_empty(), "unexpected events: {refreshed:?}");

        // Cross the 10s refresh boundary while still typing.
        advance(Duration::from_secs(2)).await;
        manager.local_typing("mls1".into(), "nostr1".into());
        settle().await;
        assert_eq!(contents(&publisher.drain()), vec!["1"]);
    }

    #[tokio::test(start_paused = true)]
    async fn stopped_after_3s_idle() {
        let publisher = RecordingPublisher::new();
        let manager = TypingManager::spawn(publisher.clone(), test_config());
        manager.local_typing("mls1".into(), "nostr1".into());
        settle().await;
        assert_eq!(contents(&publisher.drain()), vec!["1"]);

        advance(Duration::from_secs(3)).await;
        assert_eq!(contents(&publisher.drain()), vec!["0"]);

        // Idle: nothing further.
        advance(Duration::from_secs(30)).await;
        assert!(publisher.drain().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn stopped_on_send() {
        let publisher = RecordingPublisher::new();
        let manager = TypingManager::spawn(publisher.clone(), test_config());
        manager.local_typing("mls1".into(), "nostr1".into());
        settle().await;
        manager.local_stopped("mls1".into(), "nostr1".into());
        settle().await;
        assert_eq!(contents(&publisher.drain()), vec!["1", "0"]);

        // Stop again without typing: no duplicate STOPPED.
        manager.local_stopped("mls1".into(), "nostr1".into());
        settle().await;
        assert!(publisher.drain().is_empty());
    }

    fn remote_event(nostr_hex: &str, content: &str) -> Event {
        EventBuilder::new(Kind::Custom(TYPING_EVENT_KIND), content)
            .tags([Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                [nostr_hex.to_string()],
            )])
            .sign_with_keys(&Keys::generate())
            .expect("sign")
    }

    #[tokio::test(start_paused = true)]
    async fn remote_typing_emits_and_expires_after_15s() {
        let publisher = RecordingPublisher::new();
        let listener = RecordingListener::new();
        let manager = TypingManager::spawn(publisher, test_config());
        manager.set_listener(Some(listener.clone()));
        manager.update_groups([("mls1".to_string(), "nostr1".to_string())]);

        manager.handle_remote_event(&remote_event("nostr1", "1"));
        settle().await;
        assert_eq!(listener.drain(), vec![("mls1".to_string(), true)]);

        // A refresh inside the window extends, no re-notify.
        advance(Duration::from_secs(10)).await;
        manager.handle_remote_event(&remote_event("nostr1", "1"));
        settle().await;
        assert!(listener.drain().is_empty());

        // 15s after the refresh: expires.
        advance(Duration::from_secs(15)).await;
        assert_eq!(listener.drain(), vec![("mls1".to_string(), false)]);
    }

    #[tokio::test(start_paused = true)]
    async fn remote_stopped_clears_after_min_display() {
        let publisher = RecordingPublisher::new();
        let listener = RecordingListener::new();
        let manager = TypingManager::spawn(publisher, test_config());
        manager.set_listener(Some(listener.clone()));
        manager.update_groups([("mls1".to_string(), "nostr1".to_string())]);

        manager.handle_remote_event(&remote_event("nostr1", "1"));
        settle().await;
        assert_eq!(listener.drain(), vec![("mls1".to_string(), true)]);

        // A STOPPED inside the 1s min-display window is deferred, not
        // immediate (anti-flicker coalescing)...
        manager.handle_remote_event(&remote_event("nostr1", "0"));
        settle().await;
        assert!(listener.drain().is_empty(), "stop deferred inside window");

        // ...and fires at the window end.
        advance(Duration::from_secs(1)).await;
        assert_eq!(listener.drain(), vec![("mls1".to_string(), false)]);

        // Past the window, a STOPPED clears immediately.
        manager.handle_remote_event(&remote_event("nostr1", "1"));
        settle().await;
        advance(Duration::from_secs(2)).await;
        manager.handle_remote_event(&remote_event("nostr1", "0"));
        settle().await;
        assert_eq!(
            listener.drain(),
            vec![("mls1".to_string(), true), ("mls1".to_string(), false)]
        );
    }

    #[tokio::test(start_paused = true)]
    async fn forged_flood_cannot_flicker_faster_than_min_display() {
        let publisher = RecordingPublisher::new();
        let listener = RecordingListener::new();
        let manager = TypingManager::spawn(publisher, test_config());
        manager.set_listener(Some(listener.clone()));
        manager.update_groups([("mls1".to_string(), "nostr1".to_string())]);

        // Attacker alternates 1/0 with fresh keys (unique event ids) far
        // faster than the legitimate cadence.
        for _ in 0..50 {
            manager.handle_remote_event(&remote_event("nostr1", "1"));
            manager.handle_remote_event(&remote_event("nostr1", "0"));
        }
        settle().await;
        // Exactly one visible transition so far: ON. The stop is deferred.
        assert_eq!(listener.drain(), vec![("mls1".to_string(), true)]);

        // The trailing STARTEDs cancelled... last command was "0", so the
        // deferred stop is armed; it fires once at the window end.
        advance(Duration::from_secs(1)).await;
        assert_eq!(listener.drain(), vec![("mls1".to_string(), false)]);
    }

    #[tokio::test(start_paused = true)]
    async fn update_groups_replaces_and_prunes_stale_mappings() {
        let publisher = RecordingPublisher::new();
        let listener = RecordingListener::new();
        let manager = TypingManager::spawn(publisher, test_config());
        manager.set_listener(Some(listener.clone()));
        manager.update_groups([("mls1".to_string(), "nostr1".to_string())]);
        assert_eq!(manager.nostr_hex_for_mls("mls1").as_deref(), Some("nostr1"));

        // Authoritative replace: the deleted group's mapping is pruned...
        manager.update_groups([("mls2".to_string(), "nostr2".to_string())]);
        assert_eq!(manager.nostr_hex_for_mls("mls1"), None);
        assert_eq!(manager.nostr_hex_for_mls("mls2").as_deref(), Some("nostr2"));

        // ...and events for the pruned group are dropped.
        manager.handle_remote_event(&remote_event("nostr1", "1"));
        settle().await;
        assert!(listener.drain().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn own_echo_and_unknown_groups_ignored() {
        let publisher = RecordingPublisher::new();
        let listener = RecordingListener::new();
        let manager = TypingManager::spawn(publisher.clone(), test_config());
        manager.set_listener(Some(listener.clone()));
        manager.update_groups([("mls1".to_string(), "nostr1".to_string())]);

        // Publish locally, then feed the published event back (relay echo).
        manager.local_typing("mls1".into(), "nostr1".into());
        settle().await;
        let published = publisher.drain();
        assert_eq!(published.len(), 1);
        manager.handle_remote_event(&published[0]);
        settle().await;
        assert!(listener.drain().is_empty(), "own echo must not notify");

        // Unknown group tag: dropped.
        manager.handle_remote_event(&remote_event("not-our-group", "1"));
        settle().await;
        assert!(listener.drain().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn stale_events_dropped() {
        let publisher = RecordingPublisher::new();
        let listener = RecordingListener::new();
        let manager = TypingManager::spawn(publisher, test_config());
        manager.set_listener(Some(listener.clone()));
        manager.update_groups([("mls1".to_string(), "nostr1".to_string())]);

        let old = EventBuilder::new(Kind::Custom(TYPING_EVENT_KIND), CONTENT_STARTED)
            .tags([Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                ["nostr1".to_string()],
            )])
            .custom_created_at(Timestamp::from_secs(
                Timestamp::now().as_secs().saturating_sub(600),
            ))
            .sign_with_keys(&Keys::generate())
            .expect("sign");
        manager.handle_remote_event(&old);
        settle().await;
        assert!(listener.drain().is_empty());
    }
}

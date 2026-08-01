//! Abstract Sonar backend. The IRC bridge talks to this trait; the concrete
//! implementations are mock (simulated) and sonar (real sonar-core), selected by
//! cargo feature.

use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::mpsc;

/// Opaque group identifier (sonar MLS group id).
pub type GroupId = String;

#[derive(Debug, Clone)]
pub struct Member {
    pub npub: String,
    pub nick: String,
}

#[derive(Debug, Clone)]
pub struct Group {
    pub id: GroupId,
    pub name: String,
    pub members: Vec<Member>,
}

#[derive(Debug, Clone)]
pub struct InboundMessage {
    pub group: GroupId,
    pub sender_nick: String,
    pub sender_npub: String,
    pub text: String,
}

#[async_trait]
pub trait SonarBackend: Send + Sync {
    /// All conversations, exposed to IRC as channels (auto-joined on connect).
    async fn groups(&self) -> anyhow::Result<Vec<Group>>;
    /// Send a text message to a group.
    async fn send_text(&self, group: &GroupId, text: &str) -> anyhow::Result<()>;
    /// Resolve an IRC query target (nick or npub) to a 1:1 group, creating it if needed.
    async fn resolve_dm(&self, peer: &str) -> anyhow::Result<Group>;
}

/// What every backend build() returns: the shared backend plus the channel it
/// pushes inbound InboundMessages onto.
pub struct BuiltBackend {
    pub backend: Arc<dyn SonarBackend>,
    pub events: mpsc::UnboundedReceiver<InboundMessage>,
}

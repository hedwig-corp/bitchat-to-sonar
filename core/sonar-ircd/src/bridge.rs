//! Shared routing state across IRC connections: channel <-> group mapping, the
//! broadcast fan-out of inbound sonar events to clients, and the optional
//! outbound IRC bridge link.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use anyhow::Result;
use tokio::sync::{broadcast, mpsc};

use crate::backend::{Group, GroupId, SonarBackend};
use crate::irc::server::ClientEvent;

struct BridgeLink {
    local_chan: String,
    out: mpsc::UnboundedSender<String>,
}

pub struct Bridge {
    pub backend: Arc<dyn SonarBackend>,
    pub server_name: String,
    chan_to_group: Arc<RwLock<HashMap<String, Group>>>,
    group_to_chan: Arc<RwLock<HashMap<GroupId, String>>>,
    bridge_link: Arc<RwLock<Option<BridgeLink>>>,
    fanout_tx: broadcast::Sender<ClientEvent>,
}

impl Bridge {
    pub async fn build(backend: Arc<dyn SonarBackend>, server_name: String) -> Result<Arc<Self>> {
        let (fanout_tx, _) = broadcast::channel(256);
        let groups = backend.groups().await?;
        let mut chan_to_group = HashMap::new();
        let mut group_to_chan = HashMap::new();
        for g in groups {
            let chan = channel_name_for(&g.name);
            group_to_chan.insert(g.id.clone(), chan.clone());
            chan_to_group.insert(chan, g);
        }
        Ok(Arc::new(Self {
            backend,
            server_name,
            chan_to_group: Arc::new(RwLock::new(chan_to_group)),
            group_to_chan: Arc::new(RwLock::new(group_to_chan)),
            bridge_link: Arc::new(RwLock::new(None)),
            fanout_tx,
        }))
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ClientEvent> {
        self.fanout_tx.subscribe()
    }

    pub fn emit(&self, e: ClientEvent) {
        let _ = self.fanout_tx.send(e);
    }

    pub fn all_channels(&self) -> Vec<(String, Group)> {
        self.chan_to_group
            .read()
            .unwrap()
            .iter()
            .map(|(c, g)| (c.clone(), g.clone()))
            .collect()
    }

    pub fn group_for_channel(&self, chan: &str) -> Option<Group> {
        self.chan_to_group.read().unwrap().get(chan).cloned()
    }

    pub fn ensure_channel(&self, group: &GroupId, fallback_name: &str) -> String {
        if let Some(c) = self.group_to_chan.read().unwrap().get(group).cloned() {
            return c;
        }
        let chan = channel_name_for(&format!("dm-{fallback_name}"));
        self.group_to_chan
            .write()
            .unwrap()
            .entry(group.clone())
            .or_insert(chan.clone())
            .clone()
    }

    /// Register a bridged (external IRC) channel: outbound messages go to `out`,
    /// and it appears as a synthetic channel IRC clients can JOIN.
    pub fn register_bridge(&self, local_chan: String, out: mpsc::UnboundedSender<String>) {
        let name = local_chan.trim_start_matches('#').to_string();
        let group = Group {
            id: format!("bridge:{name}"),
            name,
            members: Vec::new(),
        };
        self.chan_to_group.write().unwrap().insert(local_chan.clone(), group);
        *self.bridge_link.write().unwrap() = Some(BridgeLink { local_chan, out });
    }

    pub fn is_bridged(&self, chan: &str) -> bool {
        self.bridge_link
            .read()
            .unwrap()
            .as_ref()
            .map(|l| l.local_chan == chan)
            .unwrap_or(false)
    }

    pub fn forward_to_bridge(&self, text: &str) {
        if let Some(link) = self.bridge_link.read().unwrap().as_ref() {
            let _ = link.out.send(text.to_string());
        }
    }
}

/// Map a sonar group name to a valid IRC channel name (lowercased, # prefix).
pub fn channel_name_for(name: &str) -> String {
    let clean: String = name
        .trim()
        .to_lowercase()
        .chars()
        .filter_map(|c| {
            if c.is_control() || c == ' ' || c == ',' || c == ':' {
                Some('-')
            } else {
                Some(c)
            }
        })
        .collect();
    let clean: String = clean.chars().take(50).collect();
    let clean = if clean.is_empty() { "talk".to_string() } else { clean };
    format!("#{clean}")
}

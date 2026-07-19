//! Durable local state for the Marmot recovery beacon auto-rejoin flow.
//!
//! When a party loses local MLS state but restores from `nsec`, MDK cannot
//! rejoin the old group (no external-commit / ReInit support), so recovery is
//! *new group + welcome via a fresh KeyPackage*. The restored client publishes
//! a signed [recovery beacon](crate::marmot::RECOVERY_BEACON_KIND); surviving
//! peers detect it and re-invite the restored member into a fresh MLS group.
//!
//! This sidecar — modelled on [`crate::outbox`] — stores only the small amount
//! of app-layer bookkeeping that must survive restart: which beacons we already
//! acted on (replay guard), which local DM groups we retired in favour of a
//! healed one, the newest inbound timestamp per peer (staleness guard), any
//! outstanding beacon we published (so group welcomes auto-accept), and the
//! `ConversationReset` notices the UI has not drained yet. The MLS state itself
//! stays in MDK's encrypted store; nothing secret is written here.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use nostr::prelude::*;
use serde::{Deserialize, Serialize};

use crate::marmot::RECOVERY_BEACON_KIND;
use crate::{Error, Result};

/// Sidecar file suffix for the recovery state beside the MDK database.
pub(crate) const RECOVERY_STATE_FILE_SUFFIX: &str = ".sonar-recovery.json";
const RECOVERY_STATE_VERSION: u32 = 1;

/// `d` tag value that identifies the addressable recovery beacon.
pub const RECOVERY_BEACON_D_TAG: &str = "recovery";
/// `t` tag value marking the beacon as a state-loss recovery announcement.
pub const RECOVERY_BEACON_T_TAG: &str = "state-loss";

/// A healed 1:1 conversation: the survivor retired `old_group_id_hex` and
/// created `new_group_id_hex` with the restored peer. Hosts drain these to
/// render a Signal-style "chat was reset" system notice and fold the new leg
/// into the same conversation row.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct ConversationReset {
    pub peer_pubkey_hex: String,
    pub old_group_id_hex: String,
    pub new_group_id_hex: String,
    pub at_secs: u64,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct RecoveryStateDisk {
    version: u32,
    #[serde(default)]
    outstanding_beacon_created_at: Option<u64>,
    #[serde(default)]
    processed_beacons: HashMap<String, u64>,
    #[serde(default)]
    retired_dm_group_ids: HashSet<String>,
    #[serde(default)]
    pending_resets: Vec<ConversationReset>,
    #[serde(default)]
    last_inbound_from: HashMap<String, u64>,
}

/// In-memory recovery bookkeeping, persisted to a JSON sidecar.
#[derive(Debug)]
pub(crate) struct RecoveryState {
    path: Option<PathBuf>,
    outstanding_beacon_created_at: Option<u64>,
    /// peer pubkey hex → newest beacon `created_at` we have already acted on.
    processed_beacons: HashMap<String, u64>,
    /// MLS group id hex of DM groups retired in favour of a healed group.
    retired_dm_group_ids: HashSet<String>,
    /// Conversation resets the host has not drained yet.
    pending_resets: Vec<ConversationReset>,
    /// peer pubkey hex → newest inbound (peer-authored) message `created_at`.
    last_inbound_from: HashMap<String, u64>,
    dirty: bool,
}

impl RecoveryState {
    pub fn load(path: Option<PathBuf>) -> Self {
        let disk = path
            .as_ref()
            .and_then(|path| fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<RecoveryStateDisk>(&bytes).ok())
            .filter(|state| state.version == RECOVERY_STATE_VERSION)
            .unwrap_or_default();

        Self {
            path,
            outstanding_beacon_created_at: disk.outstanding_beacon_created_at,
            processed_beacons: disk.processed_beacons,
            retired_dm_group_ids: disk.retired_dm_group_ids,
            pending_resets: disk.pending_resets,
            last_inbound_from: disk.last_inbound_from,
            dirty: false,
        }
    }

    /// Record that we published a beacon at `created_at`, so newly arriving
    /// group welcomes auto-accept while it is outstanding.
    pub fn set_outstanding_beacon(&mut self, created_at: u64) -> Result<()> {
        if self.outstanding_beacon_created_at != Some(created_at) {
            self.outstanding_beacon_created_at = Some(created_at);
            self.dirty = true;
        }
        self.save_if_dirty()
    }

    /// Clear the outstanding-beacon flag once at least one conversation healed.
    pub fn clear_outstanding_beacon(&mut self) -> Result<()> {
        if self.outstanding_beacon_created_at.take().is_some() {
            self.dirty = true;
        }
        self.save_if_dirty()
    }

    pub fn has_outstanding_beacon(&self) -> bool {
        self.outstanding_beacon_created_at.is_some()
    }

    /// True when a beacon from `peer_hex` at `created_at` must be ignored:
    /// either we already processed a beacon at that time or newer (replay), or
    /// the beacon is strictly older than the newest decrypted inbound message
    /// from that peer (stale — the peer is clearly still live on the old group).
    pub fn is_beacon_replayed_or_stale(&self, peer_hex: &str, created_at: u64) -> bool {
        if let Some(&processed) = self.processed_beacons.get(peer_hex) {
            if created_at <= processed {
                return true;
            }
        }
        if let Some(&last_inbound) = self.last_inbound_from.get(peer_hex) {
            if created_at < last_inbound {
                return true;
            }
        }
        false
    }

    /// Mark a beacon from `peer_hex` at `created_at` as processed (idempotency).
    pub fn mark_beacon_processed(&mut self, peer_hex: &str, created_at: u64) -> Result<()> {
        let slot = self
            .processed_beacons
            .entry(peer_hex.to_string())
            .or_insert(0);
        if created_at > *slot {
            *slot = created_at;
            self.dirty = true;
        }
        self.save_if_dirty()
    }

    /// Retire a DM group so it is skipped by DM reuse and (on the survivor) kept
    /// only as an archived transcript.
    pub fn retire_dm_group(&mut self, group_id_hex: &str) -> Result<()> {
        if self.retired_dm_group_ids.insert(group_id_hex.to_string()) {
            self.dirty = true;
        }
        self.save_if_dirty()
    }

    pub fn is_dm_group_retired(&self, group_id_hex: &str) -> bool {
        self.retired_dm_group_ids.contains(group_id_hex)
    }

    /// Record the newest inbound (peer-authored) message timestamp for a peer.
    pub fn record_inbound_from(&mut self, peer_hex: &str, created_at: u64) -> Result<()> {
        let slot = self
            .last_inbound_from
            .entry(peer_hex.to_string())
            .or_insert(0);
        if created_at > *slot {
            *slot = created_at;
            self.dirty = true;
        }
        self.save_if_dirty()
    }

    /// Queue a conversation-reset notice for the host to render.
    pub fn push_reset(&mut self, reset: ConversationReset) -> Result<()> {
        self.pending_resets.push(reset);
        self.dirty = true;
        self.save_if_dirty()
    }

    /// Take all queued conversation resets (host drain).
    pub fn drain_resets(&mut self) -> Vec<ConversationReset> {
        if self.pending_resets.is_empty() {
            return Vec::new();
        }
        self.dirty = true;
        let drained = std::mem::take(&mut self.pending_resets);
        let _ = self.save_if_dirty();
        drained
    }

    fn save_if_dirty(&mut self) -> Result<()> {
        if !self.dirty {
            return Ok(());
        }
        let Some(path) = self.path.as_ref() else {
            self.dirty = false;
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| {
                Error::Storage(format!("create recovery-state dir {}: {e}", parent.display()))
            })?;
        }
        let disk = RecoveryStateDisk {
            version: RECOVERY_STATE_VERSION,
            outstanding_beacon_created_at: self.outstanding_beacon_created_at,
            processed_beacons: self.processed_beacons.clone(),
            retired_dm_group_ids: self.retired_dm_group_ids.clone(),
            pending_resets: self.pending_resets.clone(),
            last_inbound_from: self.last_inbound_from.clone(),
        };
        let bytes = serde_json::to_vec(&disk)?;
        let tmp = recovery_state_tmp_path(path);
        fs::write(&tmp, bytes)
            .map_err(|e| Error::Storage(format!("write recovery state {}: {e}", tmp.display())))?;
        fs::rename(&tmp, path)
            .map_err(|e| Error::Storage(format!("replace recovery state {}: {e}", path.display())))?;
        self.dirty = false;
        Ok(())
    }
}

/// Build a signed kind-30447 recovery beacon addressable event.
///
/// Tags: `d`=`recovery` (addressable slot; republish replaces), `t`=`state-loss`
/// (marker for peers), and optionally `k`=`<fresh KeyPackage event id>` so a
/// survivor can prefer that KeyPackage when re-inviting. Experimental draft MIP
/// kind — non-Sonar clients ignore it.
pub fn build_recovery_beacon_event(
    keys: &Keys,
    key_package_event_id: Option<EventId>,
) -> Result<Event> {
    let mut tags = vec![
        Tag::identifier(RECOVERY_BEACON_D_TAG),
        Tag::hashtag(RECOVERY_BEACON_T_TAG),
    ];
    if let Some(id) = key_package_event_id {
        let tag = Tag::parse(["k".to_string(), id.to_hex()])
            .map_err(|e| Error::InvalidInput(format!("recovery beacon k tag: {e}")))?;
        tags.push(tag);
    }
    let event = EventBuilder::new(Kind::Custom(RECOVERY_BEACON_KIND), "")
        .tags(tags)
        .sign_with_keys(keys)?;
    Ok(event)
}

pub(crate) fn recovery_state_path_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-recovery.json");
    db_path.with_file_name(format!("{file_name}{RECOVERY_STATE_FILE_SUFFIX}"))
}

fn recovery_state_tmp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-recovery.json");
    path.with_file_name(format!("{file_name}.tmp"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::Keys;

    #[test]
    fn beacon_event_carries_recovery_tags() {
        let keys = Keys::generate();
        let event = build_recovery_beacon_event(&keys, None).expect("beacon builds");
        assert_eq!(event.kind, Kind::Custom(RECOVERY_BEACON_KIND));
        assert_eq!(event.pubkey, keys.public_key());
        let d = event
            .tags
            .iter()
            .find(|t| t.as_slice().first().map(|s| s.as_str()) == Some("d"))
            .and_then(|t| t.as_slice().get(1).cloned());
        assert_eq!(d.as_deref(), Some(RECOVERY_BEACON_D_TAG));
        let t = event
            .tags
            .iter()
            .find(|t| t.as_slice().first().map(|s| s.as_str()) == Some("t"))
            .and_then(|t| t.as_slice().get(1).cloned());
        assert_eq!(t.as_deref(), Some(RECOVERY_BEACON_T_TAG));
        event.verify().expect("beacon is a valid signed event");
    }

    #[test]
    fn beacon_event_includes_key_package_pointer() {
        let keys = Keys::generate();
        let kp_id = EventId::all_zeros();
        let event = build_recovery_beacon_event(&keys, Some(kp_id)).expect("beacon builds");
        let k = event
            .tags
            .iter()
            .find(|t| t.as_slice().first().map(|s| s.as_str()) == Some("k"))
            .and_then(|t| t.as_slice().get(1).cloned());
        assert_eq!(k.as_deref(), Some(kp_id.to_hex().as_str()));
    }

    #[test]
    fn replay_guard_ignores_processed_and_stale_beacons() {
        let mut state = RecoveryState::load(None);
        let peer = "aa".repeat(32);

        assert!(!state.is_beacon_replayed_or_stale(&peer, 100));
        state.mark_beacon_processed(&peer, 100).unwrap();
        // Same or older beacon is a replay.
        assert!(state.is_beacon_replayed_or_stale(&peer, 100));
        assert!(state.is_beacon_replayed_or_stale(&peer, 99));
        // A strictly newer beacon is still actionable.
        assert!(!state.is_beacon_replayed_or_stale(&peer, 101));

        // A beacon strictly older than the newest inbound is stale.
        state.record_inbound_from(&peer, 200).unwrap();
        assert!(state.is_beacon_replayed_or_stale(&peer, 150));
        // Same-second-as-inbound beacon is NOT stale (heals immediately).
        assert!(!state.is_beacon_replayed_or_stale(&peer, 200));
    }

    #[test]
    fn resets_and_retirement_round_trip_on_disk() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("db.sqlite.sonar-recovery.json");
        let mut state = RecoveryState::load(Some(path.clone()));
        state.retire_dm_group("dead").unwrap();
        state
            .push_reset(ConversationReset {
                peer_pubkey_hex: "peer".into(),
                old_group_id_hex: "dead".into(),
                new_group_id_hex: "alive".into(),
                at_secs: 7,
            })
            .unwrap();

        let reloaded = RecoveryState::load(Some(path));
        assert!(reloaded.is_dm_group_retired("dead"));
        assert_eq!(reloaded.pending_resets.len(), 1);
    }
}

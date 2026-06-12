//! Relay-connected Sonar client: ties an [`Identity`] + [`MarmotEngine`] to
//! nostr relays. This is the async I/O layer; all protocol logic lives in
//! [`crate::marmot`].
//!
//! M1 scope: explicit polling via [`SonarClient::sync`] (deterministic for
//! e2e tests). Live subscriptions land with the native shells.

use std::path::Path;
use std::time::Duration;

use mdk_core::prelude::*;
use nostr::prelude::*;
use nostr_sdk::Client;

use crate::identity::Identity;
use crate::marmot::{ChatMessage, MarmotEngine, KEY_PACKAGE_KIND};
use crate::{Error, Result};

const FETCH_TIMEOUT: Duration = Duration::from_secs(10);

pub struct SonarClient {
    engine: MarmotEngine,
    nostr: Client,
    relays: Vec<RelayUrl>,
}

impl SonarClient {
    /// Connect an identity to the given relays with a persistent, encrypted
    /// SQLCipher store at `db_path`.
    ///
    /// `db_key` is the 32-byte SQLCipher key, owned by the host (Keychain on
    /// iOS). The parent directory of `db_path` must already exist. Marmot state
    /// (groups, messages, MLS secrets) survives process restarts: reconnecting
    /// at the same path with the same key reopens the same database.
    pub async fn connect(
        identity: Identity,
        relays: Vec<RelayUrl>,
        db_path: impl AsRef<Path>,
        db_key: [u8; 32],
    ) -> Result<Self> {
        let engine = MarmotEngine::persistent(identity.clone(), db_path, db_key)?;
        Self::with_engine(identity, relays, engine).await
    }

    /// Connect with a volatile in-memory store. State is lost when the client is
    /// dropped. Intended for tests and ephemeral/anonymous sessions.
    pub async fn connect_in_memory(identity: Identity, relays: Vec<RelayUrl>) -> Result<Self> {
        let engine = MarmotEngine::in_memory(identity.clone());
        Self::with_engine(identity, relays, engine).await
    }

    async fn with_engine(
        identity: Identity,
        relays: Vec<RelayUrl>,
        engine: MarmotEngine,
    ) -> Result<Self> {
        let nostr = Client::new(identity.keys().clone());
        for relay in &relays {
            nostr.add_relay(relay.clone()).await?;
        }
        nostr.connect().await;
        Ok(Self {
            engine,
            nostr,
            relays,
        })
    }

    pub fn identity(&self) -> &Identity {
        self.engine.identity()
    }

    /// Publish our kind-30443 KeyPackage so others can start groups with us.
    pub async fn publish_key_package(&self) -> Result<()> {
        let event = self.engine.key_package_event(self.relays.clone())?;
        self.nostr.send_event(&event).await?;
        Ok(())
    }

    /// Fetch the freshest KeyPackage event for `author` from the relays.
    pub async fn fetch_key_package(&self, author: PublicKey) -> Result<Event> {
        let filter = Filter::new()
            .kind(Kind::Custom(KEY_PACKAGE_KIND))
            .author(author)
            .limit(1);
        let events = self.nostr.fetch_events(filter, FETCH_TIMEOUT).await?;
        events
            .into_iter()
            .next()
            .ok_or(Error::KeyPackageNotFound(author))
    }

    /// Start a DM/group with `peer`: fetch their KeyPackage, create the MLS
    /// group, and deliver the gift-wrapped welcome.
    pub async fn start_dm(&self, peer: PublicKey, name: &str) -> Result<GroupId> {
        let key_package = self.fetch_key_package(peer).await?;
        let creation = self
            .engine
            .create_group(name, vec![key_package], self.relays.clone())?;
        for (member, rumor) in creation.welcomes {
            let wrapped = self.engine.gift_wrap_welcome(&member, rumor).await?;
            self.nostr.send_event(&wrapped).await?;
        }
        Ok(creation.group.mls_group_id)
    }

    /// Encrypt, publish, and locally record a text message.
    pub async fn send_text(&self, group_id: &GroupId, text: &str) -> Result<()> {
        let event = self.engine.create_text_message(group_id, text)?;
        self.nostr.send_event(&event).await?;
        self.engine.process_incoming(&event).await?;
        Ok(())
    }

    /// Poll the relays once: first gift-wrapped welcomes addressed to us
    /// (which may add groups), then kind-445 messages for every known group.
    /// Duplicate/already-processed events are tolerated by design.
    pub async fn sync(&self) -> Result<()> {
        let wraps = Filter::new()
            .kind(Kind::GiftWrap)
            .pubkey(self.identity().public_key());
        for event in self.nostr.fetch_events(wraps, FETCH_TIMEOUT).await? {
            if let Err(err) = self.engine.process_incoming(&event).await {
                tracing::debug!(%err, "skipping gift wrap (likely duplicate)");
            }
        }

        for group in self.engine.groups()? {
            let filter = Filter::new()
                .kind(Kind::MlsGroupMessage)
                .custom_tag(
                    SingleLetterTag::lowercase(Alphabet::H),
                    hex::encode(group.nostr_group_id),
                );
            for event in self.nostr.fetch_events(filter, FETCH_TIMEOUT).await? {
                if let Err(err) = self.engine.process_incoming(&event).await {
                    tracing::debug!(%err, "skipping group message (likely duplicate)");
                }
            }
        }
        Ok(())
    }

    pub fn groups(&self) -> Result<Vec<group_types::Group>> {
        self.engine.groups()
    }

    pub fn messages(&self, group_id: &GroupId) -> Result<Vec<ChatMessage>> {
        self.engine.messages(group_id)
    }

    pub fn members(&self, group_id: &GroupId) -> Result<Vec<PublicKey>> {
        self.engine.members(group_id)
    }

    /// Erase a persistent database at `db_path` (and its SQLite sidecars).
    ///
    /// Free function — no live client may hold the DB open. Used by panic-wipe
    /// before the Swift host also clears the Keychain key.
    pub fn wipe_database(db_path: impl AsRef<Path>) -> Result<()> {
        MarmotEngine::wipe(db_path)
    }
}

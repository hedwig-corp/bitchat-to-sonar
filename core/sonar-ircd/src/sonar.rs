//! Sonar backend over the in-tree sonar-core (Nostr identity + Marmot/MLS).

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use nostr::ToBech32;
use tokio::time::{interval, Duration};

use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

use crate::backend::{BuiltBackend, Group, GroupId, InboundMessage, Member, SonarBackend};
use crate::config::Config;

const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.nostr.band",
];

pub struct SonarCoreBackend {
    client: Arc<SonarClient>,
    local: Member,
}

fn gid_hex(gid: &sonar_core::GroupId) -> String {
    hex::encode(gid.as_slice())
}

impl SonarCoreBackend {
    pub async fn build(cfg: &Config) -> Result<BuiltBackend> {
        let home = match cfg.backend.home.clone() {
            Some(h) => h,
            None => match std::env::var_os("HOME") {
                Some(h) => PathBuf::from(h).join(".sonar-ircd"),
                None => return Err(anyhow!("no HOME; set backend.home in config")),
            },
        };
        std::fs::create_dir_all(&home).with_context(|| format!("creating {}", home.display()))?;

        let identity = load_or_create_identity(&home, cfg)?;
        let npub = identity.npub();

        let relays: Vec<_> = resolve_relays(cfg)
            .iter()
            .map(|r| nostr_sdk::RelayUrl::parse(r))
            .collect::<Result<_, _>>()?;

        let db_path = home.join("sonar.db");
        let db_key = load_or_create_db_key(&home)?;

        let client = SonarClient::connect(identity, relays, db_path, db_key)
            .await
            .context("SonarClient::connect")?;
        let client = Arc::new(client);

        if let Err(e) = client.publish_key_package().await {
            tracing::warn!(error = %e, "publish_key_package failed (peers may not be able to DM yet)");
        }

        let local = Member {
            npub: npub.clone(),
            nick: cfg.backend.nick.clone().unwrap_or_else(|| {
                let tail = &npub[npub.len().saturating_sub(6)..];
                format!("sonar-{tail}")
            }),
        };

        let backend = Arc::new(Self { client: Arc::clone(&client), local: local.clone() }) as Arc<dyn SonarBackend>;
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        tokio::spawn(poll_loop(client, tx, Duration::from_secs(5)));
        Ok(BuiltBackend { backend, events: rx })
    }

    fn find_group_by_hex(&self, hex_id: &str) -> Result<sonar_core::GroupId> {
        for g in self.client.groups()? {
            if gid_hex(&g.mls_group_id) == hex_id {
                return Ok(g.mls_group_id);
            }
        }
        Err(anyhow!("unknown group id {hex_id}"))
    }
}

#[async_trait::async_trait]
impl SonarBackend for SonarCoreBackend {
    async fn groups(&self) -> Result<Vec<Group>> {
        let mut out = Vec::new();
        for g in self.client.groups()? {
            let id = gid_hex(&g.mls_group_id);
            let members = self
                .client
                .members(&g.mls_group_id)
                .map(|pks| {
                    pks.into_iter()
                        .map(|pk| Member {
                            npub: pk.to_bech32().unwrap_or_default(),
                            nick: nick_from_pubkey(&pk),
                        })
                        .collect::<Vec<Member>>()
                })
                .unwrap_or_default();
            out.push(Group { id, name: g.name, members });
        }
        Ok(out)
    }

    async fn send_text(&self, group: &GroupId, text: &str) -> Result<()> {
        let gid = self.find_group_by_hex(group)?;
        self.client.send_text(&gid, text).await.context("sonar send_text")
    }

    async fn resolve_dm(&self, peer: &str) -> Result<Group> {
        let pk = nostr::PublicKey::parse(peer).context("peer must be npub or hex pubkey")?;
        let gid = self.client.start_dm(pk, peer).await.context("start_dm")?;
        Ok(Group {
            id: gid_hex(&gid),
            name: peer.to_string(),
            members: vec![
                self.local.clone(),
                Member { npub: pk.to_bech32().unwrap_or_default(), nick: peer.to_string() },
            ],
        })
    }
}

async fn poll_loop(client: Arc<SonarClient>, tx: tokio::sync::mpsc::UnboundedSender<InboundMessage>, every: Duration) {
    let mut seen: HashSet<String> = HashSet::new();
    let mut tick = interval(every);
    tick.tick().await; // first tick is immediate
    loop {
        tick.tick().await;
        if let Err(e) = client.sync().await {
            tracing::warn!(error = %e, "sonar sync");
            continue;
        }
        let groups = match client.groups() {
            Ok(g) => g,
            Err(e) => {
                tracing::warn!(error = %e, "groups");
                continue;
            }
        };
        for g in groups {
            let key = gid_hex(&g.mls_group_id);
            let msgs = match client.messages(&g.mls_group_id) {
                Ok(m) => m,
                Err(e) => {
                    tracing::warn!(error = %e, "messages");
                    continue;
                }
            };
            for m in msgs.iter().rev().take(50) {
                let mid = m.id.to_hex();
                if seen.insert(mid) {
                    let _ = tx.send(InboundMessage {
                        group: key.clone(),
                        sender_nick: nick_from_pubkey(&m.sender),
                        sender_npub: m.sender.to_bech32().unwrap_or_default(),
                        text: m.content.clone(),
                    });
                }
            }
        }
    }
}

fn nick_from_pubkey(pk: &nostr::PublicKey) -> String {
    match pk.to_bech32() {
        Ok(n) if n.len() > 8 => format!("sonar-{}", &n[n.len() - 6..]),
        _ => "sonar-peer".to_string(),
    }
}

fn resolve_relays(cfg: &Config) -> Vec<String> {
    if cfg.backend.relays.is_empty() {
        DEFAULT_RELAYS.iter().map(|s| s.to_string()).collect()
    } else {
        cfg.backend.relays.clone()
    }
}

fn load_or_create_identity(home: &PathBuf, cfg: &Config) -> Result<Identity> {
    if let Some(var) = &cfg.backend.nsec_env {
        if let Ok(val) = std::env::var(var) {
            return Identity::import(&val).context("import nsec from env");
        }
    }
    if let Some(path) = &cfg.backend.nsec_file {
        let s = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        return Identity::import(s.trim()).context("import nsec from file");
    }
    let id_file = home.join("identity.nsec");
    if id_file.exists() {
        let s = std::fs::read_to_string(&id_file).with_context(|| format!("reading {}", id_file.display()))?;
        return Identity::import(s.trim()).context("import nsec");
    }
    let id = Identity::generate();
    let nsec = id.export_nsec();
    let _ = std::fs::write(&id_file, nsec);
    Ok(id)
}

fn load_or_create_db_key(home: &PathBuf) -> Result<[u8; 32]> {
    let key_file = home.join("db.key");
    if key_file.exists() {
        let hex_str = std::fs::read_to_string(&key_file)?;
        return decode_hex_32(hex_str.trim());
    }
    use rand::Rng;
    let mut buf = [0u8; 32];
    rand::thread_rng().fill(&mut buf);
    let hex_str: String = buf.iter().map(|b| format!("{b:02x}")).collect();
    let _ = std::fs::write(&key_file, hex_str);
    Ok(buf)
}

fn decode_hex_32(hex_str: &str) -> Result<[u8; 32]> {
    let bytes = hex::decode(hex_str).context("db key hex")?;
    if bytes.len() != 32 {
        return Err(anyhow!("db key must be 32 bytes"));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

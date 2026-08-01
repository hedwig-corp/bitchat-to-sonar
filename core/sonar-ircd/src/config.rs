//! TOML configuration for sonar-ircd.

use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct BackendConfig {
    #[serde(default)]
    pub home: Option<PathBuf>,
    #[serde(default)]
    pub nsec_file: Option<PathBuf>,
    #[serde(default)]
    pub nsec_env: Option<String>,
    #[serde(default)]
    pub relays: Vec<String>,
    #[serde(default)]
    pub nick: Option<String>,
}

impl Default for BackendConfig {
    fn default() -> Self {
        Self { home: None, nsec_file: None, nsec_env: None, relays: Vec::new(), nick: None }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct IrcBridgeConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub server: String,
    #[serde(default = "default_bridge_port")]
    pub port: u16,
    #[serde(default = "default_bridge_nick")]
    pub nickname: String,
    #[serde(default)]
    pub channel: String,
    #[serde(default)]
    pub local_channel: Option<String>,
}

fn default_bridge_port() -> u16 {
    6667
}
fn default_bridge_nick() -> String {
    "sonar-bridge".to_string()
}

impl Default for IrcBridgeConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            server: String::new(),
            port: default_bridge_port(),
            nickname: default_bridge_nick(),
            channel: String::new(),
            local_channel: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    #[serde(default = "default_listen")]
    pub listen: SocketAddr,
    #[serde(default = "default_server_name")]
    pub server_name: String,
    #[serde(default)]
    pub backend: BackendConfig,
    #[serde(default)]
    pub irc_bridge: IrcBridgeConfig,
}

fn default_listen() -> SocketAddr {
    "127.0.0.1:6667".parse().expect("valid default listen addr")
}
fn default_server_name() -> String {
    "sonar-ircd".to_string()
}

impl Config {
    pub fn load() -> Result<Self> {
        let path = match std::env::var("SONAR_IRCD_CONFIG").ok() {
            Some(p) => PathBuf::from(p),
            None => match std::env::args().nth(1) {
                Some(a) if a != "--help" && a != "-h" && !a.starts_with('-') => PathBuf::from(a),
                _ => PathBuf::from("config.toml"),
            },
        };
        if path.exists() {
            let raw = std::fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
            toml::from_str(&raw).with_context(|| format!("parsing {}", path.display()))
        } else {
            tracing::warn!("{} not found -- using defaults (127.0.0.1:6667)", path.display());
            Ok(Config::default())
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            listen: default_listen(),
            server_name: default_server_name(),
            backend: BackendConfig::default(),
            irc_bridge: IrcBridgeConfig::default(),
        }
    }
}

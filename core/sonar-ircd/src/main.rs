//! sonar-ircd -- an IRC server that bridges to Sonar (sonar-core).
//!
//! Any IRC client (halloy, irssi, weechat, ...) connects to this process as if
//! it were an ordinary IRC server. Channels map to Sonar MLS groups, queries to
//! 1:1 DMs. An optional [irc_bridge] mirrors an external IRC channel into a
//! local channel. In-tree consumer of sonar-core, sibling to sonar-cli.

mod backend;
mod bridge;
mod config;
mod irc;
mod sonar;
mod uplink;

use anyhow::Result;
use tokio::sync::mpsc;

use backend::BuiltBackend;
use irc::server::ClientEvent;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,sonar_ircd=debug")),
        )
        .init();

    let cfg = config::Config::load()?;
    tracing::info!(listen = %cfg.listen, "sonar-ircd starting");

    let BuiltBackend { backend, mut events } = sonar::SonarCoreBackend::build(&cfg).await?;
    let bridge = bridge::Bridge::build(backend, cfg.server_name.clone()).await?;

    if cfg.irc_bridge.enabled && !cfg.irc_bridge.channel.is_empty() {
        let local = cfg
            .irc_bridge
            .local_channel
            .clone()
            .unwrap_or_else(|| cfg.irc_bridge.channel.clone());
        let (out_tx, out_rx) = mpsc::unbounded_channel::<String>();
        bridge.register_bridge(local.clone(), out_tx);
        let up_cfg = uplink::UplinkConfig {
            server: cfg.irc_bridge.server.clone(),
            port: cfg.irc_bridge.port,
            nickname: cfg.irc_bridge.nickname.clone(),
            channel: cfg.irc_bridge.channel.clone(),
            local_channel: local,
        };
        let up_bridge = bridge.clone();
        tokio::spawn(uplink::run_uplink(up_cfg, up_bridge, out_rx));
    }

    let fan_bridge = bridge.clone();
    tokio::spawn(async move {
        while let Some(msg) = events.recv().await {
            let channel = fan_bridge.ensure_channel(&msg.group, &msg.sender_nick);
            fan_bridge.emit(ClientEvent::ChannelMessage {
                channel,
                sender_nick: msg.sender_nick,
                sender_npub: msg.sender_npub,
                text: msg.text,
            });
        }
        tracing::info!("backend event stream ended");
    });

    let server = irc::server::Server::new(bridge, cfg.listen);
    server.run().await
}

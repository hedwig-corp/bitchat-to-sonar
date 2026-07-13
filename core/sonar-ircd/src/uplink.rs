//! Outbound IRC bridge: connects to an external IRC server as a client, joins a
//! channel, and mirrors it into a local channel (so IRC clients like halloy see
//! the external traffic, and their replies are relayed out). Plaintext in v1.

use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::tcp::OwnedWriteHalf;
use tokio::net::TcpStream;
use tokio::sync::mpsc;

use crate::bridge::Bridge;
use crate::irc::codec;
use crate::irc::server::ClientEvent;

pub struct UplinkConfig {
    pub server: String,
    pub port: u16,
    pub nickname: String,
    pub channel: String,
    pub local_channel: String,
}

pub async fn run_uplink(cfg: UplinkConfig, bridge: Arc<Bridge>, out_rx: mpsc::UnboundedReceiver<String>) {
    if let Err(e) = connect_and_serve(&cfg, &bridge, out_rx).await {
        tracing::warn!(error = %e, "uplink ended (no auto-reconnect in v1)");
    }
}

async fn connect_and_serve(
    cfg: &UplinkConfig,
    bridge: &Arc<Bridge>,
    out_rx: mpsc::UnboundedReceiver<String>,
) -> anyhow::Result<()> {
    tracing::info!(server = %cfg.server, port = cfg.port, channel = %cfg.channel, "uplink connecting");

    // Retry TCP connect a few times to survive a startup race with the external IRC server.
    let stream = {
        let mut last: Option<std::io::Error> = None;
        let mut connected: Option<TcpStream> = None;
        for _ in 0..20u32 {
            match TcpStream::connect((cfg.server.as_str(), cfg.port)).await {
                Ok(s) => {
                    connected = Some(s);
                    break;
                }
                Err(e) => {
                    last = Some(e);
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
            }
        }
        match connected {
            Some(s) => s,
            None => {
                return Err(anyhow::anyhow!(
                    "uplink connect to {}:{} failed: {:?}",
                    cfg.server,
                    cfg.port,
                    last
                ));
            }
        }
    };

    let (read_half, write_half) = stream.into_split();
    let (write_tx, write_rx) = mpsc::unbounded_channel::<String>();
    tokio::spawn(writer_task(write_half, write_rx));

    let _ = write_tx.send(ln(&format!("NICK {}", cfg.nickname)));
    let _ = write_tx.send(ln(&format!("USER {} 0 * :sonar-ircd bridge", cfg.nickname)));
    let _ = write_tx.send(ln(&format!("JOIN {}", cfg.channel)));

    // local -> external (halloy posts in the local channel -> out to IRC).
    let wt = write_tx.clone();
    let chan = cfg.channel.clone();
    tokio::spawn(async move {
        let mut out_rx = out_rx;
        while let Some(text) = out_rx.recv().await {
            let _ = wt.send(ln(&format!("PRIVMSG {chan} :{text}")));
        }
    });

    // external -> local (IRC traffic -> emit on the local channel).
    let mut reader = BufReader::new(read_half);
    let mut buf = String::new();
    let local = cfg.local_channel.clone();
    let myself = cfg.nickname.clone();
    let extchan = cfg.channel.clone();
    loop {
        buf.clear();
        match reader.read_line(&mut buf).await {
            Ok(0) => return Err(anyhow::anyhow!("uplink EOF")),
            Ok(_) => {
                if let Some(m) = codec::parse_line(&buf) {
                    match m.command.as_str() {
                        "PING" => {
                            let _ = write_tx.send(ln(&format!("PONG :{}", m.trailing().unwrap_or(""))));
                        }
                        "PRIVMSG" => {
                            if m.param(0) == Some(extchan.as_str()) {
                                let sender = m
                                    .prefix
                                    .as_deref()
                                    .and_then(|p| p.split('!').next())
                                    .unwrap_or("ext")
                                    .to_string();
                                if sender != myself {
                                    if let Some(text) = m.trailing() {
                                        bridge.emit(ClientEvent::ChannelMessage {
                                            channel: local.clone(),
                                            sender_nick: sender,
                                            sender_npub: String::new(),
                                            text: text.to_string(),
                                        });
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            Err(_) => return Err(anyhow::anyhow!("uplink read error")),
        }
    }
}

async fn writer_task(mut write_half: OwnedWriteHalf, mut write_rx: mpsc::UnboundedReceiver<String>) {
    while let Some(line) = write_rx.recv().await {
        if write_half.write_all(line.as_bytes()).await.is_err() {
            break;
        }
    }
    let _ = write_half.shutdown().await;
}

fn ln(body: &str) -> String {
    let mut s = body.to_string();
    s.push(char::from_u32(13).unwrap());
    s.push(char::from_u32(10).unwrap());
    s
}



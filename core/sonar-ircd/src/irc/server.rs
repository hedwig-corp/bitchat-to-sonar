//! IRC server: accept loop + one session per connection, bridging IRC commands
//! to the shared Bridge (and from there to the sonar backend).

use std::net::SocketAddr;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc};

use crate::backend::{Group, Member};
use crate::bridge::Bridge;
use crate::irc::codec::{self, IrcMessage};

/// An inbound sonar message, delivered to every connected IRC client.
#[derive(Clone, Debug)]
pub enum ClientEvent {
    ChannelMessage {
        channel: String,
        sender_nick: String,
        sender_npub: String,
        text: String,
    },
}

pub struct Server {
    listen: SocketAddr,
    bridge: Arc<Bridge>,
}

impl Server {
    pub fn new(bridge: Arc<Bridge>, listen: SocketAddr) -> Self {
        Self { listen, bridge }
    }

    pub async fn run(self) -> anyhow::Result<()> {
        let listener = TcpListener::bind(self.listen).await?;
        tracing::info!("IRC listener bound on {}", self.listen);
        loop {
            match listener.accept().await {
                Ok((stream, peer)) => {
                    let bridge = self.bridge.clone();
                    tokio::spawn(async move {
                        let mut session = Session::new(stream, bridge);
                        if let Err(e) = session.run().await {
                            tracing::debug!(%peer, error = %e, "session ended");
                        }
                    });
                }
                Err(e) => tracing::warn!(error = %e, "accept failed"),
            }
        }
    }
}

enum Next {
    Msg(Option<IrcMessage>),
    Evt(Result<ClientEvent, broadcast::error::RecvError>),
}

struct Session {
    out_tx: mpsc::UnboundedSender<String>,
    msg_rx: mpsc::Receiver<IrcMessage>,
    fanout_rx: broadcast::Receiver<ClientEvent>,
    bridge: Arc<Bridge>,
    nick: String,
    user: String,
    server_name: String,
}

impl Session {
    fn new(stream: TcpStream, bridge: Arc<Bridge>) -> Self {
        let (read_half, write_half) = stream.into_split();
        let (out_tx, out_rx) = mpsc::unbounded_channel::<String>();
        let (msg_tx, msg_rx) = mpsc::channel::<IrcMessage>(32);

        tokio::spawn(writer_task(write_half, out_rx));
        tokio::spawn(reader_task(read_half, msg_tx));

        let fanout_rx = bridge.subscribe();

        Session {
            out_tx,
            msg_rx,
            fanout_rx,
            bridge,
            nick: String::new(),
            user: String::new(),
            server_name: String::new(),
        }
    }

    fn send(&self, body: String) {
        let mut line = body;
        line.push(char::from_u32(13).unwrap());
        line.push(char::from_u32(10).unwrap());
        let _ = self.out_tx.send(line);
    }

    async fn run(&mut self) -> anyhow::Result<()> {
        self.server_name = self.bridge.server_name.clone();

        // Phase 1: wait for NICK + USER (ignore CAP etc.).
        loop {
            match self.msg_rx.recv().await {
                None => return Ok(()),
                Some(m) => {
                    match m.command.as_str() {
                        "NICK" => {
                            if let Some(n) = m.param(0) {
                                self.nick = sanitize_nick(n);
                            }
                        }
                        "USER" => {
                            if let Some(u) = m.param(0) {
                                self.user = u.to_string();
                            }
                        }
                        "QUIT" => return Ok(()),
                        "PING" => self.send(format!("PONG :{}", m.trailing().unwrap_or(""))),
                        _ => {}
                    }
                    if !self.nick.is_empty() && !self.user.is_empty() {
                        break;
                    }
                }
            }
        }

        self.welcome();
        self.auto_join();

        // Phase 2: client commands + inbound fan-out.
        loop {
            let next = tokio::select! {
                biased;
                m = self.msg_rx.recv() => Next::Msg(m),
                e = self.fanout_rx.recv() => Next::Evt(e),
            };
            match next {
                Next::Msg(None) => break,
                Next::Msg(Some(m)) => {
                    if self.handle_command(m).await {
                        break;
                    }
                }
                Next::Evt(Ok(ClientEvent::ChannelMessage { channel, sender_nick, sender_npub, text })) => {
                    let uh = userhost(&sender_nick, &sender_npub);
                    self.send(format!(":{uh} PRIVMSG {channel} :{text}"));
                }
                Next::Evt(Err(broadcast::error::RecvError::Lagged(n))) => {
                    tracing::warn!(n, "irc client lagged behind fan-out");
                }
                Next::Evt(Err(broadcast::error::RecvError::Closed)) => break,
            }
        }
        Ok(())
    }

    fn welcome(&self) {
        let srv = &self.server_name;
        let nick = &self.nick;
        self.send(codec::numeric(srv, "001", nick, &format!("Welcome to the Sonar IRC bridge, {nick}")));
        self.send(codec::numeric(srv, "002", nick, "Your host is sonar-ircd, running the option-A bridge"));
        self.send(codec::numeric(srv, "003", nick, "This server bridges IRC to Sonar (Nostr + Marmot/MLS)"));
        self.send(format!(":{srv} 004 {nick} {srv} sonar-ircd 0.1.0 itS"));
        self.send(format!(":{srv} 005 {nick} NETWORK=Sonar CHANTYPES=# NICKLEN=30 CHANNELLEN=50 CASEMAPPING=rfc1459 :are supported by this server"));
        self.send(codec::numeric(srv, "375", nick, "- sonar-ircd Message of the day -"));
        self.send(codec::numeric(srv, "372", nick, "- Channels = your Sonar groups; queries = 1:1 DMs."));
        self.send(codec::numeric(srv, "376", nick, "End of MOTD"));
    }

    fn auto_join(&self) {
        for (chan, group) in self.bridge.all_channels() {
            self.join_channel(&chan, &group);
        }
    }

    fn join_channel(&self, chan: &str, group: &Group) {
        let srv = &self.server_name;
        let nick = &self.nick;
        let uh = format!("{nick}!{u}@sonar", u = self.user);
        self.send(format!(":{uh} JOIN {chan}"));
        self.send(codec::numeric(srv, "332", &format!("{nick} {chan}"), &format!("Sonar group: {}", group.name)));
        self.send(codec::numeric(srv, "333", &format!("{nick} {chan}"), &format!("{uh} 0")));
        self.send(codec::numeric(srv, "353", &format!("{nick} = {chan}"), &names_list(group, nick)));
        self.send(codec::numeric(srv, "366", &format!("{nick} {chan}"), "End of /NAMES list."));
    }

    async fn handle_command(&mut self, m: IrcMessage) -> bool {
        let srv = self.server_name.clone();
        let nick = self.nick.clone();
        match m.command.as_str() {
            "PING" => self.send(format!("PONG :{}", m.trailing().unwrap_or(""))),
            "PONG" => {}
            "JOIN" => {
                if let Some(targets) = m.param(0) {
                    for chan in targets.split(',') {
                        let chan = chan.trim();
                        if chan.is_empty() {
                            continue;
                        }
                        match self.bridge.group_for_channel(chan) {
                            Some(group) => self.join_channel(chan, &group),
                            None => self.send(codec::numeric(&srv, "403", &format!("{nick} {chan}"), "No such channel (only mapped Sonar groups are joinable)")),
                        }
                    }
                }
            }
            "PART" => {
                if let Some(chan) = m.param(0) {
                    self.send(format!(":{nick}!{u}@sonar PART {chan} :leaving", u = self.user));
                }
            }
            "PRIVMSG" | "NOTICE" => {
                if let (Some(target), Some(text)) = (m.param(0), m.trailing()) {
                    if target.starts_with('#') {
                        if self.bridge.is_bridged(target) {
                            self.bridge.forward_to_bridge(text);
                        } else {
                            match self.bridge.group_for_channel(target) {
                                Some(group) => {
                                    if let Err(e) = self.bridge.backend.send_text(&group.id, text).await {
                                        tracing::warn!(error = %e, "send_text failed");
                                        self.send(codec::numeric(&srv, "404", &format!("{nick} {target}"), "Could not deliver message"));
                                    }
                                }
                                None => self.send(codec::numeric(&srv, "403", &format!("{nick} {target}"), "No such channel")),
                            }
                        }
                    } else {
                        match self.bridge.backend.resolve_dm(target).await {
                            Ok(group) => {
                                let _ = self.bridge.ensure_channel(&group.id, target);
                                if let Err(e) = self.bridge.backend.send_text(&group.id, text).await {
                                    tracing::warn!(error = %e, "dm send failed");
                                    self.send(codec::numeric(&srv, "401", &format!("{nick} {target}"), "Could not deliver DM"));
                                }
                            }
                            Err(e) => {
                                tracing::warn!(error = %e, "resolve_dm failed");
                                self.send(codec::numeric(&srv, "401", &format!("{nick} {target}"), "No such nick"));
                            }
                        }
                    }
                }
            }
            "QUIT" => {
                self.send("ERROR :Closing link".to_string());
                return true;
            }
            "NAMES" => {
                if let Some(chan) = m.param(0) {
                    if let Some(group) = self.bridge.group_for_channel(chan) {
                        self.send(codec::numeric(&srv, "353", &format!("{nick} = {chan}"), &names_list(&group, &nick)));
                        self.send(codec::numeric(&srv, "366", &format!("{nick} {chan}"), "End of /NAMES list."));
                    }
                }
            }
            "WHO" => {
                if let Some(chan) = m.param(0) {
                    self.send(codec::numeric(&srv, "315", &format!("{nick} {chan}"), "End of /WHO list."));
                }
            }
            "CAP" => {
                if let Some(sub) = m.param(0) {
                    if sub.eq_ignore_ascii_case("LS") {
                        self.send(format!(":{srv} CAP * LS :"));
                    } else if sub.eq_ignore_ascii_case("REQ") {
                        self.send(format!(":{srv} CAP * NAK :{}", m.param(1).unwrap_or("")));
                    }
                }
            }
            _ => {}
        }
        false
    }
}

async fn writer_task(mut write_half: OwnedWriteHalf, mut out_rx: mpsc::UnboundedReceiver<String>) {
    while let Some(line) = out_rx.recv().await {
        if write_half.write_all(line.as_bytes()).await.is_err() {
            break;
        }
    }
    let _ = write_half.shutdown().await;
}

async fn reader_task(read_half: OwnedReadHalf, msg_tx: mpsc::Sender<IrcMessage>) {
    let mut reader = BufReader::new(read_half);
    let mut buf = String::new();
    loop {
        buf.clear();
        match reader.read_line(&mut buf).await {
            Ok(0) => break,
            Ok(_) => {
                if let Some(m) = codec::parse_line(&buf) {
                    if msg_tx.send(m).await.is_err() {
                        break;
                    }
                }
            }
            Err(_) => break,
        }
    }
}

fn names_list(group: &Group, local_nick: &str) -> String {
    let mut names = vec![local_nick.to_string()];
    for m in &group.members {
        let n = sanitize_nick(&member_nick(m));
        if n != local_nick && !names.contains(&n) {
            names.push(n);
        }
    }
    names.join(" ")
}

fn member_nick(m: &Member) -> String {
    if !m.nick.is_empty() {
        m.nick.clone()
    } else {
        npub_nick(&m.npub)
    }
}

fn npub_nick(npub: &str) -> String {
    let tail = npub.len().saturating_sub(6);
    let s = &npub[tail..];
    if s.is_empty() {
        "sonar-peer".to_string()
    } else {
        format!("sonar-{s}")
    }
}

fn userhost(nick: &str, npub: &str) -> String {
    let ident: String = npub.chars().filter(|c| !matches!(c, ' ' | '@' | '#' | '!' | ',')).take(20).collect();
    let ident = if ident.is_empty() { "sonar".to_string() } else { ident };
    format!("{nick}!~{ident}@sonar")
}

fn sanitize_nick(input: &str) -> String {
    let mut chars = input.trim().chars();
    let first = match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || is_nick_special(c) => c,
        _ => return "sonar-user".to_string(),
    };
    let mut out = String::from(first);
    for c in chars.take(29) {
        if c.is_ascii_alphanumeric() || is_nick_special(c) {
            out.push(c);
        }
    }
    out
}

/// IRC "special" nick chars: [ ] backslash backtick _ - ^ { | } (compared by
/// code point so the source stays free of literal backslash/backtick chars).
fn is_nick_special(c: char) -> bool {
    matches!(c as u32, 91 | 93 | 92 | 96 | 95 | 45 | 94 | 123 | 124 | 125)
}

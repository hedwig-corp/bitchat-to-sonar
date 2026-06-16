//! Minimal iroh P2P transport for calls (plan phase P0).
//!
//! Proves iroh integrates + connects inside `sonar-core`: a `CallTransport`
//! binds an iroh `Endpoint` (Ed25519 `EndpointId` identity, QUIC, NAT
//! hole-punching) and dials/accepts peer connections over the Sonar call ALPN.
//! The RTP-over-QUIC media + cpal/opus pipeline layer on top of this connection
//! in a later phase (see `docs/plans/2026-06-16-p2p-calls-iroh-callme.md`).
//!
//! VERSION NOTE: this uses **iroh 1.0** (the current, buildable release). The
//! `callme`/iroh-roq media stack pins iroh 0.33, whose old dependency tree does
//! not compile on the current toolchain — so the media layer must be built on
//! iroh 1.0 directly (or wait for an iroh-roq release on 1.0). See the plan's
//! "P0 attempt findings". iroh 1.0 renamed Node{Id,Addr} → Endpoint{Id,Addr}.

use anyhow::{Context, Result};
use iroh::endpoint::{presets, Connection};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};

/// ALPN for Sonar call connections. Once the media layer lands, the RTP session
/// runs *inside* this connection.
pub const CALL_ALPN: &[u8] = b"sonar/call/0";

/// A bound iroh endpoint for placing/accepting calls. Owns the QUIC socket + the
/// Ed25519 endpoint identity; one per app session.
pub struct CallTransport {
    endpoint: Endpoint,
}

impl CallTransport {
    /// Bind an endpoint for a call, with the iroh secret derived from the Sonar
    /// identity (`call::identity::derive_iroh_secret`). Uses the `N0` preset
    /// (crypto + address discovery) WITH relays enabled — relays give NAT
    /// hole-punching for real cross-network calls between two phones; the dialable
    /// [`EndpointAddr`] is still exchanged in the `☎CALL` signaling.
    pub async fn bind(secret: [u8; 32]) -> Result<Self> {
        Self::build(secret, true).await
    }

    async fn build(secret: [u8; 32], relays: bool) -> Result<Self> {
        let secret_key = SecretKey::from_bytes(&secret);
        let mut builder = Endpoint::builder(presets::N0)
            .secret_key(secret_key)
            .alpns(vec![CALL_ALPN.to_vec()]);
        if !relays {
            builder = builder.relay_mode(iroh::RelayMode::Disabled);
        }
        let endpoint = builder.bind().await.context("bind iroh endpoint")?;
        Ok(Self { endpoint })
    }

    /// Relay-less bind (direct addresses only) — for hermetic same-network tests.
    #[cfg(test)]
    pub(crate) async fn bind_relay_less(secret: [u8; 32]) -> Result<Self> {
        Self::build(secret, false).await
    }

    /// Our endpoint id (Ed25519 public key).
    pub fn endpoint_id(&self) -> EndpointId {
        self.endpoint.id()
    }

    /// Our full dialable address (id + direct socket addresses) to embed in a
    /// `☎CALL` OFFER/ANSWER.
    pub fn endpoint_addr(&self) -> EndpointAddr {
        self.endpoint.addr()
    }

    /// Dial a peer (the answerer dials, per the signaling design §4.3).
    pub async fn connect(&self, addr: EndpointAddr) -> Result<Connection> {
        self.endpoint
            .connect(addr, CALL_ALPN)
            .await
            .context("connect to peer")
    }

    /// Accept the next inbound call connection.
    ///
    /// SECURITY: the caller MUST pin the remote id (via [`Connection::remote_id`])
    /// against the `EndpointId` it received in the encrypted `☎CALL` OFFER/ANSWER
    /// and drop connections from any other id — this accepts any inbound ALPN
    /// match. QUIC already authenticates the peer's id cryptographically, so
    /// pinning fully binds the media session to the signaling identity.
    pub async fn accept(&self) -> Result<Connection> {
        let incoming = self.endpoint.accept().await.context("endpoint closed")?;
        incoming.await.context("accept inbound connection")
    }

    /// Close the endpoint (ends all calls).
    pub async fn close(&self) {
        self.endpoint.close().await;
    }
}

/// Wrap a call [`Connection`] in an iroh-roq RTP-over-QUIC session. The media
/// layer opens one send/receive *flow* per track (audio, later video) on it —
/// `session.new_send_flow(id)` / `new_receive_flow(id)`. This links our vendored
/// iroh-roq (ported to iroh 1.0, `core/vendor/iroh-roq`) against our iroh 1.0
/// connections, proving the RTP media transport integrates end-to-end. Both
/// resolve to the same iroh 1.0, so the `Connection` passes between them.
pub fn rtc_session(conn: Connection) -> iroh_roq::Session {
    iroh_roq::Session::new(conn)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// P0: iroh 1.0 integrates + binds inside `sonar-core`. Two endpoints come up
    /// with distinct, deterministic Ed25519 ids and a dialable address. This is
    /// the load-bearing proof that the iroh dependency resolves, cross-compiles,
    /// and the transport API works in our core — fast and hermetic (no network).
    #[tokio::test]
    async fn binds_distinct_deterministic_endpoints() -> Result<()> {
        let a = CallTransport::bind([1u8; 32]).await?;
        let b = CallTransport::bind([2u8; 32]).await?;
        // Distinct secrets → distinct endpoint ids.
        assert_ne!(a.endpoint_id(), b.endpoint_id());
        // The id is deterministic from the host-persisted secret (stable across
        // binds → stable NodeId for reconnection/signaling).
        let a2 = CallTransport::bind([1u8; 32]).await?;
        assert_eq!(a.endpoint_id(), a2.endpoint_id());
        // A dialable address is obtainable (goes into the ☎CALL OFFER/ANSWER).
        let _addr = a.endpoint_addr();
        a.close().await;
        b.close().await;
        a2.close().await;
        Ok(())
    }

    /// P0: two in-process iroh nodes connect over the call ALPN (relay-less,
    /// direct addresses via the `N0` preset), pin each other's endpoint id, and
    /// exchange a payload over a QUIC bi-stream — the connection the media
    /// pipeline runs inside. Wrapped in a timeout so a connectivity regression
    /// fails fast instead of hanging.
    #[tokio::test]
    async fn two_nodes_connect_and_exchange() -> Result<()> {
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
        let a = CallTransport::bind_relay_less([1u8; 32]).await?;
        let b = CallTransport::bind_relay_less([2u8; 32]).await?;
        let a_addr = a.endpoint_addr();
        let (a_id, b_id) = (a.endpoint_id(), b.endpoint_id());

        // b dials a; a accepts.
        let (conn_b, conn_a) = tokio::join!(b.connect(a_addr), a.accept());
        let conn_b = conn_b?;
        let conn_a = conn_a?;

        // Endpoint-id pinning check (the security property §3.1 relies on).
        assert_eq!(conn_a.remote_id(), b_id);
        assert_eq!(conn_b.remote_id(), a_id);

        // b opens a bi-stream and sends; a accepts it and echoes.
        let payload = b"sonar-call-hello";
        let send = async {
            let (mut s, mut r) = conn_b.open_bi().await?;
            s.write_all(payload).await?;
            s.finish()?;
            let got = r.read_to_end(1024).await?;
            anyhow::Ok(got)
        };
        let echo = async {
            let (mut s, mut r) = conn_a.accept_bi().await?;
            let got = r.read_to_end(1024).await?;
            s.write_all(&got).await?;
            s.finish()?;
            anyhow::Ok(())
        };
        let (got, ()) = tokio::try_join!(send, echo)?;
        assert_eq!(got, payload);

        a.close().await;
        b.close().await;
        anyhow::Ok(())
        })
        .await
        .context("connection test timed out (needs relay/direct-address wait)")??;
        Ok(())
    }
}

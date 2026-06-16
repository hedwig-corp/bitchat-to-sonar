//! Call media path: opus audio packets over iroh-roq RTP-over-QUIC flows.
//!
//! A call connection ([`super::transport::CallTransport`]) is wrapped in an
//! `iroh_roq::Session`; each audio track is one RTP *flow* (a `VarInt` id). The
//! sender opus-encodes 20 ms frames, packs each into an RTP packet, and
//! `send_rtp`s it on the send-flow; the receiver `read_rtp`s on the matching
//! receive-flow and opus-decodes. This is the transport the full pipeline
//! (cpal capture/playback) plugs into next.

use opus::{Application, Channels, Decoder, Encoder};

use crate::call::codec::SAMPLE_RATE;

/// Audio flow id (track 0). Video would use a second flow id.
pub const AUDIO_FLOW_ID: u32 = 0;

/// A configured opus encoder for call audio (mono, Voip, 48 kHz).
pub fn opus_encoder(channels: Channels) -> anyhow::Result<Encoder> {
    Ok(Encoder::new(SAMPLE_RATE, channels, Application::Voip)?)
}

/// A configured opus decoder matching [`opus_encoder`].
pub fn opus_decoder(channels: Channels) -> anyhow::Result<Decoder> {
    Ok(Decoder::new(SAMPLE_RATE, channels)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::call::transport::{rtc_session, CallTransport};
    use iroh_roq::{rtp, VarInt};
    use std::time::Duration;

    /// M2b audio smoke test — the media path end to end, hermetic, no devices:
    /// two in-process iroh nodes connect, node A opus-encodes a 20 ms frame and
    /// `send_rtp`s it over an iroh-roq send-flow, node B `read_rtp`s on the
    /// matching receive-flow and opus-decodes it back to non-silent audio.
    /// Proves transport + iroh-roq + opus all work together.
    #[tokio::test]
    async fn audio_smoke_opus_over_iroh_roq() -> anyhow::Result<()> {
        tokio::time::timeout(Duration::from_secs(30), async {
            // Connect two nodes (relay-less, direct).
            let a = CallTransport::bind_relay_less([1u8; 32]).await?;
            let b = CallTransport::bind_relay_less([2u8; 32]).await?;
            let a_addr = a.endpoint_addr();
            let (conn_b, conn_a) = tokio::join!(b.connect(a_addr), a.accept());
            let conn_a = conn_a?;
            let conn_b = conn_b?;

            let flow = VarInt::from_u32(AUDIO_FLOW_ID);
            // A is the sender, B the receiver.
            let session_a = rtc_session(conn_a);
            let send_flow = session_a.new_send_flow(flow).await?;
            let session_b = rtc_session(conn_b);
            let mut recv_flow = session_b.new_receive_flow(flow).await?;

            // Encode a non-silent 20 ms stereo frame.
            const SAMPLES: usize = (SAMPLE_RATE as usize / 1000) * 20; // 960 per channel
            let mut enc = opus_encoder(Channels::Stereo)?;
            let mut pcm = vec![0i16; SAMPLES * 2];
            for (i, s) in pcm.iter_mut().enumerate() {
                *s = ((i as f32 * 0.05).sin() * 8000.0) as i16;
            }
            let mut buf = vec![0u8; 1500];
            let n = enc.encode(&pcm, &mut buf)?;
            let packet = rtp::packet::Packet {
                header: rtp::header::Header {
                    sequence_number: 0,
                    timestamp: 0,
                    marker: true,
                    ..Default::default()
                },
                payload: bytes::Bytes::copy_from_slice(&buf[..n]),
            };

            // Send over the QUIC RTP flow; receive on the other node.
            send_flow.send_rtp(&packet)?;
            let incoming = recv_flow.read_rtp().await?;

            // Decode on B → a full, non-silent frame.
            let mut dec = opus_decoder(Channels::Stereo)?;
            let mut out = vec![0i16; SAMPLES * 2];
            let decoded = dec.decode(&incoming.payload, &mut out, false)?;
            assert_eq!(decoded, SAMPLES, "decoded one 20 ms frame");
            assert!(out.iter().any(|s| *s != 0), "received audio is non-silent");

            a.close().await;
            b.close().await;
            anyhow::Ok(())
        })
        .await
        .map_err(|_| anyhow::anyhow!("audio smoke test timed out"))??;
        Ok(())
    }
}

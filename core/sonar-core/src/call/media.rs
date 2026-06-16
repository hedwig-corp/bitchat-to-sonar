//! Call media path: opus audio packets over iroh-roq RTP-over-QUIC flows.
//!
//! A call connection ([`super::transport::CallTransport`]) is wrapped in an
//! `iroh_roq::Session`; each audio track is one RTP *flow* (a `VarInt` id). The
//! sender opus-encodes 20 ms frames, packs each into an RTP packet, and
//! `send_rtp`s it on the send-flow; the receiver `read_rtp`s on the matching
//! receive-flow and opus-decodes. This is the transport the full pipeline
//! (cpal capture/playback) plugs into next.

use iroh_roq::{rtp, Session, VarInt};
use opus::{Application, Channels, Decoder, Encoder};
use tokio::sync::mpsc::{self, error::TrySendError};

use crate::call::codec::SAMPLE_RATE;

/// Audio flow id (track 0). Video would use a second flow id.
pub const AUDIO_FLOW_ID: u32 = 0;

/// Samples per channel in a 20 ms frame.
const FRAME_PER_CHANNEL: usize = (SAMPLE_RATE as usize / 1000) * 20; // 960

fn channels_count(c: Channels) -> usize {
    match c {
        Channels::Mono => 1,
        Channels::Stereo => 2,
    }
}

/// Names of the default input/output audio devices (cpal). A minimal touchpoint
/// that links the platform device-audio backend (CoreAudio on Apple, oboe on
/// Android) — the cross-compile proof that the device-audio path builds for each
/// target before the full capture/playback pipeline is wired in.
pub fn default_audio_devices() -> (Option<String>, Option<String>) {
    use cpal::traits::{DeviceTrait, HostTrait};
    let host = cpal::default_host();
    let input = host.default_input_device().and_then(|d| d.name().ok());
    let output = host.default_output_device().and_then(|d| d.name().ok());
    (input, output)
}

/// A configured opus encoder for call audio (Voip, 48 kHz).
pub fn opus_encoder(channels: Channels) -> anyhow::Result<Encoder> {
    Ok(Encoder::new(SAMPLE_RATE, channels, Application::Voip)?)
}

/// A configured opus decoder matching [`opus_encoder`].
pub fn opus_decoder(channels: Channels) -> anyhow::Result<Decoder> {
    Ok(Decoder::new(SAMPLE_RATE, channels)?)
}

/// Run a call's audio FULL-DUPLEX over `session` until [`mic`] closes (hang up)
/// or the connection drops: opus-encode each 20 ms interleaved-PCM frame from
/// `mic` onto the iroh-roq send-flow, and opus-decode received RTP into
/// `speaker`. On device, cpal capture feeds `mic` and cpal playback drains
/// `speaker`; the FFI/host owns those channels. Both peers run this on their own
/// end of the same connection (same flow id, opposite directions).
pub async fn run_audio_session(
    session: Session,
    channels: Channels,
    mut mic: mpsc::Receiver<Vec<i16>>,
    speaker: mpsc::Sender<Vec<i16>>,
) -> anyhow::Result<()> {
    let flow = VarInt::from_u32(AUDIO_FLOW_ID);
    let send_flow = session.new_send_flow(flow).await?;
    let mut recv_flow = session.new_receive_flow(flow).await?;
    let ch = channels_count(channels);

    // Receive: decode incoming RTP → PCM → speaker. Ends when the flow closes.
    let recv = tokio::spawn(async move {
        let mut dec = opus_decoder(channels)?;
        loop {
            let packet = match recv_flow.read_rtp().await {
                Ok(p) => p,
                Err(_) => break, // connection closed
            };
            let mut out = vec![0i16; FRAME_PER_CHANNEL * ch];
            match dec.decode(&packet.payload, &mut out, false) {
                Ok(n) => {
                    out.truncate(n * ch);
                    match speaker.try_send(out) {
                        Ok(()) => {}
                        Err(TrySendError::Full(_)) => continue, // stale audio is worse than dropped audio
                        Err(TrySendError::Closed(_)) => break,  // host stopped draining
                    }
                }
                Err(_) => continue, // skip a bad packet
            }
        }
        anyhow::Ok(())
    });

    // Send: encode mic PCM → RTP → send-flow. Ends when the host drops `mic`.
    let mut enc = opus_encoder(channels)?;
    let mut seq: u16 = 0;
    let mut timestamp: u32 = 0;
    let mut buf = vec![0u8; 1500];
    let send_result = async {
        while let Some(pcm) = mic.recv().await {
            let n = enc.encode(&pcm, &mut buf)?;
            let packet = rtp::packet::Packet {
                header: rtp::header::Header {
                    sequence_number: seq,
                    timestamp,
                    marker: seq == 0,
                    ..Default::default()
                },
                payload: bytes::Bytes::copy_from_slice(&buf[..n]),
            };
            seq = seq.wrapping_add(1);
            timestamp = timestamp.wrapping_add(FRAME_PER_CHANNEL as u32);
            if send_flow.send_rtp(&packet).is_err() {
                break; // connection closed
            }
        }
        anyhow::Ok::<()>(())
    }
    .await;

    recv.abort();
    send_result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::call::transport::{rtc_session, CallTransport};
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

    /// M3a full-duplex: both nodes run [`run_audio_session`], both speak (feed N
    /// synthetic frames into their mic channel), and both hear (receive N frames
    /// on their speaker channel) — the bidirectional audio path of a real call.
    #[tokio::test]
    async fn full_duplex_audio_session() -> anyhow::Result<()> {
        tokio::time::timeout(Duration::from_secs(30), async {
            let a = CallTransport::bind_relay_less([3u8; 32]).await?;
            let b = CallTransport::bind_relay_less([4u8; 32]).await?;
            let a_addr = a.endpoint_addr();
            let (conn_b, conn_a) = tokio::join!(b.connect(a_addr), a.accept());
            let (conn_a, conn_b) = (conn_a?, conn_b?);

            let (mic_a_tx, mic_a_rx) = mpsc::channel::<Vec<i16>>(16);
            let (spk_a_tx, mut spk_a_rx) = mpsc::channel::<Vec<i16>>(16);
            let (mic_b_tx, mic_b_rx) = mpsc::channel::<Vec<i16>>(16);
            let (spk_b_tx, mut spk_b_rx) = mpsc::channel::<Vec<i16>>(16);

            let ha = tokio::spawn(run_audio_session(
                rtc_session(conn_a),
                Channels::Stereo,
                mic_a_rx,
                spk_a_tx,
            ));
            let hb = tokio::spawn(run_audio_session(
                rtc_session(conn_b),
                Channels::Stereo,
                mic_b_rx,
                spk_b_tx,
            ));

            // Let both receive-flows establish before sending (RTP rides
            // best-effort datagrams; early packets would otherwise drop).
            tokio::time::sleep(Duration::from_millis(400)).await;

            let n = 5;
            // A tone, not a constant: opus is a speech codec and encodes a flat
            // DC signal to ~silence, so the decoded frame would be all zeros.
            let frame: Vec<i16> = (0..FRAME_PER_CHANNEL * 2)
                .map(|i| ((i as f32 * 0.05).sin() * 8000.0) as i16)
                .collect();
            for _ in 0..n {
                mic_a_tx.send(frame.clone()).await?;
                mic_b_tx.send(frame.clone()).await?;
            }

            // Each side hears N non-silent frames.
            for _ in 0..n {
                let ra = tokio::time::timeout(Duration::from_secs(5), spk_b_rx.recv())
                    .await?
                    .expect("A→B frame");
                assert!(ra.iter().any(|s| *s != 0));
                let rb = tokio::time::timeout(Duration::from_secs(5), spk_a_rx.recv())
                    .await?
                    .expect("B→A frame");
                assert!(rb.iter().any(|s| *s != 0));
            }

            // Hang up: dropping the mic senders ends the send loops.
            drop(mic_a_tx);
            drop(mic_b_tx);
            a.close().await;
            b.close().await;
            let _ = ha.await;
            let _ = hb.await;
            anyhow::Ok(())
        })
        .await
        .map_err(|_| anyhow::anyhow!("duplex test timed out"))??;
        Ok(())
    }
}

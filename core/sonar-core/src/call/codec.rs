//! Opus audio codec for calls.
//!
//! 48 kHz / 20 ms frames, `Application::Voip` — the parameters callme uses and
//! the de-facto RTP-opus defaults (so no SDP negotiation: a fixed payload type
//! identifies opus). Built on the pure-Rust `unsafe-libopus` backend so it
//! cross-compiles to iOS/Android with no C/libopus toolchain. The media pipeline
//! (capture → encode → iroh-roq send-flow; recv-flow → decode → playback) layers
//! on top of this; here we keep the codec parameters + a round-trip proof.

/// Opus engine sample rate (Hz).
pub const SAMPLE_RATE: u32 = 48_000;

/// Samples per channel in one 20 ms frame at [`SAMPLE_RATE`].
pub const FRAME_SAMPLES: usize = (SAMPLE_RATE as usize / 1000) * 20; // 960

#[cfg(test)]
mod tests {
    use super::*;

    /// Proves the opus codec integrates + cross-compiles: encode one 20 ms mono
    /// frame and decode it back to a same-length, non-silent frame. This is the
    /// audio half of the media smoke test (the other half — moving the packets
    /// over iroh-roq — runs on the proven `CallTransport` connection).
    #[test]
    fn opus_encode_decode_roundtrip() {
        let mut enc =
            opus::Encoder::new(SAMPLE_RATE, opus::Channels::Mono, opus::Application::Voip).unwrap();
        let mut dec = opus::Decoder::new(SAMPLE_RATE, opus::Channels::Mono).unwrap();

        // A ~440 Hz tone, one 20 ms frame.
        let frame: Vec<f32> = (0..FRAME_SAMPLES)
            .map(|i| {
                (i as f32 * 2.0 * std::f32::consts::PI * 440.0 / SAMPLE_RATE as f32).sin() * 0.3
            })
            .collect();

        let mut packet = vec![0u8; 4000];
        let n = enc.encode_float(&frame, &mut packet).unwrap();
        assert!(n > 0, "opus produced a packet");
        assert!(n < frame.len() * 4, "opus compressed the frame");

        let mut out = vec![0f32; FRAME_SAMPLES];
        let decoded = dec.decode_float(&packet[..n], &mut out, false).unwrap();
        assert_eq!(decoded, FRAME_SAMPLES, "decodes back to one 20 ms frame");
        assert!(
            out.iter().any(|s| s.abs() > 0.001),
            "decoded audio is non-silent"
        );
    }
}

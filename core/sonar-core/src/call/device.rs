//! cpal mic capture + speaker playback feeding [`super::media::run_audio_session`].
//!
//! Each call uses a mono 48 kHz path: capture downmixes the mic to mono 20 ms
//! frames onto a channel; playback upmixes mono frames back to the device's
//! channel count. cpal's `Stream` is `!Send`, so each stream is built + kept on
//! its own dedicated thread (the [`AudioDevice`] handle stops + drops it); the
//! audio callbacks bridge to the async side with tokio mpsc `try_send`/`try_recv`
//! (both callable from the cpal thread). Resampling for non-48 kHz devices is a
//! TODO — phones provide 48 kHz.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, SampleRate, StreamConfig};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;

use crate::call::codec::SAMPLE_RATE;

/// Mono samples in a 20 ms frame at [`SAMPLE_RATE`].
const FRAME_SAMPLES: usize = (SAMPLE_RATE as usize / 1000) * 20; // 960
/// Keep at most this many decoded frames queued locally. Beyond this, play the
/// freshest audio and drop old samples so a call does not drift seconds behind.
const PLAYBACK_BUFFER_FRAMES: usize = 6; // ~120 ms

/// A running cpal stream on its own thread. Drop to stop capture/playback.
pub struct AudioDevice {
    stop: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl Drop for AudioDevice {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}

/// The device's default config, but at 48 kHz (the call engine format). Returns
/// `(config, sample_format, channel_count)`.
fn config_48k(device: &cpal::Device, input: bool) -> Result<(StreamConfig, SampleFormat, usize)> {
    let def = if input {
        device.default_input_config()?
    } else {
        device.default_output_config()?
    };
    let fmt = def.sample_format();
    let ch = def.channels() as usize;
    let mut cfg: StreamConfig = def.config();
    cfg.sample_rate = SampleRate(SAMPLE_RATE);
    Ok((cfg, fmt, ch))
}

/// Build a cpal stream inside a dedicated thread (cpal `Stream` is `!Send`) and
/// keep it alive there until the returned [`AudioDevice`] is dropped.
fn spawn_stream<F>(input: bool, build: F) -> Result<AudioDevice>
where
    F: FnOnce(&cpal::Device) -> Result<cpal::Stream> + Send + 'static,
{
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<()>>();
    let join = std::thread::spawn(move || {
        let host = cpal::default_host();
        let device = match if input {
            host.default_input_device()
        } else {
            host.default_output_device()
        }
        .context(if input {
            "no input audio device"
        } else {
            "no output audio device"
        }) {
            Ok(d) => d,
            Err(e) => {
                let _ = ready_tx.send(Err(e));
                return;
            }
        };
        let stream = match build(&device) {
            Ok(s) => s,
            Err(e) => {
                let _ = ready_tx.send(Err(e));
                return;
            }
        };
        if let Err(e) = stream.play() {
            let _ = ready_tx.send(Err(e.into()));
            return;
        }
        let _ = ready_tx.send(Ok(()));
        // Keep the stream alive on this thread until asked to stop.
        while !stop_thread.load(Ordering::SeqCst) {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        drop(stream);
    });
    match ready_rx.recv() {
        Ok(Ok(())) => Ok(AudioDevice {
            stop,
            join: Some(join),
        }),
        Ok(Err(e)) => {
            let _ = join.join();
            Err(e)
        }
        Err(_) => Err(anyhow::anyhow!("audio thread exited before becoming ready")),
    }
}

/// Capture the mic as mono 48 kHz / 20 ms i16 frames, sent to `mic_tx`. Feed
/// `mic_tx`'s receiver to `run_audio_session`.
pub fn start_capture(mic_tx: mpsc::Sender<Vec<i16>>) -> Result<AudioDevice> {
    start_capture_with_mute(mic_tx, Arc::new(AtomicBool::new(false)))
}

/// Capture the mic like [`start_capture`], replacing outgoing frames with
/// silence while `muted` is true. Keeping the frame cadence avoids renegotiating
/// or starving the RTP sender when the user toggles mute.
pub fn start_capture_with_mute(
    mic_tx: mpsc::Sender<Vec<i16>>,
    muted: Arc<AtomicBool>,
) -> Result<AudioDevice> {
    spawn_stream(true, move |device| {
        let (cfg, fmt, ch) = config_48k(device, true)?;
        let mut acc: Vec<i16> = Vec::with_capacity(FRAME_SAMPLES);
        let on_err = |e| tracing::warn!("capture stream error: {e}");

        macro_rules! input_stream {
            ($t:ty, $to_i16:expr) => {{
                let mic = mic_tx.clone();
                device.build_input_stream(
                    &cfg,
                    move |data: &[$t], _: &_| {
                        // Downmix interleaved frames to a single mono channel.
                        for frame in data.chunks(ch) {
                            let sum: i32 = frame.iter().map(|&s| $to_i16(s) as i32).sum();
                            acc.push((sum / ch as i32) as i16);
                            if acc.len() >= FRAME_SAMPLES {
                                let mut frame =
                                    std::mem::replace(&mut acc, Vec::with_capacity(FRAME_SAMPLES));
                                if muted.load(Ordering::Relaxed) {
                                    frame.fill(0);
                                }
                                let _ = mic.try_send(frame);
                            }
                        }
                    },
                    on_err,
                    None,
                )
            }};
        }
        let stream = match fmt {
            SampleFormat::F32 => input_stream!(f32, |s: f32| (s.clamp(-1.0, 1.0) * 32767.0) as i16),
            SampleFormat::I16 => input_stream!(i16, |s: i16| s),
            other => anyhow::bail!("unsupported input sample format {other:?}"),
        }?;
        Ok(stream)
    })
}

/// Play mono 48 kHz / 20 ms i16 frames from `speaker_rx` (the receiver
/// `run_audio_session` sends decoded audio to) on the speaker.
pub fn start_playback(speaker_rx: mpsc::Receiver<Vec<i16>>) -> Result<AudioDevice> {
    spawn_stream(false, move |device| {
        let (cfg, fmt, ch) = config_48k(device, false)?;
        let max_buffer_samples = FRAME_SAMPLES * PLAYBACK_BUFFER_FRAMES;
        let mut buf: VecDeque<i16> = VecDeque::with_capacity(max_buffer_samples);
        let mut rx = speaker_rx;
        let on_err = |e| tracing::warn!("playback stream error: {e}");

        macro_rules! output_stream {
            ($t:ty, $from_i16:expr) => {
                device.build_output_stream(
                    &cfg,
                    move |out: &mut [$t], _: &_| {
                        // Pull decoded mono frames (non-blocking) until we have enough.
                        while buf.len() < out.len() / ch {
                            match rx.try_recv() {
                                Ok(frame) => {
                                    let overflow = buf
                                        .len()
                                        .saturating_add(frame.len())
                                        .saturating_sub(max_buffer_samples);
                                    for _ in 0..overflow {
                                        let _ = buf.pop_front();
                                    }
                                    buf.extend(frame);
                                }
                                Err(_) => break, // none ready → underrun (filled with 0 below)
                            }
                        }
                        for dst in out.chunks_mut(ch) {
                            let s = buf.pop_front().unwrap_or(0);
                            let v = $from_i16(s);
                            for d in dst.iter_mut() {
                                *d = v; // upmix mono → all device channels
                            }
                        }
                    },
                    on_err,
                    None,
                )
            };
        }
        let stream = match fmt {
            SampleFormat::F32 => output_stream!(f32, |s: i16| s as f32 / 32767.0),
            SampleFormat::I16 => output_stream!(i16, |s: i16| s),
            other => anyhow::bail!("unsupported output sample format {other:?}"),
        }?;
        Ok(stream)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Opens the real mic and asserts it produces 20 ms frames. IGNORED: needs a
    /// physical input device (CI runners have none); run locally with
    /// `--ignored` on a machine with a mic.
    #[tokio::test]
    #[ignore = "needs a real microphone"]
    async fn capture_produces_frames() {
        let (tx, mut rx) = mpsc::channel::<Vec<i16>>(32);
        let _dev = start_capture(tx).expect("open mic");
        let frame = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
            .await
            .expect("a frame within 2s")
            .expect("frame");
        assert_eq!(frame.len(), FRAME_SAMPLES);
    }
}

//! `sonar-cli call` — a headless two-terminal harness for debugging the real
//! P2P call transport (iroh QUIC + cpal/opus) without the mobile apps.
//!
//! It drives the same [`sonar_core::call::engine::CallEngine`] the apps use, but
//! exchanges the iroh dial addresses **by hand** (copy/paste between two
//! terminals) instead of over the `☎CALL` Marmot/NIP-17 signaling. Admission is
//! by iroh endpoint id (QUIC-authenticated pinning), so a manual address swap
//! connects exactly like the in-app path — letting you reproduce
//! "rings, never connects" between two real machines/networks, with the full
//! `tracing` log stream (set `RUST_LOG=info,iroh=debug,sonar_core=debug`).
//!
//! Usage (two terminals, optionally on two machines):
//! ```text
//!   A$ sonar-cli call                      # offerer: prints its address, waits
//!   B$ sonar-cli call --offer <A-ADDRESS>  # answerer: prints its address, waits
//!   # 1) paste B's printed address into A's prompt, press enter
//!   # 2) press enter in B to dial
//! ```
//! Each side prints its own dialable address to **stdout** (so it is easy to
//! capture); all prompts and the live call-state log go to **stderr**.

use std::io::{self, BufRead, Write};

use sonar_core::call::engine::{CallEngine, CallStateKind};
use sonar_core::call::signaling::{AnswerKind, CallMediaKind};

use crate::{CliError, Result};

/// Parsed `call` subcommand options.
pub struct CallOpts {
    /// Offerer's dialable address (base64). Absent ⇒ this process is the offerer.
    pub offer: Option<String>,
    /// Request a video call (audio path is identical; this only sets the kind).
    pub video: bool,
    /// Shared call id. Both sides default to the same constant so a manual pair
    /// just works; override only when running several pairs at once.
    pub call_id: String,
    /// 32-byte iroh secret as 64 hex chars. Omit for a random per-run identity.
    pub seed: Option<String>,
    /// Seconds to wait for the call to connect before giving up (offerer side
    /// waits for the inbound dial; answerer's `accept` dials synchronously).
    pub connect_timeout_secs: u64,
}

pub async fn run_call(opts: CallOpts) -> Result<()> {
    let secret = resolve_secret(opts.seed.as_deref())?;
    let media = if opts.video {
        CallMediaKind::Video
    } else {
        CallMediaKind::Voice
    };

    // Bind the iroh endpoint (relays enabled, like the apps) + start the accept
    // loop. This is the call to watch in the logs: a bind failure here is exactly
    // the "can't even start" class; a successful bind that never connects is the
    // "rings, never connects" class.
    let engine = CallEngine::start(secret)
        .await
        .map_err(|e| CliError::Message(format!("bind call endpoint: {e}")))?;
    let local = engine
        .local_addr_b64()
        .map_err(|e| CliError::Message(format!("local address: {e}")))?;

    match opts.offer.as_deref() {
        // -------- OFFERER ----------------------------------------------------
        None => {
            eprintln!("\n=== OFFERER ({})  ===", media_label(media));
            eprintln!("Run this on the other side:\n    sonar-cli call --offer {local}\n");
            eprintln!("Your dialable address (stdout):");
            println!("{local}");
            engine
                .place(&opts.call_id, media)
                .map_err(|e| CliError::Message(format!("place: {e}")))?;
            let answerer = prompt_line("\nPaste the ANSWERER address, then press enter:\n> ").await?;
            let answerer = answerer.trim();
            if answerer.is_empty() {
                return Err(CliError::Message("no answerer address provided".into()));
            }
            engine
                .on_answer(&opts.call_id, AnswerKind::Accept, answerer)
                .map_err(|e| CliError::Message(format!("on_answer: {e}")))?;
            eprintln!("Pinned answerer. Waiting for the inbound dial…");
        }
        // -------- ANSWERER ---------------------------------------------------
        Some(offer_addr) => {
            eprintln!("\n=== ANSWERER ({})  ===", media_label(media));
            eprintln!("Your dialable address (paste into the offerer's prompt, stdout):");
            println!("{local}");
            engine
                .on_incoming_offer(&opts.call_id, offer_addr.trim(), media)
                .map_err(|e| CliError::Message(format!("on_incoming_offer: {e}")))?;
            // Gate the dial on a keypress so the offerer has time to paste/pin our
            // address first — otherwise our dial can land before the offerer pins
            // us and gets dropped as an "unpinned peer".
            let _ = prompt_line(
                "\nPress enter to DIAL the offerer (after it has accepted your address)…\n> ",
            )
            .await?;
            eprintln!("Dialing offerer…");
            engine
                .accept(&opts.call_id)
                .await
                .map_err(|e| CliError::Message(format!("accept/dial: {e}")))?;
        }
    }

    drive_events(&engine, opts.connect_timeout_secs).await;
    Ok(())
}

/// Print every call-state transition until the call ends. A `None` (timeout)
/// means no progress — the surrounding `tracing` logs explain why.
async fn drive_events(engine: &CallEngine, timeout_secs: u64) {
    eprintln!("Watching call state (Ctrl-C to quit)…\n");
    loop {
        match engine.next_event(timeout_secs).await {
            Some(ev) => {
                eprintln!(
                    "[call] state={:?} duration={}s {}",
                    ev.state,
                    ev.duration_secs,
                    if ev.reason.is_empty() {
                        String::new()
                    } else {
                        format!("reason={}", ev.reason)
                    }
                );
                match ev.state {
                    CallStateKind::Connected => eprintln!(
                        "[call] CONNECTED — media is flowing (mic/speaker if a device is present). Ctrl-C to hang up."
                    ),
                    CallStateKind::Ended
                    | CallStateKind::Failed
                    | CallStateKind::Declined
                    | CallStateKind::Busy
                    | CallStateKind::Missed => break,
                    _ => {}
                }
            }
            None => eprintln!(
                "[call] no state change in {timeout_secs}s — still trying. Check the iroh logs above (set RUST_LOG=iroh=debug for more)."
            ),
        }
    }
}

fn media_label(kind: CallMediaKind) -> &'static str {
    match kind {
        CallMediaKind::Voice => "voice",
        CallMediaKind::Video => "video",
    }
}

fn resolve_secret(seed: Option<&str>) -> Result<[u8; 32]> {
    match seed {
        Some(hex) => {
            let bytes = hex::decode(hex.trim())?;
            bytes
                .as_slice()
                .try_into()
                .map_err(|_| CliError::Message("--seed must be 32 bytes (64 hex chars)".into()))
        }
        None => {
            let mut buf = [0u8; 32];
            getrandom::getrandom(&mut buf)
                .map_err(|e| CliError::Message(format!("getrandom: {e}")))?;
            Ok(buf)
        }
    }
}

/// Print `prompt` to stderr and read one line from stdin off the async runtime.
async fn prompt_line(prompt: &str) -> Result<String> {
    eprint!("{prompt}");
    io::stderr().flush().ok();
    tokio::task::spawn_blocking(|| {
        let mut line = String::new();
        io::stdin().lock().read_line(&mut line).map(|_| line)
    })
    .await
    .map_err(|e| CliError::Message(format!("stdin task: {e}")))?
    .map_err(CliError::from)
}

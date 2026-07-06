//! On-device file sink for `tracing` — the Rust-core half of the diagnostics
//! log export feature (Settings → Diagnostics → "Share debug bundle").
//!
//! Design:
//! - A size-bounded rotating `sonar-core.log` family under the host-provided
//!   directory (`MAX_FILE_BYTES` per file, `MAX_ROTATIONS` kept), so disk use
//!   stays bounded regardless of log rate — matching the platform sinks.
//! - Writes go through `tracing_appender::non_blocking`, so relay/sync hot
//!   paths never block on disk I/O (lines are dropped under backpressure
//!   rather than stalling the caller).
//! - The level filter is the privacy boundary: the default profile stays at
//!   `info` for `sonar_core`, where no message content or key material is
//!   ever logged. `verbose = true` (explicit user opt-in from the
//!   Diagnostics screen) raises `sonar_core` to `debug`, which includes
//!   peer npubs — still never content or secret keys.
//! - Unlike the platform file sinks (iOS `LogFileSink`, Android/JVM
//!   `SonarFileLog`), this sink does NOT run a secondary `nsec` scrub. Those
//!   sinks tee *arbitrary* app logging and scrub as a backstop; the core is a
//!   controlled codebase where the account key never enters a `tracing` call,
//!   so a scrub here would be unexercisable dead code. The level filter is the
//!   sole, sufficient boundary.
//! - Idempotent: the first successful call installs the global subscriber;
//!   later calls only swap the level filter via a `reload` handle, so hosts
//!   can toggle verbose at runtime without restarting.
//! - A platform console layer tees the SAME events to the OS log alongside the
//!   file so they can be watched live during a repro: os_log (subsystem
//!   `chat.bitchat`, category `core`) on Apple — visible in Console.app /
//!   `idevicesyslog`; logcat (tag `SonarCore`) on Android — visible via
//!   `adb logcat`; stderr on desktop. All console output respects the same
//!   verbose filter as the file, so it never carries content or key material
//!   at the default level.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Mutex;

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::reload;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer, Registry};

/// Per-file byte cap before rotation — matches the iOS/Android sinks so total
/// disk use stays bounded regardless of log rate.
const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;
/// Rotations kept beside the live file (`sonar-core.log.1`, `.2`).
const MAX_ROTATIONS: usize = 2;

/// Size-bounded rotating file writer for `sonar-core.log`. `tracing-appender`
/// only rotates by time (daily/hourly), which leaves a single busy or verbose
/// day uncapped; this rolls `sonar-core.log` → `.1` → `.2` once it passes
/// [`MAX_FILE_BYTES`], the same way the platform sinks do. It is fed by the
/// `non_blocking` writer's single background thread, so no interior locking is
/// needed.
struct SizeRotatingFile {
    dir: PathBuf,
    file: File,
    written: u64,
}

impl SizeRotatingFile {
    fn open(dir: &str) -> Result<Self, String> {
        let dir = PathBuf::from(dir);
        fs::create_dir_all(&dir).map_err(|e| format!("create log dir {dir:?}: {e}"))?;
        let base = dir.join("sonar-core.log");
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&base)
            .map_err(|e| format!("open log file {base:?}: {e}"))?;
        let written = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(Self { dir, file, written })
    }

    fn rotated_path(&self, n: usize) -> PathBuf {
        self.dir.join(format!("sonar-core.log.{n}"))
    }

    fn rotate(&mut self) -> io::Result<()> {
        // Shift .(n-1) → .n (oldest dropped), base → .1, then truncate base.
        for n in (1..=MAX_ROTATIONS).rev() {
            let src = if n == 1 {
                self.dir.join("sonar-core.log")
            } else {
                self.rotated_path(n - 1)
            };
            let dst = self.rotated_path(n);
            let _ = fs::remove_file(&dst);
            if src.exists() {
                let _ = fs::rename(&src, &dst);
            }
        }
        self.file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(self.dir.join("sonar-core.log"))?;
        self.written = 0;
        Ok(())
    }
}

impl Write for SizeRotatingFile {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.written >= MAX_FILE_BYTES {
            // On rotation failure keep writing to the current file rather than
            // dropping the line — bounded-ish beats lost diagnostics.
            let _ = self.rotate();
        }
        let n = self.file.write(buf)?;
        self.written += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

struct LogSink {
    /// Flushes the non-blocking writer on process exit; must live as long as
    /// the subscriber, so it is parked here for the process lifetime.
    _guard: WorkerGuard,
    filter: reload::Handle<EnvFilter, Registry>,
}

/// Global sink lifecycle.
enum LogState {
    /// No install attempted yet — a `bad directory` failure stays here so a
    /// later call with a good directory can retry.
    Uninit,
    /// Installed; later calls only reload the level filter.
    Active(LogSink),
    /// `try_init` failed because some OTHER global subscriber is already
    /// installed. Retrying can never succeed (the global dispatcher is set for
    /// the process), so stop attempting and treat further calls as no-ops —
    /// the app must keep working even without the file sink.
    Unavailable,
}

static LOG_SINK: Mutex<LogState> = Mutex::new(LogState::Uninit);

fn filter_for(verbose: bool) -> EnvFilter {
    // Default is the redaction boundary: `sonar_core` debug logs are where
    // peer npubs appear, so they are excluded unless the user opts in.
    let directives = if verbose {
        "info,sonar_core=debug,sonar_ffi=debug"
    } else {
        "warn,sonar_core=info,sonar_ffi=info"
    };
    EnvFilter::new(directives)
}

/// Install the rotating file sink under `dir`, or — if already installed —
/// just switch the level filter to match `verbose`.
pub(crate) fn install_file_logging(dir: &str, verbose: bool) -> Result<(), String> {
    let mut state = LOG_SINK
        .lock()
        .map_err(|_| "log sink lock poisoned".to_string())?;

    match &*state {
        // Already installed: a repeat call (e.g. the verbose toggle) only swaps
        // the level filter.
        LogState::Active(sink) => {
            return sink
                .filter
                .reload(filter_for(verbose))
                .map_err(|e| format!("reload log filter: {e}"));
        }
        // A prior attempt hit an already-set global dispatcher; further attempts
        // can never win it, so no-op instead of erroring on every connect.
        LogState::Unavailable => return Ok(()),
        LogState::Uninit => {}
    }

    let appender = SizeRotatingFile::open(dir)?;
    let (writer, guard) = tracing_appender::non_blocking(appender);

    let (filter_layer, filter_handle) = reload::Layer::new(filter_for(verbose));
    let fmt_layer = tracing_subscriber::fmt::layer()
        .with_writer(writer)
        .with_ansi(false)
        .with_target(true);

    // The global `filter_layer` gates every layer below it (file + console),
    // so the verbose toggle applies uniformly.
    if let Err(e) = tracing_subscriber::registry()
        .with(filter_layer)
        .with(fmt_layer)
        .with(console_layer())
        .try_init()
    {
        // Another subscriber owns the global dispatcher. This is terminal for
        // the process; record it so we stop retrying (and the WorkerGuard is
        // dropped here, flushing nothing).
        *state = LogState::Unavailable;
        return Err(format!("install tracing subscriber: {e}"));
    }

    *state = LogState::Active(LogSink {
        _guard: guard,
        filter: filter_handle,
    });
    Ok(())
}

/// Platform console layer teeing events to the OS log for live monitoring.
/// Apple → os_log; Android → logcat; everything else → stderr. Generic over
/// the subscriber `S` so it composes onto the file-layer stack.
#[cfg(target_vendor = "apple")]
fn console_layer<S>() -> impl Layer<S>
where
    S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    tracing_oslog::OsLogger::new("chat.bitchat", "core")
}

#[cfg(target_os = "android")]
fn console_layer<S>() -> impl Layer<S>
where
    S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    tracing_subscriber::fmt::layer()
        .with_writer(android_logcat::MakeLogcat)
        .with_ansi(false)
        .with_target(true)
}

#[cfg(not(any(target_vendor = "apple", target_os = "android")))]
fn console_layer<S>() -> impl Layer<S>
where
    S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    tracing_subscriber::fmt::layer()
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .with_target(true)
}

/// Minimal `MakeWriter` routing formatted lines to Android logcat via liblog
/// (tag `SonarCore`), so the core trace shows up in `adb logcat` alongside the
/// file. liblog is always linked on Android.
#[cfg(target_os = "android")]
mod android_logcat {
    use std::ffi::CString;
    use std::io::{self, Write};
    use std::os::raw::{c_char, c_int};

    // ANDROID_LOG_INFO from <android/log.h>.
    const ANDROID_LOG_INFO: c_int = 4;

    extern "C" {
        fn __android_log_write(prio: c_int, tag: *const c_char, text: *const c_char) -> c_int;
    }

    pub struct LogcatWriter;

    impl Write for LogcatWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            if let Ok(text) = std::str::from_utf8(buf) {
                let trimmed = text.trim_end();
                if !trimmed.is_empty() {
                    if let (Ok(tag), Ok(msg)) = (CString::new("SonarCore"), CString::new(trimmed)) {
                        // Safety: liblog is linked on Android; both pointers are
                        // valid, NUL-terminated C strings for the call duration.
                        unsafe {
                            __android_log_write(ANDROID_LOG_INFO, tag.as_ptr(), msg.as_ptr())
                        };
                    }
                }
            }
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[derive(Clone)]
    pub struct MakeLogcat;

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for MakeLogcat {
        type Writer = LogcatWriter;
        fn make_writer(&'a self) -> Self::Writer {
            LogcatWriter
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_is_idempotent_and_toggles_verbose() {
        let dir = tempfile::tempdir().expect("tempdir");
        let dir_str = dir.path().to_str().expect("utf8 tempdir");

        install_file_logging(dir_str, false).expect("first install");
        // Second call must not try to re-init the global subscriber; it only
        // reloads the filter.
        install_file_logging(dir_str, true).expect("verbose reload");
        install_file_logging(dir_str, false).expect("quiet reload");

        tracing::info!("diagnostics smoke line");
        // A current-day log file exists under the directory.
        let has_log = std::fs::read_dir(dir.path())
            .expect("read log dir")
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().starts_with("sonar-core"));
        assert!(has_log, "expected a sonar-core.*.log file");
    }

    #[test]
    fn bad_directory_is_an_error_not_a_panic() {
        // A path under a file (not a dir) cannot be created. Tests the writer
        // opener directly — the global-sink path is exercised by
        // `install_is_idempotent_and_toggles_verbose` and test order within
        // one process must not matter.
        let file = tempfile::NamedTempFile::new().expect("tempfile");
        let bad = format!("{}/nested", file.path().display());
        assert!(SizeRotatingFile::open(&bad).is_err());
    }

    #[test]
    fn size_rotating_file_rolls_and_bounds_files() {
        let dir = tempfile::tempdir().expect("tempdir");
        let dir_str = dir.path().to_str().expect("utf8 tempdir");
        let mut w = SizeRotatingFile::open(dir_str).expect("open");
        // Force several rotations by writing well past MAX_FILE_BYTES.
        let chunk = vec![b'x'; 256 * 1024];
        for _ in 0..(MAX_FILE_BYTES / chunk.len() as u64 * 4 + 8) {
            w.write_all(&chunk).expect("write");
        }
        w.flush().expect("flush");
        // Never keeps more than base + MAX_ROTATIONS files.
        let count = std::fs::read_dir(dir.path())
            .expect("read dir")
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("sonar-core.log")
            })
            .count();
        assert!(
            count <= 1 + MAX_ROTATIONS,
            "expected <= {} files, got {count}",
            1 + MAX_ROTATIONS
        );
    }
}

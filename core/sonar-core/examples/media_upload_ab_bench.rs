//! A/B microbench: baseline vs improved Blossom upload orchestration.
//!
//! Measures the plan in `speed_up_media_upload` without needing to revert
//! production code. Both strategies encrypt with a real MLS group key and PUT
//! to an in-process mock Blossom that injects per-request latency (stand-in for
//! RTT + server work). Baseline also pays a synthetic "new TLS client" cost.
//!
//! ```text
//! cargo run -p sonar-core --example media_upload_ab_bench --release
//! ```
//!
//! Env knobs:
//! - `SONAR_UPLOAD_BENCH_LATENCY_MS` — mock Blossom per-PUT delay (default 40)
//! - `SONAR_UPLOAD_BENCH_CONNECT_MS` — baseline new-client cost (default 15)
//! - `SONAR_UPLOAD_BENCH_ITERS` — measured iterations per scenario (default 5)

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use futures_util::stream::{self, StreamExt};
use mdk_core::encrypted_media::EncryptedMediaUpload;
use mdk_storage_traits::GroupId;
use nostr::Url;
use nostr_blossom::prelude::*;
use nostr_relay_builder::MockRelay;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

static IMPROVED_HTTP: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("improved upload client")
});

#[derive(Clone, Copy, Debug)]
enum Strategy {
    /// Pre-plan behavior: encrypt-all barrier, concurrency 3, new BlossomClient
    /// (+ synthetic connect cost) per PUT.
    Baseline,
    /// Plan behavior: pipelined encrypt→upload, concurrency 5, shared HTTP client.
    Improved,
}

impl Strategy {
    fn label(self) -> &'static str {
        match self {
            Self::Baseline => "baseline",
            Self::Improved => "improved",
        }
    }

    fn concurrency(self) -> usize {
        match self {
            Self::Baseline => 3,
            Self::Improved => 5,
        }
    }
}

#[derive(Clone)]
struct Scenario {
    name: &'static str,
    /// (plaintext bytes, mime, filename) per album item.
    items: Vec<(Vec<u8>, &'static str, String)>,
}

#[tokio::main]
async fn main() {
    let latency_ms: u64 = std::env::var("SONAR_UPLOAD_BENCH_LATENCY_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(40);
    let connect_ms: u64 = std::env::var("SONAR_UPLOAD_BENCH_CONNECT_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(15);
    let iters: usize = std::env::var("SONAR_UPLOAD_BENCH_ITERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(5);

    println!("media_upload_ab_bench");
    println!("  mock_put_latency_ms={latency_ms}");
    println!("  baseline_connect_ms={connect_ms}");
    println!("  iters={iters} (+1 warmup)");
    println!();

    let blossom = spawn_mock_blossom(Duration::from_millis(latency_ms));
    let relay = MockRelay::run().await.expect("mock relay");
    let relay_url = relay.url().await;
    let alice = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url.clone()])
        .await
        .expect("alice");
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url])
        .await
        .expect("bob");
    bob.publish_key_package().await.expect("kp");
    let group = alice
        .start_dm(bob.identity().public_key(), "upload-bench")
        .await
        .expect("dm");

    let scenarios = [
        Scenario {
            name: "single_256KiB",
            items: vec![(vec![0xABu8; 256 * 1024], "application/octet-stream", "a.bin".into())],
        },
        Scenario {
            name: "single_2MiB",
            items: vec![(vec![0xCDu8; 2 * 1024 * 1024], "application/octet-stream", "b.bin".into())],
        },
        Scenario {
            name: "album_5x512KiB",
            items: (0..5)
                .map(|i| {
                    (
                        vec![0x10 + i as u8; 512 * 1024],
                        "application/octet-stream",
                        format!("p{i}.bin"),
                    )
                })
                .collect(),
        },
        Scenario {
            name: "album_8x256KiB",
            items: (0..8)
                .map(|i| {
                    (
                        vec![0x20 + i as u8; 256 * 1024],
                        "application/octet-stream",
                        format!("q{i}.bin"),
                    )
                })
                .collect(),
        },
    ];

    println!(
        "{:<16} {:>10} {:>10} {:>10} {:>8}",
        "scenario", "baseline", "improved", "delta", "speedup"
    );
    println!("{}", "-".repeat(58));

    for scenario in &scenarios {
        let base_ms = measure(
            &alice,
            &group,
            scenario,
            Strategy::Baseline,
            &blossom,
            connect_ms,
            iters,
        )
        .await;
        let imp_ms = measure(
            &alice,
            &group,
            scenario,
            Strategy::Improved,
            &blossom,
            connect_ms,
            iters,
        )
        .await;
        let delta = base_ms - imp_ms;
        let speedup = if imp_ms > 0.0 {
            base_ms / imp_ms
        } else {
            f64::INFINITY
        };
        println!(
            "{:<16} {:>8.0}ms {:>8.0}ms {:>+8.0}ms {:>7.2}x",
            scenario.name, base_ms, imp_ms, delta, speedup
        );
    }

    println!();
    println!("Notes:");
    println!("  - Times are encrypt+PUT only (no staging/outbox/relay).");
    println!("  - Latency is synthetic; use as relative A/B, not wall-clock cellular.");
    println!("  - Production path already matches `improved` in the working tree.");
}

async fn measure(
    client: &SonarClient,
    group: &GroupId,
    scenario: &Scenario,
    strategy: Strategy,
    blossom: &str,
    connect_ms: u64,
    iters: usize,
) -> f64 {
    run_once(client, group, scenario, strategy, blossom, connect_ms)
        .await
        .expect("warmup");
    let mut samples = Vec::with_capacity(iters);
    for _ in 0..iters {
        let t0 = Instant::now();
        run_once(client, group, scenario, strategy, blossom, connect_ms)
            .await
            .unwrap_or_else(|e| panic!("{} {} failed: {e}", strategy.label(), scenario.name));
        samples.push(t0.elapsed().as_secs_f64() * 1000.0);
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    samples[samples.len() / 2]
}

async fn run_once(
    client: &SonarClient,
    group: &GroupId,
    scenario: &Scenario,
    strategy: Strategy,
    blossom: &str,
    connect_ms: u64,
) -> Result<(), String> {
    match strategy {
        Strategy::Baseline => {
            upload_baseline(client, group, &scenario.items, blossom, connect_ms).await
        }
        Strategy::Improved => upload_improved(client, group, &scenario.items, blossom).await,
    }
}

/// Old shape: encrypt every item, then upload with concurrency 3 and a fresh
/// BlossomClient per PUT (plus synthetic connect cost).
async fn upload_baseline(
    client: &SonarClient,
    group: &GroupId,
    items: &[(Vec<u8>, &str, String)],
    blossom: &str,
    connect_ms: u64,
) -> Result<(), String> {
    let mut encrypted: Vec<EncryptedMediaUpload> = Vec::with_capacity(items.len());
    for (data, mime, filename) in items {
        let upload = client
            .engine()
            .encrypt_media(group, data, mime, filename)
            .map_err(|e| e.to_string())?;
        encrypted.push(upload);
    }

    let keys = client.identity().signer();
    let futs = encrypted.into_iter().enumerate().map(|(index, upload)| {
        let blossom = blossom.to_string();
        let keys = keys.clone();
        async move {
            if connect_ms > 0 {
                // Stand-in for BlossomClient::new + per-PUT reqwest rebuild (TLS).
                tokio::time::sleep(Duration::from_millis(connect_ms)).await;
            }
            let base = Url::parse(&blossom).map_err(|e| e.to_string())?;
            let blossom_client = BlossomClient::new(base);
            let _desc = blossom_client
                .upload_blob(
                    upload.encrypted_data,
                    Some("application/octet-stream".into()),
                    None,
                    Some(&keys),
                )
                .await
                .map_err(|e| format!("baseline put[{index}]: {e}"))?;
            Ok::<(), String>(())
        }
    });

    let results = stream::iter(futs)
        .buffer_unordered(Strategy::Baseline.concurrency())
        .collect::<Vec<_>>()
        .await;
    for r in results {
        r?;
    }
    Ok(())
}

/// New shape: per-item encrypt→upload under concurrency 5, shared HTTP client.
async fn upload_improved(
    client: &SonarClient,
    group: &GroupId,
    items: &[(Vec<u8>, &str, String)],
    blossom: &str,
) -> Result<(), String> {
    let keys = client.identity().signer();
    // Borrowing async blocks (no `move`) so workers share `&client` / `&group`.
    let results = stream::iter(0..items.len())
        .map(|index| {
            let (data, mime, filename) = &items[index];
            let item_index = index;
            let keys = keys.clone();
            async move {
                let upload = client
                    .engine()
                    .encrypt_media(group, data, mime, filename)
                    .map_err(|e| e.to_string())?;
                let base = Url::parse(blossom).map_err(|e| e.to_string())?;
                let blossom_client = BlossomClient::with_client(base, IMPROVED_HTTP.clone());
                let _desc = blossom_client
                    .upload_blob(
                        upload.encrypted_data,
                        Some("application/octet-stream".into()),
                        None,
                        Some(&keys),
                    )
                    .await
                    .map_err(|e| format!("improved put[{item_index}]: {e}"))?;
                Ok::<(), String>(())
            }
        })
        .buffer_unordered(Strategy::Improved.concurrency())
        .collect::<Vec<_>>()
        .await;
    for r in results {
        r?;
    }
    Ok(())
}

fn spawn_mock_blossom(put_delay: Duration) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock blossom");
    let port = listener.local_addr().unwrap().port();
    let base = format!("http://127.0.0.1:{port}");
    let base_for_thread = base.clone();
    let store: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::new(Mutex::new(HashMap::new()));
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let store = store.clone();
            let base = base_for_thread.clone();
            std::thread::spawn(move || {
                handle_blossom_conn(&mut stream, &store, &base, put_delay)
            });
        }
    });
    std::thread::sleep(Duration::from_millis(20));
    base
}

fn handle_blossom_conn(
    stream: &mut std::net::TcpStream,
    store: &Arc<Mutex<HashMap<String, Vec<u8>>>>,
    base: &str,
    put_delay: Duration,
) {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 16384];
    let header_end = loop {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => return,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos;
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut request_line = head.lines().next().unwrap_or("").split_whitespace();
    let method = request_line.next().unwrap_or("").to_string();
    let path = request_line.next().unwrap_or("").to_string();
    let content_length: usize = head
        .lines()
        .find_map(|l| {
            let lower = l.to_ascii_lowercase();
            lower
                .strip_prefix("content-length:")
                .map(|v| v.trim().parse::<usize>().unwrap_or(0))
        })
        .unwrap_or(0);
    let body_start = header_end + 4;
    while buf.len() < body_start + content_length {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
    }
    let body = buf[body_start..(body_start + content_length).min(buf.len())].to_vec();

    if method == "PUT" && path.ends_with("/upload") {
        if !put_delay.is_zero() {
            std::thread::sleep(put_delay);
        }
        use sha2::{Digest, Sha256};
        let sha = hex::encode(Sha256::digest(&body));
        store.lock().unwrap().insert(sha.clone(), body.clone());
        let json = format!(
            "{{\"url\":\"{base}/{sha}\",\"sha256\":\"{sha}\",\"size\":{},\"uploaded\":0}}",
            body.len()
        );
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n{json}",
            json.len()
        );
        let _ = stream.write_all(resp.as_bytes());
        let _ = stream.flush();
    } else {
        let _ = stream.write_all(
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
        let _ = stream.flush();
    }
}

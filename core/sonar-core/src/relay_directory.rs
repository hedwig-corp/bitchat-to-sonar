//! Geohash → nearest-relay routing, mirroring bitchat's `GeoRelayDirectory`.
//!
//! bitchat publishes AND subscribes a geohash channel's kind-20000/20001 events
//! on the N relays geographically CLOSEST to that geohash's centre. If Sonar
//! publishes to a different relay set, a bitchat client in the same geohash
//! never receives our messages (and vice-versa). So we must pick the same
//! relays from the same directory.
//!
//! The directory below is an embedded snapshot of `relays/online_relays_gps.csv`
//! at the repo root (the bitchat source of truth). It can go stale; bitchat
//! refreshes it from a remote URL — a future improvement is to fetch + cache the
//! same CSV. For now an in-sync snapshot matches bitchat's local fallback.

use std::sync::OnceLock;

const RELAYS_CSV: &str = include_str!("relays_gps.csv");

struct RelayEntry {
    host: String,
    lat: f64,
    lon: f64,
}

fn entries() -> &'static Vec<RelayEntry> {
    static ENTRIES: OnceLock<Vec<RelayEntry>> = OnceLock::new();
    ENTRIES.get_or_init(|| {
        RELAYS_CSV
            .lines()
            .skip(1) // header: "Relay URL,Latitude,Longitude"
            .filter_map(|line| {
                let mut cols = line.split(',');
                let host = cols.next()?.trim();
                let lat: f64 = cols.next()?.trim().parse().ok()?;
                let lon: f64 = cols.next()?.trim().parse().ok()?;
                if host.is_empty() {
                    return None;
                }
                Some(RelayEntry { host: host.to_string(), lat, lon })
            })
            .collect()
    })
}

/// Great-circle distance in km (haversine), as bitchat uses for relay ranking.
fn haversine_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6371.0;
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2)
        + lat1.to_radians().cos() * lat2.to_radians().cos() * (dlon / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().clamp(-1.0, 1.0).asin()
}

/// The `count` relay URLs (`wss://…`) closest to a geohash's centre — the same
/// set bitchat's `GeoRelayDirectory.closestRelays(toGeohash:)` returns. Empty if
/// the geohash is invalid or the directory is empty.
pub fn closest_relays_for_geohash(geohash: &str, count: usize) -> Vec<String> {
    let Some((lat, lon)) = crate::geohash::decode_center(geohash) else {
        return Vec::new();
    };
    let all = entries();
    let mut scored: Vec<(&RelayEntry, f64)> = all
        .iter()
        .map(|e| (e, haversine_km(lat, lon, e.lat, e.lon)))
        .collect();
    scored.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
    scored
        .into_iter()
        .take(count)
        .map(|(e, _)| format!("wss://{}", e.host))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directory_parses() {
        assert!(entries().len() > 100, "expected a populated relay directory");
    }

    #[test]
    fn closest_relays_are_returned_and_prefixed() {
        // A geohash near Italy (Rome ≈ "sr2yk"): should yield 5 wss:// relays.
        let relays = closest_relays_for_geohash("sr2yk", 5);
        assert_eq!(relays.len(), 5);
        assert!(relays.iter().all(|r| r.starts_with("wss://")));
    }

    #[test]
    fn distant_geohashes_pick_different_nearest_relays() {
        // Italy vs Japan should not produce the identical closest set.
        let italy = closest_relays_for_geohash("sr2", 3);
        let japan = closest_relays_for_geohash("xn76", 3); // ~Tokyo
        assert_ne!(italy, japan);
    }
}

//! Private timezone sharing for encrypted conversations.
//!
//! Each device shares its **current IANA timezone identifier** (e.g.
//! `Europe/Zurich`) with the members of its Marmot DMs/encrypted groups so a
//! contact's live local time can be shown privately — without publishing any
//! location, geohash, or coordinates.
//!
//! The zone travels as a **Marmot app event inside MLS (kind 445)**: kind
//! 30078 (NIP-78 application data) with a `d` tag of `sonar/local-time`.
//! Relays only ever see the same opaque group ciphertext they already store
//! for chat. This makes the payload:
//!
//! - **Private**: only current MLS group members can decrypt it. It never
//!   touches a public kind-0 profile, Sonar descriptor, BLE announce, geohash
//!   channel, or a pairwise NIP-44 gift wrap that would leak a new event kind
//!   onto relays.
//! - **Non-transcript**: the engine classifies it as `Incoming::TimezoneShare`
//!   and queues it for the host, so it can never become a transcript row,
//!   unread count, notification, or chat preview.
//! - **Not a Marmot protocol event**: kinds MDK assigns meaning to are reserved
//!   (MDK v0.10.4 `RESERVED_APP_EVENT_KINDS`: 5, 7, 9, 447–449, 1009,
//!   1200–1202, 1210, 1984, 1985, 4891). The first version used 449, which
//!   MIP-05 now defines as a push-token removal, so White Noise members parsed
//!   every share as one. 30078 is a custom kind MDK passes through, and White
//!   Noise does not render unknown kinds. The `d` tag keeps it apart from
//!   other apps' kind-30078 data, and the `v` envelope field lets newer
//!   clients ignore future payload revisions.
//!
//! Only the *zone identifier* travels on the wire; the current UTC offset is
//! recomputed locally by each host from its own tz database, so DST and offset
//! changes always display correctly without any re-send.

use nostr::{EventBuilder, Kind, PublicKey, Tag, UnsignedEvent};
use serde::{Deserialize, Serialize};

/// Marmot app-event kind carrying a timezone share: NIP-78 application data,
/// namespaced by [`TIMEZONE_SHARE_D_TAG`]. The event is encrypted into a
/// signed kind-445, never published as a public Nostr event.
pub(crate) const KIND_TIMEZONE_SHARE: u16 = 30078;

/// `d` tag value that marks a kind-30078 app event as a Sonar timezone share.
pub(crate) const TIMEZONE_SHARE_D_TAG: &str = "sonar/local-time";

/// Current wire version of [`TimezoneSharePayload`]. Bump only for an
/// incompatible payload change; older clients ignore versions they do not know.
pub(crate) const TIMEZONE_SHARE_VERSION: u32 = 1;

/// Upper bound on an accepted IANA identifier. The longest real zone id
/// (`America/Argentina/ComodRivadavia`) is 32 chars; 64 leaves generous slack
/// while still rejecting obviously abusive input.
const MAX_ZONE_LEN: usize = 64;

/// JSON payload sent inside a timezone share.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct TimezoneSharePayload {
    /// Wire version. See [`TIMEZONE_SHARE_VERSION`].
    pub v: u32,
    /// IANA timezone identifier, e.g. `Europe/Zurich`.
    pub zone: String,
}

/// A peer's most recently reported timezone, cached locally per sender.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CachedPeerTimezone {
    /// IANA timezone identifier, e.g. `Europe/Zurich`.
    pub zone: String,
    /// When this value was received/stored (unix seconds), so a stale re-send
    /// never overwrites a newer one.
    pub updated_at_secs: u64,
}

/// The unsigned app event carrying `payload` (from
/// [`encode_timezone_share_payload`]).
pub(crate) fn timezone_share_rumor(payload: &str, author: PublicKey) -> UnsignedEvent {
    EventBuilder::new(Kind::Custom(KIND_TIMEZONE_SHARE), payload)
        .tag(Tag::identifier(TIMEZONE_SHARE_D_TAG))
        .build(author)
}

/// Whether a decrypted Marmot app event is a Sonar timezone share: our kind
/// AND our `d` tag. Another app's kind-30078 data is not.
pub(crate) fn is_timezone_share(kind: u64, tags: &[Vec<String>]) -> bool {
    kind == u64::from(KIND_TIMEZONE_SHARE)
        && tags.iter().any(|tag| {
            tag.len() >= 2 && tag[0] == "d" && tag[1] == TIMEZONE_SHARE_D_TAG
        })
}

/// Encode the local timezone into the JSON body of a timezone share. Returns an
/// error for a syntactically invalid zone so we never advertise garbage.
pub(crate) fn encode_timezone_share_payload(zone: &str) -> crate::Result<String> {
    let zone = normalize_zone(zone);
    if !is_valid_iana_timezone(&zone) {
        return Err(crate::Error::InvalidInput(format!(
            "invalid IANA timezone identifier: {zone:?}"
        )));
    }
    let payload = TimezoneSharePayload {
        v: TIMEZONE_SHARE_VERSION,
        zone,
    };
    serde_json::to_string(&payload).map_err(crate::Error::from)
}

/// Parse an incoming timezone share body into a validated zone identifier.
///
/// Returns `None` (rather than erroring) for anything we cannot safely use — a
/// malformed body, an unknown version, or an invalid zone — so a bad control
/// message is simply ignored and never surfaces to the user.
pub(crate) fn parse_timezone_share_payload(content: &str) -> Option<String> {
    let payload: TimezoneSharePayload = serde_json::from_str(content).ok()?;
    if payload.v != TIMEZONE_SHARE_VERSION {
        return None;
    }
    let zone = normalize_zone(&payload.zone);
    is_valid_iana_timezone(&zone).then_some(zone)
}

/// Trim incidental whitespace a host might pass. IANA identifiers themselves
/// never contain spaces, so this only cleans up input, it does not alter a
/// legitimate id.
fn normalize_zone(zone: &str) -> String {
    zone.trim().to_string()
}

/// Syntactic validation of an IANA timezone identifier.
///
/// The core deliberately does **not** carry a full tz database (it would bloat
/// every iOS/Android cross-compile); the authoritative offset resolution lives
/// on the hosts, which null out any id their platform tz database does not know
/// — that is what keeps an invalid/absent zone from rendering a header. This
/// check only rejects structurally impossible ids so we never store or transmit
/// junk: control characters, path traversal, empty segments, or absurd length.
///
/// Accepts the real identifier shapes:
/// - single word: `UTC`, `GMT`, `Zulu`
/// - two segments: `Europe/Zurich`, `America/New_York`
/// - three segments: `America/Argentina/Buenos_Aires`
/// - offset zones: `Etc/GMT+5`, `Etc/GMT-14`
/// - hyphenated locations: `America/Port-au-Prince`
pub fn is_valid_iana_timezone(zone: &str) -> bool {
    if zone.is_empty() || zone.len() > MAX_ZONE_LEN {
        return false;
    }
    // No leading/trailing slash and no traversal-looking sequences.
    if zone.starts_with('/') || zone.ends_with('/') || zone.contains("..") {
        return false;
    }
    let segments: Vec<&str> = zone.split('/').collect();
    // Real ids have 1..=3 segments. Cap at 3 to reject nonsense.
    if segments.is_empty() || segments.len() > 3 {
        return false;
    }
    segments.iter().all(|seg| is_valid_zone_segment(seg))
}

/// A single `/`-delimited segment: must be non-empty, start with an ASCII
/// letter (rules out `+5`, digits-only, or leading punctuation) and otherwise
/// contain only letters, digits, `_`, `+` or `-`.
fn is_valid_zone_segment(seg: &str) -> bool {
    let mut chars = seg.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    seg.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '+' | '-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// MDK v0.10.4 `RESERVED_APP_EVENT_KINDS` (marmot-app
    /// `messages/intents.rs`): kinds other clients act on under MDK's
    /// meaning. 449 is MIP-05's push-token removal.
    const MARMOT_RESERVED_APP_EVENT_KINDS: [u64; 14] = [
        5, 7, 9, 447, 448, 449, 1009, 1200, 1201, 1202, 1210, 1984, 1985, 4891,
    ];

    #[test]
    fn timezone_share_kind_is_not_a_marmot_protocol_kind() {
        assert!(
            !MARMOT_RESERVED_APP_EVENT_KINDS.contains(&u64::from(KIND_TIMEZONE_SHARE)),
            "White Noise members would act on kind {KIND_TIMEZONE_SHARE} under MDK's meaning"
        );
    }

    #[test]
    fn a_timezone_share_needs_our_kind_and_our_d_tag() {
        let author = nostr::Keys::generate().public_key();
        let payload = encode_timezone_share_payload("Europe/Zurich").unwrap();
        let rumor = timezone_share_rumor(&payload, author);
        let tags: Vec<Vec<String>> = rumor.tags.iter().map(|t| t.as_slice().to_vec()).collect();
        assert!(is_timezone_share(u64::from(rumor.kind.as_u16()), &tags));

        let other_app = vec![vec!["d".to_string(), "some-other-app".to_string()]];
        assert!(!is_timezone_share(30078, &other_app), "another app's NIP-78 data");
        assert!(!is_timezone_share(30078, &[]), "no d tag");
        assert!(!is_timezone_share(449, &tags), "White Noise's push-token removal");
    }

    #[test]
    fn accepts_real_iana_identifiers() {
        for zone in [
            "UTC",
            "GMT",
            "Zulu",
            "Europe/Zurich",
            "America/New_York",
            "America/Argentina/Buenos_Aires",
            "America/Argentina/ComodRivadavia",
            "America/Port-au-Prince",
            "Etc/GMT+5",
            "Etc/GMT-14",
            "Asia/Kolkata",
            "Australia/Lord_Howe",
            "Pacific/Chatham",
        ] {
            assert!(is_valid_iana_timezone(zone), "should accept {zone:?}");
        }
    }

    #[test]
    fn rejects_malformed_or_abusive_identifiers() {
        for zone in [
            "",
            " ",
            "/Europe/Zurich",
            "Europe/Zurich/",
            "Europe//Zurich",
            "../../etc/passwd",
            "Europe/../Zurich",
            "Europe/Zurich\n",       // control char
            "Europe/Zür ich",        // space
            "5/Zurich",              // segment starts with digit
            "+05:00",                // colon / offset string, not an id
            "a/b/c/d",               // too many segments
            "Region/With;Semi",      // disallowed char
            "Europe/Zurich\u{202e}", // RTL override
        ] {
            assert!(!is_valid_iana_timezone(zone), "should reject {zone:?}");
        }
    }

    #[test]
    fn rejects_overlong_identifier() {
        let long = format!("Area/{}", "x".repeat(MAX_ZONE_LEN));
        assert!(!is_valid_iana_timezone(&long));
    }

    #[test]
    fn encode_roundtrips_through_parse() {
        let json = encode_timezone_share_payload("Europe/Zurich").unwrap();
        assert_eq!(
            parse_timezone_share_payload(&json).as_deref(),
            Some("Europe/Zurich")
        );
    }

    #[test]
    fn encode_trims_incidental_whitespace() {
        let json = encode_timezone_share_payload("  America/New_York  ").unwrap();
        assert_eq!(
            parse_timezone_share_payload(&json).as_deref(),
            Some("America/New_York")
        );
    }

    #[test]
    fn encode_rejects_invalid_zone() {
        assert!(encode_timezone_share_payload("not a zone!").is_err());
        assert!(encode_timezone_share_payload("").is_err());
    }

    #[test]
    fn parse_ignores_unknown_version() {
        let future = serde_json::to_string(&TimezoneSharePayload {
            v: TIMEZONE_SHARE_VERSION + 1,
            zone: "Europe/Zurich".to_string(),
        })
        .unwrap();
        assert_eq!(parse_timezone_share_payload(&future), None);
    }

    #[test]
    fn parse_ignores_malformed_body() {
        assert_eq!(parse_timezone_share_payload("not json"), None);
        assert_eq!(parse_timezone_share_payload("{}"), None);
        assert_eq!(parse_timezone_share_payload("{\"v\":1}"), None);
    }

    #[test]
    fn parse_rejects_invalid_zone_even_at_right_version() {
        let bad = serde_json::to_string(&TimezoneSharePayload {
            v: TIMEZONE_SHARE_VERSION,
            zone: "../etc".to_string(),
        })
        .unwrap();
        assert_eq!(parse_timezone_share_payload(&bad), None);
    }
}

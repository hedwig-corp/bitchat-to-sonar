use std::collections::HashSet;

use nostr::prelude::*;
use serde::{Deserialize, Serialize};

pub const SONAR_DESCRIPTOR_KIND: u16 = 30078;
pub const SONAR_CALL_DESCRIPTOR_D_TAG: &str = "sonar.call.v1";
pub const SONAR_META_DESCRIPTOR_D_TAG: &str = "sonar.meta.v1";

const CALL_SCHEMA: u16 = 1;
const META_SCHEMA: u16 = 2;
const APP_NAME: &str = "sonar";
const CALL_IDENTITY_V1: &str = "iroh-hkdf-sonar-call-iroh-v1";
const MAX_DESCRIPTOR_CONTENT_BYTES: usize = 4096;
const MAX_LIST_ITEMS: usize = 8;
const MAX_BOLT12_OFFER_BYTES: usize = 2048;

/// Marmot protocol version advertised in the Sonar descriptor. The value is the
/// HIGHEST Marmot protocol version this build supports, and it implies support
/// for every version from 1 up to it. Absent on the wire ⇒ 1 (MDK), so old
/// descriptors and old peers keep negotiating MDK with zero changes.
pub const SONAR_PROTOCOL_MDK: u8 = 1;
/// Darkmatter (Marmot v2). See [`SONAR_PROTOCOL_MDK`] for the "implies 1..=N" rule.
pub const SONAR_PROTOCOL_DARKMATTER: u8 = 2;

// Serde default: a descriptor with no `sonar_protocol` on the wire (every
// pre-Darkmatter client) parses as MDK.
fn default_sonar_protocol() -> u8 {
    SONAR_PROTOCOL_MDK
}

// Serde skip: protocol-1 descriptors omit the field so their wire bytes stay
// identical to pre-Darkmatter clients (asserted by
// `mdk_protocol_is_omitted_from_wire_but_parses_back_as_one`).
fn is_mdk_protocol(protocol: &u8) -> bool {
    *protocol == SONAR_PROTOCOL_MDK
}

/// Highest Marmot protocol version both peers support, given each value implies
/// support for `1..=value`. `min` — not `max` — because the result must be a
/// version BOTH sides speak: `max` would pick a protocol one peer does not
/// understand and break interop. Used to pick the engine for a NEW conversation;
/// existing conversations keep their stored backend regardless of this value.
///
/// Inputs are always `>= SONAR_PROTOCOL_MDK`: the parse path
/// ([`parse_descriptor_event`]) and the local setter
/// (`SonarClient::set_advertised_sonar_protocol`) both floor the value, so a
/// hostile `sonar_protocol: 0` on the wire cannot flow through here.
///
/// This governs Sonar↔Sonar selection only — WhiteNoise/other Marmot clients do
/// not publish a Sonar descriptor and are detected from their key-package event
/// kinds instead.
pub fn negotiate(local: u8, peer: u8) -> u8 {
    local.min(peer)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SonarDescriptor {
    pub schema: u16,
    pub calls: bool,
    pub media: Vec<String>,
    pub signaling: Vec<String>,
    pub transports: Vec<String>,
    pub call_identity: String,
    pub bolt12_offer: Option<String>,
    pub payment_receipts: Vec<String>,
    /// Highest Marmot protocol version the peer supports (1 = MDK, 2 = Darkmatter).
    /// Defaults to 1 when the descriptor omits it. See [`negotiate`].
    pub sonar_protocol: u8,
    pub published_at_secs: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct DescriptorContent {
    schema: u16,
    app: String,
    calls: bool,
    media: Vec<String>,
    signaling: Vec<String>,
    transports: Vec<String>,
    call_identity: String,
    /// Marmot protocol capability. Omitted on the wire when MDK-only (1) so
    /// protocol-1 descriptors stay byte-identical to pre-Darkmatter clients;
    /// a missing field parses back as 1.
    #[serde(
        default = "default_sonar_protocol",
        skip_serializing_if = "is_mdk_protocol"
    )]
    sonar_protocol: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    payments: Option<DescriptorPayments>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct DescriptorPayments {
    receive: Vec<DescriptorPaymentReceive>,
    receipts: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct DescriptorPaymentReceive {
    #[serde(rename = "type")]
    method_type: String,
    offer: String,
    network: String,
    proofs: Vec<String>,
    future_proofs: Vec<String>,
}

impl DescriptorContent {
    fn legacy_call(calls_enabled: bool, signaling: Vec<String>, sonar_protocol: u8) -> Self {
        Self {
            schema: CALL_SCHEMA,
            app: APP_NAME.to_string(),
            calls: calls_enabled,
            media: if calls_enabled {
                vec!["voice".to_string(), "video".to_string()]
            } else {
                Vec::new()
            },
            signaling: normalize_list(signaling, default_signaling_routes()),
            transports: if calls_enabled {
                vec!["iroh".to_string()]
            } else {
                Vec::new()
            },
            call_identity: CALL_IDENTITY_V1.to_string(),
            // The call descriptor is the ALWAYS-published one (the meta
            // descriptor is offer-gated, see `descriptor_events`), so it must
            // carry the protocol capability too or a wallet-less build could
            // never advertise Darkmatter. Old clients deserialize with serde's
            // default unknown-field tolerance and ignore it; protocol-1 builds
            // omit it entirely (`skip_serializing_if`), keeping their wire
            // bytes identical to pre-Darkmatter releases.
            sonar_protocol,
            payments: None,
        }
    }

    fn meta(
        calls_enabled: bool,
        signaling: Vec<String>,
        bolt12_offer: Option<String>,
        sonar_protocol: u8,
    ) -> Self {
        let payments =
            bolt12_offer
                .and_then(normalize_bolt12_offer)
                .map(|offer| DescriptorPayments {
                    receive: vec![DescriptorPaymentReceive {
                        method_type: "bolt12_offer".to_string(),
                        offer,
                        network: "bitcoin".to_string(),
                        proofs: vec!["preimage".to_string()],
                        future_proofs: vec!["bolt12_payer_proof".to_string()],
                    }],
                    receipts: vec!["sonar.payment.receipt.v1".to_string()],
                });
        Self {
            schema: META_SCHEMA,
            app: APP_NAME.to_string(),
            calls: calls_enabled,
            media: if calls_enabled {
                vec!["voice".to_string(), "video".to_string()]
            } else {
                Vec::new()
            },
            signaling: normalize_list(signaling, default_signaling_routes()),
            transports: if calls_enabled {
                vec!["iroh".to_string()]
            } else {
                Vec::new()
            },
            call_identity: CALL_IDENTITY_V1.to_string(),
            sonar_protocol,
            payments,
        }
    }

    fn into_descriptor(self, published_at_secs: u64) -> Option<SonarDescriptor> {
        if !matches!(self.schema, CALL_SCHEMA | META_SCHEMA) || self.app != APP_NAME {
            return None;
        }
        let (bolt12_offer, payment_receipts) = self
            .payments
            .map(|payments| {
                let offer = payments
                    .receive
                    .into_iter()
                    .find(|receive| {
                        receive.method_type == "bolt12_offer"
                            && receive.network.eq_ignore_ascii_case("bitcoin")
                    })
                    .and_then(|receive| normalize_bolt12_offer(receive.offer));
                let receipts = normalize_list(payments.receipts, Vec::new());
                (offer, receipts)
            })
            .unwrap_or((None, Vec::new()));
        Some(SonarDescriptor {
            schema: self.schema,
            calls: self.calls,
            media: normalize_list(self.media, Vec::new()),
            signaling: normalize_list(self.signaling, Vec::new()),
            transports: normalize_list(self.transports, Vec::new()),
            call_identity: self.call_identity,
            bolt12_offer,
            payment_receipts,
            // Trust boundary: descriptors come from public relays. Floor a
            // hostile/buggy `sonar_protocol: 0` to MDK so a nonsense version
            // never reaches `negotiate`. Values above DARKMATTER are kept
            // as-is on purpose — a future v3 peer must still parse and
            // interop via `min()`.
            sonar_protocol: self.sonar_protocol.max(SONAR_PROTOCOL_MDK),
            published_at_secs,
        })
    }
}

pub fn default_signaling_routes() -> Vec<String> {
    // The current account-level internet call route implemented by the app.
    // Future clients can add routes without changing the descriptor event kind.
    vec!["marmot".to_string()]
}

pub fn descriptor_content_json(
    calls_enabled: bool,
    signaling: Vec<String>,
    sonar_protocol: u8,
) -> serde_json::Result<String> {
    serde_json::to_string(&DescriptorContent::legacy_call(
        calls_enabled,
        signaling,
        sonar_protocol,
    ))
}

pub fn meta_descriptor_content_json(
    calls_enabled: bool,
    signaling: Vec<String>,
    bolt12_offer: Option<String>,
    sonar_protocol: u8,
) -> serde_json::Result<String> {
    serde_json::to_string(&DescriptorContent::meta(
        calls_enabled,
        signaling,
        bolt12_offer,
        sonar_protocol,
    ))
}

/// The descriptor events that should be (re)published for the current readiness
/// state, as `(d_tag, content_json)` pairs.
///
/// The call descriptor (`sonar.call.v1`) is always emitted so calls stay
/// discoverable even without a wallet. The meta descriptor (`sonar.meta.v1`),
/// which carries the `bolt12_offer`, is emitted ONLY when a valid offer is
/// present.
/// Both are replaceable events, so republishing the meta with `None` would
/// CLOBBER a peer's previously-published offer and make them unpayable — a
/// wallet-less / not-yet-ready publish must never wipe a known offer.
pub fn descriptor_events(
    calls_enabled: bool,
    signaling: Vec<String>,
    bolt12_offer: Option<String>,
    sonar_protocol: u8,
) -> serde_json::Result<Vec<(&'static str, String)>> {
    // Both descriptors carry `sonar_protocol`: the call descriptor is the
    // always-published capability carrier (so a wallet-less Darkmatter build
    // can still advertise v2), while the meta descriptor stays gated on a
    // valid offer so an offer-less publish never clobbers a previously
    // published one (see #180). Fetch side: `newest_valid_sonar_descriptor`
    // takes the freshest event, which now always carries the claim.
    let mut events = vec![(
        SONAR_CALL_DESCRIPTOR_D_TAG,
        descriptor_content_json(calls_enabled, signaling.clone(), sonar_protocol)?,
    )];
    if let Some(offer) = bolt12_offer.and_then(normalize_bolt12_offer) {
        events.push((
            SONAR_META_DESCRIPTOR_D_TAG,
            meta_descriptor_content_json(calls_enabled, signaling, Some(offer), sonar_protocol)?,
        ));
    }
    Ok(events)
}

pub fn descriptor_tags(d_tag: &str) -> Vec<Tag> {
    vec![
        Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::D)),
            [d_tag],
        ),
        Tag::hashtag(APP_NAME),
    ]
}

pub fn parse_descriptor_event(event: &Event) -> Option<SonarDescriptor> {
    if event.kind != Kind::Custom(SONAR_DESCRIPTOR_KIND)
        || event.content.len() > MAX_DESCRIPTOR_CONTENT_BYTES
        || !has_descriptor_d_tag(
            event,
            &[SONAR_CALL_DESCRIPTOR_D_TAG, SONAR_META_DESCRIPTOR_D_TAG],
        )
    {
        return None;
    }
    let content: DescriptorContent = serde_json::from_str(&event.content).ok()?;
    content.into_descriptor(event.created_at.as_secs())
}

pub fn descriptor_d_tags() -> [&'static str; 2] {
    [SONAR_META_DESCRIPTOR_D_TAG, SONAR_CALL_DESCRIPTOR_D_TAG]
}

fn has_descriptor_d_tag(event: &Event, accepted: &[&str]) -> bool {
    event.tags.iter().any(|tag| {
        tag.single_letter_tag() == Some(SingleLetterTag::lowercase(Alphabet::D))
            && tag.content().map_or(false, |content| {
                accepted.iter().any(|value| *value == content)
            })
    })
}

fn normalize_list(values: Vec<String>, fallback: Vec<String>) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for value in values {
        let token = value.trim().to_ascii_lowercase();
        if !is_protocol_token(&token) || !seen.insert(token.clone()) {
            continue;
        }
        out.push(token);
        if out.len() >= MAX_LIST_ITEMS {
            break;
        }
    }
    if out.is_empty() {
        fallback
    } else {
        out
    }
}

fn is_protocol_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

fn normalize_bolt12_offer(value: String) -> Option<String> {
    let offer = value.trim().to_ascii_lowercase();
    if offer.starts_with("lno")
        && offer.len() <= MAX_BOLT12_OFFER_BYTES
        && offer.bytes().all(|b| b.is_ascii_alphanumeric())
    {
        Some(offer)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_event_round_trips_and_normalizes_lists() {
        let keys = Keys::generate();
        let content = descriptor_content_json(
            true,
            vec![
                "Marmot".to_string(),
                "marmot".to_string(),
                "bad route".to_string(),
            ],
            SONAR_PROTOCOL_MDK,
        )
        .expect("descriptor json");
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .tags(descriptor_tags(SONAR_CALL_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");

        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.schema, CALL_SCHEMA);
        assert!(parsed.calls);
        assert_eq!(parsed.media, vec!["voice", "video"]);
        assert_eq!(parsed.signaling, vec!["marmot"]);
        assert_eq!(parsed.transports, vec!["iroh"]);
        assert_eq!(parsed.call_identity, CALL_IDENTITY_V1);
        assert_eq!(parsed.bolt12_offer, None);
        assert!(parsed.payment_receipts.is_empty());
        // The legacy call descriptor omits the protocol field, so it parses as MDK.
        assert_eq!(parsed.sonar_protocol, SONAR_PROTOCOL_MDK);
        assert_eq!(parsed.published_at_secs, event.created_at.as_secs());
    }

    #[test]
    fn meta_descriptor_includes_bolt12_payment_metadata() {
        let keys = Keys::generate();
        let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq"
            .to_string();
        let content = meta_descriptor_content_json(
            true,
            default_signaling_routes(),
            Some(offer.clone()),
            SONAR_PROTOCOL_DARKMATTER,
        )
        .expect("descriptor json");
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .tags(descriptor_tags(SONAR_META_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");

        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.schema, META_SCHEMA);
        assert_eq!(parsed.bolt12_offer, Some(offer));
        // A Darkmatter-capable build advertises protocol 2 and it round-trips.
        assert_eq!(parsed.sonar_protocol, SONAR_PROTOCOL_DARKMATTER);
        assert_eq!(
            parsed.payment_receipts,
            vec!["sonar.payment.receipt.v1".to_string()]
        );
    }

    #[test]
    fn meta_descriptor_without_offer_clears_payment_metadata() {
        let keys = Keys::generate();
        let content = meta_descriptor_content_json(
            true,
            default_signaling_routes(),
            None,
            SONAR_PROTOCOL_MDK,
        )
        .expect("descriptor json");
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .tags(descriptor_tags(SONAR_META_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");

        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.schema, META_SCHEMA);
        assert!(parsed.bolt12_offer.is_none());
        assert!(parsed.payment_receipts.is_empty());
        assert_eq!(parsed.sonar_protocol, SONAR_PROTOCOL_MDK);
    }

    #[test]
    fn mdk_protocol_is_omitted_from_wire_but_parses_back_as_one() {
        // A protocol-1 meta descriptor must be byte-identical on the wire to a
        // pre-Darkmatter client (no `sonar_protocol` key), and parse back as 1.
        let json = meta_descriptor_content_json(
            false,
            default_signaling_routes(),
            None,
            SONAR_PROTOCOL_MDK,
        )
        .expect("descriptor json");
        assert!(
            !json.contains("sonar_protocol"),
            "MDK descriptor must omit the protocol field on the wire: {json}"
        );

        let keys = Keys::generate();
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), json)
            .tags(descriptor_tags(SONAR_META_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");
        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.sonar_protocol, SONAR_PROTOCOL_MDK);
    }

    #[test]
    fn call_descriptor_carries_darkmatter_protocol_without_offer() {
        // A wallet-less Darkmatter build must still be able to advertise v2:
        // the always-published call descriptor carries the capability.
        let keys = Keys::generate();
        let content = descriptor_content_json(
            true,
            default_signaling_routes(),
            SONAR_PROTOCOL_DARKMATTER,
        )
        .expect("descriptor json");
        assert!(content.contains("\"sonar_protocol\":2"));

        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .tags(descriptor_tags(SONAR_CALL_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");
        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.sonar_protocol, SONAR_PROTOCOL_DARKMATTER);
    }

    #[test]
    fn hostile_zero_protocol_is_floored_to_mdk() {
        // Descriptors come from public relays: `sonar_protocol: 0` must not
        // survive parsing, or `negotiate(local, 0)` would select a nonsense
        // version. Values above DARKMATTER stay as-is (forward compat).
        let keys = Keys::generate();
        let base = meta_descriptor_content_json(
            true,
            default_signaling_routes(),
            None,
            SONAR_PROTOCOL_DARKMATTER,
        )
        .expect("descriptor json");
        let mut value: serde_json::Value = serde_json::from_str(&base).expect("valid json");
        value["sonar_protocol"] = serde_json::json!(0);
        let hostile = serde_json::to_string(&value).expect("json");

        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), hostile)
            .tags(descriptor_tags(SONAR_META_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");
        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.sonar_protocol, SONAR_PROTOCOL_MDK);

        // Forward compat: a future v3 build's descriptor still parses as 3.
        let mut future: serde_json::Value = serde_json::from_str(&base).expect("valid json");
        future["sonar_protocol"] = serde_json::json!(3);
        let future_json = serde_json::to_string(&future).expect("json");
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), future_json)
            .tags(descriptor_tags(SONAR_META_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");
        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.sonar_protocol, 3);
        assert_eq!(negotiate(SONAR_PROTOCOL_DARKMATTER, parsed.sonar_protocol), 2);
    }

    #[test]
    fn negotiate_picks_highest_common_protocol() {
        // Each value implies support for 1..=value, so min() is the highest both speak.
        assert_eq!(
            negotiate(SONAR_PROTOCOL_DARKMATTER, SONAR_PROTOCOL_MDK),
            SONAR_PROTOCOL_MDK
        );
        assert_eq!(
            negotiate(SONAR_PROTOCOL_MDK, SONAR_PROTOCOL_DARKMATTER),
            SONAR_PROTOCOL_MDK
        );
        assert_eq!(
            negotiate(SONAR_PROTOCOL_DARKMATTER, SONAR_PROTOCOL_DARKMATTER),
            SONAR_PROTOCOL_DARKMATTER
        );
        assert_eq!(
            negotiate(SONAR_PROTOCOL_MDK, SONAR_PROTOCOL_MDK),
            SONAR_PROTOCOL_MDK
        );
    }

    #[test]
    fn descriptor_events_omit_meta_when_offer_absent() {
        // No offer: only the call descriptor is emitted, so an offer-less /
        // not-yet-ready publish can never clobber a previously-published offer.
        let only_call =
            descriptor_events(true, default_signaling_routes(), None, SONAR_PROTOCOL_MDK)
                .expect("events");
        assert_eq!(only_call.len(), 1);
        assert_eq!(only_call[0].0, SONAR_CALL_DESCRIPTOR_D_TAG);

        // Invalid offers must also stay call-only. The serializer normalizes
        // offers before adding payment fields, so gating only on Option::Some
        // would still publish an empty replaceable meta descriptor.
        for invalid_offer in ["", "not-lno"] {
            let events = descriptor_events(
                true,
                default_signaling_routes(),
                Some(invalid_offer.to_string()),
                SONAR_PROTOCOL_MDK,
            )
            .expect("events");
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].0, SONAR_CALL_DESCRIPTOR_D_TAG);
        }
        let oversized_offer = format!("lno{}", "q".repeat(MAX_BOLT12_OFFER_BYTES));
        let events = descriptor_events(
            true,
            default_signaling_routes(),
            Some(oversized_offer),
            SONAR_PROTOCOL_MDK,
        )
        .expect("events");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].0, SONAR_CALL_DESCRIPTOR_D_TAG);

        // With an offer: both the call and meta descriptors are emitted, and the
        // meta carries the offer.
        let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq"
            .to_string();
        let with_offer = descriptor_events(
            true,
            default_signaling_routes(),
            Some(offer.clone()),
            SONAR_PROTOCOL_DARKMATTER,
        )
        .expect("events");
        assert_eq!(with_offer.len(), 2);
        assert!(with_offer
            .iter()
            .any(|(d, _)| *d == SONAR_CALL_DESCRIPTOR_D_TAG));
        assert!(with_offer
            .iter()
            .any(|(d, _)| *d == SONAR_META_DESCRIPTOR_D_TAG));
        let meta = with_offer
            .iter()
            .find(|(d, _)| *d == SONAR_META_DESCRIPTOR_D_TAG)
            .map(|(_, c)| c)
            .expect("meta event");
        assert!(meta.contains(&offer));
        // The advertised protocol rides the meta descriptor.
        assert!(meta.contains("\"sonar_protocol\":2"));
    }

    #[test]
    fn descriptor_requires_addressable_d_tag() {
        let keys = Keys::generate();
        let content =
            descriptor_content_json(true, default_signaling_routes(), SONAR_PROTOCOL_MDK)
                .expect("descriptor json");
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .sign_with_keys(&keys)
            .expect("sign descriptor");

        assert!(parse_descriptor_event(&event).is_none());
    }
}

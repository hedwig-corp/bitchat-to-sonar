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

fn default_sonar_protocol() -> u8 {
    SONAR_PROTOCOL_MDK
}

fn is_mdk_protocol(protocol: &u8) -> bool {
    *protocol == SONAR_PROTOCOL_MDK
}

/// Highest Marmot protocol version both peers support, given each value implies
/// support for `1..=value`. Used to pick the engine for a NEW conversation;
/// existing conversations keep their stored backend regardless of this value.
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
    fn legacy_call(calls_enabled: bool, signaling: Vec<String>) -> Self {
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
            // The legacy call-only descriptor is for pre-Darkmatter clients; it
            // always advertises MDK. The unified `meta` descriptor carries the
            // negotiable protocol value.
            sonar_protocol: SONAR_PROTOCOL_MDK,
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
            sonar_protocol: self.sonar_protocol,
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
) -> serde_json::Result<String> {
    serde_json::to_string(&DescriptorContent::legacy_call(calls_enabled, signaling))
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
    fn descriptor_requires_addressable_d_tag() {
        let keys = Keys::generate();
        let content =
            descriptor_content_json(true, default_signaling_routes()).expect("descriptor json");
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .sign_with_keys(&keys)
            .expect("sign descriptor");

        assert!(parse_descriptor_event(&event).is_none());
    }
}

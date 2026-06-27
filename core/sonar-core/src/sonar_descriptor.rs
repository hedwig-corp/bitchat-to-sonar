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
            payments: None,
        }
    }

    fn meta(calls_enabled: bool, signaling: Vec<String>, bolt12_offer: Option<String>) -> Self {
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
) -> serde_json::Result<String> {
    serde_json::to_string(&DescriptorContent::meta(
        calls_enabled,
        signaling,
        bolt12_offer,
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
) -> serde_json::Result<Vec<(&'static str, String)>> {
    let mut events = vec![(
        SONAR_CALL_DESCRIPTOR_D_TAG,
        descriptor_content_json(calls_enabled, signaling.clone())?,
    )];
    if let Some(offer) = bolt12_offer.and_then(normalize_bolt12_offer) {
        events.push((
            SONAR_META_DESCRIPTOR_D_TAG,
            meta_descriptor_content_json(calls_enabled, signaling, Some(offer))?,
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
        assert_eq!(parsed.published_at_secs, event.created_at.as_secs());
    }

    #[test]
    fn meta_descriptor_includes_bolt12_payment_metadata() {
        let keys = Keys::generate();
        let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq"
            .to_string();
        let content =
            meta_descriptor_content_json(true, default_signaling_routes(), Some(offer.clone()))
                .expect("descriptor json");
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .tags(descriptor_tags(SONAR_META_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");

        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.schema, META_SCHEMA);
        assert_eq!(parsed.bolt12_offer, Some(offer));
        assert_eq!(
            parsed.payment_receipts,
            vec!["sonar.payment.receipt.v1".to_string()]
        );
    }

    #[test]
    fn meta_descriptor_without_offer_clears_payment_metadata() {
        let keys = Keys::generate();
        let content = meta_descriptor_content_json(true, default_signaling_routes(), None)
            .expect("descriptor json");
        let event = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .tags(descriptor_tags(SONAR_META_DESCRIPTOR_D_TAG))
            .sign_with_keys(&keys)
            .expect("sign descriptor");

        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.schema, META_SCHEMA);
        assert!(parsed.bolt12_offer.is_none());
        assert!(parsed.payment_receipts.is_empty());
    }

    #[test]
    fn descriptor_events_omit_meta_when_offer_absent() {
        // No offer: only the call descriptor is emitted, so an offer-less /
        // not-yet-ready publish can never clobber a previously-published offer.
        let only_call = descriptor_events(true, default_signaling_routes(), None).expect("events");
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
            )
            .expect("events");
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].0, SONAR_CALL_DESCRIPTOR_D_TAG);
        }
        let oversized_offer = format!("lno{}", "q".repeat(MAX_BOLT12_OFFER_BYTES));
        let events = descriptor_events(true, default_signaling_routes(), Some(oversized_offer))
            .expect("events");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].0, SONAR_CALL_DESCRIPTOR_D_TAG);

        // With an offer: both the call and meta descriptors are emitted, and the
        // meta carries the offer.
        let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq"
            .to_string();
        let with_offer = descriptor_events(true, default_signaling_routes(), Some(offer.clone()))
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

use std::collections::HashSet;

use nostr::prelude::*;
use serde::{Deserialize, Serialize};

pub const SONAR_DESCRIPTOR_KIND: u16 = 30078;
pub const SONAR_DESCRIPTOR_D_TAG: &str = "sonar.call.v1";

const CURRENT_SCHEMA: u16 = 1;
const APP_NAME: &str = "sonar";
const CALL_IDENTITY_V1: &str = "iroh-hkdf-sonar-call-iroh-v1";
const MAX_DESCRIPTOR_CONTENT_BYTES: usize = 4096;
const MAX_LIST_ITEMS: usize = 8;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SonarDescriptor {
    pub schema: u16,
    pub calls: bool,
    pub media: Vec<String>,
    pub signaling: Vec<String>,
    pub transports: Vec<String>,
    pub call_identity: String,
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
}

impl DescriptorContent {
    fn new(calls_enabled: bool, signaling: Vec<String>) -> Self {
        Self {
            schema: CURRENT_SCHEMA,
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
        }
    }

    fn into_descriptor(self, published_at_secs: u64) -> Option<SonarDescriptor> {
        if self.schema != CURRENT_SCHEMA || self.app != APP_NAME {
            return None;
        }
        Some(SonarDescriptor {
            schema: self.schema,
            calls: self.calls,
            media: normalize_list(self.media, Vec::new()),
            signaling: normalize_list(self.signaling, Vec::new()),
            transports: normalize_list(self.transports, Vec::new()),
            call_identity: self.call_identity,
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
    serde_json::to_string(&DescriptorContent::new(calls_enabled, signaling))
}

pub fn descriptor_tags() -> Vec<Tag> {
    vec![
        Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::D)),
            [SONAR_DESCRIPTOR_D_TAG],
        ),
        Tag::hashtag(APP_NAME),
    ]
}

pub fn parse_descriptor_event(event: &Event) -> Option<SonarDescriptor> {
    if event.kind != Kind::Custom(SONAR_DESCRIPTOR_KIND)
        || event.content.len() > MAX_DESCRIPTOR_CONTENT_BYTES
        || !has_descriptor_d_tag(event)
    {
        return None;
    }
    let content: DescriptorContent = serde_json::from_str(&event.content).ok()?;
    content.into_descriptor(event.created_at.as_secs())
}

fn has_descriptor_d_tag(event: &Event) -> bool {
    event.tags.iter().any(|tag| {
        tag.single_letter_tag() == Some(SingleLetterTag::lowercase(Alphabet::D))
            && tag.content() == Some(SONAR_DESCRIPTOR_D_TAG)
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
            .tags(descriptor_tags())
            .sign_with_keys(&keys)
            .expect("sign descriptor");

        let parsed = parse_descriptor_event(&event).expect("valid descriptor");
        assert_eq!(parsed.schema, CURRENT_SCHEMA);
        assert!(parsed.calls);
        assert_eq!(parsed.media, vec!["voice", "video"]);
        assert_eq!(parsed.signaling, vec!["marmot"]);
        assert_eq!(parsed.transports, vec!["iroh"]);
        assert_eq!(parsed.call_identity, CALL_IDENTITY_V1);
        assert_eq!(parsed.published_at_secs, event.created_at.as_secs());
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

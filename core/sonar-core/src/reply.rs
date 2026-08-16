//! NIP-C7 reply pointer for kind-9 Marmot rumors.
//!
//! White Noise writes a single `q` tag and prepends `nostr:nevent1…` to content.
//! This module is the only place that builds or strips that prefix so
//! classification, echo matching, and chat-list previews all see the display
//! body — never the wire URI.

use nostr::nips::nip19::Nip19Event;
use nostr::nips::nip21::{FromNostrUri, ToNostrUri};
use nostr::prelude::*;

use crate::{Error, Result};

/// Max chars kept on a denormalized quote snapshot (Signal-style chip text).
pub const REPLY_PREVIEW_MAX_CHARS: usize = 140;

/// Send-side reply target. `preview` never goes on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplyTo {
    pub parent_id: EventId,
    pub parent_pubkey: PublicKey,
    pub preview: Option<String>,
}

impl ReplyTo {
    pub fn new(
        parent_id: EventId,
        parent_pubkey: PublicKey,
        preview: Option<impl Into<String>>,
    ) -> Self {
        Self {
            parent_id,
            parent_pubkey,
            preview: preview.map(|p| truncate_preview(&p.into())),
        }
    }
}

/// Projected reply pointer on a `ChatMessage`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplyRef {
    pub parent_id: EventId,
    pub parent_pubkey: Option<PublicKey>,
    pub preview: Option<String>,
}

/// NIP-C7 / NIP-18 `q` tag: `["q", <id>, "", <pubkey>]`.
pub fn quote_tag(parent_id: &EventId, parent_pubkey: &PublicKey) -> Tag {
    Tag::from_standardized_without_cell(TagStandard::Quote {
        event_id: *parent_id,
        relay_url: None,
        public_key: Some(*parent_pubkey),
    })
}

/// `nostr:nevent1…\n<body>` — author is included so White Noise can strip it.
pub fn prefix_content(user_text: &str, parent_id: &EventId, parent_pubkey: &PublicKey) -> Result<String> {
    let uri = Nip19Event::new(*parent_id)
        .author(*parent_pubkey)
        .to_nostr_uri()
        .map_err(|e| Error::InvalidInput(format!("nevent uri: {e}")))?;
    if user_text.is_empty() {
        Ok(uri)
    } else {
        Ok(format!("{uri}\n{user_text}"))
    }
}

/// Strip a leading `nostr:nevent…` line only when it names `parent_id`.
///
/// A user-pasted nevent with no matching `q` tag must be left intact.
pub fn strip_c7_prefix<'a>(content: &'a str, parent_id: &EventId) -> &'a str {
    let (head, rest) = match content.split_once('\n') {
        Some((h, r)) => (h, Some(r)),
        None => (content, None),
    };
    let Ok(ev) = Nip19Event::from_nostr_uri(head) else {
        return content;
    };
    if ev.event_id != *parent_id {
        return content;
    }
    rest.unwrap_or("")
}

pub fn parse_quote_tag<'a, I>(tags: I) -> Option<ReplyRef>
where
    I: IntoIterator<Item = &'a Tag>,
{
    for tag in tags {
        if let Some(TagStandard::Quote {
            event_id,
            public_key,
            ..
        }) = tag.as_standardized()
        {
            return Some(ReplyRef {
                parent_id: *event_id,
                parent_pubkey: *public_key,
                preview: None,
            });
        }
        let slice = tag.as_slice();
        if slice.first().map(|s| s.as_str()) != Some("q") || slice.len() < 2 {
            continue;
        }
        let Ok(parent_id) = EventId::from_hex(&slice[1]) else {
            tracing::debug!("invalid q-tag event id");
            continue;
        };
        let parent_pubkey = slice.get(3).and_then(|p| PublicKey::parse(p).ok());
        return Some(ReplyRef {
            parent_id,
            parent_pubkey,
            preview: None,
        });
    }
    None
}

/// Display body + reply pointer. Classification MUST run on the returned body.
pub fn project_application_content<'a, I>(content: &str, tags: I) -> (String, Option<ReplyRef>)
where
    I: IntoIterator<Item = &'a Tag>,
{
    let reply = parse_quote_tag(tags);
    let display = match &reply {
        Some(r) => strip_c7_prefix(content, &r.parent_id).to_string(),
        None => content.to_string(),
    };
    (display, reply)
}

pub fn truncate_preview(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= REPLY_PREVIEW_MAX_CHARS {
        return trimmed.to_string();
    }
    let mut out = trimmed.chars().take(REPLY_PREVIEW_MAX_CHARS).collect::<String>();
    out.push('…');
    out
}

/// Parent body that is safe to copy into a quote snapshot.
///
/// Pay/call/sticker/media rows are typed by the host (`Payment` / `Photo` /
/// `Sticker`). Copying raw `content` here would flash `⚡PAY|…` after a page
/// hydrate. Leave `preview` empty and let the host fill the type label.
pub fn parent_content_for_preview<'a>(
    classification: &crate::marmot::MessageClassification,
    has_sticker: bool,
    has_media: bool,
    content: &'a str,
) -> Option<&'a str> {
    use crate::marmot::MessageClassification;
    if !matches!(classification, MessageClassification::Text) {
        return None;
    }
    if has_sticker || has_media {
        return None;
    }
    let t = content.trim();
    if t.is_empty() || t.starts_with("⚡PAY") || t.starts_with('☎') {
        return None;
    }
    Some(t)
}

/// Fill a missing quote snapshot from a locally stored parent body.
/// NIP-C7 does not carry preview text; Signal-style chips denormalize it here.
pub fn hydrate_reply_preview(reply: &mut ReplyRef, parent_content: Option<&str>) {
    if reply
        .preview
        .as_ref()
        .is_some_and(|p| !p.trim().is_empty())
    {
        return;
    }
    let Some(parent) = parent_content.map(str::trim).filter(|s| !s.is_empty()) else {
        return;
    };
    reply.preview = Some(truncate_preview(parent));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::marmot::MessageClassification;

    fn ids() -> (EventId, PublicKey) {
        let keys = Keys::generate();
        let id = EventId::from_slice(&[0x11u8; 32]).expect("event id");
        (id, keys.public_key())
    }

    #[test]
    fn quote_tag_is_q_with_empty_relay_and_pubkey() {
        let (id, pk) = ids();
        let tag = quote_tag(&id, &pk);
        let slice = tag.as_slice();
        assert_eq!(slice[0], "q");
        assert_eq!(slice[1], id.to_hex());
        assert_eq!(slice[2], "", "WN uses an empty relay URL inside MLS");
        assert_eq!(slice[3], pk.to_hex());
    }

    #[test]
    fn prefix_then_strip_round_trips_user_text() {
        let (id, pk) = ids();
        let wire = prefix_content("hello", &id, &pk).unwrap();
        assert!(wire.starts_with("nostr:nevent1"));
        assert!(wire.contains('\n'));
        assert_eq!(strip_c7_prefix(&wire, &id), "hello");
    }

    #[test]
    fn empty_body_prefix_strips_to_empty() {
        let (id, pk) = ids();
        let wire = prefix_content("", &id, &pk).unwrap();
        assert!(wire.starts_with("nostr:nevent1"));
        assert!(!wire.contains('\n'));
        assert_eq!(strip_c7_prefix(&wire, &id), "");
    }

    #[test]
    fn pasted_nevent_without_matching_parent_is_kept() {
        let (id, pk) = ids();
        let other = EventId::from_slice(&[0x22u8; 32]).unwrap();
        let pasted = prefix_content("hi", &id, &pk).unwrap();
        assert_eq!(strip_c7_prefix(&pasted, &other), pasted.as_str());
        assert_eq!(
            project_application_content(&pasted, &[] as &[Tag]),
            (pasted.clone(), None),
            "no q tag → do not strip a user-pasted nevent"
        );
    }

    #[test]
    fn pay_receipt_classifies_after_strip() {
        let (id, pk) = ids();
        let body = "⚡PAY|1|abc-123|21";
        let wire = prefix_content(body, &id, &pk).unwrap();
        assert!(
            matches!(MessageClassification::of(&wire), MessageClassification::Text),
            "classifying the wire body would hide the payment"
        );
        let tag = quote_tag(&id, &pk);
        let (display, reply) = project_application_content(&wire, std::iter::once(&tag));
        assert!(reply.is_some());
        assert_eq!(display, body);
        assert!(matches!(
            MessageClassification::of(&display),
            MessageClassification::PayReceipt { .. }
        ));
    }

    #[test]
    fn malformed_q_event_id_yields_no_reply_and_keeps_content() {
        let tag = Tag::custom(TagKind::Custom("q".into()), ["zzzz".to_string()]);
        let (display, reply) = project_application_content("hello", std::iter::once(&tag));
        assert!(reply.is_none());
        assert_eq!(display, "hello");
    }

    #[test]
    fn project_with_q_strips_matching_prefix() {
        let (id, pk) = ids();
        let wire = prefix_content("yes", &id, &pk).unwrap();
        let tag = quote_tag(&id, &pk);
        let (display, reply) = project_application_content(&wire, std::iter::once(&tag));
        assert_eq!(display, "yes");
        assert_eq!(reply.unwrap().parent_id, id);
    }

    #[test]
    fn hydrate_fills_empty_preview_from_parent_body() {
        let (id, pk) = ids();
        let mut reply = ReplyRef {
            parent_id: id,
            parent_pubkey: Some(pk),
            preview: None,
        };
        hydrate_reply_preview(&mut reply, Some("  parent body  "));
        assert_eq!(reply.preview.as_deref(), Some("parent body"));
        hydrate_reply_preview(&mut reply, Some("ignored once filled"));
        assert_eq!(reply.preview.as_deref(), Some("parent body"));
    }

    #[test]
    fn parent_content_for_preview_skips_typed_and_protocol_bodies() {
        use crate::marmot::MessageClassification;
        assert_eq!(
            parent_content_for_preview(&MessageClassification::Text, false, false, " hello "),
            Some("hello")
        );
        assert_eq!(
            parent_content_for_preview(
                &MessageClassification::PayReceipt {
                    payment_id: "p".into(),
                    amount_sats: 1,
                },
                false,
                false,
                "⚡PAY|1|p|1"
            ),
            None
        );
        assert_eq!(
            parent_content_for_preview(
                &MessageClassification::Text,
                false,
                false,
                "⚡PAY|1|p|1"
            ),
            None
        );
        assert_eq!(
            parent_content_for_preview(&MessageClassification::CallControl, false, false, "☎CALL|1"),
            None
        );
        assert_eq!(
            parent_content_for_preview(&MessageClassification::Text, true, false, "sticker"),
            None
        );
        assert_eq!(
            parent_content_for_preview(&MessageClassification::Text, false, true, "photo"),
            None
        );
    }
}

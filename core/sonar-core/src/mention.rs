//! `@name` mentions inside a chat message.
//!
//! Mentions travel as PLAIN TEXT in the kind-9 rumor content — there is no `p`
//! tag and no NIP-27 `nostr:` URI — so a client that knows nothing about
//! mentions (an older Sonar, or White Noise) still renders a readable message.
//! Nothing here touches the wire; this module only parses text that is already
//! there.
//!
//! The grammar is the one bitchat's mesh chat already ships
//! (`@([\p{L}0-9_]+(?:#[a-fA-F0-9]{4})?)`), so folding the mesh onto this
//! scanner preserves its behaviour by construction. The optional `#abcd`
//! suffix is the last 4 hex of the member's public key: it disambiguates two
//! members sharing a display name, and — unlike the bare form — it survives a
//! rename, because it is derived from the key rather than the profile.
//!
//! Like [`crate::marmot::MessageClassification`], this is the *single* decoder:
//! hosts read the verdict rather than re-implementing the scan (see R-017 in
//! `docs/REGRESSIONS.md`). It is pure and synchronous — no I/O, no locks — so
//! it is safe to call from a message-processing path, and hosts memoize it at
//! row-build time so it never runs per rendered frame.

/// One `@mention` found in message content.
///
/// Offsets are **UTF-16 code units**, not bytes: they index a Kotlin `String`
/// natively and convert to a Swift `String.Index` via
/// `String.Index(utf16Offset:in:)`. Byte offsets would be wrong for both hosts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MentionSpan {
    /// Start of the span, at the `@`.
    pub start_utf16: u32,
    /// End of the span, exclusive.
    pub end_utf16: u32,
    /// The name as typed, without the `@` and without any `#abcd` suffix.
    pub name: String,
    /// The 4 hex disambiguator, lowercased, when the mention carried one.
    pub suffix_hex4: Option<String>,
}

/// True when `c` may appear in the name part of a mention. Mirrors the mesh
/// regex's `[\p{L}0-9_]`.
fn is_name_char(c: char) -> bool {
    c.is_alphabetic() || c.is_ascii_digit() || c == '_'
}

/// True when an `@` at this position opens a mention.
///
/// The shipped mesh regex has no left-boundary rule, so it happily matches the
/// `b` in `a@b.com`. We require start-of-string or whitespace, which is what
/// every chat client does and what stops emails and `https://host/@user` from
/// lighting up. The `mention_parity` test on the Swift side pins this as the
/// one intentional divergence from the old regex.
fn opens_mention(prev: Option<char>) -> bool {
    match prev {
        None => true,
        Some(c) => c.is_whitespace(),
    }
}

/// Extract every `@mention` from `content`, in order.
///
/// Returns an empty vec for the overwhelmingly common case of content with no
/// `@` at all, without scanning further.
pub fn parse_mentions(content: &str) -> Vec<MentionSpan> {
    if !content.contains('@') {
        return Vec::new();
    }

    let mut spans = Vec::new();
    // Tracks the UTF-16 offset of the char we are about to inspect, so a span
    // can be reported without re-encoding the prefix.
    let mut utf16_pos: u32 = 0;
    let mut prev: Option<char> = None;
    let mut chars = content.chars().peekable();

    while let Some(c) = chars.next() {
        let c_len = c.len_utf16() as u32;
        if c != '@' || !opens_mention(prev) {
            utf16_pos += c_len;
            prev = Some(c);
            continue;
        }

        let start = utf16_pos;
        let mut cursor = utf16_pos + c_len;
        let mut name = String::new();
        while let Some(&next) = chars.peek() {
            if !is_name_char(next) {
                break;
            }
            chars.next();
            cursor += next.len_utf16() as u32;
            name.push(next);
        }

        if name.is_empty() {
            // A bare `@` is not a mention. `prev` stays `@`, which is not
            // whitespace, so `@@name` cannot open one either.
            utf16_pos = cursor;
            prev = Some('@');
            continue;
        }

        let mut end = cursor;
        let mut suffix_hex4 = None;
        // `#abcd` only counts as a suffix when it is exactly 4 hex digits AND
        // is not followed by another name char — `@bob#abcdef` is a bare `@bob`
        // mention, not a mention with a truncated suffix.
        if chars.peek() == Some(&'#') {
            let mut lookahead = chars.clone();
            lookahead.next();
            let candidate: String = lookahead.by_ref().take(4).collect();
            let complete = candidate.chars().count() == 4
                && candidate.chars().all(|c| c.is_ascii_hexdigit());
            let terminated = lookahead.peek().map_or(true, |&c| !is_name_char(c) && c != '#');
            if complete && terminated {
                for _ in 0..5 {
                    if let Some(taken) = chars.next() {
                        end += taken.len_utf16() as u32;
                    }
                }
                suffix_hex4 = Some(candidate.to_ascii_lowercase());
            }
        }

        // The char preceding the *next* iteration is the last one this span
        // consumed. It is always a name char, a hex digit, or `#` — never
        // whitespace — so a span can never immediately open another mention.
        prev = Some('_');
        utf16_pos = end;
        spans.push(MentionSpan {
            start_utf16: start,
            end_utf16: end,
            name,
            suffix_hex4,
        });
    }

    spans
}

/// True when `content` mentions the identity holding `pubkey_hex`.
///
/// Two forms count:
///
/// 1. `@name#abcd` whose suffix equals the last 4 hex of `pubkey_hex`. This is
///    exact and **rename-proof**, since it is derived from the key.
/// 2. `@name` with no suffix whose name equals `display_name`, case-insensitively.
///    Best-effort: it stops resolving if the user renames after the message was
///    sent. That is the documented cost of keeping the wire plain text.
///
/// `display_name` is passed in rather than read from cached state: the core
/// deliberately caches no local kind-0 profile (see `identity.rs`), and both
/// hosts already hold the user's current nickname.
pub fn mentions_pubkey(content: &str, pubkey_hex: &str, display_name: Option<&str>) -> bool {
    let spans = parse_mentions(content);
    if spans.is_empty() {
        return false;
    }

    let suffix = short_suffix(pubkey_hex);
    let name = display_name
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(str::to_lowercase);

    spans.iter().any(|span| match &span.suffix_hex4 {
        Some(found) => suffix.as_deref() == Some(found.as_str()),
        None => span.name.eq_ignore_ascii_case("everyone")
            || name
                .as_deref()
                .is_some_and(|n| span.name.to_lowercase() == n),
    })
}

/// The `#abcd` disambiguator for a public key: its last 4 hex digits,
/// lowercased. `None` when `pubkey_hex` is not a plausible hex key.
pub fn short_suffix(pubkey_hex: &str) -> Option<String> {
    let hex = pubkey_hex.trim();
    if hex.len() < 4 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(hex[hex.len() - 4..].to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(content: &str) -> Vec<String> {
        parse_mentions(content)
            .into_iter()
            .map(|s| s.name)
            .collect()
    }

    #[test]
    fn plain_content_parses_no_mentions() {
        assert!(parse_mentions("hello there").is_empty());
        assert!(parse_mentions("").is_empty());
    }

    #[test]
    fn parses_bare_and_suffixed_forms() {
        let spans = parse_mentions("hey @vincenzopalazzo and @bob#a1b2 ok");
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].name, "vincenzopalazzo");
        assert_eq!(spans[0].suffix_hex4, None);
        assert_eq!(spans[1].name, "bob");
        assert_eq!(spans[1].suffix_hex4, Some("a1b2".to_string()));
    }

    #[test]
    fn suffix_is_lowercased() {
        let spans = parse_mentions("@bob#A1B2");
        assert_eq!(spans[0].suffix_hex4, Some("a1b2".to_string()));
    }

    #[test]
    fn malformed_suffix_parses_as_bare_mention() {
        // Too short, non-hex, and too long all fall back to a bare mention
        // rather than swallowing the text.
        assert_eq!(parse_mentions("@bob#abc")[0].suffix_hex4, None);
        assert_eq!(parse_mentions("@bob#zzzz")[0].suffix_hex4, None);
        assert_eq!(parse_mentions("@bob#abcdef")[0].suffix_hex4, None);
    }

    #[test]
    fn span_offsets_are_utf16_and_survive_non_bmp_prefix() {
        // A single emoji is 2 UTF-16 code units but 4 UTF-8 bytes; byte offsets
        // would put the span in the wrong place on both hosts.
        let content = "\u{1F680} @bob";
        let spans = parse_mentions(content);
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].start_utf16, 3);
        assert_eq!(spans[0].end_utf16, 7);

        let utf16: Vec<u16> = content.encode_utf16().collect();
        let sliced = String::from_utf16(
            &utf16[spans[0].start_utf16 as usize..spans[0].end_utf16 as usize],
        )
        .unwrap();
        assert_eq!(sliced, "@bob");
    }

    #[test]
    fn emails_and_urls_do_not_open_a_mention() {
        assert!(parse_mentions("mail me at alice@example.com").is_empty());
        assert!(parse_mentions("see https://njump.me/@bob").is_empty());
    }

    #[test]
    fn bare_at_is_not_a_mention() {
        assert!(parse_mentions("@").is_empty());
        assert!(parse_mentions("what @ even").is_empty());
        assert!(parse_mentions("@@bob").is_empty());
    }

    #[test]
    fn non_latin_names_parse() {
        assert_eq!(names("ciao @Виктор"), vec!["Виктор".to_string()]);
        assert_eq!(names("@田中 hi"), vec!["田中".to_string()]);
    }

    #[test]
    fn mention_at_start_of_line_parses() {
        assert_eq!(names("@bob hi"), vec!["bob".to_string()]);
    }

    #[test]
    fn short_suffix_takes_last_four_lowercased() {
        assert_eq!(short_suffix("DEADBEEF"), Some("beef".to_string()));
        assert_eq!(short_suffix("zz"), None);
        assert_eq!(short_suffix("nothex!!"), None);
    }

    #[test]
    fn mentions_pubkey_matches_suffix_form_regardless_of_name() {
        let key = "aabbccddeeff0011";
        // Rename-proof: the name no longer matches, the suffix still does.
        assert!(mentions_pubkey("hi @whoever#0011", key, Some("vincenzo")));
        assert!(mentions_pubkey("hi @whoever#0011", key, None));
    }

    #[test]
    fn mentions_pubkey_matches_bare_name_case_insensitively() {
        let key = "aabbccddeeff0011";
        assert!(mentions_pubkey("hi @Vincenzo", key, Some("vincenzo")));
        assert!(mentions_pubkey("hi @vincenzo", key, Some("Vincenzo")));
    }

    #[test]
    fn mentions_pubkey_rejects_other_people() {
        let key = "aabbccddeeff0011";
        assert!(!mentions_pubkey("hi @bob", key, Some("vincenzo")));
        assert!(!mentions_pubkey("hi @bob#ffff", key, Some("bob")));
        assert!(!mentions_pubkey("no mention here", key, Some("vincenzo")));
    }

    #[test]
    fn mentions_pubkey_without_a_display_name_needs_the_suffix() {
        let key = "aabbccddeeff0011";
        assert!(!mentions_pubkey("hi @vincenzo", key, None));
        assert!(!mentions_pubkey("hi @vincenzo", key, Some("   ")));
    }

    #[test]
    fn everyone_mentions_every_member() {
        let key = "aabbccddeeff0011";
        assert!(mentions_pubkey("hi @everyone", key, Some("vincenzo")));
        assert!(mentions_pubkey("hi @Everyone", key, None));
        // Suffixed form is a person named everyone, not the broadcast.
        assert!(!mentions_pubkey("hi @everyone#ffff", key, Some("vincenzo")));
    }
}

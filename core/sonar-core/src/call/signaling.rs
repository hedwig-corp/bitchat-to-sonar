//! `☎CALL` control protocol — the signaling that sets up a P2P call.
//!
//! A call's media goes over iroh, but the two peers first need to exchange iroh
//! addresses + call metadata. Sonar does that WITHOUT a signaling server by
//! sending these control lines as the *content* of an otherwise normal
//! end-to-end-encrypted message (Marmot/MLS group message or NIP-17 DM) — the
//! same trick the `⚡PAY` feature uses. The host's transcript-scan loop detects
//! a `☎CALL` line, hands it to [`CallControl::parse`], routes it to the call
//! engine, and NEVER renders it as a chat bubble.
//!
//! Wire grammar (pipe-delimited, versioned UTF-8; unknown versions/types parse
//! to `None` so they are silently ignored, never shown):
//!
//! ```text
//! ☎CALL|1|OFFER|<callId>|<voice|video>|<nodeAddrB64>|<unixSecs>
//! ☎CALL|1|ANSWER|<callId>|<accept|decline|busy>|<nodeAddrB64>
//! ☎CALL|1|CANCEL|<callId>
//! ☎CALL|1|END|<callId>|<reason>
//! ```
//!
//! `nodeAddrB64` is the base64url (no-pad) serialization of the sender's iroh
//! `NodeAddr` (node id + relay url + direct addrs); the codec treats it as an
//! opaque token (the engine produces/consumes it). `callId` is a UUID generated
//! by the offerer and correlates every line of one call.

/// Literal prefix every control line starts with (a phone glyph, so it never
/// collides with real chat text or the `⚡PAY` prefix).
pub const CALL_PREFIX: &str = "☎CALL";

/// Protocol version. A line with any other version parses to `None`.
pub const CALL_VERSION: u32 = 1;

/// Voice vs video — drives the call UI; an audio-only build may `decline` video.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallMediaKind {
    Voice,
    Video,
}

impl CallMediaKind {
    fn token(self) -> &'static str {
        match self {
            CallMediaKind::Voice => "voice",
            CallMediaKind::Video => "video",
        }
    }
    fn parse(s: &str) -> Option<Self> {
        match s {
            "voice" => Some(CallMediaKind::Voice),
            "video" => Some(CallMediaKind::Video),
            _ => None,
        }
    }
}

/// The answerer's verdict on an incoming offer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnswerKind {
    Accept,
    Decline,
    /// The answerer is already in another call.
    Busy,
}

impl AnswerKind {
    fn token(self) -> &'static str {
        match self {
            AnswerKind::Accept => "accept",
            AnswerKind::Decline => "decline",
            AnswerKind::Busy => "busy",
        }
    }
    fn parse(s: &str) -> Option<Self> {
        match s {
            "accept" => Some(AnswerKind::Accept),
            "decline" => Some(AnswerKind::Decline),
            "busy" => Some(AnswerKind::Busy),
            _ => None,
        }
    }
}

/// A parsed `☎CALL` control message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallControl {
    /// Caller → callee: "I want to start a call; here's my iroh address."
    Offer {
        call_id: String,
        media: CallMediaKind,
        /// base64url of the offerer's serialized iroh `NodeAddr`.
        node_addr_b64: String,
        /// Offer creation time (epoch secs) — for staleness / missed-call detection.
        unix_secs: u64,
    },
    /// Callee → caller: the verdict (+ the answerer's address on accept).
    Answer {
        call_id: String,
        answer: AnswerKind,
        /// base64url of the answerer's `NodeAddr` (empty for decline/busy).
        node_addr_b64: String,
    },
    /// Caller retracted an offer before it was answered.
    Cancel { call_id: String },
    /// Either side hung up a connected call.
    End { call_id: String, reason: String },
}

impl CallControl {
    /// The call id this control line belongs to (for dedup / correlation).
    pub fn call_id(&self) -> &str {
        match self {
            CallControl::Offer { call_id, .. }
            | CallControl::Answer { call_id, .. }
            | CallControl::Cancel { call_id }
            | CallControl::End { call_id, .. } => call_id,
        }
    }

    /// Serialize to the wire line (the message content to send encrypted).
    pub fn encode(&self) -> String {
        match self {
            CallControl::Offer {
                call_id,
                media,
                node_addr_b64,
                unix_secs,
            } => format!(
                "{CALL_PREFIX}|{CALL_VERSION}|OFFER|{call_id}|{}|{node_addr_b64}|{unix_secs}",
                media.token()
            ),
            CallControl::Answer {
                call_id,
                answer,
                node_addr_b64,
            } => format!(
                "{CALL_PREFIX}|{CALL_VERSION}|ANSWER|{call_id}|{}|{node_addr_b64}",
                answer.token()
            ),
            CallControl::Cancel { call_id } => {
                format!("{CALL_PREFIX}|{CALL_VERSION}|CANCEL|{call_id}")
            }
            CallControl::End { call_id, reason } => {
                format!("{CALL_PREFIX}|{CALL_VERSION}|END|{call_id}|{reason}")
            }
        }
    }

    /// Parse a message's content. Returns `None` for anything that is not a
    /// well-formed current-version `☎CALL` line (so plain chat, `⚡PAY` lines,
    /// future versions, and malformed lines are all silently ignored — they must
    /// never be surfaced as a call).
    pub fn parse(content: &str) -> Option<CallControl> {
        // Tolerate surrounding whitespace; reject multi-line content.
        let line = content.trim();
        if line.contains('\n') {
            return None;
        }
        // Split off the END reason last so a reason may itself contain '|';
        // every other field is '|'-free (UUIDs, fixed tokens, base64url, digits).
        let mut parts = line.splitn(5, '|');
        if parts.next()? != CALL_PREFIX {
            return None;
        }
        if parts.next()?.parse::<u32>().ok()? != CALL_VERSION {
            return None;
        }
        let kind = parts.next()?;
        let rest = parts.next()?; // call_id (+ maybe more, depending on type)
        let tail = parts.next(); // type-specific remainder (may contain '|' for END)

        match kind {
            "OFFER" => {
                // rest = call_id; tail = "<media>|<nodeAddrB64>|<unixSecs>"
                let tail = tail?;
                let mut f = tail.splitn(3, '|');
                let media = CallMediaKind::parse(f.next()?)?;
                let node_addr_b64 = f.next()?.to_string();
                let unix_secs = f.next()?.parse::<u64>().ok()?;
                if rest.is_empty() {
                    return None;
                }
                Some(CallControl::Offer {
                    call_id: rest.to_string(),
                    media,
                    node_addr_b64,
                    unix_secs,
                })
            }
            "ANSWER" => {
                // rest = call_id; tail = "<answer>|<nodeAddrB64>"
                let tail = tail?;
                let mut f = tail.splitn(2, '|');
                let answer = AnswerKind::parse(f.next()?)?;
                let node_addr_b64 = f.next().unwrap_or("").to_string();
                if rest.is_empty() {
                    return None;
                }
                Some(CallControl::Answer {
                    call_id: rest.to_string(),
                    answer,
                    node_addr_b64,
                })
            }
            "CANCEL" => {
                // rest = call_id; there must be no tail.
                if tail.is_some() || rest.is_empty() {
                    return None;
                }
                Some(CallControl::Cancel {
                    call_id: rest.to_string(),
                })
            }
            "END" => {
                // rest = call_id; tail = reason (possibly containing '|', possibly empty).
                if rest.is_empty() {
                    return None;
                }
                Some(CallControl::End {
                    call_id: rest.to_string(),
                    reason: tail.unwrap_or("").to_string(),
                })
            }
            _ => None,
        }
    }

    /// True if `content` looks like a `☎CALL` control line (cheap pre-filter for
    /// the host scan loop before the full [`parse`]).
    pub fn is_control(content: &str) -> bool {
        content.trim_start().starts_with(CALL_PREFIX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(c: CallControl) {
        let encoded = c.encode();
        let parsed = CallControl::parse(&encoded).expect("should parse its own output");
        assert_eq!(parsed, c, "round-trip mismatch for {encoded}");
    }

    #[test]
    fn offer_roundtrip() {
        roundtrip(CallControl::Offer {
            call_id: "abc-123".into(),
            media: CallMediaKind::Video,
            node_addr_b64: "bm9kZS1hZGRy".into(),
            unix_secs: 1_781_000_000,
        });
        roundtrip(CallControl::Offer {
            call_id: "id".into(),
            media: CallMediaKind::Voice,
            node_addr_b64: "QQ".into(),
            unix_secs: 0,
        });
    }

    #[test]
    fn answer_roundtrip() {
        roundtrip(CallControl::Answer {
            call_id: "c1".into(),
            answer: AnswerKind::Accept,
            node_addr_b64: "YWRkcg".into(),
        });
        roundtrip(CallControl::Answer {
            call_id: "c1".into(),
            answer: AnswerKind::Decline,
            node_addr_b64: String::new(),
        });
        roundtrip(CallControl::Answer {
            call_id: "c1".into(),
            answer: AnswerKind::Busy,
            node_addr_b64: String::new(),
        });
    }

    #[test]
    fn cancel_and_end_roundtrip() {
        roundtrip(CallControl::Cancel {
            call_id: "uuid-x".into(),
        });
        roundtrip(CallControl::End {
            call_id: "uuid-x".into(),
            reason: "hangup".into(),
        });
        roundtrip(CallControl::End {
            call_id: "uuid-x".into(),
            reason: String::new(),
        });
    }

    #[test]
    fn end_reason_may_contain_pipes() {
        let c = CallControl::End {
            call_id: "c".into(),
            reason: "network|lost|mid-call".into(),
        };
        roundtrip(c);
    }

    #[test]
    fn rejects_non_call_content() {
        assert!(CallControl::parse("hello world").is_none());
        assert!(CallControl::parse("⚡PAY|1|abc|100").is_none());
        assert!(CallControl::parse("").is_none());
        assert!(CallControl::parse("   ").is_none());
    }

    #[test]
    fn rejects_unknown_version_and_type() {
        assert!(CallControl::parse("☎CALL|2|OFFER|c|voice|addr|1").is_none());
        assert!(CallControl::parse("☎CALL|x|OFFER|c|voice|addr|1").is_none());
        assert!(CallControl::parse("☎CALL|1|RING|c").is_none());
    }

    #[test]
    fn rejects_malformed_fields() {
        // bad media kind
        assert!(CallControl::parse("☎CALL|1|OFFER|c|audio|addr|1").is_none());
        // non-numeric unix secs
        assert!(CallControl::parse("☎CALL|1|OFFER|c|voice|addr|notanumber").is_none());
        // missing fields
        assert!(CallControl::parse("☎CALL|1|OFFER|c|voice").is_none());
        assert!(CallControl::parse("☎CALL|1|ANSWER|c").is_none());
        // empty call id
        assert!(CallControl::parse("☎CALL|1|CANCEL|").is_none());
        // CANCEL must not carry extra fields
        assert!(CallControl::parse("☎CALL|1|CANCEL|c|extra").is_none());
        // bad answer verdict
        assert!(CallControl::parse("☎CALL|1|ANSWER|c|maybe|addr").is_none());
    }

    #[test]
    fn tolerates_surrounding_whitespace_but_not_newlines() {
        assert!(CallControl::parse("  ☎CALL|1|CANCEL|c  ").is_some());
        assert!(CallControl::parse("☎CALL|1|CANCEL|c\nmore").is_none());
    }

    #[test]
    fn is_control_prefilter() {
        assert!(CallControl::is_control("☎CALL|1|END|c|bye"));
        assert!(CallControl::is_control("  ☎CALL|1|END|c|bye"));
        assert!(!CallControl::is_control("hello"));
        assert!(!CallControl::is_control("⚡PAY|1|x"));
    }

    #[test]
    fn call_id_accessor() {
        assert_eq!(
            CallControl::parse("☎CALL|1|END|the-id|bye")
                .unwrap()
                .call_id(),
            "the-id"
        );
    }
}

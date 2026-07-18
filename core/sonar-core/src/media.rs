//! Shared attachment presentation metadata.
//!
//! The encrypted blob remains a standards-compatible media attachment. This
//! role only tells Sonar how to present it; unknown or absent values must fall
//! back to [`MediaRole::Standard`].

/// Presentation role carried alongside an attachment.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MediaRole {
    /// Ordinary image, audio, video, or file attachment.
    #[default]
    Standard,
    /// Short square video rendered with the circular video-note treatment.
    VideoNote,
}
impl MediaRole {
    pub const VIDEO_NOTE_WIRE_VALUE: &'static str = "video_note";

    pub fn from_wire_value(value: &str) -> Self {
        match value {
            Self::VIDEO_NOTE_WIRE_VALUE => Self::VideoNote,
            _ => Self::Standard,
        }
    }

    pub fn wire_value(self) -> Option<&'static str> {
        match self {
            Self::Standard => None,
            Self::VideoNote => Some(Self::VIDEO_NOTE_WIRE_VALUE),
        }
    }
}

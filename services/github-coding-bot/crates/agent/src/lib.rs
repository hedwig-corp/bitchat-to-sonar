//! Bounded tool-calling coding agent and OpenAI-compatible model provider.

mod loop_runner;
mod openai;

pub use loop_runner::*;
pub use openai::*;

use async_trait::async_trait;
use coding_bot_domain::{ModelRequest, ModelResponse};

#[async_trait]
pub trait LanguageModel: Send + Sync {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, ModelError>;
}

#[derive(Debug, thiserror::Error)]
pub enum ModelError {
    #[error("model request failed: {0}")]
    Transport(String),
    #[error("model returned HTTP {0}")]
    Http(u16),
    #[error("model response was invalid: {0}")]
    InvalidResponse(String),
}

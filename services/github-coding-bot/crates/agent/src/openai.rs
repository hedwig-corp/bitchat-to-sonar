use std::time::Duration;

use async_trait::async_trait;
use coding_bot_domain::{MessageRole, ModelMessage, ModelRequest, ModelResponse, ModelToolCall};
use reqwest::StatusCode;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::Url;

use crate::{LanguageModel, ModelError};

pub struct OpenAiCompatibleModel {
    client: reqwest::Client,
    endpoint: Url,
    api_key: SecretString,
    model: String,
    max_retries: u32,
}

impl OpenAiCompatibleModel {
    pub fn new(
        base_url: &Url,
        api_key: String,
        model: String,
        max_retries: u32,
        request_timeout: Duration,
    ) -> Result<Self, ModelError> {
        let normalized = format!("{}/", base_url.as_str().trim_end_matches('/'));
        let base = Url::parse(&normalized)
            .map_err(|error| ModelError::InvalidResponse(error.to_string()))?;
        let endpoint = base
            .join("chat/completions")
            .map_err(|error| ModelError::InvalidResponse(error.to_string()))?;
        let client = reqwest::Client::builder()
            .timeout(request_timeout)
            .build()
            .map_err(|error| ModelError::Transport(error.to_string()))?;
        Ok(Self {
            client,
            endpoint,
            api_key: SecretString::from(api_key),
            model,
            max_retries,
        })
    }

    async fn request_once(&self, request: &ModelRequest) -> Result<ModelResponse, AttemptError> {
        let wire_request = ChatRequest {
            model: &self.model,
            messages: request.messages.iter().map(ChatMessage::from).collect(),
            tools: request
                .tools
                .iter()
                .map(|tool| ChatTool {
                    kind: "function",
                    function: ChatFunctionDefinition {
                        name: &tool.name,
                        description: &tool.description,
                        parameters: &tool.parameters,
                    },
                })
                .collect(),
            max_tokens: request.max_output_tokens,
        };

        let response = self
            .client
            .post(self.endpoint.clone())
            .bearer_auth(self.api_key.expose_secret())
            .json(&wire_request)
            .send()
            .await
            .map_err(AttemptError::Transport)?;
        let status = response.status();
        if !status.is_success() {
            return Err(AttemptError::Status(status));
        }
        let response: ChatResponse = response.json().await.map_err(AttemptError::Transport)?;
        let choice = response
            .choices
            .into_iter()
            .next()
            .ok_or_else(|| AttemptError::Invalid("missing choices[0]".to_owned()))?;
        let mut tool_calls = Vec::with_capacity(choice.message.tool_calls.len());
        for call in choice.message.tool_calls {
            let arguments =
                serde_json::from_str::<Value>(&call.function.arguments).map_err(|error| {
                    AttemptError::Invalid(format!("invalid tool arguments: {error}"))
                })?;
            tool_calls.push(ModelToolCall {
                id: call.id,
                name: call.function.name,
                arguments,
            });
        }
        let usage = response.usage.unwrap_or_default();
        Ok(ModelResponse {
            content: choice.message.content,
            tool_calls,
            input_tokens: usage.prompt_tokens,
            output_tokens: usage.completion_tokens,
        })
    }
}

#[async_trait]
impl LanguageModel for OpenAiCompatibleModel {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, ModelError> {
        let mut attempt = 0_u32;
        loop {
            match self.request_once(&request).await {
                Ok(response) => return Ok(response),
                Err(error) if error.retryable() && attempt < self.max_retries => {
                    attempt += 1;
                    let exponent = attempt.saturating_sub(1).min(10);
                    let delay = Duration::from_millis(250 * (1_u64 << exponent));
                    tokio::time::sleep(delay).await;
                }
                Err(AttemptError::Status(status)) => return Err(ModelError::Http(status.as_u16())),
                Err(AttemptError::Transport(error)) => {
                    return Err(ModelError::Transport(error.to_string()))
                }
                Err(AttemptError::Invalid(reason)) => {
                    return Err(ModelError::InvalidResponse(reason))
                }
            }
        }
    }
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    tools: Vec<ChatTool<'a>>,
    max_tokens: u32,
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'static str,
    content: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_call_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tool_calls: Vec<ChatToolCallOut<'a>>,
}

impl<'a> From<&'a ModelMessage> for ChatMessage<'a> {
    fn from(message: &'a ModelMessage) -> Self {
        Self {
            role: match message.role {
                MessageRole::System => "system",
                MessageRole::User => "user",
                MessageRole::Assistant => "assistant",
                MessageRole::Tool => "tool",
            },
            content: &message.content,
            tool_call_id: message.tool_call_id.as_deref(),
            tool_calls: message
                .tool_calls
                .iter()
                .map(|call| ChatToolCallOut {
                    id: &call.id,
                    kind: "function",
                    function: ChatFunctionCallOut {
                        name: &call.name,
                        arguments: call.arguments.to_string(),
                    },
                })
                .collect(),
        }
    }
}

#[derive(Serialize)]
struct ChatTool<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    function: ChatFunctionDefinition<'a>,
}

#[derive(Serialize)]
struct ChatFunctionDefinition<'a> {
    name: &'a str,
    description: &'a str,
    parameters: &'a Value,
}

#[derive(Serialize)]
struct ChatToolCallOut<'a> {
    id: &'a str,
    #[serde(rename = "type")]
    kind: &'static str,
    function: ChatFunctionCallOut<'a>,
}

#[derive(Serialize)]
struct ChatFunctionCallOut<'a> {
    name: &'a str,
    arguments: String,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
    usage: Option<ChatUsage>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatMessageIn,
}

#[derive(Deserialize)]
struct ChatMessageIn {
    content: Option<String>,
    #[serde(default)]
    tool_calls: Vec<ChatToolCallIn>,
}

#[derive(Deserialize)]
struct ChatToolCallIn {
    id: String,
    function: ChatFunctionCallIn,
}

#[derive(Deserialize)]
struct ChatFunctionCallIn {
    name: String,
    arguments: String,
}

#[derive(Default, Deserialize)]
struct ChatUsage {
    #[serde(default)]
    prompt_tokens: u64,
    #[serde(default)]
    completion_tokens: u64,
}

enum AttemptError {
    Status(StatusCode),
    Transport(reqwest::Error),
    Invalid(String),
}

impl AttemptError {
    fn retryable(&self) -> bool {
        match self {
            Self::Status(status) => {
                *status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error()
            }
            Self::Transport(error) => error.is_connect() || error.is_timeout(),
            Self::Invalid(_) => false,
        }
    }
}

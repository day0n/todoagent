use std::collections::BTreeMap;
use std::time::Duration;

use reqwest::header::HeaderValue;
use reqwest::{Client, StatusCode, Url};
use serde::Serialize;
use serde_json::{Map, Value};
use thiserror::Error;
use tokio::time::{sleep, timeout};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

use super::types::{
    AssembledStep, InteractionProvider, InteractionRequest, InteractionResponse, ProviderEvent,
    ProviderEventSink, TerminalStatus, object_with_type,
};

const DEFAULT_ENDPOINT: &str =
    "https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_RETRIES: usize = 2;
const RETRY_BASE_DELAY_MS: u64 = 400;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RetryClass {
    Transient,
    Permanent,
}

#[derive(Debug, Error)]
pub enum ProviderError {
    #[error("provider request was cancelled")]
    Cancelled,
    #[error("provider request exceeded 45 seconds")]
    Timeout,
    #[error("provider HTTP {status}: {message}")]
    Http {
        status: u16,
        message: String,
        retry: RetryClass,
    },
    #[error("provider network error: {message}")]
    Network { message: String, retry: RetryClass },
    #[error("invalid provider stream: {0}")]
    Protocol(String),
    #[error("provider stream ended before interaction.completed")]
    MissingTerminal,
    #[error("provider interaction failed ({code}): {message}")]
    Remote {
        code: String,
        message: String,
        retry: RetryClass,
    },
}

impl ProviderError {
    pub fn retry_class(&self) -> RetryClass {
        match self {
            Self::Timeout | Self::MissingTerminal => RetryClass::Transient,
            Self::Http { retry, .. } | Self::Network { retry, .. } | Self::Remote { retry, .. } => {
                *retry
            }
            Self::Cancelled | Self::Protocol(_) => RetryClass::Permanent,
        }
    }

    pub fn classify_status(status: StatusCode) -> RetryClass {
        if status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error() {
            RetryClass::Transient
        } else {
            RetryClass::Permanent
        }
    }
}

/// Direct Gemini Interactions API provider. It intentionally keeps no
/// server-side conversation state: every request is `store=false` and carries
/// the locally selected transcript, including thought signatures.
pub struct GeminiInteractionsProvider {
    client: Client,
    endpoint: Url,
    api_key: Zeroizing<String>,
    request_timeout: Duration,
    max_retries: usize,
}

impl GeminiInteractionsProvider {
    pub fn new(api_key: impl Into<String>) -> Result<Self, ProviderError> {
        Self::with_endpoint(api_key, DEFAULT_ENDPOINT)
    }

    /// Exposed for a local mock server. Production should use [`Self::new`].
    pub fn with_endpoint(
        api_key: impl Into<String>,
        endpoint: impl AsRef<str>,
    ) -> Result<Self, ProviderError> {
        let api_key = api_key.into();
        if api_key.trim().is_empty() {
            return Err(ProviderError::Http {
                status: 401,
                message: "Gemini API key is empty".to_owned(),
                retry: RetryClass::Permanent,
            });
        }
        let endpoint = Url::parse(endpoint.as_ref())
            .map_err(|error| ProviderError::Protocol(format!("invalid endpoint: {error}")))?;
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| ProviderError::Protocol(error.to_string()))?;
        Ok(Self {
            client,
            endpoint,
            api_key: Zeroizing::new(api_key),
            request_timeout: REQUEST_TIMEOUT,
            max_retries: MAX_RETRIES,
        })
    }

    async fn send_once(
        &self,
        request: &InteractionRequest,
        attempt: usize,
        cancellation: &CancellationToken,
        sink: &mut dyn ProviderEventSink,
    ) -> Result<InteractionResponse, ProviderError> {
        let body = WireRequest {
            model: &request.model,
            input: &request.input,
            system_instruction: request.system_instruction.as_deref(),
            tools: &request.tools,
            stream: true,
            store: false,
            generation_config: GenerationConfig {
                thinking_level: "minimal",
                max_output_tokens: 8_192,
            },
        };

        let mut api_key = HeaderValue::from_str(self.api_key.as_str()).map_err(|_| {
            ProviderError::Protocol("Gemini API key is not a valid HTTP header value".to_owned())
        })?;
        api_key.set_sensitive(true);
        let mut response = tokio::select! {
            _ = cancellation.cancelled() => return Err(ProviderError::Cancelled),
            result = self.client
                .post(self.endpoint.clone())
                .header("x-goog-api-key", api_key)
                .header("accept", "text/event-stream")
                .json(&body)
                .send() => result.map_err(network_error)?,
        };

        if !response.status().is_success() {
            let status = response.status();
            let message = response
                .text()
                .await
                .map(|text| sanitize_provider_message(&text))
                .unwrap_or_else(|error| error.to_string());
            let message = redact_secret(message, self.api_key.as_str());
            return Err(ProviderError::Http {
                status: status.as_u16(),
                message,
                retry: ProviderError::classify_status(status),
            });
        }

        let mut assembler = InteractionsSseAssembler::new(attempt);
        loop {
            let chunk = tokio::select! {
                _ = cancellation.cancelled() => return Err(ProviderError::Cancelled),
                chunk = response.chunk() => chunk.map_err(network_error)?,
            };
            let Some(chunk) = chunk else { break };
            for event in assembler.push_chunk(&chunk)? {
                sink.on_event(event);
            }
        }
        for event in assembler.finish_stream()? {
            sink.on_event(event);
        }
        assembler.complete()
    }
}

impl InteractionProvider for GeminiInteractionsProvider {
    async fn interact<'a>(
        &'a self,
        request: &'a InteractionRequest,
        cancellation: &'a CancellationToken,
        sink: &'a mut dyn ProviderEventSink,
    ) -> Result<InteractionResponse, ProviderError> {
        for retry_index in 0..=self.max_retries {
            let attempt = retry_index + 1;
            sink.on_event(ProviderEvent::AttemptStarted { attempt });
            let result = tokio::select! {
                _ = cancellation.cancelled() => Err(ProviderError::Cancelled),
                result = timeout(
                    self.request_timeout,
                    self.send_once(request, attempt, cancellation, sink),
                ) => result.unwrap_or(Err(ProviderError::Timeout)),
            }
            .map_err(|error| redact_provider_error(error, self.api_key.as_str()));

            match result {
                Ok(response) => return Ok(response),
                Err(error)
                    if error.retry_class() == RetryClass::Transient
                        && retry_index < self.max_retries =>
                {
                    sink.on_event(ProviderEvent::AttemptDiscarded {
                        attempt,
                        reason: error.to_string(),
                    });
                    let delay_ms = RETRY_BASE_DELAY_MS.saturating_mul(1_u64 << retry_index);
                    sink.on_event(ProviderEvent::Retrying {
                        next_attempt: attempt + 1,
                        delay_ms,
                    });
                    tokio::select! {
                        _ = cancellation.cancelled() => return Err(ProviderError::Cancelled),
                        _ = sleep(Duration::from_millis(delay_ms)) => {}
                    }
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!("retry loop always returns")
    }
}

#[derive(Serialize)]
struct WireRequest<'a> {
    model: &'a str,
    input: &'a [Value],
    #[serde(skip_serializing_if = "Option::is_none")]
    system_instruction: Option<&'a str>,
    tools: &'a [super::ToolDefinition],
    stream: bool,
    store: bool,
    generation_config: GenerationConfig,
}

#[derive(Serialize)]
struct GenerationConfig {
    thinking_level: &'static str,
    max_output_tokens: usize,
}

fn network_error(error: reqwest::Error) -> ProviderError {
    let retry = if error.is_connect() || error.is_timeout() || error.is_request() || error.is_body()
    {
        RetryClass::Transient
    } else {
        RetryClass::Permanent
    };
    tracing::warn!(error = ?error, "Gemini network request failed");
    ProviderError::Network {
        message: error.to_string(),
        retry,
    }
}

fn sanitize_provider_message(text: &str) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    compact.chars().take(2_000).collect()
}

fn redact_secret(message: String, secret: &str) -> String {
    if secret.is_empty() || !message.contains(secret) {
        message
    } else {
        message.replace(secret, "[REDACTED]")
    }
}

/// Provider failures can originate in HTTP bodies, network diagnostics, or SSE
/// terminal events. Redact at the provider boundary so retry events, persisted
/// turn errors, and UI messages can never receive the in-memory credential.
fn redact_provider_error(error: ProviderError, secret: &str) -> ProviderError {
    match error {
        ProviderError::Http {
            status,
            message,
            retry,
        } => ProviderError::Http {
            status,
            message: redact_secret(message, secret),
            retry,
        },
        ProviderError::Network { message, retry } => ProviderError::Network {
            message: redact_secret(message, secret),
            retry,
        },
        ProviderError::Protocol(message) => ProviderError::Protocol(redact_secret(message, secret)),
        ProviderError::Remote {
            code,
            message,
            retry,
        } => ProviderError::Remote {
            code: redact_secret(code, secret),
            message: redact_secret(message, secret),
            retry,
        },
        other => other,
    }
}

#[derive(Default)]
struct SseDecoder {
    buffer: Vec<u8>,
}

impl SseDecoder {
    fn push(&mut self, bytes: &[u8]) -> Result<Vec<SseFrame>, ProviderError> {
        self.buffer.extend_from_slice(bytes);
        self.drain(false)
    }

    fn finish(&mut self) -> Result<Vec<SseFrame>, ProviderError> {
        self.drain(true)
    }

    fn drain(&mut self, finish: bool) -> Result<Vec<SseFrame>, ProviderError> {
        let mut frames = Vec::new();
        while let Some((at, delimiter_len)) = frame_boundary(&self.buffer) {
            let raw = self.buffer.drain(..at).collect::<Vec<_>>();
            self.buffer.drain(..delimiter_len);
            if let Some(frame) = parse_frame(&raw)? {
                frames.push(frame);
            }
        }
        if finish && self.buffer.iter().any(|byte| !byte.is_ascii_whitespace()) {
            let raw = std::mem::take(&mut self.buffer);
            if let Some(frame) = parse_frame(&raw)? {
                frames.push(frame);
            }
        }
        Ok(frames)
    }
}

fn frame_boundary(bytes: &[u8]) -> Option<(usize, usize)> {
    let lf = bytes
        .windows(2)
        .position(|window| window == b"\n\n")
        .map(|at| (at, 2));
    let crlf = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|at| (at, 4));
    match (lf, crlf) {
        (Some(left), Some(right)) => Some(if left.0 <= right.0 { left } else { right }),
        (Some(found), None) | (None, Some(found)) => Some(found),
        (None, None) => None,
    }
}

struct SseFrame {
    event: Option<String>,
    data: String,
}

fn parse_frame(raw: &[u8]) -> Result<Option<SseFrame>, ProviderError> {
    let text = std::str::from_utf8(raw)
        .map_err(|error| ProviderError::Protocol(format!("SSE was not UTF-8: {error}")))?;
    let mut event = None;
    let mut data = Vec::new();
    for line in text.lines().map(|line| line.trim_end_matches('\r')) {
        if line.starts_with(':') {
            continue;
        }
        if let Some(value) = line.strip_prefix("event:") {
            event = Some(value.trim_start().to_owned());
        } else if let Some(value) = line.strip_prefix("data:") {
            data.push(value.trim_start());
        }
    }
    if data.is_empty() {
        return Ok(None);
    }
    Ok(Some(SseFrame {
        event,
        data: data.join("\n"),
    }))
}

struct StepBuilder {
    payload: Map<String, Value>,
    raw_deltas: Vec<Value>,
    arguments_text: Option<String>,
    stopped: bool,
}

impl StepBuilder {
    fn new(step: Value) -> Result<Self, ProviderError> {
        let payload = step.as_object().cloned().ok_or_else(|| {
            ProviderError::Protocol("step.start.step must be an object".to_owned())
        })?;
        let arguments_text = match payload.get("arguments") {
            Some(Value::String(text)) if !text.is_empty() => Some(text.clone()),
            Some(Value::Object(object)) if !object.is_empty() => {
                Some(serde_json::to_string(object).unwrap_or_default())
            }
            _ => None,
        };
        Ok(Self {
            payload,
            raw_deltas: Vec::new(),
            arguments_text,
            stopped: false,
        })
    }

    fn apply_delta(&mut self, delta: Value) -> Result<Option<DeltaSignal>, ProviderError> {
        let delta_type = delta
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let signal = match delta_type {
            "text" => {
                let text = delta
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                append_text(&mut self.payload, "content", text);
                (!text.is_empty()).then(|| DeltaSignal::Text(text.to_owned()))
            }
            "arguments" | "arguments_delta" => {
                let partial = delta
                    .get("partial_arguments")
                    .or_else(|| delta.get("arguments_delta"))
                    .or_else(|| delta.get("arguments"))
                    .or_else(|| delta.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                self.arguments_text
                    .get_or_insert_with(String::new)
                    .push_str(partial);
                None
            }
            "thought_signature" => {
                let signature = delta
                    .get("signature")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                self.payload
                    .insert("signature".to_owned(), Value::String(signature.clone()));
                (!signature.is_empty()).then_some(DeltaSignal::ThoughtSignature(signature))
            }
            "thought_summary" => {
                let content = delta
                    .get("content")
                    .cloned()
                    .or_else(|| {
                        delta.get("text").and_then(Value::as_str).map(|text| {
                            let mut content = object_with_type("text");
                            content.insert("text".to_owned(), Value::String(text.to_owned()));
                            Value::Object(content)
                        })
                    })
                    .unwrap_or(Value::Null);
                if !content.is_null() {
                    append_value(&mut self.payload, "summary", content.clone());
                    Some(DeltaSignal::ThoughtSummary(content))
                } else {
                    None
                }
            }
            _ => None,
        };
        self.raw_deltas.push(delta);
        Ok(signal)
    }

    fn initial_signals(&self) -> Vec<DeltaSignal> {
        let mut signals = Vec::new();
        match self.payload.get("type").and_then(Value::as_str) {
            Some("model_output") => {
                let text = self
                    .payload
                    .get("content")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter(|item| item.get("type").and_then(Value::as_str) == Some("text"))
                    .filter_map(|item| item.get("text").and_then(Value::as_str))
                    .collect::<String>();
                if !text.is_empty() {
                    signals.push(DeltaSignal::Text(text));
                }
            }
            Some("thought") => {
                if let Some(signature) = self
                    .payload
                    .get("signature")
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                {
                    signals.push(DeltaSignal::ThoughtSignature(signature.to_owned()));
                }
                if let Some(summary) = self.payload.get("summary").and_then(Value::as_array) {
                    signals.extend(summary.iter().cloned().map(DeltaSignal::ThoughtSummary));
                }
            }
            _ => {}
        }
        signals
    }

    fn stop(&mut self, full_step: Option<&Value>) -> Result<(), ProviderError> {
        if self.stopped {
            return Err(ProviderError::Protocol("duplicate step.stop".to_owned()));
        }
        if let Some(full) = full_step {
            let full = full.as_object().ok_or_else(|| {
                ProviderError::Protocol("step.stop.step must be an object".to_owned())
            })?;
            for (key, value) in full {
                self.payload.insert(key.clone(), value.clone());
            }
        }
        if let Some(arguments) = self.arguments_text.take() {
            let value =
                serde_json::from_str::<Value>(&arguments).unwrap_or(Value::String(arguments));
            self.payload.insert("arguments".to_owned(), value);
        }
        self.stopped = true;
        Ok(())
    }
}

enum DeltaSignal {
    Text(String),
    ThoughtSummary(Value),
    ThoughtSignature(String),
}

fn append_text(payload: &mut Map<String, Value>, field: &str, text: &str) {
    if text.is_empty() {
        return;
    }
    let values = payload
        .entry(field.to_owned())
        .or_insert_with(|| Value::Array(Vec::new()));
    let Some(values) = values.as_array_mut() else {
        return;
    };
    if let Some(last) = values.last_mut().and_then(Value::as_object_mut)
        && last.get("type").and_then(Value::as_str) == Some("text")
        && let Some(existing) = last.get_mut("text").and_then(|value| value.as_str())
    {
        let mut combined = existing.to_owned();
        combined.push_str(text);
        last.insert("text".to_owned(), Value::String(combined));
        return;
    }
    values.push(Value::Object({
        let mut item = object_with_type("text");
        item.insert("text".to_owned(), Value::String(text.to_owned()));
        item
    }));
}

fn append_value(payload: &mut Map<String, Value>, field: &str, value: Value) {
    if let Some(values) = payload
        .entry(field.to_owned())
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
    {
        values.push(value);
    }
}

/// Incremental SSE parser and step assembler. It never exposes assembled steps
/// until an `interaction.completed` terminal event has been validated.
pub struct InteractionsSseAssembler {
    attempt: usize,
    decoder: SseDecoder,
    steps: BTreeMap<usize, StepBuilder>,
    terminal_interaction: Option<Value>,
    terminal_status: Option<TerminalStatus>,
    interaction_id: Option<String>,
}

impl InteractionsSseAssembler {
    pub fn new(attempt: usize) -> Self {
        Self {
            attempt,
            decoder: SseDecoder::default(),
            steps: BTreeMap::new(),
            terminal_interaction: None,
            terminal_status: None,
            interaction_id: None,
        }
    }

    pub fn push_chunk(&mut self, bytes: &[u8]) -> Result<Vec<ProviderEvent>, ProviderError> {
        let frames = self.decoder.push(bytes)?;
        self.process_frames(frames)
    }

    pub fn finish_stream(&mut self) -> Result<Vec<ProviderEvent>, ProviderError> {
        let frames = match self.decoder.finish() {
            Ok(frames) => frames,
            // A clean EOF can still cut through the middle of one SSE JSON
            // object. Treat that as an interrupted attempt so it receives the
            // same bounded retry policy as a body read error. A malformed frame
            // that had its delimiter is rejected earlier by `push_chunk`.
            Err(_) if self.terminal_interaction.is_none() => {
                return Err(ProviderError::MissingTerminal);
            }
            Err(error) => return Err(error),
        };
        self.process_frames(frames)
    }

    fn process_frames(
        &mut self,
        frames: Vec<SseFrame>,
    ) -> Result<Vec<ProviderEvent>, ProviderError> {
        let mut events = Vec::new();
        for frame in frames {
            if frame.data.trim() == "[DONE]" {
                continue;
            }
            let value: Value = serde_json::from_str(&frame.data)
                .map_err(|error| ProviderError::Protocol(format!("invalid SSE JSON: {error}")))?;
            let event_type = value
                .get("event_type")
                .or_else(|| value.get("type"))
                .and_then(Value::as_str)
                .or(frame.event.as_deref())
                .unwrap_or_default();

            match event_type {
                "interaction.created" => {
                    if let Some(interaction) = value.get("interaction") {
                        self.capture_interaction_id(interaction);
                    }
                }
                "step.start" => {
                    let index = event_index(&value)?;
                    if self.steps.contains_key(&index) {
                        return Err(ProviderError::Protocol(format!(
                            "duplicate step.start index {index}"
                        )));
                    }
                    let step = value.get("step").cloned().ok_or_else(|| {
                        ProviderError::Protocol("step.start missing step".to_owned())
                    })?;
                    let builder = StepBuilder::new(step)?;
                    let kind = builder
                        .payload
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    events.push(ProviderEvent::StepStarted {
                        attempt: self.attempt,
                        index,
                        kind,
                    });
                    for signal in builder.initial_signals() {
                        match signal {
                            DeltaSignal::Text(text) => events.push(ProviderEvent::TextDelta {
                                attempt: self.attempt,
                                index,
                                text,
                            }),
                            DeltaSignal::ThoughtSummary(content) => {
                                events.push(ProviderEvent::ThoughtSummaryDelta {
                                    attempt: self.attempt,
                                    index,
                                    content,
                                });
                            }
                            DeltaSignal::ThoughtSignature(signature) => {
                                events.push(ProviderEvent::ThoughtSignature {
                                    attempt: self.attempt,
                                    index,
                                    signature,
                                });
                            }
                        }
                    }
                    self.steps.insert(index, builder);
                }
                "step.delta" => {
                    let index = event_index(&value)?;
                    let delta = value.get("delta").cloned().ok_or_else(|| {
                        ProviderError::Protocol("step.delta missing delta".to_owned())
                    })?;
                    let builder = self.steps.get_mut(&index).ok_or_else(|| {
                        ProviderError::Protocol(format!("step.delta before step.start at {index}"))
                    })?;
                    match builder.apply_delta(delta)? {
                        Some(DeltaSignal::Text(text)) => events.push(ProviderEvent::TextDelta {
                            attempt: self.attempt,
                            index,
                            text,
                        }),
                        Some(DeltaSignal::ThoughtSummary(content)) => {
                            events.push(ProviderEvent::ThoughtSummaryDelta {
                                attempt: self.attempt,
                                index,
                                content,
                            });
                        }
                        Some(DeltaSignal::ThoughtSignature(signature)) => {
                            events.push(ProviderEvent::ThoughtSignature {
                                attempt: self.attempt,
                                index,
                                signature,
                            });
                        }
                        None => {}
                    }
                }
                "step.stop" => {
                    let index = event_index(&value)?;
                    let builder = self.steps.get_mut(&index).ok_or_else(|| {
                        ProviderError::Protocol(format!("step.stop before step.start at {index}"))
                    })?;
                    builder.stop(value.get("step"))?;
                    events.push(ProviderEvent::StepStopped {
                        attempt: self.attempt,
                        index,
                    });
                }
                "interaction.completed" => {
                    if self.terminal_interaction.is_some() {
                        return Err(ProviderError::Protocol(
                            "duplicate interaction.completed".to_owned(),
                        ));
                    }
                    let interaction = value.get("interaction").cloned().ok_or_else(|| {
                        ProviderError::Protocol(
                            "interaction.completed missing interaction".to_owned(),
                        )
                    })?;
                    self.capture_interaction_id(&interaction);
                    let status = match interaction.get("status").and_then(Value::as_str) {
                        Some("completed") => TerminalStatus::Completed,
                        // The event itself is still the official completed
                        // terminal; requires_action is the documented status
                        // when client-side function calls must be answered.
                        Some("requires_action") => TerminalStatus::RequiresAction,
                        Some(other) => {
                            return Err(ProviderError::Protocol(format!(
                                "illegal terminal interaction status {other}"
                            )));
                        }
                        None => {
                            return Err(ProviderError::Protocol(
                                "terminal interaction missing status".to_owned(),
                            ));
                        }
                    };
                    self.terminal_status = Some(status);
                    self.terminal_interaction = Some(interaction);
                }
                "interaction.failed" | "error" => return Err(remote_stream_error(&value)),
                _ => {
                    // The Interactions API is additive. Unknown event/delta
                    // types are intentionally ignored and the full known step
                    // payload is still retained.
                }
            }
        }
        Ok(events)
    }

    fn capture_interaction_id(&mut self, interaction: &Value) {
        if let Some(id) = interaction.get("id").and_then(Value::as_str) {
            self.interaction_id = Some(id.to_owned());
        }
    }

    pub fn complete(self) -> Result<InteractionResponse, ProviderError> {
        let interaction = self
            .terminal_interaction
            .ok_or(ProviderError::MissingTerminal)?;
        let status = self.terminal_status.ok_or(ProviderError::MissingTerminal)?;
        let interaction_id = self.interaction_id.ok_or_else(|| {
            ProviderError::Protocol("completed interaction missing id".to_owned())
        })?;

        if let Some((index, _)) = self.steps.iter().find(|(_, step)| !step.stopped) {
            return Err(ProviderError::Protocol(format!(
                "interaction completed before step.stop at index {index}"
            )));
        }

        let steps = self
            .steps
            .into_iter()
            .map(|(index, step)| AssembledStep {
                index: Some(index),
                payload: Value::Object(step.payload),
                raw_deltas: step.raw_deltas,
            })
            .collect::<Vec<_>>();
        let has_calls = steps
            .iter()
            .any(|step| step.kind() == Some("function_call"));
        // Gemini 3.6 currently returns a valid `interaction.completed` event
        // with status=`completed` even when the completed steps contain a
        // client-side function call. Older/documented streams may instead use
        // status=`requires_action`. The fully stopped function_call steps are
        // the executable authority; the redundant terminal status must not
        // prevent a valid call from reaching the AgentRunner.
        //
        // A requires_action terminal with no function call is still malformed:
        // there is nothing the client can execute to make progress.
        if status == TerminalStatus::RequiresAction && !has_calls {
            return Err(ProviderError::Protocol(
                "requires_action terminal is missing function-call steps".to_owned(),
            ));
        }
        let usage = interaction.get("usage").cloned().unwrap_or(Value::Null);
        Ok(InteractionResponse {
            interaction_id,
            status,
            steps,
            usage,
            interaction,
        })
    }
}

fn event_index(value: &Value) -> Result<usize, ProviderError> {
    value
        .get("index")
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .ok_or_else(|| ProviderError::Protocol("step event missing valid index".to_owned()))
}

fn remote_stream_error(value: &Value) -> ProviderError {
    let error = value.get("error").unwrap_or(value);
    let code_value = error
        .get("status")
        .or_else(|| error.get("code"))
        .or_else(|| value.get("code"));
    let code = code_value
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            code_value
                .and_then(Value::as_u64)
                .map(|value| value.to_string())
        })
        .unwrap_or_else(|| "unknown".to_owned());
    let normalized = code.to_ascii_lowercase().replace('-', "_");
    let retry = if matches!(
        normalized.as_str(),
        "gateway_timeout"
            | "deadline_exceeded"
            | "service_unavailable"
            | "internal"
            | "resource_exhausted"
            | "429"
            | "500"
            | "502"
            | "503"
            | "504"
    ) {
        RetryClass::Transient
    } else {
        RetryClass::Permanent
    };
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .map(sanitize_provider_message)
        .unwrap_or_else(|| sanitize_provider_message(&value.to_string()));
    ProviderError::Remote {
        code,
        message,
        retry,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(event: &str, value: Value) -> String {
        format!("event: {event}\ndata: {value}\n\n")
    }

    #[test]
    fn wire_request_is_stateless_private_and_bounded() {
        let input = vec![serde_json::json!({"type":"user_input","content":[]})];
        let tools = vec![super::super::ToolDefinition::function(
            "list_state",
            "read current task state",
            serde_json::json!({"type":"object"}),
        )];
        let wire = WireRequest {
            model: "gemini-3.6-flash",
            input: &input,
            system_instruction: Some("system"),
            tools: &tools,
            stream: true,
            store: false,
            generation_config: GenerationConfig {
                thinking_level: "minimal",
                max_output_tokens: 8_192,
            },
        };
        let value = serde_json::to_value(wire).unwrap();

        assert_eq!(value["stream"], true);
        assert_eq!(value["store"], false);
        assert_eq!(value["generation_config"]["thinking_level"], "minimal");
        assert_eq!(value["generation_config"]["max_output_tokens"], 8_192);
        assert!(value.get("previous_interaction_id").is_none());
    }

    #[test]
    fn assembles_fragmented_arguments_across_arbitrary_chunks() {
        let stream = [
            frame(
                "interaction.created",
                serde_json::json!({"event_type":"interaction.created","interaction":{"id":"i1","status":"in_progress"}}),
            ),
            frame(
                "step.start",
                serde_json::json!({"event_type":"step.start","index":0,"step":{"type":"function_call","id":"c1","name":"create_tasks","arguments":{}}}),
            ),
            frame(
                "step.delta",
                serde_json::json!({"event_type":"step.delta","index":0,"delta":{"type":"arguments_delta","partial_arguments":"{\"tasks\":[{\"title\":\"买"}}),
            ),
            frame(
                "step.delta",
                serde_json::json!({"event_type":"step.delta","index":0,"delta":{"type":"arguments","partial_arguments":"猫粮\"}]}"}}),
            ),
            frame(
                "step.stop",
                serde_json::json!({"event_type":"step.stop","index":0}),
            ),
            frame(
                "interaction.completed",
                serde_json::json!({"event_type":"interaction.completed","interaction":{"id":"i1","status":"requires_action","usage":{"total_tokens":12}}}),
            ),
            "event: done\ndata: [DONE]\n\n".to_owned(),
        ]
        .concat();
        let bytes = stream.as_bytes();
        let mut assembler = InteractionsSseAssembler::new(1);
        for chunk in bytes.chunks(7) {
            assembler.push_chunk(chunk).unwrap();
        }
        assembler.finish_stream().unwrap();
        let response = assembler.complete().unwrap();
        let call = response.steps[0].function_call().unwrap();

        assert_eq!(call.id, "c1");
        assert_eq!(call.arguments_error, None);
        assert_eq!(call.arguments["tasks"][0]["title"], "买猫粮");
    }

    #[test]
    fn completed_terminal_with_function_call_matches_live_gemini_streams() {
        let stream = [
            frame(
                "interaction.created",
                serde_json::json!({"event_type":"interaction.created","interaction":{"id":"","status":"in_progress"}}),
            ),
            frame(
                "step.start",
                serde_json::json!({"event_type":"step.start","index":0,"step":{"type":"function_call","id":"live-call","name":"create_tasks","arguments":{}}}),
            ),
            frame(
                "step.delta",
                serde_json::json!({"event_type":"step.delta","index":0,"delta":{"type":"arguments_delta","arguments":"{\"tasks\":[{\"title\":\"今天要健身\"}]}"}}),
            ),
            frame(
                "step.stop",
                serde_json::json!({"event_type":"step.stop","index":0}),
            ),
            frame(
                "interaction.completed",
                serde_json::json!({"event_type":"interaction.completed","interaction":{"id":"","status":"completed"}}),
            ),
            "event: done\ndata: [DONE]\n\n".to_owned(),
        ]
        .concat();
        let mut assembler = InteractionsSseAssembler::new(1);

        assembler.push_chunk(stream.as_bytes()).unwrap();
        assembler.finish_stream().unwrap();
        let response = assembler.complete().unwrap();
        let call = response.steps[0].function_call().unwrap();

        assert_eq!(response.status, TerminalStatus::Completed);
        assert_eq!(call.name, "create_tasks");
        assert_eq!(call.arguments["tasks"][0]["title"], "今天要健身");
    }

    #[test]
    fn requires_action_without_a_function_call_is_rejected() {
        let stream = [
            frame(
                "interaction.created",
                serde_json::json!({"event_type":"interaction.created","interaction":{"id":"i-bad","status":"in_progress"}}),
            ),
            frame(
                "step.start",
                serde_json::json!({"event_type":"step.start","index":0,"step":{"type":"model_output","content":[{"type":"text","text":"无法继续"}]}}),
            ),
            frame(
                "step.stop",
                serde_json::json!({"event_type":"step.stop","index":0}),
            ),
            frame(
                "interaction.completed",
                serde_json::json!({"event_type":"interaction.completed","interaction":{"id":"i-bad","status":"requires_action"}}),
            ),
        ]
        .concat();
        let mut assembler = InteractionsSseAssembler::new(1);

        assembler.push_chunk(stream.as_bytes()).unwrap();
        let error = assembler.complete().unwrap_err();

        assert!(matches!(
            error,
            ProviderError::Protocol(message)
                if message == "requires_action terminal is missing function-call steps"
        ));
    }

    #[test]
    fn step_start_text_is_streamed_before_later_deltas() {
        let stream = [
            frame(
                "interaction.created",
                serde_json::json!({"event_type":"interaction.created","interaction":{"id":"i-start","status":"in_progress"}}),
            ),
            frame(
                "step.start",
                serde_json::json!({"event_type":"step.start","index":0,"step":{"type":"model_output","content":[{"type":"text","text":"Hello "}]}}),
            ),
            frame(
                "step.delta",
                serde_json::json!({"event_type":"step.delta","index":0,"delta":{"type":"text","text":"world"}}),
            ),
            frame(
                "step.stop",
                serde_json::json!({"event_type":"step.stop","index":0}),
            ),
            frame(
                "interaction.completed",
                serde_json::json!({"event_type":"interaction.completed","interaction":{"id":"i-start","status":"completed"}}),
            ),
        ]
        .concat();
        let mut assembler = InteractionsSseAssembler::new(1);
        let events = assembler.push_chunk(stream.as_bytes()).unwrap();
        let deltas = events
            .into_iter()
            .filter_map(|event| match event {
                ProviderEvent::TextDelta { text, .. } => Some(text),
                _ => None,
            })
            .collect::<Vec<_>>();
        let response = assembler.complete().unwrap();

        assert_eq!(deltas, ["Hello ", "world"]);
        assert_eq!(response.steps[0].model_text(), "Hello world");
    }

    #[test]
    fn missing_completed_terminal_discards_assembled_steps() {
        let mut assembler = InteractionsSseAssembler::new(2);
        assembler
            .push_chunk(
                frame(
                    "step.start",
                    serde_json::json!({"event_type":"step.start","index":0,"step":{"type":"model_output"}}),
                )
                .as_bytes(),
            )
            .unwrap();
        assembler
            .push_chunk(
                frame(
                    "step.stop",
                    serde_json::json!({"event_type":"step.stop","index":0}),
                )
                .as_bytes(),
            )
            .unwrap();

        assert!(matches!(
            assembler.complete(),
            Err(ProviderError::MissingTerminal)
        ));
    }

    #[test]
    fn thought_signature_survives_assembly_and_stateless_round_trip() {
        let mut assembler = InteractionsSseAssembler::new(1);
        let stream = [
            frame(
                "interaction.created",
                serde_json::json!({"event_type":"interaction.created","interaction":{"id":"i2","status":"in_progress"}}),
            ),
            frame(
                "step.start",
                serde_json::json!({"event_type":"step.start","index":0,"step":{"type":"thought"}}),
            ),
            frame(
                "step.delta",
                serde_json::json!({"event_type":"step.delta","index":0,"delta":{"type":"thought_signature","signature":"signed-state"}}),
            ),
            frame(
                "step.stop",
                serde_json::json!({"event_type":"step.stop","index":0}),
            ),
            frame(
                "step.start",
                serde_json::json!({"event_type":"step.start","index":1,"step":{"type":"model_output"}}),
            ),
            frame(
                "step.delta",
                serde_json::json!({"event_type":"step.delta","index":1,"delta":{"type":"text","text":"完成"}}),
            ),
            frame(
                "step.stop",
                serde_json::json!({"event_type":"step.stop","index":1}),
            ),
            frame(
                "interaction.completed",
                serde_json::json!({"event_type":"interaction.completed","interaction":{"id":"i2","status":"completed"}}),
            ),
        ]
        .concat();
        assembler.push_chunk(stream.as_bytes()).unwrap();
        let response = assembler.complete().unwrap();
        let input = response
            .steps
            .iter()
            .map(|step| step.payload.clone())
            .collect::<Vec<_>>();

        assert_eq!(response.steps[0].thought_signature(), Some("signed-state"));
        assert_eq!(input[0]["signature"], "signed-state");
    }

    #[test]
    fn retries_only_documented_transient_classes() {
        assert_eq!(
            ProviderError::classify_status(StatusCode::TOO_MANY_REQUESTS),
            RetryClass::Transient
        );
        assert_eq!(
            ProviderError::classify_status(StatusCode::BAD_GATEWAY),
            RetryClass::Transient
        );
        assert_eq!(
            ProviderError::classify_status(StatusCode::UNAUTHORIZED),
            RetryClass::Permanent
        );
        assert_eq!(
            ProviderError::classify_status(StatusCode::BAD_REQUEST),
            RetryClass::Permanent
        );
        assert_eq!(
            remote_stream_error(&serde_json::json!({
                "error": {"status":"RESOURCE_EXHAUSTED","message":"slow down"}
            }))
            .retry_class(),
            RetryClass::Transient
        );
        assert_eq!(
            remote_stream_error(&serde_json::json!({
                "error": {"status":"INVALID_ARGUMENT","message":"bad schema"}
            }))
            .retry_class(),
            RetryClass::Permanent
        );
    }

    #[test]
    fn provider_errors_redact_an_echoed_api_key() {
        let key = "private-gemini-key";
        let redacted = redact_secret(format!("provider rejected {key}"), key);
        assert_eq!(redacted, "provider rejected [REDACTED]");
        assert!(!redacted.contains(key));
    }

    #[test]
    fn streamed_remote_errors_are_redacted_before_the_provider_returns_them() {
        let key = "private-stream-key";
        let mut assembler = InteractionsSseAssembler::new(1);
        let wire = frame(
            "error",
            serde_json::json!({
                "event_type":"error",
                "error": {
                    "status":"INVALID_ARGUMENT",
                    "message": format!("credential {key} was rejected")
                }
            }),
        );
        let error = assembler.push_chunk(wire.as_bytes()).unwrap_err();
        let redacted = redact_provider_error(error, key).to_string();

        assert!(redacted.contains("[REDACTED]"));
        assert!(!redacted.contains(key));
    }
}

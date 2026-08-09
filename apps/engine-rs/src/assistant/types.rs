use std::collections::{HashMap, HashSet};
use std::future::Future;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use thiserror::Error;
use tokio_util::sync::CancellationToken;

/// One client-side function exposed to Gemini.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ToolDefinition {
    #[serde(rename = "type")]
    pub kind: String,
    pub name: String,
    pub description: String,
    pub parameters: Value,
}

impl ToolDefinition {
    pub fn function(
        name: impl Into<String>,
        description: impl Into<String>,
        parameters: Value,
    ) -> Self {
        Self {
            kind: "function".to_owned(),
            name: name.into(),
            description: description.into(),
            parameters,
        }
    }
}

pub const ALLOWED_ASSISTANT_TOOLS: [&str; 5] = [
    "create_tasks",
    "find_related",
    "update_task",
    "list_state",
    "list_lists",
];

#[derive(Clone, Debug)]
pub struct ToolRegistry {
    definitions: Vec<ToolDefinition>,
    by_name: HashMap<String, usize>,
}

impl ToolRegistry {
    pub fn new(definitions: Vec<ToolDefinition>) -> Result<Self, ToolRegistryError> {
        let allowed = ALLOWED_ASSISTANT_TOOLS.into_iter().collect::<HashSet<_>>();
        let mut by_name = HashMap::new();
        for (index, definition) in definitions.iter().enumerate() {
            if definition.kind != "function" {
                return Err(ToolRegistryError::InvalidKind(definition.name.clone()));
            }
            if !allowed.contains(definition.name.as_str()) {
                return Err(ToolRegistryError::NotAllowed(definition.name.clone()));
            }
            if by_name.insert(definition.name.clone(), index).is_some() {
                return Err(ToolRegistryError::Duplicate(definition.name.clone()));
            }
        }
        Ok(Self {
            definitions,
            by_name,
        })
    }

    pub fn contains(&self, name: &str) -> bool {
        self.by_name.contains_key(name)
    }

    pub fn declarations(&self) -> &[ToolDefinition] {
        &self.definitions
    }
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum ToolRegistryError {
    #[error("assistant tool is not allowed: {0}")]
    NotAllowed(String),
    #[error("assistant tool must have type=function: {0}")]
    InvalidKind(String),
    #[error("assistant tool is declared more than once: {0}")]
    Duplicate(String),
}

/// Stateless input for one Gemini Interactions request.
///
/// `input` contains API-native steps (`user_input`, `model_output`,
/// `function_call`, `function_result`, `thought`). The provider always forces
/// `store=false` and therefore sends the complete selected context each time.
#[derive(Clone, Debug, PartialEq)]
pub struct InteractionRequest {
    pub model: String,
    pub input: Vec<Value>,
    pub system_instruction: Option<String>,
    pub tools: Vec<ToolDefinition>,
}

/// A fully assembled step, plus the original deltas retained for diagnostics.
/// Only `payload` is sent back as model input.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AssembledStep {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index: Option<usize>,
    pub payload: Value,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub raw_deltas: Vec<Value>,
}

impl AssembledStep {
    pub fn kind(&self) -> Option<&str> {
        self.payload.get("type").and_then(Value::as_str)
    }

    pub fn model_text(&self) -> String {
        if self.kind() != Some("model_output") {
            return String::new();
        }
        self.payload
            .get("content")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|item| item.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|item| item.get("text").and_then(Value::as_str))
            .collect()
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn thought_signature(&self) -> Option<&str> {
        (self.kind() == Some("thought"))
            .then(|| self.payload.get("signature").and_then(Value::as_str))
            .flatten()
    }

    pub fn function_call(&self) -> Option<FunctionCall> {
        if self.kind() != Some("function_call") {
            return None;
        }
        let id = self
            .payload
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let name = self
            .payload
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let raw = self
            .payload
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| json!({}));
        let (arguments, arguments_error) = match raw {
            Value::String(text) => match serde_json::from_str::<Value>(&text) {
                Ok(value) => (value, None),
                Err(error) => (Value::String(text), Some(error.to_string())),
            },
            value @ Value::Object(_) => (value, None),
            value => (
                value,
                Some("function arguments must be a JSON object".to_owned()),
            ),
        };
        Some(FunctionCall {
            id,
            name,
            arguments,
            arguments_error,
        })
    }

    pub fn from_payload(payload: Value) -> Self {
        Self {
            index: None,
            payload,
            raw_deltas: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FunctionCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
    pub arguments_error: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TerminalStatus {
    Completed,
    RequiresAction,
}

impl TerminalStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::RequiresAction => "requires_action",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct InteractionResponse {
    pub interaction_id: String,
    pub status: TerminalStatus,
    pub steps: Vec<AssembledStep>,
    #[serde(default)]
    pub usage: Value,
    /// The complete terminal interaction object for forward-compatible storage.
    pub interaction: Value,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ProviderEvent {
    AttemptStarted {
        attempt: usize,
    },
    AttemptDiscarded {
        attempt: usize,
        reason: String,
    },
    Retrying {
        next_attempt: usize,
        delay_ms: u64,
    },
    StepStarted {
        attempt: usize,
        index: usize,
        kind: String,
    },
    TextDelta {
        attempt: usize,
        index: usize,
        text: String,
    },
    ThoughtSummaryDelta {
        attempt: usize,
        index: usize,
        content: Value,
    },
    ThoughtSignature {
        attempt: usize,
        index: usize,
        signature: String,
    },
    StepStopped {
        attempt: usize,
        index: usize,
    },
}

pub trait ProviderEventSink: Send {
    fn on_event(&mut self, event: ProviderEvent);
}

impl<F> ProviderEventSink for F
where
    F: FnMut(ProviderEvent) + Send,
{
    fn on_event(&mut self, event: ProviderEvent) {
        self(event);
    }
}

/// Provider abstraction used by the loop and by deterministic offline tests.
pub trait InteractionProvider: Send + Sync {
    fn interact<'a>(
        &'a self,
        request: &'a InteractionRequest,
        cancellation: &'a CancellationToken,
        sink: &'a mut dyn ProviderEventSink,
    ) -> impl Future<Output = Result<InteractionResponse, crate::assistant::ProviderError>> + Send + 'a;
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ContextSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default)]
    pub turns: Vec<StoredTurn>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StoredTurn {
    pub turn_id: String,
    /// API-native interaction steps in chronological order.
    pub steps: Vec<Value>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContextPlan {
    pub input: Vec<Value>,
    pub estimated_tokens: usize,
    pub compaction: Option<CompactionRequest>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompactionRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_summary: Option<String>,
    pub turns_to_summarize: Vec<StoredTurn>,
    pub turns_to_keep: Vec<StoredTurn>,
    pub target_tokens: usize,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompactionResult {
    pub summary: String,
    #[serde(default)]
    pub estimated_tokens: usize,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PersistSteps {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interaction_id: Option<String>,
    pub status: String,
    pub steps: Vec<AssembledStep>,
    #[serde(default)]
    pub usage: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ToolRequest {
    pub session_id: String,
    pub turn_id: String,
    pub call_id: String,
    pub name: String,
    pub arguments: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ToolReceipt {
    pub call_id: String,
    pub name: String,
    pub result: Value,
    #[serde(default)]
    pub is_error: bool,
}

impl ToolReceipt {
    pub fn as_step(&self) -> AssembledStep {
        AssembledStep::from_payload(json!({
            "type": "function_result",
            "call_id": self.call_id,
            "name": self.name,
            "result": self.result,
            "is_error": self.is_error,
        }))
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ToolErrorKind {
    UnknownTool,
    InvalidArguments,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Error, Serialize, Deserialize, PartialEq, Eq)]
#[error("{message}")]
pub struct ToolError {
    pub kind: ToolErrorKind,
    pub message: String,
}

#[derive(Clone, Debug, Error, Serialize, Deserialize, PartialEq, Eq)]
#[error("{code}: {message}")]
pub struct HostError {
    pub code: String,
    pub message: String,
}

impl HostError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentEvent {
    Status {
        phase: String,
        detail: Option<String>,
    },
    DraftReset {
        attempt: usize,
        reason: String,
    },
    Delta {
        attempt: usize,
        text: String,
    },
    ThoughtSummary {
        attempt: usize,
        content: Value,
    },
    ToolStarted {
        call_id: String,
        name: String,
    },
    ToolFinished {
        call_id: String,
        name: String,
        is_error: bool,
    },
    Final {
        text: String,
    },
    Failed {
        code: String,
        message: String,
    },
}

/// Boundary implemented by the engine service. All methods that can touch
/// SQLite remain here instead of leaking into the model/provider layer.
pub trait AssistantHost: Send + Sync {
    fn load_context<'a>(
        &'a self,
        session_id: &'a str,
    ) -> impl Future<Output = Result<ContextSnapshot, HostError>> + Send + 'a;

    /// Persist a provider-completed batch atomically. The runner never calls
    /// this for a truncated SSE attempt.
    fn persist_steps<'a>(
        &'a self,
        session_id: &'a str,
        turn_id: &'a str,
        batch: PersistSteps,
    ) -> impl Future<Output = Result<(), HostError>> + Send + 'a;

    fn lookup_receipt<'a>(
        &'a self,
        session_id: &'a str,
        call_id: &'a str,
    ) -> impl Future<Output = Result<Option<ToolReceipt>, HostError>> + Send + 'a;

    /// The Store adapter should transactionally couple a mutating tool's side
    /// effect and receipt whenever possible. Lookup/save in the runner prevents
    /// ordinary retries; the transaction closes the process-crash window.
    fn save_receipt<'a>(
        &'a self,
        session_id: &'a str,
        turn_id: &'a str,
        receipt: &'a ToolReceipt,
    ) -> impl Future<Output = Result<(), HostError>> + Send + 'a;

    /// Execute at most once for `request.call_id` and durably return its
    /// receipt. For mutating tools the Store implementation must commit the
    /// mutation and receipt in the same SQLite transaction. This is the
    /// crash-safe authority; the runner's lookup is only a fast path.
    fn execute_named_tool_once<'a>(
        &'a self,
        request: ToolRequest,
        cancellation: &'a CancellationToken,
    ) -> impl Future<Output = Result<ToolReceipt, ToolError>> + Send + 'a;

    fn append_final<'a>(
        &'a self,
        session_id: &'a str,
        turn_id: &'a str,
        text: &'a str,
    ) -> impl Future<Output = Result<(), HostError>> + Send + 'a;

    /// Generate and persist a new cumulative summary. Failure is deliberately
    /// non-destructive: the runner continues with the old snapshot.
    fn compact_context<'a>(
        &'a self,
        session_id: &'a str,
        request: CompactionRequest,
        cancellation: &'a CancellationToken,
    ) -> impl Future<Output = Result<CompactionResult, HostError>> + Send + 'a;

    /// Synchronous by design: the concrete engine can enqueue this into its
    /// existing bounded NDJSON writer without blocking the model loop.
    fn emit(&self, session_id: &str, turn_id: &str, event: AgentEvent);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RunLimits {
    pub wall_time_seconds: u64,
    pub request_time_seconds: u64,
    pub max_model_interactions: usize,
    pub max_tool_calls: usize,
    pub max_network_retries: usize,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RunLimitKind {
    ModelInteractions,
    ToolCalls,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AgentRunRequest {
    pub session_id: String,
    pub turn_id: String,
    pub model: String,
    pub system_instruction: Option<String>,
    pub tools: Vec<ToolDefinition>,
    /// One or more API-native input steps for the new user turn.
    pub input: Vec<Value>,
}

impl AgentRunRequest {
    #[cfg(test)]
    pub fn text(
        session_id: impl Into<String>,
        turn_id: impl Into<String>,
        model: impl Into<String>,
        text: impl Into<String>,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            turn_id: turn_id.into(),
            model: model.into(),
            system_instruction: None,
            tools: Vec::new(),
            input: vec![json!({
                "type": "user_input",
                "content": [{"type": "text", "text": text.into()}],
            })],
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentRunResult {
    pub final_text: String,
    pub model_interactions: usize,
    pub tool_calls: usize,
}

#[derive(Debug, Error)]
pub enum AssistantError {
    #[error("assistant run was cancelled")]
    Cancelled,
    #[error("assistant run exceeded its 120 second wall clock")]
    WallTimeout,
    #[error("assistant limit reached: {kind:?}")]
    Limit { kind: RunLimitKind },
    #[error("host error: {0}")]
    Host(#[from] HostError),
    #[error("provider error: {0}")]
    Provider(#[from] crate::assistant::ProviderError),
    #[error("tool registry error: {0}")]
    Registry(#[from] ToolRegistryError),
    #[error("provider completed without model output or function calls")]
    EmptyResponse,
}

pub(crate) fn object_with_type(kind: &str) -> Map<String, Value> {
    let mut object = Map::new();
    object.insert("type".to_owned(), Value::String(kind.to_owned()));
    object
}

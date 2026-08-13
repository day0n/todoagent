use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct List {
    pub id: String,
    pub name: String,
    pub color: String,
    pub repository_path: Option<String>,
    pub archived_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TaskStatus {
    Open,
    Completed,
}

impl TaskStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Completed => "completed",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "open" => Some(Self::Open),
            "completed" => Some(Self::Completed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    pub id: String,
    pub list_id: Option<String>,
    pub title: String,
    pub note: String,
    pub status: TaskStatus,
    pub execution_date: Option<String>,
    pub due_date: Option<String>,
    pub completed_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TaskAttachment {
    pub id: String,
    pub task_id: String,
    pub original_name: String,
    pub size_bytes: i64,
    pub mime_type: String,
    pub relative_path: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeKind {
    Codex,
    Claude,
    Cursor,
    Kiro,
}

impl RuntimeKind {
    pub const ALL: [Self; 4] = [Self::Codex, Self::Claude, Self::Cursor, Self::Kiro];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
            Self::Cursor => "cursor",
            Self::Kiro => "kiro",
        }
    }

    pub fn executable_name(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
            Self::Cursor => "cursor-agent",
            Self::Kiro => "kiro-cli",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "codex" => Some(Self::Codex),
            "claude" => Some(Self::Claude),
            "cursor" => Some(Self::Cursor),
            "kiro" => Some(Self::Kiro),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Runtime {
    pub kind: RuntimeKind,
    pub launch_path: Option<String>,
    pub resolved_path: Option<String>,
    pub version: Option<String>,
    pub status: String,
    pub auth_status: String,
    pub capabilities: serde_json::Value,
    pub provider_engine: Option<String>,
    pub detected_at: Option<String>,
    pub verified_at: Option<String>,
    pub verify_error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderBindingState {
    Unbound,
    Bound,
    CaptureFailed,
}

impl ProviderBindingState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unbound => "unbound",
            Self::Bound => "bound",
            Self::CaptureFailed => "capture_failed",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "unbound" => Some(Self::Unbound),
            "bound" => Some(Self::Bound),
            "capture_failed" => Some(Self::CaptureFailed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TerminalAgentStatus {
    Unknown,
    Idle,
    Active,
    Blocked,
    Completed,
}

impl TerminalAgentStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Idle => "idle",
            Self::Active => "active",
            Self::Blocked => "blocked",
            Self::Completed => "completed",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "unknown" => Some(Self::Unknown),
            "idle" => Some(Self::Idle),
            "active" => Some(Self::Active),
            "blocked" => Some(Self::Blocked),
            "completed" => Some(Self::Completed),
            _ => None,
        }
    }

    pub fn creates_attention(self) -> bool {
        matches!(self, Self::Blocked | Self::Completed)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TerminalRunState {
    Starting,
    Running,
    Stopping,
    Exited,
    Failed,
    Interrupted,
}

impl TerminalRunState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Stopping => "stopping",
            Self::Exited => "exited",
            Self::Failed => "failed",
            Self::Interrupted => "interrupted",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "starting" => Some(Self::Starting),
            "running" => Some(Self::Running),
            "stopping" => Some(Self::Stopping),
            "exited" => Some(Self::Exited),
            "failed" => Some(Self::Failed),
            "interrupted" => Some(Self::Interrupted),
            _ => None,
        }
    }

    pub fn is_active(self) -> bool {
        matches!(self, Self::Starting | Self::Running | Self::Stopping)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TerminalLaunchMode {
    Fresh,
    Resume,
}

impl TerminalLaunchMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fresh => "fresh",
            Self::Resume => "resume",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "fresh" => Some(Self::Fresh),
            "resume" => Some(Self::Resume),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSession {
    pub id: String,
    pub task_id: String,
    pub runtime_kind: RuntimeKind,
    pub working_directory: String,
    pub provider_session_id: Option<String>,
    pub provider_binding_state: ProviderBindingState,
    pub provider_binding_source: Option<String>,
    pub agent_status: TerminalAgentStatus,
    /// Process lifecycle is intentionally independent from provider hook
    /// attention. Kiro, and providers whose hooks are disabled, can be
    /// running while `agent_status` remains `unknown`.
    pub has_active_run: bool,
    pub status_sequence: i64,
    pub seen_status_sequence: i64,
    pub last_error_code: Option<String>,
    pub last_error_message: Option<String>,
    pub last_started_at: Option<String>,
    pub last_exited_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalResumeCandidate {
    pub provider_session_id: String,
    pub source: String,
    pub created_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalResumeCandidates {
    pub session: TerminalSession,
    pub candidates: Vec<TerminalResumeCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalRun {
    pub id: String,
    pub session_id: String,
    pub ordinal: i64,
    pub launch_mode: TerminalLaunchMode,
    pub state: TerminalRunState,
    pub provider_session_id_at_launch: Option<String>,
    pub exit_code: Option<i32>,
    pub exit_reason: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub started_at: Option<String>,
    pub exited_at: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSessionBundle {
    pub session: TerminalSession,
    pub active_run: Option<TerminalRun>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalLaunchPlan {
    pub session: TerminalSession,
    pub run: TerminalRun,
    pub executable: String,
    pub arguments: Vec<String>,
    pub working_directory: String,
    pub environment: BTreeMap<String, String>,
    pub capture_strategy: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bootstrap {
    pub revision: i64,
    pub lists: Vec<List>,
    pub tasks: Vec<Task>,
    pub task_attachments: Vec<TaskAttachment>,
    pub runtimes: Vec<Runtime>,
    pub sessions: Vec<TerminalSession>,
}

/// Provider-neutral Chat V2 item. Provider call/result frames are paired into
/// one stable tool item, while text and reasoning retain their original turn
/// position instead of being collapsed into a single final message.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionTimelineItem {
    pub id: String,
    pub session_id: String,
    pub turn_id: String,
    pub sequence: i64,
    pub turn_ordinal: i64,
    pub item_ordinal: i64,
    pub kind: String,
    pub body: String,
    pub call_id: Option<String>,
    pub tool_name: Option<String>,
    pub input_json: Option<String>,
    pub output_text: Option<String>,
    pub tool_state: Option<String>,
    pub is_error: bool,
    pub source_event_sequence: Option<i64>,
    pub source_block_index: Option<i64>,
    pub fidelity: String,
    pub metadata_json: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

/// A persistent conversational session owned by the TodoAgent assistant.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantSession {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub archived_at: Option<String>,
    pub last_sequence: i64,
    pub is_running: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AssistantTurnStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
    Interrupted,
}

impl AssistantTurnStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Interrupted => "interrupted",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "queued" => Some(Self::Queued),
            "running" => Some(Self::Running),
            "completed" => Some(Self::Completed),
            "failed" => Some(Self::Failed),
            "cancelled" => Some(Self::Cancelled),
            "interrupted" => Some(Self::Interrupted),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantTurn {
    pub id: String,
    pub session_id: String,
    pub ordinal: i64,
    pub user_message_id: String,
    pub model_id: Option<String>,
    pub attempt_count: i64,
    pub status: AssistantTurnStatus,
    pub final_output: Option<String>,
    pub usage_json: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantMessage {
    pub id: String,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub sequence: i64,
    pub client_message_id: Option<String>,
    pub role: String,
    pub kind: String,
    pub body: String,
    pub payload_json: Option<String>,
    pub task_refs_json: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantStep {
    pub id: String,
    pub session_id: String,
    pub turn_id: String,
    pub sequence: i64,
    pub interaction_ordinal: i64,
    pub provider_step_index: Option<i64>,
    pub kind: String,
    pub status: String,
    pub title: Option<String>,
    pub payload_json: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantToolExecution {
    pub id: String,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub step_id: Option<String>,
    pub call_id: String,
    pub tool_name: String,
    pub request_json: String,
    pub response_json: Option<String>,
    pub task_refs_json: Option<String>,
    pub is_error: bool,
    pub status: String,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

/// Bounded tool-card projection returned to the SwiftUI message timeline.
/// Provider request/response payloads remain private to model context storage.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantToolSummary {
    pub id: String,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub call_id: String,
    pub tool_name: String,
    pub task_refs_json: Option<String>,
    pub is_error: bool,
    pub status: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantToolResult {
    pub result_json: String,
    pub is_error: bool,
    pub task_refs_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantCompaction {
    pub session_id: String,
    pub through_sequence: i64,
    pub summary: String,
    pub payload_json: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantHistory {
    pub session: AssistantSession,
    pub messages: Vec<AssistantMessage>,
    #[serde(default)]
    pub tools: Vec<AssistantToolSummary>,
    /// Provider-neutral ordered parts for the TodoAgent conversation. Thought
    /// items contain provider-exposed summaries only; signatures and raw
    /// provider payloads never cross this UI boundary.
    #[serde(default)]
    pub timeline: Vec<SessionTimelineItem>,
    pub active_turn: Option<AssistantTurn>,
    pub compaction: Option<AssistantCompaction>,
}

/// Persistence projection used exclusively to rebuild Gemini's stateless input.
///
/// Provider steps deliberately do not share the user-visible message cursor, so
/// they must never be loaded as a side effect of rendering chat history.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantContextHistory {
    pub messages: Vec<AssistantMessage>,
    pub steps: Vec<AssistantStep>,
    pub active_turn: Option<AssistantTurn>,
    pub compaction: Option<AssistantCompaction>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct QueuedAssistantTurn {
    pub session: AssistantSession,
    pub turn: AssistantTurn,
    pub message: AssistantMessage,
    pub is_new: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CreateTaskInput {
    pub title: String,
    #[serde(default)]
    pub note: String,
    pub list_id: Option<String>,
    pub execution_date: Option<String>,
    pub due_date: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateTaskInput {
    pub title: Option<String>,
    pub note: Option<String>,
    pub status: Option<TaskStatus>,
    #[serde(default, deserialize_with = "deserialize_present_uuid_option")]
    pub list_id: Option<Option<String>>,
    #[serde(default, deserialize_with = "deserialize_present_option")]
    pub execution_date: Option<Option<String>>,
    #[serde(default, deserialize_with = "deserialize_present_option")]
    pub due_date: Option<Option<String>>,
}

fn deserialize_present_option<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

fn deserialize_present_uuid_option<'de, D>(
    deserializer: D,
) -> Result<Option<Option<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<String>::deserialize(deserializer)?;
    value
        .map(|value| {
            uuid::Uuid::parse_str(&value)
                .map(|value| value.to_string())
                .map_err(serde::de::Error::custom)
        })
        .transpose()
        .map(Some)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TaskState {
    pub revision: i64,
    pub lists: Vec<List>,
    pub tasks: Vec<Task>,
}

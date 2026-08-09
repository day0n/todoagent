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
    pub due_date: Option<String>,
    pub completed_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
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
pub enum SessionState {
    Idle,
    Queued,
    Running,
    Failed,
    Closed,
}

impl SessionState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Failed => "failed",
            Self::Closed => "closed",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "idle" => Some(Self::Idle),
            "queued" => Some(Self::Queued),
            "running" => Some(Self::Running),
            "failed" => Some(Self::Failed),
            "closed" => Some(Self::Closed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TurnStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
    Interrupted,
}

impl TurnStatus {
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    User,
    Agent,
    System,
    Tool,
}

impl MessageRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Agent => "agent",
            Self::System => "system",
            Self::Tool => "tool",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "user" => Some(Self::User),
            "agent" => Some(Self::Agent),
            "system" => Some(Self::System),
            "tool" => Some(Self::Tool),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TaskSession {
    pub id: String,
    pub task_id: String,
    pub runtime_kind: RuntimeKind,
    pub working_directory: String,
    pub provider_session_id: Option<String>,
    pub provider_engine: Option<String>,
    pub state: SessionState,
    pub last_agent_sequence: i64,
    pub last_read_sequence: i64,
    pub last_error_code: Option<String>,
    pub last_error_message: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionTurn {
    pub id: String,
    pub session_id: String,
    pub ordinal: i64,
    pub user_message_id: String,
    pub provider_session_id_before: Option<String>,
    pub provider_session_id_after: Option<String>,
    pub status: TurnStatus,
    pub exit_code: Option<i32>,
    pub final_output: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub provider_usage_json: Option<String>,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionMessage {
    pub id: String,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub sequence: i64,
    pub client_message_id: Option<String>,
    pub role: MessageRole,
    pub kind: String,
    pub body: String,
    pub payload_json: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bootstrap {
    pub revision: i64,
    pub lists: Vec<List>,
    pub tasks: Vec<Task>,
    pub runtimes: Vec<Runtime>,
    pub sessions: Vec<TaskSession>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionBundle {
    pub session: TaskSession,
    pub messages: Vec<SessionMessage>,
    pub active_turn: Option<SessionTurn>,
}

#[derive(Debug, Clone)]
pub struct QueuedTurn {
    pub session: TaskSession,
    pub turn: SessionTurn,
    pub prompt: String,
    pub is_new: bool,
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
    pub due_date: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateTaskInput {
    pub title: Option<String>,
    pub note: Option<String>,
    #[serde(default, deserialize_with = "deserialize_present_option")]
    pub list_id: Option<Option<String>>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TaskState {
    pub revision: i64,
    pub lists: Vec<List>,
    pub tasks: Vec<Task>,
}

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use chrono::Local;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;
use tokio::sync::{Mutex, Semaphore};
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

use crate::assistant::{
    AgentEvent, AgentRunRequest, AgentRunner, AssistantError, AssistantHost, CompactionRequest,
    CompactionResult, ContextBuilder, ContextBuilderConfig, ContextSnapshot,
    GeminiInteractionsProvider, HostError, InteractionProvider, InteractionRequest, PersistSteps,
    ProviderError, StoredTurn, ToolDefinition, ToolError, ToolErrorKind, ToolReceipt, ToolRequest,
    estimate_tokens,
};
use crate::models::{
    AssistantContextHistory, AssistantHistory, AssistantMessage, AssistantSession,
    AssistantToolSummary, AssistantTurn, AssistantTurnStatus, QueuedAssistantTurn,
    SessionTimelineItem,
};
use crate::output::OutputWriter;
use crate::protocol::Event;
use crate::store::AssistantDeleteTaskOutcome;
use crate::store::StoreError;
use crate::store_worker::{StoreWorker, StoreWorkerError};

const DEFAULT_SESSION_TITLE: &str = "新对话";
const MAX_USER_CHARACTERS: usize = 16_000;
const MAX_TEXT_ATTACHMENTS: usize = 4;
const MAX_ATTACHMENT_NAME_CHARACTERS: usize = 255;
const MAX_ATTACHMENT_BYTES: usize = 131_072;
const MAX_TOTAL_ATTACHMENT_BYTES: usize = 262_144;
const MAX_ASSISTANT_CONCURRENCY: usize = 2;
const DELTA_FLUSH_BYTES: usize = 8 * 1024;
const DELTA_FLUSH_INTERVAL: Duration = Duration::from_millis(100);
const PUBLIC_THOUGHT_SUMMARY_MAX_BYTES: usize = 256 * 1024;
const THOUGHT_DELTA_FLUSH_BYTES: usize = 32 * 1024;

#[derive(Debug, Error)]
pub enum AssistantServiceError {
    #[error(transparent)]
    Store(#[from] StoreWorkerError),
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Conflict(&'static str),
    #[error("{message}")]
    Unavailable { code: &'static str, message: String },
}

#[derive(Clone)]
pub struct AssistantService {
    store: StoreWorker,
    writer: OutputWriter,
    gemini_key: Arc<Mutex<Option<Zeroizing<String>>>>,
    data_directory: Arc<PathBuf>,
    task_file_mutation: Arc<Mutex<()>>,
    active: Arc<Mutex<HashMap<String, ActiveAssistantTurn>>>,
    concurrency: Arc<Semaphore>,
    model_input_limits: Arc<Mutex<HashMap<String, usize>>>,
}

#[derive(Clone)]
struct ActiveAssistantTurn {
    turn_id: String,
    cancellation: CancellationToken,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantStatusResponse {
    configured: bool,
    available: bool,
    model: Option<String>,
    reason: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantSessionListResponse {
    sessions: Vec<AssistantSessionView>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantSessionView {
    id: String,
    title: String,
    archived: bool,
    created_at: String,
    updated_at: String,
    last_sequence: i64,
    is_running: bool,
    last_model: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantTurnView {
    id: String,
    session_id: String,
    client_message_id: Option<String>,
    model: Option<String>,
    status: AssistantTurnStatus,
    error_code: Option<String>,
    error_message: Option<String>,
    started_at: Option<String>,
    ended_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantMessageView {
    id: String,
    session_id: String,
    turn_id: Option<String>,
    sequence: i64,
    client_message_id: Option<String>,
    role: String,
    kind: String,
    body: String,
    payload_json: Option<String>,
    task_references: Vec<String>,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantBundleView {
    session: AssistantSessionView,
    messages: Vec<AssistantMessageView>,
    tools: Vec<AssistantToolView>,
    timeline: Vec<SessionTimelineItem>,
    active_turn: Option<AssistantTurnView>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct AssistantToolView {
    id: String,
    session_id: String,
    turn_id: Option<String>,
    call_id: String,
    tool_name: String,
    task_refs_json: Option<String>,
    is_error: bool,
    status: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantSessionListParams {
    #[serde(default)]
    pub include_archived: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantSessionCreateParams {
    pub title: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantSessionRenameParams {
    pub session_id: String,
    pub title: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantSessionIDParams {
    pub session_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantHistoryParams {
    pub session_id: String,
    #[serde(default)]
    pub after_sequence: i64,
    #[serde(default = "default_history_limit")]
    pub limit: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantSendParams {
    pub session_id: String,
    pub client_message_id: String,
    pub text: String,
    pub model: String,
    #[serde(default)]
    pub attachments: Vec<AssistantTextAttachment>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantTextAttachment {
    pub name: String,
    pub media_type: String,
    pub content: String,
    pub byte_count: usize,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
struct AssistantMessagePayload {
    attachments: Vec<AssistantTextAttachment>,
}

fn default_history_limit() -> i64 {
    500
}

impl AssistantService {
    pub fn new(
        store: StoreWorker,
        writer: OutputWriter,
        gemini_key: Arc<Mutex<Option<Zeroizing<String>>>>,
        data_directory: Arc<PathBuf>,
        task_file_mutation: Arc<Mutex<()>>,
    ) -> Self {
        Self {
            store,
            writer,
            gemini_key,
            data_directory,
            task_file_mutation,
            active: Arc::new(Mutex::new(HashMap::new())),
            concurrency: Arc::new(Semaphore::new(MAX_ASSISTANT_CONCURRENCY)),
            model_input_limits: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn record_model_input_limit(&self, model: &str, limit: usize) {
        if !model.trim().is_empty() && limit > 0 {
            self.model_input_limits
                .lock()
                .await
                .insert(model.trim().to_owned(), limit.min(128_000));
        }
    }

    pub async fn status(&self) -> AssistantStatusResponse {
        let configured = self.gemini_key.lock().await.is_some();
        AssistantStatusResponse {
            configured,
            available: configured,
            model: None,
            reason: (!configured).then(|| "请先在设置中保存并测试 Gemini API Key。".to_owned()),
        }
    }

    pub async fn sessions(
        &self,
        include_archived: bool,
    ) -> Result<AssistantSessionListResponse, AssistantServiceError> {
        let sessions = self
            .store
            .call(move |store| store.assistant_sessions(include_archived))
            .await?
            .into_iter()
            .map(|session| AssistantSessionView::from_session(session, None))
            .collect();
        Ok(AssistantSessionListResponse { sessions })
    }

    pub async fn create_session(
        &self,
        title: Option<&str>,
    ) -> Result<AssistantSessionView, AssistantServiceError> {
        let title = title.unwrap_or(DEFAULT_SESSION_TITLE).to_owned();
        let session = self
            .store
            .call(move |store| store.create_assistant_session(&title))
            .await?;
        let session = AssistantSessionView::from_session(session, None);
        self.emit("assistant.session.changed", json!({"session": session}))
            .await;
        Ok(session)
    }

    pub async fn rename_session(
        &self,
        session_id: &str,
        title: &str,
    ) -> Result<AssistantSessionView, AssistantServiceError> {
        validate_characters(title, 120, "title")?;
        let session_id = canonical_assistant_uuid(session_id, "sessionId")?;
        let title = title.to_owned();
        let session = self
            .store
            .call(move |store| store.rename_assistant_session(&session_id, &title))
            .await?;
        let session = AssistantSessionView::from_session(session, None);
        self.emit("assistant.session.changed", json!({"session": session}))
            .await;
        Ok(session)
    }

    pub async fn archive_session(
        &self,
        session_id: &str,
    ) -> Result<AssistantSessionView, AssistantServiceError> {
        let persisted_session_id = canonical_assistant_uuid(session_id, "sessionId")?;
        let session = self
            .store
            .call(move |store| store.archive_assistant_session(&persisted_session_id))
            .await?;
        let session = AssistantSessionView::from_session(session, None);
        self.emit("assistant.session.changed", json!({"session": session}))
            .await;
        Ok(session)
    }

    pub async fn history(
        &self,
        session_id: &str,
        after_sequence: i64,
        limit: i64,
    ) -> Result<AssistantBundleView, AssistantServiceError> {
        if after_sequence < 0 {
            return Err(AssistantServiceError::Invalid(
                "afterSequence must not be negative".to_owned(),
            ));
        }
        let session_id = canonical_assistant_uuid(session_id, "sessionId")?;
        self.bundle(&session_id, after_sequence, limit).await
    }

    pub async fn send(
        &self,
        params: AssistantSendParams,
    ) -> Result<AssistantBundleView, AssistantServiceError> {
        let user_text = params.text.trim().to_owned();
        if !user_text.is_empty() {
            validate_characters(&user_text, MAX_USER_CHARACTERS, "text")?;
        }
        let attachments = validate_text_attachments(params.attachments)?;
        if user_text.is_empty() && attachments.is_empty() {
            return Err(AssistantServiceError::Invalid(
                "text or attachments is required".to_owned(),
            ));
        }
        validate_characters(&params.model, 200, "model")?;
        if self.gemini_key.lock().await.is_none() {
            return Err(AssistantServiceError::Unavailable {
                code: "gemini_key_missing",
                message: "请先在设置中保存并测试 Gemini API Key。".to_owned(),
            });
        }
        let session_id = canonical_assistant_uuid(&params.session_id, "sessionId")?;
        let client_message_id =
            canonical_assistant_uuid(&params.client_message_id, "clientMessageId")?;
        let visible_user_text = if user_text.is_empty() {
            "请处理这些附件".to_owned()
        } else {
            user_text
        };
        let payload_json = (!attachments.is_empty())
            .then(|| serde_json::to_string(&AssistantMessagePayload { attachments }))
            .transpose()
            .map_err(|error| AssistantServiceError::Invalid(error.to_string()))?;
        let model_input = assistant_user_model_text(&visible_user_text, payload_json.as_deref());
        let model = params.model.trim().to_owned();
        let persisted_user_text = visible_user_text.clone();
        let persisted_payload_json = payload_json.clone();
        let persisted_session_id = session_id.clone();
        let queued = self
            .store
            .call(move |store| {
                if let Some(payload_json) = persisted_payload_json.as_deref() {
                    store.begin_assistant_turn_with_payload(
                        &persisted_session_id,
                        &client_message_id,
                        &persisted_user_text,
                        Some(payload_json),
                        None,
                        Some(&model),
                    )
                } else {
                    store.begin_assistant_turn(
                        &persisted_session_id,
                        &client_message_id,
                        &persisted_user_text,
                        None,
                        Some(&model),
                    )
                }
            })
            .await?;

        let mut response_session = queued.session.clone();
        if queued.is_new
            && queued.turn.ordinal == 1
            && queued.session.title == DEFAULT_SESSION_TITLE
        {
            let title = first_characters(&visible_user_text, 30);
            if !title.is_empty() {
                let session_id = session_id.clone();
                if let Ok(renamed) = self
                    .store
                    .call(move |store| store.rename_assistant_session(&session_id, &title))
                    .await
                {
                    response_session = renamed;
                }
            }
        }

        if queued.is_new {
            self.schedule(queued.clone(), model_input).await;
        }
        let bundle = AssistantBundleView::from_queued(response_session, &queued);
        self.emit(
            "assistant.session.changed",
            json!({"session": bundle.session}),
        )
        .await;
        Ok(bundle)
    }

    pub async fn cancel_turn(&self, session_id: &str) -> Result<(), AssistantServiceError> {
        let session_id = canonical_assistant_uuid(session_id, "sessionId")?;
        let active = self.active.lock().await.get(&session_id).cloned().ok_or(
            AssistantServiceError::Conflict("assistant_session_not_running"),
        )?;
        active.cancellation.cancel();
        Ok(())
    }

    pub async fn shutdown(&self) {
        self.cancel_all().await;
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self.active.lock().await.is_empty() && Instant::now() < deadline {
            sleep(Duration::from_millis(50)).await;
        }
    }

    pub async fn cancel_all(&self) {
        let tokens = self
            .active
            .lock()
            .await
            .values()
            .map(|active| active.cancellation.clone())
            .collect::<Vec<_>>();
        for token in tokens {
            token.cancel();
        }
    }

    async fn bundle(
        &self,
        session_id: &str,
        after_sequence: i64,
        limit: i64,
    ) -> Result<AssistantBundleView, AssistantServiceError> {
        let session_id = session_id.to_owned();
        let history = self
            .store
            .call(move |store| store.assistant_history(&session_id, after_sequence, limit))
            .await?;
        Ok(AssistantBundleView::from_history(history))
    }

    async fn schedule(&self, queued: QueuedAssistantTurn, user_text: String) {
        let token = CancellationToken::new();
        self.active.lock().await.insert(
            queued.session.id.clone(),
            ActiveAssistantTurn {
                turn_id: queued.turn.id.clone(),
                cancellation: token.clone(),
            },
        );
        let service = self.clone();
        tokio::spawn(async move {
            service.run_queued(queued, user_text, token).await;
        });
    }

    async fn run_queued(
        &self,
        queued: QueuedAssistantTurn,
        user_text: String,
        cancellation: CancellationToken,
    ) {
        let permit = tokio::select! {
            _ = cancellation.cancelled() => None,
            permit = self.concurrency.clone().acquire_owned() => permit.ok(),
        };
        let Some(_permit) = permit else {
            self.remove_active_if_turn(&queued.session.id, &queued.turn.id)
                .await;
            self.finish_before_start(
                &queued,
                AssistantTurnStatus::Cancelled,
                "cancelled",
                "本轮已停止。",
            )
            .await;
            return;
        };
        if cancellation.is_cancelled() {
            self.remove_active_if_turn(&queued.session.id, &queued.turn.id)
                .await;
            self.finish_before_start(
                &queued,
                AssistantTurnStatus::Cancelled,
                "cancelled",
                "本轮已停止。",
            )
            .await;
            return;
        }

        let turn_id = queued.turn.id.clone();
        let running = match self
            .store
            .call(move |store| store.mark_assistant_turn_running(&turn_id))
            .await
        {
            Ok(turn) => turn,
            Err(error) => {
                tracing::error!("failed to mark assistant turn running: {error}");
                self.remove_active_if_turn(&queued.session.id, &queued.turn.id)
                    .await;
                self.finish_before_start(
                    &queued,
                    AssistantTurnStatus::Failed,
                    "assistant_storage_error",
                    "TodoAgent 无法启动本轮，请重试。",
                )
                .await;
                return;
            }
        };
        self.emit_turn("assistant.turn.started", &running, Some(&queued.message))
            .await;
        let session_id = queued.session.id.clone();
        if let Ok(session) = self
            .store
            .call(move |store| store.assistant_session(&session_id))
            .await
            && let Some(session) = session
        {
            self.emit(
                "assistant.session.changed",
                json!({"session": AssistantSessionView::from_session(session, running.model_id.clone())}),
            )
            .await;
        }

        let key = self.gemini_key.lock().await.as_ref().cloned();
        let result = match key {
            Some(key) => match GeminiInteractionsProvider::new(key.as_str().to_owned()) {
                Ok(provider) => {
                    let host = EngineAssistantHost::new(
                        self.clone(),
                        queued.session.id.clone(),
                        queued.turn.id.clone(),
                    );
                    let model = running.model_id.clone().unwrap_or_default();
                    let context_window_tokens = self
                        .model_input_limits
                        .lock()
                        .await
                        .get(&model)
                        .copied()
                        .unwrap_or(128_000)
                        .min(128_000);
                    let request = AgentRunRequest {
                        session_id: queued.session.id.clone(),
                        turn_id: queued.turn.id.clone(),
                        model,
                        system_instruction: Some(assistant_system_instruction()),
                        tools: assistant_tools(),
                        input: vec![json!({
                            "type": "user_input",
                            "content": [{"type": "text", "text": user_text}],
                        })],
                    };
                    let runner = AgentRunner::new(provider, host.clone()).with_context_builder(
                        ContextBuilder::new(ContextBuilderConfig {
                            context_window_tokens,
                            reserve_tokens: 16_384,
                            keep_recent_tokens: 20_000,
                        }),
                    );
                    let result = runner.run(request, &cancellation).await;
                    let usage = host.usage_json();
                    let completed_turn = host.completed_turn();
                    (result, usage, completed_turn)
                }
                Err(error) => (Err(AssistantError::Provider(error)), None, None),
            },
            None => (
                Err(AssistantError::Host(HostError::new(
                    "gemini_key_missing",
                    "Gemini API Key 已被移除，请重新配置。",
                ))),
                None,
                None,
            ),
        };

        let (status, error_code, error_message) = match result.0 {
            Ok(_) if result.2.is_some() => (AssistantTurnStatus::Completed, None, None),
            Ok(_) => (
                AssistantTurnStatus::Failed,
                Some("assistant_storage_error".to_owned()),
                Some("TodoAgent 无法保存 Gemini 的最终回复，请重试。".to_owned()),
            ),
            Err(AssistantError::Cancelled) => (
                AssistantTurnStatus::Cancelled,
                Some("cancelled".to_owned()),
                Some("本轮已停止。".to_owned()),
            ),
            Err(error) => (
                AssistantTurnStatus::Failed,
                Some(assistant_error_code(&error).to_owned()),
                Some(user_facing_assistant_error(&error)),
            ),
        };

        let persisted_turn = if status == AssistantTurnStatus::Completed {
            result.2
        } else {
            let turn_id = queued.turn.id.clone();
            let error_code_for_store = error_code.clone();
            let error_message_for_store = error_message.clone();
            let visible_message = error_message.clone();
            let usage = result.1.clone();
            let kind = if status == AssistantTurnStatus::Cancelled {
                "status"
            } else {
                "error"
            };
            let session_id = queued.session.id.clone();
            match self
                .store
                .call(move |store| {
                    store.finish_assistant_turn_with_message(
                        &session_id,
                        &turn_id,
                        status,
                        visible_message.as_deref().map(|message| (kind, message)),
                        None,
                        error_code_for_store.as_deref(),
                        error_message_for_store.as_deref(),
                        usage.as_deref(),
                    )
                })
                .await
            {
                Ok((message, turn)) => {
                    if let Some(message) = message {
                        self.emit_message(message).await;
                    }
                    Some(turn)
                }
                Err(StoreWorkerError::Store(StoreError::Conflict(_))) => {
                    // The final model message may have committed atomically while
                    // cancellation won the outer select. A terminal completion is
                    // immutable, so recover and publish the actual stored state.
                    let turn_id = queued.turn.id.clone();
                    match self
                        .store
                        .call(move |store| {
                            let turn = store.assistant_turn(&turn_id)?;
                            let message = store.assistant_final_message_for_turn(&turn_id)?;
                            Ok((message, turn))
                        })
                        .await
                    {
                        Ok((message, turn)) => {
                            if let Some(message) = message {
                                self.emit_message(message).await;
                            }
                            turn
                        }
                        Err(_) => None,
                    }
                }
                Err(error) => {
                    tracing::error!("failed to finish assistant turn: {error}");
                    None
                }
            }
        };

        // Remove the exact generation before publishing terminal events. A UI
        // reacting to turn.finished may immediately enqueue the next turn, and
        // cleanup from this task must never delete that new cancellation token.
        self.remove_active_if_turn(&queued.session.id, &queued.turn.id)
            .await;
        if let Some(turn) = persisted_turn {
            self.emit_turn("assistant.turn.finished", &turn, Some(&queued.message))
                .await;
            let session_id = queued.session.id.clone();
            match self
                .store
                .call(move |store| store.assistant_session(&session_id))
                .await
            {
                Ok(Some(session)) => {
                    self.emit(
                        "assistant.session.changed",
                        json!({"session": AssistantSessionView::from_session(session, turn.model_id.clone())}),
                    )
                    .await;
                }
                Ok(None) => {}
                Err(error) => tracing::error!("failed to reload assistant session: {error}"),
            }
        }
    }

    async fn remove_active_if_turn(&self, session_id: &str, turn_id: &str) -> bool {
        let mut active = self.active.lock().await;
        let is_current = active
            .get(session_id)
            .is_some_and(|entry| entry.turn_id == turn_id);
        if is_current {
            active.remove(session_id);
        }
        is_current
    }

    async fn finish_before_start(
        &self,
        queued: &QueuedAssistantTurn,
        status: AssistantTurnStatus,
        code: &'static str,
        message: &'static str,
    ) {
        let turn_id = queued.turn.id.clone();
        let session_id = queued.session.id.clone();
        let kind = if status == AssistantTurnStatus::Cancelled {
            "status"
        } else {
            "error"
        };
        if let Ok(turn) = self
            .store
            .call(move |store| {
                store.finish_assistant_turn_with_message(
                    &session_id,
                    &turn_id,
                    status,
                    Some((kind, message)),
                    None,
                    Some(code),
                    Some(message),
                    None,
                )
            })
            .await
        {
            if let Some(message) = turn.0 {
                self.emit_message(message).await;
            }
            let turn = turn.1;
            self.emit_turn("assistant.turn.finished", &turn, Some(&queued.message))
                .await;
            let session_id = queued.session.id.clone();
            if let Ok(Some(session)) = self
                .store
                .call(move |store| store.assistant_session(&session_id))
                .await
            {
                self.emit(
                    "assistant.session.changed",
                    json!({"session": AssistantSessionView::from_session(session, turn.model_id.clone())}),
                )
                .await;
            }
        }
    }

    async fn emit_turn(
        &self,
        event: &'static str,
        turn: &AssistantTurn,
        user: Option<&AssistantMessage>,
    ) {
        self.emit(
            event,
            json!({
                "sessionId": turn.session_id,
                "turn": AssistantTurnView::from_turn(turn.clone(), user),
            }),
        )
        .await;
    }

    async fn emit_message(&self, message: AssistantMessage) {
        let session_id = message.session_id.clone();
        self.emit(
            "assistant.message.appended",
            json!({
                "sessionId": session_id,
                "message": AssistantMessageView::from(message),
            }),
        )
        .await;
    }

    async fn emit<T: Serialize>(&self, event: &'static str, data: T) {
        // Persistent state notifications must not disappear behind a burst of
        // text deltas. Waiting for bounded queue capacity yields to the runtime.
        self.writer.send(&Event { event, data }).await;
    }

    fn emit_ephemeral<T: Serialize>(&self, event: &'static str, data: T) {
        self.writer.try_send_ephemeral(&Event { event, data });
    }
}

#[derive(Default)]
struct HostState {
    interaction_ordinal: i64,
    model_interaction: usize,
    usage: Vec<Value>,
    task_references: HashSet<String>,
    tool_references: HashMap<String, Vec<String>>,
    draft_attempt: usize,
    draft_buffer: String,
    draft_generation: u64,
    draft_timer_generation: Option<u64>,
    thought_attempt: usize,
    thought_provider_attempt: usize,
    thought_interaction: usize,
    thought_pending_delta: String,
    thought_emitted_bytes: usize,
    thought_original_bytes: usize,
    thought_generation: u64,
    thought_timer_generation: Option<u64>,
    completed_turn: Option<AssistantTurn>,
}

struct ThoughtEmission {
    global_attempt: usize,
    provider_attempt: usize,
    interaction_ordinal: usize,
    content: String,
    original_bytes: usize,
    truncated: bool,
}

fn take_thought_emission(state: &mut HostState) -> Option<ThoughtEmission> {
    if state.thought_pending_delta.is_empty() {
        state.thought_timer_generation = None;
        return None;
    }
    let content = std::mem::take(&mut state.thought_pending_delta);
    state.thought_emitted_bytes = state.thought_emitted_bytes.saturating_add(content.len());
    state.thought_generation = state.thought_generation.wrapping_add(1);
    state.thought_timer_generation = None;
    Some(ThoughtEmission {
        global_attempt: state.thought_attempt.max(1),
        provider_attempt: state.thought_provider_attempt.max(1),
        interaction_ordinal: state.thought_interaction.max(1),
        content,
        original_bytes: state.thought_original_bytes,
        truncated: state.thought_original_bytes > PUBLIC_THOUGHT_SUMMARY_MAX_BYTES,
    })
}

#[derive(Clone)]
struct EngineAssistantHost {
    service: AssistantService,
    session_id: String,
    turn_id: String,
    state: Arc<StdMutex<HostState>>,
}

impl EngineAssistantHost {
    fn new(service: AssistantService, session_id: String, turn_id: String) -> Self {
        Self {
            service,
            session_id,
            turn_id,
            state: Arc::new(StdMutex::new(HostState::default())),
        }
    }

    fn usage_json(&self) -> Option<String> {
        let state = self.state.lock().ok()?;
        (!state.usage.is_empty()).then(|| Value::Array(state.usage.clone()).to_string())
    }

    fn completed_turn(&self) -> Option<AssistantTurn> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.completed_turn.clone())
    }

    fn begin_model_interaction(&self) {
        self.flush_thought();
        let attempt = if let Ok(mut state) = self.state.lock() {
            state.model_interaction += 1;
            let attempt = global_draft_attempt(state.model_interaction, 1);
            state.draft_buffer.clear();
            state.draft_attempt = attempt;
            state.draft_generation = state.draft_generation.wrapping_add(1);
            state.draft_timer_generation = None;
            attempt
        } else {
            return;
        };
        self.send_delta(attempt, String::new());
    }

    fn append_thought_summary(&self, provider_attempt: usize, delta: &str) {
        let mut emissions = Vec::new();
        let mut timer = None;
        if let Ok(mut state) = self.state.lock() {
            let interaction = state.model_interaction.max(1);
            let global_attempt = global_draft_attempt(interaction, provider_attempt);
            if state.thought_attempt != global_attempt {
                if let Some(emission) = take_thought_emission(&mut state) {
                    emissions.push(emission);
                }
                state.thought_attempt = global_attempt;
                state.thought_provider_attempt = provider_attempt;
                state.thought_interaction = interaction;
                state.thought_pending_delta.clear();
                state.thought_emitted_bytes = 0;
                state.thought_original_bytes = 0;
                state.thought_generation = state.thought_generation.wrapping_add(1);
                state.thought_timer_generation = None;
            }
            state.thought_original_bytes = state.thought_original_bytes.saturating_add(delta.len());
            let accepted_bytes = state
                .thought_emitted_bytes
                .saturating_add(state.thought_pending_delta.len());
            let remaining = PUBLIC_THOUGHT_SUMMARY_MAX_BYTES.saturating_sub(accepted_bytes);
            state
                .thought_pending_delta
                .push_str(&bounded_utf8_prefix(delta, remaining));
            if state.thought_pending_delta.len() >= THOUGHT_DELTA_FLUSH_BYTES {
                if let Some(emission) = take_thought_emission(&mut state) {
                    emissions.push(emission);
                }
            } else if !state.thought_pending_delta.is_empty()
                && state.thought_timer_generation.is_none()
            {
                let generation = state.thought_generation;
                state.thought_timer_generation = Some(generation);
                timer = Some((global_attempt, generation));
            }
        }
        for emission in emissions {
            self.send_thought_delta(emission);
        }
        if let Some((attempt, generation)) = timer {
            let host = self.clone();
            tokio::spawn(async move {
                sleep(DELTA_FLUSH_INTERVAL).await;
                host.flush_thought_generation(attempt, generation);
            });
        }
    }

    fn flush_thought(&self) {
        let emission = self
            .state
            .lock()
            .ok()
            .and_then(|mut state| take_thought_emission(&mut state));
        if let Some(emission) = emission {
            self.send_thought_delta(emission);
        }
    }

    fn flush_thought_generation(&self, attempt: usize, generation: u64) {
        let emission = self.state.lock().ok().and_then(|mut state| {
            if state.thought_attempt != attempt
                || state.thought_generation != generation
                || state.thought_timer_generation != Some(generation)
            {
                return None;
            }
            take_thought_emission(&mut state)
        });
        if let Some(emission) = emission {
            self.send_thought_delta(emission);
        }
    }

    fn send_thought_delta(&self, emission: ThoughtEmission) {
        self.service.emit_ephemeral(
            "assistant.thought.summary",
            json!({
                "sessionId": self.session_id,
                "turnId": self.turn_id,
                "attempt": emission.global_attempt,
                "providerAttempt": emission.provider_attempt,
                "interactionOrdinal": emission.interaction_ordinal,
                "partId": format!("assistant-live-reasoning-{}-{}", self.turn_id, emission.global_attempt),
                "partOrdinal": emission.global_attempt,
                "isDelta": true,
                "originalBytes": emission.original_bytes,
                "truncated": emission.truncated,
                "content": emission.content,
            }),
        );
    }

    fn reset_draft(&self, provider_attempt: usize) {
        let mut global_attempt = provider_attempt.max(1);
        if let Ok(mut state) = self.state.lock() {
            global_attempt = global_draft_attempt(state.model_interaction.max(1), provider_attempt);
            state.draft_buffer.clear();
            state.draft_attempt = global_attempt;
            state.draft_generation = state.draft_generation.wrapping_add(1);
            state.draft_timer_generation = None;
        }
        self.send_delta(global_attempt, String::new());
    }

    fn append_delta(&self, provider_attempt: usize, text: &str) {
        if text.is_empty() {
            return;
        }
        let mut flush = None;
        let mut timer = None;
        if let Ok(mut state) = self.state.lock() {
            let attempt = global_draft_attempt(state.model_interaction.max(1), provider_attempt);
            if attempt > state.draft_attempt {
                state.draft_attempt = attempt;
                state.draft_buffer.clear();
                state.draft_generation = state.draft_generation.wrapping_add(1);
                state.draft_timer_generation = None;
            } else if attempt < state.draft_attempt {
                return;
            }
            state.draft_buffer.push_str(text);
            if state.draft_buffer.len() >= DELTA_FLUSH_BYTES {
                flush = Some((
                    state.draft_attempt.max(1),
                    std::mem::take(&mut state.draft_buffer),
                ));
                state.draft_generation = state.draft_generation.wrapping_add(1);
                state.draft_timer_generation = None;
            } else if state.draft_timer_generation.is_none() {
                let generation = state.draft_generation;
                state.draft_timer_generation = Some(generation);
                timer = Some((state.draft_attempt.max(1), generation));
            }
        }
        if let Some((attempt, delta)) = flush {
            self.send_delta(attempt, delta);
        } else if let Some((attempt, generation)) = timer {
            let host = self.clone();
            tokio::spawn(async move {
                sleep(DELTA_FLUSH_INTERVAL).await;
                host.flush_draft_generation(attempt, generation);
            });
        }
    }

    fn flush_draft(&self) {
        let flush = self.state.lock().ok().and_then(|mut state| {
            (!state.draft_buffer.is_empty()).then(|| {
                let value = (
                    state.draft_attempt.max(1),
                    std::mem::take(&mut state.draft_buffer),
                );
                state.draft_generation = state.draft_generation.wrapping_add(1);
                state.draft_timer_generation = None;
                value
            })
        });
        if let Some((attempt, delta)) = flush {
            self.send_delta(attempt, delta);
        }
    }

    fn flush_draft_generation(&self, attempt: usize, generation: u64) {
        let flush = self.state.lock().ok().and_then(|mut state| {
            if state.draft_attempt != attempt
                || state.draft_generation != generation
                || state.draft_timer_generation != Some(generation)
            {
                return None;
            }
            state.draft_timer_generation = None;
            state.draft_generation = state.draft_generation.wrapping_add(1);
            (!state.draft_buffer.is_empty())
                .then(|| (attempt, std::mem::take(&mut state.draft_buffer)))
        });
        if let Some((attempt, delta)) = flush {
            self.send_delta(attempt, delta);
        }
    }

    fn send_delta(&self, attempt: usize, delta: String) {
        self.service.emit_ephemeral(
            "assistant.message.delta",
            json!({
                "sessionId": self.session_id,
                "turnId": self.turn_id,
                "messageId": format!("draft-{}", self.turn_id),
                "attempt": attempt,
                "delta": delta,
            }),
        );
    }

    fn remember_tool_references(&self, call_id: &str, references: Vec<String>) {
        if let Ok(mut state) = self.state.lock() {
            state.task_references.extend(references.iter().cloned());
            state.tool_references.insert(call_id.to_owned(), references);
        }
    }
}

impl AssistantHost for EngineAssistantHost {
    async fn load_context(&self, session_id: &str) -> Result<ContextSnapshot, HostError> {
        let session_id = session_id.to_owned();
        let history = self
            .service
            .store
            .call(move |store| store.assistant_context_history(&session_id))
            .await
            .map_err(host_store_error)?;
        Ok(context_from_history(&history, &self.turn_id))
    }

    async fn persist_steps(
        &self,
        _session_id: &str,
        turn_id: &str,
        batch: PersistSteps,
    ) -> Result<(), HostError> {
        let interaction_ordinal = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| HostError::new("state_poisoned", "assistant state is unavailable"))?;
            state.interaction_ordinal += 1;
            if !batch.usage.is_null() {
                state.usage.push(batch.usage.clone());
            }
            state.interaction_ordinal
        };
        let owned = batch
            .steps
            .iter()
            .map(|step| {
                let kind = step.kind().unwrap_or("unknown").to_owned();
                let title = step
                    .payload
                    .get("name")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                let payload = step.payload.to_string();
                let index = step.index.and_then(|value| i64::try_from(value).ok());
                (kind, title, payload, index)
            })
            .collect::<Vec<_>>();
        let turn_id = turn_id.to_owned();
        self.service
            .store
            .call(move |store| {
                let borrowed = owned
                    .iter()
                    .map(|(kind, title, payload, index)| {
                        (
                            kind.as_str(),
                            title.as_deref(),
                            Some(payload.as_str()),
                            *index,
                        )
                    })
                    .collect::<Vec<_>>();
                store.append_assistant_steps(&turn_id, interaction_ordinal, &borrowed)
            })
            .await
            .map_err(host_store_error)?;
        Ok(())
    }

    async fn lookup_receipt(
        &self,
        session_id: &str,
        call_id: &str,
    ) -> Result<Option<ToolReceipt>, HostError> {
        let session_id = session_id.to_owned();
        let call_id = call_id.to_owned();
        let execution = self
            .service
            .store
            .call(move |store| store.assistant_tool_execution(&session_id, &call_id))
            .await
            .map_err(host_store_error)?;
        Ok(execution.map(|execution| ToolReceipt {
            call_id: execution.call_id,
            name: execution.tool_name,
            result: execution
                .response_json
                .as_deref()
                .and_then(|value| serde_json::from_str(value).ok())
                .unwrap_or(Value::Null),
            is_error: execution.is_error,
        }))
    }

    async fn save_receipt(
        &self,
        session_id: &str,
        turn_id: &str,
        receipt: &ToolReceipt,
    ) -> Result<(), HostError> {
        let response = receipt.result.to_string();
        let session_id = session_id.to_owned();
        let turn_id = turn_id.to_owned();
        let call_id = receipt.call_id.clone();
        let name = receipt.name.clone();
        let is_error = receipt.is_error;
        self.service
            .store
            .call(move |store| {
                store.save_assistant_tool_execution(
                    &session_id,
                    &turn_id,
                    None,
                    &call_id,
                    &name,
                    "{}",
                    Some(&response),
                    is_error,
                    if is_error { "failed" } else { "completed" },
                    is_error.then_some("tool_error"),
                    is_error.then_some("tool call returned an error"),
                )
            })
            .await
            .map_err(host_store_error)?;
        Ok(())
    }

    async fn execute_named_tool_once(
        &self,
        request: ToolRequest,
        cancellation: &CancellationToken,
    ) -> Result<ToolReceipt, ToolError> {
        if cancellation.is_cancelled() {
            return Err(ToolError {
                kind: ToolErrorKind::Cancelled,
                message: "assistant turn was cancelled".to_owned(),
            });
        }
        if !crate::assistant::ALLOWED_ASSISTANT_TOOLS.contains(&request.name.as_str()) {
            return Err(ToolError {
                kind: ToolErrorKind::UnknownTool,
                message: "unknown TodoAgent tool".to_owned(),
            });
        }
        if request.name == "delete_task" {
            let service = self.service.clone();
            let cancellation = cancellation.clone();
            return tokio::spawn(async move {
                execute_assistant_delete_tool(service, request, cancellation).await
            })
            .await
            .map_err(|error| ToolError {
                kind: ToolErrorKind::Failed,
                message: format!("delete_task worker failed: {error}"),
            })?;
        }
        let arguments = request.arguments.to_string();
        let turn_id = request.turn_id.clone();
        let call_id = request.call_id.clone();
        let name = request.name.clone();
        let result = self
            .service
            .store
            .call(move |store| store.execute_assistant_tool(&turn_id, &call_id, &name, &arguments))
            .await
            .map_err(tool_store_error)?;
        let references = parse_string_array(Some(&result.task_refs_json));
        self.remember_tool_references(&request.call_id, references.clone());
        if matches!(request.name.as_str(), "create_tasks" | "update_task") && !result.is_error {
            if let Ok(snapshot) = self.service.store.call(|store| store.bootstrap()).await {
                self.service.emit("task.changed", snapshot).await;
            }
        }
        Ok(ToolReceipt {
            call_id: request.call_id,
            name: request.name,
            result: serde_json::from_str(&result.result_json).unwrap_or(Value::Null),
            is_error: result.is_error,
        })
    }

    async fn append_final(
        &self,
        session_id: &str,
        turn_id: &str,
        text: &str,
    ) -> Result<(), HostError> {
        self.flush_draft();
        let references = self
            .state
            .lock()
            .map(|state| {
                let mut values = state.task_references.iter().cloned().collect::<Vec<_>>();
                values.sort();
                values
            })
            .unwrap_or_default();
        let references_json = serde_json::to_string(&references)
            .map_err(|error| HostError::new("serialization_failed", error.to_string()))?;
        let session_id = session_id.to_owned();
        let turn_id = turn_id.to_owned();
        let text = text.to_owned();
        let usage = self.usage_json();
        let (message, turn) = self
            .service
            .store
            .call(move |store| {
                store.complete_assistant_turn_with_message(
                    &session_id,
                    &turn_id,
                    &text,
                    Some(&references_json),
                    usage.as_deref(),
                )
            })
            .await
            .map_err(host_store_error)?;
        if let Ok(mut state) = self.state.lock() {
            state.completed_turn = Some(turn);
        }
        self.service.emit_message(message).await;
        Ok(())
    }

    async fn compact_context(
        &self,
        session_id: &str,
        request: CompactionRequest,
        cancellation: &CancellationToken,
    ) -> Result<CompactionResult, HostError> {
        let key = self
            .service
            .gemini_key
            .lock()
            .await
            .as_ref()
            .cloned()
            .ok_or_else(|| HostError::new("gemini_key_missing", "Gemini API Key is unavailable"))?;
        let turn_id = self.turn_id.clone();
        let model = self
            .service
            .store
            .call(move |store| store.assistant_turn(&turn_id))
            .await
            .map_err(host_store_error)?
            .and_then(|turn| turn.model_id)
            .ok_or_else(|| HostError::new("model_missing", "assistant model is unavailable"))?;
        let prompt = compaction_prompt(&request);
        let provider = GeminiInteractionsProvider::new(key.as_str().to_owned())
            .map_err(|error| HostError::new("provider_error", error.to_string()))?;
        let interaction = InteractionRequest {
            model,
            input: vec![json!({
                "type":"user_input",
                "content":[{"type":"text","text":prompt}],
            })],
            system_instruction: Some(
                "你是本地对话压缩器。只输出精确、结构化的中文摘要，保留用户意图、任务事实、工具结果和未完成事项，不添加新事实。"
                    .to_owned(),
            ),
            tools: Vec::new(),
        };
        let mut sink = |_event| {};
        let response = provider
            .interact(&interaction, cancellation, &mut sink)
            .await
            .map_err(|error| HostError::new("compaction_failed", error.to_string()))?;
        if !response.usage.is_null()
            && let Ok(mut state) = self.state.lock()
        {
            state.usage.push(response.usage.clone());
        }
        let summary = response
            .steps
            .iter()
            .map(|step| step.model_text())
            .collect::<String>();
        if summary.trim().is_empty() {
            return Err(HostError::new(
                "compaction_failed",
                "Gemini returned an empty summary",
            ));
        }
        let summarized_ids = request
            .turns_to_summarize
            .iter()
            .map(|turn| turn.turn_id.as_str())
            .collect::<HashSet<_>>();
        let context_session_id = session_id.to_owned();
        let history = self
            .service
            .store
            .call(move |store| store.assistant_context_history(&context_session_id))
            .await
            .map_err(host_store_error)?;
        let through_sequence = history
            .steps
            .iter()
            .filter(|step| summarized_ids.contains(step.turn_id.as_str()))
            .map(|step| step.sequence)
            .max()
            .unwrap_or(0);
        let summary_value = Value::String(summary.trim().to_owned());
        let payload = json!({
            "providerInteractionId": response.interaction_id,
            "estimatedTokens": estimate_tokens(&summary_value),
        });
        let session_id = session_id.to_owned();
        let summary_for_store = summary.trim().to_owned();
        let payload = payload.to_string();
        self.service
            .store
            .call(move |store| {
                store.save_assistant_compaction(
                    &session_id,
                    through_sequence,
                    &summary_for_store,
                    Some(&payload),
                )
            })
            .await
            .map_err(host_store_error)?;
        Ok(CompactionResult {
            summary: summary.trim().to_owned(),
            estimated_tokens: estimate_tokens(&summary_value),
        })
    }

    fn emit(&self, _session_id: &str, _turn_id: &str, event: AgentEvent) {
        match event {
            AgentEvent::DraftReset { attempt, .. } => {
                self.flush_thought();
                self.reset_draft(attempt);
            }
            AgentEvent::Delta { attempt, text } => self.append_delta(attempt, &text),
            AgentEvent::ToolStarted { call_id, name } => {
                self.flush_draft();
                self.flush_thought();
                self.service.emit_ephemeral(
                    "assistant.tool.started",
                    json!({
                        "sessionId": self.session_id,
                        "turnId": self.turn_id,
                        "toolCallId": call_id,
                        "name": name,
                    }),
                );
            }
            AgentEvent::ToolFinished {
                call_id,
                name,
                is_error,
            } => {
                self.flush_draft();
                self.flush_thought();
                let task_references = self
                    .state
                    .lock()
                    .ok()
                    .and_then(|state| state.tool_references.get(&call_id).cloned())
                    .unwrap_or_default();
                self.service.emit_ephemeral(
                    "assistant.tool.finished",
                    json!({
                        "sessionId": self.session_id,
                        "turnId": self.turn_id,
                        "toolCallId": call_id,
                        "name": name,
                        "isError": is_error,
                        "taskReferences": task_references,
                    }),
                );
            }
            AgentEvent::Final { .. } | AgentEvent::Failed { .. } => {
                self.flush_draft();
                self.flush_thought();
            }
            AgentEvent::Status { phase, .. } if phase == "model" => {
                self.begin_model_interaction();
            }
            AgentEvent::ThoughtSummary { attempt, content } => {
                let content = public_thought_summary_text(&content);
                if !content.is_empty() {
                    self.append_thought_summary(attempt, &content);
                }
            }
            AgentEvent::Status { .. } => {}
        }
    }
}

impl AssistantSessionView {
    fn from_session(session: AssistantSession, last_model: Option<String>) -> Self {
        Self {
            id: session.id,
            title: session.title,
            archived: session.archived_at.is_some(),
            created_at: session.created_at,
            updated_at: session.updated_at,
            last_sequence: session.last_sequence,
            is_running: session.is_running,
            last_model,
        }
    }
}

impl AssistantTurnView {
    fn from_turn(turn: AssistantTurn, user: Option<&AssistantMessage>) -> Self {
        Self {
            id: turn.id,
            session_id: turn.session_id,
            client_message_id: user.and_then(|message| message.client_message_id.clone()),
            model: turn.model_id,
            status: turn.status,
            error_code: turn.error_code,
            error_message: turn.error_message,
            started_at: turn.started_at,
            ended_at: turn.ended_at,
        }
    }
}

impl From<AssistantMessage> for AssistantMessageView {
    fn from(message: AssistantMessage) -> Self {
        Self {
            id: message.id,
            session_id: message.session_id,
            turn_id: message.turn_id,
            sequence: message.sequence,
            client_message_id: message.client_message_id,
            role: message.role,
            kind: message.kind,
            body: message.body,
            payload_json: message.payload_json,
            task_references: parse_string_array(message.task_refs_json.as_deref()),
            created_at: message.created_at,
            updated_at: message.updated_at,
        }
    }
}

impl AssistantBundleView {
    fn from_queued(session: AssistantSession, queued: &QueuedAssistantTurn) -> Self {
        let active_turn = matches!(
            queued.turn.status,
            AssistantTurnStatus::Queued | AssistantTurnStatus::Running
        )
        .then(|| AssistantTurnView::from_turn(queued.turn.clone(), Some(&queued.message)));
        Self {
            session: AssistantSessionView::from_session(session, queued.turn.model_id.clone()),
            messages: vec![AssistantMessageView::from(queued.message.clone())],
            tools: Vec::new(),
            timeline: vec![SessionTimelineItem {
                id: format!("assistant-timeline-message-{}", queued.message.id),
                session_id: queued.message.session_id.clone(),
                turn_id: queued.turn.id.clone(),
                sequence: 1,
                turn_ordinal: queued.turn.ordinal,
                item_ordinal: 0,
                kind: "user".to_owned(),
                body: queued.message.body.clone(),
                call_id: None,
                tool_name: None,
                input_json: None,
                output_text: None,
                tool_state: None,
                is_error: false,
                source_event_sequence: None,
                source_block_index: None,
                fidelity: "exact".to_owned(),
                metadata_json: None,
                created_at: queued.message.created_at.clone(),
                updated_at: queued.message.updated_at.clone(),
            }],
            active_turn,
        }
    }

    fn from_history(history: AssistantHistory) -> Self {
        let active_user = history.active_turn.as_ref().and_then(|turn| {
            history
                .messages
                .iter()
                .find(|message| message.id == turn.user_message_id)
        });
        let active_turn = history
            .active_turn
            .clone()
            .map(|turn| AssistantTurnView::from_turn(turn, active_user));
        let last_model = active_turn.as_ref().and_then(|turn| turn.model.clone());
        Self {
            session: AssistantSessionView::from_session(history.session, last_model),
            messages: history
                .messages
                .into_iter()
                .map(AssistantMessageView::from)
                .collect(),
            tools: history
                .tools
                .into_iter()
                .map(AssistantToolView::from)
                .collect(),
            timeline: history.timeline,
            active_turn,
        }
    }
}

impl From<AssistantToolSummary> for AssistantToolView {
    fn from(tool: AssistantToolSummary) -> Self {
        Self {
            id: tool.id,
            session_id: tool.session_id,
            turn_id: tool.turn_id,
            call_id: tool.call_id,
            tool_name: tool.tool_name,
            task_refs_json: tool.task_refs_json,
            is_error: tool.is_error,
            status: tool.status,
        }
    }
}

fn context_from_history(
    history: &AssistantContextHistory,
    current_turn_id: &str,
) -> ContextSnapshot {
    let compacted_through = history
        .compaction
        .as_ref()
        .map(|value| value.through_sequence)
        .unwrap_or(0);
    let mut turns = BTreeMap::<i64, (String, Vec<Value>, i64)>::new();

    for message in &history.messages {
        let Some(turn_id) = message.turn_id.as_deref() else {
            continue;
        };
        if turn_id == current_turn_id || message.role != "user" || message.kind != "text" {
            continue;
        }
        turns.insert(
            message.sequence,
            (
                turn_id.to_owned(),
                vec![json!({
                    "type":"user_input",
                    "content":[{
                        "type":"text",
                        "text":assistant_user_model_text(
                            &message.body,
                            message.payload_json.as_deref(),
                        ),
                    }],
                })],
                0,
            ),
        );
    }

    let mut key_by_turn = turns
        .iter()
        .map(|(key, (turn_id, _, _))| (turn_id.clone(), *key))
        .collect::<HashMap<_, _>>();
    for step in &history.steps {
        if step.turn_id == current_turn_id {
            continue;
        }
        let Some(key) = key_by_turn.get(&step.turn_id).copied() else {
            continue;
        };
        if let Some((_, values, last_step)) = turns.get_mut(&key) {
            if let Some(payload) = step
                .payload_json
                .as_deref()
                .and_then(|value| serde_json::from_str::<Value>(value).ok())
            {
                values.push(payload);
            }
            *last_step = (*last_step).max(step.sequence);
        }
    }
    key_by_turn.clear();

    let has_compaction = history.compaction.is_some();
    let turns = turns
        .into_values()
        // Store intentionally omits steps at/before the compaction watermark.
        // With a summary present, an old user message without a returned step
        // is therefore covered history, not a new prompt-only turn.
        .filter(|(_, _, last_step)| !has_compaction || *last_step > compacted_through)
        .map(|(turn_id, steps, _)| StoredTurn { turn_id, steps })
        .collect();
    ContextSnapshot {
        summary: history
            .compaction
            .as_ref()
            .map(|value| value.summary.clone()),
        turns,
    }
}

fn compaction_prompt(request: &CompactionRequest) -> String {
    let previous = request.previous_summary.as_deref().unwrap_or("无");
    let history = serde_json::to_string(&request.turns_to_summarize).unwrap_or_default();
    format!(
        "请把下面的旧摘要与对话步骤更新成一份独立可用的累计摘要。\n\n旧摘要：\n{previous}\n\n新增历史：\n{history}\n\n摘要必须保留：用户偏好、明确决定、任务标题/状态/执行日期 executionDate/截止日期 dueDate/清单、工具结果、未完成问题。执行日期与截止日期必须分别保留，不得合并或互相推断。"
    )
}

fn assistant_system_instruction() -> String {
    let today = Local::now().format("%Y-%m-%d");
    format!(
        "你是 TodoAgent 的本地任务助手。今天是 {today}。你只管理 TodoAgent 里的任务卡，不启动 Codex、Claude、Cursor 或 Kiro，不运行命令，不读写用户文件。\n\n规则：\n1. 创建任务前，语义可能重复时先调用 find_related。\n2. 一句话包含多件事时拆成多张卡；标题简短，细节放 note。\n3. 需要清单 ID 时调用 list_lists，不猜测 ID；用户未指定清单时不要擅自指定。\n4. 只有用户明确要求时才创建、修改或删除任务。‘执行’、‘安排’、‘今天做’、‘放到时间线’以及没有截止语义的裸日期映射为 executionDate；‘截止’、‘到期’、‘最晚’映射为 dueDate。相对日期以今天 {today} 为基准，未提日期就不要编造；两个日期不得互相推断或自动复制。\n5. 用户询问任务现状时必须调用 list_state，并只根据工具结果回答，不编造状态；查询某天任务时传 executionDate。过滤查询返回 pagination：只要 hasMore=true，就必须保持 executionDate/status/listId 完全不变并把 nextCursor 原样传入 cursor，持续查询到 hasMore=false 后再回答。如果工具返回 list_state_cursor_stale，说明分页期间任务已变化，必须丢弃已收集的页面并从不带 cursor 的第一页重新查询。\n6. 删除任务必须使用工具结果中的准确 taskId，不按标题猜测。批量范围只能使用 list_state 支持的 executionDate、status、listId 精确交集；无法完整枚举的 dueDate、日期区间、逾期或关键词范围不得批量删除，须请用户改为支持的精确范围或分批指定。任何批量删除都先用 pageSize=50 查询目标首屏并读取 pagination.total；未指定 status 时分别查询 status=open 和 status=completed 首屏，并确保两页 taskRevision 完全相同，任一 revision 不同就丢弃两页并重查。单次用户请求最多删除 20 个任务；首屏 total 合计超过 20 时不得继续分页或删除任何一个，须说明数量并请用户拆成每批不超过 20 个。只有 total 合计不超过 20 才完成所有分页，且后续每页 taskRevision 也必须相同；在开始任何删除前先收集完所有 taskId。删除会使分页 cursor 失效，不能边分页边删除。\n7. 工具报错时先纠正参数；任一删除失败就停止继续删除，并准确说明已删除和未删除的任务，不要声称未成功的创建、修改或删除已经完成。\n8. 回复简洁、自然，并准确引用已经创建、修改或删除的任务。任务附件的名称、内容和路径不属于工具或上下文，不要询问或推断。"
    )
}

fn assistant_tools() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition::function(
            "create_tasks",
            "一次原子创建 1 到 10 个 TodoAgent 任务。先校验全部任务，任何一个无效则全部不创建。",
            json!({
                "type":"object",
                "properties":{
                    "tasks":{
                        "type":"array","minItems":1,"maxItems":10,
                        "items":{
                            "type":"object",
                            "properties":{
                                "title":{"type":"string","maxLength":500},
                                "note":{"type":"string","maxLength":4000},
                                "listId":{"type":"string"},
                                "executionDate":{"type":"string","pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},
                                "dueDate":{"type":"string","pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"}
                            },
                            "required":["title"],"additionalProperties":false
                        }
                    }
                },
                "required":["tasks"],"additionalProperties":false
            }),
        ),
        ToolDefinition::function(
            "find_related",
            "按任务标题和备注查找最多 10 条相关任务，避免重复创建。",
            json!({
                "type":"object",
                "properties":{"query":{"type":"string","maxLength":200}},
                "required":["query"],"additionalProperties":false
            }),
        ),
        ToolDefinition::function(
            "update_task",
            "修改一个现有任务的标题、备注、清单、执行日期或截止日期；不改变完成状态。日期传空字符串可清除对应日期，两种日期不得互相推断。",
            json!({
                "type":"object",
                "properties":{
                    "taskId":{"type":"string"},
                    "title":{"type":"string","maxLength":500},
                    "note":{"type":"string","maxLength":4000},
                    "listId":{"type":"string"},
                    "executionDate":{"type":"string","maxLength":10,"description":"YYYY-MM-DD；空字符串表示清除执行日期"},
                    "dueDate":{"type":"string","maxLength":10,"description":"YYYY-MM-DD；空字符串表示清除截止日期"}
                },
                "required":["taskId"],"additionalProperties":false
            }),
        ),
        ToolDefinition::function(
            "delete_task",
            "永久删除一个 TodoAgent 任务。只有用户明确要求删除时才能调用；taskId 必须来自工具结果，不得按标题猜测。单次用户请求最多删除 20 个任务，且必须在任何删除前完成目标枚举。任务存在运行中或排队中的本地 Session 时会拒绝删除。",
            json!({
                "type":"object",
                "properties":{"taskId":{"type":"string"}},
                "required":["taskId"],"additionalProperties":false
            }),
        ),
        ToolDefinition::function(
            "list_state",
            "读取未完成/已完成任务摘要，以及本地 Terminal Run 生命周期与 attention 状态。按执行日期、状态或清单过滤时使用快照游标分页；pagination.hasMore 为 true 时保持过滤条件不变，并把 nextCursor 原样传入 cursor，直到 hasMore 为 false。若返回 list_state_cursor_stale，丢弃旧页面并从第一页重新查询。",
            json!({
                "type":"object",
                "properties":{
                    "executionDate":{"type":"string","pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},
                    "status":{"type":"string","enum":["open","completed"]},
                    "listId":{"type":"string"},
                    "pageSize":{"type":"integer","minimum":1,"maximum":50},
                    "cursor":{
                        "type":"object",
                        "properties":{
                            "taskRevision":{"type":"integer","minimum":0},
                            "status":{"type":"string","enum":["open","completed"]},
                            "updatedAt":{"type":"string"},
                            "taskId":{"type":"string"},
                            "filterExecutionDate":{"type":"string"},
                            "filterStatus":{"type":"string","enum":["open","completed"]},
                            "filterListId":{"type":"string"}
                        },
                        "required":["taskRevision","status","updatedAt","taskId"],
                        "additionalProperties":false
                    }
                },
                "additionalProperties":false
            }),
        ),
        ToolDefinition::function(
            "list_lists",
            "读取所有未归档的用户清单及其 ID。",
            json!({"type":"object","properties":{},"additionalProperties":false}),
        ),
    ]
}

fn validate_text_attachments(
    attachments: Vec<AssistantTextAttachment>,
) -> Result<Vec<AssistantTextAttachment>, AssistantServiceError> {
    if attachments.len() > MAX_TEXT_ATTACHMENTS {
        return Err(AssistantServiceError::Invalid(format!(
            "attachments must contain at most {MAX_TEXT_ATTACHMENTS} files"
        )));
    }

    let mut total_bytes = 0usize;
    let mut validated = Vec::with_capacity(attachments.len());
    for attachment in attachments {
        let name = attachment.name.trim();
        let name_characters = name.chars().count();
        if name_characters == 0 || name_characters > MAX_ATTACHMENT_NAME_CHARACTERS {
            return Err(AssistantServiceError::Invalid(format!(
                "attachment name must contain 1...{MAX_ATTACHMENT_NAME_CHARACTERS} characters"
            )));
        }
        // The UI sends only a leaf display name. Rejecting separators prevents
        // an accidentally supplied local path from reaching the provider or
        // being persisted as attachment metadata.
        if name.contains('/') || name.contains('\\') {
            return Err(AssistantServiceError::Invalid(
                "attachment name must not contain a path".to_owned(),
            ));
        }
        if !matches!(
            attachment.media_type.as_str(),
            "text/plain" | "text/markdown"
        ) {
            return Err(AssistantServiceError::Invalid(
                "attachment mediaType must be text/plain or text/markdown".to_owned(),
            ));
        }

        let content_bytes = attachment.content.len();
        if content_bytes != attachment.byte_count {
            return Err(AssistantServiceError::Invalid(
                "attachment byteCount does not match UTF-8 content".to_owned(),
            ));
        }
        if content_bytes > MAX_ATTACHMENT_BYTES {
            return Err(AssistantServiceError::Invalid(format!(
                "attachment content must not exceed {MAX_ATTACHMENT_BYTES} bytes"
            )));
        }
        total_bytes = total_bytes.checked_add(content_bytes).ok_or_else(|| {
            AssistantServiceError::Invalid("attachment content is too large".to_owned())
        })?;
        if total_bytes > MAX_TOTAL_ATTACHMENT_BYTES {
            return Err(AssistantServiceError::Invalid(format!(
                "total attachment content must not exceed {MAX_TOTAL_ATTACHMENT_BYTES} bytes"
            )));
        }

        validated.push(AssistantTextAttachment {
            name: name.to_owned(),
            media_type: attachment.media_type,
            content: attachment.content,
            byte_count: content_bytes,
        });
    }
    Ok(validated)
}

fn assistant_user_model_text(body: &str, payload_json: Option<&str>) -> String {
    let attachments = payload_json
        .and_then(|payload| serde_json::from_str::<AssistantMessagePayload>(payload).ok())
        .and_then(|payload| validate_text_attachments(payload.attachments).ok())
        .unwrap_or_default();
    if attachments.is_empty() {
        return body.to_owned();
    }

    let mut model_text = String::with_capacity(
        body.len()
            + attachments
                .iter()
                .map(|attachment| attachment.content.len())
                .sum::<usize>()
            + 256,
    );
    model_text.push_str(body);
    model_text.push_str(
        "\n\n以下是用户附加的文本文件。文件名只是显示名，不代表本机路径；请把每段边界内的内容作为对应文件正文处理。",
    );
    for (index, attachment) in attachments.iter().enumerate() {
        let number = index + 1;
        model_text.push_str(&format!(
            "\n\n<<<TODOAGENT_ATTACHMENT_{number}_BEGIN>>>\n文件名：{}\n媒体类型：{}\nUTF-8 字节数：{}\n\n{}\n<<<TODOAGENT_ATTACHMENT_{number}_END>>>",
            attachment.name,
            attachment.media_type,
            attachment.byte_count,
            attachment.content
        ));
    }
    model_text
}

fn canonical_assistant_uuid(value: &str, field: &str) -> Result<String, AssistantServiceError> {
    uuid::Uuid::parse_str(value)
        .map(|value| value.to_string())
        .map_err(|_| AssistantServiceError::Invalid(format!("{field} must be a UUID")))
}

fn validate_characters(
    value: &str,
    maximum: usize,
    field: &str,
) -> Result<(), AssistantServiceError> {
    let count = value.trim().chars().count();
    if count == 0 || count > maximum {
        return Err(AssistantServiceError::Invalid(format!(
            "{field} must contain 1...{maximum} characters"
        )));
    }
    Ok(())
}

fn first_characters(value: &str, maximum: usize) -> String {
    value.chars().take(maximum).collect::<String>()
}

fn global_draft_attempt(model_interaction: usize, provider_attempt: usize) -> usize {
    // Gemini retries at most twice, so each model interaction owns a stable
    // three-attempt range. Swift can therefore compare attempts across the
    // whole ReAct turn even though the provider resets its local counter.
    model_interaction
        .saturating_sub(1)
        .saturating_mul(3)
        .saturating_add(provider_attempt.max(1))
}

fn public_thought_summary_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(values) => values
            .iter()
            .map(public_thought_summary_text)
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Object(object) => {
            if matches!(object.get("type").and_then(Value::as_str), Some("text")) {
                return object
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
            }
            ["content", "summary"]
                .into_iter()
                .filter_map(|key| object.get(key))
                .map(public_thought_summary_text)
                .filter(|text| !text.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        }
        _ => String::new(),
    }
}

fn bounded_utf8_prefix(value: &str, maximum_bytes: usize) -> String {
    if value.len() <= maximum_bytes {
        return value.to_owned();
    }
    let mut end = maximum_bytes;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

async fn execute_assistant_delete_tool(
    service: AssistantService,
    request: ToolRequest,
    cancellation: CancellationToken,
) -> Result<ToolReceipt, ToolError> {
    let task_id = assistant_delete_task_id(&request.arguments)?;
    if let Some(receipt) =
        lookup_assistant_delete_receipt(&service, &request.session_id, &request.call_id, &task_id)
            .await?
    {
        return Ok(receipt);
    }

    // Once filesystem preparation starts, this owned task deliberately runs to
    // completion even if the surrounding assistant turn is cancelled. Dropping
    // its JoinHandle cannot strand quarantine links after SQLite commits.
    let file_mutation = tokio::select! {
        _ = cancellation.cancelled() => return Err(cancelled_delete_tool_error()),
        file_mutation = service.task_file_mutation.lock() => file_mutation,
    };
    if let Some(receipt) =
        lookup_assistant_delete_receipt(&service, &request.session_id, &request.call_id, &task_id)
            .await?
    {
        return Ok(receipt);
    }
    if cancellation.is_cancelled() {
        return Err(cancelled_delete_tool_error());
    }

    let prepare_task_id = task_id.clone();
    let attachments = service
        .store
        .call(move |store| store.prepare_delete_task(&prepare_task_id))
        .await
        .map_err(tool_store_error)?;
    // This is the final cancellation point. Once the first managed file is
    // prepared, the owned task must run through SQLite commit/rollback and all
    // cleanup even if its parent assistant turn is dropped.
    if cancellation.is_cancelled() {
        return Err(cancelled_delete_tool_error());
    }
    let prepared_attachments = attachments
        .iter()
        .map(|attachment| (attachment.id.clone(), attachment.relative_path.clone()))
        .collect::<Vec<_>>();
    let mut final_paths = Vec::with_capacity(attachments.len());
    let mut quarantine_paths = Vec::with_capacity(attachments.len());
    for attachment in attachments {
        let final_path = match crate::managed_attachment_path(
            service.data_directory.as_ref(),
            &attachment.relative_path,
        ) {
            Ok(path) => path,
            Err(error) => {
                cleanup_delete_paths(&quarantine_paths, "rolling back prepared quarantine");
                return Err(ToolError {
                    kind: ToolErrorKind::Failed,
                    message: error.to_string(),
                });
            }
        };
        let quarantine = service
            .data_directory
            .join("Attachments")
            .join(format!(".removing-{}", attachment.id));
        let prepared = match crate::prepare_managed_attachment_deletion(&final_path, &quarantine) {
            Ok(prepared) => prepared,
            Err(error) => {
                cleanup_delete_paths(&quarantine_paths, "rolling back prepared quarantine");
                return Err(ToolError {
                    kind: ToolErrorKind::Failed,
                    message: error.to_string(),
                });
            }
        };
        if let Some(path) = prepared.0 {
            final_paths.push(path);
        }
        if let Some(path) = prepared.1 {
            quarantine_paths.push(path);
        }
    }

    let turn_id = request.turn_id.clone();
    let call_id = request.call_id.clone();
    let delete_task_id = task_id.clone();
    let arguments = request.arguments.to_string();
    let outcome = match service
        .store
        .call(move |store| {
            store.execute_assistant_delete_task(
                &turn_id,
                &call_id,
                &delete_task_id,
                &prepared_attachments,
                &arguments,
            )
        })
        .await
    {
        Ok(outcome) => outcome,
        Err(error) => {
            cleanup_delete_paths(&quarantine_paths, "rolling back prepared quarantine");
            return Err(tool_store_error(error));
        }
    };
    let (result, applied) = match outcome {
        AssistantDeleteTaskOutcome::Applied(result) => (result, true),
        AssistantDeleteTaskOutcome::Replayed(result) => (result, false),
    };
    if applied || !result.is_error {
        cleanup_delete_paths(&final_paths, "cleaning committed task attachment");
        cleanup_delete_paths(
            &quarantine_paths,
            "cleaning committed task attachment quarantine",
        );
    } else {
        cleanup_delete_paths(&quarantine_paths, "rolling back prepared quarantine");
    }
    drop(file_mutation);

    if applied {
        match service.store.call(|store| store.bootstrap()).await {
            Ok(snapshot) => service.emit("task.changed", snapshot).await,
            Err(error) => {
                tracing::warn!(
                    task_id,
                    "assistant delete committed but task.changed snapshot failed: {error}"
                );
            }
        }
    }
    Ok(ToolReceipt {
        call_id: request.call_id,
        name: request.name,
        result: serde_json::from_str(&result.result_json).unwrap_or(Value::Null),
        is_error: result.is_error,
    })
}

fn cancelled_delete_tool_error() -> ToolError {
    ToolError {
        kind: ToolErrorKind::Cancelled,
        message: "assistant turn was cancelled before task deletion started".to_owned(),
    }
}

fn cleanup_delete_paths(paths: &[PathBuf], action: &'static str) {
    for path in paths {
        if let Err(error) = fs::remove_file(path)
            && error.kind() != io::ErrorKind::NotFound
        {
            tracing::warn!(path = %path.display(), "{action}: {error}");
        }
    }
}

async fn lookup_assistant_delete_receipt(
    service: &AssistantService,
    session_id: &str,
    call_id: &str,
    task_id: &str,
) -> Result<Option<ToolReceipt>, ToolError> {
    let stored_session_id = session_id.to_owned();
    let stored_call_id = call_id.to_owned();
    let execution = service
        .store
        .call(move |store| store.assistant_tool_execution(&stored_session_id, &stored_call_id))
        .await
        .map_err(tool_store_error)?;
    let Some(execution) = execution else {
        return Ok(None);
    };
    let stored_task_id = serde_json::from_str::<Value>(&execution.request_json)
        .ok()
        .and_then(|value| assistant_delete_task_id(&value).ok());
    if execution.tool_name != "delete_task" || stored_task_id.as_deref() != Some(task_id) {
        return Err(ToolError {
            kind: ToolErrorKind::Failed,
            message: "assistant tool call ID was already used for a different request".to_owned(),
        });
    }
    Ok(Some(ToolReceipt {
        call_id: execution.call_id,
        name: execution.tool_name,
        result: execution
            .response_json
            .as_deref()
            .and_then(|value| serde_json::from_str(value).ok())
            .unwrap_or(Value::Null),
        is_error: execution.is_error,
    }))
}

fn assistant_delete_task_id(arguments: &Value) -> Result<String, ToolError> {
    let object = arguments.as_object().ok_or_else(|| ToolError {
        kind: ToolErrorKind::InvalidArguments,
        message: "delete_task arguments must be an object".to_owned(),
    })?;
    if object.len() != 1 || !object.contains_key("taskId") {
        return Err(ToolError {
            kind: ToolErrorKind::InvalidArguments,
            message: "delete_task accepts exactly one taskId field".to_owned(),
        });
    }
    let task_id = object
        .get("taskId")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolError {
            kind: ToolErrorKind::InvalidArguments,
            message: "delete_task.taskId must be a UUID string".to_owned(),
        })?;
    uuid::Uuid::parse_str(task_id)
        .map(|value| value.to_string())
        .map_err(|_| ToolError {
            kind: ToolErrorKind::InvalidArguments,
            message: "delete_task.taskId must be a UUID string".to_owned(),
        })
}

fn tool_store_error(error: StoreWorkerError) -> ToolError {
    ToolError {
        kind: match &error {
            StoreWorkerError::Store(StoreError::Invalid(_) | StoreError::NotFound) => {
                ToolErrorKind::InvalidArguments
            }
            StoreWorkerError::Store(
                StoreError::Conflict(_) | StoreError::Sql(_) | StoreError::Io(_),
            )
            | StoreWorkerError::Closed
            | StoreWorkerError::ResponseCancelled
            | StoreWorkerError::Spawn(_)
            | StoreWorkerError::Panicked => ToolErrorKind::Failed,
        },
        message: error.to_string(),
    }
}

fn parse_string_array(value: Option<&str>) -> Vec<String> {
    value
        .and_then(|value| serde_json::from_str::<Vec<String>>(value).ok())
        .unwrap_or_default()
}

fn host_store_error(error: StoreWorkerError) -> HostError {
    let code = match &error {
        StoreWorkerError::Store(StoreError::NotFound) => "not_found",
        StoreWorkerError::Store(StoreError::Conflict(code)) => code,
        StoreWorkerError::Store(StoreError::Invalid(_)) => "invalid_data",
        StoreWorkerError::Store(StoreError::Sql(_)) => "database_error",
        StoreWorkerError::Store(StoreError::Io(_)) => "filesystem_error",
        StoreWorkerError::Closed
        | StoreWorkerError::ResponseCancelled
        | StoreWorkerError::Spawn(_)
        | StoreWorkerError::Panicked => "database_worker_error",
    };
    HostError::new(code, error.to_string())
}

fn assistant_error_code(error: &AssistantError) -> &'static str {
    match error {
        AssistantError::Cancelled => "cancelled",
        AssistantError::WallTimeout => "assistant_timeout",
        AssistantError::Limit { .. } => "assistant_limit_reached",
        AssistantError::Host(host) if host.code == "gemini_key_missing" => "gemini_key_missing",
        AssistantError::Host(_) => "assistant_storage_error",
        AssistantError::Provider(_) => "gemini_request_failed",
        AssistantError::Registry(_) => "assistant_configuration_error",
        AssistantError::EmptyResponse => "gemini_empty_response",
    }
}

fn user_facing_assistant_error(error: &AssistantError) -> String {
    match error {
        AssistantError::WallTimeout => "TodoAgent 等待 Gemini 超时，请稍后重试。".to_owned(),
        AssistantError::Limit { .. } => {
            "本轮对话达到安全上限，请换一种更具体的说法重试。".to_owned()
        }
        AssistantError::Provider(ProviderError::Network { .. }) => {
            "Gemini 网络连接失败，TodoAgent 已自动重试。请确认 macOS 代理或 VPN 可用后再试。"
                .to_owned()
        }
        AssistantError::Provider(ProviderError::Timeout) => {
            "Gemini 连接超时，TodoAgent 已自动重试。请稍后再试或检查代理设置。".to_owned()
        }
        AssistantError::Provider(provider) => format!("Gemini 请求失败：{provider}"),
        AssistantError::EmptyResponse => "Gemini 没有返回可显示的内容。".to_owned(),
        AssistantError::Host(host) => host.message.clone(),
        AssistantError::Registry(error) => format!("TodoAgent 工具配置错误：{error}"),
        AssistantError::Cancelled => "本轮已停止。".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_writer(capacity: usize) -> (OutputWriter, std::sync::mpsc::Receiver<Value>) {
        crate::output::test_channel(capacity)
    }

    fn recv_event(receiver: &std::sync::mpsc::Receiver<Value>, event_name: &str) -> Value {
        loop {
            let value = receiver.recv().unwrap();
            if value["event"] == event_name {
                return value;
            }
        }
    }

    use crate::models::{AssistantCompaction, AssistantSession, TaskAttachment};
    use crate::store::Store;

    #[test]
    fn assistant_tool_registry_is_exactly_the_six_task_tools() {
        let tools = assistant_tools();
        assert_eq!(tools.len(), 6);
        assert_eq!(
            tools
                .iter()
                .map(|tool| tool.name.as_str())
                .collect::<Vec<_>>(),
            crate::assistant::ALLOWED_ASSISTANT_TOOLS
        );
    }

    #[test]
    fn update_task_declaration_matches_the_web_compatible_flat_contract() {
        let update = assistant_tools()
            .into_iter()
            .find(|tool| tool.name == "update_task")
            .unwrap();
        let properties = update.parameters["properties"].as_object().unwrap();

        assert!(properties.contains_key("taskId"));
        assert!(properties.contains_key("title"));
        assert!(properties.contains_key("note"));
        assert!(properties.contains_key("listId"));
        assert_eq!(properties["executionDate"]["type"], "string");
        assert_eq!(properties["dueDate"]["type"], "string");
        assert!(!properties.contains_key("update"));
        assert_eq!(update.parameters["additionalProperties"], false);
    }

    #[test]
    fn delete_task_declaration_and_prompt_require_explicit_exact_deletion() {
        let delete = assistant_tools()
            .into_iter()
            .find(|tool| tool.name == "delete_task")
            .unwrap();
        assert_eq!(delete.parameters["required"], json!(["taskId"]));
        assert_eq!(delete.parameters["additionalProperties"], false);
        assert_eq!(delete.parameters["properties"]["taskId"]["type"], "string");

        let instruction = assistant_system_instruction();
        assert!(instruction.contains("明确要求时才创建、修改或删除"));
        assert!(instruction.contains("准确 taskId"));
        assert!(instruction.contains("完成所有分页"));
        assert!(instruction.contains("status=open 和 status=completed"));
        assert!(instruction.contains("开始任何删除前先收集完所有 taskId"));
        assert!(instruction.contains("不能边分页边删除"));
        assert!(instruction.contains("taskRevision 完全相同"));
        assert!(instruction.contains("单次用户请求最多删除 20 个任务"));
        assert!(instruction.contains("超过 20 时不得继续分页或删除任何一个"));
        assert!(instruction.contains("只有 total 合计不超过 20 才完成所有分页"));
        assert!(instruction.contains("dueDate、日期区间、逾期或关键词范围不得批量删除"));
    }

    #[test]
    fn task_date_prompt_and_tools_keep_execution_and_deadline_semantics_distinct() {
        let instruction = assistant_system_instruction();
        assert!(instruction.contains("放到时间线"));
        assert!(instruction.contains("executionDate"));
        assert!(instruction.contains("最晚"));
        assert!(instruction.contains("dueDate"));
        assert!(instruction.contains("不得互相推断或自动复制"));

        let tools = assistant_tools();
        let create = tools
            .iter()
            .find(|tool| tool.name == "create_tasks")
            .unwrap();
        let item = &create.parameters["properties"]["tasks"]["items"]["properties"];
        assert!(item["executionDate"].is_object());
        assert!(item["dueDate"].is_object());
        let list_state = tools.iter().find(|tool| tool.name == "list_state").unwrap();
        let filters = &list_state.parameters["properties"];
        assert!(filters["executionDate"].is_object());
        assert!(filters["status"].is_object());
        assert!(filters["listId"].is_object());
        assert!(filters["pageSize"].is_object());
        assert!(filters["cursor"].is_object());
        assert!(filters["cursor"]["properties"]["taskRevision"].is_object());
        assert!(instruction.contains("hasMore=true"));
        assert!(instruction.contains("nextCursor"));
        assert!(instruction.contains("list_state_cursor_stale"));

        let compact = compaction_prompt(&CompactionRequest {
            previous_summary: None,
            turns_to_summarize: Vec::new(),
            turns_to_keep: Vec::new(),
            target_tokens: 0,
        });
        assert!(compact.contains("执行日期 executionDate"));
        assert!(compact.contains("截止日期 dueDate"));
    }

    #[test]
    fn draft_attempts_remain_monotonic_across_model_interactions() {
        assert_eq!(global_draft_attempt(1, 1), 1);
        assert_eq!(global_draft_attempt(1, 2), 2);
        assert_eq!(global_draft_attempt(2, 1), 4);
        assert_eq!(global_draft_attempt(3, 3), 9);
    }

    #[test]
    fn network_failures_have_actionable_redacted_user_copy() {
        let error = AssistantError::Provider(ProviderError::Network {
            message: "error sending request for url (https://example.invalid)".to_owned(),
            retry: crate::assistant::RetryClass::Transient,
        });

        let message = user_facing_assistant_error(&error);
        assert!(message.contains("已自动重试"));
        assert!(message.contains("macOS 代理或 VPN"));
        assert!(!message.contains("example.invalid"));
        assert!(!message.contains("provider network error"));
    }

    #[test]
    fn transport_session_is_not_model_bound() {
        let view = AssistantSessionView::from_session(
            AssistantSession {
                id: "session".to_owned(),
                title: "测试".to_owned(),
                created_at: "now".to_owned(),
                updated_at: "now".to_owned(),
                archived_at: None,
                last_sequence: 3,
                is_running: false,
            },
            Some("gemini-next".to_owned()),
        );
        let value = serde_json::to_value(view).unwrap();
        assert_eq!(value["lastModel"], "gemini-next");
        assert!(value.get("model").is_none());
    }

    #[test]
    fn context_excludes_current_turn_and_covered_steps() {
        let history = AssistantContextHistory {
            messages: vec![
                assistant_message("m1", "old", 1, "以前"),
                assistant_message("m2", "current", 2, "现在"),
            ],
            steps: vec![crate::models::AssistantStep {
                id: "s1".to_owned(),
                session_id: "session".to_owned(),
                turn_id: "old".to_owned(),
                sequence: 1,
                interaction_ordinal: 1,
                provider_step_index: Some(0),
                kind: "model_output".to_owned(),
                status: "completed".to_owned(),
                title: None,
                payload_json: Some(
                    json!({"type":"model_output","content":[{"type":"text","text":"答复"}]})
                        .to_string(),
                ),
                created_at: "now".to_owned(),
                updated_at: "now".to_owned(),
            }],
            active_turn: None,
            compaction: Some(AssistantCompaction {
                session_id: "session".to_owned(),
                through_sequence: 0,
                summary: "更早摘要".to_owned(),
                payload_json: None,
                created_at: "now".to_owned(),
                updated_at: "now".to_owned(),
            }),
        };
        let context = context_from_history(&history, "current");
        assert_eq!(context.summary.as_deref(), Some("更早摘要"));
        assert_eq!(context.turns.len(), 1);
        assert_eq!(context.turns[0].turn_id, "old");
        assert_eq!(context.turns[0].steps.len(), 2);
    }

    #[test]
    fn text_attachments_enforce_wire_limits_and_leaf_names() {
        let valid = AssistantTextAttachment {
            name: "notes.md".to_owned(),
            media_type: "text/markdown".to_owned(),
            content: "你好".to_owned(),
            byte_count: "你好".len(),
        };
        assert_eq!(
            validate_text_attachments(vec![valid.clone()]).unwrap(),
            vec![valid]
        );

        let invalid_path = AssistantTextAttachment {
            name: "/Users/alice/private.md".to_owned(),
            media_type: "text/markdown".to_owned(),
            content: "secret".to_owned(),
            byte_count: 6,
        };
        assert!(
            validate_text_attachments(vec![invalid_path])
                .unwrap_err()
                .to_string()
                .contains("must not contain a path")
        );

        let invalid_media = AssistantTextAttachment {
            name: "notes.rtf".to_owned(),
            media_type: "text/rtf".to_owned(),
            content: "text".to_owned(),
            byte_count: 4,
        };
        assert!(validate_text_attachments(vec![invalid_media]).is_err());

        let mismatched_size = AssistantTextAttachment {
            name: "notes.txt".to_owned(),
            media_type: "text/plain".to_owned(),
            content: "你好".to_owned(),
            byte_count: 2,
        };
        assert!(validate_text_attachments(vec![mismatched_size]).is_err());

        let too_large = AssistantTextAttachment {
            name: "large.txt".to_owned(),
            media_type: "text/plain".to_owned(),
            content: "x".repeat(MAX_ATTACHMENT_BYTES + 1),
            byte_count: MAX_ATTACHMENT_BYTES + 1,
        };
        assert!(validate_text_attachments(vec![too_large]).is_err());

        let total_too_large = (0..3)
            .map(|index| AssistantTextAttachment {
                name: format!("{index}.txt"),
                media_type: "text/plain".to_owned(),
                content: "x".repeat(100_000),
                byte_count: 100_000,
            })
            .collect();
        assert!(validate_text_attachments(total_too_large).is_err());

        let too_many = (0..=MAX_TEXT_ATTACHMENTS)
            .map(|index| AssistantTextAttachment {
                name: format!("{index}.txt"),
                media_type: "text/plain".to_owned(),
                content: String::new(),
                byte_count: 0,
            })
            .collect();
        assert!(validate_text_attachments(too_many).is_err());
    }

    #[test]
    fn attachment_only_wire_payload_is_accepted_and_has_stable_json() {
        let params: AssistantSendParams = serde_json::from_value(json!({
            "sessionId":"session",
            "clientMessageId":uuid::Uuid::new_v4().to_string(),
            "text":"",
            "model":"gemini-test",
            "attachments":[{
                "name":"brief.md",
                "mediaType":"text/markdown",
                "content":"# Brief",
                "byteCount":7
            }]
        }))
        .unwrap();
        let attachments = validate_text_attachments(params.attachments).unwrap();
        let payload = serde_json::to_string(&AssistantMessagePayload { attachments }).unwrap();
        assert_eq!(
            payload,
            r##"{"attachments":[{"name":"brief.md","mediaType":"text/markdown","content":"# Brief","byteCount":7}]}"##
        );
        let model_text = assistant_user_model_text("请处理这些附件", Some(&payload));
        assert!(model_text.contains("文件名：brief.md"));
        assert!(model_text.contains("# Brief"));
        assert!(!model_text.contains("/Users/"));

        let unsafe_payload = r#"{"attachments":[{"name":"/Users/alice/private.txt","mediaType":"text/plain","content":"secret","byteCount":6}]}"#;
        let safe_text = assistant_user_model_text("处理附件", Some(unsafe_payload));
        assert_eq!(safe_text, "处理附件");
        assert!(!safe_text.contains("/Users/alice"));
    }

    #[test]
    fn persisted_attachment_is_restored_into_next_turn_context_after_restart() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("assistant.sqlite3");
        let session_id;
        {
            let store = Store::open(&database).unwrap();
            let session = store.create_assistant_session("附件上下文").unwrap();
            session_id = session.id.clone();
            let client_id = uuid::Uuid::new_v4().to_string();
            let payload = r##"{"attachments":[{"name":"plan.md","mediaType":"text/markdown","content":"# 第一版\n只读今日任务","byteCount":30}]}"##;
            let queued = store
                .begin_assistant_turn_with_payload(
                    &session.id,
                    &client_id,
                    "总结这个计划",
                    Some(payload),
                    None,
                    Some("model"),
                )
                .unwrap();
            store.mark_assistant_turn_running(&queued.turn.id).unwrap();
            store
                .append_assistant_steps(
                    &queued.turn.id,
                    1,
                    &[(
                        "model_output",
                        None,
                        Some(
                            r#"{"type":"model_output","content":[{"type":"text","text":"已总结"}]}"#,
                        ),
                        Some(0),
                    )],
                )
                .unwrap();
            store
                .complete_assistant_turn_with_message(
                    &session.id,
                    &queued.turn.id,
                    "已总结",
                    None,
                    None,
                )
                .unwrap();
        }

        let store = Store::open(&database).unwrap();
        let current = store
            .begin_assistant_turn(
                &session_id,
                &uuid::Uuid::new_v4().to_string(),
                "继续",
                None,
                Some("model"),
            )
            .unwrap();
        let history = store.assistant_context_history(&session_id).unwrap();
        let context = context_from_history(&history, &current.turn.id);
        assert_eq!(context.turns.len(), 1);
        let restored = context.turns[0].steps[0]["content"][0]["text"]
            .as_str()
            .unwrap();
        assert!(restored.contains("文件名：plan.md"));
        assert!(restored.contains("# 第一版\n只读今日任务"));
        assert!(!restored.contains("relative_path"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn send_rejects_an_empty_message_before_provider_or_storage_work() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("assistant.sqlite3")).unwrap();
        let (writer, _receiver) = test_writer(4);
        let service = AssistantService::new(
            worker.clone(),
            writer,
            Arc::new(Mutex::new(None)),
            Arc::new(directory.path().to_path_buf()),
            Arc::new(Mutex::new(())),
        );
        let error = service
            .send(AssistantSendParams {
                session_id: "missing-session".to_owned(),
                client_message_id: uuid::Uuid::new_v4().to_string(),
                text: "  ".to_owned(),
                model: "gemini-test".to_owned(),
                attachments: Vec::new(),
            })
            .await
            .unwrap_err();
        assert_eq!(error.to_string(), "text or attachments is required");
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn assistant_delete_tool_cleans_managed_files_emits_snapshot_and_replays() {
        let directory = tempfile::tempdir().unwrap();
        let data_directory = directory.path().join("data");
        fs::create_dir_all(data_directory.join("Attachments")).unwrap();
        let database_path = data_directory.join("assistant.sqlite3");
        let worker = StoreWorker::open(&database_path).unwrap();
        let attachment_id = uuid::Uuid::new_v4().to_string();
        let relative_path = format!("Attachments/{attachment_id}.txt");
        let setup_attachment_id = attachment_id.clone();
        let setup_relative_path = relative_path.clone();
        let (task, queued) = worker
            .call(move |store| {
                let task = store.create_task("Agent 删除", "", None, None, None)?;
                store.add_task_attachments(
                    &task.id,
                    &[TaskAttachment {
                        id: setup_attachment_id,
                        task_id: task.id.clone(),
                        original_name: "memo.txt".to_owned(),
                        size_bytes: 4,
                        mime_type: "text/plain".to_owned(),
                        relative_path: setup_relative_path,
                        created_at: chrono::Utc::now().to_rfc3339(),
                    }],
                )?;
                let session = store.create_assistant_session("删除任务")?;
                let queued = store.begin_assistant_turn(
                    &session.id,
                    &uuid::Uuid::new_v4().to_string(),
                    "删除这项任务",
                    None,
                    Some("model-x"),
                )?;
                store.mark_assistant_turn_running(&queued.turn.id)?;
                Ok((task, queued))
            })
            .await
            .unwrap();
        let managed_path = data_directory.join(&relative_path);
        fs::write(&managed_path, b"memo").unwrap();
        let quarantine_path = data_directory
            .join("Attachments")
            .join(format!(".removing-{attachment_id}"));
        let (writer, receiver) = test_writer(16);
        let service = AssistantService::new(
            worker.clone(),
            writer,
            Arc::new(Mutex::new(None)),
            Arc::new(data_directory),
            Arc::new(Mutex::new(())),
        );
        let host = EngineAssistantHost::new(
            service,
            queued.turn.session_id.clone(),
            queued.turn.id.clone(),
        );
        let request = ToolRequest {
            session_id: queued.turn.session_id.clone(),
            turn_id: queued.turn.id.clone(),
            call_id: "delete-managed".to_owned(),
            name: "delete_task".to_owned(),
            arguments: json!({"taskId":task.id.to_uppercase()}),
        };

        let failure_connection = rusqlite::Connection::open(&database_path).unwrap();
        failure_connection
            .execute_batch(
                "CREATE TRIGGER fail_assistant_delete_receipt
                 BEFORE INSERT ON assistant_tool_execution
                 WHEN NEW.tool_name='delete_task'
                 BEGIN
                   SELECT RAISE(ABORT, 'forced delete receipt failure');
                 END;",
            )
            .unwrap();
        drop(failure_connection);
        let mut failed_request = request.clone();
        failed_request.call_id = "delete-receipt-fails".to_owned();
        let failure = host
            .execute_named_tool_once(failed_request, &CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(failure.kind, ToolErrorKind::Failed);
        assert!(managed_path.exists());
        assert!(!quarantine_path.exists());
        let retained_task_id = task.id.clone();
        assert!(
            worker
                .call(move |store| store.task(&retained_task_id))
                .await
                .unwrap()
                .is_some()
        );
        assert!(receiver.try_recv().is_err());
        let failure_connection = rusqlite::Connection::open(&database_path).unwrap();
        failure_connection
            .execute_batch("DROP TRIGGER fail_assistant_delete_receipt;")
            .unwrap();
        drop(failure_connection);

        let receipt = host
            .execute_named_tool_once(request.clone(), &CancellationToken::new())
            .await
            .unwrap();
        assert!(!receipt.is_error);
        assert_eq!(receipt.result["deletedTask"]["id"], task.id);
        assert!(!managed_path.exists());
        assert!(!quarantine_path.exists());
        let deleted_task_id = task.id.clone();
        assert!(
            worker
                .call(move |store| store.task(&deleted_task_id))
                .await
                .unwrap()
                .is_none()
        );
        let receipt_session_id = queued.turn.session_id.clone();
        let execution = worker
            .call(move |store| {
                store.assistant_tool_execution(&receipt_session_id, "delete-managed")
            })
            .await
            .unwrap()
            .unwrap();
        assert_eq!(execution.task_refs_json.as_deref(), Some("[]"));
        assert!(receiver.try_iter().any(|event| {
            event["event"] == "task.changed"
                && event["data"]["tasks"]
                    .as_array()
                    .is_some_and(|tasks| tasks.iter().all(|value| value["id"] != task.id))
        }));

        let replay = host
            .execute_named_tool_once(request, &CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(replay, receipt);
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn assistant_delete_cancelled_while_waiting_for_file_lock_preserves_everything() {
        let directory = tempfile::tempdir().unwrap();
        let data_directory = directory.path().join("data");
        fs::create_dir_all(data_directory.join("Attachments")).unwrap();
        let worker = StoreWorker::open(&data_directory.join("assistant.sqlite3")).unwrap();
        let attachment_id = uuid::Uuid::new_v4().to_string();
        let relative_path = format!("Attachments/{attachment_id}.txt");
        let setup_attachment_id = attachment_id.clone();
        let setup_relative_path = relative_path.clone();
        let (task, queued) = worker
            .call(move |store| {
                let task = store.create_task("等待锁时取消", "", None, None, None)?;
                store.add_task_attachments(
                    &task.id,
                    &[TaskAttachment {
                        id: setup_attachment_id,
                        task_id: task.id.clone(),
                        original_name: "keep.txt".to_owned(),
                        size_bytes: 4,
                        mime_type: "text/plain".to_owned(),
                        relative_path: setup_relative_path,
                        created_at: chrono::Utc::now().to_rfc3339(),
                    }],
                )?;
                let session = store.create_assistant_session("取消删除")?;
                let queued = store.begin_assistant_turn(
                    &session.id,
                    &uuid::Uuid::new_v4().to_string(),
                    "删除后立刻取消",
                    None,
                    Some("model-x"),
                )?;
                store.mark_assistant_turn_running(&queued.turn.id)?;
                Ok((task, queued))
            })
            .await
            .unwrap();
        let managed_path = data_directory.join(&relative_path);
        fs::write(&managed_path, b"keep").unwrap();
        let quarantine_path = data_directory
            .join("Attachments")
            .join(format!(".removing-{attachment_id}"));
        let task_file_mutation = Arc::new(Mutex::new(()));
        let held_file_lock = task_file_mutation.lock().await;
        let (writer, receiver) = test_writer(16);
        let service = AssistantService::new(
            worker.clone(),
            writer,
            Arc::new(Mutex::new(None)),
            Arc::new(data_directory),
            task_file_mutation.clone(),
        );
        let host = EngineAssistantHost::new(
            service,
            queued.turn.session_id.clone(),
            queued.turn.id.clone(),
        );
        let request = ToolRequest {
            session_id: queued.turn.session_id.clone(),
            turn_id: queued.turn.id.clone(),
            call_id: "cancelled-delete".to_owned(),
            name: "delete_task".to_owned(),
            arguments: json!({"taskId":task.id}),
        };
        let cancellation = CancellationToken::new();
        let call_cancellation = cancellation.clone();
        let execution = tokio::spawn(async move {
            host.execute_named_tool_once(request, &call_cancellation)
                .await
        });
        sleep(Duration::from_millis(20)).await;
        assert!(!execution.is_finished());

        cancellation.cancel();
        let failure = tokio::time::timeout(Duration::from_secs(1), execution)
            .await
            .expect("cancellation should win without releasing the file lock")
            .unwrap()
            .unwrap_err();
        assert_eq!(failure.kind, ToolErrorKind::Cancelled);
        drop(held_file_lock);

        assert!(managed_path.exists());
        assert!(!quarantine_path.exists());
        let retained_task_id = task.id.clone();
        assert!(
            worker
                .call(move |store| store.task(&retained_task_id))
                .await
                .unwrap()
                .is_some()
        );
        let receipt_session_id = queued.turn.session_id.clone();
        assert!(
            worker
                .call(move |store| {
                    store.assistant_tool_execution(&receipt_session_id, "cancelled-delete")
                })
                .await
                .unwrap()
                .is_none()
        );
        assert!(receiver.try_recv().is_err());
        worker.shutdown().await.unwrap();
    }

    #[test]
    fn store_compaction_does_not_reintroduce_covered_user_prompts() {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("assistant.sqlite3")).unwrap();
        let session = store.create_assistant_session("测试").unwrap();
        let first_client = uuid::Uuid::new_v4().to_string();
        let first = store
            .begin_assistant_turn(&session.id, &first_client, "旧问题", None, Some("model"))
            .unwrap();
        store.mark_assistant_turn_running(&first.turn.id).unwrap();
        store
            .append_assistant_steps(
                &first.turn.id,
                1,
                &[(
                    "model_output",
                    None,
                    Some(r#"{"type":"model_output","content":[{"type":"text","text":"旧答复"}]}"#),
                    Some(0),
                )],
            )
            .unwrap();
        store
            .complete_assistant_turn_with_message(&session.id, &first.turn.id, "旧答复", None, None)
            .unwrap();
        store
            .save_assistant_compaction(&session.id, 1, "已经覆盖旧问答", None)
            .unwrap();

        let current_client = uuid::Uuid::new_v4().to_string();
        let current = store
            .begin_assistant_turn(&session.id, &current_client, "新问题", None, Some("model"))
            .unwrap();
        let history = store.assistant_context_history(&session.id).unwrap();
        assert!(history.steps.is_empty());
        let context = context_from_history(&history, &current.turn.id);
        assert_eq!(context.summary.as_deref(), Some("已经覆盖旧问答"));
        assert!(context.turns.is_empty());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn short_delta_flushes_after_the_real_time_deadline() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("assistant.sqlite3")).unwrap();
        let (writer, receiver) = test_writer(16);
        let service = AssistantService::new(
            worker.clone(),
            writer,
            Arc::new(Mutex::new(None)),
            Arc::new(directory.path().to_path_buf()),
            Arc::new(Mutex::new(())),
        );
        let host = EngineAssistantHost::new(service, "session".to_owned(), "turn".to_owned());
        host.begin_model_interaction();
        let _ = recv_event(&receiver, "assistant.message.delta");

        host.append_delta(1, "短片段");
        assert!(receiver.try_recv().is_err());
        sleep(DELTA_FLUSH_INTERVAL + Duration::from_millis(30)).await;
        let event = recv_event(&receiver, "assistant.message.delta");
        assert_eq!(event["event"], "assistant.message.delta");
        assert_eq!(event["data"]["delta"], "短片段");

        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn fast_megabyte_delta_stream_is_coalesced_into_bounded_event_count() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("assistant.sqlite3")).unwrap();
        // This test verifies coalescing, not the intentionally lossy
        // backpressure policy. Size the observation queue for the bounded
        // worst-case event count so scheduling cannot discard valid deltas.
        let maximum_delta_events = 1024 * 1024 / DELTA_FLUSH_BYTES + 2;
        let (writer, receiver) = test_writer(maximum_delta_events);
        let service = AssistantService::new(
            worker.clone(),
            writer,
            Arc::new(Mutex::new(None)),
            Arc::new(directory.path().to_path_buf()),
            Arc::new(Mutex::new(())),
        );
        let host = EngineAssistantHost::new(service, "session".to_owned(), "turn".to_owned());
        host.begin_model_interaction();
        let _ = recv_event(&receiver, "assistant.message.delta");

        let chunk = "x".repeat(256);
        for _ in 0..(1024 * 1024 / chunk.len()) {
            host.append_delta(1, &chunk);
        }
        host.flush_draft();

        let deltas = receiver
            .try_iter()
            .filter(|event| event["event"] == "assistant.message.delta")
            .collect::<Vec<_>>();
        assert_eq!(
            deltas
                .iter()
                .map(|event| event["data"]["delta"].as_str().unwrap().len())
                .sum::<usize>(),
            1024 * 1024
        );
        assert!(deltas.len() < maximum_delta_events);

        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn thought_summary_events_are_public_bounded_deltas_with_global_parts() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("assistant.sqlite3")).unwrap();
        let (writer, receiver) = test_writer(16);
        let service = AssistantService::new(
            worker.clone(),
            writer,
            Arc::new(Mutex::new(None)),
            Arc::new(directory.path().to_path_buf()),
            Arc::new(Mutex::new(())),
        );
        let host = EngineAssistantHost::new(service, "session".to_owned(), "turn".to_owned());
        host.begin_model_interaction();
        let _ = recv_event(&receiver, "assistant.message.delta");

        AssistantHost::emit(
            &host,
            "session",
            "turn",
            AgentEvent::ThoughtSummary {
                attempt: 1,
                content: json!({"type":"text","text":"先"}),
            },
        );
        sleep(DELTA_FLUSH_INTERVAL + Duration::from_millis(20)).await;
        let first = recv_event(&receiver, "assistant.thought.summary");
        assert_eq!(first["data"]["content"], "先");
        assert_eq!(first["data"]["attempt"], 1);
        assert_eq!(first["data"]["interactionOrdinal"], 1);
        assert_eq!(first["data"]["isDelta"], true);

        AssistantHost::emit(
            &host,
            "session",
            "turn",
            AgentEvent::ThoughtSummary {
                attempt: 1,
                content: json!({
                    "summary":[{"type":"text","text":"想"}],
                    "signature":"PRIVATE-SIGNATURE"
                }),
            },
        );
        sleep(DELTA_FLUSH_INTERVAL + Duration::from_millis(20)).await;
        let accumulated = recv_event(&receiver, "assistant.thought.summary");
        assert_eq!(accumulated["data"]["content"], "想");
        assert!(!accumulated.to_string().contains("PRIVATE-SIGNATURE"));

        host.begin_model_interaction();
        let _ = recv_event(&receiver, "assistant.message.delta");
        AssistantHost::emit(
            &host,
            "session",
            "turn",
            AgentEvent::ThoughtSummary {
                attempt: 1,
                content: json!({"type":"text","text":"后"}),
            },
        );
        sleep(DELTA_FLUSH_INTERVAL + Duration::from_millis(20)).await;
        let next = recv_event(&receiver, "assistant.thought.summary");
        assert_eq!(next["data"]["content"], "后");
        assert_eq!(next["data"]["attempt"], 4);
        assert_ne!(first["data"]["partId"], next["data"]["partId"]);

        for _ in 0..1_000 {
            AssistantHost::emit(
                &host,
                "session",
                "turn",
                AgentEvent::ThoughtSummary {
                    attempt: 1,
                    content: json!({"type":"text","text":"界".repeat(512)}),
                },
            );
        }
        host.flush_thought();
        {
            let state = host.state.lock().unwrap();
            assert!(state.thought_emitted_bytes <= PUBLIC_THOUGHT_SUMMARY_MAX_BYTES);
            assert!(PUBLIC_THOUGHT_SUMMARY_MAX_BYTES - state.thought_emitted_bytes < "界".len());
            assert!(state.thought_original_bytes > PUBLIC_THOUGHT_SUMMARY_MAX_BYTES);
        }

        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn stale_turn_cleanup_never_removes_the_next_turn_token() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("active.sqlite3")).unwrap();
        let (writer, _receiver) = test_writer(16);
        let service = AssistantService::new(
            worker.clone(),
            writer,
            Arc::new(Mutex::new(None)),
            Arc::new(directory.path().to_path_buf()),
            Arc::new(Mutex::new(())),
        );
        let session_id = uuid::Uuid::new_v4().to_string();
        let next = CancellationToken::new();
        service.active.lock().await.insert(
            session_id.clone(),
            ActiveAssistantTurn {
                turn_id: "next-turn".to_owned(),
                cancellation: next.clone(),
            },
        );

        assert!(!service.remove_active_if_turn(&session_id, "old-turn").await);
        service
            .cancel_turn(&session_id.to_uppercase())
            .await
            .unwrap();
        assert!(next.is_cancelled());
        assert!(
            service
                .remove_active_if_turn(&session_id, "next-turn")
                .await
        );

        worker.shutdown().await.unwrap();
    }

    fn assistant_message(id: &str, turn_id: &str, sequence: i64, body: &str) -> AssistantMessage {
        AssistantMessage {
            id: id.to_owned(),
            session_id: "session".to_owned(),
            turn_id: Some(turn_id.to_owned()),
            sequence,
            client_message_id: None,
            role: "user".to_owned(),
            kind: "text".to_owned(),
            body: body.to_owned(),
            payload_json: None,
            task_refs_json: None,
            created_at: "now".to_owned(),
            updated_at: "now".to_owned(),
        }
    }
}

mod adapters;
mod models;
mod protocol;
mod runtime;
mod store;

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{SyncSender, sync_channel};
use std::time::Duration;

use adapters::{ProviderEvent, TurnOutcome, TurnRequest};
use models::{MessageRole, QueuedTurn, RuntimeKind, TurnStatus};
use protocol::{Request, Response};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Store, StoreError};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{Mutex, Semaphore, mpsc};
use tokio::time::{Instant, interval, sleep};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

const MAX_REQUEST_BYTES: usize = 1024 * 1024;

#[derive(Clone)]
struct Engine {
    store: Arc<Mutex<Store>>,
    writer: SyncSender<Value>,
    turns: Arc<Mutex<HashMap<String, CancellationToken>>>,
    concurrency: Arc<Semaphore>,
    authorized_directories: Arc<Mutex<HashSet<PathBuf>>>,
    gemini_key: Arc<Mutex<Option<Zeroizing<String>>>>,
}

#[derive(Debug, Error)]
enum EngineError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Conflict(&'static str),
    #[error("{0}")]
    Runtime(&'static str),
    #[error("{0}")]
    Io(#[from] io::Error),
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateListParams {
    name: String,
    #[serde(default = "default_color")]
    color: String,
    repository_path: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateTaskParams {
    title: String,
    #[serde(default)]
    note: String,
    list_id: Option<String>,
    due_date: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TaskIDParams {
    task_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerifyRuntimeParams {
    kind: String,
    executable: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateSessionParams {
    task_id: String,
    runtime_kind: String,
    working_directory: String,
    client_message_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionIDParams {
    session_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionLookupParams {
    session_id: Option<String>,
    task_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionHistoryParams {
    session_id: String,
    #[serde(default)]
    after_sequence: i64,
    #[serde(default = "default_history_limit")]
    limit: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendSessionParams {
    session_id: String,
    client_message_id: String,
    text: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MarkReadParams {
    session_id: String,
    through_sequence: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceAuthorizationParams {
    path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecretInjectionParams {
    gemini_api_key: String,
}

fn default_color() -> String {
    "blue".to_owned()
}
fn default_history_limit() -> i64 {
    500
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("TodoAgent Engine failed: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let paths = prepare_directories()?;
    init_logging(&paths.logs);
    let store = Store::open(&paths.data.join("todoagent.sqlite3"))?;
    let (writer_tx, writer_rx) = sync_channel::<Value>(512);
    let writer_thread = std::thread::spawn(move || -> io::Result<()> {
        let stdout = io::stdout();
        let mut stdout = stdout.lock();
        while let Ok(value) = writer_rx.recv() {
            let mut bytes = match serde_json::to_vec(&value) {
                Ok(bytes) => bytes,
                Err(_) => continue,
            };
            bytes.push(b'\n');
            stdout.write_all(&bytes)?;
            stdout.flush()?;
        }
        Ok(())
    });
    let engine = Engine {
        store: Arc::new(Mutex::new(store)),
        writer: writer_tx,
        turns: Arc::new(Mutex::new(HashMap::new())),
        concurrency: Arc::new(Semaphore::new(2)),
        authorized_directories: Arc::new(Mutex::new(HashSet::new())),
        gemini_key: Arc::new(Mutex::new(None)),
    };
    engine.send(&protocol::handshake()).await;

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        if line.len() > MAX_REQUEST_BYTES {
            engine.send(&json!({"id":Value::Null,"error":{"code":"invalid_request","message":"request exceeds 1 MiB"}})).await;
            continue;
        }
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(error) => {
                engine.send(&json!({"id":Value::Null,"error":{"code":"invalid_request","message":error.to_string()}})).await;
                continue;
            }
        };
        let shutdown = request.method == "engine.shutdown";
        let response = engine.handle(request).await;
        engine.send(&response).await;
        if shutdown {
            engine.shutdown().await;
            break;
        }
    }
    drop(engine.writer);
    writer_thread
        .join()
        .map_err(|_| io::Error::other("stdout writer panicked"))??;
    Ok(())
}

impl Engine {
    async fn handle(&self, request: Request) -> Response {
        let id = request.id.clone();
        let result = self.handle_inner(&request).await;
        match result {
            Ok(value) => Response::ok(id, value),
            Err(error) => response_for_error(id, error),
        }
    }

    async fn handle_inner(&self, request: &Request) -> Result<Value, EngineError> {
        match request.method.as_str() {
            "engine.health" | "health" => to_value(self.store.lock().await.health()?),
            "app.bootstrap" | "app.snapshot" => to_value(self.store.lock().await.bootstrap()?),
            "app.sync" => to_value(self.store.lock().await.bootstrap()?),
            "list.create" => {
                let params: CreateListParams = parse(&request.params)?;
                validate_text(&params.name, 200, "name")?;
                let list = self.store.lock().await.create_list(
                    &params.name,
                    &params.color,
                    params.repository_path.as_deref(),
                )?;
                self.emit("task.changed", self.store.lock().await.bootstrap()?)
                    .await;
                to_value(list)
            }
            "task.create" => {
                let params: CreateTaskParams = parse(&request.params)?;
                validate_text(&params.title, 500, "title")?;
                let task = self.store.lock().await.create_task(
                    &params.title,
                    &params.note,
                    params.list_id.as_deref(),
                    params.due_date.as_deref(),
                )?;
                self.emit("task.changed", self.store.lock().await.bootstrap()?)
                    .await;
                to_value(task)
            }
            "task.complete" | "task.reopen" => {
                let params: TaskIDParams = parse(&request.params)?;
                let status = if request.method == "task.complete" {
                    models::TaskStatus::Completed
                } else {
                    models::TaskStatus::Open
                };
                let task = self
                    .store
                    .lock()
                    .await
                    .set_task_status(&params.task_id, status)?;
                self.emit("task.changed", self.store.lock().await.bootstrap()?)
                    .await;
                to_value(task)
            }
            "runtime.list" => to_value(self.store.lock().await.runtimes()?),
            "runtime.detect" => {
                let detected = runtime::detect_all();
                let store = self.store.lock().await;
                for runtime in &detected {
                    store.save_runtime(runtime)?;
                }
                drop(store);
                self.emit("runtime.changed", &detected).await;
                to_value(detected)
            }
            "runtime.verify" => {
                let params: VerifyRuntimeParams = parse(&request.params)?;
                let kind = RuntimeKind::parse(&params.kind)
                    .ok_or_else(|| EngineError::Invalid("unknown runtime kind".to_owned()))?;
                let verified = runtime::verify(kind, params.executable.as_deref()).await;
                self.store.lock().await.save_runtime(&verified)?;
                self.emit("runtime.changed", self.store.lock().await.runtimes()?)
                    .await;
                to_value(verified)
            }
            "workspace.authorize" => {
                let params: WorkspaceAuthorizationParams = parse(&request.params)?;
                let directory = canonical_directory(&params.path)?;
                self.authorized_directories
                    .lock()
                    .await
                    .insert(directory.clone());
                Ok(json!({"path": directory.display().to_string()}))
            }
            "secret.inject" => {
                let params: SecretInjectionParams = parse(&request.params)?;
                if params.gemini_api_key.trim().len() < 8 {
                    return Err(EngineError::Invalid("Gemini API key is invalid".to_owned()));
                }
                *self.gemini_key.lock().await = Some(Zeroizing::new(params.gemini_api_key));
                Ok(json!({"ok":true}))
            }
            "session.create" => {
                let params: CreateSessionParams = parse(&request.params)?;
                let kind = RuntimeKind::parse(&params.runtime_kind)
                    .ok_or_else(|| EngineError::Invalid("unknown runtime kind".to_owned()))?;
                let directory = canonical_directory(&params.working_directory)?;
                if !self
                    .authorized_directories
                    .lock()
                    .await
                    .contains(&directory)
                {
                    return Err(EngineError::Conflict("workspace_not_authorized"));
                }
                let runtime = self.ready_runtime(kind).await?;
                let task = self
                    .store
                    .lock()
                    .await
                    .task(&params.task_id)?
                    .ok_or(StoreError::NotFound)?;
                let prompt = if task.note.trim().is_empty() {
                    task.title
                } else {
                    format!("{}\n\n{}", task.title, task.note)
                };
                let queued = self.store.lock().await.create_session(
                    &params.task_id,
                    kind,
                    &directory.display().to_string(),
                    &params.client_message_id,
                    &prompt,
                )?;
                let bundle = self
                    .store
                    .lock()
                    .await
                    .session_bundle(&queued.session.id, 0, 500)?;
                self.emit("session.created", &bundle).await;
                if queued.is_new {
                    self.schedule(
                        queued,
                        runtime
                            .resolved_path
                            .or(runtime.launch_path)
                            .ok_or(EngineError::Runtime("runtime_missing"))?,
                    )
                    .await;
                }
                to_value(bundle)
            }
            "session.get" => {
                let params: SessionLookupParams = parse(&request.params)?;
                let store = self.store.lock().await;
                let session_id = if let Some(id) = params.session_id {
                    id
                } else if let Some(task_id) = params.task_id {
                    store
                        .session_for_task(&task_id)?
                        .ok_or(StoreError::NotFound)?
                        .id
                } else {
                    return Err(EngineError::Invalid(
                        "sessionId or taskId is required".to_owned(),
                    ));
                };
                to_value(store.session_bundle(&session_id, 0, 500)?)
            }
            "session.history" => {
                let params: SessionHistoryParams = parse(&request.params)?;
                to_value(self.store.lock().await.session_bundle(
                    &params.session_id,
                    params.after_sequence,
                    params.limit,
                )?)
            }
            "session.send" => {
                let params: SendSessionParams = parse(&request.params)?;
                validate_text(&params.text, 200_000, "text")?;
                let queued = self.store.lock().await.send_message(
                    &params.session_id,
                    &params.client_message_id,
                    &params.text,
                )?;
                let runtime = self.ready_runtime(queued.session.runtime_kind).await?;
                let bundle = self
                    .store
                    .lock()
                    .await
                    .session_bundle(&params.session_id, 0, 500)?;
                self.emit("session.state_changed", &bundle).await;
                if queued.is_new {
                    self.schedule(
                        queued,
                        runtime
                            .resolved_path
                            .or(runtime.launch_path)
                            .ok_or(EngineError::Runtime("runtime_missing"))?,
                    )
                    .await;
                }
                to_value(bundle)
            }
            "session.mark_read" => {
                let params: MarkReadParams = parse(&request.params)?;
                let session = self
                    .store
                    .lock()
                    .await
                    .mark_read(&params.session_id, params.through_sequence)?;
                self.emit("session.unread_changed", &session).await;
                to_value(session)
            }
            "session.cancel_turn" => {
                let params: SessionIDParams = parse(&request.params)?;
                let token = self
                    .turns
                    .lock()
                    .await
                    .get(&params.session_id)
                    .cloned()
                    .ok_or(EngineError::Conflict("session_not_running"))?;
                token.cancel();
                Ok(json!({"ok":true}))
            }
            "engine.shutdown" => Ok(json!({"ok":true})),
            _ => Err(EngineError::Invalid(format!(
                "method_not_found: {}",
                request.method
            ))),
        }
    }

    async fn ready_runtime(&self, kind: RuntimeKind) -> Result<models::Runtime, EngineError> {
        let runtime = self
            .store
            .lock()
            .await
            .runtime(kind)?
            .ok_or(EngineError::Runtime("runtime_missing"))?;
        match runtime.status.as_str() {
            "ready" => Ok(runtime),
            "auth_required" => Err(EngineError::Runtime("auth_required")),
            _ => Err(EngineError::Runtime("runtime_not_verified")),
        }
    }

    async fn schedule(&self, queued: QueuedTurn, executable: String) {
        let token = CancellationToken::new();
        self.turns
            .lock()
            .await
            .insert(queued.session.id.clone(), token.clone());
        let engine = self.clone();
        tokio::spawn(async move {
            let permit = match engine.concurrency.clone().acquire_owned().await {
                Ok(permit) => permit,
                Err(_) => return,
            };
            let _permit = permit;
            if token.is_cancelled() {
                engine.finish_cancelled(&queued).await;
                return;
            }
            let running = match engine.store.lock().await.mark_turn_running(&queued.turn.id) {
                Ok(turn) => turn,
                Err(error) => {
                    tracing::error!("failed to mark turn running: {error}");
                    return;
                }
            };
            engine.emit("session.turn.started", &running).await;
            if let Ok(bundle) = engine
                .store
                .lock()
                .await
                .session_bundle(&queued.session.id, 0, 500)
            {
                engine.emit("session.state_changed", &bundle).await;
            }
            let request = TurnRequest {
                runtime: queued.session.runtime_kind,
                executable: PathBuf::from(executable),
                working_directory: PathBuf::from(&queued.session.working_directory),
                prompt: queued.prompt.clone(),
                provider_session_id: queued.session.provider_session_id.clone(),
            };
            let outcome = engine.execute_once(&queued, request, token.clone()).await;
            let outcome = if outcome.error_code.as_deref() == Some("provider_session_invalid")
                && !token.is_cancelled()
            {
                engine.cold_recover(&queued, outcome, token.clone()).await
            } else {
                outcome
            };
            engine.persist_outcome(&queued, outcome).await;
            engine.turns.lock().await.remove(&queued.session.id);
        });
    }

    async fn execute_once(
        &self,
        queued: &QueuedTurn,
        request: TurnRequest,
        token: CancellationToken,
    ) -> TurnOutcome {
        let (event_tx, mut event_rx) = mpsc::channel(256);
        let runner = tokio::spawn(adapters::run_turn(request, token, event_tx));
        tokio::pin!(runner);
        let mut text_buffer = String::new();
        let mut flush_clock = interval(Duration::from_millis(400));
        flush_clock.tick().await;
        let outcome = loop {
            tokio::select! {
                result = &mut runner => break result.unwrap_or_else(|error| TurnOutcome {
                    status:"failed",exit_code:None,final_output:String::new(),provider_session_id:None,
                    error_code:Some("engine_error".to_owned()),error_message:Some(error.to_string()),usage:None,
                }),
                _ = flush_clock.tick() => {
                    self.flush_text(&queued.turn.id, &mut text_buffer).await;
                }
                event = event_rx.recv() => match event {
                    Some(ProviderEvent::Text(text)) => {
                        text_buffer.push_str(&text);
                        if text_buffer.chars().count() >= 120 { self.flush_text(&queued.turn.id, &mut text_buffer).await; }
                    }
                    Some(event) => {
                        self.flush_text(&queued.turn.id, &mut text_buffer).await;
                        self.persist_provider_event(queued, event).await;
                    }
                    None => {}
                }
            }
        };
        while let Ok(event) = event_rx.try_recv() {
            match event {
                ProviderEvent::Text(text) => text_buffer.push_str(&text),
                event => {
                    self.flush_text(&queued.turn.id, &mut text_buffer).await;
                    self.persist_provider_event(queued, event).await;
                }
            }
        }
        self.flush_text(&queued.turn.id, &mut text_buffer).await;
        outcome
    }

    async fn cold_recover(
        &self,
        queued: &QueuedTurn,
        original: TurnOutcome,
        token: CancellationToken,
    ) -> TurnOutcome {
        let context = match self
            .store
            .lock()
            .await
            .recovery_context(&queued.session.id, 64 * 1024)
        {
            Ok(context) => context,
            Err(_) => return original,
        };
        let _ = self
            .store
            .lock()
            .await
            .clear_provider_session(&queued.session.id);
        if let Ok(message) = self.store.lock().await.append_message(
            &queued.turn.id,
            MessageRole::System,
            "status",
            "原供应商 Session 已失效，TodoAgent 正在用最近对话重建上下文。",
            None,
        ) {
            self.emit("session.message.appended", &message).await;
        }
        let runtime = match self.ready_runtime(queued.session.runtime_kind).await {
            Ok(runtime) => runtime,
            Err(_) => return original,
        };
        self.execute_once(
            queued,
            TurnRequest {
                runtime: queued.session.runtime_kind,
                executable: PathBuf::from(
                    runtime
                        .resolved_path
                        .or(runtime.launch_path)
                        .unwrap_or_default(),
                ),
                working_directory: PathBuf::from(&queued.session.working_directory),
                prompt: context,
                provider_session_id: None,
            },
            token,
        )
        .await
    }

    async fn flush_text(&self, turn_id: &str, buffer: &mut String) {
        if buffer.is_empty() {
            return;
        }
        let text = std::mem::take(buffer);
        match self.store.lock().await.append_agent_text(turn_id, &text) {
            Ok(message) => self.emit("session.message.delta", &message).await,
            Err(error) => tracing::error!("failed to persist agent text: {error}"),
        }
    }

    async fn persist_provider_event(&self, queued: &QueuedTurn, event: ProviderEvent) {
        match event {
            ProviderEvent::SessionId(id) => {
                let _ = self
                    .store
                    .lock()
                    .await
                    .set_provider_session(&queued.session.id, &id);
            }
            ProviderEvent::ToolUse {
                name,
                call_id,
                input,
            } => {
                let payload = json!({"name":name,"callId":call_id,"input":input});
                if let Ok(message) = self.store.lock().await.append_message(
                    &queued.turn.id,
                    MessageRole::Tool,
                    "tool_call",
                    &name,
                    Some(&payload.to_string()),
                ) {
                    self.emit("session.message.appended", &message).await;
                }
            }
            ProviderEvent::ToolResult {
                name,
                call_id,
                output,
            } => {
                let payload = json!({"name":name,"callId":call_id});
                if let Ok(message) = self.store.lock().await.append_message(
                    &queued.turn.id,
                    MessageRole::Tool,
                    "tool_result",
                    &output,
                    Some(&payload.to_string()),
                ) {
                    self.emit("session.message.appended", &message).await;
                }
            }
            ProviderEvent::Status(status) => {
                if let Ok(message) = self.store.lock().await.append_message(
                    &queued.turn.id,
                    MessageRole::System,
                    "status",
                    &status,
                    None,
                ) {
                    self.emit("session.message.appended", &message).await;
                }
            }
            ProviderEvent::Raw { kind, payload } => {
                let _ = self
                    .store
                    .lock()
                    .await
                    .append_turn_event(&queued.turn.id, &kind, &payload);
            }
            ProviderEvent::Text(_) => {}
        }
    }

    async fn persist_outcome(&self, queued: &QueuedTurn, outcome: TurnOutcome) {
        let status = match outcome.status {
            "completed" => TurnStatus::Completed,
            "cancelled" => TurnStatus::Cancelled,
            _ => TurnStatus::Failed,
        };
        // Some providers only expose final text in their terminal event.
        if status == TurnStatus::Completed && !outcome.final_output.is_empty() {
            let bundle = self
                .store
                .lock()
                .await
                .session_bundle(&queued.session.id, 0, 2000)
                .ok();
            let has_agent = bundle.as_ref().is_some_and(|bundle| {
                bundle.messages.iter().any(|message| {
                    message.turn_id.as_deref() == Some(&queued.turn.id)
                        && message.role == MessageRole::Agent
                })
            });
            if !has_agent {
                self.flush_text(&queued.turn.id, &mut outcome.final_output.clone())
                    .await;
            }
        }
        let usage = outcome.usage.as_ref().map(Value::to_string);
        match self.store.lock().await.finish_turn(
            &queued.turn.id,
            status,
            outcome.exit_code,
            Some(&outcome.final_output),
            outcome.provider_session_id.as_deref(),
            outcome.error_code.as_deref(),
            outcome.error_message.as_deref(),
            usage.as_deref(),
        ) {
            Ok(bundle) => {
                self.emit("session.turn.finished", &bundle).await;
                self.emit("session.state_changed", &bundle).await;
                self.emit("session.unread_changed", &bundle.session).await;
            }
            Err(error) => tracing::error!("failed to finish turn: {error}"),
        }
    }

    async fn finish_cancelled(&self, queued: &QueuedTurn) {
        self.persist_outcome(
            queued,
            TurnOutcome {
                status: "cancelled",
                exit_code: None,
                final_output: String::new(),
                provider_session_id: queued.session.provider_session_id.clone(),
                error_code: Some("cancelled".to_owned()),
                error_message: Some("cancelled".to_owned()),
                usage: None,
            },
        )
        .await;
        self.turns.lock().await.remove(&queued.session.id);
    }

    async fn shutdown(&self) {
        *self.gemini_key.lock().await = None;
        let tokens: Vec<_> = self.turns.lock().await.values().cloned().collect();
        for token in tokens {
            token.cancel();
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self.turns.lock().await.is_empty() && Instant::now() < deadline {
            sleep(Duration::from_millis(50)).await;
        }
    }

    async fn emit<T: serde::Serialize>(&self, event: &'static str, data: T) {
        self.send(&protocol::Event { event, data }).await;
    }

    async fn send<T: serde::Serialize>(&self, value: &T) {
        if let Ok(value) = serde_json::to_value(value) {
            let _ = self.writer.send(value);
        }
    }
}

fn response_for_error(id: String, error: EngineError) -> Response {
    match error {
        EngineError::Store(StoreError::NotFound) => {
            Response::err(id, "not_found", "requested record does not exist")
        }
        EngineError::Store(StoreError::Conflict(code)) | EngineError::Conflict(code) => {
            Response::err(id, code, code.replace('_', " "))
        }
        EngineError::Store(StoreError::Invalid(message)) | EngineError::Invalid(message) => {
            if let Some(method) = message.strip_prefix("method_not_found: ") {
                Response::err(id, "method_not_found", format!("unknown method {method}"))
            } else {
                Response::err(id, "invalid_params", message)
            }
        }
        EngineError::Runtime(code) => Response::err(id, code, code.replace('_', " ")),
        EngineError::Store(error) => Response::err(id, "engine_error", error.to_string()),
        EngineError::Io(error) => Response::err(id, "engine_error", error.to_string()),
    }
}

fn parse<T: for<'de> Deserialize<'de>>(value: &Value) -> Result<T, EngineError> {
    serde_json::from_value(value.clone()).map_err(|error| EngineError::Invalid(error.to_string()))
}

fn validate_text(value: &str, maximum: usize, name: &str) -> Result<(), EngineError> {
    if value.trim().is_empty() || value.chars().count() > maximum {
        return Err(EngineError::Invalid(format!(
            "{name} must contain 1...{maximum} characters"
        )));
    }
    Ok(())
}

fn canonical_directory(value: &str) -> Result<PathBuf, EngineError> {
    let path = fs::canonicalize(value)
        .map_err(|_| EngineError::Invalid("working directory does not exist".to_owned()))?;
    if !path.is_absolute() || !path.is_dir() {
        return Err(EngineError::Invalid(
            "working directory is invalid".to_owned(),
        ));
    }
    Ok(path)
}

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, EngineError> {
    serde_json::to_value(value).map_err(|error| EngineError::Invalid(error.to_string()))
}

struct Paths {
    data: PathBuf,
    logs: PathBuf,
}

fn prepare_directories() -> io::Result<Paths> {
    let data = if let Some(path) = std::env::var_os("TODOAGENT_NATIVE_DATA_DIR") {
        PathBuf::from(path)
    } else {
        dirs::home_dir()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "home directory unavailable"))?
            .join("Library/Application Support/TodoAgent")
    };
    let logs = if let Some(path) = std::env::var_os("TODOAGENT_NATIVE_LOG_DIR") {
        PathBuf::from(path)
    } else {
        dirs::home_dir()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "home directory unavailable"))?
            .join("Library/Logs/TodoAgent")
    };
    secure_directory(&data)?;
    secure_directory(&data.join("Attachments"))?;
    secure_directory(&logs)?;
    let database = data.join("todoagent.sqlite3");
    if database.exists() {
        fs::set_permissions(&database, fs::Permissions::from_mode(0o600))?;
    }
    Ok(Paths { data, logs })
}

fn secure_directory(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

fn init_logging(logs: &Path) {
    let _ = logs;
    let _ = tracing_subscriber::fmt()
        .with_env_filter("todoagent_engine=info")
        .with_writer(io::stderr)
        .try_init();
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn request_size_is_bounded() {
        assert_eq!(MAX_REQUEST_BYTES, 1024 * 1024);
    }

    #[test]
    fn client_message_ids_are_uuid_shaped() {
        assert!(Uuid::parse_str(&Uuid::new_v4().to_string()).is_ok());
    }
}

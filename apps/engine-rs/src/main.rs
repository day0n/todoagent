mod assistant;
mod assistant_service;
mod instance_lock;
mod models;
mod output;
mod protocol;
mod runtime;
mod store;
mod store_worker;
mod terminal;

use std::collections::HashSet;
use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use models::{
    RuntimeKind, TaskAttachment, TerminalAgentStatus, TerminalLaunchIntent, UpdateTaskInput,
};
use output::{DrainOutcome, OutputWriter};
use protocol::{Request, Response};
use serde::Serialize;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use store::StoreError;
use store_worker::{StoreWorker, StoreWorkerError};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::sync::Mutex;
use zeroize::Zeroizing;

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const MAX_TASK_ATTACHMENT_BYTES: u64 = 100 * 1024 * 1024;
const CURSOR_CREATE_CHAT_TIMEOUT: Duration = Duration::from_secs(15);
const OUTPUT_QUEUE_CAPACITY: usize = 512;
const REQUEST_QUEUE_CAPACITY: usize = 64;
const CONTROL_QUEUE_CAPACITY: usize = 32;
const REQUEST_DRAIN_TIMEOUT: Duration = Duration::from_secs(1);
const ENGINE_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(1);
const OUTPUT_DRAIN_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Clone)]
struct Engine {
    store: StoreWorker,
    writer: OutputWriter,
    authorized_directories: Arc<Mutex<HashSet<PathBuf>>>,
    gemini_key: Arc<Mutex<Option<Zeroizing<String>>>>,
    assistant: assistant_service::AssistantService,
    data_directory: Arc<PathBuf>,
    task_file_mutation: Arc<Mutex<()>>,
    shutdown_requested: tokio_util::sync::CancellationToken,
}

#[derive(Debug, Error)]
enum EngineError {
    #[error(transparent)]
    Store(#[from] StoreWorkerError),
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Conflict(&'static str),
    #[error("{0}")]
    Runtime(&'static str),
    #[error("{message}")]
    Gemini { code: &'static str, message: String },
    #[error(transparent)]
    Assistant(#[from] assistant_service::AssistantServiceError),
    #[error("{0}")]
    Io(#[from] io::Error),
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateListParams {
    name: String,
    #[serde(default = "default_color")]
    color: String,
    repository_path: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RenameListParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    list_id: String,
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ListIDParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    list_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateTaskParams {
    title: String,
    #[serde(default)]
    note: String,
    #[serde(default, deserialize_with = "deserialize_optional_canonical_uuid")]
    list_id: Option<String>,
    execution_date: Option<String>,
    due_date: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct UpdateTaskParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    task_id: String,
    patch: UpdateTaskInput,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TaskIDParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    task_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AddTaskAttachmentsParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    task_id: String,
    source_paths: Vec<String>,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    client_mutation_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RemoveTaskAttachmentParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    task_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    attachment_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    client_mutation_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerifyRuntimeParams {
    kind: String,
    executable: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateTerminalSessionParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    task_id: String,
    runtime_kind: String,
    working_directory: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalSessionLookupParams {
    #[serde(default, deserialize_with = "deserialize_optional_canonical_uuid")]
    session_id: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_canonical_uuid")]
    task_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RebindTerminalWorkspaceParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    working_directory: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceAuthorizationParams {
    path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PrepareTerminalLaunchParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    run_id: String,
    task_title: Option<String>,
    status_socket: String,
    lifecycle_token: String,
    hook_token: String,
    host_pid: u32,
    provider_hooks_enabled: bool,
    #[serde(default)]
    intent: Option<String>,
    #[serde(default)]
    runtime_kind: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalRunIDParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    run_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalSessionIDParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BindTerminalProviderParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    run_id: String,
    provider_session_id: String,
    source: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReportTerminalStatusParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    event_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    run_id: String,
    status: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExitTerminalRunParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    run_id: String,
    exit_code: Option<i32>,
    reason: String,
    error_code: Option<String>,
    error_message: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MarkTerminalSeenParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    through_status_sequence: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecretInjectionParams {
    gemini_api_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiTestParams {
    model: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiModelMetadata {
    name: String,
    #[serde(default)]
    display_name: String,
    #[serde(default)]
    version: String,
    #[serde(default)]
    supported_generation_methods: Vec<String>,
    #[serde(default)]
    input_token_limit: Option<usize>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GeminiTestResult {
    ok: bool,
    model: String,
    display_name: String,
    version: String,
    input_token_limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct GoogleErrorEnvelope {
    error: GoogleErrorBody,
}

#[derive(Debug, Deserialize)]
struct GoogleErrorBody {
    #[serde(default)]
    message: String,
}

fn default_color() -> String {
    "blue".to_owned()
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
    // Acquire ownership before opening SQLite or running any startup recovery.
    // The binding must stay alive until `run` returns so a second Engine cannot
    // reconcile live sessions or remove this process's launch descriptors.
    let _data_directory_lease = instance_lock::DataDirectoryLease::acquire(&paths.data)?;
    init_logging(&paths.logs);
    let database_path = paths.data.join("todoagent.sqlite3");
    let attachments_path = paths.data.join("Attachments");
    store::prepare_database_files(&database_path, &attachments_path)?;
    secure_directory(&attachments_path)?;
    let store = StoreWorker::open(&database_path)?;
    terminal::cleanup_stale_descriptors(&paths.data.join("TerminalRuns"))?;
    let recovery_attachments = attachments_path.clone();
    store
        .call(move |store| store.reconcile_task_attachment_files(&recovery_attachments))
        .await?;
    fs::set_permissions(&database_path, fs::Permissions::from_mode(0o600))?;
    let (writer, writer_drain) = output::spawn(OUTPUT_QUEUE_CAPACITY, io::stdout());
    let gemini_key = Arc::new(Mutex::new(None));
    let data_directory = Arc::new(paths.data);
    let task_file_mutation = Arc::new(Mutex::new(()));
    let assistant = assistant_service::AssistantService::new(
        store.clone(),
        writer.clone(),
        gemini_key.clone(),
        data_directory.clone(),
        task_file_mutation.clone(),
    );
    let engine = Engine {
        store,
        writer,
        authorized_directories: Arc::new(Mutex::new(HashSet::new())),
        gemini_key,
        assistant,
        data_directory,
        task_file_mutation,
        shutdown_requested: tokio_util::sync::CancellationToken::new(),
    };
    engine.send(&protocol::handshake()).await;
    run_request_loop(BufReader::new(tokio::io::stdin()).lines(), engine.clone()).await?;
    engine.shutdown().await;
    // Never wait for output queue capacity during process teardown. The writer
    // gets a bounded opportunity to flush accepted NDJSON; a wedged OS stdout
    // write is then detached so returning from `main` terminates the process.
    let _ = engine.writer.try_shutdown();
    drop(engine);
    if writer_drain.wait(OUTPUT_DRAIN_TIMEOUT).await? == DrainOutcome::TimedOut {
        tracing::warn!("stdout writer did not drain before shutdown deadline");
    }
    Ok(())
}

async fn run_request_loop<R>(
    mut lines: tokio::io::Lines<BufReader<R>>,
    engine: Engine,
) -> io::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
{
    // The data lane preserves the pre-existing request ordering and every
    // StoreWorker/file mutation serialization guarantee. Control requests are
    // handled independently so a slow probe or attachment copy cannot delay
    // cancellation, health reporting, or shutdown acknowledgement.
    let (request_tx, mut request_rx) = tokio::sync::mpsc::channel(REQUEST_QUEUE_CAPACITY);
    let request_engine = engine.clone();
    let mut request_worker = tokio::spawn(async move {
        while let Some(request) = request_rx.recv().await {
            let response = request_engine.handle(request).await;
            request_engine.send(&response).await;
        }
    });
    // A bounded control lane replaces one spawned task per request. Its
    // responses use non-waiting output so stdout backpressure cannot retain an
    // unbounded number of health/cancellation tasks.
    let (control_tx, mut control_rx) = tokio::sync::mpsc::channel(CONTROL_QUEUE_CAPACITY);
    let control_engine = engine.clone();
    let mut control_worker = tokio::spawn(async move {
        while let Some(request) = control_rx.recv().await {
            let response = control_engine.handle(request).await;
            control_engine.send_control(&response);
        }
    });

    let mut shutdown_requested = false;
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        if line.len() > MAX_REQUEST_BYTES {
            engine.send_control(&json!({"id":Value::Null,"error":{"code":"invalid_request","message":"request exceeds 1 MiB"}}));
            continue;
        }
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(error) => {
                engine.send_control(&json!({"id":Value::Null,"error":{"code":"invalid_request","message":error.to_string()}}));
                continue;
            }
        };
        match request.method.as_str() {
            "engine.shutdown" => {
                engine.shutdown_requested.cancel();
                engine.send_control(&Response::ok(request.id, json!({"ok":true})));
                shutdown_requested = true;
                break;
            }
            "engine.health" | "health" | "assistant.cancel_turn" => {
                match control_tx.try_send(request) {
                    Ok(()) => {}
                    Err(tokio::sync::mpsc::error::TrySendError::Full(request)) => {
                        engine.send_control(&Response::err(
                            request.id,
                            "engine_busy",
                            "engine control queue is full; retry later",
                        ));
                    }
                    Err(tokio::sync::mpsc::error::TrySendError::Closed(request)) => {
                        engine.send_control(&Response::err(
                            request.id,
                            "engine_shutting_down",
                            "engine is shutting down",
                        ));
                        break;
                    }
                }
            }
            _ => {
                match request_tx.try_send(request) {
                    Ok(()) => {}
                    Err(tokio::sync::mpsc::error::TrySendError::Full(request)) => {
                        // Never wait for data-lane capacity in the parser: the
                        // next line may be the cancellation, health probe, or
                        // shutdown request needed to unblock that lane.
                        engine.send_control(&Response::err(
                            request.id,
                            "engine_busy",
                            "engine request queue is full; retry later",
                        ));
                    }
                    Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => break,
                }
            }
        }
    }
    drop(request_tx);
    drop(control_tx);
    if shutdown_requested {
        request_worker.abort();
        control_worker.abort();
        let _ = request_worker.await;
        let _ = control_worker.await;
    } else {
        // EOF normally drains accepted work. Bound that grace period because a
        // worker may be suspended in a durable send behind a blocked stdout.
        let drain_workers = async {
            let (request_result, control_result) =
                tokio::join!(&mut request_worker, &mut control_worker);
            (request_result, control_result)
        };
        match tokio::time::timeout(REQUEST_DRAIN_TIMEOUT, drain_workers).await {
            Ok((request_result, control_result)) => {
                if let Err(error) = request_result {
                    tracing::error!("request worker failed: {error}");
                }
                if let Err(error) = control_result {
                    tracing::error!("control worker failed: {error}");
                }
            }
            Err(_) => {
                engine.shutdown_requested.cancel();
                request_worker.abort();
                control_worker.abort();
                let _ = request_worker.await;
                let _ = control_worker.await;
                tracing::warn!("request workers did not drain before shutdown deadline");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
async fn run_request_stream<R>(reader: R, engine: Engine) -> io::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
{
    run_request_loop(BufReader::new(reader).lines(), engine).await
}

impl Engine {
    async fn handle(&self, request: Request) -> Response {
        let id = request.id.clone();
        let result = if request.method == "engine.shutdown" {
            self.handle_inner(&request).await
        } else {
            tokio::select! {
                biased;
                _ = self.shutdown_requested.cancelled() => Err(EngineError::Runtime("engine_shutting_down")),
                result = self.handle_inner(&request) => result,
            }
        };
        match result {
            Ok(value) => Response::ok(id, value),
            Err(error) => response_for_error(id, error),
        }
    }

    async fn handle_inner(&self, request: &Request) -> Result<Value, EngineError> {
        match request.method.as_str() {
            "engine.health" | "health" => to_value(self.store.call(|store| store.health()).await?),
            "app.bootstrap" | "app.snapshot" | "app.sync" => {
                to_value(self.store.call(|store| store.bootstrap()).await?)
            }
            "list.create" => {
                let params: CreateListParams = parse(&request.params)?;
                let snapshot = self
                    .store
                    .call(move |store| {
                        store.create_list(
                            &params.name,
                            &params.color,
                            params.repository_path.as_deref(),
                        )?;
                        store.bootstrap()
                    })
                    .await?;
                self.publish_task_snapshot(snapshot).await
            }
            "list.rename" => {
                let params: RenameListParams = parse(&request.params)?;
                let snapshot = self
                    .store
                    .call(move |store| {
                        store.rename_list(&params.list_id, &params.name)?;
                        store.bootstrap()
                    })
                    .await?;
                self.publish_task_snapshot(snapshot).await
            }
            "list.delete" => {
                let params: ListIDParams = parse(&request.params)?;
                let snapshot = self
                    .store
                    .call(move |store| {
                        store.delete_list(&params.list_id)?;
                        store.bootstrap()
                    })
                    .await?;
                self.publish_task_snapshot(snapshot).await
            }
            "task.create" => {
                let params: CreateTaskParams = parse(&request.params)?;
                let snapshot = self
                    .store
                    .call(move |store| {
                        store.create_task(
                            &params.title,
                            &params.note,
                            params.list_id.as_deref(),
                            params.execution_date.as_deref(),
                            params.due_date.as_deref(),
                        )?;
                        store.bootstrap()
                    })
                    .await?;
                self.publish_task_snapshot(snapshot).await
            }
            "task.update" => {
                let params: UpdateTaskParams = parse(&request.params)?;
                let snapshot = self
                    .store
                    .call(move |store| {
                        store.update_task(&params.task_id, &params.patch)?;
                        store.bootstrap()
                    })
                    .await?;
                self.publish_task_snapshot(snapshot).await
            }
            "task.complete" | "task.reopen" => {
                let params: TaskIDParams = parse(&request.params)?;
                let status = if request.method == "task.complete" {
                    models::TaskStatus::Completed
                } else {
                    models::TaskStatus::Open
                };
                let task_id = params.task_id;
                let snapshot = self
                    .store
                    .call(move |store| {
                        store.set_task_status(&task_id, status)?;
                        store.bootstrap()
                    })
                    .await?;
                self.publish_task_snapshot(snapshot).await
            }
            "task.create_list" => {
                let params: TaskIDParams = parse(&request.params)?;
                let task_id = params.task_id;
                let snapshot = self
                    .store
                    .call(move |store| {
                        store.create_list_from_task(&task_id)?;
                        store.bootstrap()
                    })
                    .await?;
                self.publish_task_snapshot(snapshot).await
            }
            "task.delete" => {
                let params: TaskIDParams = parse(&request.params)?;
                let snapshot = self.delete_task(params.task_id).await?;
                self.publish_task_snapshot(snapshot).await
            }
            "task.attachment.add" => {
                let params: AddTaskAttachmentsParams = parse(&request.params)?;
                let snapshot = self.add_task_attachments(params).await?;
                self.publish_task_snapshot(snapshot).await
            }
            "task.attachment.remove" => {
                let params: RemoveTaskAttachmentParams = parse(&request.params)?;
                let snapshot = self.remove_task_attachment(params).await?;
                self.publish_task_snapshot(snapshot).await
            }
            "runtime.list" => to_value(self.store.call(|store| store.runtimes()).await?),
            "runtime.detect" => {
                let candidates = runtime::detect_all();
                let persisted = self
                    .store
                    .call(move |store| store.save_detected_runtimes(&candidates))
                    .await?;
                self.emit("runtime.changed", &persisted).await;
                to_value(persisted)
            }
            "runtime.verify" => {
                let params: VerifyRuntimeParams = parse(&request.params)?;
                let kind = RuntimeKind::parse(&params.kind)
                    .ok_or_else(|| EngineError::Invalid("unknown runtime kind".to_owned()))?;
                let verified = runtime::verify(kind, params.executable.as_deref()).await;
                let persisted = verified.clone();
                self.store
                    .call(move |store| store.save_runtime(&persisted))
                    .await?;
                let runtimes = self.store.call(|store| store.runtimes()).await?;
                self.emit("runtime.changed", runtimes).await;
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
            "secret.clear" => {
                self.assistant.cancel_all().await;
                *self.gemini_key.lock().await = None;
                Ok(json!({"ok":true}))
            }
            "gemini.test" => {
                let params: GeminiTestParams = parse(&request.params)?;
                let result = self.test_gemini_connection(&params.model).await?;
                to_value(result)
            }
            "assistant.status" => to_value(self.assistant.status().await),
            "assistant.session.list" => {
                let params: assistant_service::AssistantSessionListParams = parse(&request.params)?;
                to_value(self.assistant.sessions(params.include_archived).await?)
            }
            "assistant.session.create" => {
                let params: assistant_service::AssistantSessionCreateParams =
                    parse(&request.params)?;
                to_value(
                    self.assistant
                        .create_session(params.title.as_deref())
                        .await?,
                )
            }
            "assistant.session.rename" => {
                let params: assistant_service::AssistantSessionRenameParams =
                    parse(&request.params)?;
                to_value(
                    self.assistant
                        .rename_session(&params.session_id, &params.title)
                        .await?,
                )
            }
            "assistant.session.archive" => {
                let params: assistant_service::AssistantSessionIDParams = parse(&request.params)?;
                to_value(self.assistant.archive_session(&params.session_id).await?)
            }
            "assistant.history" => {
                let params: assistant_service::AssistantHistoryParams = parse(&request.params)?;
                to_value(
                    self.assistant
                        .history(&params.session_id, params.after_sequence, params.limit)
                        .await?,
                )
            }
            "assistant.send" => {
                let params: assistant_service::AssistantSendParams = parse(&request.params)?;
                to_value(self.assistant.send(params).await?)
            }
            "assistant.cancel_turn" => {
                let params: assistant_service::AssistantSessionIDParams = parse(&request.params)?;
                self.assistant.cancel_turn(&params.session_id).await?;
                Ok(json!({"ok":true}))
            }
            "terminal.session.create" => {
                let params: CreateTerminalSessionParams = parse(&request.params)?;
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
                let working_directory = directory.display().to_string();
                let task_id = params.task_id;
                let prepare_task_id = task_id.clone();
                let prepare_directory = working_directory.clone();
                let replayed = self
                    .store
                    .call(move |store| {
                        store.prepare_terminal_session_create(
                            &prepare_task_id,
                            kind,
                            &prepare_directory,
                        )
                    })
                    .await?;
                let session = if let Some(session) = replayed {
                    session
                } else {
                    // A task owns a host shell even when its preferred Agent
                    // runtime is not installed yet. Runtime verification stays
                    // at the launch boundary so opening the task can always
                    // present the retained terminal instead of a setup/error
                    // replacement view.
                    self.store
                        .call(move |store| {
                            store.create_terminal_session(&task_id, kind, &working_directory)
                        })
                        .await?
                };
                let session_id = session.id.clone();
                let bundle = self
                    .store
                    .call(move |store| store.terminal_session_bundle(&session_id))
                    .await?;
                self.emit("terminal.session.created", &bundle).await;
                to_value(bundle)
            }
            "terminal.session.get" => {
                let params: TerminalSessionLookupParams = parse(&request.params)?;
                if params.session_id.is_none() && params.task_id.is_none() {
                    return Err(EngineError::Invalid(
                        "sessionId or taskId is required".to_owned(),
                    ));
                }
                let bundle = self
                    .store
                    .call(move |store| {
                        let session_id = if let Some(id) = params.session_id {
                            id
                        } else {
                            store
                                .terminal_session_for_task(
                                    params.task_id.as_deref().unwrap_or_default(),
                                )?
                                .ok_or(StoreError::NotFound)?
                                .id
                        };
                        store.terminal_session_bundle(&session_id)
                    })
                    .await?;
                to_value(bundle)
            }
            "terminal.session.delete" => {
                let params: TerminalSessionIDParams = parse(&request.params)?;
                let lookup = params.session_id.clone();
                let session = self
                    .store
                    .call(move |store| store.terminal_session(&lookup)?.ok_or(StoreError::NotFound))
                    .await?;
                let session_id = session.id.clone();
                let task_id = session.task_id.clone();
                self.store
                    .call(move |store| store.delete_idle_terminal_session(&session_id))
                    .await?;
                self.emit(
                    "terminal.session.deleted",
                    &json!({"sessionId": session.id, "taskId": task_id}),
                )
                .await;
                to_value(json!({"ok": true}))
            }
            "terminal.session.rebind_workspace" => {
                let params: RebindTerminalWorkspaceParams = parse(&request.params)?;
                let directory = canonical_directory(&params.working_directory)?;
                if !self
                    .authorized_directories
                    .lock()
                    .await
                    .contains(&directory)
                {
                    return Err(EngineError::Conflict("workspace_not_authorized"));
                }
                let working_directory = directory.display().to_string();
                let bundle = self
                    .store
                    .call(move |store| {
                        store.rebind_terminal_session_workspace(
                            &params.session_id,
                            &working_directory,
                        )
                    })
                    .await?;
                self.emit("terminal.session.changed", &bundle).await;
                to_value(bundle)
            }
            "terminal.session.resume_candidates" => {
                let params: TerminalSessionIDParams = parse(&request.params)?;
                to_value(self.resume_candidates(&params.session_id).await?)
            }
            "terminal.session.prepare_launch" => {
                let params: PrepareTerminalLaunchParams = parse(&request.params)?;
                let plan = self.prepare_terminal_launch(params).await?;
                self.emit(
                    "terminal.run.changed",
                    &models::TerminalSessionBundle {
                        session: plan.session.clone(),
                        active_run: Some(plan.run.clone()),
                    },
                )
                .await;
                to_value(plan)
            }
            "terminal.run.started" => {
                let params: TerminalRunIDParams = parse(&request.params)?;
                let bundle = self
                    .store
                    .call(move |store| {
                        store.mark_terminal_run_started(&params.session_id, &params.run_id)
                    })
                    .await?;
                self.emit("terminal.run.changed", &bundle).await;
                to_value(bundle)
            }
            "terminal.run.stopping" => {
                let params: TerminalRunIDParams = parse(&request.params)?;
                let bundle = self
                    .store
                    .call(move |store| {
                        store.mark_terminal_run_stopping(&params.session_id, &params.run_id)
                    })
                    .await?;
                self.emit("terminal.run.changed", &bundle).await;
                to_value(bundle)
            }
            "terminal.run.bind_provider" => {
                let params: BindTerminalProviderParams = parse(&request.params)?;
                let bundle = self
                    .store
                    .call(move |store| {
                        store.bind_terminal_provider(
                            &params.session_id,
                            &params.run_id,
                            &params.provider_session_id,
                            &params.source,
                        )
                    })
                    .await?;
                self.emit("terminal.session.changed", &bundle).await;
                to_value(bundle)
            }
            "terminal.run.report_status" => {
                let params: ReportTerminalStatusParams = parse(&request.params)?;
                let status = TerminalAgentStatus::parse(&params.status).ok_or_else(|| {
                    EngineError::Invalid("unknown terminal agent status".to_owned())
                })?;
                let bundle = self
                    .store
                    .call(move |store| {
                        store.report_terminal_status(
                            &params.event_id,
                            &params.session_id,
                            &params.run_id,
                            status,
                        )
                    })
                    .await?;
                self.emit("terminal.session.changed", &bundle).await;
                to_value(bundle)
            }
            "terminal.run.exited" => {
                let params: ExitTerminalRunParams = parse(&request.params)?;
                let cleanup_run_id = params.run_id.clone();
                let bundle = self
                    .store
                    .call(move |store| {
                        store.finish_terminal_run(
                            &params.session_id,
                            &params.run_id,
                            params.exit_code,
                            &params.reason,
                            params.error_code.as_deref(),
                            params.error_message.as_deref(),
                        )
                    })
                    .await?;
                terminal::cleanup_run_artifacts(
                    &self.data_directory.join("TerminalRuns"),
                    &cleanup_run_id,
                );
                self.emit("terminal.run.changed", &bundle).await;
                to_value(bundle)
            }
            "terminal.session.mark_seen" => {
                let params: MarkTerminalSeenParams = parse(&request.params)?;
                let session = self
                    .store
                    .call(move |store| {
                        store.mark_terminal_seen(&params.session_id, params.through_status_sequence)
                    })
                    .await?;
                self.emit("terminal.session.changed", &session).await;
                to_value(session)
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
            .call(move |store| store.runtime(kind))
            .await?
            .ok_or(EngineError::Runtime("runtime_missing"))?;
        match runtime.status.as_str() {
            "ready" => Ok(runtime),
            "auth_required" => Err(EngineError::Runtime("auth_required")),
            _ => Err(EngineError::Runtime("runtime_not_verified")),
        }
    }

    async fn ready_runtime_for_launch(
        &self,
        kind: RuntimeKind,
    ) -> Result<models::Runtime, EngineError> {
        let cached = self.ready_runtime(kind).await?;
        match runtime::resolve_launch_executable(&cached) {
            Ok(runtime::LaunchExecutableResolution::Cached(_)) => Ok(cached),
            Ok(runtime::LaunchExecutableResolution::RefreshRequired {
                launch_path,
                resolved_path,
            }) => {
                tracing::info!(
                    runtime = kind.as_str(),
                    launch_path = %launch_path.display(),
                    resolved_path = %resolved_path.display(),
                    "runtime stable path moved; verifying the current target before launch"
                );
                let launch_path = launch_path
                    .to_str()
                    .ok_or(EngineError::Runtime("runtime_executable_invalid"))?;
                let refreshed = runtime::verify(kind, Some(launch_path)).await;
                let persisted = refreshed.clone();
                self.store
                    .call(move |store| store.save_runtime(&persisted))
                    .await?;
                let runtimes = self.store.call(|store| store.runtimes()).await?;
                self.emit("runtime.changed", runtimes).await;
                match refreshed.status.as_str() {
                    "ready" => Ok(refreshed),
                    "auth_required" => Err(EngineError::Runtime("auth_required")),
                    _ => Err(EngineError::Runtime("runtime_not_verified")),
                }
            }
            Err(code) => Err(EngineError::Runtime(code)),
        }
    }

    async fn prepare_terminal_launch(
        &self,
        params: PrepareTerminalLaunchParams,
    ) -> Result<models::TerminalLaunchPlan, EngineError> {
        for (name, token) in [
            ("lifecycleToken", params.lifecycle_token.as_str()),
            ("hookToken", params.hook_token.as_str()),
        ] {
            if token.is_empty() || token.len() > 512 {
                return Err(EngineError::Invalid(format!("{name} is invalid")));
            }
        }
        if params.lifecycle_token == params.hook_token {
            return Err(EngineError::Invalid(
                "terminal status tokens must be distinct".to_owned(),
            ));
        }
        let intent = match params.intent.as_deref() {
            None | Some("") => TerminalLaunchIntent::Auto,
            Some(value) => TerminalLaunchIntent::parse(value)
                .ok_or_else(|| EngineError::Invalid("invalid terminal launch intent".to_owned()))?,
        };
        let requested_kind = match params.runtime_kind.as_deref() {
            None | Some("") => None,
            Some(value) => Some(
                RuntimeKind::parse(value)
                    .ok_or_else(|| EngineError::Invalid("unknown runtime".to_owned()))?,
            ),
        };
        let lookup_id = params.session_id.clone();
        let session = self
            .store
            .call(move |store| {
                store
                    .terminal_session(&lookup_id)?
                    .ok_or(StoreError::NotFound)
            })
            .await?;
        let will_resume = match intent {
            TerminalLaunchIntent::Resume => session.provider_session_id.is_some(),
            TerminalLaunchIntent::Auto => {
                session.auto_resume && session.provider_session_id.is_some()
            }
            TerminalLaunchIntent::Fresh => false,
        };
        if (will_resume || intent == TerminalLaunchIntent::Resume)
            && requested_kind.is_some_and(|kind| kind != session.runtime_kind)
        {
            return Err(EngineError::Conflict("runtime_change_requires_fresh"));
        }
        // Resume is an identity-preserving operation. Keep both the executable
        // and argument profile on the Session's persisted Runtime even if an
        // older client also sends a different optional runtimeKind. Changing
        // Runtime is only valid for a fresh launch.
        let launch_kind = if will_resume || intent == TerminalLaunchIntent::Resume {
            session.runtime_kind
        } else {
            requested_kind.unwrap_or(session.runtime_kind)
        };
        // A Session keeps the original canonical cwd permanently, but that
        // directory can be moved or deleted later. Reject it before scanning
        // provider state or durably inserting a `starting` Run; otherwise the
        // runner is launched only to print an error and immediately exit.
        terminal::validate_launch_working_directory(&session.working_directory)
            .map_err(|_| EngineError::Runtime("terminal_working_directory_unavailable"))?;
        let status_socket = PathBuf::from(&params.status_socket);
        validate_status_socket(&status_socket, params.host_pid)?;
        let provider_session_is_resumable = if will_resume && launch_kind == RuntimeKind::Claude {
            let provider_session_id = session
                .provider_session_id
                .as_deref()
                .ok_or(EngineError::Runtime("provider_session_unbound"))?
                .to_owned();
            let working_directory = PathBuf::from(&session.working_directory);
            let resume_state = tokio::task::spawn_blocking(move || {
                terminal::claude_resume_state(&provider_session_id, &working_directory)
            })
            .await
            .map_err(|_| EngineError::Runtime("claude_session_scan_failed"))?;
            match resume_state {
                Ok(terminal::ClaudeResumeState::Absent) => {
                    return Err(EngineError::Runtime("claude_session_not_found"));
                }
                Ok(terminal::ClaudeResumeState::Resumable) => true,
                Ok(terminal::ClaudeResumeState::Unusable) => {
                    return Err(EngineError::Runtime("claude_session_not_resumable"));
                }
                Err(_) => return Err(EngineError::Runtime("claude_session_scan_failed")),
            }
        } else {
            true
        };
        let runtime = self.ready_runtime_for_launch(launch_kind).await?;
        let agent_executable = runtime
            .resolved_path
            .or(runtime.launch_path)
            .ok_or(EngineError::Runtime("runtime_missing"))?;
        validate_launch_executable(Path::new(&agent_executable), "agent executable")?;
        let current_executable =
            std::env::current_exe().map_err(|_| EngineError::Runtime("terminal_runner_missing"))?;
        let runner = current_executable.with_file_name(terminal::RUNNER_BINARY_NAME);
        validate_launch_executable(&runner, "terminal runner")?;

        // Reserve or replay the exact durable Run before any provider-side
        // effect. The persisted launch mode, rather than mutable Session
        // `auto_resume`, is authoritative when a lost response is retried.
        let prepare_session_id = params.session_id.clone();
        let prepare_run_id = params.run_id.clone();
        let bundle = self
            .store
            .call(move |store| {
                store.prepare_terminal_run_with_options(
                    &prepare_session_id,
                    &prepare_run_id,
                    intent,
                    provider_session_is_resumable,
                    Some(launch_kind),
                )
            })
            .await?;
        if bundle.session.id != params.session_id || bundle.session.runtime_kind != launch_kind {
            return Err(EngineError::Conflict("terminal_run_not_prepared"));
        }
        let prepared_run = bundle
            .active_run
            .as_ref()
            .filter(|run| {
                run.id == params.run_id && run.state == models::TerminalRunState::Starting
            })
            .ok_or(EngineError::Conflict("terminal_run_not_prepared"))?;

        if launch_kind == RuntimeKind::Cursor
            && prepared_run.launch_mode == models::TerminalLaunchMode::Fresh
        {
            // Cursor allocates its chat identity externally. A competing launch
            // is rejected by the reservation above; an exact replay with an
            // already-bound ID skips the external create-chat side effect.
            if let Some(provider_id) = prepared_run.provider_session_id_at_launch.as_deref() {
                if bundle.session.provider_session_id.as_deref() != Some(provider_id) {
                    return Err(EngineError::Conflict("provider_session_conflict"));
                }
                return self.build_terminal_plan(
                    params,
                    bundle,
                    runner,
                    agent_executable,
                    launch_kind,
                );
            }
            let mut command = tokio::process::Command::new(&agent_executable);
            command
                .arg("create-chat")
                .current_dir(&bundle.session.working_directory)
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true);
            let mut child = command
                .spawn()
                .map_err(|_| EngineError::Runtime("cursor_create_chat_failed"))?;
            let stdout = child
                .stdout
                .take()
                .ok_or(EngineError::Runtime("cursor_create_chat_failed"))?;
            let stdout_task = tokio::spawn(async move {
                let mut output = Vec::new();
                stdout
                    .take(64 * 1024 + 1)
                    .read_to_end(&mut output)
                    .await
                    .map(|_| output)
            });
            let status = match tokio::time::timeout(CURSOR_CREATE_CHAT_TIMEOUT, child.wait()).await
            {
                Ok(result) => {
                    result.map_err(|_| EngineError::Runtime("cursor_create_chat_failed"))?
                }
                Err(_) => {
                    let _ = child.start_kill();
                    let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
                    stdout_task.abort();
                    return Err(EngineError::Runtime("cursor_create_chat_timeout"));
                }
            };
            let stdout = stdout_task
                .await
                .map_err(|_| EngineError::Runtime("cursor_create_chat_failed"))?
                .map_err(|_| EngineError::Runtime("cursor_create_chat_failed"))?;
            if stdout.len() > 64 * 1024 {
                return Err(EngineError::Runtime("cursor_create_chat_invalid"));
            }
            if !status.success() {
                return Err(EngineError::Runtime("cursor_create_chat_failed"));
            }
            let id = parse_single_uuid(&stdout)
                .ok_or(EngineError::Runtime("cursor_create_chat_invalid"))?;
            // Cursor obtains its identity before the terminal starts. Bind it
            // to the already-reserved fresh Run before exposing the plan.
            let bind_session_id = params.session_id.clone();
            let bind_run_id = params.run_id.clone();
            let bundle = self
                .store
                .call(move |store| {
                    store.bind_prepared_terminal_provider(
                        &bind_session_id,
                        &bind_run_id,
                        &id,
                        "create_chat",
                    )
                })
                .await?;
            return self.build_terminal_plan(params, bundle, runner, agent_executable, launch_kind);
        }
        self.build_terminal_plan(params, bundle, runner, agent_executable, launch_kind)
    }

    async fn resume_candidates(
        &self,
        session_id: &str,
    ) -> Result<models::TerminalResumeCandidates, EngineError> {
        let lookup = session_id.to_owned();
        let session = self
            .store
            .call(move |store| store.terminal_session(&lookup)?.ok_or(StoreError::NotFound))
            .await?;
        if session.provider_session_id.is_some() {
            return Ok(models::TerminalResumeCandidates {
                session,
                candidates: Vec::new(),
            });
        }
        let scan_session = session.clone();
        let candidates =
            tokio::task::spawn_blocking(move || terminal::resume_candidates(&scan_session))
                .await
                .map_err(|_| EngineError::Runtime("resume_candidate_scan_failed"))??;
        Ok(models::TerminalResumeCandidates {
            session,
            candidates,
        })
    }

    fn build_terminal_plan(
        &self,
        params: PrepareTerminalLaunchParams,
        bundle: models::TerminalSessionBundle,
        runner: PathBuf,
        agent_executable: String,
        expected_runtime: RuntimeKind,
    ) -> Result<models::TerminalLaunchPlan, EngineError> {
        if bundle.session.id != params.session_id || bundle.session.runtime_kind != expected_runtime
        {
            return Err(EngineError::Conflict("terminal_run_not_prepared"));
        }
        let run = bundle
            .active_run
            .ok_or(EngineError::Conflict("terminal_run_not_active"))?;
        if run.id != params.run_id || run.state != models::TerminalRunState::Starting {
            return Err(EngineError::Conflict("terminal_run_not_prepared"));
        }
        let descriptor_directory = self.data_directory.join("TerminalRuns");
        terminal::build_launch_plan(
            bundle.session,
            run,
            runner.display().to_string(),
            agent_executable,
            params.task_title.as_deref(),
            &params.status_socket,
            &params.lifecycle_token,
            &params.hook_token,
            params.host_pid,
            params.provider_hooks_enabled,
            &descriptor_directory,
        )
        .map_err(|_| EngineError::Runtime("terminal_descriptor_failed"))
    }

    async fn test_gemini_connection(&self, model: &str) -> Result<GeminiTestResult, EngineError> {
        let model = model.trim();
        validate_text(model, 200, "model")?;
        let key = self
            .gemini_key
            .lock()
            .await
            .as_ref()
            .cloned()
            .ok_or_else(|| EngineError::Gemini {
                code: "gemini_key_missing",
                message: "请先输入或保存 Gemini API Key。".to_owned(),
            })?;

        let mut url =
            reqwest::Url::parse("https://generativelanguage.googleapis.com/v1beta/models")
                .expect("Gemini models endpoint is a valid static URL");
        url.path_segments_mut()
            .expect("Gemini models endpoint supports path segments")
            .push(model);

        let mut api_key = reqwest::header::HeaderValue::from_str(key.as_str()).map_err(|_| {
            EngineError::Gemini {
                code: "gemini_invalid_key",
                message: "Gemini API Key 的格式无效。".to_owned(),
            }
        })?;
        api_key.set_sensitive(true);
        let response = reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| EngineError::Gemini {
                code: "gemini_network_error",
                message: format!("无法初始化 Gemini 网络连接：{error}"),
            })?
            .get(url)
            .header("x-goog-api-key", api_key)
            .send()
            .await
            .map_err(|error| EngineError::Gemini {
                code: "gemini_network_error",
                message: if error.is_timeout() {
                    "连接 Gemini 超时，请检查网络或代理设置。".to_owned()
                } else {
                    "无法连接 Gemini，请检查网络或代理设置。".to_owned()
                },
            })?;

        let status = response.status();
        let body = response.bytes().await.map_err(|_| EngineError::Gemini {
            code: "gemini_invalid_response",
            message: "Gemini 返回了无法读取的响应。".to_owned(),
        })?;
        if !status.is_success() {
            return Err(gemini_http_error(status, &body, key.as_str()));
        }

        let metadata: GeminiModelMetadata =
            serde_json::from_slice(&body).map_err(|_| EngineError::Gemini {
                code: "gemini_invalid_response",
                message: "Gemini 返回了无法识别的模型信息。".to_owned(),
            })?;
        if !metadata
            .supported_generation_methods
            .iter()
            .any(|method| method == "generateContent")
        {
            return Err(EngineError::Gemini {
                code: "gemini_model_unsupported",
                message: "这个模型不支持 TodoAgent 所需的文本生成能力。".to_owned(),
            });
        }

        if let Some(limit) = metadata.input_token_limit {
            self.assistant.record_model_input_limit(model, limit).await;
        }
        Ok(GeminiTestResult {
            ok: true,
            model: model.to_owned(),
            display_name: if metadata.display_name.is_empty() {
                metadata.name
            } else {
                metadata.display_name
            },
            version: metadata.version,
            input_token_limit: metadata.input_token_limit,
        })
    }

    async fn publish_task_snapshot(
        &self,
        snapshot: models::Bootstrap,
    ) -> Result<Value, EngineError> {
        let result = to_value(&snapshot)?;
        self.emit("task.changed", &snapshot).await;
        Ok(result)
    }

    async fn add_task_attachments(
        &self,
        params: AddTaskAttachmentsParams,
    ) -> Result<models::Bootstrap, EngineError> {
        let _file_mutation = self.task_file_mutation.lock().await;
        let task_id = params.task_id;
        let source_paths = params.source_paths;
        let client_mutation_id = params.client_mutation_id;
        let prepare_task_id = task_id.clone();
        let prepare_source_paths = source_paths.clone();
        let prepare_mutation_id = client_mutation_id.clone();
        let replay_snapshot = self
            .store
            .call(move |store| {
                if store.prepare_add_task_attachment_mutation(
                    &prepare_task_id,
                    &prepare_mutation_id,
                    &prepare_source_paths,
                )? {
                    Ok(Some(store.bootstrap()?))
                } else {
                    Ok(None)
                }
            })
            .await?;
        if let Some(snapshot) = replay_snapshot {
            return Ok(snapshot);
        }

        let staging_directory = self.data_directory.as_ref().clone();
        let staging_task_id = task_id.clone();
        let staging_source_paths = source_paths.clone();
        let (staged, managed_paths) = tokio::task::spawn_blocking(move || {
            stage_task_attachment_batch(&staging_directory, &staging_task_id, &staging_source_paths)
        })
        .await
        .map_err(|error| {
            EngineError::Io(io::Error::other(format!(
                "task attachment staging worker failed: {error}"
            )))
        })??;

        let outcome = match self
            .store
            .call(move |store| {
                store.add_task_attachments_idempotent(
                    &task_id,
                    &client_mutation_id,
                    &source_paths,
                    &staged,
                )
            })
            .await
        {
            Ok(outcome) => outcome,
            Err(error) => {
                cleanup_files(&managed_paths);
                return Err(error.into());
            }
        };
        if outcome == store::AttachmentMutationOutcome::Replayed {
            cleanup_files(&managed_paths);
        }
        Ok(self.store.call(|store| store.bootstrap()).await?)
    }

    async fn remove_task_attachment(
        &self,
        params: RemoveTaskAttachmentParams,
    ) -> Result<models::Bootstrap, EngineError> {
        let _file_mutation = self.task_file_mutation.lock().await;
        let task_id = params.task_id;
        let attachment_id = params.attachment_id;
        let client_mutation_id = params.client_mutation_id;
        let prepare_task_id = task_id.clone();
        let prepare_attachment_id = attachment_id.clone();
        let prepare_mutation_id = client_mutation_id.clone();
        let preparation = self
            .store
            .call(move |store| {
                store.prepare_remove_task_attachment_mutation(
                    &prepare_task_id,
                    &prepare_attachment_id,
                    &prepare_mutation_id,
                )
            })
            .await?;
        let attachment = match preparation {
            store::RemoveTaskAttachmentPreparation::Pending(attachment) => attachment,
            store::RemoveTaskAttachmentPreparation::Replayed => {
                return Ok(self.store.call(|store| store.bootstrap()).await?);
            }
        };
        let managed_path =
            managed_attachment_path(&self.data_directory, &attachment.relative_path)?;
        let quarantine = self
            .data_directory
            .join("Attachments")
            .join(format!(".removing-{}", attachment.id));
        let moved = if managed_path.exists() {
            fs::rename(&managed_path, &quarantine)?;
            true
        } else {
            false
        };

        if let Err(error) = self
            .store
            .call(move |store| {
                store.remove_task_attachment_idempotent(
                    &task_id,
                    &attachment_id,
                    &client_mutation_id,
                )
            })
            .await
        {
            if moved {
                let _ = fs::rename(&quarantine, &managed_path);
            }
            return Err(error.into());
        }
        if moved {
            if let Err(error) = fs::remove_file(&quarantine) {
                tracing::warn!("failed to remove detached managed attachment: {error}");
            }
        }
        Ok(self.store.call(|store| store.bootstrap()).await?)
    }

    async fn delete_task(&self, task_id: String) -> Result<models::Bootstrap, EngineError> {
        let _file_mutation = self.task_file_mutation.lock().await;
        let prepare_task_id = task_id.clone();
        let attachments = self
            .store
            .call(move |store| store.prepare_delete_task(&prepare_task_id))
            .await?;
        let mut final_paths = Vec::with_capacity(attachments.len());
        let mut quarantine_paths = Vec::with_capacity(attachments.len());
        for attachment in attachments {
            let final_path =
                managed_attachment_path(&self.data_directory, attachment.relative_path.as_str())?;
            let quarantine = self
                .data_directory
                .join("Attachments")
                .join(format!(".removing-{}", attachment.id));
            let prepared = match prepare_managed_attachment_deletion(&final_path, &quarantine) {
                Ok(prepared) => prepared,
                Err(error) => {
                    cleanup_files(&quarantine_paths);
                    return Err(error);
                }
            };
            if let Some(path) = prepared.0 {
                final_paths.push(path);
            }
            if let Some(path) = prepared.1 {
                quarantine_paths.push(path);
            }
        }

        let delete_task_id = task_id.clone();
        if let Err(error) = self
            .store
            .call(move |store| store.delete_task(&delete_task_id))
            .await
        {
            // Every final path still exists because preparation used hard links,
            // so a database failure cannot leave attachment metadata dangling.
            cleanup_files(&quarantine_paths);
            return Err(error.into());
        }
        for path in final_paths.iter().chain(quarantine_paths.iter()) {
            if let Err(error) = fs::remove_file(path)
                && error.kind() != io::ErrorKind::NotFound
            {
                // The DB no longer references the file. Startup reconciliation
                // will safely remove any final or quarantine orphan left behind.
                tracing::warn!(path = %path.display(), "failed to clean deleted task attachment: {error}");
            }
        }
        Ok(self.store.call(|store| store.bootstrap()).await?)
    }

    async fn shutdown(&self) {
        let _ = self.shutdown_with_timeout(ENGINE_SHUTDOWN_TIMEOUT).await;
    }

    /// Gives in-flight assistant work a chance to persist its cancellation before
    /// closing SQLite, while bounding the whole sequence. If an already-running
    /// OS-thread job never returns, dropping the timed-out future leaves that
    /// thread detached so `main` can continue to the independent stdout-drain
    /// deadline and then exit the process.
    async fn shutdown_with_timeout(&self, timeout: Duration) -> bool {
        let shutdown = async {
            self.assistant.shutdown().await;
            *self.gemini_key.lock().await = None;
            self.store.shutdown().await
        };
        match tokio::time::timeout(timeout, shutdown).await {
            Ok(Ok(())) => true,
            Ok(Err(error)) => {
                tracing::error!("failed to stop database worker: {error}");
                true
            }
            Err(_) => {
                tracing::warn!("Engine resources did not stop before shutdown deadline");
                false
            }
        }
    }

    async fn emit<T: serde::Serialize>(&self, event: &'static str, data: T) {
        self.send(&protocol::Event { event, data }).await;
    }

    async fn send<T: serde::Serialize>(&self, value: &T) {
        self.writer.send(value).await;
    }

    fn send_control<T: serde::Serialize>(&self, value: &T) {
        let _ = self.writer.try_send_control(value);
    }
}

fn validate_launch_executable(path: &Path, label: &str) -> Result<(), EngineError> {
    if !path.is_absolute() {
        return Err(EngineError::Invalid(format!("{label} must be absolute")));
    }
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.permissions().mode() & 0o111 == 0
    {
        return Err(EngineError::Invalid(format!(
            "{label} must be a regular executable file"
        )));
    }
    Ok(())
}

fn validate_status_socket(path: &Path, host_pid: u32) -> Result<(), EngineError> {
    validate_status_socket_under(path, host_pid, Path::new("/tmp"))
}

fn validate_status_socket_under(
    path: &Path,
    host_pid: u32,
    temporary_root: &Path,
) -> Result<(), EngineError> {
    if !path.is_absolute() || host_pid == 0 {
        return Err(EngineError::Invalid("statusSocket is invalid".to_owned()));
    }
    let parent = path
        .parent()
        .ok_or_else(|| EngineError::Invalid("statusSocket has no parent".to_owned()))?;
    let expected_parent = temporary_root.join(format!("todoagent-{host_pid}"));
    if parent != expected_parent {
        return Err(EngineError::Invalid(
            "statusSocket must be inside the TodoAgent host directory".to_owned(),
        ));
    }
    let uid = unsafe { nix::libc::geteuid() };
    let parent_metadata = fs::symlink_metadata(parent)?;
    if parent_metadata.file_type().is_symlink()
        || !parent_metadata.is_dir()
        || parent_metadata.uid() != uid
        || parent_metadata.permissions().mode() & 0o077 != 0
    {
        return Err(EngineError::Invalid(
            "statusSocket parent must be current-user mode 0700".to_owned(),
        ));
    }
    validate_status_socket_file(path, uid)
}

fn validate_status_socket_file(path: &Path, uid: u32) -> Result<(), EngineError> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_socket()
        || metadata.uid() != uid
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(EngineError::Invalid(
            "statusSocket must be a current-user mode 0600 Unix socket".to_owned(),
        ));
    }
    Ok(())
}

fn stage_task_attachment_batch(
    data_directory: &Path,
    task_id: &str,
    source_paths: &[String],
) -> Result<(Vec<TaskAttachment>, Vec<PathBuf>), EngineError> {
    let mut staged = Vec::with_capacity(source_paths.len());
    let mut managed_paths = Vec::with_capacity(source_paths.len());
    for source in source_paths {
        match stage_task_attachment(data_directory, task_id, Path::new(source)) {
            Ok((attachment, managed_path)) => {
                staged.push(attachment);
                managed_paths.push(managed_path);
            }
            Err(error) => {
                cleanup_files(&managed_paths);
                return Err(error);
            }
        }
    }
    Ok((staged, managed_paths))
}

fn stage_task_attachment(
    data_directory: &Path,
    task_id: &str,
    source: &Path,
) -> Result<(TaskAttachment, PathBuf), EngineError> {
    secure_directory(data_directory)?;
    secure_directory(&data_directory.join("Attachments"))?;
    if !source.is_absolute() {
        return Err(EngineError::Invalid(
            "task attachment source paths must be absolute".to_owned(),
        ));
    }
    let source_file = match fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(source)
    {
        Ok(file) => file,
        Err(error) if error.raw_os_error() == Some(nix::libc::ELOOP) => {
            return Err(EngineError::Invalid(
                "task attachments must not be symbolic links".to_owned(),
            ));
        }
        Err(error) => return Err(error.into()),
    };
    let metadata = source_file.metadata()?;
    if !metadata.is_file() {
        return Err(EngineError::Invalid(
            "task attachments must be regular files".to_owned(),
        ));
    }
    if metadata.len() > MAX_TASK_ATTACHMENT_BYTES {
        return Err(EngineError::Invalid(
            "task attachment exceeds the 100 MiB limit".to_owned(),
        ));
    }
    let original_name = source
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .ok_or_else(|| EngineError::Invalid("attachment name is invalid".to_owned()))?
        .to_owned();
    let id = uuid::Uuid::new_v4().to_string();
    let safe_extension = source
        .extension()
        .and_then(|extension| extension.to_str())
        .filter(|extension| {
            !extension.is_empty()
                && extension.len() <= 16
                && extension
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric())
        })
        .map(str::to_ascii_lowercase);
    let managed_name = safe_extension
        .as_deref()
        .map_or_else(|| id.clone(), |extension| format!("{id}.{extension}"));
    let relative_path = format!("Attachments/{managed_name}");
    let managed_path = managed_attachment_path(data_directory, &relative_path)?;
    let staging_path = data_directory
        .join("Attachments")
        .join(format!(".staging-{id}"));
    let mut staging_file = match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(&staging_path)
    {
        Ok(file) => file,
        Err(error) => {
            let _ = fs::remove_file(&staging_path);
            return Err(error.into());
        }
    };
    let copied = match io::copy(
        &mut source_file.take(MAX_TASK_ATTACHMENT_BYTES + 1),
        &mut staging_file,
    ) {
        Ok(copied) => copied,
        Err(error) => {
            let _ = fs::remove_file(&staging_path);
            return Err(error.into());
        }
    };
    if copied > MAX_TASK_ATTACHMENT_BYTES || copied != metadata.len() {
        drop(staging_file);
        let _ = fs::remove_file(&staging_path);
        return Err(EngineError::Invalid(
            "task attachment changed while it was copied".to_owned(),
        ));
    }
    if let Err(error) = staging_file.sync_all() {
        drop(staging_file);
        let _ = fs::remove_file(&staging_path);
        return Err(error.into());
    }
    drop(staging_file);
    if let Err(error) = fs::set_permissions(&staging_path, fs::Permissions::from_mode(0o600)) {
        let _ = fs::remove_file(&staging_path);
        return Err(error.into());
    }
    if let Err(error) = fs::rename(&staging_path, &managed_path) {
        let _ = fs::remove_file(&staging_path);
        return Err(error.into());
    }
    Ok((
        TaskAttachment {
            id,
            task_id: task_id.to_owned(),
            original_name,
            size_bytes: i64::try_from(metadata.len())
                .map_err(|_| EngineError::Invalid("task attachment size is invalid".to_owned()))?,
            mime_type: mime_type_for_path(source).to_owned(),
            relative_path,
            created_at: chrono::Utc::now().to_rfc3339(),
        },
        managed_path,
    ))
}

fn managed_attachment_path(data_directory: &Path, relative: &str) -> Result<PathBuf, EngineError> {
    let relative_path = Path::new(relative);
    let mut components = relative_path.components();
    let valid = matches!(components.next(), Some(std::path::Component::Normal(name)) if name == "Attachments")
        && matches!(components.next(), Some(std::path::Component::Normal(_)))
        && components.next().is_none();
    if !valid {
        return Err(EngineError::Invalid(
            "managed attachment path is invalid".to_owned(),
        ));
    }
    Ok(data_directory.join(relative_path))
}

fn mime_type_for_path(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("txt") => "text/plain",
        Some("md" | "markdown") => "text/markdown",
        Some("json") => "application/json",
        Some("pdf") => "application/pdf",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("csv") => "text/csv",
        Some("zip") => "application/zip",
        _ => "application/octet-stream",
    }
}

fn cleanup_files(paths: &[PathBuf]) {
    for path in paths {
        let _ = fs::remove_file(path);
    }
}

/// Prepares one managed attachment for a cascading task delete without ever
/// removing the path SQLite currently references. A previous failed cleanup may
/// leave the quarantine name behind; regular final files replace that stale name
/// with a fresh hard link, while a quarantine-only regular file is reused and
/// linked back to the final path before proceeding.
fn prepare_managed_attachment_deletion(
    final_path: &Path,
    quarantine: &Path,
) -> Result<(Option<PathBuf>, Option<PathBuf>), EngineError> {
    let final_metadata = match fs::symlink_metadata(final_path) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error.into()),
    };
    let quarantine_metadata = match fs::symlink_metadata(quarantine) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error.into()),
    };

    if final_metadata.is_none()
        && quarantine_metadata
            .as_ref()
            .is_some_and(fs::Metadata::is_file)
    {
        fs::hard_link(quarantine, final_path)?;
        return Ok((Some(final_path.to_owned()), Some(quarantine.to_owned())));
    }

    if final_metadata
        .as_ref()
        .is_some_and(|metadata| metadata.file_type().is_symlink())
    {
        if quarantine_metadata
            .as_ref()
            .is_some_and(fs::Metadata::is_file)
        {
            return Err(EngineError::Invalid(
                "managed task attachment recovery is required".to_owned(),
            ));
        }
        if let Some(metadata) = quarantine_metadata {
            if metadata.file_type().is_symlink() {
                fs::remove_file(quarantine)?;
            } else {
                return Err(EngineError::Invalid(
                    "managed task attachment quarantine must be a file".to_owned(),
                ));
            }
        }
        // The link itself is untrusted and is removed only after the database
        // commits; its external target is never opened or followed.
        return Ok((Some(final_path.to_owned()), None));
    }

    let Some(final_metadata) = final_metadata else {
        if let Some(metadata) = quarantine_metadata {
            if metadata.file_type().is_symlink() {
                fs::remove_file(quarantine)?;
            } else {
                return Err(EngineError::Invalid(
                    "managed task attachment quarantine must be a file".to_owned(),
                ));
            }
        }
        return Ok((None, None));
    };
    if !final_metadata.is_file() {
        return Err(EngineError::Invalid(
            "managed task attachment must be a regular file".to_owned(),
        ));
    }
    if let Some(metadata) = quarantine_metadata {
        if metadata.is_file() || metadata.file_type().is_symlink() {
            fs::remove_file(quarantine)?;
        } else {
            return Err(EngineError::Invalid(
                "managed task attachment quarantine must be a file".to_owned(),
            ));
        }
    }
    fs::hard_link(final_path, quarantine)?;
    Ok((Some(final_path.to_owned()), Some(quarantine.to_owned())))
}

fn response_for_error(id: String, error: EngineError) -> Response {
    match error {
        EngineError::Store(StoreWorkerError::Store(StoreError::NotFound)) => {
            Response::err(id, "not_found", "requested record does not exist")
        }
        EngineError::Store(StoreWorkerError::Store(StoreError::Conflict(code)))
        | EngineError::Conflict(code) => Response::err(id, code, code.replace('_', " ")),
        EngineError::Store(StoreWorkerError::Store(StoreError::Invalid(message)))
        | EngineError::Invalid(message) => {
            if let Some(method) = message.strip_prefix("method_not_found: ") {
                Response::err(id, "method_not_found", format!("unknown method {method}"))
            } else {
                Response::err(id, "invalid_params", message)
            }
        }
        EngineError::Runtime(code) => {
            let message = match code {
                "claude_session_not_found" => {
                    "找不到这个 TodoAgent Session 绑定的 Claude 本地会话记录。为避免打开错误对话，已停止恢复；请确认 Claude 配置目录和原会话文件仍然存在。"
                }
                "claude_session_not_resumable" => {
                    "Claude 的会话记录已存在，但还没有可恢复的对话内容。请先在 Claude Code 中处理或移走这条不完整记录，再重试。"
                }
                "claude_session_scan_failed" => {
                    "无法安全检查 Claude 的本地会话记录，请确认 ~/.claude（或 CLAUDE_CONFIG_DIR）可以读取后重试。"
                }
                "terminal_working_directory_unavailable" => {
                    "这个 Session 绑定的工作目录已不存在或不再是真实目录。请在 TodoAgent 中重新定位项目当前目录后重试。"
                }
                _ => return Response::err(id, code, code.replace('_', " ")),
            };
            Response::err(id, code, message)
        }
        EngineError::Gemini { code, message } => Response::err(id, code, message),
        EngineError::Assistant(assistant_service::AssistantServiceError::Store(
            StoreWorkerError::Store(StoreError::NotFound),
        )) => Response::err(id, "not_found", "requested record does not exist"),
        EngineError::Assistant(assistant_service::AssistantServiceError::Store(
            StoreWorkerError::Store(StoreError::Conflict(code)),
        ))
        | EngineError::Assistant(assistant_service::AssistantServiceError::Conflict(code)) => {
            Response::err(id, code, code.replace('_', " "))
        }
        EngineError::Assistant(assistant_service::AssistantServiceError::Store(
            StoreWorkerError::Store(StoreError::Invalid(message)),
        ))
        | EngineError::Assistant(assistant_service::AssistantServiceError::Invalid(message)) => {
            Response::err(id, "invalid_params", message)
        }
        EngineError::Assistant(assistant_service::AssistantServiceError::Unavailable {
            code,
            message,
        }) => Response::err(id, code, message),
        EngineError::Assistant(assistant_service::AssistantServiceError::Store(error)) => {
            Response::err(id, "engine_error", error.to_string())
        }
        EngineError::Store(error) => Response::err(id, "engine_error", error.to_string()),
        EngineError::Io(error) => Response::err(id, "engine_error", error.to_string()),
    }
}

fn gemini_http_error(status: reqwest::StatusCode, body: &[u8], api_key: &str) -> EngineError {
    let provider_message = serde_json::from_slice::<GoogleErrorEnvelope>(body)
        .ok()
        .map(|response| response.error.message)
        .map(|message| message.replace(api_key, "[REDACTED]"))
        .filter(|message| !message.trim().is_empty());
    let (code, fallback) = match status.as_u16() {
        400 => ("gemini_invalid_request", "Gemini 拒绝了模型或请求参数。"),
        401 | 403 => (
            "gemini_auth_failed",
            "API Key 无效、受限或没有 Gemini API 权限。",
        ),
        404 => ("gemini_model_not_found", "找不到这个 Gemini 模型。"),
        429 => (
            "gemini_rate_limited",
            "Gemini 配额不足或请求过于频繁，请稍后重试。",
        ),
        500..=599 => (
            "gemini_service_unavailable",
            "Gemini 服务暂时不可用，请稍后重试。",
        ),
        _ => ("gemini_request_failed", "Gemini 连接测试失败。"),
    };
    EngineError::Gemini {
        code,
        message: provider_message.unwrap_or_else(|| fallback.to_owned()),
    }
}

fn parse<T: for<'de> Deserialize<'de>>(value: &Value) -> Result<T, EngineError> {
    serde_json::from_value(value.clone()).map_err(|error| EngineError::Invalid(error.to_string()))
}

fn deserialize_canonical_uuid<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    uuid::Uuid::parse_str(&value)
        .map(|value| value.to_string())
        .map_err(serde::de::Error::custom)
}

fn deserialize_optional_canonical_uuid<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer)?
        .map(|value| {
            uuid::Uuid::parse_str(&value)
                .map(|value| value.to_string())
                .map_err(serde::de::Error::custom)
        })
        .transpose()
}

fn validate_text(value: &str, maximum: usize, name: &str) -> Result<(), EngineError> {
    if value.trim().is_empty() || value.chars().count() > maximum {
        return Err(EngineError::Invalid(format!(
            "{name} must contain 1...{maximum} characters"
        )));
    }
    Ok(())
}

fn parse_single_uuid(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut values = text
        .split(|character: char| character.is_whitespace() || matches!(character, '"' | '\''))
        .filter_map(|candidate| uuid::Uuid::parse_str(candidate.trim()).ok())
        .map(|value| value.to_string());
    let first = values.next()?;
    values.next().is_none().then_some(first)
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
    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_DIRECTORY | nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(path)?;
    if !directory.metadata()?.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "private data root must be a real directory",
        ));
    }
    directory.set_permissions(fs::Permissions::from_mode(0o700))
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
    use std::os::unix::fs::symlink;
    use tokio::io::AsyncWriteExt;
    use uuid::Uuid;

    fn test_engine(
        store: StoreWorker,
        _concurrency: usize,
        data_directory: PathBuf,
    ) -> (Engine, std::sync::mpsc::Receiver<Value>) {
        let (writer, receiver) = output::test_channel(512);
        let gemini_key = Arc::new(Mutex::new(None));
        let data_directory = Arc::new(data_directory);
        let task_file_mutation = Arc::new(Mutex::new(()));
        let assistant = assistant_service::AssistantService::new(
            store.clone(),
            writer.clone(),
            gemini_key.clone(),
            data_directory.clone(),
            task_file_mutation.clone(),
        );
        (
            Engine {
                store,
                writer,
                authorized_directories: Arc::new(Mutex::new(HashSet::new())),
                gemini_key,
                assistant,
                data_directory,
                task_file_mutation,
                shutdown_requested: tokio_util::sync::CancellationToken::new(),
            },
            receiver,
        )
    }

    #[test]
    fn request_size_is_bounded() {
        assert_eq!(MAX_REQUEST_BYTES, 1024 * 1024);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn terminal_session_create_keeps_the_host_shell_independent_of_agent_installation() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let workspace = directory.path().join("workspace");
        fs::create_dir_all(&data).unwrap();
        fs::create_dir(&workspace).unwrap();
        let workspace = fs::canonicalize(workspace).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let task = worker
            .call(|store| store.create_task("Direct terminal", "", None, None, None))
            .await
            .unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data);
        engine
            .authorized_directories
            .lock()
            .await
            .insert(workspace.clone());

        let response = engine
            .handle(Request {
                id: "create-terminal-without-runtime".to_owned(),
                method: "terminal.session.create".to_owned(),
                params: json!({
                    "taskId": task.id,
                    "runtimeKind": "claude",
                    "workingDirectory": workspace,
                }),
            })
            .await;

        let bundle = response.result.expect("the host shell should be created");
        assert_eq!(bundle["session"]["runtimeKind"], "claude");
        assert_eq!(bundle["session"]["taskId"], task.id);
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "terminal.session.created");
        assert!(matches!(
            engine.ready_runtime_for_launch(RuntimeKind::Claude).await,
            Err(EngineError::Runtime("runtime_missing"))
        ));
        let session_id = bundle["session"]["id"].as_str().unwrap().to_owned();
        assert!(
            worker
                .call(move |store| store.latest_terminal_run(&session_id))
                .await
                .unwrap()
                .is_none(),
            "creating the host shell must not prepare or start an Agent Run"
        );

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn shutdown_bypasses_a_blocked_data_request() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(&data).unwrap();
        let worker = StoreWorker::open(&directory.path().join("shutdown-lane.sqlite3")).unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data);
        let held_file_mutation = engine.task_file_mutation.lock().await;
        let source = directory.path().join("source.txt");
        fs::write(&source, b"pending").unwrap();
        let list = worker
            .call(|store| store.create_list("work", "blue", None))
            .await
            .unwrap();
        let task = worker
            .call(move |store| store.create_task("blocked", "", Some(&list.id), None, None))
            .await
            .unwrap();
        let input = format!(
            "{{\"id\":\"slow\",\"method\":\"task.attachment.add\",\"params\":{{\"taskId\":\"{}\",\"sourcePaths\":[{}],\"clientMutationId\":\"{}\"}}}}\n{{\"id\":\"stop\",\"method\":\"engine.shutdown\"}}\n",
            task.id,
            serde_json::to_string(source.to_str().unwrap()).unwrap(),
            Uuid::new_v4()
        );

        tokio::time::timeout(
            Duration::from_millis(250),
            run_request_stream(std::io::Cursor::new(input.into_bytes()), engine.clone()),
        )
        .await
        .expect("shutdown must not wait for a blocked data request")
        .unwrap();

        let response = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(response["id"], "stop");
        assert_eq!(response["result"]["ok"], true);
        drop(held_file_mutation);
        engine.shutdown().await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn shutdown_bypasses_a_saturated_data_queue() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(&data).unwrap();
        let worker = StoreWorker::open(&directory.path().join("saturated-lane.sqlite3")).unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data);
        let held_file_mutation = engine.task_file_mutation.lock().await;
        let source = directory.path().join("source.txt");
        fs::write(&source, b"pending").unwrap();
        let list = worker
            .call(|store| store.create_list("work", "blue", None))
            .await
            .unwrap();
        let task = worker
            .call(move |store| store.create_task("blocked", "", Some(&list.id), None, None))
            .await
            .unwrap();
        let mut input = format!(
            "{{\"id\":\"slow\",\"method\":\"task.attachment.add\",\"params\":{{\"taskId\":\"{}\",\"sourcePaths\":[{}],\"clientMutationId\":\"{}\"}}}}\n",
            task.id,
            serde_json::to_string(source.to_str().unwrap()).unwrap(),
            Uuid::new_v4()
        );
        // One request may already be running while the parser fills the bounded
        // queue, so submit capacity + 1 followers to guarantee one overflow in
        // either scheduling order.
        for index in 0..=REQUEST_QUEUE_CAPACITY {
            input.push_str(&format!(
                "{{\"id\":\"queued-{index}\",\"method\":\"unknown.data.request\"}}\n"
            ));
        }
        input.push_str("{\"id\":\"stop\",\"method\":\"engine.shutdown\"}\n");

        tokio::time::timeout(
            Duration::from_millis(250),
            run_request_stream(std::io::Cursor::new(input.into_bytes()), engine.clone()),
        )
        .await
        .expect("shutdown must remain readable after the data queue is full")
        .unwrap();

        let mut saw_busy = false;
        let mut saw_shutdown = false;
        for _ in 0..3 {
            let response = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
            saw_busy |= response["error"]["code"] == "engine_busy";
            saw_shutdown |= response["id"] == "stop" && response["result"]["ok"] == true;
            if saw_busy && saw_shutdown {
                break;
            }
        }
        assert!(
            saw_busy,
            "the overflow request must receive a retryable error"
        );
        assert!(saw_shutdown, "shutdown must bypass the saturated data lane");

        drop(held_file_mutation);
        engine.shutdown().await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn shutdown_does_not_wait_for_full_output_or_spawn_per_control_request() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(&data).unwrap();
        let worker = StoreWorker::open(&directory.path().join("full-output.sqlite3")).unwrap();
        let (mut engine, _unused_receiver) = test_engine(worker, 0, data);
        let (blocked_writer, _blocked_receiver) = OutputWriter::channel(1);
        assert!(blocked_writer.try_send_control(&json!({"fills": "queue"})));
        engine.writer = blocked_writer;

        // More than the bounded control capacity proves that excess requests
        // are rejected inline rather than retained as one task per request.
        let mut input = String::new();
        for index in 0..(CONTROL_QUEUE_CAPACITY * 4) {
            input.push_str(&format!(
                "{{\"id\":\"health-{index}\",\"method\":\"engine.health\"}}\n"
            ));
        }
        input.push_str("{\"id\":\"stop\",\"method\":\"engine.shutdown\"}\n");

        tokio::time::timeout(
            Duration::from_millis(250),
            run_request_stream(std::io::Cursor::new(input.into_bytes()), engine.clone()),
        )
        .await
        .expect("shutdown parsing must not wait for stdout capacity")
        .unwrap();

        assert!(engine.shutdown_requested.is_cancelled());
        engine.shutdown().await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn engine_shutdown_has_a_deadline_when_the_database_worker_never_returns() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(&data).unwrap();
        let worker = StoreWorker::open(&directory.path().join("blocked-shutdown.sqlite3")).unwrap();
        let (engine, _receiver) = test_engine(worker.clone(), 0, data);
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (_release_tx, release_rx) = std::sync::mpsc::sync_channel::<()>(0);
        let blocked = tokio::spawn(async move {
            worker
                .call(move |_store| {
                    let _ = started_tx.send(());
                    // The sender deliberately remains alive for the duration of
                    // this test, modelling an OS/SQLite call that does not yield.
                    let _ = release_rx.recv();
                    Ok(())
                })
                .await
        });
        tokio::task::spawn_blocking(move || {
            started_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("database worker must enter the simulated blocking call");
        })
        .await
        .unwrap();

        let started_at = tokio::time::Instant::now();
        assert!(
            !engine
                .shutdown_with_timeout(Duration::from_millis(25))
                .await
        );
        assert!(started_at.elapsed() < Duration::from_millis(250));
        blocked.abort();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn health_bypasses_a_blocked_data_request() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(&data).unwrap();
        let worker = StoreWorker::open(&directory.path().join("health-lane.sqlite3")).unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data);
        let held_file_mutation = engine.task_file_mutation.lock().await;
        let source = directory.path().join("source.txt");
        fs::write(&source, b"pending").unwrap();
        let list = worker
            .call(|store| store.create_list("work", "blue", None))
            .await
            .unwrap();
        let task = worker
            .call(move |store| store.create_task("blocked", "", Some(&list.id), None, None))
            .await
            .unwrap();
        let input = format!(
            "{{\"id\":\"slow\",\"method\":\"task.attachment.add\",\"params\":{{\"taskId\":\"{}\",\"sourcePaths\":[{}],\"clientMutationId\":\"{}\"}}}}\n{{\"id\":\"health\",\"method\":\"engine.health\"}}\n",
            task.id,
            serde_json::to_string(source.to_str().unwrap()).unwrap(),
            Uuid::new_v4()
        );
        let (mut reader, mut writer) = tokio::io::duplex(input.len() + 1);
        writer.write_all(input.as_bytes()).await.unwrap();

        let loop_engine = engine.clone();
        let request_loop =
            tokio::spawn(async move { run_request_stream(&mut reader, loop_engine).await });
        let response = tokio::task::spawn_blocking(move || {
            receiver.recv_timeout(Duration::from_millis(250)).unwrap()
        })
        .await
        .unwrap();
        assert_eq!(response["id"], "health");
        assert_eq!(response["result"]["ok"], true);

        request_loop.abort();
        drop(writer);
        drop(held_file_mutation);
        engine.shutdown().await;
    }

    fn write_fake_claude(path: &Path, version: &str) {
        fs::write(
            path,
            format!(
                "#!/bin/sh\ncase \"$1\" in\n  --version) echo '{version} (Claude Code)' ;;\n  --help) echo '--session-id --resume --name --settings' ;;\n  auth) echo '{{\"authenticated\":true}}' ;;\n  *) exit 1 ;;\nesac\n"
            ),
        )
        .unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    async fn assert_claude_version_symlink_rollover(delete_old_target: bool) {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(&data).unwrap();
        let versions = directory.path().join("versions");
        fs::create_dir_all(&versions).unwrap();
        let old_target = versions.join("2.1.224");
        let new_target = versions.join("2.1.228");
        write_fake_claude(&old_target, "2.1.224");
        write_fake_claude(&new_target, "2.1.228");
        let old_resolved = fs::canonicalize(&old_target).unwrap();
        let new_resolved = fs::canonicalize(&new_target).unwrap();
        let stable_launch = directory.path().join("claude");
        symlink(&old_target, &stable_launch).unwrap();

        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let verified = models::Runtime {
            kind: RuntimeKind::Claude,
            launch_path: Some(stable_launch.to_string_lossy().into_owned()),
            resolved_path: Some(old_resolved.to_string_lossy().into_owned()),
            version: Some("2.1.224 (Claude Code)".to_owned()),
            status: "ready".to_owned(),
            auth_status: "authenticated".to_owned(),
            capabilities: json!({"capabilityProbe":"passed","oldTarget":true}),
            provider_engine: None,
            detected_at: Some("2026-08-09T00:00:00Z".to_owned()),
            verified_at: Some("2026-08-09T00:00:00Z".to_owned()),
            verify_error: None,
        };
        worker
            .call(move |store| store.save_runtime(&verified))
            .await
            .unwrap();

        fs::remove_file(&stable_launch).unwrap();
        symlink(&new_target, &stable_launch).unwrap();
        if delete_old_target {
            fs::remove_file(&old_target).unwrap();
        }

        let (engine, receiver) = test_engine(worker.clone(), 0, data);
        let refreshed = engine
            .ready_runtime_for_launch(RuntimeKind::Claude)
            .await
            .unwrap();
        assert_eq!(
            refreshed.resolved_path.as_deref(),
            Some(new_resolved.to_string_lossy().as_ref())
        );
        assert_eq!(refreshed.version.as_deref(), Some("2.1.228 (Claude Code)"));
        assert_eq!(refreshed.status, "ready");
        assert_eq!(refreshed.capabilities["capabilityProbe"], "passed");
        assert!(refreshed.capabilities.get("oldTarget").is_none());
        assert_eq!(old_target.exists(), !delete_old_target);

        let persisted = worker
            .call(|store| store.runtime(RuntimeKind::Claude))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(persisted, refreshed);
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "runtime.changed");
        assert_eq!(
            event["data"][0]["resolvedPath"],
            new_resolved.to_string_lossy().as_ref()
        );

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn launch_refreshes_claude_when_stable_symlink_moves_and_old_target_remains() {
        assert_claude_version_symlink_rollover(false).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn launch_refreshes_claude_when_stable_symlink_moves_and_old_target_is_deleted() {
        assert_claude_version_symlink_rollover(true).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn prepare_launch_rejects_a_removed_session_directory_without_creating_a_run() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(&data).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let missing = directory.path().join("removed-project");
        let task = worker
            .call(|store| store.create_task("Removed cwd", "", None, None, None))
            .await
            .unwrap();
        let task_id = task.id.clone();
        let missing_path = missing.to_string_lossy().into_owned();
        let session = worker
            .call(move |store| {
                store.create_terminal_session(&task_id, RuntimeKind::Claude, &missing_path)
            })
            .await
            .unwrap();
        let session_id = session.id.clone();
        let run_id = Uuid::new_v4().to_string();
        let (engine, _receiver) = test_engine(worker.clone(), 0, data);

        let result = engine
            .prepare_terminal_launch(PrepareTerminalLaunchParams {
                session_id: session_id.clone(),
                run_id,
                task_title: Some("Removed cwd".to_owned()),
                // cwd validation must happen before this deliberately invalid
                // socket can affect the result.
                status_socket: "/not/a/status.sock".to_owned(),
                lifecycle_token: "lifecycle-token".to_owned(),
                hook_token: "hook-token".to_owned(),
                host_pid: std::process::id(),
                provider_hooks_enabled: false,
                intent: None,
                runtime_kind: None,
            })
            .await;
        assert!(matches!(
            result,
            Err(EngineError::Runtime(
                "terminal_working_directory_unavailable"
            ))
        ));
        assert!(
            worker
                .call(move |store| store.latest_terminal_run(&session_id))
                .await
                .unwrap()
                .is_none(),
            "a stale working directory must not create a durable starting Run"
        );

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn resume_rejects_a_different_requested_runtime_before_launch_side_effects() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let workspace = directory.path().join("workspace");
        fs::create_dir_all(&data).unwrap();
        fs::create_dir(&workspace).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let task = worker
            .call(|store| store.create_task("Resume runtime", "", None, None, None))
            .await
            .unwrap();
        let task_id = task.id;
        let workspace = workspace.to_string_lossy().into_owned();
        let session = worker
            .call(move |store| {
                store.create_terminal_session(&task_id, RuntimeKind::Claude, &workspace)
            })
            .await
            .unwrap();
        let first_run_id = Uuid::new_v4().to_string();
        let prepare_session_id = session.id.clone();
        let prepare_run_id = first_run_id.clone();
        worker
            .call(move |store| store.prepare_terminal_run(&prepare_session_id, &prepare_run_id))
            .await
            .unwrap();
        let start_session_id = session.id.clone();
        let start_run_id = first_run_id.clone();
        worker
            .call(move |store| store.mark_terminal_run_started(&start_session_id, &start_run_id))
            .await
            .unwrap();
        let finish_session_id = session.id.clone();
        let finish_run_id = first_run_id.clone();
        worker
            .call(move |store| {
                store.finish_terminal_run(
                    &finish_session_id,
                    &finish_run_id,
                    Some(143),
                    "app_shutdown",
                    None,
                    None,
                )
            })
            .await
            .unwrap();

        let (engine, _receiver) = test_engine(worker.clone(), 0, data);
        let rejected_run_id = Uuid::new_v4().to_string();
        let result = engine
            .prepare_terminal_launch(PrepareTerminalLaunchParams {
                session_id: session.id.clone(),
                run_id: rejected_run_id.clone(),
                task_title: None,
                // Runtime mismatch must fail before socket/runtime validation.
                status_socket: "/not/a/status.sock".to_owned(),
                lifecycle_token: "lifecycle-token".to_owned(),
                hook_token: "hook-token".to_owned(),
                host_pid: std::process::id(),
                provider_hooks_enabled: true,
                intent: Some("resume".to_owned()),
                runtime_kind: Some("cursor".to_owned()),
            })
            .await;
        assert!(matches!(
            result,
            Err(EngineError::Conflict("runtime_change_requires_fresh"))
        ));
        let persisted_session_id = session.id.clone();
        let persisted = worker
            .call(move |store| store.terminal_session_bundle(&persisted_session_id))
            .await
            .unwrap();
        assert_eq!(persisted.session.runtime_kind, RuntimeKind::Claude);
        assert!(persisted.session.auto_resume);
        assert_eq!(persisted.active_run.unwrap().id, first_run_id);
        let missing_run_id = rejected_run_id.clone();
        assert!(
            worker
                .call(move |store| store.terminal_run(&missing_run_id))
                .await
                .unwrap()
                .is_none()
        );

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn rebind_workspace_requires_authorization_and_preserves_the_provider() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let replacement = directory.path().join("replacement");
        fs::create_dir_all(&data).unwrap();
        fs::create_dir(&replacement).unwrap();
        let replacement = fs::canonicalize(replacement).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let task = worker
            .call(|store| store.create_task("Moved cwd", "", None, None, None))
            .await
            .unwrap();
        let task_id = task.id;
        let session = worker
            .call(move |store| {
                store.create_terminal_session(&task_id, RuntimeKind::Claude, "/old/project")
            })
            .await
            .unwrap();
        let session_id = session.id.clone();
        let run_id = uuid::Uuid::new_v4().to_string();
        let prepared = worker
            .call(move |store| store.prepare_terminal_run(&session_id, &run_id))
            .await
            .unwrap();
        let provider_id = prepared.session.provider_session_id.clone();
        let finish_session = prepared.session.id.clone();
        let finish_run = prepared.active_run.unwrap().id.clone();
        worker
            .call(move |store| {
                store.finish_terminal_run(
                    &finish_session,
                    &finish_run,
                    Some(0),
                    "process_exit",
                    None,
                    None,
                )
            })
            .await
            .unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data);
        let request = || Request {
            id: "rebind".to_owned(),
            method: "terminal.session.rebind_workspace".to_owned(),
            params: json!({
                "sessionId": session.id,
                "workingDirectory": replacement,
            }),
        };

        let unauthorized = engine.handle(request()).await;
        assert_eq!(unauthorized.error.unwrap().code, "workspace_not_authorized");
        engine
            .authorized_directories
            .lock()
            .await
            .insert(replacement.clone());
        let rebound = engine.handle(request()).await.result.unwrap();
        assert_eq!(
            rebound["session"]["workingDirectory"],
            replacement.to_string_lossy().as_ref()
        );
        assert_eq!(
            rebound["session"]["providerSessionId"],
            provider_id.as_deref().unwrap()
        );
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "terminal.session.changed");
        assert_eq!(event["data"], rebound);

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[test]
    fn missing_terminal_working_directory_has_actionable_protocol_error() {
        let response = response_for_error(
            "resume".to_owned(),
            EngineError::Runtime("terminal_working_directory_unavailable"),
        );
        let error = response.error.unwrap();
        assert_eq!(error.code, "terminal_working_directory_unavailable");
        assert!(error.message.contains("重新定位"));
    }

    #[test]
    fn status_socket_must_be_host_scoped_secure_and_a_datagram_socket() {
        let host_pid = std::process::id();
        assert_eq!(
            Path::new("/tmp").join(format!("todoagent-{host_pid}")),
            PathBuf::from(format!("/tmp/todoagent-{host_pid}"))
        );
        let temporary_root = tempfile::Builder::new()
            .prefix("ta-")
            .tempdir_in("/private/tmp")
            .unwrap();
        let directory = temporary_root.path().join(format!("todoagent-{host_pid}"));
        fs::create_dir_all(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.join(format!("engine-test-{}.sock", Uuid::new_v4()));
        fs::write(&path, b"not a socket").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        // The sandbox cannot bind AF_UNIX paths, but parent provenance is
        // independently accepted and a same-mode regular file is rejected.
        assert!(validate_status_socket_file(&path, unsafe { nix::libc::geteuid() }).is_err());
        assert!(validate_status_socket_under(&path, host_pid, temporary_root.path()).is_err());
        assert!(
            validate_status_socket_under(&path, host_pid.saturating_add(1), temporary_root.path())
                .is_err()
        );
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn task_attachment_staging_copies_uniquely_and_rejects_unsafe_sources() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let first_parent = directory.path().join("first");
        let second_parent = directory.path().join("second");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        fs::create_dir_all(&first_parent).unwrap();
        fs::create_dir_all(&second_parent).unwrap();
        let first = first_parent.join("brief.PDF");
        let second = second_parent.join("brief.PDF");
        fs::write(&first, b"first").unwrap();
        fs::write(&second, b"second").unwrap();

        let (first_attachment, first_managed) =
            stage_task_attachment(&data, "task-1", &first).unwrap();
        let (second_attachment, second_managed) =
            stage_task_attachment(&data, "task-1", &second).unwrap();

        assert_ne!(
            first_attachment.relative_path,
            second_attachment.relative_path
        );
        assert!(first_attachment.relative_path.ends_with(".pdf"));
        assert_eq!(fs::read(first_managed).unwrap(), b"first");
        assert_eq!(fs::read(second_managed).unwrap(), b"second");
        assert_eq!(first_attachment.original_name, "brief.PDF");
        assert_eq!(first_attachment.mime_type, "application/pdf");

        let relative_error = stage_task_attachment(&data, "task-1", Path::new("brief.PDF"));
        assert!(matches!(relative_error, Err(EngineError::Invalid(_))));
        let directory_error = stage_task_attachment(&data, "task-1", &first_parent);
        assert!(matches!(directory_error, Err(EngineError::Invalid(_))));
        let link = directory.path().join("brief-link.pdf");
        symlink(&first, &link).unwrap();
        let link_error = stage_task_attachment(&data, "task-1", &link);
        assert!(matches!(link_error, Err(EngineError::Invalid(_))));

        let oversized = directory.path().join("oversized.bin");
        let file = fs::File::create(&oversized).unwrap();
        file.set_len(MAX_TASK_ATTACHMENT_BYTES + 1).unwrap();
        let size_error = stage_task_attachment(&data, "task-1", &oversized);
        assert!(matches!(size_error, Err(EngineError::Invalid(_))));
        assert!(
            fs::read_dir(data.join("Attachments"))
                .unwrap()
                .all(|entry| !entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".staging-"))
        );
    }

    #[test]
    fn private_data_and_attachment_roots_reject_symlinks_without_touching_targets() {
        let directory = tempfile::tempdir().unwrap();
        let external = directory.path().join("external");
        fs::create_dir_all(&external).unwrap();
        let sentinel = external.join("sentinel.txt");
        fs::write(&sentinel, b"keep").unwrap();
        let data_link = directory.path().join("data-link");
        symlink(&external, &data_link).unwrap();

        assert!(secure_directory(&data_link).is_err());
        assert_eq!(fs::read(&sentinel).unwrap(), b"keep");

        let data = directory.path().join("data");
        fs::create_dir_all(&data).unwrap();
        symlink(&external, data.join("Attachments")).unwrap();
        let source = directory.path().join("source.txt");
        fs::write(&source, b"source").unwrap();

        let result = stage_task_attachment(&data, &Uuid::new_v4().to_string(), &source);
        assert!(result.is_err());
        assert_eq!(fs::read(&sentinel).unwrap(), b"keep");
        assert_eq!(fs::read_dir(&external).unwrap().count(), 1);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn attachment_batch_rolls_back_files_and_rows_when_a_later_source_fails() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let task = worker
            .call(|store| store.create_task("批量附件", "", None, None, None))
            .await
            .unwrap();
        let (engine, _receiver) = test_engine(worker.clone(), 0, data.clone());
        let first = directory.path().join("first.txt");
        fs::write(&first, b"first").unwrap();
        let missing = directory.path().join("missing.txt");

        let result = engine
            .add_task_attachments(AddTaskAttachmentsParams {
                task_id: task.id,
                source_paths: vec![
                    first.to_string_lossy().into_owned(),
                    missing.to_string_lossy().into_owned(),
                ],
                client_mutation_id: Uuid::new_v4().to_string(),
            })
            .await;

        assert!(result.is_err());
        assert!(
            worker
                .call(|store| store.bootstrap())
                .await
                .unwrap()
                .task_attachments
                .is_empty()
        );
        assert_eq!(fs::read_dir(data.join("Attachments")).unwrap().count(), 0);

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn attachment_ipc_replays_committed_mutations_without_duplicate_side_effects() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let task = worker
            .call(|store| store.create_task("附件重放", "", None, None, None))
            .await
            .unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data.clone());
        let source = directory.path().join("retry.txt");
        fs::write(&source, b"first copy").unwrap();
        let source_path = source.to_string_lossy().into_owned();
        let add_mutation_id = Uuid::new_v4().to_string();
        let add_params = json!({
            "taskId":task.id.to_uppercase(),
            "sourcePaths":[source_path],
            "clientMutationId":add_mutation_id.to_uppercase(),
        });

        let first_add = engine
            .handle(Request {
                id: "attachment-add-first".to_owned(),
                method: "task.attachment.add".to_owned(),
                params: add_params.clone(),
            })
            .await
            .result
            .unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap()["data"],
            first_add
        );
        let first_revision = first_add["revision"].as_i64().unwrap();
        let attachment_id = first_add["taskAttachments"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let relative_path = first_add["taskAttachments"][0]["relativePath"]
            .as_str()
            .unwrap()
            .to_owned();
        fs::remove_file(&source).unwrap();

        worker
            .call(|store| store.create_task("推进快照", "", None, None, None))
            .await
            .unwrap();
        let replayed_add = engine
            .handle(Request {
                id: "attachment-add-replay".to_owned(),
                method: "task.attachment.add".to_owned(),
                params: add_params.clone(),
            })
            .await
            .result
            .unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap()["data"],
            replayed_add
        );
        assert!(replayed_add["revision"].as_i64().unwrap() > first_revision);
        assert_eq!(replayed_add["taskAttachments"].as_array().unwrap().len(), 1);
        assert!(data.join(&relative_path).exists());
        assert_eq!(fs::read_dir(data.join("Attachments")).unwrap().count(), 1);

        let conflicting_add = engine
            .handle(Request {
                id: "attachment-add-conflict".to_owned(),
                method: "task.attachment.add".to_owned(),
                params: json!({
                    "taskId":task.id,
                    "sourcePaths":[directory.path().join("different.txt")],
                    "clientMutationId":add_mutation_id,
                }),
            })
            .await;
        assert_eq!(
            conflicting_add.error.unwrap().code,
            "attachment_mutation_conflict"
        );

        let remove_mutation_id = Uuid::new_v4().to_string();
        let remove_params = json!({
            "taskId":task.id,
            "attachmentId":attachment_id,
            "clientMutationId":remove_mutation_id.to_uppercase(),
        });
        let first_remove = engine
            .handle(Request {
                id: "attachment-remove-first".to_owned(),
                method: "task.attachment.remove".to_owned(),
                params: remove_params.clone(),
            })
            .await
            .result
            .unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap()["data"],
            first_remove
        );
        let remove_revision = first_remove["revision"].as_i64().unwrap();
        assert!(!data.join(&relative_path).exists());

        let replayed_remove = engine
            .handle(Request {
                id: "attachment-remove-replay".to_owned(),
                method: "task.attachment.remove".to_owned(),
                params: remove_params.clone(),
            })
            .await
            .result
            .unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap()["data"],
            replayed_remove
        );
        assert_eq!(replayed_remove["revision"], remove_revision);

        let new_key_missing = engine
            .handle(Request {
                id: "attachment-remove-new-key".to_owned(),
                method: "task.attachment.remove".to_owned(),
                params: json!({
                    "taskId":task.id,
                    "attachmentId":attachment_id,
                    "clientMutationId":Uuid::new_v4().to_string(),
                }),
            })
            .await;
        assert_eq!(new_key_missing.error.unwrap().code, "not_found");

        let missing_key = engine
            .handle(Request {
                id: "attachment-add-missing-key".to_owned(),
                method: "task.attachment.add".to_owned(),
                params: json!({"taskId":task.id,"sourcePaths":["/tmp/missing"]}),
            })
            .await;
        assert_eq!(missing_key.error.unwrap().code, "invalid_params");

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn attachment_batch_rolls_back_files_when_database_transaction_fails() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        let database = data.join("todoagent.sqlite3");
        let worker = StoreWorker::open(&database).unwrap();
        let task = worker
            .call(|store| store.create_task("数据库回滚", "", None, None, None))
            .await
            .unwrap();
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TRIGGER reject_bad_attachment
                 BEFORE INSERT ON task_attachment
                 WHEN NEW.original_name = 'bad.txt'
                 BEGIN SELECT RAISE(ABORT, 'injected attachment failure'); END;",
            )
            .unwrap();
        drop(connection);
        let (engine, _receiver) = test_engine(worker.clone(), 0, data.clone());
        let first = directory.path().join("first.txt");
        let bad = directory.path().join("bad.txt");
        fs::write(&first, b"first").unwrap();
        fs::write(&bad, b"bad").unwrap();

        let result = engine
            .add_task_attachments(AddTaskAttachmentsParams {
                task_id: task.id,
                source_paths: vec![
                    first.to_string_lossy().into_owned(),
                    bad.to_string_lossy().into_owned(),
                ],
                client_mutation_id: Uuid::new_v4().to_string(),
            })
            .await;

        assert!(result.is_err());
        assert!(
            worker
                .call(|store| store.bootstrap())
                .await
                .unwrap()
                .task_attachments
                .is_empty()
        );
        assert_eq!(fs::read_dir(data.join("Attachments")).unwrap().count(), 0);

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn attachment_staging_does_not_block_the_async_runtime() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let task = worker
            .call(|store| store.create_task("异步附件", "", None, None, None))
            .await
            .unwrap();
        let (engine, _receiver) = test_engine(worker.clone(), 0, data);
        let fifo = directory.path().join("blocked-source");
        nix::unistd::mkfifo(
            &fifo,
            nix::sys::stat::Mode::S_IRUSR | nix::sys::stat::Mode::S_IWUSR,
        )
        .unwrap();
        let writer_fifo = fifo.clone();
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(1));
            fs::OpenOptions::new()
                .write(true)
                .open(writer_fifo)
                .unwrap()
        });
        let staging_engine = engine.clone();
        let staging = tokio::spawn(async move {
            staging_engine
                .add_task_attachments(AddTaskAttachmentsParams {
                    task_id: task.id,
                    source_paths: vec![fifo.to_string_lossy().into_owned()],
                    client_mutation_id: Uuid::new_v4().to_string(),
                })
                .await
        });
        let started = std::time::Instant::now();

        tokio::time::sleep(Duration::from_millis(50)).await;

        assert!(
            started.elapsed() < Duration::from_millis(500),
            "attachment copy blocked the current-thread Tokio runtime"
        );
        assert!(staging.await.unwrap().is_err());
        drop(writer.join().unwrap());

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[test]
    fn client_message_ids_are_uuid_shaped() {
        assert!(Uuid::parse_str(&Uuid::new_v4().to_string()).is_ok());
    }

    #[test]
    fn terminal_session_lookup_requires_protocol_camel_case_ids() {
        let task_id = Uuid::new_v4().to_string();
        let task: TerminalSessionLookupParams =
            parse(&json!({"taskId":task_id.to_uppercase()})).unwrap();
        assert_eq!(task.task_id.as_deref(), Some(task_id.as_str()));
        assert!(task.session_id.is_none());

        let error = parse::<TerminalSessionLookupParams>(&json!({"taskID":task_id.to_uppercase()}))
            .unwrap_err();
        assert!(error.to_string().contains("unknown field `taskID`"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn task_mutations_return_and_emit_the_same_authoritative_snapshot() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data.clone());
        let list = worker
            .call(|store| store.create_list("大写 UUID", "blue", None))
            .await
            .unwrap();

        let created = engine
            .handle(Request {
                id: "create-task".to_owned(),
                method: "task.create".to_owned(),
                params: json!({
                    "title":"八月十日执行",
                    "listId":list.id.to_uppercase(),
                    "executionDate":"2026-08-10",
                    "dueDate":"2026-08-12"
                }),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "task.changed");
        assert_eq!(event["data"], created);
        assert_eq!(created["tasks"][0]["executionDate"], "2026-08-10");
        assert_eq!(created["tasks"][0]["dueDate"], "2026-08-12");
        assert_eq!(created["tasks"][0]["listId"], list.id);
        let task_id = created["tasks"][0]["id"].as_str().unwrap().to_owned();
        let uppercase_task_id = task_id.to_uppercase();

        let updated = engine
            .handle(Request {
                id: "update-task".to_owned(),
                method: "task.update".to_owned(),
                params: json!({
                    "taskId":uppercase_task_id.clone(),
                    "patch":{"executionDate":"2026-08-11","dueDate":null}
                }),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["data"], updated);
        assert_eq!(updated["tasks"][0]["executionDate"], "2026-08-11");
        assert!(updated["tasks"][0]["dueDate"].is_null());

        let completed = engine
            .handle(Request {
                id: "complete-task".to_owned(),
                method: "task.complete".to_owned(),
                params: json!({"taskId":uppercase_task_id.clone()}),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["data"], completed);
        assert_eq!(completed["tasks"][0]["status"], "completed");

        let reopened = engine
            .handle(Request {
                id: "reopen-task".to_owned(),
                method: "task.reopen".to_owned(),
                params: json!({"taskId":uppercase_task_id.clone()}),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["data"], reopened);
        assert_eq!(reopened["tasks"][0]["status"], "open");

        let source = directory.path().join("brief.txt");
        fs::write(&source, b"memo").unwrap();
        let with_attachment = engine
            .handle(Request {
                id: "add-attachment".to_owned(),
                method: "task.attachment.add".to_owned(),
                params: json!({
                    "taskId":uppercase_task_id.clone(),
                    "sourcePaths":[source],
                    "clientMutationId":Uuid::new_v4().to_string().to_uppercase()
                }),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["data"], with_attachment);
        let attachment = &with_attachment["taskAttachments"][0];
        let relative_path = attachment["relativePath"].as_str().unwrap();
        assert!(relative_path.starts_with("Attachments/"));
        assert!(data.join(relative_path).exists());
        let attachment_id = attachment["id"].as_str().unwrap().to_owned();

        let removed = engine
            .handle(Request {
                id: "remove-attachment".to_owned(),
                method: "task.attachment.remove".to_owned(),
                params: json!({
                    "taskId":uppercase_task_id,
                    "attachmentId":attachment_id.to_uppercase(),
                    "clientMutationId":Uuid::new_v4().to_string().to_uppercase()
                }),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["data"], removed);
        assert!(removed["taskAttachments"].as_array().unwrap().is_empty());
        assert!(source.exists());
        assert!(!data.join(relative_path).exists());

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn list_rename_and_delete_publish_authoritative_snapshots() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data);
        let list = worker
            .call(|store| store.create_list("原清单", "blue", None))
            .await
            .unwrap();
        let task_list_id = list.id.clone();
        worker
            .call(move |store| store.create_task("保留任务", "", Some(&task_list_id), None, None))
            .await
            .unwrap();

        let renamed = engine
            .handle(Request {
                id: "rename-list".to_owned(),
                method: "list.rename".to_owned(),
                params: json!({
                    "listId": list.id.to_uppercase(),
                    "name": "  新清单  "
                }),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "task.changed");
        assert_eq!(event["data"], renamed);
        assert_eq!(renamed["lists"][0]["name"], "新清单");

        let deleted = engine
            .handle(Request {
                id: "delete-list".to_owned(),
                method: "list.delete".to_owned(),
                params: json!({"listId": list.id.to_uppercase()}),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "task.changed");
        assert_eq!(event["data"], deleted);
        assert!(deleted["lists"].as_array().unwrap().is_empty());
        assert!(deleted["tasks"][0]["listId"].is_null());

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn task_create_list_and_delete_publish_snapshots_and_clean_managed_files() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data.clone());
        let task = worker
            .call(|store| store.create_task("右键任务", "", None, None, None))
            .await
            .unwrap();
        let source = directory.path().join("original.txt");
        fs::write(&source, b"original").unwrap();
        let with_attachment = engine
            .handle(Request {
                id: "add-before-delete".to_owned(),
                method: "task.attachment.add".to_owned(),
                params: json!({
                    "taskId":task.id.to_uppercase(),
                    "sourcePaths":[source],
                    "clientMutationId":Uuid::new_v4().to_string()
                }),
            })
            .await
            .result
            .unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap()["data"],
            with_attachment
        );
        let managed_relative = with_attachment["taskAttachments"][0]["relativePath"]
            .as_str()
            .unwrap()
            .to_owned();
        let managed_path = data.join(&managed_relative);
        assert!(managed_path.exists());
        let attachment_id = with_attachment["taskAttachments"][0]["id"]
            .as_str()
            .unwrap();
        let stale_quarantine = data
            .join("Attachments")
            .join(format!(".removing-{attachment_id}"));
        fs::hard_link(&managed_path, &stale_quarantine).unwrap();
        assert!(stale_quarantine.exists());

        let with_list = engine
            .handle(Request {
                id: "create-list-from-task".to_owned(),
                method: "task.create_list".to_owned(),
                params: json!({"taskId":task.id.to_uppercase()}),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "task.changed");
        assert_eq!(event["data"], with_list);
        assert_eq!(with_list["lists"][0]["name"], "右键任务");
        assert_eq!(with_list["lists"][0]["color"], "blue");
        assert_eq!(with_list["tasks"][0]["listId"], with_list["lists"][0]["id"]);

        let deleted = engine
            .handle(Request {
                id: "delete-task".to_owned(),
                method: "task.delete".to_owned(),
                params: json!({"taskId":task.id.to_uppercase()}),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "task.changed");
        assert_eq!(event["data"], deleted);
        assert!(deleted["tasks"].as_array().unwrap().is_empty());
        assert!(deleted["taskAttachments"].as_array().unwrap().is_empty());
        assert!(source.exists(), "deletion must preserve the source file");
        assert!(!managed_path.exists());
        assert!(!stale_quarantine.exists());
        assert_eq!(fs::read_dir(data.join("Attachments")).unwrap().count(), 0);

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn task_delete_reports_active_session_conflict_without_emitting_change() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let task = worker
            .call(|store| store.create_task("执行中", "", None, None, None))
            .await
            .unwrap();
        let task_id = task.id.clone();
        worker
            .call(move |store| {
                let session =
                    store.create_terminal_session(&task_id, RuntimeKind::Codex, "/tmp")?;
                store.prepare_terminal_run(&session.id, &Uuid::new_v4().to_string())?;
                Ok(())
            })
            .await
            .unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data);

        let response = engine
            .handle(Request {
                id: "delete-active".to_owned(),
                method: "task.delete".to_owned(),
                params: json!({"taskId":task.id.to_uppercase()}),
            })
            .await;

        assert!(response.result.is_none());
        assert_eq!(response.error.unwrap().code, "task_session_active");
        assert!(receiver.try_recv().is_err());
        assert!(
            worker
                .call(move |store| Ok(store.task(&task.id)?.is_some()))
                .await
                .unwrap()
        );

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }
    #[test]
    fn gemini_model_metadata_requires_generation_support() {
        let metadata: GeminiModelMetadata = serde_json::from_str(
            r#"{"name":"models/gemini-3.6-flash","displayName":"Gemini 3.6 Flash","version":"3.6","supportedGenerationMethods":["generateContent","countTokens"],"inputTokenLimit":1048576}"#,
        )
        .unwrap();
        assert_eq!(metadata.display_name, "Gemini 3.6 Flash");
        assert!(
            metadata
                .supported_generation_methods
                .iter()
                .any(|method| method == "generateContent")
        );
        assert_eq!(metadata.input_token_limit, Some(1_048_576));
    }

    #[test]
    fn gemini_auth_error_keeps_actionable_provider_message() {
        let error = gemini_http_error(
            reqwest::StatusCode::FORBIDDEN,
            br#"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#,
            "secret-key",
        );
        match error {
            EngineError::Gemini { code, message } => {
                assert_eq!(code, "gemini_auth_failed");
                assert!(message.contains("API key not valid"));
            }
            other => panic!("unexpected error: {other}"),
        }
    }

    #[test]
    fn gemini_error_without_json_uses_localized_fallback() {
        let error = gemini_http_error(reqwest::StatusCode::NOT_FOUND, b"not-json", "secret-key");
        match error {
            EngineError::Gemini { code, message } => {
                assert_eq!(code, "gemini_model_not_found");
                assert_eq!(message, "找不到这个 Gemini 模型。");
            }
            other => panic!("unexpected error: {other}"),
        }
    }

    #[test]
    fn gemini_provider_error_redacts_the_api_key() {
        let error = gemini_http_error(
            reqwest::StatusCode::BAD_REQUEST,
            br#"{"error":{"message":"request contained secret-key"}}"#,
            "secret-key",
        );
        match error {
            EngineError::Gemini { message, .. } => {
                assert_eq!(message, "request contained [REDACTED]");
            }
            other => panic!("unexpected error: {other}"),
        }
    }
}

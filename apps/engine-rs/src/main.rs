mod adapters;
mod assistant;
mod assistant_service;
mod models;
mod protocol;
mod runtime;
mod store;
mod store_worker;

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{SyncSender, sync_channel};
use std::time::Duration;

use adapters::{ProviderEvent, TurnOutcome, TurnRequest};
use models::{MessageRole, QueuedTurn, RuntimeKind, TaskAttachment, TurnStatus, UpdateTaskInput};
use protocol::{Request, Response};
use serde::Serialize;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use store::StoreError;
use store_worker::{StoreWorker, StoreWorkerError};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{Mutex, Semaphore, mpsc};
use tokio::time::{Instant, interval, sleep};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const MAX_TASK_ATTACHMENT_BYTES: u64 = 100 * 1024 * 1024;

#[derive(Clone)]
struct Engine {
    store: StoreWorker,
    writer: SyncSender<Value>,
    turns: Arc<Mutex<HashMap<String, ActiveCliTurn>>>,
    concurrency: Arc<Semaphore>,
    authorized_directories: Arc<Mutex<HashSet<PathBuf>>>,
    gemini_key: Arc<Mutex<Option<Zeroizing<String>>>>,
    assistant: assistant_service::AssistantService,
    data_directory: Arc<PathBuf>,
    task_file_mutation: Arc<Mutex<()>>,
}

#[derive(Clone)]
struct ActiveCliTurn {
    turn_id: String,
    cancellation: CancellationToken,
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
#[serde(rename_all = "camelCase")]
struct CreateListParams {
    name: String,
    #[serde(default = "default_color")]
    color: String,
    repository_path: Option<String>,
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
#[serde(rename_all = "camelCase")]
struct CreateSessionParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    task_id: String,
    runtime_kind: String,
    working_directory: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionIDParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionLookupParams {
    #[serde(default, deserialize_with = "deserialize_optional_canonical_uuid")]
    session_id: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_canonical_uuid")]
    task_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionHistoryParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    #[serde(default)]
    after_sequence: i64,
    #[serde(default = "default_history_limit")]
    limit: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendSessionParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    session_id: String,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    client_message_id: String,
    text: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MarkReadParams {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
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
    let database_path = paths.data.join("todoagent.sqlite3");
    let attachments_path = paths.data.join("Attachments");
    store::prepare_database_files(&database_path, &attachments_path)?;
    secure_directory(&attachments_path)?;
    let store = StoreWorker::open(&database_path)?;
    let recovery_attachments = attachments_path.clone();
    store
        .call(move |store| store.reconcile_task_attachment_files(&recovery_attachments))
        .await?;
    fs::set_permissions(&database_path, fs::Permissions::from_mode(0o600))?;
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
    let gemini_key = Arc::new(Mutex::new(None));
    let data_directory = Arc::new(paths.data);
    let task_file_mutation = Arc::new(Mutex::new(()));
    let assistant = assistant_service::AssistantService::new(
        store.clone(),
        writer_tx.clone(),
        gemini_key.clone(),
        data_directory.clone(),
        task_file_mutation.clone(),
    );
    let engine = Engine {
        store,
        writer: writer_tx,
        turns: Arc::new(Mutex::new(HashMap::new())),
        concurrency: Arc::new(Semaphore::new(2)),
        authorized_directories: Arc::new(Mutex::new(HashSet::new())),
        gemini_key,
        assistant,
        data_directory,
        task_file_mutation,
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
    // EOF is also a shutdown path. Release every stdout sender (including the
    // AssistantService clone) before joining the writer thread.
    engine.shutdown().await;
    drop(engine);
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
            "engine.health" | "health" => to_value(self.store.call(|store| store.health()).await?),
            "app.bootstrap" | "app.snapshot" | "app.sync" => {
                to_value(self.store.call(|store| store.bootstrap()).await?)
            }
            "list.create" => {
                let params: CreateListParams = parse(&request.params)?;
                validate_text(&params.name, 200, "name")?;
                let list = self
                    .store
                    .call(move |store| {
                        store.create_list(
                            &params.name,
                            &params.color,
                            params.repository_path.as_deref(),
                        )
                    })
                    .await?;
                let snapshot = self.store.call(|store| store.bootstrap()).await?;
                self.emit("task.changed", snapshot).await;
                to_value(list)
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
                let working_directory = directory.display().to_string();
                let task_id = params.task_id;
                let prepare_task_id = task_id.clone();
                let prepare_directory = working_directory.clone();
                let replayed = self
                    .store
                    .call(move |store| {
                        store.prepare_session_create(&prepare_task_id, kind, &prepare_directory)
                    })
                    .await?;
                let session = if let Some(session) = replayed {
                    session
                } else {
                    let runtime = self.ready_runtime(kind).await?;
                    let _executable = runtime
                        .resolved_path
                        .or(runtime.launch_path)
                        .ok_or(EngineError::Runtime("runtime_missing"))?;
                    self.store
                        .call(move |store| store.create_session(&task_id, kind, &working_directory))
                        .await?
                };
                let session_id = session.id.clone();
                let bundle = self
                    .store
                    .call(move |store| store.session_bundle(&session_id, 0, 500))
                    .await?;
                self.emit("session.created", &bundle).await;
                to_value(bundle)
            }
            "session.get" => {
                let params: SessionLookupParams = parse(&request.params)?;
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
                                .session_for_task(params.task_id.as_deref().unwrap_or_default())?
                                .ok_or(StoreError::NotFound)?
                                .id
                        };
                        store.session_bundle(&session_id, 0, 500)
                    })
                    .await?;
                to_value(bundle)
            }
            "session.history" => {
                let params: SessionHistoryParams = parse(&request.params)?;
                to_value(
                    self.store
                        .call(move |store| {
                            store.session_bundle(
                                &params.session_id,
                                params.after_sequence,
                                params.limit,
                            )
                        })
                        .await?,
                )
            }
            "session.send" => {
                let params: SendSessionParams = parse(&request.params)?;
                validate_text(&params.text, 200_000, "text")?;
                let session_id = params.session_id.clone();
                let (queued, executable) = self.prepare_session_send(params).await?;
                let bundle = self
                    .store
                    .call(move |store| store.session_bundle(&session_id, 0, 500))
                    .await?;
                self.emit("session.state_changed", &bundle).await;
                if let Some(executable) = executable {
                    self.schedule(queued, executable).await;
                }
                to_value(bundle)
            }
            "session.mark_read" => {
                let params: MarkReadParams = parse(&request.params)?;
                let session = self
                    .store
                    .call(move |store| store.mark_read(&params.session_id, params.through_sequence))
                    .await?;
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
                    .map(|active| active.cancellation.clone())
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
            .call(move |store| store.runtime(kind))
            .await?
            .ok_or(EngineError::Runtime("runtime_missing"))?;
        match runtime.status.as_str() {
            "ready" => Ok(runtime),
            "auth_required" => Err(EngineError::Runtime("auth_required")),
            _ => Err(EngineError::Runtime("runtime_not_verified")),
        }
    }

    async fn prepare_session_send(
        &self,
        params: SendSessionParams,
    ) -> Result<(QueuedTurn, Option<String>), EngineError> {
        let SendSessionParams {
            session_id,
            client_message_id,
            text,
        } = params;
        let lookup_session_id = session_id.clone();
        let lookup_client_message_id = client_message_id.clone();
        if let Some(existing) = self
            .store
            .call(move |store| {
                store.session_turn_for_client_message(&lookup_session_id, &lookup_client_message_id)
            })
            .await?
        {
            return Ok((existing, None));
        }

        let runtime_session_id = session_id.clone();
        let runtime_kind = self
            .store
            .call(move |store| {
                store
                    .session(&runtime_session_id)?
                    .map(|session| session.runtime_kind)
                    .ok_or(StoreError::NotFound)
            })
            .await?;
        let runtime = self.ready_runtime(runtime_kind).await?;
        let executable = runtime
            .resolved_path
            .or(runtime.launch_path)
            .ok_or(EngineError::Runtime("runtime_missing"))?;
        let queued = self
            .store
            .call(move |store| store.send_message(&session_id, &client_message_id, &text))
            .await?;
        let executable = queued.is_new.then_some(executable);
        Ok((queued, executable))
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

    async fn schedule(&self, queued: QueuedTurn, executable: String) {
        let token = CancellationToken::new();
        self.turns.lock().await.insert(
            queued.session.id.clone(),
            ActiveCliTurn {
                turn_id: queued.turn.id.clone(),
                cancellation: token.clone(),
            },
        );
        let engine = self.clone();
        tokio::spawn(async move {
            let permit = match engine.concurrency.clone().acquire_owned().await {
                Ok(permit) => permit,
                Err(_) => {
                    engine
                        .remove_cli_turn_if_matches(&queued.session.id, &queued.turn.id)
                        .await;
                    return;
                }
            };
            let _permit = permit;
            if token.is_cancelled() {
                engine.finish_cancelled(&queued).await;
                return;
            }
            let turn_id = queued.turn.id.clone();
            let running = match engine
                .store
                .call(move |store| store.mark_turn_running(&turn_id))
                .await
            {
                Ok(turn) => turn,
                Err(error) => {
                    tracing::error!("failed to mark turn running: {error}");
                    engine
                        .remove_cli_turn_if_matches(&queued.session.id, &queued.turn.id)
                        .await;
                    return;
                }
            };
            engine.emit("session.turn.started", &running).await;
            let session_id = queued.session.id.clone();
            if let Ok(bundle) = engine
                .store
                .call(move |store| store.session_bundle(&session_id, 0, 500))
                .await
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
            engine
                .remove_cli_turn_if_matches(&queued.session.id, &queued.turn.id)
                .await;
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
        let session_id = queued.session.id.clone();
        let context = match self
            .store
            .call(move |store| store.recovery_context(&session_id, 64 * 1024))
            .await
        {
            Ok(context) => context,
            Err(_) => return original,
        };
        let session_id = queued.session.id.clone();
        let _ = self
            .store
            .call(move |store| store.clear_provider_session(&session_id))
            .await;
        let turn_id = queued.turn.id.clone();
        if let Ok(message) = self
            .store
            .call(move |store| {
                store.append_message(
                    &turn_id,
                    MessageRole::System,
                    "status",
                    "原供应商 Session 已失效，TodoAgent 正在用最近对话重建上下文。",
                    None,
                )
            })
            .await
        {
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
        let turn_id = turn_id.to_owned();
        match self
            .store
            .call(move |store| store.append_agent_text(&turn_id, &text))
            .await
        {
            Ok(message) => self.emit("session.message.delta", &message).await,
            Err(error) => tracing::error!("failed to persist agent text: {error}"),
        }
    }

    async fn persist_provider_event(&self, queued: &QueuedTurn, event: ProviderEvent) {
        match event {
            ProviderEvent::SessionId(id) => {
                let session_id = queued.session.id.clone();
                let _ = self
                    .store
                    .call(move |store| store.set_provider_session(&session_id, &id))
                    .await;
            }
            ProviderEvent::ToolUse {
                name,
                call_id,
                input,
            } => {
                let payload = json!({"name":name,"callId":call_id,"input":input});
                let turn_id = queued.turn.id.clone();
                if let Ok(message) = self
                    .store
                    .call(move |store| {
                        store.append_message(
                            &turn_id,
                            MessageRole::Tool,
                            "tool_call",
                            &name,
                            Some(&payload.to_string()),
                        )
                    })
                    .await
                {
                    self.emit("session.message.appended", &message).await;
                }
            }
            ProviderEvent::ToolResult {
                name,
                call_id,
                output,
            } => {
                let payload = json!({"name":name,"callId":call_id});
                let turn_id = queued.turn.id.clone();
                if let Ok(message) = self
                    .store
                    .call(move |store| {
                        store.append_message(
                            &turn_id,
                            MessageRole::Tool,
                            "tool_result",
                            &output,
                            Some(&payload.to_string()),
                        )
                    })
                    .await
                {
                    self.emit("session.message.appended", &message).await;
                }
            }
            ProviderEvent::Status(status) => {
                let turn_id = queued.turn.id.clone();
                if let Ok(message) = self
                    .store
                    .call(move |store| {
                        store.append_message(&turn_id, MessageRole::System, "status", &status, None)
                    })
                    .await
                {
                    self.emit("session.message.appended", &message).await;
                }
            }
            ProviderEvent::Raw { kind, payload } => {
                let turn_id = queued.turn.id.clone();
                let _ = self
                    .store
                    .call(move |store| store.append_turn_event(&turn_id, &kind, &payload))
                    .await;
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
            let session_id = queued.session.id.clone();
            let bundle = self
                .store
                .call(move |store| store.session_bundle(&session_id, 0, 2000))
                .await
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
        let turn_id = queued.turn.id.clone();
        match self
            .store
            .call(move |store| {
                store.finish_turn(
                    &turn_id,
                    status,
                    outcome.exit_code,
                    Some(&outcome.final_output),
                    outcome.provider_session_id.as_deref(),
                    outcome.error_code.as_deref(),
                    outcome.error_message.as_deref(),
                    usage.as_deref(),
                )
            })
            .await
        {
            Ok(bundle) => {
                self.remove_cli_turn_if_matches(&queued.session.id, &queued.turn.id)
                    .await;
                self.emit("session.turn.finished", &bundle).await;
                self.emit("session.state_changed", &bundle).await;
                self.emit("session.unread_changed", &bundle.session).await;
            }
            Err(error) => {
                self.remove_cli_turn_if_matches(&queued.session.id, &queued.turn.id)
                    .await;
                tracing::error!("failed to finish turn: {error}");
            }
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
        self.remove_cli_turn_if_matches(&queued.session.id, &queued.turn.id)
            .await;
    }

    async fn remove_cli_turn_if_matches(&self, session_id: &str, turn_id: &str) -> bool {
        let mut turns = self.turns.lock().await;
        remove_matching_cli_turn(&mut turns, session_id, turn_id)
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
        self.assistant.shutdown().await;
        *self.gemini_key.lock().await = None;
        let tokens: Vec<_> = self.turns.lock().await.values().cloned().collect();
        for active in tokens {
            active.cancellation.cancel();
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self.turns.lock().await.is_empty() && Instant::now() < deadline {
            sleep(Duration::from_millis(50)).await;
        }
        if let Err(error) = self.store.shutdown().await {
            tracing::error!("failed to stop database worker: {error}");
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

fn remove_matching_cli_turn(
    turns: &mut HashMap<String, ActiveCliTurn>,
    session_id: &str,
    turn_id: &str,
) -> bool {
    if turns
        .get(session_id)
        .is_some_and(|active| active.turn_id == turn_id)
    {
        turns.remove(session_id);
        true
    } else {
        false
    }
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
        EngineError::Runtime(code) => Response::err(id, code, code.replace('_', " ")),
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
    use uuid::Uuid;

    fn test_runtime(kind: RuntimeKind, status: &str) -> models::Runtime {
        models::Runtime {
            kind,
            launch_path: Some("/usr/bin/true".to_owned()),
            resolved_path: Some("/usr/bin/true".to_owned()),
            version: Some("test".to_owned()),
            status: status.to_owned(),
            auth_status: if status == "auth_required" {
                "required".to_owned()
            } else {
                "authenticated".to_owned()
            },
            capabilities: json!({}),
            provider_engine: None,
            detected_at: None,
            verified_at: None,
            verify_error: None,
        }
    }

    fn test_engine(
        store: StoreWorker,
        concurrency: usize,
        data_directory: PathBuf,
    ) -> (Engine, std::sync::mpsc::Receiver<Value>) {
        let (writer, receiver) = sync_channel(512);
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
                turns: Arc::new(Mutex::new(HashMap::new())),
                concurrency: Arc::new(Semaphore::new(concurrency)),
                authorized_directories: Arc::new(Mutex::new(HashSet::new())),
                gemini_key,
                assistant,
                data_directory,
                task_file_mutation,
            },
            receiver,
        )
    }

    #[test]
    fn request_size_is_bounded() {
        assert_eq!(MAX_REQUEST_BYTES, 1024 * 1024);
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

        sleep(Duration::from_millis(50)).await;

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
    fn session_lookup_requires_protocol_camel_case_ids() {
        let task_id = Uuid::new_v4().to_string();
        let task: SessionLookupParams = parse(&json!({"taskId":task_id.to_uppercase()})).unwrap();
        assert_eq!(task.task_id.as_deref(), Some(task_id.as_str()));
        assert!(task.session_id.is_none());

        let error =
            parse::<SessionLookupParams>(&json!({"taskID":task_id.to_uppercase()})).unwrap_err();
        assert!(error.to_string().contains("unknown field `taskID`"));
    }

    #[test]
    fn stale_cli_turn_cleanup_never_removes_the_next_turn_token() {
        let mut turns = HashMap::new();
        turns.insert(
            "session-1".to_owned(),
            ActiveCliTurn {
                turn_id: "turn-new".to_owned(),
                cancellation: CancellationToken::new(),
            },
        );

        assert!(!remove_matching_cli_turn(
            &mut turns,
            "session-1",
            "turn-old"
        ));
        assert_eq!(turns["session-1"].turn_id, "turn-new");
        assert!(remove_matching_cli_turn(
            &mut turns,
            "session-1",
            "turn-new"
        ));
        assert!(turns.is_empty());
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
                let session = store.create_session(&task_id, RuntimeKind::Codex, "/tmp")?;
                store.send_message(&session.id, &Uuid::new_v4().to_string(), "执行中")?;
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

    #[tokio::test(flavor = "current_thread")]
    async fn session_create_checks_executable_before_persisting_the_session() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("session-create.sqlite3")).unwrap();
        let task_id = worker
            .call(|store| Ok(store.create_task("任务", "", None, None, None)?.id))
            .await
            .unwrap();
        let mut pathless = test_runtime(RuntimeKind::Codex, "ready");
        pathless.launch_path = None;
        pathless.resolved_path = None;
        worker
            .call(move |store| store.save_runtime(&pathless))
            .await
            .unwrap();
        let (engine, _receiver) = test_engine(worker.clone(), 0, directory.path().to_owned());
        let workspace = fs::canonicalize(directory.path()).unwrap();
        engine
            .authorized_directories
            .lock()
            .await
            .insert(workspace.clone());

        let error = engine
            .handle_inner(&Request {
                id: "create".to_owned(),
                method: "session.create".to_owned(),
                params: json!({
                    "taskId": task_id,
                    "runtimeKind": "codex",
                    "workingDirectory": workspace.display().to_string(),
                }),
            })
            .await
            .unwrap_err();
        assert!(matches!(error, EngineError::Runtime("runtime_missing")));
        let session = worker
            .call(move |store| store.session_for_task(&task_id))
            .await
            .unwrap();
        assert!(session.is_none());

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn session_create_returns_an_empty_idle_bundle_and_replays_without_scheduling() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let workspace = directory.path().join("workspace");
        fs::create_dir_all(data.join("Attachments")).unwrap();
        fs::create_dir_all(&workspace).unwrap();
        let worker = StoreWorker::open(&data.join("todoagent.sqlite3")).unwrap();
        let task = worker
            .call(|store| {
                store.create_task(
                    "任务标题",
                    "任务备注",
                    None,
                    Some("2026-08-10"),
                    Some("2026-08-12"),
                )
            })
            .await
            .unwrap();
        let ready = test_runtime(RuntimeKind::Codex, "ready");
        worker
            .call(move |store| store.save_runtime(&ready))
            .await
            .unwrap();
        let (engine, receiver) = test_engine(worker.clone(), 0, data);
        let workspace = fs::canonicalize(workspace).unwrap();
        engine
            .authorized_directories
            .lock()
            .await
            .insert(workspace.clone());
        let params = json!({
            "taskId":task.id.to_uppercase(),
            "runtimeKind":"codex",
            "workingDirectory":workspace.display().to_string(),
        });

        let first = engine
            .handle(Request {
                id: "session-create-first".to_owned(),
                method: "session.create".to_owned(),
                params: params.clone(),
            })
            .await
            .result
            .unwrap();
        let event = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event["event"], "session.created");
        assert_eq!(event["data"], first);
        assert_eq!(first["session"]["state"], "idle");
        assert!(first["messages"].as_array().unwrap().is_empty());
        assert!(first["activeTurn"].is_null());
        assert!(engine.turns.lock().await.is_empty());
        let session_id = first["session"]["id"].as_str().unwrap().to_owned();
        let revision = worker.call(|store| store.revision()).await.unwrap();
        let turn_count = worker
            .call({
                let session_id = session_id.clone();
                move |store| store.session_turn_count(&session_id)
            })
            .await
            .unwrap();
        assert_eq!(turn_count, 0);

        let unavailable = test_runtime(RuntimeKind::Codex, "auth_required");
        worker
            .call(move |store| store.save_runtime(&unavailable))
            .await
            .unwrap();
        let replay_revision = worker.call(|store| store.revision()).await.unwrap();
        let replayed = engine
            .handle(Request {
                id: "session-create-replay".to_owned(),
                method: "session.create".to_owned(),
                params,
            })
            .await
            .result
            .unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap()["data"],
            replayed
        );
        assert_eq!(replayed["session"]["id"], session_id);
        assert!(replayed["messages"].as_array().unwrap().is_empty());
        assert!(replayed["activeTurn"].is_null());
        assert!(replay_revision > revision);
        assert_eq!(
            worker.call(|store| store.revision()).await.unwrap(),
            replay_revision
        );
        assert!(engine.turns.lock().await.is_empty());

        engine.assistant.shutdown().await;
        worker.shutdown().await.unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn session_send_checks_runtime_before_queue_and_keeps_retries_idempotent() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("session-send.sqlite3")).unwrap();
        let session_id = worker
            .call(|store| {
                let task = store.create_task("任务", "", None, None, None)?;
                Ok(store
                    .create_session(&task.id, RuntimeKind::Codex, "/tmp")?
                    .id)
            })
            .await
            .unwrap();
        let (engine, _receiver) = test_engine(worker.clone(), 0, directory.path().to_owned());
        let initial_turn_count = worker
            .call({
                let session_id = session_id.clone();
                move |store| store.session_turn_count(&session_id)
            })
            .await
            .unwrap();

        let missing_error = engine
            .prepare_session_send(SendSessionParams {
                session_id: session_id.clone(),
                client_message_id: Uuid::new_v4().to_string(),
                text: "runtime missing".to_owned(),
            })
            .await
            .unwrap_err();
        assert!(matches!(
            missing_error,
            EngineError::Runtime("runtime_missing")
        ));

        for (status, expected_error) in [
            ("auth_required", "auth_required"),
            ("error", "runtime_not_verified"),
        ] {
            let runtime = test_runtime(RuntimeKind::Codex, status);
            worker
                .call(move |store| store.save_runtime(&runtime))
                .await
                .unwrap();
            let error = engine
                .prepare_session_send(SendSessionParams {
                    session_id: session_id.clone(),
                    client_message_id: Uuid::new_v4().to_string(),
                    text: format!("runtime {status}"),
                })
                .await
                .unwrap_err();
            assert!(matches!(
                error,
                EngineError::Runtime(code) if code == expected_error
            ));
        }

        let unchanged_turn_count = worker
            .call({
                let session_id = session_id.clone();
                move |store| store.session_turn_count(&session_id)
            })
            .await
            .unwrap();
        assert_eq!(unchanged_turn_count, initial_turn_count);
        let unchanged_bundle = worker
            .call({
                let session_id = session_id.clone();
                move |store| store.session_bundle(&session_id, 0, 100)
            })
            .await
            .unwrap();
        assert!(unchanged_bundle.active_turn.is_none());
        assert!(unchanged_bundle.messages.is_empty());

        let ready = test_runtime(RuntimeKind::Codex, "ready");
        worker
            .call(move |store| store.save_runtime(&ready))
            .await
            .unwrap();
        let client_message_id = Uuid::new_v4().to_string();
        let params = SendSessionParams {
            session_id: session_id.clone(),
            client_message_id: client_message_id.clone(),
            text: "正常发送".to_owned(),
        };
        let (queued, executable) = engine.prepare_session_send(params).await.unwrap();
        assert!(queued.is_new);
        assert_eq!(queued.turn.status, TurnStatus::Queued);
        assert_eq!(queued.prompt, "正常发送");
        assert_eq!(executable.as_deref(), Some("/usr/bin/true"));
        let queued_turn_count = worker
            .call({
                let session_id = session_id.clone();
                move |store| store.session_turn_count(&session_id)
            })
            .await
            .unwrap();
        assert_eq!(queued_turn_count, initial_turn_count + 1);

        let unavailable = test_runtime(RuntimeKind::Codex, "auth_required");
        worker
            .call(move |store| store.save_runtime(&unavailable))
            .await
            .unwrap();
        let (duplicate, duplicate_executable) = engine
            .prepare_session_send(SendSessionParams {
                session_id: session_id.clone(),
                client_message_id,
                text: "正常发送".to_owned(),
            })
            .await
            .unwrap();
        assert!(!duplicate.is_new);
        assert_eq!(duplicate.turn.id, queued.turn.id);
        assert!(duplicate_executable.is_none());
        let duplicate_turn_count = worker
            .call({
                let session_id = session_id.clone();
                move |store| store.session_turn_count(&session_id)
            })
            .await
            .unwrap();
        assert_eq!(duplicate_turn_count, queued_turn_count);

        engine.schedule(queued.clone(), executable.unwrap()).await;
        let cancellation = engine
            .turns
            .lock()
            .await
            .get(&session_id)
            .expect("ready send should be scheduled")
            .cancellation
            .clone();
        cancellation.cancel();
        engine.concurrency.add_permits(1);
        tokio::time::timeout(Duration::from_secs(2), async {
            while !engine.turns.lock().await.is_empty() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let finished = worker
            .call(move |store| store.turn(&queued.turn.id))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(finished.status, TurnStatus::Cancelled);

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

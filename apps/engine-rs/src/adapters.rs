use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use agent_client_protocol::schema::ProtocolVersion;
use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;
use serde_json::{Value, json};
use tokio::io::{
    AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader, Lines,
};
use tokio::process::{Child, Command};
use tokio::sync::mpsc;
use tokio::time::{Instant, sleep, timeout};
use tokio_util::sync::CancellationToken;

use crate::models::RuntimeKind;
use crate::runtime::merged_path;

const WALL_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const STDERR_LIMIT: u64 = 64 * 1024;
const ACP_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(90);
const ACP_PROMPT_IDLE_TIMEOUT: Duration = Duration::from_secs(90);
const ACP_PROMPT_WALL_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const ACP_CANCEL_GRACE: Duration = Duration::from_millis(250);

#[derive(Debug, Clone)]
pub enum ProviderEvent {
    SessionId(String),
    Text(String),
    /// Reasoning text explicitly exposed by the provider. Token counters and
    /// encrypted/hidden reasoning never use this variant.
    Reasoning(String),
    ToolUse {
        name: String,
        call_id: String,
        input: Value,
    },
    ToolResult {
        name: String,
        call_id: String,
        output: String,
        is_error: bool,
    },
    Status(String),
}

/// One provider transport frame and every semantic event derived from that
/// exact frame. The Engine persists the whole value atomically before any UI
/// event is emitted, so a crash cannot leave a projection without its audit
/// source (or vice versa).
#[derive(Debug, Clone)]
pub struct ProviderFrame {
    pub raw_kind: Option<String>,
    pub raw_payload: Option<Value>,
    pub events: Vec<ProviderEvent>,
}

impl ProviderFrame {
    fn raw(kind: impl Into<String>, payload: Value, events: Vec<ProviderEvent>) -> Self {
        Self {
            raw_kind: Some(kind.into()),
            raw_payload: Some(payload),
            events,
        }
    }
}

#[derive(Debug, Clone)]
pub struct TurnRequest {
    pub runtime: RuntimeKind,
    pub executable: PathBuf,
    pub working_directory: PathBuf,
    pub prompt: String,
    pub provider_session_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct TurnOutcome {
    pub status: &'static str,
    pub exit_code: Option<i32>,
    pub final_output: String,
    pub provider_session_id: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub usage: Option<Value>,
}

impl TurnOutcome {
    fn failed(code: &str, message: impl Into<String>) -> Self {
        Self {
            status: "failed",
            exit_code: None,
            final_output: String::new(),
            provider_session_id: None,
            error_code: Some(code.to_owned()),
            error_message: Some(message.into()),
            usage: None,
        }
    }

    fn cancelled() -> Self {
        Self {
            status: "cancelled",
            exit_code: None,
            final_output: String::new(),
            provider_session_id: None,
            error_code: Some("cancelled".to_owned()),
            error_message: Some("cancelled".to_owned()),
            usage: None,
        }
    }
}

pub async fn run_turn(
    request: TurnRequest,
    cancellation: CancellationToken,
    events: mpsc::Sender<ProviderFrame>,
) -> TurnOutcome {
    if !request.working_directory.is_dir() {
        return TurnOutcome::failed("directory_missing", "working directory does not exist");
    }
    match request.runtime {
        RuntimeKind::Codex => run_stream(request, cancellation, events, StreamKind::Codex).await,
        RuntimeKind::Claude => run_stream(request, cancellation, events, StreamKind::Claude).await,
        RuntimeKind::Cursor => run_stream(request, cancellation, events, StreamKind::Cursor).await,
        RuntimeKind::Kiro => run_kiro(request, cancellation, events).await,
    }
}

#[derive(Clone, Copy)]
enum StreamKind {
    Codex,
    Claude,
    Cursor,
}

/// Replays already-persisted provider frames into the same semantic vocabulary
/// used by live turns. It intentionally omits Raw events; callers already own
/// the durable turn_event row they are replaying.
pub struct RecordedEventParser {
    runtime: RuntimeKind,
    stream: Option<StreamParser>,
}

impl RecordedEventParser {
    pub fn new(runtime: RuntimeKind) -> Self {
        let stream = match runtime {
            RuntimeKind::Codex => Some(StreamParser::new(StreamKind::Codex)),
            RuntimeKind::Claude => Some(StreamParser::new(StreamKind::Claude)),
            RuntimeKind::Cursor => Some(StreamParser::new(StreamKind::Cursor)),
            RuntimeKind::Kiro => None,
        };
        Self { runtime, stream }
    }

    pub fn parse(&mut self, value: Value) -> Vec<ProviderEvent> {
        if self.runtime == RuntimeKind::Kiro {
            return parse_kiro_update(value.pointer("/params/update").unwrap_or(&Value::Null));
        }
        self.stream
            .as_mut()
            .map(|parser| parser.parse(value))
            .unwrap_or_default()
    }
}

async fn run_stream(
    request: TurnRequest,
    cancellation: CancellationToken,
    events: mpsc::Sender<ProviderFrame>,
    kind: StreamKind,
) -> TurnOutcome {
    let mut command = Command::new(&request.executable);
    configure_command(&mut command, &request.working_directory);
    let stdin_prompt = match kind {
        StreamKind::Codex => {
            command
                .args(["-s", "workspace-write", "-a", "never", "-C"])
                .arg(&request.working_directory)
                .arg("exec");
            if let Some(session) = &request.provider_session_id {
                command.args(["resume", session, "--json", "--skip-git-repo-check", "-"]);
            } else {
                command.args(["--json", "--skip-git-repo-check", "-"]);
            }
            true
        }
        StreamKind::Claude => {
            command.args([
                "--print",
                "--input-format",
                "text",
                "--output-format",
                "stream-json",
                "--verbose",
                "--permission-mode",
                "bypassPermissions",
            ]);
            if let Some(session) = &request.provider_session_id {
                command.args(["--resume", session]);
            }
            true
        }
        StreamKind::Cursor => {
            command
                .arg("-p")
                .arg(&request.prompt)
                .args([
                    "--output-format",
                    "stream-json",
                    "--force",
                    "--trust",
                    "--workspace",
                ])
                .arg(&request.working_directory);
            if let Some(session) = &request.provider_session_id {
                command.args(["--resume", session]);
            }
            false
        }
    };
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => return TurnOutcome::failed("spawn_failed", error.to_string()),
    };
    let pid = child.id();
    if stdin_prompt {
        if let Some(mut stdin) = child.stdin.take() {
            if let Err(error) = stdin.write_all(request.prompt.as_bytes()).await {
                terminate_group(pid).await;
                return TurnOutcome::failed("stdin_failed", error.to_string());
            }
        }
    } else {
        drop(child.stdin.take());
    }
    let Some(stdout) = child.stdout.take() else {
        terminate_group(pid).await;
        return TurnOutcome::failed("stdout_missing", "runtime stdout is unavailable");
    };
    let stderr_task = read_stderr(child.stderr.take());
    let mut lines = BufReader::new(stdout).lines();
    let mut parser = StreamParser::new(kind);
    let wall = sleep(WALL_TIMEOUT);
    tokio::pin!(wall);
    loop {
        tokio::select! {
            _ = cancellation.cancelled() => {
                terminate_group(pid).await;
                let _ = child.wait().await;
                let _ = stderr_task.await;
                return TurnOutcome::cancelled();
            }
            _ = &mut wall => {
                terminate_group(pid).await;
                let _ = child.wait().await;
                let stderr = stderr_task.await.unwrap_or_default();
                return TurnOutcome::failed("timed_out", if stderr.is_empty() { "runtime exceeded 30 minutes".to_owned() } else { stderr });
            }
            line = lines.next_line() => match line {
                Ok(Some(line)) => {
                    if let Ok(value) = serde_json::from_str::<Value>(&line) {
                        let kind = value
                            .get("type")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown")
                            .to_owned();
                        let semantic_events = parser.parse(value.clone());
                        let _ = events
                            .send(ProviderFrame::raw(kind, value, semantic_events))
                            .await;
                    }
                }
                Ok(None) => break,
                Err(error) => {
                    terminate_group(pid).await;
                    let _ = child.wait().await;
                    return TurnOutcome::failed("stream_failed", error.to_string());
                }
            }
        }
    }
    let status = child.wait().await.ok();
    let stderr = stderr_task.await.unwrap_or_default();
    parser.finish(status.and_then(|value| value.code()), stderr)
}

struct StreamParser {
    kind: StreamKind,
    terminal: bool,
    failed: Option<String>,
    session_id: Option<String>,
    final_output: String,
    usage: Option<Value>,
}

impl StreamParser {
    fn new(kind: StreamKind) -> Self {
        Self {
            kind,
            terminal: false,
            failed: None,
            session_id: None,
            final_output: String::new(),
            usage: None,
        }
    }

    fn parse(&mut self, value: Value) -> Vec<ProviderEvent> {
        let event_type = value.get("type").and_then(Value::as_str).unwrap_or("");
        match self.kind {
            StreamKind::Codex => self.parse_codex(event_type, &value),
            StreamKind::Claude => self.parse_claude(event_type, &value),
            StreamKind::Cursor => self.parse_cursor(event_type, &value),
        }
    }

    fn parse_codex(&mut self, event_type: &str, value: &Value) -> Vec<ProviderEvent> {
        let mut out = Vec::new();
        match event_type {
            "thread.started" => {
                if let Some(id) =
                    string_at(value, &["thread_id"]).or_else(|| string_at(value, &["thread", "id"]))
                {
                    self.session_id = Some(id.clone());
                    out.push(ProviderEvent::SessionId(id));
                }
            }
            "item.completed" => {
                let item = value.get("item").unwrap_or(&Value::Null);
                match item.get("type").and_then(Value::as_str).unwrap_or("") {
                    "agent_message" => {
                        if let Some(text) = string_at(item, &["text"]) {
                            self.final_output = text.clone();
                            out.push(ProviderEvent::Text(text));
                        }
                    }
                    "reasoning" => {
                        if let Some(text) = string_at(item, &["text"])
                            .or_else(|| string_at(item, &["summary"]))
                            .filter(|text| !text.is_empty())
                        {
                            out.push(ProviderEvent::Reasoning(text));
                        }
                    }
                    "command_execution" | "file_change" | "mcp_tool_call" => {
                        out.push(ProviderEvent::ToolResult {
                            name: item
                                .get("type")
                                .and_then(Value::as_str)
                                .unwrap_or("tool")
                                .to_owned(),
                            call_id: string_at(item, &["id"]).unwrap_or_default(),
                            output: compact_json(item),
                            is_error: value_is_error(item),
                        });
                    }
                    _ => {}
                }
            }
            "item.started" => {
                let item = value.get("item").unwrap_or(&Value::Null);
                if matches!(
                    item.get("type").and_then(Value::as_str),
                    Some("command_execution" | "file_change" | "mcp_tool_call")
                ) {
                    out.push(ProviderEvent::ToolUse {
                        name: item
                            .get("type")
                            .and_then(Value::as_str)
                            .unwrap_or("tool")
                            .to_owned(),
                        call_id: string_at(item, &["id"]).unwrap_or_default(),
                        input: item.clone(),
                    });
                }
            }
            "turn.completed" => {
                self.terminal = true;
                self.usage = value.get("usage").cloned();
            }
            "turn.failed" => {
                self.failed = Some(compact_json(value));
            }
            _ => {}
        }
        out
    }

    fn parse_claude(&mut self, event_type: &str, value: &Value) -> Vec<ProviderEvent> {
        let mut out = Vec::new();
        match event_type {
            "system" => {
                if value.get("subtype").and_then(Value::as_str) == Some("init") {
                    if let Some(id) = string_at(value, &["session_id"]) {
                        self.session_id = Some(id.clone());
                        out.push(ProviderEvent::SessionId(id));
                    }
                }
            }
            "assistant" => {
                if let Some(content) = value.pointer("/message/content").and_then(Value::as_array) {
                    for block in content {
                        match block.get("type").and_then(Value::as_str).unwrap_or("") {
                            "text" => {
                                if let Some(text) = string_at(block, &["text"]) {
                                    self.final_output.push_str(&text);
                                    out.push(ProviderEvent::Text(text));
                                }
                            }
                            "tool_use" => out.push(ProviderEvent::ToolUse {
                                name: string_at(block, &["name"])
                                    .unwrap_or_else(|| "tool".to_owned()),
                                call_id: string_at(block, &["id"]).unwrap_or_default(),
                                input: block.get("input").cloned().unwrap_or(Value::Null),
                            }),
                            "thinking" => {
                                if let Some(text) = string_at(block, &["thinking"])
                                    .or_else(|| string_at(block, &["text"]))
                                    .filter(|text| !text.is_empty())
                                {
                                    out.push(ProviderEvent::Reasoning(text));
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            "user" => {
                if let Some(content) = value.pointer("/message/content").and_then(Value::as_array) {
                    for block in content {
                        if block.get("type").and_then(Value::as_str) == Some("tool_result") {
                            out.push(ProviderEvent::ToolResult {
                                name: "".to_owned(),
                                call_id: string_at(block, &["tool_use_id"]).unwrap_or_default(),
                                output: compact_json(block),
                                is_error: value_is_error(block),
                            });
                        }
                    }
                }
            }
            "result" => {
                self.terminal = true;
                if let Some(id) = string_at(value, &["session_id"]) {
                    self.session_id = Some(id.clone());
                    out.push(ProviderEvent::SessionId(id));
                }
                if value.get("is_error").and_then(Value::as_bool) == Some(true) {
                    self.failed = Some(compact_json(value));
                }
                if self.final_output.is_empty() {
                    self.final_output = string_at(value, &["result"]).unwrap_or_default();
                }
                self.usage = value.get("usage").cloned();
            }
            _ => {}
        }
        out
    }

    fn parse_cursor(&mut self, event_type: &str, value: &Value) -> Vec<ProviderEvent> {
        let mut out = Vec::new();
        match event_type {
            "system" => {
                if let Some(id) =
                    string_at(value, &["session_id"]).or_else(|| string_at(value, &["sessionId"]))
                {
                    self.session_id = Some(id.clone());
                    out.push(ProviderEvent::SessionId(id));
                }
                out.push(ProviderEvent::Status(
                    string_at(value, &["subtype"]).unwrap_or_else(|| "system".to_owned()),
                ));
            }
            "assistant" => {
                if let Some(message) = value.get("message") {
                    apply_cursor_usage(&mut self.usage, message);
                }
                if let Some(content) = value.pointer("/message/content").and_then(Value::as_array) {
                    for block in content {
                        match block.get("type").and_then(Value::as_str).unwrap_or("") {
                            "text" | "output_text" => {
                                if let Some(text) =
                                    string_at(block, &["text"]).filter(|text| !text.is_empty())
                                {
                                    self.final_output.push_str(&text);
                                    out.push(ProviderEvent::Text(text));
                                }
                            }
                            "thinking" => {
                                if let Some(text) =
                                    string_at(block, &["text"]).filter(|text| !text.is_empty())
                                {
                                    out.push(ProviderEvent::Reasoning(text));
                                }
                            }
                            "tool_use" => out.push(ProviderEvent::ToolUse {
                                name: string_at(block, &["name"])
                                    .unwrap_or_else(|| "unknown".to_owned()),
                                call_id: string_at(block, &["id"]).unwrap_or_default(),
                                input: block.get("input").cloned().unwrap_or(Value::Null),
                            }),
                            _ => {}
                        }
                    }
                }
            }
            "text" => {
                if let Some(text) = string_at(value, &["text"]) {
                    self.final_output.push_str(&text);
                    out.push(ProviderEvent::Text(text));
                }
            }
            "thinking" => {
                if value.get("subtype").and_then(Value::as_str) != Some("delta") {
                    if let Some(text) = string_at(value, &["text"]).filter(|text| !text.is_empty())
                    {
                        out.push(ProviderEvent::Reasoning(text));
                    }
                }
            }
            "tool_call" => {
                if let Some(inner) = value.get("tool_call").and_then(Value::as_object) {
                    let key = inner
                        .iter()
                        .find(|(key, detail)| key.ends_with("ToolCall") && detail.is_object())
                        .map(|(key, _)| key.clone());
                    let name = key
                        .as_deref()
                        .map(|key| key.trim_end_matches("ToolCall").to_owned())
                        .or_else(|| string_at(value, &["tool_name"]))
                        .unwrap_or_else(|| "unknown".to_owned());
                    let detail = key
                        .as_ref()
                        .and_then(|key| inner.get(key))
                        .cloned()
                        .unwrap_or(Value::Null);
                    let call_id = string_at(value, &["call_id"])
                        .or_else(|| {
                            inner
                                .get("toolCallId")
                                .and_then(Value::as_str)
                                .map(str::to_owned)
                        })
                        .or_else(|| string_at(value, &["tool_id"]))
                        .unwrap_or_default();
                    if value.get("subtype").and_then(Value::as_str) == Some("started") {
                        out.push(ProviderEvent::ToolUse {
                            name,
                            call_id,
                            input: detail.get("args").cloned().unwrap_or(Value::Null),
                        });
                    } else if value.get("subtype").and_then(Value::as_str) == Some("completed") {
                        out.push(ProviderEvent::ToolResult {
                            name,
                            call_id,
                            output: cursor_tool_output(&detail),
                            is_error: cursor_tool_failed(&detail),
                        });
                    }
                }
            }
            "tool_use" => out.push(ProviderEvent::ToolUse {
                name: string_at(value, &["tool_name"]).unwrap_or_else(|| "unknown".to_owned()),
                call_id: string_at(value, &["tool_id"])
                    .or_else(|| string_at(value, &["call_id"]))
                    .unwrap_or_default(),
                input: value.get("parameters").cloned().unwrap_or(Value::Null),
            }),
            "tool_result" => out.push(ProviderEvent::ToolResult {
                name: string_at(value, &["tool_name"]).unwrap_or_default(),
                call_id: string_at(value, &["tool_id"])
                    .or_else(|| string_at(value, &["call_id"]))
                    .unwrap_or_default(),
                output: value
                    .get("output")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| compact_json(value.get("output").unwrap_or(&Value::Null))),
                is_error: value_is_error(value),
            }),
            "connection" | "retry" => out.push(ProviderEvent::Status(format!(
                "{}: {}{}",
                event_type,
                value
                    .get("subtype")
                    .and_then(Value::as_str)
                    .unwrap_or("update"),
                value
                    .get("attempt")
                    .and_then(Value::as_i64)
                    .filter(|attempt| *attempt > 0)
                    .map(|attempt| format!(" (attempt {attempt})"))
                    .unwrap_or_default()
            ))),
            "result" => {
                self.terminal = true;
                if let Some(id) =
                    string_at(value, &["session_id"]).or_else(|| string_at(value, &["sessionId"]))
                {
                    self.session_id = Some(id.clone());
                    out.push(ProviderEvent::SessionId(id));
                }
                if value.get("is_error").and_then(Value::as_bool) == Some(true) {
                    self.failed = Some(compact_json(value));
                }
                if self.final_output.is_empty() {
                    self.final_output = string_at(value, &["result"]).unwrap_or_default();
                }
                apply_cursor_usage(&mut self.usage, value);
            }
            "error" => {
                self.failed = string_at(value, &["error"])
                    .or_else(|| string_at(value, &["detail"]))
                    .or_else(|| Some(compact_json(value)));
            }
            "step_finish" => apply_cursor_usage(&mut self.usage, value),
            _ => {}
        }
        out
    }

    fn finish(self, exit_code: Option<i32>, stderr: String) -> TurnOutcome {
        let failure = self
            .failed
            .or_else(|| {
                (exit_code != Some(0)).then(|| {
                    if stderr.is_empty() {
                        format!("runtime exited {exit_code:?}")
                    } else {
                        stderr
                    }
                })
            })
            .or_else(|| {
                (!self.terminal).then(|| "runtime ended without a terminal event".to_owned())
            });
        if let Some(error) = failure {
            TurnOutcome {
                status: "failed",
                exit_code,
                final_output: self.final_output,
                provider_session_id: self.session_id,
                error_code: Some(classify_error(&error).to_owned()),
                error_message: Some(error),
                usage: self.usage,
            }
        } else {
            TurnOutcome {
                status: "completed",
                exit_code,
                final_output: self.final_output,
                provider_session_id: self.session_id,
                error_code: None,
                error_message: None,
                usage: self.usage,
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct AcpWaitPolicy {
    hard_timeout: Duration,
    idle_timeout: Option<Duration>,
}

impl AcpWaitPolicy {
    const fn handshake() -> Self {
        Self {
            hard_timeout: ACP_HANDSHAKE_TIMEOUT,
            idle_timeout: None,
        }
    }

    const fn prompt() -> Self {
        Self {
            hard_timeout: ACP_PROMPT_WALL_TIMEOUT,
            idle_timeout: Some(ACP_PROMPT_IDLE_TIMEOUT),
        }
    }
}

#[derive(Debug, Default)]
struct KiroMetering {
    credits: f64,
}

struct AcpWaitContext<'a> {
    phase: AcpPhase,
    events: &'a mpsc::Sender<ProviderFrame>,
    cancellation: &'a CancellationToken,
    cancel_session_id: Option<&'a str>,
    policy: AcpWaitPolicy,
    metering: &'a mut KiroMetering,
}

impl KiroMetering {
    fn observe(&mut self, params: &Value) {
        let Some(entries) = params.get("meteringUsage").and_then(Value::as_array) else {
            return;
        };
        for entry in entries {
            if entry.get("unit").and_then(Value::as_str) != Some("credit") {
                continue;
            }
            if let Some(value) = entry.get("value").and_then(Value::as_f64)
                && value.is_finite()
                && value >= 0.0
            {
                self.credits += value;
            }
        }
    }

    fn usage(&self, prompt_meta: Option<&Value>) -> Option<Value> {
        if self.credits == 0.0 && prompt_meta.is_none() {
            return None;
        }
        let mut usage = serde_json::Map::new();
        usage.insert("provider".to_owned(), Value::String("kiro".to_owned()));
        if self.credits > 0.0 {
            usage.insert(
                "credits".to_owned(),
                json!({"unit":"credit","value":self.credits}),
            );
        }
        if let Some(meta) = prompt_meta {
            usage.insert("providerMeta".to_owned(), meta.clone());
        }
        Some(Value::Object(usage))
    }
}

async fn run_kiro(
    request: TurnRequest,
    cancellation: CancellationToken,
    events: mpsc::Sender<ProviderFrame>,
) -> TurnOutcome {
    // Keep the official SDK linked and version-pinned while TodoAgent owns the subprocess transport
    // so it can enforce cwd, process groups and the app-wide cancellation contract.
    let _wire_version_type = std::mem::size_of::<ProtocolVersion>();
    let mut command = Command::new(&request.executable);
    configure_command(&mut command, &request.working_directory);
    command.args(["acp", "--trust-all-tools", "--agent-engine", "v2"]);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => return TurnOutcome::failed("spawn_failed", error.to_string()),
    };
    let pid = child.id();
    let Some(mut stdin) = child.stdin.take() else {
        terminate_group(pid).await;
        return TurnOutcome::failed("stdin_missing", "Kiro stdin missing");
    };
    let Some(stdout) = child.stdout.take() else {
        terminate_group(pid).await;
        return TurnOutcome::failed("stdout_missing", "Kiro stdout missing");
    };
    let stderr_task = read_stderr(child.stderr.take());
    let mut lines = BufReader::new(stdout).lines();
    let mut metering = KiroMetering::default();
    let initialize = json!({
        "jsonrpc":"2.0", "id":1, "method":"initialize",
        "params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}},"clientInfo":{"name":"TodoAgent","version":env!("CARGO_PKG_VERSION")}}
    });
    if let Err(error) = write_rpc(&mut stdin, &initialize).await {
        return finish_kiro_child(
            child,
            stderr_task,
            TurnOutcome::failed("acp_write_failed", error),
        )
        .await;
    }
    let init = match wait_rpc(
        &mut lines,
        &mut stdin,
        1,
        AcpWaitContext {
            phase: AcpPhase::Replay,
            events: &events,
            cancellation: &cancellation,
            cancel_session_id: None,
            policy: AcpWaitPolicy::handshake(),
            metering: &mut metering,
        },
    )
    .await
    {
        Ok(value) => value,
        Err(outcome) => return finish_kiro_child(child, stderr_task, outcome).await,
    };
    let can_load = init
        .pointer("/agentCapabilities/loadSession")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let provider_session_id = if let Some(existing) = &request.provider_session_id {
        if !can_load {
            return finish_kiro_child(
                child,
                stderr_task,
                TurnOutcome::failed(
                    "capability_missing",
                    "Kiro ACP does not advertise loadSession",
                ),
            )
            .await;
        }
        let load = json!({"jsonrpc":"2.0","id":2,"method":"session/load","params":{"sessionId":existing,"cwd":request.working_directory,"mcpServers":[]}});
        if let Err(error) = write_rpc(&mut stdin, &load).await {
            return finish_kiro_child(
                child,
                stderr_task,
                TurnOutcome::failed("acp_write_failed", error),
            )
            .await;
        }
        match wait_rpc(
            &mut lines,
            &mut stdin,
            2,
            AcpWaitContext {
                phase: AcpPhase::Replay,
                events: &events,
                cancellation: &cancellation,
                cancel_session_id: Some(existing),
                policy: AcpWaitPolicy::handshake(),
                metering: &mut metering,
            },
        )
        .await
        {
            Ok(_) => existing.clone(),
            Err(outcome) => return finish_kiro_child(child, stderr_task, outcome).await,
        }
    } else {
        let new_session = json!({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":request.working_directory,"mcpServers":[]}});
        if let Err(error) = write_rpc(&mut stdin, &new_session).await {
            return finish_kiro_child(
                child,
                stderr_task,
                TurnOutcome::failed("acp_write_failed", error),
            )
            .await;
        }
        match wait_rpc(
            &mut lines,
            &mut stdin,
            2,
            AcpWaitContext {
                phase: AcpPhase::Replay,
                events: &events,
                cancellation: &cancellation,
                cancel_session_id: None,
                policy: AcpWaitPolicy::handshake(),
                metering: &mut metering,
            },
        )
        .await
        {
            Ok(value) => match string_at(&value, &["sessionId"]) {
                Some(id) => id,
                None => {
                    return finish_kiro_child(
                        child,
                        stderr_task,
                        TurnOutcome::failed("protocol_error", "session/new returned no sessionId"),
                    )
                    .await;
                }
            },
            Err(outcome) => return finish_kiro_child(child, stderr_task, outcome).await,
        }
    };
    let prompt = json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":provider_session_id,"prompt":[{"type":"text","text":request.prompt}]}});
    if let Err(error) = write_rpc(&mut stdin, &prompt).await {
        return finish_kiro_child(
            child,
            stderr_task,
            TurnOutcome::failed("acp_write_failed", error),
        )
        .await;
    }
    let prompt_result = match wait_rpc(
        &mut lines,
        &mut stdin,
        3,
        AcpWaitContext {
            phase: AcpPhase::Live,
            events: &events,
            cancellation: &cancellation,
            cancel_session_id: Some(&provider_session_id),
            policy: AcpWaitPolicy::prompt(),
            metering: &mut metering,
        },
    )
    .await
    {
        Ok(value) => value,
        Err(outcome) => return finish_kiro_child(child, stderr_task, outcome).await,
    };
    let stop = prompt_result
        .get("stopReason")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    drop(stdin);
    let exit_code = match timeout(Duration::from_secs(3), child.wait()).await {
        Ok(Ok(status)) => status.code(),
        _ => {
            terminate_group(pid).await;
            child.wait().await.ok().and_then(|status| status.code())
        }
    };
    let stderr = stderr_task.await.unwrap_or_default();
    let usage = metering.usage(prompt_result.get("_meta"));
    if stop == "end_turn" && exit_code == Some(0) {
        TurnOutcome {
            status: "completed",
            exit_code,
            final_output: String::new(),
            provider_session_id: Some(provider_session_id),
            error_code: None,
            error_message: None,
            usage,
        }
    } else if stop == "cancelled" {
        TurnOutcome::cancelled()
    } else {
        TurnOutcome {
            status: "failed",
            exit_code,
            final_output: String::new(),
            provider_session_id: Some(provider_session_id),
            error_code: Some("process_failed".to_owned()),
            error_message: Some(if stderr.is_empty() {
                format!("ACP stopReason: {stop}")
            } else {
                stderr
            }),
            usage,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AcpPhase {
    Replay,
    Live,
}

async fn wait_rpc<R, W>(
    lines: &mut Lines<BufReader<R>>,
    stdin: &mut W,
    request_id: i64,
    context: AcpWaitContext<'_>,
) -> Result<Value, TurnOutcome>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let hard_deadline = sleep(context.policy.hard_timeout);
    tokio::pin!(hard_deadline);
    let idle_deadline = sleep(
        context
            .policy
            .idle_timeout
            .unwrap_or(context.policy.hard_timeout),
    );
    tokio::pin!(idle_deadline);
    loop {
        tokio::select! {
            _ = context.cancellation.cancelled() => {
                if let Some(session_id) = context.cancel_session_id {
                    let _ = write_rpc(stdin, &cancel_session_notification(session_id)).await;
                }
                return Err(TurnOutcome::cancelled());
            }
            _ = &mut hard_deadline => {
                return Err(TurnOutcome::failed(
                    "timed_out",
                    format!("ACP request exceeded {} seconds", context.policy.hard_timeout.as_secs()),
                ));
            }
            _ = &mut idle_deadline, if context.policy.idle_timeout.is_some() => {
                return Err(TurnOutcome::failed(
                    "timed_out",
                    format!(
                        "ACP request produced no protocol activity for {} seconds",
                        context.policy.idle_timeout.unwrap_or_default().as_secs()
                    ),
                ));
            }
            line = lines.next_line() => {
                let line = match line {
                    Ok(Some(line)) => line,
                    Ok(None) => return Err(TurnOutcome::failed("process_failed", "Kiro exited before replying")),
                    Err(error) => return Err(TurnOutcome::failed("stream_failed", error.to_string())),
                };
                let Ok(value) = serde_json::from_str::<Value>(&line) else { continue; };
                if let Some(idle_timeout) = context.policy.idle_timeout {
                    idle_deadline.as_mut().reset(Instant::now() + idle_timeout);
                }
                if value.get("id").and_then(Value::as_i64) == Some(request_id) && value.get("method").is_none() {
                    let semantic_events = value
                        .pointer("/result/sessionId")
                        .and_then(Value::as_str)
                        .filter(|id| !id.is_empty())
                        .map(|id| vec![ProviderEvent::SessionId(id.to_owned())])
                        .unwrap_or_default();
                    let _ = context
                        .events
                        .send(ProviderFrame::raw("response", value.clone(), semantic_events))
                        .await;
                    if let Some(error) = value.get("error") {
                        return Err(TurnOutcome::failed(classify_error(&compact_json(error)), compact_json(error)));
                    }
                    return Ok(value.get("result").cloned().unwrap_or(Value::Null));
                }
                let method = value
                    .get("method")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                if value.get("id").is_some_and(|id| !id.is_null()) && !method.is_empty() {
                    let _ = context
                        .events
                        .send(ProviderFrame::raw(&method, value.clone(), Vec::new()))
                        .await;
                    if method == "session/request_permission" {
                        answer_permission(stdin, &value).await;
                    } else {
                        let _ = write_rpc(stdin, &method_not_found_response(&value, &method)).await;
                    }
                    continue;
                }
                let semantic_events = if context.phase == AcpPhase::Live
                    && matches!(method.as_str(), "session/update" | "session/notification")
                {
                    parse_kiro_update(value.pointer("/params/update").unwrap_or(&Value::Null))
                } else {
                    Vec::new()
                };
                if context.phase == AcpPhase::Live && method == "_kiro.dev/metadata" {
                    context.metering.observe(value.get("params").unwrap_or(&Value::Null));
                }
                let _ = context
                    .events
                    .send(ProviderFrame::raw(
                        if method.is_empty() { "unknown" } else { &method },
                        value,
                        semantic_events,
                    ))
                    .await;
            }
        }
    }
}

fn cancel_session_notification(session_id: &str) -> Value {
    json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":session_id}})
}

fn method_not_found_response(request: &Value, method: &str) -> Value {
    json!({
        "jsonrpc":"2.0",
        "id":request.get("id").cloned().unwrap_or(Value::Null),
        "error":{"code":-32601,"message":format!("unsupported: {method}")}
    })
}

fn parse_kiro_update(update: &Value) -> Vec<ProviderEvent> {
    let kind = update
        .get("sessionUpdate")
        .and_then(Value::as_str)
        .unwrap_or("");
    match kind {
        "agent_message_chunk" | "AgentMessageChunk" => string_at(update, &["content", "text"])
            .filter(|value| !value.is_empty())
            .map(|value| vec![ProviderEvent::Text(value)])
            .unwrap_or_default(),
        "agent_thought_chunk" | "AgentThoughtChunk" => string_at(update, &["content", "text"])
            .filter(|value| !value.is_empty())
            .map(|value| vec![ProviderEvent::Reasoning(value)])
            .unwrap_or_default(),
        "tool_call" | "ToolCall" => vec![ProviderEvent::ToolUse {
            name: string_at(update, &["title"])
                .or_else(|| string_at(update, &["kind"]))
                .unwrap_or_else(|| "tool".to_owned()),
            call_id: string_at(update, &["toolCallId"]).unwrap_or_default(),
            input: update.get("rawInput").cloned().unwrap_or(Value::Null),
        }],
        "tool_call_update" | "ToolCallUpdate"
            if matches!(
                update.get("status").and_then(Value::as_str),
                Some("completed" | "failed")
            ) =>
        {
            vec![ProviderEvent::ToolResult {
                name: string_at(update, &["title"]).unwrap_or_default(),
                call_id: string_at(update, &["toolCallId"]).unwrap_or_default(),
                output: compact_json(update.get("content").unwrap_or(&Value::Null)),
                is_error: update.get("status").and_then(Value::as_str) == Some("failed")
                    || value_is_error(update),
            }]
        }
        _ => Vec::new(),
    }
}

async fn answer_permission<W: AsyncWrite + Unpin>(stdin: &mut W, request: &Value) {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let allow = request
        .pointer("/params/options")
        .and_then(Value::as_array)
        .and_then(|options| {
            options
                .iter()
                .find(|option| {
                    option
                        .get("kind")
                        .and_then(Value::as_str)
                        .is_some_and(|kind| kind.to_lowercase().contains("allow"))
                        || option
                            .get("optionId")
                            .and_then(Value::as_str)
                            .is_some_and(|kind| kind.to_lowercase().contains("allow"))
                })
                .and_then(|option| option.get("optionId").and_then(Value::as_str))
                .map(str::to_owned)
        });
    let response = if let Some(option_id) = allow {
        json!({"jsonrpc":"2.0","id":id,"result":{"outcome":{"outcome":"selected","optionId":option_id}}})
    } else {
        json!({"jsonrpc":"2.0","id":id,"result":{"outcome":{"outcome":"cancelled"}}})
    };
    let _ = write_rpc(stdin, &response).await;
}

async fn write_rpc<W: AsyncWrite + Unpin>(stdin: &mut W, value: &Value) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    stdin
        .write_all(&bytes)
        .await
        .map_err(|error| error.to_string())?;
    stdin.flush().await.map_err(|error| error.to_string())
}

async fn finish_kiro_child(
    mut child: Child,
    stderr_task: tokio::task::JoinHandle<String>,
    mut outcome: TurnOutcome,
) -> TurnOutcome {
    let mut exited = false;
    if outcome.status == "cancelled" {
        if let Ok(Ok(status)) = timeout(ACP_CANCEL_GRACE, child.wait()).await {
            outcome.exit_code = status.code();
            exited = true;
        }
    }
    if !exited {
        terminate_group(child.id()).await;
        outcome.exit_code = child.wait().await.ok().and_then(|status| status.code());
    }
    let stderr = stderr_task.await.unwrap_or_default();
    if outcome.error_message.as_deref().is_none_or(str::is_empty) && !stderr.is_empty() {
        outcome.error_message = Some(stderr);
    }
    outcome
}

fn configure_command(command: &mut Command, cwd: &Path) {
    use std::os::unix::process::CommandExt;
    command
        .current_dir(cwd)
        .env("PWD", cwd)
        .env("PATH", merged_path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    command.as_std_mut().process_group(0);
}

fn read_stderr(stderr: Option<tokio::process::ChildStderr>) -> tokio::task::JoinHandle<String> {
    tokio::spawn(async move {
        let Some(stderr) = stderr else {
            return String::new();
        };
        let mut bytes = Vec::new();
        let _ = stderr.take(STDERR_LIMIT).read_to_end(&mut bytes).await;
        String::from_utf8_lossy(&bytes).trim().to_owned()
    })
}

async fn terminate_group(pid: Option<u32>) {
    let Some(pid) = pid else {
        return;
    };
    let group = Pid::from_raw(-(pid as i32));
    let _ = kill(group, Signal::SIGTERM);
    sleep(Duration::from_secs(3)).await;
    let _ = kill(group, Signal::SIGKILL);
}

fn classify_error(message: &str) -> &'static str {
    let lowered = message.to_lowercase();
    if lowered.contains("session")
        && (lowered.contains("not found")
            || lowered.contains("invalid")
            || lowered.contains("incompatible"))
    {
        "provider_session_invalid"
    } else if lowered.contains("auth") || lowered.contains("login") || lowered.contains("logged in")
    {
        "auth_required"
    } else if lowered.contains("cancel") {
        "cancelled"
    } else {
        "process_failed"
    }
}

fn string_at(value: &Value, path: &[&str]) -> Option<String> {
    path.iter()
        .try_fold(value, |current, key| current.get(*key))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn compact_json(value: &Value) -> String {
    let value = value.to_string();
    if value.len() <= 20_000 {
        return value;
    }
    let mut end = 20_000;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn apply_cursor_usage(current: &mut Option<Value>, container: &Value) {
    let source = container
        .get("usage")
        .filter(|usage| usage.is_object())
        .unwrap_or(container);
    let delta = [
        cursor_usage_number(source, &["input_tokens", "inputTokens"]),
        cursor_usage_number(source, &["output_tokens", "outputTokens"]),
        cursor_usage_number(
            source,
            &[
                "cached_input_tokens",
                "cachedInputTokens",
                "cacheReadTokens",
                "cache_read_input_tokens",
                "cacheReadInputTokens",
            ],
        ),
        cursor_usage_number(
            source,
            &[
                "cacheWriteTokens",
                "cache_creation_input_tokens",
                "cacheCreationInputTokens",
            ],
        ),
    ];
    if delta.iter().all(|value| *value == 0) && current.is_none() {
        return;
    }
    let previous = current.as_ref().unwrap_or(&Value::Null);
    let totals = [
        cursor_usage_number(previous, &["inputTokens"]).saturating_add(delta[0]),
        cursor_usage_number(previous, &["outputTokens"]).saturating_add(delta[1]),
        cursor_usage_number(previous, &["cacheReadTokens"]).saturating_add(delta[2]),
        cursor_usage_number(previous, &["cacheWriteTokens"]).saturating_add(delta[3]),
    ];
    *current = Some(json!({
        "inputTokens": totals[0],
        "outputTokens": totals[1],
        "cacheReadTokens": totals[2],
        "cacheWriteTokens": totals[3],
    }));
}

fn cursor_usage_number(value: &Value, keys: &[&str]) -> u64 {
    keys.iter()
        .find_map(|key| {
            value.get(*key).and_then(|number| {
                number
                    .as_u64()
                    .or_else(|| number.as_i64().and_then(|value| u64::try_from(value).ok()))
            })
        })
        .unwrap_or(0)
}

fn cursor_tool_output(detail: &Value) -> String {
    let result = detail.get("result").unwrap_or(&Value::Null);
    if let Some(error) = ["error", "failure"]
        .into_iter()
        .filter_map(|key| result.get(key))
        .find(|value| meaningful_failure_value(value))
    {
        return compact_json(error);
    }
    let success = result.get("success").unwrap_or(result);
    for key in ["message", "content", "diffString"] {
        if let Some(value) = success.get(key).and_then(Value::as_str) {
            if !value.is_empty() {
                return value.chars().take(20_000).collect();
            }
        }
    }
    if let Some(files) = success.get("files").and_then(Value::as_array) {
        return files
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join("\n");
    }
    compact_json(success)
}

fn cursor_tool_failed(detail: &Value) -> bool {
    let result = detail.get("result").unwrap_or(&Value::Null);
    ["error", "failure"]
        .into_iter()
        .filter_map(|key| result.get(key))
        .any(meaningful_failure_value)
        || value_is_error(detail)
}

fn meaningful_failure_value(value: &Value) -> bool {
    match value {
        Value::Null | Value::Bool(false) => false,
        Value::String(value) => !value.trim().is_empty(),
        Value::Array(values) => !values.is_empty(),
        Value::Object(values) => !values.is_empty(),
        Value::Number(value) => value.as_i64() != Some(0),
        Value::Bool(true) => true,
    }
}

fn value_is_error(value: &Value) -> bool {
    value.get("is_error").and_then(Value::as_bool) == Some(true)
        || value.get("isError").and_then(Value::as_bool) == Some(true)
        || value.get("success").and_then(Value::as_bool) == Some(false)
        || matches!(
            value.get("status").and_then(Value::as_str),
            Some("error" | "failed" | "failure" | "cancelled" | "interrupted")
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_requires_terminal_result() {
        let parser = StreamParser::new(StreamKind::Cursor);
        let result = parser.finish(Some(0), String::new());
        assert_eq!(result.status, "failed");
        assert!(result.error_message.unwrap().contains("terminal"));
    }

    #[test]
    fn cursor_nested_tool_is_legible() {
        let mut parser = StreamParser::new(StreamKind::Cursor);
        let value = json!({"type":"tool_call","subtype":"completed","tool_call":{"toolCallId":"nested-c1","editToolCall":{"args":{"path":"a"},"result":{"success":{"message":"Wrote a"}}}}});
        let events = parser.parse(value);
        assert!(
            matches!(&events[0], ProviderEvent::ToolResult { name, call_id, output, .. } if name == "edit" && call_id == "nested-c1" && output == "Wrote a")
        );
    }

    #[test]
    fn provider_exposed_reasoning_is_normalized_for_codex_claude_and_kiro() {
        let mut codex = StreamParser::new(StreamKind::Codex);
        let events = codex.parse(json!({
            "type":"item.completed",
            "item":{"type":"reasoning","id":"reason-1","summary":"codex summary"}
        }));
        assert!(
            matches!(&events[..], [ProviderEvent::Reasoning(value)] if value == "codex summary")
        );

        let mut claude = StreamParser::new(StreamKind::Claude);
        let events = claude.parse(json!({
            "type":"assistant",
            "message":{"content":[{"type":"thinking","thinking":"claude thought"}]}
        }));
        assert!(
            matches!(&events[..], [ProviderEvent::Reasoning(value)] if value == "claude thought")
        );

        let events = parse_kiro_update(&json!({
            "sessionUpdate":"AgentThoughtChunk",
            "content":{"text":"kiro thought"}
        }));
        assert!(
            matches!(&events[..], [ProviderEvent::Reasoning(value)] if value == "kiro thought")
        );
    }

    #[test]
    fn cursor_legacy_vocabulary_and_usage_are_preserved() {
        let mut parser = StreamParser::new(StreamKind::Cursor);
        let assistant = parser.parse(json!({
            "type":"assistant",
            "message":{
                "usage":{"inputTokens":10,"output_tokens":2},
                "content":[
                    {"type":"thinking","text":"checking"},
                    {"type":"tool_use","name":"read","id":"tool-1","input":{"path":"a"}}
                ]
            }
        }));
        assert!(matches!(&assistant[0], ProviderEvent::Reasoning(value) if value == "checking"));
        assert!(
            matches!(&assistant[1], ProviderEvent::ToolUse { name, call_id, .. } if name == "read" && call_id == "tool-1")
        );

        let tool_result = parser.parse(json!({
            "type":"tool_result","tool_name":"read","tool_id":"tool-1","output":"contents"
        }));
        assert!(
            matches!(&tool_result[0], ProviderEvent::ToolResult { name, call_id, output, .. } if name == "read" && call_id == "tool-1" && output == "contents")
        );

        assert!(
            parser
                .parse(json!({"type":"step_finish","cache_read_input_tokens":3}))
                .is_empty()
        );
        parser.parse(json!({
            "type":"result",
            "result":"done",
            "sessionId":"cursor-session",
            "input_tokens":5,
            "outputTokens":4,
            "cacheCreationInputTokens":1
        }));
        let outcome = parser.finish(Some(0), String::new());
        assert_eq!(outcome.status, "completed");
        assert_eq!(
            outcome.provider_session_id.as_deref(),
            Some("cursor-session")
        );
        let usage = outcome.usage.expect("normalized cursor usage");
        assert_eq!(usage["inputTokens"], 15);
        assert_eq!(usage["outputTokens"], 6);
        assert_eq!(usage["cacheReadTokens"], 3);
        assert_eq!(usage["cacheWriteTokens"], 1);
    }

    #[test]
    fn cursor_null_error_fields_do_not_turn_successful_tools_into_failures() {
        let detail = json!({
            "result": {
                "error": null,
                "failure": null,
                "success": {"message":"ok"}
            }
        });
        assert!(!cursor_tool_failed(&detail));
        assert_eq!(cursor_tool_output(&detail), "ok");
        assert!(cursor_tool_failed(&json!({
            "result":{"error":{"message":"denied"}}
        })));
    }

    #[test]
    fn kiro_replay_and_live_phases_are_distinct() {
        assert_ne!(AcpPhase::Replay, AcpPhase::Live);
        let events = parse_kiro_update(
            &json!({"sessionUpdate":"agent_message_chunk","content":{"text":"你"}}),
        );
        assert!(matches!(&events[0], ProviderEvent::Text(value) if value == "你"));
    }

    #[test]
    fn kiro_prompt_has_separate_idle_and_wall_budgets() {
        assert_eq!(
            AcpWaitPolicy::handshake().hard_timeout,
            Duration::from_secs(90)
        );
        assert_eq!(AcpWaitPolicy::handshake().idle_timeout, None);
        assert_eq!(
            AcpWaitPolicy::prompt(),
            AcpWaitPolicy {
                hard_timeout: Duration::from_secs(30 * 60),
                idle_timeout: Some(Duration::from_secs(90)),
            }
        );
    }

    #[test]
    fn compact_json_truncates_multibyte_payloads_on_utf8_boundaries() {
        let value = json!({"text":"😀".repeat(6_000)});
        let compact = compact_json(&value);
        assert!(compact.len() <= 20_000);
        assert!(compact.is_char_boundary(compact.len()));
        assert!(std::str::from_utf8(compact.as_bytes()).is_ok());
    }

    #[test]
    fn kiro_credit_metadata_never_becomes_dollars() {
        let mut metering = KiroMetering::default();
        metering.observe(&json!({
            "meteringUsage":[
                {"unit":"credit","value":1.25},
                {"unit":"token","value":500}
            ]
        }));
        let usage = metering
            .usage(Some(&json!({"usage":{"inputTokens":3}})))
            .expect("Kiro usage");
        assert_eq!(usage["provider"], "kiro");
        assert_eq!(usage["credits"]["unit"], "credit");
        assert_eq!(usage["credits"]["value"], 1.25);
        assert!(usage.get("costUsd").is_none());
    }

    #[test]
    fn kiro_cancel_and_unknown_request_responses_follow_json_rpc() {
        let cancel = cancel_session_notification("kiro-session");
        assert_eq!(cancel["method"], "session/cancel");
        assert_eq!(cancel["params"]["sessionId"], "kiro-session");

        let request = json!({"jsonrpc":"2.0","id":"agent-1","method":"custom/read"});
        let response = method_not_found_response(&request, "custom/read");
        assert_eq!(response["id"], "agent-1");
        assert_eq!(response["error"]["code"], -32601);
    }
}

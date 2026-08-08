use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use agent_client_protocol::schema::ProtocolVersion;
use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdout, Command};
use tokio::sync::mpsc;
use tokio::time::{sleep, timeout};
use tokio_util::sync::CancellationToken;

use crate::models::RuntimeKind;
use crate::runtime::merged_path;

const WALL_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const STDERR_LIMIT: u64 = 64 * 1024;

#[derive(Debug, Clone)]
pub enum ProviderEvent {
    SessionId(String),
    Text(String),
    ToolUse {
        name: String,
        call_id: String,
        input: Value,
    },
    ToolResult {
        name: String,
        call_id: String,
        output: String,
    },
    Status(String),
    Raw {
        kind: String,
        payload: Value,
    },
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
    events: mpsc::Sender<ProviderEvent>,
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

async fn run_stream(
    request: TurnRequest,
    cancellation: CancellationToken,
    events: mpsc::Sender<ProviderEvent>,
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
                        for event in parser.parse(value.clone()) {
                            let _ = events.send(event).await;
                        }
                        let _ = events.send(ProviderEvent::Raw { kind: value.get("type").and_then(Value::as_str).unwrap_or("unknown").to_owned(), payload: value }).await;
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
                    "command_execution" | "file_change" | "mcp_tool_call" => {
                        out.push(ProviderEvent::ToolResult {
                            name: item
                                .get("type")
                                .and_then(Value::as_str)
                                .unwrap_or("tool")
                                .to_owned(),
                            call_id: string_at(item, &["id"]).unwrap_or_default(),
                            output: compact_json(item),
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
                if let Some(id) = string_at(value, &["session_id"]) {
                    self.session_id = Some(id.clone());
                    out.push(ProviderEvent::SessionId(id));
                }
            }
            "assistant" => {
                if let Some(content) = value.pointer("/message/content").and_then(Value::as_array) {
                    for block in content {
                        if block.get("type").and_then(Value::as_str) == Some("text") {
                            if let Some(text) = string_at(block, &["text"]) {
                                self.final_output.push_str(&text);
                                out.push(ProviderEvent::Text(text));
                            }
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
            "tool_call" => {
                if let Some(inner) = value.get("tool_call").and_then(Value::as_object) {
                    let key = inner.keys().find(|key| key.ends_with("ToolCall")).cloned();
                    let name = key
                        .as_deref()
                        .unwrap_or("unknownToolCall")
                        .trim_end_matches("ToolCall")
                        .to_owned();
                    let detail = key
                        .as_ref()
                        .and_then(|key| inner.get(key))
                        .cloned()
                        .unwrap_or(Value::Null);
                    let call_id = string_at(value, &["call_id"])
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
                        });
                    }
                }
            }
            "connection" | "retry" => out.push(ProviderEvent::Status(format!(
                "{}: {}",
                event_type,
                value
                    .get("subtype")
                    .and_then(Value::as_str)
                    .unwrap_or("update")
            ))),
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
            "error" => self.failed = Some(compact_json(value)),
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

async fn run_kiro(
    request: TurnRequest,
    cancellation: CancellationToken,
    events: mpsc::Sender<ProviderEvent>,
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
    let initialize = json!({
        "jsonrpc":"2.0", "id":1, "method":"initialize",
        "params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}},"clientInfo":{"name":"TodoAgent","version":env!("CARGO_PKG_VERSION")}}
    });
    if let Err(error) = write_rpc(&mut stdin, &initialize).await {
        terminate_group(pid).await;
        return TurnOutcome::failed("acp_write_failed", error);
    }
    let init = match wait_rpc(
        &mut lines,
        &mut stdin,
        1,
        AcpPhase::Replay,
        &events,
        &cancellation,
        pid,
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
            terminate_group(pid).await;
            return TurnOutcome::failed(
                "capability_missing",
                "Kiro ACP does not advertise loadSession",
            );
        }
        let load = json!({"jsonrpc":"2.0","id":2,"method":"session/load","params":{"sessionId":existing,"cwd":request.working_directory,"mcpServers":[]}});
        if let Err(error) = write_rpc(&mut stdin, &load).await {
            terminate_group(pid).await;
            return TurnOutcome::failed("acp_write_failed", error);
        }
        match wait_rpc(
            &mut lines,
            &mut stdin,
            2,
            AcpPhase::Replay,
            &events,
            &cancellation,
            pid,
        )
        .await
        {
            Ok(_) => existing.clone(),
            Err(outcome) => return finish_kiro_child(child, stderr_task, outcome).await,
        }
    } else {
        let new_session = json!({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":request.working_directory,"mcpServers":[]}});
        if let Err(error) = write_rpc(&mut stdin, &new_session).await {
            terminate_group(pid).await;
            return TurnOutcome::failed("acp_write_failed", error);
        }
        match wait_rpc(
            &mut lines,
            &mut stdin,
            2,
            AcpPhase::Replay,
            &events,
            &cancellation,
            pid,
        )
        .await
        {
            Ok(value) => match string_at(&value, &["sessionId"]) {
                Some(id) => {
                    let _ = events.send(ProviderEvent::SessionId(id.clone())).await;
                    id
                }
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
        terminate_group(pid).await;
        return TurnOutcome::failed("acp_write_failed", error);
    }
    let prompt_result = match wait_rpc(
        &mut lines,
        &mut stdin,
        3,
        AcpPhase::Live,
        &events,
        &cancellation,
        pid,
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
    if stop == "end_turn" && exit_code == Some(0) {
        TurnOutcome {
            status: "completed",
            exit_code,
            final_output: String::new(),
            provider_session_id: Some(provider_session_id),
            error_code: None,
            error_message: None,
            usage: prompt_result.get("_meta").cloned(),
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
            usage: prompt_result.get("_meta").cloned(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AcpPhase {
    Replay,
    Live,
}

async fn wait_rpc(
    lines: &mut Lines<BufReader<ChildStdout>>,
    stdin: &mut tokio::process::ChildStdin,
    request_id: i64,
    phase: AcpPhase,
    events: &mpsc::Sender<ProviderEvent>,
    cancellation: &CancellationToken,
    pid: Option<u32>,
) -> Result<Value, TurnOutcome> {
    let budget = sleep(Duration::from_secs(90));
    tokio::pin!(budget);
    loop {
        tokio::select! {
            _ = cancellation.cancelled() => {
                let cancel = json!({"jsonrpc":"2.0","method":"session/cancel","params":{}});
                let _ = write_rpc(stdin, &cancel).await;
                terminate_group(pid).await;
                return Err(TurnOutcome::cancelled());
            }
            _ = &mut budget => {
                terminate_group(pid).await;
                return Err(TurnOutcome::failed("timed_out", "ACP request timed out after 90 seconds"));
            }
            line = lines.next_line() => {
                let line = match line {
                    Ok(Some(line)) => line,
                    Ok(None) => return Err(TurnOutcome::failed("process_failed", "Kiro exited before replying")),
                    Err(error) => return Err(TurnOutcome::failed("stream_failed", error.to_string())),
                };
                let Ok(value) = serde_json::from_str::<Value>(&line) else { continue; };
                if value.get("id").and_then(Value::as_i64) == Some(request_id) && value.get("method").is_none() {
                    if let Some(error) = value.get("error") {
                        return Err(TurnOutcome::failed(classify_error(&compact_json(error)), compact_json(error)));
                    }
                    return Ok(value.get("result").cloned().unwrap_or(Value::Null));
                }
                if value.get("id").and_then(Value::as_i64).is_some() && value.get("method").and_then(Value::as_str) == Some("session/request_permission") {
                    answer_permission(stdin, &value).await;
                    continue;
                }
                let method = value.get("method").and_then(Value::as_str).unwrap_or("");
                if phase == AcpPhase::Live && matches!(method, "session/update" | "session/notification") {
                    for event in parse_kiro_update(value.pointer("/params/update").unwrap_or(&Value::Null)) {
                        let _ = events.send(event).await;
                    }
                }
                let _ = events.send(ProviderEvent::Raw { kind: method.to_owned(), payload: value }).await;
            }
        }
    }
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
        "agent_thought_chunk" | "AgentThoughtChunk" => Vec::new(),
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
            }]
        }
        _ => Vec::new(),
    }
}

async fn answer_permission(stdin: &mut tokio::process::ChildStdin, request: &Value) {
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

async fn write_rpc(stdin: &mut tokio::process::ChildStdin, value: &Value) -> Result<(), String> {
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
    terminate_group(child.id()).await;
    outcome.exit_code = child.wait().await.ok().and_then(|status| status.code());
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
    let mut value = value.to_string();
    value.truncate(20_000);
    value
}

fn cursor_tool_output(detail: &Value) -> String {
    let result = detail.get("result").unwrap_or(&Value::Null);
    if let Some(error) = result.get("error").or_else(|| result.get("failure")) {
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
        let value = json!({"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"a"},"result":{"success":{"message":"Wrote a"}}}}});
        let events = parser.parse(value);
        assert!(
            matches!(&events[0], ProviderEvent::ToolResult { name, output, .. } if name == "edit" && output == "Wrote a")
        );
    }

    #[test]
    fn kiro_replay_and_live_phases_are_distinct() {
        assert_ne!(AcpPhase::Replay, AcpPhase::Live);
        let events = parse_kiro_update(
            &json!({"sessionUpdate":"agent_message_chunk","content":{"text":"你"}}),
        );
        assert!(matches!(&events[0], ProviderEvent::Text(value) if value == "你"));
    }
}

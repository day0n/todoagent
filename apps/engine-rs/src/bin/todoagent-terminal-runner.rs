use std::collections::BTreeMap;
use std::env;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixDatagram;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, ExitStatus};
use std::sync::atomic::{AtomicU8, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use nix::libc;
use nix::sys::signal::{self, SaFlags, SigAction, SigHandler, SigSet, Signal, killpg};
use nix::unistd::{Pid, getpgrp, getuid, isatty, tcsetpgrp};
use serde::{Deserialize, Serialize};

const EXEC_ERROR: u8 = 126;
const TERM_GRACE: Duration = Duration::from_secs(2);
const POLL_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Descriptor {
    version: u32,
    session_id: String,
    run_id: String,
    executable: PathBuf,
    arguments: Vec<String>,
    working_directory: PathBuf,
    working_directory_device: u64,
    working_directory_inode: u64,
    environment: BTreeMap<String, String>,
    status_socket: PathBuf,
    lifecycle_token: String,
    hook_token: String,
    host_pid: u32,
    cleanup_paths: Vec<PathBuf>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RunnerEvent<'a> {
    token: &'a str,
    session_id: &'a str,
    run_id: &'a str,
    event: &'a str,
    pid: Option<u32>,
    pgid: Option<i32>,
    exit_code: Option<i32>,
    signal: Option<i32>,
}

fn main() -> ExitCode {
    if env::args().nth(1).as_deref() == Some("hook-event") {
        hook_event(env::args().nth(2));
        return ExitCode::SUCCESS;
    }
    match run(env::args().skip(1)) {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("todoagent-terminal-runner: {error}");
            ExitCode::from(EXEC_ERROR)
        }
    }
}

fn hook_event(status_override: Option<String>) {
    let _ = try_hook_event(status_override.as_deref());
}

fn try_hook_event(status_override: Option<&str>) -> Result<(), String> {
    let socket_path = PathBuf::from(required_hook_env("TODOAGENT_STATUS_SOCKET")?);
    let token = required_hook_env("TODOAGENT_HOOK_TOKEN")?;
    let session_id = required_hook_env("TODOAGENT_SESSION_ID")?;
    let run_id = required_hook_env("TODOAGENT_RUN_ID")?;
    let socket = connect_status_socket(&socket_path)?;
    let mut input = Vec::new();
    io::stdin()
        .take(64 * 1024 + 1)
        .read_to_end(&mut input)
        .map_err(|error| error.to_string())?;
    if input.len() > 64 * 1024 {
        return Ok(());
    }
    let value: serde_json::Value = serde_json::from_slice(&input).unwrap_or_default();
    let runtime = env::var("TODOAGENT_RUNTIME").unwrap_or_default();
    let Some(event) = hook_attention_status(&value, status_override, &runtime) else {
        return Ok(());
    };
    let provider_session_id = [
        "session_id",
        "sessionId",
        "conversation_id",
        "conversationId",
    ]
    .into_iter()
    .find_map(|key| value.get(key).and_then(serde_json::Value::as_str));
    if let Some(provider_session_id) = provider_session_id {
        send_hook_payload(
            &socket,
            &serde_json::json!({
                "token": token,
                "sessionId": session_id,
                "runId": run_id,
                "event": "provider_bound",
                "providerSessionId": provider_session_id,
                "source": "session_start_hook",
            }),
        )?;
    }
    send_hook_payload(
        &socket,
        &serde_json::json!({
            "token": token,
            "eventId": stable_hook_event_id(&run_id, &event, &input),
            "sessionId": session_id,
            "runId": run_id,
            "event": "status",
            "status": event,
        }),
    )?;
    Ok(())
}

fn stable_hook_event_id(run_id: &str, status: &str, input: &[u8]) -> String {
    // Provider hooks do not all expose a callback ID. Derive a stable 128-bit
    // receipt from the run, classified status and exact bounded stdin so a
    // provider retry receives the same idempotency key without another crate.
    // This is not a security primitive; the authenticated socket token is.
    fn mix(mut hash: u64, bytes: &[u8]) -> u64 {
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100_0000_01b3);
        }
        hash
    }
    let mut high = mix(0xcbf2_9ce4_8422_2325, run_id.as_bytes());
    high = mix(high, status.as_bytes());
    high = mix(high, input);
    let mut low = mix(0x8422_2325_cbf2_9ce4, input);
    low = mix(low, status.as_bytes());
    low = mix(low, run_id.as_bytes());
    let mut bytes = [0_u8; 16];
    bytes[..8].copy_from_slice(&high.to_be_bytes());
    bytes[8..].copy_from_slice(&low.to_be_bytes());
    // Mark the deterministic value as an RFC 4122 variant/version-5-shaped
    // UUID so the existing canonical UUID validation can be reused.
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    uuid::Uuid::from_bytes(bytes).to_string()
}

fn hook_attention_status(
    value: &serde_json::Value,
    status_override: Option<&str>,
    runtime: &str,
) -> Option<String> {
    match status_override.filter(|value| !value.is_empty()) {
        Some(value @ ("active" | "blocked" | "completed")) => Some(value.to_owned()),
        Some(_) => None,
        None => {
            let runtime = runtime.to_ascii_lowercase();
            let raw_event = value
                .get("event")
                .or_else(|| value.get("hook_event_name"))
                .or_else(|| value.get("type"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or("active")
                .to_ascii_lowercase();
            Some(
                // Only Claude exposes a reliable permission-prompt hook in
                // the supported capability matrix. Codex PermissionRequest
                // runs before guardian/user UI and therefore remains active;
                // Cursor and Kiro never infer blocked from visible text.
                if runtime == "claude"
                    && (raw_event.contains("permission") || raw_event.contains("blocked"))
                {
                    "blocked"
                } else if raw_event.contains("stop")
                    || raw_event.contains("complete")
                    || raw_event.contains("end")
                {
                    "completed"
                } else {
                    "active"
                }
                .to_owned(),
            )
        }
    }
}

fn send_hook_payload(socket: &UnixDatagram, payload: &serde_json::Value) -> Result<(), String> {
    let payload = serde_json::to_vec(payload).map_err(|error| error.to_string())?;
    socket.send(&payload).map_err(|error| error.to_string())?;
    Ok(())
}

fn required_hook_env(key: &str) -> Result<String, String> {
    env::var(key).map_err(|_| format!("{key} missing"))
}

fn run(arguments: impl IntoIterator<Item = String>) -> Result<u8, String> {
    let descriptor_path = parse(arguments)?;
    let descriptor = load_descriptor(&descriptor_path)?;
    validate_descriptor(&descriptor_path, &descriptor)?;
    let working_directory = open_verified_working_directory(
        &descriptor.working_directory,
        descriptor.working_directory_device,
        descriptor.working_directory_inode,
    )?;
    let _cleanup = CleanupFiles {
        descriptor: descriptor_path.clone(),
        auxiliary: descriptor.cleanup_paths.clone(),
    };
    let socket = connect_status_socket(&descriptor.status_socket)?;
    let termination_requested = install_signal_handlers()?;
    // The descriptor is only a secure handoff from Engine to runner. Unlink
    // it before the untrusted Agent exists so the lifecycle credential remains
    // solely in runner memory for the rest of the run.
    fs::remove_file(&descriptor_path)
        .map_err(|error| format!("cannot consume descriptor: {error}"))?;

    let mut command = Command::new(&descriptor.executable);
    command
        .args(&descriptor.arguments)
        .envs(&descriptor.environment);
    sanitize_environment(&mut command);
    let working_directory_fd = working_directory.as_raw_fd();
    unsafe {
        command.pre_exec(move || {
            if libc::fchdir(working_directory_fd) == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::setpgid(0, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            libc::signal(libc::SIGTTOU, libc::SIG_DFL);
            Ok(())
        });
    }
    let mut child = command.spawn().map_err(|error| {
        format!(
            "failed to spawn {}: {error}",
            descriptor.executable.display()
        )
    })?;
    // The child already changed directory through this descriptor-verified FD
    // and O_CLOEXEC closed its copy. The runner no longer needs to pin it.
    drop(working_directory);
    let pid = child.id();
    let pgid = i32::try_from(pid).map_err(|_| "child PID is out of range".to_owned())?;
    if let Err(error) = foreground_child_process_group(pgid) {
        let _ = killpg(Pid::from_raw(pgid), Signal::SIGKILL);
        let _ = child.wait();
        return Err(error);
    }
    send_event(
        &socket,
        &descriptor,
        "started",
        Some(pid),
        Some(pgid),
        None,
        None,
    );

    let mut termination_started = None;
    let status = loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("failed to wait for child: {error}"))?
        {
            break status;
        }
        let requested_signal = termination_requested.swap(NO_SIGNAL, Ordering::Relaxed);
        if requested_signal == INTERRUPT_SIGNAL {
            let _ = killpg(Pid::from_raw(pgid), Signal::SIGINT);
        }
        if requested_signal == TERMINATE_SIGNAL || !host_is_alive(descriptor.host_pid) {
            if termination_started.is_none() {
                let _ = killpg(Pid::from_raw(pgid), Signal::SIGTERM);
                termination_started = Some(Instant::now());
            } else if termination_started.is_some_and(|started| started.elapsed() >= TERM_GRACE) {
                let _ = killpg(Pid::from_raw(pgid), Signal::SIGKILL);
            }
        }
        thread::sleep(POLL_INTERVAL);
    };
    restore_runner_process_group();
    let (exit_code, signal) = exit_details(status);
    send_event(
        &socket,
        &descriptor,
        "exited",
        Some(pid),
        Some(pgid),
        exit_code,
        signal,
    );
    Ok(exit_code
        .and_then(|code| u8::try_from(code).ok())
        .unwrap_or(1))
}

struct CleanupFiles {
    descriptor: PathBuf,
    auxiliary: Vec<PathBuf>,
}

impl Drop for CleanupFiles {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.descriptor);
        for path in &self.auxiliary {
            let _ = fs::remove_file(path);
        }
    }
}

fn parse(arguments: impl IntoIterator<Item = String>) -> Result<PathBuf, String> {
    let mut arguments = arguments.into_iter();
    if arguments.next().as_deref() != Some("--descriptor") {
        return Err("usage: todoagent-terminal-runner --descriptor ABSOLUTE_PATH".to_owned());
    }
    let path = PathBuf::from(
        arguments
            .next()
            .ok_or_else(|| "--descriptor requires a path".to_owned())?,
    );
    if arguments.next().is_some() {
        return Err("unexpected runner argument".to_owned());
    }
    Ok(path)
}

fn load_descriptor(path: &Path) -> Result<Descriptor, String> {
    if !path.is_absolute() {
        return Err("descriptor path must be absolute".to_owned());
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| format!("cannot open descriptor: {error}"))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("cannot inspect descriptor: {error}"))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err("descriptor must be a regular non-symlink file".to_owned());
    }
    if metadata.uid() != getuid().as_raw() || metadata.permissions().mode() & 0o077 != 0 {
        return Err("descriptor must be owned by the current user and mode 0600".to_owned());
    }
    serde_json::from_reader(file).map_err(|error| format!("invalid descriptor: {error}"))
}

const NO_SIGNAL: u8 = 0;
const INTERRUPT_SIGNAL: u8 = 1;
const TERMINATE_SIGNAL: u8 = 2;
static REQUESTED_SIGNAL: AtomicU8 = AtomicU8::new(NO_SIGNAL);

extern "C" fn request_signal(signal: libc::c_int) {
    if signal == libc::SIGINT {
        let _ = REQUESTED_SIGNAL.compare_exchange(
            NO_SIGNAL,
            INTERRUPT_SIGNAL,
            Ordering::Relaxed,
            Ordering::Relaxed,
        );
    } else {
        REQUESTED_SIGNAL.store(TERMINATE_SIGNAL, Ordering::Relaxed);
    }
}

fn install_signal_handlers() -> Result<&'static AtomicU8, String> {
    REQUESTED_SIGNAL.store(NO_SIGNAL, Ordering::Relaxed);
    let action = SigAction::new(
        SigHandler::Handler(request_signal),
        SaFlags::SA_RESTART,
        SigSet::empty(),
    );
    for signal in [Signal::SIGTERM, Signal::SIGINT, Signal::SIGHUP] {
        unsafe { signal::sigaction(signal, &action) }
            .map_err(|error| format!("cannot install signal handler: {error}"))?;
    }
    unsafe {
        signal::signal(Signal::SIGTTOU, SigHandler::SigIgn)
            .map_err(|error| format!("cannot ignore SIGTTOU: {error}"))?;
    }
    Ok(&REQUESTED_SIGNAL)
}

fn foreground_child_process_group(pgid: i32) -> Result<(), String> {
    let stdin = io::stdin();
    if isatty(&stdin).unwrap_or(false) {
        tcsetpgrp(&stdin, Pid::from_raw(pgid))
            .map_err(|error| format!("cannot foreground child process group: {error}"))?;
    }
    Ok(())
}

fn restore_runner_process_group() {
    let stdin = io::stdin();
    if isatty(&stdin).unwrap_or(false) {
        let _ = tcsetpgrp(&stdin, getpgrp());
    }
}

fn validate_descriptor(path: &Path, descriptor: &Descriptor) -> Result<(), String> {
    if descriptor.version != 3 {
        return Err("unsupported descriptor version".to_owned());
    }
    for (label, value) in [
        ("sessionId", descriptor.session_id.as_str()),
        ("runId", descriptor.run_id.as_str()),
    ] {
        uuid::Uuid::parse_str(value).map_err(|_| format!("{label} must be a UUID"))?;
    }
    for (name, token) in [
        ("lifecycleToken", descriptor.lifecycle_token.as_str()),
        ("hookToken", descriptor.hook_token.as_str()),
    ] {
        if token.is_empty() || token.len() > 512 {
            return Err(format!("{name} is invalid"));
        }
    }
    if descriptor.lifecycle_token == descriptor.hook_token {
        return Err("status tokens must be distinct".to_owned());
    }
    validate_regular_executable(&descriptor.executable)?;
    if !descriptor.working_directory.is_absolute() {
        return Err("workingDirectory must be absolute".to_owned());
    }
    if !descriptor.status_socket.is_absolute() {
        return Err("statusSocket must be absolute".to_owned());
    }
    if descriptor.host_pid == 0 {
        return Err("hostPid is invalid".to_owned());
    }
    if path.parent().is_none() {
        return Err("descriptor has no parent directory".to_owned());
    }
    let cleanup_parent = descriptor
        .status_socket
        .parent()
        .ok_or_else(|| "statusSocket has no parent".to_owned())?;
    for cleanup_path in &descriptor.cleanup_paths {
        if !cleanup_path.is_absolute() || cleanup_path.parent() != Some(cleanup_parent) {
            return Err("cleanupPath must be inside the status socket directory".to_owned());
        }
        let metadata = fs::symlink_metadata(cleanup_path)
            .map_err(|error| format!("cannot inspect cleanupPath: {error}"))?;
        if metadata.file_type().is_symlink()
            || !metadata.is_file()
            || metadata.uid() != getuid().as_raw()
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err("cleanupPath must be a current-user mode 0600 file".to_owned());
        }
    }
    Ok(())
}

fn open_verified_working_directory(
    path: &Path,
    expected_device: u64,
    expected_inode: u64,
) -> Result<OwnedFd, String> {
    if !path.is_absolute() {
        return Err("workingDirectory must be absolute".to_owned());
    }

    let root = CString::new("/").expect("root path has no NUL");
    let root_fd = unsafe {
        libc::open(
            root.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if root_fd == -1 {
        return Err(format!(
            "cannot open workingDirectory root: {}",
            io::Error::last_os_error()
        ));
    }
    let mut current = unsafe { OwnedFd::from_raw_fd(root_fd) };

    for component in path.components() {
        let std::path::Component::Normal(name) = component else {
            if matches!(
                component,
                std::path::Component::RootDir | std::path::Component::CurDir
            ) {
                continue;
            }
            return Err("workingDirectory contains an invalid component".to_owned());
        };
        let name = CString::new(name.as_bytes())
            .map_err(|_| "workingDirectory contains NUL".to_owned())?;
        let next_fd = unsafe {
            libc::openat(
                current.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if next_fd == -1 {
            return Err(format!(
                "cannot open workingDirectory without symlinks: {}",
                io::Error::last_os_error()
            ));
        }
        current = unsafe { OwnedFd::from_raw_fd(next_fd) };
    }

    let directory = fs::File::from(current);
    let metadata = directory
        .metadata()
        .map_err(|error| format!("cannot inspect workingDirectory: {error}"))?;
    if metadata.dev() != expected_device || metadata.ino() != expected_inode {
        return Err("workingDirectory changed after launch preparation".to_owned());
    }
    Ok(directory.into())
}

fn validate_regular_executable(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("executable must be absolute".to_owned());
    }
    let metadata =
        fs::metadata(path).map_err(|error| format!("cannot stat executable: {error}"))?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err("executable must be a regular executable file".to_owned());
    }
    Ok(())
}

fn connect_status_socket(path: &Path) -> Result<UnixDatagram, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("cannot stat status socket: {error}"))?;
    if !metadata.file_type().is_socket()
        || metadata.uid() != getuid().as_raw()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err("status socket must be a current-user Unix socket with mode 0600".to_owned());
    }
    let socket = UnixDatagram::unbound().map_err(|error| format!("socket failed: {error}"))?;
    socket
        .connect(path)
        .map_err(|error| format!("cannot connect status socket: {error}"))?;
    Ok(socket)
}

fn sanitize_environment(command: &mut Command) {
    for (key, _) in env::vars_os() {
        let key = key.to_string_lossy();
        if key.starts_with("DYLD_") || key.starts_with("GHOSTTY_") || key.starts_with("AGTERM_") {
            command.env_remove(key.as_ref());
        }
    }
}

fn send_event(
    socket: &UnixDatagram,
    descriptor: &Descriptor,
    event: &str,
    pid: Option<u32>,
    pgid: Option<i32>,
    exit_code: Option<i32>,
    signal: Option<i32>,
) {
    let payload = RunnerEvent {
        token: &descriptor.lifecycle_token,
        session_id: &descriptor.session_id,
        run_id: &descriptor.run_id,
        event,
        pid,
        pgid,
        exit_code,
        signal,
    };
    if let Ok(payload) = serde_json::to_vec(&payload) {
        let _ = socket.send(&payload);
    }
}

fn host_is_alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    match nix::sys::signal::kill(Pid::from_raw(pid), None) {
        Ok(()) => true,
        Err(nix::errno::Errno::EPERM) => true,
        Err(_) => false,
    }
}

#[cfg(unix)]
fn exit_details(status: ExitStatus) -> (Option<i32>, Option<i32>) {
    use std::os::unix::process::ExitStatusExt;
    (status.code(), status.signal())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixDatagram;

    #[test]
    fn only_accepts_one_descriptor_argument() {
        assert!(parse(Vec::<String>::new()).is_err());
        assert_eq!(
            parse(
                ["--descriptor", "/tmp/run.json"]
                    .into_iter()
                    .map(str::to_owned)
            )
            .unwrap(),
            PathBuf::from("/tmp/run.json")
        );
        assert!(
            parse(
                ["--descriptor", "/tmp/a", "extra"]
                    .into_iter()
                    .map(str::to_owned)
            )
            .is_err()
        );
    }

    #[test]
    fn executable_requires_absolute_regular_file_and_execute_permission() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("agent");
        fs::write(&file, b"#!/bin/sh\n").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(validate_regular_executable(&file).is_err());
        fs::set_permissions(&file, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(validate_regular_executable(&file).is_ok());
        assert!(validate_regular_executable(Path::new("agent")).is_err());
    }

    #[test]
    fn working_directory_fd_requires_the_prepared_directory_identity() {
        let directory = tempfile::tempdir().unwrap();
        let directory_path = fs::canonicalize(directory.path()).unwrap();
        let project = directory_path.join("project");
        fs::create_dir(&project).unwrap();
        let metadata = fs::metadata(&project).unwrap();

        assert!(open_verified_working_directory(&project, metadata.dev(), metadata.ino()).is_ok());
        assert!(
            open_verified_working_directory(&project, metadata.dev(), metadata.ino() + 1).is_err(),
            "a directory replacement must not inherit the prepared launch"
        );
    }

    #[test]
    fn working_directory_fd_rejects_final_and_parent_symlinks() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let directory_path = fs::canonicalize(directory.path()).unwrap();
        let parent = directory_path.join("real-parent");
        let project = parent.join("project");
        fs::create_dir_all(&project).unwrap();
        let metadata = fs::metadata(&project).unwrap();

        let final_link = parent.join("project-link");
        symlink(&project, &final_link).unwrap();
        assert!(
            open_verified_working_directory(&final_link, metadata.dev(), metadata.ino()).is_err()
        );

        let parent_link = directory_path.join("parent-link");
        symlink(&parent, &parent_link).unwrap();
        assert!(
            open_verified_working_directory(
                &parent_link.join("project"),
                metadata.dev(),
                metadata.ino()
            )
            .is_err()
        );
    }

    #[test]
    fn working_directory_fd_rejects_a_real_directory_replacement() {
        let directory = tempfile::tempdir().unwrap();
        let directory_path = fs::canonicalize(directory.path()).unwrap();
        let project = directory_path.join("project");
        fs::create_dir(&project).unwrap();
        let original = fs::metadata(&project).unwrap();
        fs::rename(&project, directory_path.join("moved-project")).unwrap();
        fs::create_dir(&project).unwrap();

        assert!(open_verified_working_directory(&project, original.dev(), original.ino()).is_err());
    }

    #[test]
    fn detects_current_and_missing_host_processes() {
        assert!(host_is_alive(std::process::id()));
        assert!(!host_is_alive(u32::MAX));
    }

    #[test]
    fn hook_event_is_silent_and_emits_authenticated_status() {
        let (sender, receiver) = UnixDatagram::pair().unwrap();
        let payload = serde_json::json!({
            "token":"token",
            "sessionId":"session",
            "runId":"run",
            "event":"status",
            "status":"blocked"
        });
        send_hook_payload(&sender, &payload).unwrap();
        let mut buffer = [0_u8; 1024];
        let size = receiver.recv(&mut buffer).unwrap();
        let decoded: serde_json::Value = serde_json::from_slice(&buffer[..size]).unwrap();
        assert_eq!(decoded["token"], "token");
        assert_eq!(decoded["event"], "status");
        assert_eq!(decoded["status"], "blocked");
    }

    #[test]
    fn hook_status_override_is_explicit_and_fail_closed() {
        let payload = serde_json::json!({"event":"UserPromptSubmit"});
        assert_eq!(
            hook_attention_status(&payload, None, "codex").as_deref(),
            Some("active")
        );
        assert_eq!(
            hook_attention_status(&payload, Some("completed"), "codex").as_deref(),
            Some("completed")
        );
        assert_eq!(
            hook_attention_status(&payload, Some("running"), "codex"),
            None
        );
    }

    #[test]
    fn permission_status_is_blocked_only_for_claude() {
        let payload = serde_json::json!({"hook_event_name":"PermissionRequest"});
        assert_eq!(
            hook_attention_status(&payload, None, "claude").as_deref(),
            Some("blocked")
        );
        assert_eq!(
            hook_attention_status(&payload, None, "codex").as_deref(),
            Some("active")
        );
    }

    #[test]
    fn identical_provider_callbacks_have_a_stable_event_id() {
        let run_id = uuid::Uuid::new_v4().to_string();
        let payload = br#"{"event":"Stop","session_id":"provider"}"#;
        let first = stable_hook_event_id(&run_id, "completed", payload);
        let duplicate = stable_hook_event_id(&run_id, "completed", payload);
        let different = stable_hook_event_id(&run_id, "active", payload);

        assert_eq!(first, duplicate);
        assert_ne!(first, different);
        assert!(uuid::Uuid::parse_str(&first).is_ok());
    }
}

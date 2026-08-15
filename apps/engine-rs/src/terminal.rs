use std::collections::BTreeMap;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use crate::models::{
    RuntimeKind, TerminalLaunchPlan, TerminalResumeCandidate, TerminalRun, TerminalSession,
};

pub const RUNNER_BINARY_NAME: &str = "todoagent-terminal-runner";
const MAX_CANDIDATE_FILES: usize = 10_000;
const MAX_CANDIDATE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_CANDIDATE_TOTAL_BYTES: u64 = 64 * 1024 * 1024;
const MAX_RESUME_CANDIDATES: usize = 256;
const CANDIDATE_SCAN_BUDGET: Duration = Duration::from_secs(2);
const MAX_CLAUDE_PROJECT_DIRECTORIES: usize = 10_000;
const MAX_CLAUDE_TRANSCRIPT_BYTES: u64 = 2 * 1024 * 1024;
const CLAUDE_TRANSCRIPT_SCAN_BUDGET: Duration = Duration::from_secs(2);
const MAX_PRIVATE_LAUNCH_ARTIFACT_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClaudeResumeState {
    Absent,
    Resumable,
    Unusable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct WorkingDirectoryIdentity {
    device: u64,
    inode: u64,
}

/// Revalidates a Session's permanently bound working directory immediately
/// before a launch is prepared. A directory can disappear after the Session
/// was created; allowing that stale value into the descriptor only makes the
/// terminal flash open before the runner rejects it.
pub fn validate_launch_working_directory(working_directory: &str) -> std::io::Result<()> {
    launch_working_directory_identity(working_directory).map(|_| ())
}

fn launch_working_directory_identity(
    working_directory: &str,
) -> std::io::Result<WorkingDirectoryIdentity> {
    let directory = open_working_directory_without_symlinks(Path::new(working_directory))?;
    let metadata = fs::File::from(directory).metadata()?;
    Ok(WorkingDirectoryIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

fn open_working_directory_without_symlinks(path: &Path) -> std::io::Result<OwnedFd> {
    if !path.is_absolute() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "terminal working directory must be absolute",
        ));
    }

    let root = CString::new("/").expect("root path has no NUL");
    let root_fd = unsafe {
        nix::libc::open(
            root.as_ptr(),
            nix::libc::O_RDONLY
                | nix::libc::O_DIRECTORY
                | nix::libc::O_NOFOLLOW
                | nix::libc::O_CLOEXEC,
        )
    };
    if root_fd == -1 {
        return Err(std::io::Error::last_os_error());
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
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "terminal working directory contains an invalid component",
            ));
        };
        let name = CString::new(name.as_bytes()).map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "terminal working directory contains NUL",
            )
        })?;
        let next_fd = unsafe {
            nix::libc::openat(
                current.as_raw_fd(),
                name.as_ptr(),
                nix::libc::O_RDONLY
                    | nix::libc::O_DIRECTORY
                    | nix::libc::O_NOFOLLOW
                    | nix::libc::O_CLOEXEC,
            )
        };
        if next_fd == -1 {
            return Err(std::io::Error::last_os_error());
        }
        current = unsafe { OwnedFd::from_raw_fd(next_fd) };
    }
    Ok(current)
}

/// Determines whether Claude has materialized a provider conversation for a
/// preallocated TodoAgent session ID. Claude does not create a transcript just
/// by starting its TUI, so process history alone is not sufficient evidence
/// that `--resume` will work.
pub fn claude_resume_state(
    provider_session_id: &str,
    working_directory: &Path,
) -> std::io::Result<ClaudeResumeState> {
    let Some(config_directory) = claude_config_directory(working_directory) else {
        return Ok(ClaudeResumeState::Absent);
    };
    claude_resume_state_in(&config_directory, provider_session_id)
}

fn claude_config_directory(working_directory: &Path) -> Option<PathBuf> {
    match std::env::var_os("CLAUDE_CONFIG_DIR") {
        Some(value) if !value.is_empty() => {
            let value = PathBuf::from(value);
            if value.is_absolute() {
                Some(value)
            } else {
                Some(working_directory.join(value))
            }
        }
        _ => dirs::home_dir().map(|home| home.join(".claude")),
    }
}

fn claude_resume_state_in(
    config_directory: &Path,
    provider_session_id: &str,
) -> std::io::Result<ClaudeResumeState> {
    let provider_session_id = uuid::Uuid::parse_str(provider_session_id).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Claude provider session ID is not a UUID",
        )
    })?;
    let projects_directory = config_directory.join("projects");
    let projects_metadata = match fs::symlink_metadata(&projects_directory) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(ClaudeResumeState::Absent);
        }
        Err(error) => return Err(error),
    };
    if !projects_metadata.file_type().is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Claude projects directory is not a regular directory",
        ));
    }

    let deadline = Instant::now() + CLAUDE_TRANSCRIPT_SCAN_BUDGET;
    let transcript_name = format!("{provider_session_id}.jsonl");
    let mut found_transcript = false;
    for (index, entry) in fs::read_dir(&projects_directory)?.enumerate() {
        if index >= MAX_CLAUDE_PROJECT_DIRECTORIES || Instant::now() >= deadline {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Claude transcript scan exceeded its safety budget",
            ));
        }
        let entry = entry?;
        let project_metadata = fs::symlink_metadata(entry.path())?;
        if project_metadata.file_type().is_symlink() {
            continue;
        }
        if !project_metadata.is_dir() {
            continue;
        }

        let transcript_path = entry.path().join(&transcript_name);
        let transcript_metadata = match fs::symlink_metadata(&transcript_path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        found_transcript = true;
        if !transcript_metadata.file_type().is_file() {
            continue;
        }
        let transcript = OpenOptions::new()
            .read(true)
            .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
            .open(&transcript_path)?;
        let mut reader = BufReader::new(transcript);
        let mut scanned_bytes = 0_u64;
        let mut line = String::new();
        while scanned_bytes < MAX_CLAUDE_TRANSCRIPT_BYTES {
            let remaining = MAX_CLAUDE_TRANSCRIPT_BYTES - scanned_bytes;
            let bytes_read = reader.by_ref().take(remaining).read_line(&mut line)?;
            if bytes_read == 0 {
                break;
            }
            scanned_bytes = scanned_bytes.saturating_add(bytes_read as u64);
            if Instant::now() >= deadline {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "Claude transcript scan exceeded its safety budget",
                ));
            }
            if let Ok(record) = serde_json::from_str::<serde_json::Value>(&line) {
                let is_conversation_record = matches!(
                    record.get("type").and_then(serde_json::Value::as_str),
                    Some("user" | "assistant")
                );
                let is_sidechain = record
                    .get("isSidechain")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                if is_conversation_record && !is_sidechain {
                    return Ok(ClaudeResumeState::Resumable);
                }
            }
            line.clear();
        }
    }
    Ok(if found_transcript {
        ClaudeResumeState::Unusable
    } else {
        ClaudeResumeState::Absent
    })
}

pub fn cleanup_stale_descriptors(directory: &Path) -> std::io::Result<()> {
    let Some(_) = secure_descriptor_directory(directory, false)? else {
        return Ok(());
    };
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let metadata = match fs::symlink_metadata(entry.path()) {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        if owned_uuid_json(&entry.path(), &metadata) {
            let _ = fs::remove_file(entry.path());
        }
    }
    Ok(())
}

fn secure_descriptor_directory(
    directory: &Path,
    create: bool,
) -> std::io::Result<Option<fs::File>> {
    if create {
        match fs::create_dir(directory) {
            Ok(()) => fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_DIRECTORY | nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(directory)
    {
        Ok(file) => file,
        Err(error) if !create && error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let metadata = file.metadata()?;
    let uid = unsafe { nix::libc::geteuid() };
    if !metadata.is_dir() || metadata.uid() != uid || metadata.permissions().mode() & 0o077 != 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "TerminalRuns must be a current-user mode 0700 directory",
        ));
    }
    Ok(Some(file))
}

fn owned_uuid_json(path: &Path, metadata: &fs::Metadata) -> bool {
    let uid = unsafe { nix::libc::geteuid() };
    metadata.file_type().is_file()
        && metadata.uid() == uid
        && metadata.permissions().mode() & 0o077 == 0
        && path
            .file_stem()
            .and_then(|value| value.to_str())
            .is_some_and(|value| uuid::Uuid::parse_str(value).is_ok())
        && path.extension().and_then(|value| value.to_str()) == Some("json")
}

pub fn cleanup_run_artifacts(directory: &Path, run_id: &str) {
    if uuid::Uuid::parse_str(run_id).is_err() {
        return;
    }
    let descriptor_path = directory.join(format!("{run_id}.json"));
    if let Ok(content) = fs::read_to_string(&descriptor_path)
        && content.len() <= 64 * 1024
        && let Ok(value) = serde_json::from_str::<serde_json::Value>(&content)
        && let Some(paths) = value
            .get("cleanupPaths")
            .and_then(serde_json::Value::as_array)
    {
        for path in paths.iter().filter_map(serde_json::Value::as_str) {
            let path = Path::new(path);
            let trusted_parent = path.parent().is_some_and(|parent| {
                parent.parent() == Some(Path::new("/tmp"))
                    && parent
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.starts_with("todoagent-"))
            });
            if trusted_parent {
                let _ = fs::remove_file(path);
            }
        }
    }
    let _ = fs::remove_file(descriptor_path);
}

pub fn resume_candidates(
    session: &TerminalSession,
) -> std::io::Result<Vec<TerminalResumeCandidate>> {
    let Some(home) = dirs::home_dir() else {
        return Ok(Vec::new());
    };
    let (root, source) = match session.runtime_kind {
        RuntimeKind::Codex => (home.join(".codex/sessions"), "codex_session_store"),
        RuntimeKind::Kiro => (home.join(".kiro/sessions/cli"), "kiro_session_store"),
        RuntimeKind::Claude | RuntimeKind::Cursor => return Ok(Vec::new()),
    };
    let mut candidates = Vec::new();
    let mut remaining_files = MAX_CANDIDATE_FILES;
    let mut remaining_bytes = MAX_CANDIDATE_TOTAL_BYTES;
    let deadline = Instant::now() + CANDIDATE_SCAN_BUDGET;
    let canonical_working_directory = fs::canonicalize(&session.working_directory)
        .unwrap_or_else(|_| session.working_directory.clone().into());
    collect_candidate_files(
        &root,
        source,
        &canonical_working_directory,
        &mut candidates,
        &mut remaining_files,
        &mut remaining_bytes,
        deadline,
        0,
    )?;
    filter_candidates_to_run_window(&mut candidates, session);
    candidates.sort_by(|left, right| right.created_at.cmp(&left.created_at));
    candidates.dedup_by(|left, right| left.provider_session_id == right.provider_session_id);
    Ok(candidates)
}

fn filter_candidates_to_run_window(
    candidates: &mut Vec<TerminalResumeCandidate>,
    session: &TerminalSession,
) {
    let started_at = session
        .last_started_at
        .as_deref()
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok());
    let exited_at = session
        .last_exited_at
        .as_deref()
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok());
    match (started_at, exited_at, session.has_active_run) {
        (Some(started_at), Some(exited_at), _) if exited_at >= started_at => {
            let tolerance = chrono::Duration::minutes(5);
            let earliest = started_at - tolerance;
            let latest = exited_at + tolerance;
            candidates.retain(|candidate| {
                candidate
                    .created_at
                    .as_deref()
                    .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
                    .is_some_and(|created_at| created_at >= earliest && created_at <= latest)
            });
        }
        // Kiro writes its provider identity after the TUI has started. A
        // filesystem notification may therefore ask for candidates while the
        // first Run is still active. Keep the same strict lower bound and cap
        // the upper bound at the observation time; exact cwd plus a unique
        // candidate is still required before the App binds it.
        (Some(started_at), None, true) => {
            let tolerance = chrono::Duration::minutes(5);
            let earliest = started_at - tolerance;
            let latest = chrono::Utc::now().fixed_offset() + tolerance;
            candidates.retain(|candidate| {
                candidate
                    .created_at
                    .as_deref()
                    .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
                    .is_some_and(|created_at| created_at >= earliest && created_at <= latest)
            });
        }
        // A candidate without a complete run time window is never strong
        // enough for the caller's unique-result automatic binding.
        _ => candidates.clear(),
    }
}

#[allow(clippy::too_many_arguments)]
fn collect_candidate_files(
    directory: &Path,
    source: &str,
    working_directory: &Path,
    candidates: &mut Vec<TerminalResumeCandidate>,
    remaining_files: &mut usize,
    remaining_bytes: &mut u64,
    deadline: Instant,
    depth: usize,
) -> std::io::Result<()> {
    if depth > 4
        || !directory.exists()
        || *remaining_files == 0
        || *remaining_bytes == 0
        || candidates.len() >= MAX_RESUME_CANDIDATES
        || Instant::now() >= deadline
    {
        return Ok(());
    }
    for entry in fs::read_dir(directory)?.take(10_000) {
        let entry = entry?;
        let metadata = entry.metadata()?;
        if metadata.is_dir() {
            collect_candidate_files(
                &entry.path(),
                source,
                working_directory,
                candidates,
                remaining_files,
                remaining_bytes,
                deadline,
                depth + 1,
            )?;
            continue;
        }
        if !metadata.is_file()
            || metadata.len() > MAX_CANDIDATE_BYTES
            || metadata.len() > *remaining_bytes
            || *remaining_files == 0
            || candidates.len() >= MAX_RESUME_CANDIDATES
            || Instant::now() >= deadline
        {
            continue;
        }
        *remaining_files -= 1;
        *remaining_bytes -= metadata.len();
        let content = match fs::read_to_string(entry.path()) {
            Ok(content) => content,
            Err(_) => continue,
        };
        let values = if source == "codex_session_store" {
            // Codex rollouts are bounded JSONL streams, not one JSON document.
            content
                .lines()
                .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
                .collect::<Vec<_>>()
        } else {
            // Kiro persists a complete JSON document. Do not accept a partial
            // line from a malformed snapshot as authoritative session data.
            serde_json::from_str::<serde_json::Value>(&content)
                .ok()
                .into_iter()
                .collect()
        };
        if !values
            .iter()
            .any(|value| value_has_working_directory(value, working_directory))
        {
            continue;
        }
        let provider_session_id = values.iter().find_map(find_session_id).or_else(|| {
            entry
                .path()
                .file_stem()
                .and_then(|value| value.to_str())
                .and_then(trailing_uuid)
        });
        let Some(provider_session_id) = provider_session_id else {
            continue;
        };
        candidates.push(TerminalResumeCandidate {
            provider_session_id,
            source: source.to_owned(),
            created_at: metadata
                .created()
                .or_else(|_| metadata.modified())
                .ok()
                .and_then(system_time_string),
        });
    }
    Ok(())
}

fn value_has_working_directory(value: &serde_json::Value, working_directory: &Path) -> bool {
    match value {
        serde_json::Value::Object(object) => object.iter().any(|(key, value)| {
            if matches!(
                key.as_str(),
                "cwd" | "working_directory" | "workingDirectory"
            ) {
                return value.as_str().is_some_and(|candidate| {
                    fs::canonicalize(candidate).unwrap_or_else(|_| candidate.into())
                        == working_directory
                });
            }
            value_has_working_directory(value, working_directory)
        }),
        serde_json::Value::Array(values) => values
            .iter()
            .any(|value| value_has_working_directory(value, working_directory)),
        _ => false,
    }
}

fn trailing_uuid(value: &str) -> Option<String> {
    value.char_indices().find_map(|(index, _)| {
        let candidate = &value[index..];
        uuid::Uuid::parse_str(candidate)
            .ok()
            .map(|value| value.to_string())
    })
}

fn find_session_id(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::Object(object) => {
            for key in [
                "session_id",
                "sessionId",
                "conversation_id",
                "conversationId",
                "id",
            ] {
                if let Some(id) = object.get(key).and_then(serde_json::Value::as_str)
                    && let Ok(id) = uuid::Uuid::parse_str(id)
                {
                    return Some(id.to_string());
                }
            }
            object.values().find_map(find_session_id)
        }
        serde_json::Value::Array(values) => values.iter().find_map(find_session_id),
        _ => None,
    }
}

fn system_time_string(value: SystemTime) -> Option<String> {
    let timestamp: chrono::DateTime<chrono::Utc> = value.into();
    Some(timestamp.to_rfc3339())
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct RunnerDescriptor<'a> {
    version: u32,
    session_id: &'a str,
    run_id: &'a str,
    executable: &'a str,
    arguments: &'a [String],
    working_directory: &'a str,
    working_directory_device: u64,
    working_directory_inode: u64,
    environment: &'a BTreeMap<String, String>,
    status_socket: &'a str,
    lifecycle_token: &'a str,
    hook_token: &'a str,
    host_pid: u32,
    cleanup_paths: &'a [String],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PrivateFileIdentity {
    device: u64,
    inode: u64,
}

impl PrivateFileIdentity {
    fn from_metadata(metadata: &fs::Metadata) -> Self {
        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
        }
    }

    fn matches(self, metadata: &fs::Metadata) -> bool {
        metadata.dev() == self.device && metadata.ino() == self.inode
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PrivateFileWrite {
    Created(PrivateFileIdentity),
    Reused,
}

fn validate_exact_private_file_metadata(
    metadata: &fs::Metadata,
    expected_len: usize,
) -> std::io::Result<()> {
    let uid = unsafe { nix::libc::geteuid() };
    if !metadata.file_type().is_file()
        || metadata.uid() != uid
        || metadata.permissions().mode() & 0o7777 != 0o600
        || metadata.nlink() != 1
        || metadata.len() != expected_len as u64
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "launch artifact must be a current-user mode 0600 single-link regular file of the expected size",
        ));
    }
    Ok(())
}

fn validate_private_file_path(
    path: &Path,
    opened: &fs::Metadata,
    expected_len: usize,
) -> std::io::Result<()> {
    let current = fs::symlink_metadata(path)?;
    validate_exact_private_file_metadata(&current, expected_len)?;
    if !PrivateFileIdentity::from_metadata(opened).matches(&current) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "launch artifact path changed during validation",
        ));
    }
    Ok(())
}

fn remove_created_file_if_same(path: &Path, created: PrivateFileIdentity) {
    let Ok(current) = fs::symlink_metadata(path) else {
        return;
    };
    if created.matches(&current) {
        let _ = fs::remove_file(path);
    }
}

/// Creates an Engine-to-runner artifact once, or validates an exact replay
/// without rewriting the original bytes. This keeps a lost IPC response
/// retryable while refusing to reuse a path for changed launch credentials or
/// parameters.
fn write_or_validate_exact_private_file(
    path: &Path,
    expected: &[u8],
) -> std::io::Result<PrivateFileWrite> {
    if expected.len() > MAX_PRIVATE_LAUNCH_ARTIFACT_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "launch artifact exceeds the size limit",
        ));
    }

    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(path)
    {
        Ok(mut file) => {
            let created = PrivateFileIdentity::from_metadata(&file.metadata()?);
            let result = (|| -> std::io::Result<()> {
                // `mode` is filtered by the process umask. Set the final mode
                // explicitly so the runner always sees the promised 0600.
                file.set_permissions(fs::Permissions::from_mode(0o600))?;
                file.write_all(expected)?;
                file.sync_all()?;
                let final_metadata = file.metadata()?;
                validate_exact_private_file_metadata(&final_metadata, expected.len())?;
                validate_private_file_path(path, &final_metadata, expected.len())
            })();
            if let Err(error) = result {
                drop(file);
                remove_created_file_if_same(path, created);
                return Err(error);
            }
            Ok(PrivateFileWrite::Created(created))
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            // O_NONBLOCK prevents a hostile pre-existing FIFO from blocking
            // before its metadata can be rejected.
            let mut file = OpenOptions::new()
                .read(true)
                .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC | nix::libc::O_NONBLOCK)
                .open(path)?;
            validate_exact_private_file_metadata(&file.metadata()?, expected.len())?;
            let mut actual = Vec::with_capacity(expected.len());
            {
                let mut bounded = (&mut file).take(expected.len() as u64 + 1);
                bounded.read_to_end(&mut actual)?;
            }
            let final_metadata = file.metadata()?;
            validate_exact_private_file_metadata(&final_metadata, expected.len())?;
            if actual != expected {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "existing launch artifact does not match this request",
                ));
            }
            validate_private_file_path(path, &final_metadata, expected.len())?;
            Ok(PrivateFileWrite::Reused)
        }
        Err(error) => Err(error),
    }
}

#[allow(clippy::too_many_arguments)]
pub fn build_launch_plan(
    session: TerminalSession,
    run: TerminalRun,
    runner_executable: String,
    agent_executable: String,
    task_title: Option<&str>,
    status_socket: &str,
    lifecycle_token: &str,
    hook_token: &str,
    host_pid: u32,
    provider_hooks_enabled: bool,
    descriptor_directory: &Path,
) -> std::io::Result<TerminalLaunchPlan> {
    // Validate before creating hook settings or a launch descriptor. The
    // runner repeats this check at consumption time to close the TOCTOU gap.
    let working_directory_identity = launch_working_directory_identity(&session.working_directory)?;
    let mut cleanup_paths = Vec::new();
    let mut created_cleanup_paths = Vec::new();
    let claude_settings = if session.runtime_kind == RuntimeKind::Claude && provider_hooks_enabled {
        let socket_parent = Path::new(status_socket).parent().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "status socket has no parent",
            )
        })?;
        let path = socket_parent.join(format!("claude-hooks-{}.json", run.id));
        cleanup_old_claude_hook_settings(socket_parent);
        if let PrivateFileWrite::Created(identity) =
            write_claude_hook_settings(&path, &runner_executable)?
        {
            created_cleanup_paths.push((path.clone(), identity));
        }
        cleanup_paths.push(path.display().to_string());
        Some(path)
    } else {
        None
    };
    let result = (|| -> std::io::Result<TerminalLaunchPlan> {
        let (agent_arguments, capture_strategy) =
            provider_arguments(&session, &run, task_title, claude_settings.as_deref());
        let mut environment = BTreeMap::new();
        environment.insert("TODOAGENT_SESSION_ID".to_owned(), session.id.clone());
        environment.insert("TODOAGENT_RUN_ID".to_owned(), run.id.clone());
        environment.insert(
            "TODOAGENT_RUNTIME".to_owned(),
            session.runtime_kind.as_str().to_owned(),
        );
        environment.insert(
            "TODOAGENT_STATUS_SOCKET".to_owned(),
            status_socket.to_owned(),
        );
        environment.insert("TODOAGENT_HOOK_TOKEN".to_owned(), hook_token.to_owned());
        if session.runtime_kind == RuntimeKind::Claude
            && let Some(config_directory) =
                claude_config_directory(Path::new(&session.working_directory))
        {
            // The managed Runner may itself be launched from a login shell. Pin
            // Claude to the same configuration root the Engine scans so shell-only
            // CLAUDE_CONFIG_DIR changes cannot create a transcript that the next
            // app process looks for somewhere else.
            environment.insert(
                "CLAUDE_CONFIG_DIR".to_owned(),
                config_directory.display().to_string(),
            );
        }

        secure_descriptor_directory(descriptor_directory, true)?;
        for entry in fs::read_dir(descriptor_directory)? {
            let entry = entry?;
            let metadata = match fs::symlink_metadata(entry.path()) {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };
            if owned_uuid_json(&entry.path(), &metadata)
                && metadata
                    .modified()
                    .ok()
                    .and_then(|value| value.elapsed().ok())
                    .is_some_and(|age| age.as_secs() > 24 * 60 * 60)
            {
                let _ = fs::remove_file(entry.path());
            }
        }
        let descriptor_path = descriptor_directory.join(format!("{}.json", run.id));
        let mut descriptor_bytes = serde_json::to_vec(&RunnerDescriptor {
            version: 3,
            session_id: &session.id,
            run_id: &run.id,
            executable: &agent_executable,
            arguments: &agent_arguments,
            working_directory: &session.working_directory,
            working_directory_device: working_directory_identity.device,
            working_directory_inode: working_directory_identity.inode,
            environment: &environment,
            status_socket,
            lifecycle_token,
            hook_token,
            host_pid,
            cleanup_paths: &cleanup_paths,
        })?;
        descriptor_bytes.push(b'\n');
        write_or_validate_exact_private_file(&descriptor_path, &descriptor_bytes)?;

        Ok(TerminalLaunchPlan {
            working_directory: session.working_directory.clone(),
            executable: runner_executable,
            arguments: vec![
                "--descriptor".to_owned(),
                descriptor_path.display().to_string(),
            ],
            environment: BTreeMap::new(),
            capture_strategy: capture_strategy.to_owned(),
            session,
            run,
        })
    })();
    if result.is_err() {
        for (path, identity) in created_cleanup_paths {
            remove_created_file_if_same(&path, identity);
        }
    }
    result
}

fn cleanup_old_claude_hook_settings(directory: &Path) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        if name.starts_with("claude-hooks-")
            && name.ends_with(".json")
            && metadata.is_file()
            && metadata
                .modified()
                .ok()
                .and_then(|value| value.elapsed().ok())
                .is_some_and(|age| age.as_secs() > 24 * 60 * 60)
        {
            let _ = fs::remove_file(entry.path());
        }
    }
}

fn provider_arguments(
    session: &TerminalSession,
    run: &TerminalRun,
    task_title: Option<&str>,
    claude_settings: Option<&Path>,
) -> (Vec<String>, &'static str) {
    let provider_id = run
        .provider_session_id_at_launch
        .as_deref()
        .or(session.provider_session_id.as_deref());
    let first_launch = run.launch_mode == crate::models::TerminalLaunchMode::Fresh;
    match session.runtime_kind {
        RuntimeKind::Codex if first_launch => (
            vec!["-C".to_owned(), session.working_directory.clone()],
            "session_store_scan",
        ),
        RuntimeKind::Codex => (
            vec![
                "resume".to_owned(),
                "-C".to_owned(),
                session.working_directory.clone(),
                required_provider_id(provider_id).to_owned(),
            ],
            "already_bound",
        ),
        RuntimeKind::Claude if first_launch => {
            let mut arguments = vec![
                "--session-id".to_owned(),
                required_provider_id(provider_id).to_owned(),
            ];
            if let Some(title) = task_title.map(str::trim).filter(|title| !title.is_empty()) {
                arguments.extend(["--name".to_owned(), title.to_owned()]);
            }
            append_claude_settings(&mut arguments, claude_settings);
            (arguments, "preallocated")
        }
        RuntimeKind::Claude => {
            let mut arguments = vec![
                "--resume".to_owned(),
                required_provider_id(provider_id).to_owned(),
            ];
            append_claude_settings(&mut arguments, claude_settings);
            (arguments, "already_bound")
        }
        RuntimeKind::Cursor => (
            vec![
                "--workspace".to_owned(),
                session.working_directory.clone(),
                "--resume".to_owned(),
                required_provider_id(provider_id).to_owned(),
            ],
            if first_launch {
                "create_chat"
            } else {
                "already_bound"
            },
        ),
        RuntimeKind::Kiro if first_launch => (
            vec!["chat".to_owned(), "--tui".to_owned()],
            "session_store_scan",
        ),
        RuntimeKind::Kiro => (
            vec![
                "chat".to_owned(),
                "--tui".to_owned(),
                "--resume-id".to_owned(),
                required_provider_id(provider_id).to_owned(),
            ],
            "already_bound",
        ),
    }
}

fn append_claude_settings(arguments: &mut Vec<String>, settings: Option<&Path>) {
    if let Some(settings) = settings {
        arguments.extend(["--settings".to_owned(), settings.display().to_string()]);
    }
}

fn write_claude_hook_settings(
    path: &Path,
    runner_executable: &str,
) -> std::io::Result<PrivateFileWrite> {
    let mut hooks = serde_json::Map::new();
    for event in [
        "SessionStart",
        "UserPromptSubmit",
        "PermissionRequest",
        "Stop",
        "SessionEnd",
    ] {
        let mut arguments = vec!["hook-event"];
        if matches!(event, "Stop" | "SessionEnd") {
            arguments.push("completed");
        }
        let handler = serde_json::json!({
            "type": "command",
            "command": runner_executable,
            "args": arguments,
            "timeout": 3
        });
        hooks.insert(event.to_owned(), serde_json::json!([{"hooks": [handler]}]));
    }
    let mut bytes = serde_json::to_vec(&serde_json::json!({"hooks": hooks}))?;
    bytes.push(b'\n');
    write_or_validate_exact_private_file(path, &bytes)
}

fn required_provider_id(value: Option<&str>) -> &str {
    // Store invariants prevent a resume plan without a provider binding. Keep
    // this function total so launch-plan construction cannot panic on corrupt
    // on-disk state; the empty value is rejected by the runner-facing caller.
    value.unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{
        ProviderBindingState, TerminalAgentStatus, TerminalLaunchMode, TerminalRunState,
    };

    fn session(kind: RuntimeKind, provider_id: Option<&str>) -> TerminalSession {
        let working_directory = fs::canonicalize(std::env::temp_dir()).unwrap();
        TerminalSession {
            id: "session-id".to_owned(),
            task_id: "task-id".to_owned(),
            runtime_kind: kind,
            working_directory: working_directory.to_string_lossy().into_owned(),
            provider_session_id: provider_id.map(str::to_owned),
            provider_binding_state: if provider_id.is_some() {
                ProviderBindingState::Bound
            } else {
                ProviderBindingState::Unbound
            },
            provider_binding_source: None,
            agent_status: TerminalAgentStatus::Unknown,
            has_active_run: false,
            status_sequence: 0,
            seen_status_sequence: 0,
            last_error_code: None,
            last_error_message: None,
            last_started_at: None,
            last_exited_at: None,
            last_exit_reason: None,
            auto_resume: false,
            created_at: "now".to_owned(),
            updated_at: "now".to_owned(),
        }
    }

    fn run(ordinal: i64) -> TerminalRun {
        TerminalRun {
            id: "run-id".to_owned(),
            session_id: "session-id".to_owned(),
            ordinal,
            launch_mode: if ordinal == 1 {
                TerminalLaunchMode::Fresh
            } else {
                TerminalLaunchMode::Resume
            },
            state: TerminalRunState::Starting,
            provider_session_id_at_launch: None,
            exit_code: None,
            exit_reason: None,
            error_code: None,
            error_message: None,
            started_at: None,
            exited_at: None,
            created_at: "now".to_owned(),
        }
    }

    #[test]
    fn claude_fresh_and_resume_use_the_same_explicit_provider_identity() {
        let provider_id = "7b9a3276-dfcd-46e3-94e3-92d43f9ebad4";
        let session = session(RuntimeKind::Claude, Some(provider_id));
        let (fresh_arguments, fresh_source) = provider_arguments(&session, &run(1), None, None);
        let (resume_arguments, resume_source) = provider_arguments(&session, &run(2), None, None);

        assert_eq!(
            fresh_arguments,
            vec!["--session-id".to_owned(), provider_id.to_owned()]
        );
        assert_eq!(fresh_source, "preallocated");
        assert_eq!(
            resume_arguments,
            vec!["--resume".to_owned(), provider_id.to_owned()]
        );
        assert_eq!(resume_source, "already_bound");
    }

    #[test]
    fn launch_working_directory_must_still_exist_as_an_absolute_real_directory() {
        let directory = tempfile::tempdir().unwrap();
        let directory_path = fs::canonicalize(directory.path()).unwrap();
        let valid = directory_path.join("project");
        fs::create_dir(&valid).unwrap();
        assert!(
            validate_launch_working_directory(valid.to_str().unwrap()).is_ok(),
            "an existing absolute directory remains launchable"
        );
        assert!(validate_launch_working_directory("relative/project").is_err());

        let missing = directory_path.join("missing");
        assert!(validate_launch_working_directory(missing.to_str().unwrap()).is_err());

        let file = directory_path.join("project.txt");
        fs::write(&file, b"not a directory").unwrap();
        assert!(validate_launch_working_directory(file.to_str().unwrap()).is_err());

        use std::os::unix::fs::symlink;
        let linked = directory_path.join("project-link");
        symlink(&valid, &linked).unwrap();
        assert!(validate_launch_working_directory(linked.to_str().unwrap()).is_err());

        let linked_parent = directory_path.join("parent-link");
        symlink(&directory_path, &linked_parent).unwrap();
        assert!(
            validate_launch_working_directory(linked_parent.join("project").to_str().unwrap())
                .is_err(),
            "no ancestor component may be a symlink"
        );
    }

    #[test]
    fn launch_plan_rejects_a_removed_working_directory_before_writing_artifacts() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let descriptor_directory = directory.path().join("TerminalRuns");
        let missing = directory.path().join("removed-project");
        let mut stale_session = session(RuntimeKind::Claude, Some("claude-id"));
        stale_session.working_directory = missing.to_string_lossy().into_owned();
        let result = build_launch_plan(
            stale_session,
            run(2),
            "/app/todoagent-terminal-runner".to_owned(),
            "/usr/local/bin/claude".to_owned(),
            None,
            directory.path().join("status.sock").to_str().unwrap(),
            "lifecycle-token",
            "hook-token",
            42,
            true,
            &descriptor_directory,
        );
        assert!(result.is_err());
        assert!(!descriptor_directory.exists());
    }

    #[test]
    fn launch_plan_exact_replay_reuses_descriptor_and_hook_settings() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let descriptor_directory = directory.path().join("TerminalRuns");
        let status_socket = directory.path().join("status.sock");
        let provider_session = session(RuntimeKind::Claude, Some("claude-id"));
        let terminal_run = run(1);
        let build = |hook_token: &str| {
            build_launch_plan(
                provider_session.clone(),
                terminal_run.clone(),
                "/app/todoagent-terminal-runner".to_owned(),
                "/usr/local/bin/claude".to_owned(),
                Some("task"),
                status_socket.to_str().unwrap(),
                "lifecycle-token",
                hook_token,
                42,
                true,
                &descriptor_directory,
            )
        };

        let first = build("hook-token").unwrap();
        let descriptor_path = PathBuf::from(&first.arguments[1]);
        let descriptor_before = fs::read(&descriptor_path).unwrap();
        let descriptor: serde_json::Value = serde_json::from_slice(&descriptor_before).unwrap();
        let settings_path = PathBuf::from(descriptor["cleanupPaths"][0].as_str().unwrap());
        let settings_before = fs::read(&settings_path).unwrap();

        let replay = build("hook-token").unwrap();
        assert_eq!(replay.arguments, first.arguments);
        assert_eq!(fs::read(&descriptor_path).unwrap(), descriptor_before);
        assert_eq!(fs::read(&settings_path).unwrap(), settings_before);

        let changed = build("hook-tokem").unwrap_err();
        assert_eq!(changed.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&descriptor_path).unwrap(), descriptor_before);
        assert_eq!(
            fs::read(&settings_path).unwrap(),
            settings_before,
            "a conflicting replay must not delete settings created by the original request"
        );
    }

    #[test]
    fn private_launch_artifact_replay_rejects_unsafe_existing_paths() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("artifact.json");
        let expected = b"{\"version\":3}\n";
        assert!(matches!(
            write_or_validate_exact_private_file(&path, expected).unwrap(),
            PrivateFileWrite::Created(_)
        ));
        let metadata_before = fs::metadata(&path).unwrap();
        assert_eq!(
            write_or_validate_exact_private_file(&path, expected).unwrap(),
            PrivateFileWrite::Reused
        );
        let metadata_after = fs::metadata(&path).unwrap();
        assert_eq!(metadata_after.ino(), metadata_before.ino());
        assert_eq!(
            metadata_after.modified().unwrap(),
            metadata_before.modified().unwrap(),
            "an exact replay must not rewrite the artifact"
        );
        let mismatch =
            write_or_validate_exact_private_file(&path, b"{\"version\":4}\n").unwrap_err();
        assert_eq!(mismatch.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&path).unwrap(), expected);

        let hardlink = directory.path().join("artifact-hardlink.json");
        fs::hard_link(&path, &hardlink).unwrap();
        let hardlink_error = write_or_validate_exact_private_file(&path, expected).unwrap_err();
        assert_eq!(hardlink_error.kind(), std::io::ErrorKind::PermissionDenied);

        let symlink_path = directory.path().join("artifact-symlink.json");
        symlink(&path, &symlink_path).unwrap();
        assert!(write_or_validate_exact_private_file(&symlink_path, expected).is_err());
    }

    #[test]
    fn launch_plan_failure_only_cleans_hook_settings_created_by_this_attempt() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let descriptor_directory = directory.path().join("TerminalRuns");
        fs::create_dir(&descriptor_directory).unwrap();
        fs::set_permissions(&descriptor_directory, fs::Permissions::from_mode(0o700)).unwrap();
        let conflicting_descriptor = descriptor_directory.join("run-id.json");
        fs::write(&conflicting_descriptor, b"{}\n").unwrap();
        fs::set_permissions(&conflicting_descriptor, fs::Permissions::from_mode(0o600)).unwrap();
        let status_socket = directory.path().join("status.sock");
        let hook_settings = directory.path().join("claude-hooks-run-id.json");

        let result = build_launch_plan(
            session(RuntimeKind::Claude, Some("claude-id")),
            run(1),
            "/app/todoagent-terminal-runner".to_owned(),
            "/usr/local/bin/claude".to_owned(),
            None,
            status_socket.to_str().unwrap(),
            "lifecycle-token",
            "hook-token",
            42,
            true,
            &descriptor_directory,
        );

        assert!(result.is_err());
        assert!(!hook_settings.exists());
        assert_eq!(fs::read(&conflicting_descriptor).unwrap(), b"{}\n");
    }

    #[test]
    fn provider_profiles_never_use_ambiguous_last_or_continue_flags() {
        let cases = [
            (RuntimeKind::Codex, Some("codex-id")),
            (RuntimeKind::Claude, Some("claude-id")),
            (RuntimeKind::Cursor, Some("cursor-id")),
            (RuntimeKind::Kiro, Some("kiro-id")),
        ];
        for (kind, provider_id) in cases {
            let directory = tempfile::tempdir().unwrap();
            fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
            let status_socket = directory.path().join("status.sock");
            let provider_session = session(kind, provider_id);
            let expected_claude_config =
                claude_config_directory(Path::new(&provider_session.working_directory));
            let plan = build_launch_plan(
                provider_session,
                run(2),
                "/app/runner".to_owned(),
                "/usr/local/bin/agent".to_owned(),
                None,
                status_socket.to_str().unwrap(),
                "lifecycle-token",
                "hook-token",
                1,
                true,
                directory.path(),
            )
            .unwrap();
            assert!(
                !plan
                    .arguments
                    .iter()
                    .any(|arg| { matches!(arg.as_str(), "--last" | "--continue" | "-r") })
            );
            let descriptor = fs::read_to_string(&plan.arguments[1]).unwrap();
            assert!(descriptor.contains(provider_id.unwrap()));
            if kind == RuntimeKind::Claude {
                let descriptor: serde_json::Value = serde_json::from_str(&descriptor).unwrap();
                assert_eq!(
                    descriptor["environment"]["CLAUDE_CONFIG_DIR"].as_str(),
                    expected_claude_config
                        .as_ref()
                        .map(|path| path.to_string_lossy())
                        .as_deref()
                );
            }
        }
    }

    #[test]
    fn claude_resume_state_distinguishes_absent_resumable_and_unusable_transcripts() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("claude-config");
        let project = config.join("projects/project-a");
        fs::create_dir_all(&project).unwrap();

        let absent_id = uuid::Uuid::new_v4().to_string();
        assert_eq!(
            claude_resume_state_in(&config, &absent_id).unwrap(),
            ClaudeResumeState::Absent
        );

        let resumable_id = uuid::Uuid::new_v4().to_string();
        fs::write(
            project.join(format!("{resumable_id}.jsonl")),
            "{\"type\":\"queue-operation\"}\n{\"type\":\"user\",\"isSidechain\":false,\"message\":{}}\n",
        )
        .unwrap();
        assert_eq!(
            claude_resume_state_in(&config, &resumable_id).unwrap(),
            ClaudeResumeState::Resumable
        );

        let unusable_id = uuid::Uuid::new_v4().to_string();
        fs::write(
            project.join(format!("{unusable_id}.jsonl")),
            "{\"type\":\"queue-operation\"}\n{\"type\":\"assistant\",\"isSidechain\":true}\n",
        )
        .unwrap();
        assert_eq!(
            claude_resume_state_in(&config, &unusable_id).unwrap(),
            ClaudeResumeState::Unusable
        );

        let large_id = uuid::Uuid::new_v4().to_string();
        let mut large_transcript =
            b"{\"type\":\"user\",\"isSidechain\":false,\"message\":{}}\n".to_vec();
        large_transcript.resize(MAX_CLAUDE_TRANSCRIPT_BYTES as usize + 1, b' ');
        fs::write(project.join(format!("{large_id}.jsonl")), large_transcript).unwrap();
        assert_eq!(
            claude_resume_state_in(&config, &large_id).unwrap(),
            ClaudeResumeState::Resumable
        );
    }

    #[test]
    fn claude_resume_scan_does_not_follow_project_directory_symlinks() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("claude-config");
        let projects = config.join("projects");
        let outside = directory.path().join("outside");
        fs::create_dir_all(&projects).unwrap();
        fs::create_dir_all(&outside).unwrap();
        let provider_id = uuid::Uuid::new_v4().to_string();
        fs::write(
            outside.join(format!("{provider_id}.jsonl")),
            "{\"type\":\"user\",\"isSidechain\":false}\n",
        )
        .unwrap();
        symlink(&outside, projects.join("linked-project")).unwrap();

        assert_eq!(
            claude_resume_state_in(&config, &provider_id).unwrap(),
            ClaudeResumeState::Absent
        );
    }

    #[test]
    fn first_launch_profiles_do_not_inject_a_task_prompt() {
        let cases = [
            (RuntimeKind::Codex, None),
            (RuntimeKind::Claude, Some("claude-id")),
            (RuntimeKind::Cursor, Some("cursor-id")),
            (RuntimeKind::Kiro, None),
        ];
        for (kind, provider_id) in cases {
            let directory = tempfile::tempdir().unwrap();
            fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
            let status_socket = directory.path().join("status.sock");
            let plan = build_launch_plan(
                session(kind, provider_id),
                run(1),
                "/app/runner".to_owned(),
                "/usr/local/bin/agent".to_owned(),
                Some("task title"),
                status_socket.to_str().unwrap(),
                "lifecycle-token",
                "hook-token",
                1,
                true,
                directory.path(),
            )
            .unwrap();
            let descriptor = fs::read_to_string(&plan.arguments[1]).unwrap();
            if kind != RuntimeKind::Claude {
                assert!(!descriptor.contains("task title"));
            }
        }
    }

    #[test]
    fn descriptor_hides_agent_command_and_contains_hook_credentials() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let status_socket = directory.path().join("status.sock");
        let plan = build_launch_plan(
            session(RuntimeKind::Claude, Some("claude-id")),
            run(1),
            "/app/todoagent-terminal-runner".to_owned(),
            "/usr/local/bin/claude".to_owned(),
            Some("task"),
            status_socket.to_str().unwrap(),
            "lifecycle-secret",
            "hook-secret",
            42,
            true,
            directory.path(),
        )
        .unwrap();
        assert_eq!(plan.arguments[0], "--descriptor");
        assert!(!plan.arguments.iter().any(|value| value.contains("claude")));
        let descriptor = fs::read_to_string(&plan.arguments[1]).unwrap();
        assert!(descriptor.contains("TODOAGENT_STATUS_SOCKET"));
        assert!(descriptor.contains("TODOAGENT_HOOK_TOKEN"));
        assert!(descriptor.contains("lifecycle-secret"));
        assert!(descriptor.contains("hook-secret"));
        let descriptor_value: serde_json::Value = serde_json::from_str(&descriptor).unwrap();
        let working_directory_metadata =
            fs::metadata(fs::canonicalize(std::env::temp_dir()).unwrap()).unwrap();
        assert_eq!(descriptor_value["version"], 3);
        assert_eq!(
            descriptor_value["workingDirectoryDevice"],
            working_directory_metadata.dev()
        );
        assert_eq!(
            descriptor_value["workingDirectoryInode"],
            working_directory_metadata.ino()
        );
        assert_eq!(
            descriptor_value["environment"]["TODOAGENT_HOOK_TOKEN"],
            "hook-secret"
        );
        assert!(
            descriptor_value["environment"]
                .as_object()
                .unwrap()
                .values()
                .all(|value| value != "lifecycle-secret")
        );
        assert_eq!(
            fs::metadata(&plan.arguments[1])
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let settings_path = descriptor_value["cleanupPaths"][0].as_str().unwrap();
        let settings: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(settings_path).unwrap()).unwrap();
        let handler = &settings["hooks"]["SessionStart"][0]["hooks"][0];
        assert_eq!(handler["type"], "command");
        assert_eq!(handler["command"], "/app/todoagent-terminal-runner");
        assert_eq!(handler["args"], serde_json::json!(["hook-event"]));
        assert_eq!(handler["timeout"], 3);
        let completed = &settings["hooks"]["Stop"][0]["hooks"][0];
        assert_eq!(
            completed["args"],
            serde_json::json!(["hook-event", "completed"])
        );
    }

    #[test]
    fn declining_provider_hooks_does_not_create_or_inject_claude_settings() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let status_socket = directory.path().join("status.sock");
        let plan = build_launch_plan(
            session(RuntimeKind::Claude, Some("claude-id")),
            run(1),
            "/app/todoagent-terminal-runner".to_owned(),
            "/usr/local/bin/claude".to_owned(),
            None,
            status_socket.to_str().unwrap(),
            "lifecycle-token",
            "hook-token",
            42,
            false,
            directory.path(),
        )
        .unwrap();
        let descriptor = fs::read_to_string(&plan.arguments[1]).unwrap();
        assert!(!descriptor.contains("--settings"));
        assert!(
            fs::read_dir(directory.path())
                .unwrap()
                .filter_map(Result::ok)
                .all(|entry| !entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("claude-hooks-"))
        );
    }

    #[test]
    fn codex_jsonl_candidates_require_an_exact_working_directory() {
        let directory = tempfile::tempdir().unwrap();
        let wanted = directory.path().join("project");
        let wrong = directory.path().join("project-copy");
        fs::create_dir_all(&wanted).unwrap();
        fs::create_dir_all(&wrong).unwrap();
        let store = directory.path().join("sessions");
        fs::create_dir_all(&store).unwrap();
        let wanted_id = uuid::Uuid::new_v4().to_string();
        let wrong_id = uuid::Uuid::new_v4().to_string();
        fs::write(
            store.join(format!("rollout-2026-08-12-{wanted_id}.jsonl")),
            format!(
                "{{\"type\":\"metadata\",\"payload\":{{\"cwd\":{},\"session_id\":\"{wanted_id}\"}}}}\n{{\"type\":\"event\"}}\n",
                serde_json::to_string(wanted.to_str().unwrap()).unwrap()
            ),
        )
        .unwrap();
        fs::write(
            store.join(format!("rollout-2026-08-12-{wrong_id}.jsonl")),
            format!(
                "{{\"cwd\":{},\"session_id\":\"{wrong_id}\"}}\n",
                serde_json::to_string(wrong.to_str().unwrap()).unwrap()
            ),
        )
        .unwrap();
        let mut candidates = Vec::new();
        let mut remaining = MAX_CANDIDATE_FILES;
        let mut remaining_bytes = MAX_CANDIDATE_TOTAL_BYTES;
        collect_candidate_files(
            &store,
            "codex_session_store",
            &fs::canonicalize(&wanted).unwrap(),
            &mut candidates,
            &mut remaining,
            &mut remaining_bytes,
            Instant::now() + CANDIDATE_SCAN_BUDGET,
            0,
        )
        .unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].provider_session_id, wanted_id);
    }

    #[test]
    fn multiple_exact_candidates_are_returned_without_guessing() {
        let directory = tempfile::tempdir().unwrap();
        let wanted = directory.path().join("project");
        fs::create_dir_all(&wanted).unwrap();
        let store = directory.path().join("sessions");
        fs::create_dir_all(&store).unwrap();
        let ids = [uuid::Uuid::new_v4(), uuid::Uuid::new_v4()];
        for id in ids {
            fs::write(
                store.join(format!("rollout-2026-08-12-{id}.jsonl")),
                format!(
                    "{{\"type\":\"metadata\",\"payload\":{{\"cwd\":{},\"session_id\":\"{id}\"}}}}\n",
                    serde_json::to_string(wanted.to_str().unwrap()).unwrap()
                ),
            )
            .unwrap();
        }
        let mut candidates = Vec::new();
        let mut remaining = MAX_CANDIDATE_FILES;
        let mut remaining_bytes = MAX_CANDIDATE_TOTAL_BYTES;
        collect_candidate_files(
            &store,
            "codex_session_store",
            &fs::canonicalize(&wanted).unwrap(),
            &mut candidates,
            &mut remaining,
            &mut remaining_bytes,
            Instant::now() + CANDIDATE_SCAN_BUDGET,
            0,
        )
        .unwrap();
        assert_eq!(candidates.len(), 2);
    }

    #[test]
    fn terminal_runs_directory_rejects_symlinks_and_cleanup_is_narrow() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let real = directory.path().join("real");
        fs::create_dir(&real).unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o700)).unwrap();
        let linked = directory.path().join("TerminalRuns");
        symlink(&real, &linked).unwrap();
        assert!(secure_descriptor_directory(&linked, true).is_err());

        let valid = uuid::Uuid::new_v4().to_string();
        let valid_path = real.join(format!("{valid}.json"));
        fs::write(&valid_path, b"{}").unwrap();
        fs::set_permissions(&valid_path, fs::Permissions::from_mode(0o600)).unwrap();
        let unrelated = real.join("notes.json");
        fs::write(&unrelated, b"keep").unwrap();
        let target = directory.path().join("target.json");
        fs::write(&target, b"keep").unwrap();
        let symlink_path = real.join(format!("{}.json", uuid::Uuid::new_v4()));
        symlink(&target, &symlink_path).unwrap();
        cleanup_stale_descriptors(&real).unwrap();
        assert!(!valid_path.exists());
        assert!(unrelated.exists());
        assert!(symlink_path.exists());
        assert_eq!(fs::read(&target).unwrap(), b"keep");
    }

    #[test]
    fn resume_candidates_outside_the_completed_run_window_are_rejected() {
        let mut session = session(RuntimeKind::Codex, None);
        session.last_started_at = Some("2026-08-12T10:00:00Z".to_owned());
        session.last_exited_at = Some("2026-08-12T10:10:00Z".to_owned());
        let mut candidates = vec![
            TerminalResumeCandidate {
                provider_session_id: uuid::Uuid::new_v4().to_string(),
                source: "codex_session_store".to_owned(),
                created_at: Some("2026-08-12T10:05:00Z".to_owned()),
            },
            TerminalResumeCandidate {
                provider_session_id: uuid::Uuid::new_v4().to_string(),
                source: "codex_session_store".to_owned(),
                created_at: Some("2026-08-12T11:00:00Z".to_owned()),
            },
            TerminalResumeCandidate {
                provider_session_id: uuid::Uuid::new_v4().to_string(),
                source: "codex_session_store".to_owned(),
                created_at: None,
            },
        ];
        filter_candidates_to_run_window(&mut candidates, &session);
        assert_eq!(candidates.len(), 1);
        assert_eq!(
            candidates[0].created_at.as_deref(),
            Some("2026-08-12T10:05:00Z")
        );
    }

    #[test]
    fn active_kiro_run_accepts_only_candidates_created_after_start() {
        let mut session = session(RuntimeKind::Kiro, None);
        session.has_active_run = true;
        session.last_started_at = Some(chrono::Utc::now().to_rfc3339());
        session.last_exited_at = None;
        let current_id = uuid::Uuid::new_v4().to_string();
        let old_id = uuid::Uuid::new_v4().to_string();
        let mut candidates = vec![
            TerminalResumeCandidate {
                provider_session_id: current_id.clone(),
                source: "kiro_session_store".to_owned(),
                created_at: Some(chrono::Utc::now().to_rfc3339()),
            },
            TerminalResumeCandidate {
                provider_session_id: old_id,
                source: "kiro_session_store".to_owned(),
                created_at: Some((chrono::Utc::now() - chrono::Duration::hours(1)).to_rfc3339()),
            },
        ];

        filter_candidates_to_run_window(&mut candidates, &session);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].provider_session_id, current_id);
    }
}

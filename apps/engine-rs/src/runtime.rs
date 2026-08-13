use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use chrono::Utc;
use serde_json::{Value, json};
use tokio::process::Command;
use tokio::time::timeout;

use crate::models::{Runtime, RuntimeKind};

const VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(15);
const CAPABILITY_PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const AUTH_PROBE_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, PartialEq, Eq)]
pub enum LaunchExecutableResolution {
    Cached(PathBuf),
    RefreshRequired {
        launch_path: PathBuf,
        resolved_path: PathBuf,
    },
}

pub fn detect_all() -> Vec<Runtime> {
    RuntimeKind::ALL
        .into_iter()
        .map(|kind| {
            let launch = discover(kind);
            Runtime {
                kind,
                launch_path: launch.as_ref().map(|path| path.display().to_string()),
                resolved_path: launch
                    .as_ref()
                    .and_then(|path| fs::canonicalize(path).ok())
                    .map(|path| path.display().to_string()),
                version: None,
                status: if launch.is_some() {
                    "detected"
                } else {
                    "missing"
                }
                .to_owned(),
                auth_status: "unknown".to_owned(),
                capabilities: capabilities(kind),
                provider_engine: (kind == RuntimeKind::Kiro).then(|| "v2".to_owned()),
                detected_at: Some(Utc::now().to_rfc3339()),
                verified_at: None,
                verify_error: None,
            }
        })
        .collect()
}

pub async fn verify(kind: RuntimeKind, explicit: Option<&str>) -> Runtime {
    let timestamp = Utc::now().to_rfc3339();
    let launch = explicit.map(PathBuf::from).or_else(|| discover(kind));
    let Some(launch) = launch else {
        return Runtime {
            kind,
            launch_path: None,
            resolved_path: None,
            version: None,
            status: "missing".to_owned(),
            auth_status: "unknown".to_owned(),
            capabilities: capabilities(kind),
            provider_engine: provider_engine(kind),
            detected_at: Some(timestamp.clone()),
            verified_at: Some(timestamp),
            verify_error: Some("executable not found".to_owned()),
        };
    };
    let resolved = fs::canonicalize(&launch).unwrap_or_else(|_| launch.clone());
    if !resolved.is_absolute() || !is_executable(&resolved) {
        return failed(
            kind,
            launch,
            resolved,
            timestamp,
            "path is not an executable file".to_owned(),
        );
    }
    let version = match command_output(&resolved, &["--version"], VERSION_PROBE_TIMEOUT).await {
        Ok(output) => first_line(&output).unwrap_or_else(|| "unknown".to_owned()),
        Err(error) => return failed(kind, launch, resolved, timestamp, error),
    };
    let terminal_capabilities = match probe_terminal_capabilities(kind, &resolved).await {
        Ok(capabilities) => capabilities,
        Err(error) => return failed(kind, launch, resolved, timestamp, error),
    };
    let (auth_status, verify_error) = verify_auth(kind, &resolved).await;
    let status = match auth_status.as_str() {
        "authenticated" => "ready",
        "required" => "auth_required",
        _ => "error",
    };
    Runtime {
        kind,
        launch_path: Some(launch.display().to_string()),
        resolved_path: Some(resolved.display().to_string()),
        version: Some(version),
        status: status.to_owned(),
        auth_status,
        capabilities: terminal_capabilities,
        provider_engine: provider_engine(kind),
        detected_at: Some(timestamp.clone()),
        verified_at: Some(timestamp),
        verify_error,
    }
}

/// Resolves the executable used for a terminal launch without permanently
/// pinning a self-updating CLI to its old versioned target.
///
/// A successful verification stores both the stable discovery path (for
/// example `~/.local/bin/claude`) and its canonical target. The canonical
/// target remains the authority while the stable path is unchanged, but many
/// vendor updaters atomically repoint that stable symlink. Comparing it on
/// every launch catches that rollover even when the old target still exists.
/// The caller must fully verify and persist `RefreshRequired` before executing
/// the returned target.
pub fn resolve_launch_executable(
    runtime: &Runtime,
) -> Result<LaunchExecutableResolution, &'static str> {
    let cached = runtime
        .resolved_path
        .as_deref()
        .map(PathBuf::from)
        .filter(|path| is_resolved_executable(path));

    let Some(launch_path) = runtime.launch_path.as_deref().map(PathBuf::from) else {
        return Err("runtime_executable_missing");
    };
    if !launch_path.is_absolute() {
        return Err("runtime_executable_invalid");
    }

    let current = match fs::canonicalize(&launch_path) {
        Ok(path) if is_resolved_executable(&path) => path,
        Ok(_) => return Err("runtime_executable_invalid"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err("runtime_executable_missing");
        }
        Err(_) => return Err("runtime_executable_invalid"),
    };

    if cached.as_ref() == Some(&current) {
        return Ok(LaunchExecutableResolution::Cached(current));
    }
    Ok(LaunchExecutableResolution::RefreshRequired {
        launch_path,
        resolved_path: current,
    })
}

pub fn discover(kind: RuntimeKind) -> Option<PathBuf> {
    let name = kind.executable_name();
    search_directories()
        .into_iter()
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable(candidate))
}

pub fn merged_path() -> String {
    std::env::join_paths(search_directories())
        .ok()
        .and_then(|value| value.into_string().ok())
        .unwrap_or_default()
}

pub fn capabilities(kind: RuntimeKind) -> Value {
    match kind {
        RuntimeKind::Kiro => json!({
            "terminalPty": true, "nativeResume": true, "transport": "pty",
            "providerBinding": "session_store_scan", "statusHooks": "process_only",
            "testedBaseline": "2.12.2", "providerEngine": "v2"
        }),
        RuntimeKind::Codex => json!({
            "terminalPty": true, "nativeResume": true, "transport": "pty",
            "providerBinding": "session_start_hook_or_session_store_scan", "statusHooks": "active_completed",
            "testedBaseline": "0.146.0"
        }),
        RuntimeKind::Claude => json!({
            "terminalPty": true, "nativeResume": true, "transport": "pty",
            "providerBinding": "preallocated", "statusHooks": "active_blocked_completed",
            "runScopedSettings": true, "testedBaseline": "2.1.228"
        }),
        RuntimeKind::Cursor => json!({
            "terminalPty": true, "nativeResume": true, "transport": "pty",
            "providerBinding": "create_chat", "statusHooks": "active_completed",
            "testedBaseline": "2026.07.23"
        }),
    }
}

/// Probes the actual CLI grammar needed by the terminal launch profiles. This
/// deliberately does not infer compatibility from a version string: vendors
/// may backport, remove, or rename flags independently of their display
/// version. Help commands are non-mutating and do not require a PTY.
async fn probe_terminal_capabilities(
    kind: RuntimeKind,
    executable: &Path,
) -> Result<Value, String> {
    let root_args = help_probe(kind);
    let root = command_output(executable, &root_args, CAPABILITY_PROBE_TIMEOUT).await?;
    let secondary_args = secondary_help_probe(kind);
    let secondary = command_output(executable, secondary_args, CAPABILITY_PROBE_TIMEOUT).await?;
    validate_terminal_capability_output(kind, &root, &secondary)?;
    let mut result = capabilities(kind);
    if let Some(object) = result.as_object_mut() {
        object.insert(
            "capabilityProbe".to_owned(),
            Value::String("passed".to_owned()),
        );
    }
    Ok(result)
}

fn help_probe(kind: RuntimeKind) -> Vec<&'static str> {
    match kind {
        RuntimeKind::Codex | RuntimeKind::Claude | RuntimeKind::Cursor => vec!["--help"],
        RuntimeKind::Kiro => vec!["chat", "--help"],
    }
}

fn secondary_help_probe(kind: RuntimeKind) -> &'static [&'static str] {
    match kind {
        RuntimeKind::Codex => &["resume", "--help"],
        RuntimeKind::Claude => &["--help"],
        RuntimeKind::Cursor => &["create-chat", "--help"],
        RuntimeKind::Kiro => &["chat", "--help"],
    }
}

fn validate_terminal_capability_output(
    kind: RuntimeKind,
    root: &str,
    secondary: &str,
) -> Result<(), String> {
    let required: &[(&str, &str)] = match kind {
        RuntimeKind::Codex => &[
            (root, "--cd"),
            (root, "resume"),
            (secondary, "session_id"),
            (secondary, "--cd"),
        ],
        RuntimeKind::Claude => &[
            (root, "--session-id"),
            (root, "--resume"),
            (root, "--name"),
            (root, "--settings"),
        ],
        RuntimeKind::Cursor => &[
            (root, "--workspace"),
            (root, "--resume"),
            (root, "create-chat"),
            (secondary, "create new empty chat"),
        ],
        RuntimeKind::Kiro => &[
            (root, "--tui"),
            (root, "--resume-id"),
            (root, "--resume-picker"),
            (root, "--list-sessions"),
        ],
    };
    let missing = required
        .iter()
        .filter_map(|(output, token)| {
            (!output
                .to_ascii_lowercase()
                .contains(&token.to_ascii_lowercase()))
            .then_some(*token)
        })
        .collect::<Vec<_>>();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "runtime terminal capability probe failed; missing {}",
            missing.join(", ")
        ))
    }
}

async fn verify_auth(kind: RuntimeKind, executable: &Path) -> (String, Option<String>) {
    let args: &[&str] = match kind {
        RuntimeKind::Codex => &["login", "status"],
        RuntimeKind::Claude => &["auth", "status", "--json"],
        RuntimeKind::Cursor => &["status", "--format", "json"],
        RuntimeKind::Kiro => &["whoami", "--format", "json"],
    };
    match command_output(executable, args, AUTH_PROBE_TIMEOUT).await {
        Ok(output) => {
            let lowered = output.to_lowercase();
            let unauthenticated = lowered.contains("not logged in")
                || lowered.contains("not authenticated")
                || lowered.contains("\"account\":null")
                || lowered.contains("\"loggedin\":false")
                || lowered.contains("\"authenticated\":false");
            if unauthenticated {
                (
                    "required".to_owned(),
                    Some("runtime is not authenticated".to_owned()),
                )
            } else {
                ("authenticated".to_owned(), None)
            }
        }
        Err(error) => {
            let lowered = error.to_lowercase();
            if lowered.contains("not logged in")
                || lowered.contains("not authenticated")
                || lowered.contains("login")
            {
                ("required".to_owned(), Some(error))
            } else {
                ("error".to_owned(), Some(error))
            }
        }
    }
}

async fn command_output(path: &Path, args: &[&str], budget: Duration) -> Result<String, String> {
    let mut command = Command::new(path);
    command
        .args(args)
        .env("PATH", merged_path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let output = timeout(budget, command.output())
        .await
        .map_err(|_| format!("{} timed out", args.join(" ")))?
        .map_err(|error| error.to_string())?;
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if output.status.success() {
        Ok(combined.trim().to_owned())
    } else {
        Err(format!(
            "{} exited {}: {}",
            args.join(" "),
            output.status,
            combined.trim()
        ))
    }
}

fn failed(
    kind: RuntimeKind,
    launch: PathBuf,
    resolved: PathBuf,
    timestamp: String,
    error: String,
) -> Runtime {
    Runtime {
        kind,
        launch_path: Some(launch.display().to_string()),
        resolved_path: Some(resolved.display().to_string()),
        version: None,
        status: "error".to_owned(),
        auth_status: "error".to_owned(),
        capabilities: capabilities(kind),
        provider_engine: provider_engine(kind),
        detected_at: Some(timestamp.clone()),
        verified_at: Some(timestamp),
        verify_error: Some(error),
    }
}

fn provider_engine(kind: RuntimeKind) -> Option<String> {
    (kind == RuntimeKind::Kiro).then(|| "v2".to_owned())
}

fn first_line(value: &str) -> Option<String> {
    value
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_owned)
}

fn search_directories() -> Vec<PathBuf> {
    let mut directories = vec![
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/opt/homebrew/sbin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
        PathBuf::from("/bin"),
    ];
    if let Some(home) = dirs::home_dir() {
        directories.push(home.join(".local/bin"));
        directories.push(home.join(".bun/bin"));
        directories.push(home.join(".cargo/bin"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        directories.extend(std::env::split_paths(&path));
    }
    let mut seen = HashSet::new();
    directories.retain(|path| seen.insert(path.clone()));
    directories
}

fn is_executable(path: &Path) -> bool {
    path.metadata()
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

fn is_resolved_executable(path: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    fs::symlink_metadata(path)
        .map(|metadata| {
            !metadata.file_type().is_symlink()
                && metadata.is_file()
                && metadata.permissions().mode() & 0o111 != 0
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use tempfile::tempdir;

    #[test]
    fn all_four_runtimes_have_distinct_executables() {
        let names: HashSet<_> = RuntimeKind::ALL
            .into_iter()
            .map(RuntimeKind::executable_name)
            .collect();
        assert_eq!(names.len(), 4);
        assert_eq!(RuntimeKind::Cursor.executable_name(), "cursor-agent");
        assert_eq!(RuntimeKind::Kiro.executable_name(), "kiro-cli");
    }

    #[test]
    fn terminal_capability_probe_requires_exact_resume_grammar() {
        let cases = [
            (
                RuntimeKind::Codex,
                "Usage: codex --cd DIR resume",
                "Usage: codex resume [SESSION_ID] --cd DIR",
            ),
            (
                RuntimeKind::Claude,
                "--session-id UUID --resume ID --name NAME --settings JSON",
                "--session-id UUID --resume ID --name NAME --settings JSON",
            ),
            (
                RuntimeKind::Cursor,
                "--workspace PATH --resume ID create-chat",
                "Create new empty chat and return its ID",
            ),
            (
                RuntimeKind::Kiro,
                "--tui --resume-id ID --resume-picker --list-sessions",
                "--tui --resume-id ID --resume-picker --list-sessions",
            ),
        ];
        for (kind, root, secondary) in cases {
            assert!(validate_terminal_capability_output(kind, root, secondary).is_ok());
            assert!(validate_terminal_capability_output(kind, "--help", "--help").is_err());
        }
    }

    #[test]
    fn advertised_capabilities_describe_pty_not_legacy_message_transport() {
        for kind in RuntimeKind::ALL {
            let value = capabilities(kind);
            assert_eq!(value["terminalPty"], true);
            assert_eq!(value["nativeResume"], true);
            assert_eq!(value["transport"], "pty");
            assert!(value.get("testedBaseline").is_some());
        }
    }

    fn ready_runtime(launch_path: &Path, resolved_path: &Path) -> Runtime {
        Runtime {
            kind: RuntimeKind::Claude,
            launch_path: Some(launch_path.to_string_lossy().into_owned()),
            resolved_path: Some(resolved_path.to_string_lossy().into_owned()),
            version: Some("2.1.224 (Claude Code)".to_owned()),
            status: "ready".to_owned(),
            auth_status: "authenticated".to_owned(),
            capabilities: capabilities(RuntimeKind::Claude),
            provider_engine: None,
            detected_at: None,
            verified_at: None,
            verify_error: None,
        }
    }

    #[test]
    fn missing_stable_launch_path_never_falls_back_to_an_existing_cached_target() {
        let directory = tempdir().unwrap();
        let old_target = directory.path().join("2.1.224");
        fs::write(&old_target, b"old").unwrap();
        fs::set_permissions(&old_target, fs::Permissions::from_mode(0o755)).unwrap();
        let missing_launch = directory.path().join("claude");

        assert_eq!(
            resolve_launch_executable(&ready_runtime(&missing_launch, &old_target)),
            Err("runtime_executable_missing")
        );
    }

    #[test]
    fn broken_stable_launch_symlink_never_falls_back_to_an_existing_cached_target() {
        let directory = tempdir().unwrap();
        let old_target = directory.path().join("2.1.224");
        fs::write(&old_target, b"old").unwrap();
        fs::set_permissions(&old_target, fs::Permissions::from_mode(0o755)).unwrap();
        let stable_launch = directory.path().join("claude");
        symlink(directory.path().join("missing-version"), &stable_launch).unwrap();

        assert_eq!(
            resolve_launch_executable(&ready_runtime(&stable_launch, &old_target)),
            Err("runtime_executable_missing")
        );
    }
}

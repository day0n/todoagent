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
    let version = match command_output(&resolved, &["--version"], Duration::from_secs(8)).await {
        Ok(output) => first_line(&output).unwrap_or_else(|| "unknown".to_owned()),
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
        capabilities: capabilities(kind),
        provider_engine: provider_engine(kind),
        detected_at: Some(timestamp.clone()),
        verified_at: Some(timestamp),
        verify_error,
    }
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
            "nativeResume": true, "transport": "acp", "text": true,
            "attachments": false, "providerEngine": "v2"
        }),
        RuntimeKind::Codex => {
            json!({"nativeResume": true, "transport": "jsonl", "text": true, "attachments": false})
        }
        RuntimeKind::Claude | RuntimeKind::Cursor => {
            json!({"nativeResume": true, "transport": "stream_json", "text": true, "attachments": false})
        }
    }
}

async fn verify_auth(kind: RuntimeKind, executable: &Path) -> (String, Option<String>) {
    let args: &[&str] = match kind {
        RuntimeKind::Codex => &["login", "status"],
        RuntimeKind::Claude => &["auth", "status", "--json"],
        RuntimeKind::Cursor => &["status", "--format", "json"],
        RuntimeKind::Kiro => &["whoami", "--format", "json"],
    };
    match command_output(executable, args, Duration::from_secs(10)).await {
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

#[cfg(test)]
mod tests {
    use super::*;

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
}

use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use chrono::Utc;
use wait_timeout::ChildExt;

use crate::models::{Runtime, RuntimeKind};
use crate::store::Store;

pub fn detect(store: &Store) -> rusqlite::Result<Vec<Runtime>> {
    for kind in [RuntimeKind::Codex, RuntimeKind::Claude] {
        let existing = store.runtime(kind)?;
        let executable = discover(kind);
        let runtime = Runtime {
            kind,
            executable: executable.as_ref().map(|path| path.display().to_string()),
            version: existing.as_ref().and_then(|value| value.version.clone()),
            status: if executable.is_some() {
                "detected"
            } else {
                "missing"
            }
            .to_owned(),
            detected_at: Some(Utc::now().to_rfc3339()),
            verified_at: existing.and_then(|value| value.verified_at),
            verify_error: None,
        };
        store.save_runtime(&runtime)?;
    }
    store.runtimes()
}

pub fn verify(
    store: &Store,
    kind: RuntimeKind,
    explicit: Option<&str>,
) -> rusqlite::Result<Runtime> {
    let executable = explicit
        .map(PathBuf::from)
        .or_else(|| {
            store
                .runtime(kind)
                .ok()
                .flatten()
                .and_then(|value| value.executable.map(PathBuf::from))
        })
        .or_else(|| discover(kind));
    let now = Utc::now().to_rfc3339();
    let Some(executable) = executable else {
        let runtime = Runtime {
            kind,
            executable: None,
            version: None,
            status: "missing".to_owned(),
            detected_at: Some(now.clone()),
            verified_at: Some(now),
            verify_error: Some("executable not found".to_owned()),
        };
        store.save_runtime(&runtime)?;
        return Ok(runtime);
    };
    let absolute = fs::canonicalize(&executable).unwrap_or(executable);
    let validation = validate_executable(&absolute);
    let (status, version, verify_error) = match validation {
        Ok(version) => ("ready".to_owned(), Some(version), None),
        Err(error) => ("error".to_owned(), None, Some(error)),
    };
    let runtime = Runtime {
        kind,
        executable: Some(absolute.display().to_string()),
        version,
        status,
        detected_at: Some(now.clone()),
        verified_at: Some(now),
        verify_error,
    };
    store.save_runtime(&runtime)?;
    Ok(runtime)
}

fn discover(kind: RuntimeKind) -> Option<PathBuf> {
    let name = kind.as_str();
    search_directories()
        .into_iter()
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable(candidate))
        .and_then(|candidate| fs::canonicalize(&candidate).ok().or(Some(candidate)))
}

fn search_directories() -> Vec<PathBuf> {
    let mut directories = vec![
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/opt/homebrew/sbin"),
        PathBuf::from("/usr/local/bin"),
    ];
    if let Some(home) = dirs::home_dir() {
        directories.push(home.join(".local/bin"));
        directories.push(home.join(".bun/bin"));
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

fn validate_executable(path: &Path) -> Result<String, String> {
    if !path.is_absolute() || !is_executable(path) {
        return Err("path is not an executable file".to_owned());
    }
    let mut child = Command::new(path)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    match child
        .wait_timeout(Duration::from_secs(5))
        .map_err(|error| error.to_string())?
    {
        Some(status) if status.success() => {
            let output = child
                .wait_with_output()
                .map_err(|error| error.to_string())?;
            let version = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            if version.is_empty() {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
                if stderr.is_empty() {
                    Ok("unknown".to_owned())
                } else {
                    Ok(stderr)
                }
            } else {
                Ok(version)
            }
        }
        Some(status) => Err(format!("version command exited with {status}")),
        None => {
            let _ = child.kill();
            let _ = child.wait();
            Err("version command timed out".to_owned())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_a_non_executable_path() {
        assert!(validate_executable(Path::new("/definitely/missing/codex")).is_err());
    }
}

use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

fn wait_with_timeout(child: &mut Child, timeout: Duration) -> std::process::ExitStatus {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            let _ = child.wait();
            panic!("Engine did not exit within {timeout:?}");
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn second_engine_cannot_clean_descriptors_in_an_owned_data_directory() {
    let directory = tempfile::tempdir().unwrap();
    let data = directory.path().join("data");
    let logs = directory.path().join("logs");

    let mut owner = Command::new(env!("CARGO_BIN_EXE_todoagent-engine"))
        .env("TODOAGENT_NATIVE_DATA_DIR", &data)
        .env("TODOAGENT_NATIVE_LOG_DIR", &logs)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let mut handshake = String::new();
    BufReader::new(owner.stdout.as_mut().unwrap())
        .read_line(&mut handshake)
        .unwrap();
    let handshake: serde_json::Value = serde_json::from_str(&handshake).unwrap();
    assert_eq!(handshake["event"], "engine.ready");

    // This file is created only after the first Engine has completed its own
    // cleanup. A second Engine reaching cleanup would remove it.
    let descriptors = data.join("TerminalRuns");
    fs::create_dir(&descriptors).unwrap();
    fs::set_permissions(&descriptors, fs::Permissions::from_mode(0o700)).unwrap();
    let sentinel = descriptors.join("00000000-0000-4000-8000-000000000001.json");
    fs::write(&sentinel, b"{}\n").unwrap();
    fs::set_permissions(&sentinel, fs::Permissions::from_mode(0o600)).unwrap();

    let contender = Command::new(env!("CARGO_BIN_EXE_todoagent-engine"))
        .env("TODOAGENT_NATIVE_DATA_DIR", &data)
        .env(
            "TODOAGENT_NATIVE_LOG_DIR",
            directory.path().join("contender-logs"),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .unwrap();
    assert!(!contender.status.success());
    assert!(String::from_utf8_lossy(&contender.stderr).contains("already owned by another Engine"));
    assert!(
        sentinel.exists(),
        "a contender must fail before descriptor cleanup"
    );

    // Closing stdin drives the normal EOF shutdown path and releases the lock.
    drop(owner.stdin.take());
    assert!(wait_with_timeout(&mut owner, Duration::from_secs(5)).success());

    let mut successor = Command::new(env!("CARGO_BIN_EXE_todoagent-engine"))
        .env("TODOAGENT_NATIVE_DATA_DIR", &data)
        .env(
            "TODOAGENT_NATIVE_LOG_DIR",
            directory.path().join("successor-logs"),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(wait_with_timeout(&mut successor, Duration::from_secs(5)).success());
    assert!(
        !sentinel.exists(),
        "the successor should acquire ownership and perform stale cleanup"
    );
}

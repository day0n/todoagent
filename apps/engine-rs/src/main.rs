mod models;
mod protocol;
mod runtime;
mod store;

use std::fs;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;

use protocol::{Request, Response};
use serde::Deserialize;
use serde_json::{Value, json};
use store::Store;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateListParams {
    name: String,
    #[serde(default = "default_color")]
    color: String,
    repository_path: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateTaskParams {
    title: String,
    list_id: Option<String>,
    due_date: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetStatusParams {
    task_id: String,
    status: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerifyRuntimeParams {
    kind: String,
    executable: Option<String>,
}

fn default_color() -> String {
    "blue".to_owned()
}

fn main() {
    if let Err(error) = run() {
        eprintln!("TodoAgent Engine failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let data_directory = data_directory()?;
    fs::create_dir_all(&data_directory)?;
    fs::create_dir_all(data_directory.join("Attachments"))?;
    let store = Store::open(&data_directory.join("todoagent.sqlite3"))?;

    let stdout = io::stdout();
    let mut writer = stdout.lock();
    write_json_line(&mut writer, &protocol::handshake())?;

    for line in io::stdin().lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let request: Request = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                write_json_line(
                    &mut writer,
                    &json!({
                        "id": Value::Null,
                        "error": { "code": "invalid_request", "message": error.to_string() }
                    }),
                )?;
                continue;
            }
        };

        let shutdown = request.method == "engine.shutdown";
        let response = handle(&store, &request);
        write_json_line(&mut writer, &response)?;
        if request.method.starts_with("runtime.") {
            write_json_line(
                &mut writer,
                &protocol::Event {
                    event: "runtime.changed",
                    data: store.runtimes()?,
                },
            )?;
        } else if request.method.starts_with("task.") || request.method.starts_with("list.") {
            write_json_line(
                &mut writer,
                &protocol::Event {
                    event: "task.changed",
                    data: store.snapshot()?,
                },
            )?;
        }
        if shutdown {
            break;
        }
    }
    Ok(())
}

fn handle<'a>(store: &Store, request: &'a Request) -> Response<'a> {
    let result = match request.method.as_str() {
        "health" => store.health(),
        "app.snapshot" => store.snapshot().and_then(to_value),
        "list.create" => parse::<CreateListParams>(&request.params).and_then(|params| {
            validate_title(&params.name)?;
            store
                .create_list(
                    &params.name,
                    &params.color,
                    params.repository_path.as_deref(),
                )
                .and_then(to_value)
        }),
        "task.create" => parse::<CreateTaskParams>(&request.params).and_then(|params| {
            validate_title(&params.title)?;
            store
                .create_task(
                    &params.title,
                    params.list_id.as_deref(),
                    params.due_date.as_deref(),
                )
                .and_then(to_value)
        }),
        "task.set_status" => parse::<SetStatusParams>(&request.params).and_then(|params| {
            let status =
                models::TaskStatus::parse(&params.status).ok_or(rusqlite::Error::InvalidQuery)?;
            store
                .set_task_status(&params.task_id, status)
                .and_then(to_value)
        }),
        "runtime.detect" => runtime::detect(store).and_then(to_value),
        "runtime.verify" => parse::<VerifyRuntimeParams>(&request.params).and_then(|params| {
            let kind =
                models::RuntimeKind::parse(&params.kind).ok_or(rusqlite::Error::InvalidQuery)?;
            runtime::verify(store, kind, params.executable.as_deref()).and_then(to_value)
        }),
        "engine.shutdown" => Ok(json!({ "ok": true })),
        _ => {
            return Response::err(
                &request.id,
                "method_not_found",
                format!("unknown method {}", request.method),
            );
        }
    };

    match result {
        Ok(value) => Response::ok(&request.id, value),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            Response::err(&request.id, "not_found", "requested record does not exist")
        }
        Err(rusqlite::Error::InvalidQuery) => {
            Response::err(&request.id, "invalid_params", "parameters are invalid")
        }
        Err(error) => Response::err(&request.id, "engine_error", error.to_string()),
    }
}

fn parse<T: for<'de> Deserialize<'de>>(value: &Value) -> rusqlite::Result<T> {
    serde_json::from_value(value.clone()).map_err(|_| rusqlite::Error::InvalidQuery)
}

fn validate_title(title: &str) -> rusqlite::Result<()> {
    if title.trim().is_empty() || title.chars().count() > 500 {
        return Err(rusqlite::Error::InvalidQuery);
    }
    Ok(())
}

fn to_value<T: serde::Serialize>(value: T) -> rusqlite::Result<Value> {
    serde_json::to_value(value).map_err(|_| rusqlite::Error::InvalidQuery)
}

fn write_json_line(writer: &mut impl Write, value: &impl serde::Serialize) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, value)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

fn data_directory() -> io::Result<PathBuf> {
    if let Some(path) = std::env::var_os("TODOAGENT_NATIVE_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    let home = dirs::home_dir()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "home directory unavailable"))?;
    Ok(home
        .join("Library")
        .join("Application Support")
        .join("TodoAgent"))
}

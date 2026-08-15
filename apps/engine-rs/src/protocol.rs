use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 4;

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ProtocolError>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Event<T: Serialize> {
    pub event: &'static str,
    pub data: T,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Handshake {
    pub protocol_version: u32,
    pub engine_version: &'static str,
    pub capabilities: &'static [&'static str],
    pub runtimes: &'static [&'static str],
}

impl Response {
    pub fn ok(id: impl Into<String>, result: Value) -> Self {
        Self {
            id: id.into(),
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: impl Into<String>, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            result: None,
            error: Some(ProtocolError {
                code: code.into(),
                message: message.into(),
                details: None,
            }),
        }
    }
}

pub fn handshake() -> Event<Handshake> {
    Event {
        event: "engine.ready",
        data: Handshake {
            protocol_version: PROTOCOL_VERSION,
            engine_version: env!("CARGO_PKG_VERSION"),
            capabilities: &[
                "app.bootstrap",
                "app.sync",
                "list.create",
                "list.rename",
                "list.delete",
                "task.create",
                "task.update",
                "task.complete",
                "task.reopen",
                "task.create_list",
                "task.delete",
                "task.attachment.add",
                "task.attachment.remove",
                "runtime.list",
                "runtime.detect",
                "runtime.verify",
                "workspace.authorize",
                "secret.inject",
                "secret.clear",
                "gemini.test",
                "assistant.status",
                "assistant.session.list",
                "assistant.session.create",
                "assistant.session.rename",
                "assistant.session.archive",
                "assistant.history",
                "assistant.send",
                "assistant.cancel_turn",
                "terminal.session.create",
                "terminal.session.get",
                "terminal.session.rebind_workspace",
                "terminal.session.resume_candidates",
                "terminal.session.prepare_launch",
                "terminal.session.delete",
                "terminal.run.started",
                "terminal.run.stopping",
                "terminal.run.bind_provider",
                "terminal.run.report_status",
                "terminal.run.exited",
                "terminal.session.mark_seen",
                "engine.shutdown",
            ],
            runtimes: &["codex", "claude", "cursor", "kiro"],
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHARED_CONTRACT: &str = include_str!("../../../protocol/fixtures/contract.ndjson");

    #[test]
    fn request_defaults_params_to_null() {
        let request: Request =
            serde_json::from_str(r#"{"id":"1","method":"engine.health"}"#).unwrap();
        assert_eq!(request.id, "1");
        assert_eq!(request.params, Value::Null);
    }

    #[test]
    fn handshake_is_v4_and_lists_four_runtimes() {
        let value = serde_json::to_value(handshake()).unwrap();
        assert_eq!(value["data"]["protocolVersion"], 4);
        assert_eq!(value["data"]["runtimes"].as_array().unwrap().len(), 4);
        let capabilities = value["data"]["capabilities"].as_array().unwrap();
        assert!(capabilities.contains(&Value::String("list.rename".to_owned())));
        assert!(capabilities.contains(&Value::String("list.delete".to_owned())));
        assert!(capabilities.contains(&Value::String("task.create_list".to_owned())));
        assert!(capabilities.contains(&Value::String("task.delete".to_owned())));
        assert!(
            capabilities.contains(&Value::String("terminal.session.prepare_launch".to_owned()))
        );
        assert!(capabilities.contains(&Value::String("terminal.session.delete".to_owned())));
        assert!(capabilities.contains(&Value::String(
            "terminal.session.rebind_workspace".to_owned()
        )));
        assert!(capabilities.contains(&Value::String("terminal.run.stopping".to_owned())));
    }

    #[test]
    fn rust_decodes_every_shared_ndjson_contract_message() {
        let values = SHARED_CONTRACT
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();

        assert_eq!(values.len(), 29);
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("assistant.send")
        }));
        assert!(values.iter().any(|value| {
            value.get("event").and_then(Value::as_str) == Some("task.changed")
                && value["data"]["tasks"][0]["executionDate"] == "2026-08-11"
                && value["data"]["taskAttachments"][0]["relativePath"]
                    == "Attachments/abcdefab-cdef-4abc-8def-abcdefabc102.pdf"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("task.update")
                && value["params"]["taskId"] == "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABC101"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("task.create_list")
                && value["params"]["taskId"] == "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABC101"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("terminal.session.rebind_workspace")
                && value["params"]["sessionId"] == "00000000-0000-4000-8000-000000000301"
                && value["params"]["workingDirectory"] == "/tmp/rebound-project"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("terminal.session.prepare_launch")
                && value["params"]["intent"] == "fresh"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("terminal.run.bind_provider")
                && value["params"]["providerSessionId"] == "00000000-0000-4000-8000-000000000304"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("terminal.session.delete")
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("task.delete")
                && value["params"]["taskId"] == "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABC101"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("list.rename")
                && value["params"]["listId"] == "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABC105"
                && value["params"]["name"] == "重命名清单"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("list.delete")
                && value["params"]["listId"] == "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABC105"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("task.attachment.add")
                && value["params"]["clientMutationId"] == "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABC103"
        }));
        assert!(values.iter().any(|value| {
            value.get("method").and_then(Value::as_str) == Some("task.attachment.remove")
                && value["params"]["clientMutationId"] == "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABC104"
        }));
        assert!(values.iter().any(|value| {
            value.get("event").and_then(Value::as_str) == Some("assistant.message.delta")
                && value["data"]["attempt"] == 1
        }));
        assert!(values.iter().any(|value| {
            value.get("id").and_then(Value::as_str) == Some("assistant-history-1")
                && value["result"]["tools"][0]["taskRefsJson"].is_string()
                && value["result"]["activeTurn"].is_null()
        }));

        for value in values {
            if value.get("method").is_some() {
                serde_json::from_value::<Request>(value).unwrap();
            } else if value.get("id").is_some() {
                assert!(value.get("result").is_some() || value.get("error").is_some());
            } else {
                assert!(value.get("event").and_then(Value::as_str).is_some());
                assert!(value.get("data").is_some());
            }
        }
    }
}

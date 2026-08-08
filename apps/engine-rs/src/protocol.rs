use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 2;

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
                "task.create",
                "task.complete",
                "task.reopen",
                "runtime.list",
                "runtime.detect",
                "runtime.verify",
                "workspace.authorize",
                "secret.inject",
                "session.create",
                "session.get",
                "session.history",
                "session.send",
                "session.mark_read",
                "session.cancel_turn",
                "engine.shutdown",
            ],
            runtimes: &["codex", "claude", "cursor", "kiro"],
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_defaults_params_to_null() {
        let request: Request =
            serde_json::from_str(r#"{"id":"1","method":"engine.health"}"#).unwrap();
        assert_eq!(request.id, "1");
        assert_eq!(request.params, Value::Null);
    }

    #[test]
    fn handshake_is_v2_and_lists_four_runtimes() {
        let value = serde_json::to_value(handshake()).unwrap();
        assert_eq!(value["data"]["protocolVersion"], 2);
        assert_eq!(value["data"]["runtimes"].as_array().unwrap().len(), 4);
    }
}

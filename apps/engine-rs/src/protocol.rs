use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct Response<'a> {
    pub id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ProtocolError>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProtocolError {
    pub code: &'static str,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[derive(Debug, Serialize)]
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
}

impl<'a> Response<'a> {
    pub fn ok(id: &'a str, result: Value) -> Self {
        Self {
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: &'a str, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            id,
            result: None,
            error: Some(ProtocolError {
                code,
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
                "snapshot",
                "list.create",
                "task.create",
                "task.set_status",
                "runtime.detect",
                "runtime.verify",
                "engine.shutdown",
            ],
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_defaults_params_to_null() {
        let request: Request = serde_json::from_str(r#"{"id":"1","method":"health"}"#).unwrap();
        assert_eq!(request.id, "1");
        assert_eq!(request.params, Value::Null);
    }

    #[test]
    fn handshake_is_versioned() {
        let value = serde_json::to_value(handshake()).unwrap();
        assert_eq!(value["event"], "engine.ready");
        assert_eq!(value["data"]["protocolVersion"], PROTOCOL_VERSION);
    }

    #[test]
    fn shared_contract_fixture_is_valid_ndjson() {
        let fixture = include_str!("../../../protocol/fixtures/contract.ndjson");
        let values: Vec<Value> = fixture
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(values.len(), 4);
        assert_eq!(values[0]["data"]["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(values[1]["method"], "app.snapshot");
        assert_eq!(values[3]["error"]["code"], "not_found");
    }
}

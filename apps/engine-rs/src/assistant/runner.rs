use std::time::Duration;

use serde_json::{Value, json};
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;

use super::{
    AgentEvent, AgentRunRequest, AgentRunResult, AssembledStep, AssistantError, AssistantHost,
    ContextBuilder, HostError, InteractionProvider, InteractionRequest, PersistSteps,
    ProviderEvent, ProviderEventSink, RunLimitKind, RunLimits, ToolErrorKind, ToolReceipt,
    ToolRegistry, ToolRequest,
};

pub const DEFAULT_RUN_LIMITS: RunLimits = RunLimits {
    wall_time_seconds: 120,
    request_time_seconds: 45,
    max_model_interactions: 8,
    max_tool_calls: 32,
    max_network_retries: 2,
};

pub struct AgentRunner<P, H> {
    provider: P,
    host: H,
    context_builder: ContextBuilder,
    limits: RunLimits,
}

impl<P, H> AgentRunner<P, H>
where
    P: InteractionProvider,
    H: AssistantHost,
{
    pub fn new(provider: P, host: H) -> Self {
        Self {
            provider,
            host,
            context_builder: ContextBuilder::default(),
            limits: DEFAULT_RUN_LIMITS,
        }
    }

    pub fn with_context_builder(mut self, context_builder: ContextBuilder) -> Self {
        self.context_builder = context_builder;
        self
    }

    pub async fn run(
        &self,
        request: AgentRunRequest,
        cancellation: &CancellationToken,
    ) -> Result<AgentRunResult, AssistantError> {
        self.host.emit(
            &request.session_id,
            &request.turn_id,
            AgentEvent::Status {
                phase: "starting".to_owned(),
                detail: None,
            },
        );

        let local_cancellation = CancellationToken::new();
        let result = tokio::select! {
            _ = cancellation.cancelled() => {
                local_cancellation.cancel();
                Err(AssistantError::Cancelled)
            }
            result = timeout(
                Duration::from_secs(self.limits.wall_time_seconds),
                self.run_inner(&request, &local_cancellation),
            ) => match result {
                Ok(result) => result,
                Err(_) => {
                    local_cancellation.cancel();
                    Err(AssistantError::WallTimeout)
                }
            }
        };

        if let Err(error) = &result {
            let (code, message) = error_for_event(error);
            self.host.emit(
                &request.session_id,
                &request.turn_id,
                AgentEvent::Failed { code, message },
            );
        }
        result
    }

    async fn run_inner(
        &self,
        request: &AgentRunRequest,
        cancellation: &CancellationToken,
    ) -> Result<AgentRunResult, AssistantError> {
        let registry = ToolRegistry::new(request.tools.clone())?;
        let snapshot = self.host.load_context(&request.session_id).await?;
        let context_plan = self.context_builder.build(&snapshot, &request.input);
        let mut input = context_plan.input;
        let mut budget = RunBudget::new(self.limits);

        if let Some(compaction) = context_plan.compaction {
            budget.consume_interaction()?;
            self.host.emit(
                &request.session_id,
                &request.turn_id,
                AgentEvent::Status {
                    phase: "compacting".to_owned(),
                    detail: None,
                },
            );
            let kept_turns = compaction.turns_to_keep.clone();
            match self
                .host
                .compact_context(&request.session_id, compaction, cancellation)
                .await
            {
                Ok(compacted) if !compacted.summary.trim().is_empty() => {
                    input = self.context_builder.input_after_compaction(
                        &compacted.summary,
                        &kept_turns,
                        &request.input,
                    );
                }
                Ok(_) => {
                    self.host.emit(
                        &request.session_id,
                        &request.turn_id,
                        AgentEvent::Status {
                            phase: "compaction_failed".to_owned(),
                            detail: Some("summary was empty; old history retained".to_owned()),
                        },
                    );
                }
                Err(error) => {
                    self.host.emit(
                        &request.session_id,
                        &request.turn_id,
                        AgentEvent::Status {
                            phase: "compaction_failed".to_owned(),
                            detail: Some(error.message),
                        },
                    );
                }
            }
        }

        loop {
            if cancellation.is_cancelled() {
                return Err(AssistantError::Cancelled);
            }
            budget.consume_interaction()?;
            self.host.emit(
                &request.session_id,
                &request.turn_id,
                AgentEvent::Status {
                    phase: "model".to_owned(),
                    detail: Some(format!(
                        "interaction {}/{}",
                        budget.model_interactions, self.limits.max_model_interactions
                    )),
                },
            );

            let model_request = InteractionRequest {
                model: request.model.clone(),
                input: input.clone(),
                system_instruction: request.system_instruction.clone(),
                tools: registry.declarations().to_vec(),
            };
            let mut sink = HostSink {
                host: &self.host,
                session_id: &request.session_id,
                turn_id: &request.turn_id,
            };
            let response = self
                .provider
                .interact(&model_request, cancellation, &mut sink)
                .await?;

            // This is the commit boundary: the provider returned only after a
            // valid interaction.completed event and every step.stop. Truncated
            // attempts can emit ephemeral drafts but never reach this call.
            self.host
                .persist_steps(
                    &request.session_id,
                    &request.turn_id,
                    PersistSteps {
                        interaction_id: Some(response.interaction_id.clone()),
                        status: response.status.as_str().to_owned(),
                        steps: response.steps.clone(),
                        usage: response.usage.clone(),
                    },
                )
                .await?;

            input.extend(response.steps.iter().map(|step| step.payload.clone()));
            let calls = response
                .steps
                .iter()
                .filter_map(AssembledStep::function_call)
                .collect::<Vec<_>>();

            if calls.is_empty() {
                let final_text = response
                    .steps
                    .iter()
                    .map(AssembledStep::model_text)
                    .collect::<String>();
                if final_text.trim().is_empty() {
                    return Err(AssistantError::EmptyResponse);
                }
                self.host
                    .append_final(&request.session_id, &request.turn_id, final_text.trim())
                    .await?;
                self.host.emit(
                    &request.session_id,
                    &request.turn_id,
                    AgentEvent::Final {
                        text: final_text.clone(),
                    },
                );
                return Ok(AgentRunResult {
                    final_text,
                    model_interactions: budget.model_interactions,
                    tool_calls: budget.tool_calls,
                });
            }

            budget.consume_tools(calls.len())?;
            let mut delete_failed = false;
            let mut result_steps = Vec::with_capacity(calls.len());
            for call in calls {
                if cancellation.is_cancelled() {
                    return Err(AssistantError::Cancelled);
                }
                let is_delete_call = call.name == "delete_task";
                self.host.emit(
                    &request.session_id,
                    &request.turn_id,
                    AgentEvent::ToolStarted {
                        call_id: call.id.clone(),
                        name: call.name.clone(),
                    },
                );

                let receipt = if delete_failed && is_delete_call {
                    self.error_receipt(
                        request,
                        &call.id,
                        &call.name,
                        "delete_skipped_after_failure",
                        "an earlier delete_task call failed; no later delete calls were executed",
                    )
                    .await?
                } else if call.id.is_empty() || call.name.is_empty() {
                    self.error_receipt(
                        request,
                        &call.id,
                        &call.name,
                        "invalid_tool_call",
                        "function call is missing id or name",
                    )
                    .await?
                } else if !registry.contains(&call.name) {
                    self.error_receipt(
                        request,
                        &call.id,
                        &call.name,
                        "unknown_tool",
                        "the function is not in TodoAgent's declared tool registry",
                    )
                    .await?
                } else if let Some(error) = call.arguments_error.as_deref() {
                    self.error_receipt(request, &call.id, &call.name, "invalid_arguments", error)
                        .await?
                } else if !call.arguments.is_object() {
                    self.error_receipt(
                        request,
                        &call.id,
                        &call.name,
                        "invalid_arguments",
                        "function arguments must be an object",
                    )
                    .await?
                } else if let Some(receipt) = self
                    .host
                    .lookup_receipt(&request.session_id, &call.id)
                    .await?
                {
                    if receipt.call_id != call.id || receipt.name != call.name {
                        return Err(AssistantError::Host(HostError::new(
                            "invalid_tool_receipt",
                            "durable receipt belongs to a different tool call",
                        )));
                    }
                    if call.name == "delete_task" && !receipt.is_error {
                        let tool_request = ToolRequest {
                            session_id: request.session_id.clone(),
                            turn_id: request.turn_id.clone(),
                            call_id: call.id.clone(),
                            name: call.name.clone(),
                            arguments: call.arguments.clone(),
                        };
                        match self
                            .host
                            .execute_named_tool_once(tool_request, cancellation)
                            .await
                        {
                            Ok(receipt)
                                if receipt.call_id == call.id && receipt.name == call.name =>
                            {
                                receipt
                            }
                            Ok(_) => {
                                return Err(AssistantError::Host(HostError::new(
                                    "invalid_tool_receipt",
                                    "host returned a receipt for a different tool call",
                                )));
                            }
                            Err(error) if error.kind == ToolErrorKind::Cancelled => {
                                return Err(AssistantError::Cancelled);
                            }
                            Err(error) => {
                                return Err(AssistantError::Host(HostError::new(
                                    "invalid_tool_receipt",
                                    error.message,
                                )));
                            }
                        }
                    } else {
                        receipt
                    }
                } else {
                    let tool_request = ToolRequest {
                        session_id: request.session_id.clone(),
                        turn_id: request.turn_id.clone(),
                        call_id: call.id.clone(),
                        name: call.name.clone(),
                        arguments: call.arguments,
                    };
                    match self
                        .host
                        .execute_named_tool_once(tool_request, cancellation)
                        .await
                    {
                        Ok(receipt) if receipt.call_id == call.id && receipt.name == call.name => {
                            receipt
                        }
                        Ok(_) => {
                            return Err(AssistantError::Host(HostError::new(
                                "invalid_tool_receipt",
                                "host returned a receipt for a different tool call",
                            )));
                        }
                        Err(error) if error.kind == ToolErrorKind::Cancelled => {
                            return Err(AssistantError::Cancelled);
                        }
                        Err(error) => {
                            let code = match error.kind {
                                ToolErrorKind::UnknownTool => "unknown_tool",
                                ToolErrorKind::InvalidArguments => "invalid_arguments",
                                ToolErrorKind::Failed => "tool_failed",
                                ToolErrorKind::Cancelled => unreachable!(),
                            };
                            self.error_receipt(request, &call.id, &call.name, code, &error.message)
                                .await?
                        }
                    }
                };
                if is_delete_call && receipt.is_error {
                    delete_failed = true;
                }

                self.host.emit(
                    &request.session_id,
                    &request.turn_id,
                    AgentEvent::ToolFinished {
                        call_id: receipt.call_id.clone(),
                        name: receipt.name.clone(),
                        is_error: receipt.is_error,
                    },
                );
                result_steps.push(receipt.as_step());
            }

            self.host
                .persist_steps(
                    &request.session_id,
                    &request.turn_id,
                    PersistSteps {
                        interaction_id: None,
                        status: "tool_results".to_owned(),
                        steps: result_steps.clone(),
                        usage: Value::Null,
                    },
                )
                .await?;
            input.extend(result_steps.into_iter().map(|step| step.payload));
        }
    }

    async fn error_receipt(
        &self,
        request: &AgentRunRequest,
        call_id: &str,
        name: &str,
        code: &str,
        message: &str,
    ) -> Result<ToolReceipt, AssistantError> {
        let receipt = ToolReceipt {
            call_id: call_id.to_owned(),
            name: name.to_owned(),
            result: json!({"error": {"code": code, "message": message}}),
            is_error: true,
        };
        // A malformed provider call still needs an isError result so Gemini can
        // repair it, but either empty identity component would violate the
        // durable receipt key and must never be persisted.
        if call_id.is_empty() || name.is_empty() {
            return Ok(receipt);
        }
        if let Some(receipt) = self
            .host
            .lookup_receipt(&request.session_id, call_id)
            .await?
        {
            return Ok(receipt);
        }
        self.host
            .save_receipt(&request.session_id, &request.turn_id, &receipt)
            .await?;
        Ok(receipt)
    }
}

struct HostSink<'a, H> {
    host: &'a H,
    session_id: &'a str,
    turn_id: &'a str,
}

impl<H> ProviderEventSink for HostSink<'_, H>
where
    H: AssistantHost,
{
    fn on_event(&mut self, event: ProviderEvent) {
        match event {
            ProviderEvent::AttemptStarted { attempt } => {
                if attempt > 1 {
                    self.host.emit(
                        self.session_id,
                        self.turn_id,
                        AgentEvent::DraftReset {
                            attempt,
                            reason: "provider retry started".to_owned(),
                        },
                    );
                }
                self.host.emit(
                    self.session_id,
                    self.turn_id,
                    AgentEvent::Status {
                        phase: "request".to_owned(),
                        detail: Some(format!("attempt {attempt}")),
                    },
                );
            }
            ProviderEvent::AttemptDiscarded { attempt, reason } => self.host.emit(
                self.session_id,
                self.turn_id,
                AgentEvent::Status {
                    phase: "attempt_discarded".to_owned(),
                    detail: Some(format!("attempt {attempt}: {reason}")),
                },
            ),
            ProviderEvent::Retrying {
                next_attempt,
                delay_ms,
            } => self.host.emit(
                self.session_id,
                self.turn_id,
                AgentEvent::Status {
                    phase: "retrying".to_owned(),
                    detail: Some(format!("attempt {next_attempt} in {delay_ms}ms")),
                },
            ),
            ProviderEvent::TextDelta { attempt, text, .. } => self.host.emit(
                self.session_id,
                self.turn_id,
                AgentEvent::Delta { attempt, text },
            ),
            ProviderEvent::ThoughtSummaryDelta {
                attempt, content, ..
            } => self.host.emit(
                self.session_id,
                self.turn_id,
                AgentEvent::ThoughtSummary { attempt, content },
            ),
            ProviderEvent::StepStarted { .. }
            | ProviderEvent::ThoughtSignature { .. }
            | ProviderEvent::StepStopped { .. } => {}
        }
    }
}

struct RunBudget {
    limits: RunLimits,
    model_interactions: usize,
    tool_calls: usize,
}

impl RunBudget {
    fn new(limits: RunLimits) -> Self {
        Self {
            limits,
            model_interactions: 0,
            tool_calls: 0,
        }
    }

    fn consume_interaction(&mut self) -> Result<(), AssistantError> {
        if self.model_interactions >= self.limits.max_model_interactions {
            return Err(AssistantError::Limit {
                kind: RunLimitKind::ModelInteractions,
            });
        }
        self.model_interactions += 1;
        Ok(())
    }

    fn consume_tools(&mut self, count: usize) -> Result<(), AssistantError> {
        if self.tool_calls.saturating_add(count) > self.limits.max_tool_calls {
            return Err(AssistantError::Limit {
                kind: RunLimitKind::ToolCalls,
            });
        }
        self.tool_calls += count;
        Ok(())
    }
}

fn error_for_event(error: &AssistantError) -> (String, String) {
    let code = match error {
        AssistantError::Cancelled => "cancelled",
        AssistantError::WallTimeout => "wall_timeout",
        AssistantError::Limit {
            kind: RunLimitKind::ModelInteractions,
        } => "model_interaction_limit",
        AssistantError::Limit {
            kind: RunLimitKind::ToolCalls,
        } => "tool_call_limit",
        AssistantError::Host(_) => "host_error",
        AssistantError::Provider(_) => "provider_error",
        AssistantError::Registry(_) => "tool_registry_error",
        AssistantError::EmptyResponse => "empty_response",
    };
    (code.to_owned(), error.to_string())
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, VecDeque};
    use std::sync::Mutex;

    use super::*;
    use crate::assistant::{
        CompactionRequest, CompactionResult, ContextSnapshot, InteractionResponse, ProviderError,
        TerminalStatus, ToolError, ToolReceipt,
    };

    #[test]
    fn run_budget_enforces_model_and_tool_limits_before_work_starts() {
        let mut budget = RunBudget::new(RunLimits {
            wall_time_seconds: 120,
            request_time_seconds: 45,
            max_model_interactions: 2,
            max_tool_calls: 3,
            max_network_retries: 2,
        });

        assert!(budget.consume_interaction().is_ok());
        assert!(budget.consume_interaction().is_ok());
        assert!(matches!(
            budget.consume_interaction(),
            Err(AssistantError::Limit {
                kind: RunLimitKind::ModelInteractions
            })
        ));
        assert!(budget.consume_tools(2).is_ok());
        assert!(matches!(
            budget.consume_tools(2),
            Err(AssistantError::Limit {
                kind: RunLimitKind::ToolCalls
            })
        ));
        assert_eq!(
            budget.tool_calls, 2,
            "overflow batch must not partially execute"
        );
    }

    #[test]
    fn registry_rejects_every_tool_outside_the_six_explicit_names() {
        let bad = super::super::ToolDefinition::function(
            "bash",
            "must never be exposed",
            json!({"type":"object"}),
        );
        assert!(ToolRegistry::new(vec![bad]).is_err());
    }

    struct MockProvider {
        responses: Mutex<VecDeque<InteractionResponse>>,
        requests: Mutex<Vec<InteractionRequest>>,
    }

    impl InteractionProvider for MockProvider {
        async fn interact<'a>(
            &'a self,
            request: &'a InteractionRequest,
            _cancellation: &'a CancellationToken,
            sink: &'a mut dyn ProviderEventSink,
        ) -> Result<InteractionResponse, ProviderError> {
            self.requests.lock().unwrap().push(request.clone());
            sink.on_event(ProviderEvent::AttemptStarted { attempt: 1 });
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .ok_or_else(|| ProviderError::Protocol("fixture exhausted".to_owned()))
        }
    }

    #[derive(Default)]
    struct HostState {
        persisted: Vec<PersistSteps>,
        receipts: HashMap<String, ToolReceipt>,
        events: Vec<AgentEvent>,
        finals: Vec<String>,
        executions: usize,
        execution_names: Vec<String>,
    }

    #[derive(Default)]
    struct MockHost {
        state: Mutex<HostState>,
    }

    impl AssistantHost for MockHost {
        async fn load_context<'a>(
            &'a self,
            _session_id: &'a str,
        ) -> Result<ContextSnapshot, HostError> {
            Ok(ContextSnapshot::default())
        }

        async fn persist_steps<'a>(
            &'a self,
            _session_id: &'a str,
            _turn_id: &'a str,
            batch: PersistSteps,
        ) -> Result<(), HostError> {
            self.state.lock().unwrap().persisted.push(batch);
            Ok(())
        }

        async fn lookup_receipt<'a>(
            &'a self,
            _session_id: &'a str,
            call_id: &'a str,
        ) -> Result<Option<ToolReceipt>, HostError> {
            Ok(self.state.lock().unwrap().receipts.get(call_id).cloned())
        }

        async fn save_receipt<'a>(
            &'a self,
            _session_id: &'a str,
            _turn_id: &'a str,
            receipt: &'a ToolReceipt,
        ) -> Result<(), HostError> {
            self.state
                .lock()
                .unwrap()
                .receipts
                .insert(receipt.call_id.clone(), receipt.clone());
            Ok(())
        }

        async fn execute_named_tool_once<'a>(
            &'a self,
            request: ToolRequest,
            _cancellation: &'a CancellationToken,
        ) -> Result<ToolReceipt, ToolError> {
            let mut state = self.state.lock().unwrap();
            state.executions += 1;
            state.execution_names.push(request.name.clone());
            let receipt = ToolReceipt {
                call_id: request.call_id,
                name: request.name,
                result: json!({"ok":true}),
                is_error: false,
            };
            state
                .receipts
                .insert(receipt.call_id.clone(), receipt.clone());
            Ok(receipt)
        }

        async fn append_final<'a>(
            &'a self,
            _session_id: &'a str,
            _turn_id: &'a str,
            text: &'a str,
        ) -> Result<(), HostError> {
            self.state.lock().unwrap().finals.push(text.to_owned());
            Ok(())
        }

        async fn compact_context<'a>(
            &'a self,
            _session_id: &'a str,
            _request: CompactionRequest,
            _cancellation: &'a CancellationToken,
        ) -> Result<CompactionResult, HostError> {
            Err(HostError::new("not_needed", "fixture does not compact"))
        }

        fn emit(&self, _session_id: &str, _turn_id: &str, event: AgentEvent) {
            self.state.lock().unwrap().events.push(event);
        }
    }

    fn interaction(id: &str, status: TerminalStatus, payloads: Vec<Value>) -> InteractionResponse {
        InteractionResponse {
            interaction_id: id.to_owned(),
            status,
            steps: payloads
                .into_iter()
                .map(AssembledStep::from_payload)
                .collect(),
            usage: json!({"total_tokens":10}),
            interaction: json!({"id":id,"status":status.as_str()}),
        }
    }

    #[tokio::test]
    async fn completed_terminal_function_calls_execute_once_and_round_trip_results() {
        let calls = [
            (
                "call-create",
                "create_tasks",
                json!({"tasks":[{"title":"今天要健身"}]}),
            ),
            ("call-find", "find_related", json!({"query":"今天要健身"})),
            (
                "call-update",
                "update_task",
                json!({"taskId":"task-1","update":{"note":"晚上去"}}),
            ),
            ("call-state", "list_state", json!({})),
            ("call-lists", "list_lists", json!({})),
        ];
        let first_steps = calls
            .iter()
            .map(|(call_id, name, arguments)| {
                json!({
                    "type":"function_call",
                    "id":call_id,
                    "name":name,
                    "arguments":arguments,
                })
            })
            .collect::<Vec<_>>();
        let provider = MockProvider {
            responses: Mutex::new(VecDeque::from([
                interaction("i-tools", TerminalStatus::Completed, first_steps),
                interaction(
                    "i-final",
                    TerminalStatus::Completed,
                    vec![json!({
                        "type":"model_output",
                        "content":[{"type":"text","text":"五个工具均已处理"}],
                    })],
                ),
            ])),
            requests: Mutex::new(Vec::new()),
        };
        let host = MockHost::default();
        let runner = AgentRunner::new(provider, host);
        let mut request =
            AgentRunRequest::text("s-tools", "t-tools", "gemini-test", "测试全部工具");
        request.tools = calls
            .iter()
            .map(|(_, name, _)| {
                super::super::ToolDefinition::function(
                    *name,
                    format!("test {name}"),
                    json!({"type":"object"}),
                )
            })
            .collect();

        let result = runner
            .run(request, &CancellationToken::new())
            .await
            .unwrap();
        let state = runner.host.state.lock().unwrap();

        assert_eq!(result.final_text, "五个工具均已处理");
        assert_eq!(result.model_interactions, 2);
        assert_eq!(result.tool_calls, calls.len());
        assert_eq!(state.executions, calls.len());
        assert_eq!(
            state.execution_names,
            calls
                .iter()
                .map(|(_, name, _)| (*name).to_owned())
                .collect::<Vec<_>>()
        );
        assert_eq!(state.receipts.len(), calls.len());
        assert_eq!(state.persisted.len(), 3);
        assert_eq!(state.persisted[0].status, "completed");
        assert_eq!(state.persisted[1].status, "tool_results");
        assert_eq!(state.persisted[1].steps.len(), calls.len());
        assert_eq!(state.persisted[2].status, "completed");
        assert_eq!(state.finals, ["五个工具均已处理"]);

        for (call_id, name, _) in &calls {
            assert!(state.receipts.contains_key(*call_id));
            let result_step = state.persisted[1]
                .steps
                .iter()
                .find(|step| step.payload["call_id"] == *call_id)
                .unwrap();
            assert_eq!(result_step.payload["type"], "function_result");
            assert_eq!(result_step.payload["name"], *name);
            assert_eq!(result_step.payload["is_error"], false);
            assert_eq!(result_step.payload["result"], json!({"ok":true}));
        }

        drop(state);
        let requests = runner.provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        let follow_up_input = &requests[1].input;
        for (call_id, name, _) in &calls {
            let call_index = follow_up_input
                .iter()
                .position(|step| {
                    step["type"] == "function_call"
                        && step["id"] == *call_id
                        && step["name"] == *name
                })
                .unwrap();
            let result_index = follow_up_input
                .iter()
                .position(|step| {
                    step["type"] == "function_result"
                        && step["call_id"] == *call_id
                        && step["name"] == *name
                })
                .unwrap();
            assert!(call_index < result_index);
        }
    }

    #[tokio::test]
    async fn successful_delete_receipts_reenter_the_host_for_argument_validation() {
        let provider = MockProvider {
            responses: Mutex::new(VecDeque::from([
                interaction(
                    "delete-call",
                    TerminalStatus::Completed,
                    vec![json!({
                        "type":"function_call",
                        "id":"delete-1",
                        "name":"delete_task",
                        "arguments":{"taskId":"00000000-0000-0000-0000-000000000001"}
                    })],
                ),
                interaction(
                    "delete-final",
                    TerminalStatus::Completed,
                    vec![json!({
                        "type":"model_output",
                        "content":[{"type":"text","text":"已删除"}]
                    })],
                ),
            ])),
            requests: Mutex::new(Vec::new()),
        };
        let host = MockHost::default();
        host.state.lock().unwrap().receipts.insert(
            "delete-1".to_owned(),
            ToolReceipt {
                call_id: "delete-1".to_owned(),
                name: "delete_task".to_owned(),
                result: json!({"deletedTask":{"id":"00000000-0000-0000-0000-000000000001"}}),
                is_error: false,
            },
        );
        let runner = AgentRunner::new(provider, host);
        let mut request = AgentRunRequest::text("session", "turn", "model", "删除任务");
        request.tools = vec![super::super::ToolDefinition::function(
            "delete_task",
            "delete",
            json!({"type":"object"}),
        )];

        let result = runner
            .run(request, &CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(result.final_text, "已删除");
        assert_eq!(runner.host.state.lock().unwrap().executions, 1);
    }

    #[tokio::test]
    async fn a_failed_delete_skips_later_deletes_in_the_same_model_batch() {
        let provider = MockProvider {
            responses: Mutex::new(VecDeque::from([
                interaction(
                    "delete-batch",
                    TerminalStatus::Completed,
                    vec![
                        json!({
                            "type":"function_call",
                            "id":"delete-failed",
                            "name":"delete_task",
                            "arguments":{"taskId":"00000000-0000-0000-0000-000000000001"}
                        }),
                        json!({
                            "type":"function_call",
                            "id":"delete-must-skip",
                            "name":"delete_task",
                            "arguments":{"taskId":"00000000-0000-0000-0000-000000000002"}
                        }),
                    ],
                ),
                interaction(
                    "delete-summary",
                    TerminalStatus::Completed,
                    vec![json!({
                        "type":"model_output",
                        "content":[{"type":"text","text":"第一个删除失败，后续未执行"}]
                    })],
                ),
            ])),
            requests: Mutex::new(Vec::new()),
        };
        let host = MockHost::default();
        host.state.lock().unwrap().receipts.insert(
            "delete-failed".to_owned(),
            ToolReceipt {
                call_id: "delete-failed".to_owned(),
                name: "delete_task".to_owned(),
                result: json!({"error":{"code":"task_session_active"}}),
                is_error: true,
            },
        );
        let runner = AgentRunner::new(provider, host);
        let mut request = AgentRunRequest::text("session", "turn", "model", "删除两个任务");
        request.tools = vec![super::super::ToolDefinition::function(
            "delete_task",
            "delete",
            json!({"type":"object"}),
        )];

        let result = runner
            .run(request, &CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(result.final_text, "第一个删除失败，后续未执行");
        let state = runner.host.state.lock().unwrap();
        assert_eq!(state.executions, 0);
        let skipped = state.receipts.get("delete-must-skip").unwrap();
        assert!(skipped.is_error);
        assert_eq!(
            skipped.result["error"]["code"],
            "delete_skipped_after_failure"
        );
    }

    #[tokio::test]
    async fn durable_receipt_for_a_different_tool_name_is_rejected() {
        let provider = MockProvider {
            responses: Mutex::new(VecDeque::from([interaction(
                "mismatch",
                TerminalStatus::Completed,
                vec![json!({
                    "type":"function_call",
                    "id":"reused-call",
                    "name":"create_tasks",
                    "arguments":{"tasks":[{"title":"不能执行"}]}
                })],
            )])),
            requests: Mutex::new(Vec::new()),
        };
        let host = MockHost::default();
        host.state.lock().unwrap().receipts.insert(
            "reused-call".to_owned(),
            ToolReceipt {
                call_id: "reused-call".to_owned(),
                name: "update_task".to_owned(),
                result: json!({"ok":true}),
                is_error: false,
            },
        );
        let runner = AgentRunner::new(provider, host);
        let mut request = AgentRunRequest::text("session", "turn", "model", "创建任务");
        request.tools = vec![super::super::ToolDefinition::function(
            "create_tasks",
            "create",
            json!({"type":"object"}),
        )];

        let error = runner
            .run(request, &CancellationToken::new())
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            AssistantError::Host(HostError { ref code, .. }) if code == "invalid_tool_receipt"
        ));
        assert_eq!(runner.host.state.lock().unwrap().executions, 0);
    }

    #[tokio::test]
    async fn unknown_and_bad_arguments_become_durable_error_results() {
        let provider = MockProvider {
            responses: Mutex::new(VecDeque::from([
                interaction(
                    "i1",
                    TerminalStatus::RequiresAction,
                    vec![
                        json!({"type":"function_call","id":"c1","name":"bash","arguments":{}}),
                        json!({"type":"function_call","id":"c2","name":"create_tasks","arguments":"{bad"}),
                    ],
                ),
                interaction(
                    "i2",
                    TerminalStatus::Completed,
                    vec![json!({
                        "type":"model_output",
                        "content":[{"type":"text","text":"已处理"}],
                    })],
                ),
            ])),
            requests: Mutex::new(Vec::new()),
        };
        let host = MockHost::default();
        let runner = AgentRunner::new(provider, host);
        let mut request = AgentRunRequest::text("s1", "t1", "gemini-test", "帮我建任务");
        request.tools = vec![super::super::ToolDefinition::function(
            "create_tasks",
            "create task cards",
            json!({"type":"object"}),
        )];

        let result = runner
            .run(request, &CancellationToken::new())
            .await
            .unwrap();
        let state = runner.host.state.lock().unwrap();

        assert_eq!(result.final_text, "已处理");
        assert_eq!(
            state.executions, 0,
            "invalid calls must never reach Store tools"
        );
        assert!(state.receipts["c1"].is_error);
        assert!(state.receipts["c2"].is_error);
        assert_eq!(state.persisted.len(), 3);
        assert_eq!(state.persisted[1].status, "tool_results");
        assert!(
            state.persisted[1].steps.iter().all(|step| {
                step.payload.get("is_error").and_then(Value::as_bool) == Some(true)
            })
        );
    }

    #[tokio::test]
    async fn a_function_call_without_a_name_is_returned_but_not_persisted_as_a_receipt() {
        let provider = MockProvider {
            responses: Mutex::new(VecDeque::from([
                interaction(
                    "i1",
                    TerminalStatus::RequiresAction,
                    vec![json!({"type":"function_call","id":"c-missing-name","arguments":{}})],
                ),
                interaction(
                    "i2",
                    TerminalStatus::Completed,
                    vec![json!({
                        "type":"model_output",
                        "content":[{"type":"text","text":"已修正"}],
                    })],
                ),
            ])),
            requests: Mutex::new(Vec::new()),
        };
        let host = MockHost::default();
        let runner = AgentRunner::new(provider, host);
        let mut request = AgentRunRequest::text("s1", "t1", "gemini-test", "整理任务");
        request.tools = vec![super::super::ToolDefinition::function(
            "create_tasks",
            "create task cards",
            json!({"type":"object"}),
        )];

        let result = runner
            .run(request, &CancellationToken::new())
            .await
            .unwrap();
        let state = runner.host.state.lock().unwrap();

        assert_eq!(result.final_text, "已修正");
        assert!(state.receipts.is_empty());
        assert_eq!(state.persisted[1].steps.len(), 1);
        assert_eq!(
            state.persisted[1].steps[0]
                .payload
                .get("is_error")
                .and_then(Value::as_bool),
            Some(true)
        );
    }
}

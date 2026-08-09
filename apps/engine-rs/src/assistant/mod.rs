//! A small, host-agnostic assistant kernel.
//!
//! The kernel deliberately owns only model orchestration. Database access, task
//! mutations and UI events stay behind [`AssistantHost`], so the engine can wire
//! it to SQLite without coupling provider code to the store implementation.

mod context;
mod provider;
mod runner;
mod types;

#[allow(unused_imports)]
pub use context::{ContextBuilder, ContextBuilderConfig, estimate_tokens};
#[allow(unused_imports)]
pub use provider::{
    GeminiInteractionsProvider, InteractionsSseAssembler, ProviderError, RetryClass,
};
#[allow(unused_imports)]
pub use runner::{AgentRunner, DEFAULT_RUN_LIMITS};
#[allow(unused_imports)]
pub use types::{
    ALLOWED_ASSISTANT_TOOLS, AgentEvent, AgentRunRequest, AgentRunResult, AssembledStep,
    AssistantError, AssistantHost, CompactionRequest, CompactionResult, ContextPlan,
    ContextSnapshot, FunctionCall, HostError, InteractionProvider, InteractionRequest,
    InteractionResponse, PersistSteps, ProviderEvent, ProviderEventSink, RunLimitKind, RunLimits,
    StoredTurn, TerminalStatus, ToolDefinition, ToolError, ToolErrorKind, ToolReceipt,
    ToolRegistry, ToolRegistryError, ToolRequest,
};

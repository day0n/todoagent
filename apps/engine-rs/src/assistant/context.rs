use std::collections::HashSet;

use serde_json::{Value, json};

use super::{CompactionRequest, ContextPlan, ContextSnapshot, StoredTurn};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ContextBuilderConfig {
    pub context_window_tokens: usize,
    pub reserve_tokens: usize,
    pub keep_recent_tokens: usize,
}

impl Default for ContextBuilderConfig {
    fn default() -> Self {
        Self {
            context_window_tokens: 128_000,
            reserve_tokens: 16_384,
            keep_recent_tokens: 20_000,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ContextBuilder {
    config: ContextBuilderConfig,
}

impl Default for ContextBuilder {
    fn default() -> Self {
        Self::new(ContextBuilderConfig::default())
    }
}

impl ContextBuilder {
    pub fn new(config: ContextBuilderConfig) -> Self {
        Self { config }
    }

    /// Build stateless Interactions input and, when necessary, a safe
    /// compaction request. The current user input is never summarized.
    pub fn build(&self, snapshot: &ContextSnapshot, current_input: &[Value]) -> ContextPlan {
        let input = flatten(snapshot.summary.as_deref(), &snapshot.turns, current_input);
        let estimated_tokens = estimate_tokens(&Value::Array(input.clone()));
        let threshold = self
            .config
            .context_window_tokens
            .saturating_sub(self.config.reserve_tokens);

        if estimated_tokens <= threshold || snapshot.turns.is_empty() {
            return ContextPlan {
                input,
                estimated_tokens,
                compaction: None,
            };
        }

        let current_tokens = estimate_tokens(&Value::Array(current_input.to_vec()));
        let mut kept_tokens = current_tokens;
        let mut keep_from = snapshot.turns.len();
        while keep_from > 0 {
            let turn_tokens = estimate_turn(&snapshot.turns[keep_from - 1]);
            if kept_tokens.saturating_add(turn_tokens) > self.config.keep_recent_tokens {
                break;
            }
            keep_from -= 1;
            kept_tokens = kept_tokens.saturating_add(turn_tokens);
        }

        // Never place a function call on one side of the summary boundary and
        // its result on the other. Move the boundary backwards until it is safe.
        while keep_from > 0 && !safe_boundary(&snapshot.turns, keep_from) {
            keep_from -= 1;
        }

        // Nothing can be summarized safely. Keep the old context intact; the
        // caller may surface the provider's context-window error without losing
        // history.
        if keep_from == 0 {
            return ContextPlan {
                input,
                estimated_tokens,
                compaction: None,
            };
        }

        ContextPlan {
            input,
            estimated_tokens,
            compaction: Some(CompactionRequest {
                previous_summary: snapshot.summary.clone(),
                turns_to_summarize: snapshot.turns[..keep_from].to_vec(),
                turns_to_keep: snapshot.turns[keep_from..].to_vec(),
                target_tokens: self.config.keep_recent_tokens,
            }),
        }
    }

    pub fn input_after_compaction(
        &self,
        summary: &str,
        kept_turns: &[StoredTurn],
        current_input: &[Value],
    ) -> Vec<Value> {
        flatten(Some(summary), kept_turns, current_input)
    }
}

/// A conservative local estimate used only to decide when to compact. Actual
/// provider usage, when available, should be persisted by the host and can
/// replace this estimate in a later implementation.
pub fn estimate_tokens(value: &Value) -> usize {
    let serialized = serde_json::to_string(value).unwrap_or_default();
    let (ascii, non_ascii) = serialized
        .chars()
        .fold((0usize, 0usize), |counts, character| {
            if character.is_ascii() {
                (counts.0 + 1, counts.1)
            } else {
                (counts.0, counts.1 + 1)
            }
        });
    // English/code averages roughly four bytes per token, while CJK and other
    // non-ASCII text is much denser. JSON punctuation is already included in
    // the ASCII side, making this deliberately conservative for compaction.
    ascii.div_ceil(4).saturating_add(non_ascii).max(1)
}

fn estimate_turn(turn: &StoredTurn) -> usize {
    estimate_tokens(&Value::Array(turn.steps.clone()))
}

fn flatten(summary: Option<&str>, turns: &[StoredTurn], current_input: &[Value]) -> Vec<Value> {
    let mut input = Vec::new();
    if let Some(summary) = summary.filter(|summary| !summary.trim().is_empty()) {
        input.push(json!({
            "type": "user_input",
            "content": [{
                "type": "text",
                "text": format!("以下是此前对话的压缩摘要，请视为历史上下文：\n\n{summary}"),
            }],
        }));
    }
    for turn in turns {
        input.extend(turn.steps.iter().cloned());
    }
    input.extend(current_input.iter().cloned());
    input
}

fn safe_boundary(turns: &[StoredTurn], keep_from: usize) -> bool {
    let (prefix, kept) = turns.split_at(keep_from);
    let prefix_pairs = pair_ids(prefix);
    let kept_pairs = pair_ids(kept);

    prefix_pairs.calls.is_disjoint(&kept_pairs.results)
        && kept_pairs.calls.is_disjoint(&prefix_pairs.results)
}

#[derive(Default)]
struct PairIds {
    calls: HashSet<String>,
    results: HashSet<String>,
}

fn pair_ids(turns: &[StoredTurn]) -> PairIds {
    let mut ids = PairIds::default();
    for step in turns.iter().flat_map(|turn| &turn.steps) {
        match step.get("type").and_then(Value::as_str) {
            Some("function_call") => {
                if let Some(id) = step.get("id").and_then(Value::as_str) {
                    ids.calls.insert(id.to_owned());
                }
            }
            Some("function_result") => {
                if let Some(id) = step.get("call_id").and_then(Value::as_str) {
                    ids.results.insert(id.to_owned());
                }
            }
            _ => {}
        }
    }
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(id: &str, steps: Vec<Value>) -> StoredTurn {
        StoredTurn {
            turn_id: id.to_owned(),
            steps,
        }
    }

    #[test]
    fn compaction_moves_boundary_to_keep_call_and_result_together() {
        let old_text = "旧历史".repeat(120);
        let recent_text = "最近".repeat(20);
        let snapshot = ContextSnapshot {
            summary: Some("更早摘要".to_owned()),
            turns: vec![
                turn(
                    "old",
                    vec![
                        json!({"type":"model_output","content":[{"type":"text","text":old_text}]}),
                    ],
                ),
                turn(
                    "call",
                    vec![
                        json!({"type":"function_call","id":"call-1","name":"list_state","arguments":{}}),
                    ],
                ),
                turn(
                    "result",
                    vec![
                        json!({"type":"function_result","call_id":"call-1","name":"list_state","result":{}}),
                    ],
                ),
                turn(
                    "recent",
                    vec![
                        json!({"type":"model_output","content":[{"type":"text","text":recent_text}]}),
                    ],
                ),
            ],
        };
        let builder = ContextBuilder::new(ContextBuilderConfig {
            context_window_tokens: 220,
            reserve_tokens: 10,
            keep_recent_tokens: 140,
        });

        let plan = builder.build(
            &snapshot,
            &[json!({"type":"user_input","content":[{"type":"text","text":"继续"}]})],
        );
        let compaction = plan.compaction.expect("history should require compaction");

        assert_eq!(
            compaction
                .turns_to_summarize
                .iter()
                .map(|turn| turn.turn_id.as_str())
                .collect::<Vec<_>>(),
            vec!["old"]
        );
        assert_eq!(
            compaction
                .turns_to_keep
                .iter()
                .map(|turn| turn.turn_id.as_str())
                .collect::<Vec<_>>(),
            vec!["call", "result", "recent"]
        );
    }

    #[test]
    fn summarizing_a_complete_call_result_pair_keeps_old_input_until_success() {
        let snapshot = ContextSnapshot {
            summary: None,
            turns: vec![
                turn(
                    "call",
                    vec![json!({"type":"function_call","id":"cross","name":"x","arguments":{}})],
                ),
                turn(
                    "result",
                    vec![json!({"type":"function_result","call_id":"cross","result":"ok"})],
                ),
            ],
        };
        let current = vec![json!({"type":"user_input","content":[{"type":"text","text":"x"}]})];
        let builder = ContextBuilder::new(ContextBuilderConfig {
            context_window_tokens: 10,
            reserve_tokens: 1,
            keep_recent_tokens: 1,
        });
        let plan = builder.build(&snapshot, &current);

        let compaction = plan
            .compaction
            .expect("the complete pair is safe to summarize");
        assert_eq!(compaction.turns_to_summarize.len(), 2);
        assert!(compaction.turns_to_keep.is_empty());
        assert_eq!(plan.input, flatten(None, &snapshot.turns, &current));
    }

    #[test]
    fn large_chinese_history_is_not_underestimated_before_compaction() {
        let old_text = "这是需要完整保留的中文任务上下文。".repeat(18);
        let recent_text = "这是最近一轮中文对话。".repeat(12);
        let snapshot = ContextSnapshot {
            summary: None,
            turns: vec![
                turn(
                    "old-chinese",
                    vec![
                        json!({"type":"model_output","content":[{"type":"text","text":old_text}]}),
                    ],
                ),
                turn(
                    "recent-chinese",
                    vec![
                        json!({"type":"model_output","content":[{"type":"text","text":recent_text}]}),
                    ],
                ),
            ],
        };
        let builder = ContextBuilder::new(ContextBuilderConfig {
            context_window_tokens: 500,
            reserve_tokens: 50,
            keep_recent_tokens: 300,
        });
        let current = json!({"type":"user_input","content":[{"type":"text","text":"继续处理"}]});

        assert!(estimate_tokens(&json!("中文字符".repeat(100))) >= 400);
        let plan = builder.build(&snapshot, &[current]);
        let compaction = plan
            .compaction
            .expect("dense Chinese history should trigger compaction");
        assert_eq!(compaction.turns_to_summarize[0].turn_id, "old-chinese");
        assert_eq!(compaction.turns_to_keep[0].turn_id, "recent-chinese");
    }

    #[test]
    fn one_oversized_complete_turn_can_be_summarized_at_its_boundary() {
        let snapshot = ContextSnapshot {
            summary: None,
            turns: vec![turn(
                "oversized",
                vec![json!({
                    "type":"model_output",
                    "content":[{"type":"text","text":"很长的历史".repeat(500)}]
                })],
            )],
        };
        let builder = ContextBuilder::new(ContextBuilderConfig {
            context_window_tokens: 300,
            reserve_tokens: 50,
            keep_recent_tokens: 100,
        });

        let plan = builder.build(
            &snapshot,
            &[json!({"type":"user_input","content":[{"type":"text","text":"继续"}]})],
        );
        let compaction = plan
            .compaction
            .expect("a complete old turn is a safe compaction boundary");

        assert_eq!(compaction.turns_to_summarize[0].turn_id, "oversized");
        assert!(compaction.turns_to_keep.is_empty());
    }
}

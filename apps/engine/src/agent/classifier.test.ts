import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyHeuristic, classifyOutcome } from "./classifier.ts";

/**
 * Outcome classification, both layers.
 *
 * The heuristic is tested directly because it is a pure function AND because it is
 * the configuration the milestone requires to work: with no `TODOAGENT_MODEL` the
 * whole product must still route a question to 需要你. Every rule below is pinned
 * rather than described, since "ends with a question" is exactly the kind of
 * judgement that drifts silently when someone tunes it later.
 *
 * The model layer is driven through an injected `resolve`, so these tests exercise
 * the real parse/retry/timeout logic without an LLM and without touching the
 * environment. The end-to-end path (a real run, a real card moving) is covered in
 * `outcome.test.ts` against a stub CLI.
 */

// ── Heuristic ───────────────────────────────────────────────

test("a short closing question is a question", () => {
  const out = classifyHeuristic("我把 parser 重写了。\n\n数据库用 postgres 还是 sqlite？");
  assert.equal(out.kind, "question");
  assert.equal(out.text, "数据库用 postgres 还是 sqlite？");
  assert.equal(out.via, "heuristic");
});

test("an ASCII question mark counts too", () => {
  // Workers switch between full-width and ASCII punctuation freely, often mid-output.
  assert.equal(classifyHeuristic("Done.\n\nShould I also update the tests?").kind, "question");
});

test("ordinary completion is done, and carries no text", () => {
  const out = classifyHeuristic("改完了。app.ts 的返回值换成 new，并加了一行注释。");
  assert.equal(out.kind, "done");
  assert.equal(out.text, "", "a done card must not park text it would never show");
});

test("a question mark buried in a long paragraph is not a question", () => {
  /*
   * The rule that stops false positives. A long final paragraph containing `?` is
   * usually code, a quoted error, or rhetorical narration — and parking a finished
   * task in 需要你 interrupts a person to show them nothing is wrong.
   */
  const long = `${"我检查了整个调用链，确认没有其他地方读这个字段。".repeat(20)}顺带一提，a?b:c 这种三元表达式我保留了原样。`;
  assert.ok(long.length > 400, `fixture must exceed the cap, was ${long.length}`);
  assert.equal(classifyHeuristic(long).kind, "done");
});

test("a question in an EARLIER paragraph does not count", () => {
  // Only the last paragraph is the ask. A worker that wondered aloud mid-way and
  // then finished has finished.
  const out = classifyHeuristic("要不要顺便升级依赖？\n\n算了，我自己判断了：没升，风险太大。已完成。");
  assert.equal(out.kind, "done");
});

test("trailing blank lines do not hide the question", () => {
  // Adapters hand over whatever the CLI printed, trailing newlines included.
  const out = classifyHeuristic("好了。\n\n需要我删掉旧文件吗？\n\n\n   \n");
  assert.equal(out.kind, "question");
  assert.equal(out.text, "需要我删掉旧文件吗？");
});

test("empty and whitespace-only output is done", () => {
  // A run that completed with no final text is the M0 `done` case, not a mystery.
  for (const input of ["", "   ", "\n\n\t\n"]) {
    assert.equal(classifyHeuristic(input).kind, "done", JSON.stringify(input));
  }
});

test("the heuristic never returns blocked", () => {
  /*
   * Pinned deliberately. There is no textual signal for "I gave up" that is not also
   * present in ordinary narration — "I couldn't find the config so I used defaults"
   * describes a COMPLETED task. Only a model may return blocked.
   */
  const looksBlocked = [
    "我没有权限读那个文件，停下了。",
    "缺少 API key，无法继续。",
    "blocked: cannot proceed without credentials",
  ];
  for (const text of looksBlocked) {
    assert.notEqual(classifyHeuristic(text).kind, "blocked", text);
  }
});

test("needsText is capped", () => {
  // 400 chars of question is within the paragraph cap but still longer than a card
  // subtitle should carry.
  const q = `${"要不要改这个？".repeat(50)}?`;
  const out = classifyHeuristic(q);
  if (out.kind === "question") assert.ok(out.text.length <= 500, `was ${out.text.length}`);
});

// ── Model layer, driven without an LLM ──────────────────────

/** A fake `resolve` whose runtime replies with whatever the script says. */
function fakeModel(replies: string[]): {
  resolve: () => Promise<{ ok: true; resolved: never }>;
  calls: () => number;
} {
  let calls = 0;
  const runtime = {
    complete: async () => {
      const reply = replies[calls] ?? replies[replies.length - 1] ?? "";
      calls += 1;
      return { content: [{ type: "text", text: reply }] };
    },
  };
  return {
    // The shape `classifyOutcome` actually touches: `resolved.runtime.complete`
    // and `resolved.model`. Cast because a real ResolvedModel carries the entire
    // pi-ai Models surface, none of which this path uses.
    resolve: async () =>
      ({ ok: true, resolved: { runtime, model: { provider: "fake", id: "m" }, spec: "fake/m" } }) as never,
    calls: () => calls,
  };
}

test("the model's verdict wins over the heuristic", async () => {
  // Text the heuristic would call `done`, classified `blocked` by the model — which
  // is the one kind the heuristic cannot produce, so this proves the model was used.
  const fake = fakeModel(['{"kind":"blocked","text":"缺少 DATABASE_URL，跑不了迁移。"}']);
  const out = await classifyOutcome("我试着跑迁移，没成功。", { resolve: fake.resolve, log: () => {} });
  assert.equal(out.kind, "blocked");
  assert.equal(out.text, "缺少 DATABASE_URL，跑不了迁移。");
  assert.equal(out.via, "model");
});

test("a fenced JSON reply is still read", async () => {
  // Text-first models wrap JSON in code fences constantly, whatever the prompt says.
  const fake = fakeModel(['```json\n{"kind":"question","text":"用哪个端口？"}\n```']);
  const out = await classifyOutcome("写好了。", { resolve: fake.resolve, log: () => {} });
  assert.equal(out.kind, "question");
  assert.equal(out.text, "用哪个端口？");
});

test("garbage twice falls back to the heuristic", async () => {
  const fake = fakeModel(["I think it's done!", "still not json"]);
  const out = await classifyOutcome("好了。\n\n要我继续吗？", { resolve: fake.resolve, log: () => {} });
  assert.equal(out.via, "heuristic");
  assert.equal(out.kind, "question", "the heuristic still reads the closing question");
  assert.equal(fake.calls(), 2, "exactly one retry, not an unbounded loop");
});

test("a question with no text is treated as unusable", async () => {
  /*
   * A card parked in 需要你 with an empty subtitle interrupts a person and then
   * tells them nothing. Rejecting it here lets the heuristic supply real text.
   */
  const fake = fakeModel(['{"kind":"question","text":""}', '{"kind":"question","text":"  "}']);
  const out = await classifyOutcome("完成。\n\n下一步做哪个？", { resolve: fake.resolve, log: () => {} });
  assert.equal(out.via, "heuristic");
  assert.equal(out.text, "下一步做哪个？");
});

test("an unknown kind falls back rather than inventing a status", async () => {
  const fake = fakeModel(['{"kind":"needs_review","text":"看看"}', '{"kind":"maybe"}']);
  const out = await classifyOutcome("干完了。", { resolve: fake.resolve, log: () => {} });
  assert.equal(out.via, "heuristic");
  assert.equal(out.kind, "done");
});

test("no model configured goes straight to the heuristic", async () => {
  let asked = false;
  const out = await classifyOutcome("好了。\n\n要删旧文件吗？", {
    resolve: async () => {
      asked = true;
      return { ok: false, reason: "未配置模型。设置 TODOAGENT_MODEL" };
    },
    log: () => {},
  });
  assert.equal(asked, true);
  assert.equal(out.via, "heuristic");
  assert.equal(out.kind, "question");
});

test("a hung model does not hold the card: the timeout yields the heuristic", async () => {
  /*
   * The property that matters most in this file. Classification is an enhancement;
   * a card stuck at 进行中 because a side-channel LLM call never answered is worse
   * than one classified imperfectly.
   */
  const started = Date.now();
  const out = await classifyOutcome("完成。\n\n要不要加测试？", {
    resolve: () => new Promise(() => {}), // never settles
    timeoutMs: 120,
    log: () => {},
  });
  const elapsed = Date.now() - started;
  assert.equal(out.via, "heuristic");
  assert.equal(out.kind, "question");
  assert.ok(elapsed < 2_000, `should have given up promptly, took ${elapsed}ms`);
});

test("a throwing model is caught, not propagated", async () => {
  // The caller is the path that moves a card out of 进行中. It cannot handle a throw.
  const out = await classifyOutcome("完成。", {
    resolve: async () => {
      throw new Error("provider exploded");
    },
    log: () => {},
  });
  assert.equal(out.kind, "done");
  assert.equal(out.via, "heuristic");
});

test("empty output never reaches the model", async () => {
  let called = false;
  const out = await classifyOutcome("   ", {
    resolve: async () => {
      called = true;
      return { ok: false, reason: "x" };
    },
    log: () => {},
  });
  assert.equal(called, false, "nothing to classify means no token spend");
  assert.equal(out.kind, "done");
});

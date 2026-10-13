import assert from "node:assert/strict";
import { spawn as spawnChild } from "node:child_process";
import { once } from "node:events";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import plugin, * as pluginModule from "../../integrations/opencode/agent-notify.js";
import { assistant, createHarness, deferred, execution, flush, inbox, LocationRouter, native, session, status, text } from "./native-harness.js";

const directory = await mkdtemp(join(tmpdir(), "agent-notify-native-"));
const settingsFile = join(directory, "settings.conf");
process.env.AGENT_NOTIFY_SETTINGS_FILE = settingsFile;
process.on("exit", () => rmSync(directory, { force: true, recursive: true }));
const corpus = JSON.parse(readFileSync(new URL("../fixtures/excerpt-corpus.json", import.meta.url), "utf8"));
const tree = { root: session("root"), child: session("child", "root"), grandchild: session("grandchild", "child") };
const permission = (id, action, request = "request") => native(`permission.${action}`, id,
  action === "asked" ? { id: request, resource: "private-permission-sentinel" } : { requestID: request, reply: "once" });
const form = (id, action, request = "request") => action === "created"
  ? native("form.created", undefined, { form: { id: request, sessionID: id, title: "private-form-sentinel",
    fields: [{ label: "private-field-sentinel" }] } })
  : native(`form.${action}`, id, { id: request, answers: { secret: "private-answer-sentinel" } });
const failure = (id, error = { type: "provider.invalid-request", message: "test failure", response: { body: "private-response-sentinel" } }) =>
  execution(id, "failed", { error });

test("exports one native definition; detached setup owns an abortable subscription", async (t) => {
  assert.deepEqual(Object.keys(pluginModule), ["default"]);
  assert.deepEqual(Object.keys(plugin), ["id", "setup"]);
  assert.equal(plugin.id, "agent-notify");
  const h = createHarness(t);
  assert.equal(h.stream.subscribeCalls, 1);
  assert.equal(h.stream.signal.aborted, false);
  assert.equal(h.stream.waiters.length, 1);
  h.cleanup();
  assert.equal(h.stream.signal.aborted, true);
  await flush();
  assert.deepEqual(h.events, []);
});

test("requires observed activation, native success, idle and 50 ms quiescence", async (t) => {
  const h = createHarness(t);
  await h.emit(status("unobserved", "idle"), execution("unobserved", "succeeded"), status("unobserved", "idle"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.events, []);
  await h.emit(execution("root", "started"), status("root", "busy"), execution("root", "started"));
  await h.emit(status("root", "idle"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root"]);
  await h.emit(execution("root", "succeeded"));
  await h.scheduler.advanceBy(49);
  assert.deepEqual(h.kinds, ["began:root"]);
  await h.scheduler.advanceBy(1);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
  await h.emit(status("root", "idle"), execution("root", "succeeded"));
  await h.scheduler.advanceBy(50);
  assert.equal(h.events.length, 2);
  assert.deepEqual(h.getRequests[0], { sessionID: "unobserved" });
});

test("busy is an activation fallback; native success projects idle without a separate status event", async (t) => {
  const h = createHarness(t);
  await h.emit(status("root", "busy"), status("root", "busy"), execution("root", "succeeded"));
  await h.scheduler.advanceBy(49);
  assert.deepEqual(h.kinds, ["began:root"]);
  await h.scheduler.advanceBy(1);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
  await h.emit(status("root", "idle"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
  await h.complete("root");
  assert.deepEqual(h.kinds, ["began:root", "completed:root", "began:root", "completed:root"]);
});

test("duplicate success/idle signals retain one candidate and its original quiescence deadline", async (t) => {
  const h = createHarness(t);
  await h.emit(execution("root", "started"));
  await h.settle("root");
  const candidate = h.scheduler.pending.find((timer) => timer.delay === 50);
  await h.scheduler.advanceBy(25);
  await h.emit(status("root", "idle"), execution("root", "succeeded"));
  assert.deepEqual(h.scheduler.pending.filter((timer) => timer.delay === 50), [candidate]);
  await h.scheduler.advanceBy(25);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
});

test("a bounded pending attention lookup cannot strand an expired candidate", async (t) => {
  const lookup = deferred();
  let delayed = false;
  const h = createHarness(t, { getSession() { return delayed ? lookup.promise : session("root"); } });
  await h.emit(execution("root", "started"));
  await h.settle("root");
  delayed = true;
  await h.emit(permission("root", "asked"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root"]);
  lookup.resolve(session("root"));
  await flush();
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "attention:root", "completed:root"]);
});

test("metadata lookups expire after one second and late results cannot replace tracked relationships", async (t) => {
  const lookup = deferred();
  let delayed = false;
  const h = createHarness(t, { getSession(id) { return delayed ? lookup.promise : tree[id]; } });
  await h.emit(execution("root", "started"), execution("child", "started"));
  await h.settle("root");
  delayed = true;
  await h.emit(execution("child", "succeeded"), status("child", "idle"));
  await h.scheduler.advanceBy(1000);
  await h.scheduler.advanceBy(1000);
  lookup.resolve(session("child", undefined, "/work/late-unrelated"));
  await flush();
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "completed:root"]);
  assert.equal(h.events.at(-1).session_dir, "/work/root");
});

for (const profile of ["build", "explore", "custom-reviewer", "same-mode-all"]) {
  test(`relationship, not agent profile, controls root/child lifecycle (${profile})`, async (t) => {
    const h = createHarness(t, { sessions: Object.fromEntries(Object.entries(tree).map(([id, info]) => [id, { ...info, agent: profile }])) });
    await h.emit(execution("root", "started"), execution("child", "started"), status("child", "busy"));
    await h.settle("root");
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root", "reset:child"]);
    await h.settle("child");
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root", "reset:child", "completed:root"]);
  });
}

test("foreground/background/nested out-of-order trees settle without restarting a pending root", async (t) => {
  const h = createHarness(t, { sessions: tree });
  await h.emit(execution("grandchild", "started"), execution("child", "started"), execution("root", "started"));
  await h.settle("root");
  await h.settle("child");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["reset:grandchild", "reset:child", "began:root"]);
  await h.settle("grandchild");
  const stale = h.scheduler.pending.find((timer) => timer.delay === 50);
  await h.emit(execution("root", "started"), status("root", "busy"));
  stale.callback();
  await h.scheduler.advanceBy(50);
  assert.equal(h.events.filter((event) => event.event === "completed").length, 0);
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["reset:grandchild", "reset:child", "began:root", "completed:root"]);
});

test("root/child success and idle ordering never substitutes status for an execution outcome", async (t) => {
  function permutations(values) {
    if (values.length === 0) return [[]];
    return values.flatMap((value, index) => permutations(values.filter((_, other) => other !== index))
      .map((rest) => [value, ...rest]));
  }
  const signals = [execution("root", "succeeded"), status("root", "idle"),
    execution("child", "succeeded"), status("child", "idle")];
  for (const ordering of permutations(signals)) {
    const h = createHarness(t, { sessions: tree });
    await h.emit(execution("root", "started"), execution("child", "started"));
    for (const [index, signal] of ordering.entries()) {
      await h.emit(signal);
      await h.scheduler.advanceBy(50);
      const outcomes = ordering.slice(0, index + 1).filter((entry) => entry.type === "session.execution.succeeded");
      assert.equal(h.events.filter((event) => event.event === "completed").length, outcomes.length === 2 ? 1 : 0);
    }
    assert.deepEqual(h.kinds, ["began:root", "reset:child", "completed:root"]);
  }
});

test("native creation records relationships/location but does not activate", async (t) => {
  const h = createHarness(t, { getSession() { throw new Error("lookup unavailable"); } });
  await h.emit(native("session.created", "child", { parentID: "root", location: { directory: "/work/child" } }),
    native("session.created", "root", { location: { directory: "/work/root" } }));
  assert.deepEqual(h.events, []);
  await h.emit(execution("root", "started"), execution("child", "started"));
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child"]);
  await h.settle("child");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "completed:root"]);
});

for (const [label, parentID] of [["malformed", {}], ["self-parent", "child"], ["cyclic", "grandchild"]]) {
  test(`valid native creation relationship survives ${label} lookup metadata`, async (t) => {
    const h = createHarness(t, { getSession(id) {
      return id === "child" ? session(id, parentID, "/work/resolved-child") : tree[id];
    } });
    await h.emit(execution("root", "started"),
      native("session.created", "grandchild", { parentID: "child", location: { directory: "/work/grandchild" } }),
      native("session.created", "child", { parentID: "root", location: { directory: "/work/event-child" } }));
    assert.deepEqual(h.kinds, ["began:root"]);
    await h.emit(execution("child", "started"), status("child", "busy"), permission("child", "asked"));
    await h.settle("root");
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root", "reset:child", "attention:child"]);
    assert.ok(h.events.filter((event) => event.session_id === "child")
      .every((event) => event.session_dir === "/work/resolved-child"));
    await h.settle("child");
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root", "reset:child", "attention:child", "completed:root"]);
  });
}

test("lookup failure preserves tracked relationships and successful pending root", async (t) => {
  let fail = false;
  const h = createHarness(t, { getSession(id) { if (fail) throw new Error("unavailable"); return tree[id]; } });
  await h.emit(execution("root", "started"), execution("child", "started"));
  fail = true;
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child"]);
  await h.settle("child");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "completed:root"]);
});

test("malformed native lookup objects cannot erase a known child relationship", async (t) => {
  let malformed = false;
  const h = createHarness(t, { getSession(id) { return malformed ? { id } : tree[id]; } });
  await h.emit(execution("root", "started"), execution("child", "started"));
  malformed = true;
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child"]);
  await h.settle("child");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "completed:root"]);
});

test("invalid/self-parent/cyclic lookups retain known state or bounded per-session fallback", async (t) => {
  const sessions = { root: session("root"), child: session("child", "root"), self: session("self", "self"),
    invalid: session("invalid", {}), a: session("a", "b"), b: session("b", "a") };
  const h = createHarness(t, { sessions });
  await h.emit(execution("root", "started"), execution("child", "started"));
  sessions.child = session("child", "child");
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child"]);
  await h.settle("child");
  await h.scheduler.advanceBy(50);
  for (const id of ["self", "invalid"]) await h.complete(id);
  await h.emit(native("session.created", "a", { parentID: "b", location: { directory: "/work/a" } }),
    native("session.created", "b", { parentID: "a", location: { directory: "/work/b" } }));
  await h.complete("b");
  assert.equal(h.events.filter((event) => event.event === "completed" && event.session_id === "root").length, 1);
  assert.ok(h.kinds.includes("completed:self") && h.kinds.includes("completed:invalid"));
});

test("unresolved directory never falls back to ctx.location; native event location permits fallback", async (t) => {
  const h = createHarness(t, { getSession() { throw new Error("private lookup error"); } });
  await h.complete("missing");
  assert.deepEqual(h.events, []);
  await h.emit(native("session.execution.started", "fallback", {}, { location: { directory: "/work/actual" } }));
  await h.settle("fallback");
  await h.scheduler.advanceBy(50);
  assert.equal(h.events[0].session_dir, "/work/actual");
  assert.equal(h.events[1].event, "completed");
});

test("permission/form attention uses exact native IDs, matching family and child scope", async (t) => {
  const h = createHarness(t, { sessions: tree });
  await h.emit(execution("root", "started"), execution("child", "started"), permission("child", "asked"),
    permission("child", "asked"), form("child", "created"), form("child", "created"),
    permission("child", "replied", "unmatched"), form("root", "replied"), permission("child", "replied"),
    permission("child", "replied"), form("child", "cancelled"), form("child", "replied"));
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "attention:child", "attention:child",
    "attention-cleared:child", "attention-cleared:child"]);
  assert.deepEqual(h.events.slice(2).map((event) => event.request_id), ["request", "request", "request", "request"]);
  assert.equal(JSON.stringify(h.events).includes("private-"), false);
});

test("global forms and malformed nesting/IDs are ignored without ending observation", async (t) => {
  const h = createHarness(t);
  await h.emit(form("global", "created"), form("global", "replied"), form("global", "cancelled"),
    native("form.created", "root", { id: "wrong-nesting" }), native("permission.asked", "root", { requestID: "wrong-field" }),
    native("permission.replied", "root", { id: "wrong-field" }), native("permission.asked", "x".repeat(257), { id: "request" }),
    native("permission.asked", "root", { id: "control\nrequest" }), { type: "session.status", data: [] },
    { type: "session.execution.started", data: { sessionID: {} } }, null);
  assert.deepEqual(h.events, []);
  await h.emit(permission("root", "asked"));
  assert.deepEqual(h.kinds, ["attention:root"]);
});

test("ignores V1 properties, deprecated/alias events and step/tool failures", async (t) => {
  const h = createHarness(t);
  for (const type of ["session.status", "session.execution.started", "session.idle", "session.error", "session.next.prompted",
    "session.next.prompt.admitted", "question.asked", "question.replied", "question.rejected", "permission.v2.asked", "permission.v2.replied",
    "question.v2.asked", "question.v2.replied", "form.v2.created", "session.step.failed", "session.tool.failed"]) {
    await h.emit({ type, properties: { sessionID: "root", id: "request", status: { type: "busy" } } });
    if (type !== "session.status" && type !== "session.execution.started") {
      await h.emit(native(type, "root", { id: "request", requestID: "request", status: { type: "busy" }, error: { type: "failure" } }));
    }
  }
  assert.deepEqual(h.events, []);
  assert.deepEqual(h.getRequests, []);
});

test("actionable retries are deduplicated attention, ordinary retries are not failure", async (t) => {
  const h = createHarness(t, { sessions: tree });
  await h.emit(execution("root", "started"), status("child", "retry", { attempt: 2, action: { title: "private-retry-sentinel" } }),
    status("child", "retry", { attempt: 2, action: { title: "private-retry-sentinel" } }));
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "attention:child"]);
  assert.equal(h.events.at(-1).request_id, "retry:2");
  await h.emit(status("child", "retry", { attempt: 3 }));
  await h.settle("child");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "attention:child", "completed:root"]);
});

for (const terminal of ["failed", "interrupted"]) {
  test(`busy-only activation after ${terminal} starts a new execution without explicit idle`, async (t) => {
    const h = createHarness(t, { sessions: tree });
    await h.emit(status("root", "busy"), status("child", "busy"));
    const end = (id) => terminal === "failed" ? failure(id) : execution(id, "interrupted", { reason: "user" });
    await h.emit(end("root"), end("child"), status("root", "busy"), status("child", "busy"), status("child", "busy"));
    await h.emit(end("child"), execution("root", "succeeded"));
    await h.scheduler.advanceBy(50);
    const kind = terminal === "failed" ? "failed" : "reset";
    assert.deepEqual(h.kinds, ["began:root", "reset:child", `${kind}:root`, `${kind}:child`,
      "began:root", "reset:child", `${kind}:child`, "completed:root"]);
  });

  test(`intervening retry cannot hide busy-only root activation after ${terminal}`, async (t) => {
    const h = createHarness(t);
    await h.emit(execution("root", "started"),
      terminal === "failed" ? failure("root") : execution("root", "interrupted", { reason: "user" }),
      status("root", "retry", { attempt: 1 }), status("root", "busy"),
      permission("root", "asked"), status("root", "busy"), permission("root", "replied"));
    await h.settle("root");
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root", `${terminal === "failed" ? "failed" : "reset"}:root`,
      "began:root", "attention:root", "attention-cleared:root", "completed:root"]);
  });

  test(`child ${terminal} settles without a root failure; reused executions reset once`, async (t) => {
    const h = createHarness(t, { sessions: tree });
    await h.emit(execution("root", "started"));
    for (let index = 0; index < 2; index += 1) {
      await h.emit(execution("child", "started"), status("child", "busy"), execution("child", "started"),
        permission("child", "asked", `request-${index}`), status("child", "busy"));
      await h.emit(terminal === "failed" ? failure("child") : execution("child", "interrupted", { reason: "user" }));
      await h.emit(terminal === "failed" ? failure("child") : execution("child", "interrupted", { reason: "user" }),
        status("child", "idle"), permission("child", "replied", `request-${index}`));
    }
    await h.settle("root");
    await h.scheduler.advanceBy(50);
    const kind = terminal === "failed" ? "failed" : "reset";
    assert.deepEqual(h.kinds, ["began:root", "reset:child", "attention:child", `${kind}:child`,
      "reset:child", "attention:child", `${kind}:child`, "completed:root"]);
  });
  test(`root ${terminal} prevents later success/idle completion and clears attention`, async (t) => {
    const h = createHarness(t);
    await h.emit(execution("root", "started"), permission("root", "asked"));
    await h.emit(terminal === "failed" ? failure("root") : execution("root", "interrupted", { reason: "user" }));
    await h.emit(status("root", "idle"), execution("root", "succeeded"), permission("root", "replied"));
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root", "attention:root", `${terminal === "failed" ? "failed" : "reset"}:root`]);
    await h.complete("root");
    assert.deepEqual(h.kinds.slice(-2), ["began:root", "completed:root"]);
  });
}

test("session-associated failure without observed start is reported once, sessionless errors ignored", async (t) => {
  const h = createHarness(t);
  await h.emit(failure("root"), failure("root"), native("session.execution.failed", undefined, { error: { type: "failure" } }));
  assert.deepEqual(h.kinds, ["failed:root"]);
});

for (const id of ["root", "child"]) {
  test(`outstanding ${id} inbox blocks successful idle roots; duplicates/unmatched do not corrupt settlement`, async (t) => {
    const h = createHarness(t, { sessions: tree });
    await h.emit(native("session.created", "child", { parentID: "root", location: { directory: "/work/child" } }), execution("root", "started"));
    await h.settle("root");
    await h.emit(inbox(id, "enqueued", "msg_one"), inbox(id, "enqueued", "msg_one"), inbox(id, "enqueued", "msg_two"),
      inbox(id, "cancelled", "msg_unmatched"), inbox(id, "cancelled", "msg_one"), inbox(id, "cancelled", "msg_one"));
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root"]);
    await h.emit(inbox(id, "cancelled", "msg_two"));
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
    assert.equal(JSON.stringify(h.events).includes("private-item-sentinel"), false);
  });
}

for (const childOutcome of ["succeeded", "failed", "interrupted"]) {
  test(`delivered child inbox requires a later native outcome (${childOutcome}), not prior idle/success`, async (t) => {
    const h = createHarness(t, { sessions: tree });
    await h.emit(execution("root", "started"), execution("child", "started"));
    await h.settle("child");
    await h.settle("root");
    await h.emit(inbox("child", "enqueued", "msg_one"), inbox("child", "delivered", "msg_one"),
      inbox("child", "delivered", "msg_one"), inbox("child", "cancelled", "msg_one"), status("child", "idle"));
    await h.scheduler.advanceBy(50);
    assert.equal(h.kinds.includes("completed:root"), false);
    await h.emit(execution("child", "started"));
    await h.emit(childOutcome === "failed" ? failure("child") : execution("child", childOutcome));
    await h.emit(status("child", "idle"));
    await h.scheduler.advanceBy(50);
    assert.equal(h.events.filter((event) => event.event === "completed").length, 1);
    assert.equal(h.events.at(-1).session_id, "root");
  });
}

test("background result inbox delivery invalidates root success until parent consumes and succeeds", async (t) => {
  const h = createHarness(t, { sessions: tree });
  await h.emit(execution("root", "started"), execution("child", "started"));
  await h.settle("root");
  await h.settle("child");
  await h.emit(inbox("root", "enqueued", "msg_result"), inbox("root", "delivered", "msg_result"), status("root", "idle"));
  await h.scheduler.advanceBy(50);
  assert.equal(h.kinds.includes("completed:root"), false);
  await h.emit(execution("root", "started"));
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "completed:root"]);
});

test("delivered observed work can settle on the next native outcome even when start was not observed", async (t) => {
  const h = createHarness(t, { sessions: tree });
  await h.emit(execution("root", "started"), execution("child", "started"));
  await h.settle("root");
  await h.settle("child");
  await h.emit(inbox("root", "enqueued", "msg_one"), inbox("root", "delivered", "msg_one"),
    inbox("child", "enqueued", "msg_child"), inbox("child", "delivered", "msg_child"));
  await h.scheduler.advanceBy(50);
  assert.equal(h.kinds.includes("completed:root"), false);
  await h.emit(execution("root", "succeeded"), failure("child"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "failed:child", "completed:root"]);
});

test("cancelling queued inbox cannot reuse success after root has resumed", async (t) => {
  const h = createHarness(t);
  await h.emit(execution("root", "started"));
  await h.settle("root");
  await h.emit(inbox("root", "enqueued", "msg_one"), execution("root", "started"), inbox("root", "cancelled", "msg_one"), status("root", "idle"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root"]);
  await h.emit(execution("root", "succeeded"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
});

test("root or nested activation invalidates a known candidate before stalled lookup completes", async (t) => {
  for (const id of ["root", "grandchild"]) {
    const lookup = deferred();
    let stalled = false;
    const h = createHarness(t, { getSession(name) { return stalled && name === id ? lookup.promise : tree[name]; } });
    await h.emit(native("session.created", "grandchild", { parentID: "child", location: { directory: "/work/grandchild" } }),
      native("session.created", "child", { parentID: "root", location: { directory: "/work/child" } }), execution("root", "started"));
    await h.settle("root");
    const stale = h.scheduler.pending.find((timer) => timer.delay === 50);
    stalled = true;
    await h.emit(execution(id, "started"));
    stale.callback();
    await h.scheduler.advanceBy(50);
    assert.equal(h.kinds.includes("completed:root"), false);
    lookup.resolve(tree[id]);
    await flush();
    await h.settle(id);
    await h.scheduler.advanceBy(50);
    assert.equal(h.events.filter((event) => event.event === "began").length, 1);
    assert.equal(h.events.filter((event) => event.event === "completed").length, 1);
  }
});

test("root resumption during delayed excerpt cancels late text and preserves original turn", async (t) => {
  const context = deferred();
  let delayed = true;
  const h = createHarness(t, { getContext() { return delayed ? context.promise : [assistant(text("fresh"))]; } });
  await h.emit(execution("root", "started"));
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.equal(h.contextRequests.length, 1);
  await h.emit(execution("root", "started"));
  context.resolve([assistant(text("stale"))]);
  await flush();
  assert.deepEqual(h.kinds, ["began:root"]);
  delayed = false;
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
  assert.equal(h.events.at(-1).excerpt, "fresh");
});

test("stalled attention delivery does not block intake; queued completion is cancellable at FIFO front", async (t) => {
  const delivery = deferred();
  const h = createHarness(t, { delivery(event) { return event.event === "attention" ? delivery.promise : Promise.resolve(0); } });
  await h.emit(execution("root", "started"), permission("root", "asked"));
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "attention:root"]);
  await h.emit(execution("root", "started"));
  delivery.resolve(0);
  await flush();
  assert.deepEqual(h.kinds, ["began:root", "attention:root"]);
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "attention:root", "completed:root"]);
});

test("nested activation also cancels a completion waiting behind a root attention subprocess", async (t) => {
  const delivery = deferred();
  const h = createHarness(t, { sessions: tree, delivery(event) { return event.event === "attention" ? delivery.promise : Promise.resolve(0); } });
  await h.emit(execution("root", "started"), native("session.created", "child", { parentID: "root", location: { directory: "/work/child" } }),
    permission("root", "asked"));
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  await h.emit(execution("grandchild", "started"));
  delivery.resolve(0);
  await flush();
  assert.equal(h.kinds.includes("completed:root"), false);
  await h.settle("grandchild");
  await h.scheduler.advanceBy(50);
  assert.equal(h.events.filter((event) => event.event === "completed").length, 1);
});

test("completion consumes the turn at submission, not slow subprocess exit", async (t) => {
  const delivery = deferred();
  const h = createHarness(t, { delivery(event) { return event.event === "completed" ? delivery.promise : Promise.resolve(0); } });
  await h.complete("root");
  await h.emit(execution("root", "started"));
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
  delivery.resolve(0);
  await flush();
  assert.deepEqual(h.kinds, ["began:root", "completed:root", "began:root"]);
});

test("same-owner movement preserves a new turn's queued begin behind submitted completion", async (t) => {
  const delivery = deferred();
  let completions = 0;
  const location = { directory: "/work/root" };
  const h = createHarness(t, { location, delivery(event) {
    return event.event === "completed" && ++completions === 1 ? delivery.promise : Promise.resolve(0);
  } });
  await h.complete("root");
  await h.emit(execution("root", "started"), native("session.moved", "root", { location, projectID: "project" }),
    execution("root", "succeeded"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
  delivery.resolve(0);
  await flush();
  assert.deepEqual(h.kinds, ["began:root", "completed:root", "began:root", "completed:root"]);
});

test("same-owner child movement preserves the queued reset needed after a stalled prior failure", async (t) => {
  const delivery = deferred();
  let failures = 0;
  const location = { directory: "/work/child" };
  const h = createHarness(t, { sessions: tree, location, delivery(event) {
    return event.event === "failed" && ++failures === 1 ? delivery.promise : Promise.resolve(0);
  } });
  await h.emit(execution("root", "started"), execution("child", "started"), failure("child"),
    execution("child", "started"), native("session.moved", "child", { location, projectID: "project" }), failure("child"));
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "failed:child"]);
  delivery.resolve(0);
  await flush();
  assert.deepEqual(h.kinds, ["began:root", "reset:child", "failed:child", "reset:child", "failed:child"]);
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  assert.equal(h.kinds.at(-1), "completed:root");
});

test("a same-owner move invalidates old candidates and queued events, resolving display from session metadata", async (t) => {
  const sessions = { root: session("root") };
  const delivery = deferred();
  const h = createHarness(t, { sessions, location: { directory: "/work/moved-project" },
    delivery(event) { return event.event === "attention" ? delivery.promise : Promise.resolve(0); } });
  await h.emit(execution("root", "started"), permission("root", "asked"), permission("root", "asked", "queued"));
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  sessions.root = session("root", undefined, "/work/moved-project");
  await h.emit(native("session.moved", "root", { location: { directory: "/work/moved-project" }, projectID: "project" }));
  delivery.resolve(0);
  await flush();
  assert.deepEqual(h.kinds, ["began:root", "attention:root"]);
  await h.scheduler.advanceBy(50);
  assert.equal(h.events.at(-1).event, "completed");
  assert.equal(h.events.at(-1).session_dir, "/work/moved-project");
  assert.equal(h.events.some((event) => event.request_id === "queued"), false);
});

test("same-owner movement preserves a pending resumption and discards its obsolete lookup result", async (t) => {
  const lookup = deferred();
  let delayed = false;
  let unavailable = false;
  const location = { directory: "/work/project" };
  const h = createHarness(t, { location, getSession() {
    if (delayed) return lookup.promise;
    if (unavailable) throw new Error("fresh lookup unavailable");
    return session("root", undefined, location.directory);
  } });
  await h.emit(execution("root", "started"), execution("root", "succeeded"));
  delayed = true;
  await h.emit(execution("root", "started"));
  delayed = false;
  unavailable = true;
  await h.emit(native("session.moved", "root", { location, projectID: "project" }));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root"], "discarded activation must not revive prior success");
  lookup.resolve(session("root", undefined, "/work/obsolete"));
  await flush();
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root"]);
  unavailable = false;
  await h.emit(execution("root", "succeeded"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
  assert.equal(h.events.at(-1).session_dir, location.directory);
});

for (const sameDirectory of [false, true]) {
  test(`outgoing ownership cannot re-arm a root after a location-routed move (same directory: ${sameDirectory})`, async (t) => {
    const oldLocation = { directory: "/work/old", workspaceID: "wrk_old" };
    const newLocation = { directory: sameDirectory ? "/work/old" : "/work/new", workspaceID: "wrk_new" };
    const sessions = { root: { id: "root", location: oldLocation } };
    const delivery = deferred();
    const outgoing = createHarness(t, { sessions, location: oldLocation,
      delivery(event) { return event.event === "attention" ? delivery.promise : Promise.resolve(0); } });
    const incoming = createHarness(t, { sessions, location: newLocation });
    const router = new LocationRouter();
    router.attach(oldLocation, outgoing.stream);
    router.attach(newLocation, incoming.stream);
    await router.emit(native("session.created", "root", { location: oldLocation }), execution("root", "started"),
      permission("root", "asked"), permission("root", "asked", "queued"), execution("root", "succeeded"));
    await outgoing.scheduler.advanceBy(50);
    assert.deepEqual(outgoing.kinds, ["began:root", "attention:root"]);
    sessions.root = { id: "root", location: newLocation };
    await router.emit(native("session.moved", "root", { location: newLocation, projectID: "project" }, { location: oldLocation }));
    assert.deepEqual(incoming.events, [], "arrival must not invent or replay a turn");
    await router.emit(execution("root", "started"));
    delivery.resolve(0);
    await flush();
    await outgoing.scheduler.advanceBy(1000);
    assert.deepEqual(outgoing.kinds, ["began:root", "attention:root"], "old owner cannot clear the destination's active notifier state");
    await router.emit(execution("root", "succeeded"));
    await incoming.scheduler.advanceBy(50);
    assert.deepEqual(incoming.kinds, ["began:root", "completed:root"]);
    assert.ok(incoming.events.every((event) => event.session_dir === newLocation.directory));
    await outgoing.scheduler.advanceBy(1000);
    assert.equal(outgoing.events.length, 2);
  });
}

test("late lookup after movement cannot revive obsolete location or queued events", async (t) => {
  const lookup = deferred();
  let delayed = false;
  const h = createHarness(t, { getSession() { return delayed ? lookup.promise : session("root"); } });
  await h.emit(execution("root", "started"));
  delayed = true;
  await h.emit(permission("root", "asked"));
  await h.emit(native("session.moved", "root", { location: { directory: "/work/new" }, projectID: "project" }));
  delayed = false;
  lookup.resolve(session("root", undefined, "/work/obsolete"));
  await flush();
  assert.deepEqual(h.kinds, ["began:root"]);
});

test("deletion silently resets, invalidates pending lookup and never revives old observation", async (t) => {
  const lookup = deferred();
  let delayed = false;
  const h = createHarness(t, { getSession() { return delayed ? lookup.promise : session("root"); } });
  await h.emit(execution("root", "started"));
  await h.settle("root");
  delayed = true;
  await h.emit(permission("root", "asked"));
  await h.emit(native("session.deleted", "root"));
  lookup.resolve(session("root"));
  await flush();
  await h.emit(status("root", "idle"), execution("root", "succeeded"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:root"]);
});

test("independent roots and plugin instances do not share turn/tree state", async (t) => {
  const a = createHarness(t);
  const b = createHarness(t);
  await a.emit(execution("one", "started"), execution("two", "started"));
  await b.complete("one");
  assert.deepEqual(a.kinds, ["began:one", "began:two"]);
  assert.deepEqual(b.kinds, ["began:one", "completed:one"]);
  await a.settle("two");
  await a.scheduler.advanceBy(50);
  assert.deepEqual(a.kinds, ["began:one", "began:two", "completed:two"]);
});

test("a known independent tree's sustained lookup stalls do not starve completion or lifecycle reduction", async (t) => {
  const lookups = [];
  let delayed = false;
  const h = createHarness(t, { getSession(id) {
    if (delayed && id === "other") { const lookup = deferred(); lookups.push(lookup); return lookup.promise; }
    return session(id);
  } });
  await h.emit(execution("root", "started"), execution("other", "started"));
  await h.settle("root");
  const candidate = h.scheduler.pending.find((timer) => timer.delay === 50);
  delayed = true;
  for (let index = 0; index < 5; index += 1) await h.emit(permission("other", "asked", `request-${index}`));
  await h.scheduler.advanceBy(50);
  assert.equal(candidate.cancelled, true, "a committed completion consumes its candidate");
  assert.deepEqual(h.kinds, ["began:root", "began:other", "completed:root"]);
  await h.emit(execution("root", "started"), execution("root", "succeeded"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "began:other", "completed:root", "began:root", "completed:root"]);
  assert.equal(lookups.length, 5);
  for (const lookup of [...lookups].reverse()) { lookup.resolve(session("other")); await flush(); }
  assert.deepEqual(h.events.filter((event) => event.session_id === "other").map((event) => event.request_id),
    ["", "request-0", "request-1", "request-2", "request-3", "request-4"]);
});

test("unknown relationships conservatively block completion until lookup resolves into the affected tree", async (t) => {
  const lookup = deferred();
  const h = createHarness(t, { getSession(id) { return id === "new-child" ? lookup.promise : session(id); } });
  await h.emit(execution("root", "started"));
  await h.settle("root");
  await h.emit(execution("new-child", "started"));
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root"]);
  lookup.resolve(session("new-child", "root"));
  await flush();
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:new-child"]);
  await h.settle("new-child");
  await h.scheduler.advanceBy(50);
  assert.deepEqual(h.kinds, ["began:root", "reset:new-child", "completed:root"]);
});

test("completion excerpts inspect twelve recent native entries, newest assistant first text only", async (t) => {
  const h = createHarness(t, { contexts: { root: [assistant(text("older")), assistant({ type: "reasoning", text: "private-reasoning" },
    { type: "tool", text: "private-tool" }, text(" "), text("first eligible"), text("second excluded")),
    { type: "synthetic", text: "private-child-report" }, { type: "system", text: "private-system" },
    { type: "compaction", summary: "private-compaction" }] } });
  await h.complete("root");
  assert.equal(h.events.at(-1).excerpt, "first eligible");
  assert.deepEqual(h.contextRequests, [{ sessionID: "root" }]);
});

test("newest assistant without eligible text never falls back to older assistant", async (t) => {
  for (const content of [[{ type: "reasoning", text: "private" }], [text(" ")], [text("hidden", { synthetic: true })],
    [text("hidden", { ignored: true })], [], [{ type: "tool", text: "private" }]]) {
    const h = createHarness(t, { contexts: { root: [assistant(text("older")), assistant(...content)] } });
    await h.complete("root");
    assert.equal(h.events.at(-1).excerpt, undefined);
  }
  const h = createHarness(t, { contexts: { root: [assistant(text("outside window")), ...Array.from({ length: 12 }, () => ({ type: "system", text: "excluded" }))] } });
  await h.complete("root");
  assert.equal(h.events.at(-1).excerpt, undefined);
});

test("deferred root excerpts use prior root text, never child context or synthetic reports", async (t) => {
  const h = createHarness(t, { sessions: tree, contexts: { root: [assistant(text("root text before child")), { type: "synthetic", text: "private child report" }],
    child: [assistant(text("private child text"))] } });
  await h.emit(execution("root", "started"), execution("child", "started"));
  await h.settle("root");
  await h.settle("child");
  await h.scheduler.advanceBy(50);
  assert.equal(h.events.at(-1).excerpt, "root text before child");
  assert.deepEqual(h.contextRequests, [{ sessionID: "root" }]);
});

test("context missing/rejected/one-second timeout are excerpt-free, with late results discarded", async (t) => {
  for (const getContext of [() => undefined, () => { throw new Error("private transport failure"); }]) {
    const h = createHarness(t, { getContext });
    await h.complete("root");
    assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
    assert.equal(h.events.at(-1).excerpt, undefined);
  }
  const context = deferred();
  const h = createHarness(t, { getContext() { return context.promise; } });
  await h.complete("root");
  await h.scheduler.advanceBy(999);
  assert.deepEqual(h.kinds, ["began:root"]);
  await h.scheduler.advanceBy(1);
  assert.deepEqual(h.kinds, ["began:root", "completed:root"]);
  context.resolve([assistant(text("too late"))]);
  await flush();
  assert.equal(h.events.at(-1).excerpt, undefined);
});

test("structured failure uses message/type, never response bodies, and preserves excerpt corpus", async (t) => {
  const h = createHarness(t);
  await h.emit(failure("message"), failure("type", { type: "provider.rate-limit", response: { body: "private-response-sentinel" } }));
  assert.deepEqual(h.events.map((event) => event.excerpt), ["test failure", "provider.rate-limit"]);
  for (const [index, entry] of corpus.cases.entries()) {
    const id = `corpus-${index}`;
    const c = createHarness(t, { contexts: { [id]: [assistant(text(entry.input))] } });
    await c.complete(id);
    assert.equal(c.events.at(-1).excerpt, entry.excerpt || undefined, entry.name);
    await c.emit(failure(`error-${index}`, { type: "error", message: entry.input }));
    assert.equal(c.events.at(-1).excerpt, entry.input ? entry.excerpt || undefined : "error", entry.name);
  }
  assert.equal(JSON.stringify(h.events).includes("private-response-sentinel"), false);
});

test("live excerpt opt-out performs no context request and no error excerpt", async (t) => {
  t.after(() => rmSync(settingsFile, { force: true }));
  const h = createHarness(t, { contexts: { root: [assistant(text("visible"))] } });
  await h.emit(execution("root", "started"));
  writeFileSync(settingsFile, "EXCERPT=0\n");
  await h.settle("root");
  await h.scheduler.advanceBy(50);
  await h.emit(failure("failure"));
  assert.equal(h.events.at(-1).excerpt, undefined);
  assert.deepEqual(h.contextRequests, []);
  writeFileSync(settingsFile, "EXCERPT=1\n");
  await h.complete("root");
  assert.equal(h.events.at(-1).excerpt, "visible");
  writeFileSync(settingsFile, "malformed settings\n");
  await h.complete("root");
  assert.equal(h.events.at(-1).excerpt, "visible");
});

test("2048-byte transport degradation drops only excerpt; bounds reject invalid identifiers/dirs", async (t) => {
  const wide = "実".repeat(256);
  const h = createHarness(t, { sessions: { [wide]: session(wide, undefined, `/${"実".repeat(255)}`) },
    contexts: { [wide]: [assistant(text("完了".repeat(200)))] } });
  await h.complete(wide);
  assert.equal(h.events.at(-1).event, "completed");
  assert.equal(h.events.at(-1).excerpt, undefined);
  for (const call of h.calls) assert.ok(call.options.stdin.byteLength <= 2048);
  const bad = createHarness(t, { getSession() { return { location: { directory: "x".repeat(257) } }; } });
  await bad.complete("root");
  assert.deepEqual(bad.events, []);
});

test("inherited server pane variables and arbitrary metadata never change project attribution", async (t) => {
  const prior = { TMUX: process.env.TMUX, TMUX_PANE: process.env.TMUX_PANE };
  t.after(() => { for (const [key, value] of Object.entries(prior)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  } });
  process.env.TMUX = "server-terminal-sentinel";
  process.env.TMUX_PANE = "%42";
  const h = createHarness(t, { sessions: { root: { ...session("root", undefined, "/work/actual-project"),
    metadata: { TMUX_PANE: "%99", pane: "%88", directory: "/work/wrong-terminal" } } } });
  await h.complete("root");
  await h.emit(permission("root", "asked"), failure("root"));
  assert.ok(h.events.every((event) => event.session_dir === "/work/actual-project" && !("tmux_session" in event)));
  assert.ok(h.calls.every((call) => call.command[0] === "agent-notify"));
});

test("canonical subprocess arguments, discarded output, ten-second deadline and advisory spawn/kill failures", async (t) => {
  const stalled = deferred();
  const h = createHarness(t, { delivery() { return stalled.promise; } });
  await h.emit(permission("root", "asked"));
  assert.deepEqual(h.calls[0].command, ["agent-notify", "event"]);
  assert.deepEqual(h.events[0], { source: "opencode", event: "attention", session_id: "root", session_dir: "/work/root", request_id: "request" });
  assert.equal(h.calls[0].options.stdout, "ignore");
  assert.equal(h.calls[0].options.stderr, "ignore");
  await h.scheduler.advanceBy(9999);
  assert.equal(h.calls[0].kills, 0);
  await h.scheduler.advanceBy(1);
  assert.equal(h.calls[0].kills, 1);
  const bad = createHarness(t, { delivery() { throw new Error("private spawn error"); } });
  await bad.emit(permission("root", "asked"), permission("root", "asked", "second"));
  assert.equal(bad.events.length, 2);
});

test("cleanup aborts stream, cancels pending context/lookup/queues, and terminates owned delivery", async (t) => {
  const context = deferred();
  const h = createHarness(t, { getContext() { return context.promise; } });
  await h.complete("root");
  h.cleanup();
  context.resolve([assistant(text("late"))]);
  await h.scheduler.advanceBy(1000);
  assert.deepEqual(h.kinds, ["began:root"]);
  assert.deepEqual(h.scheduler.pending, []);
  const lookup = deferred();
  const l = createHarness(t, { getSession() { return lookup.promise; } });
  await l.emit(execution("root", "started"));
  l.cleanup();
  lookup.resolve(session("root"));
  await flush();
  assert.deepEqual(l.events, []);
  const delivery = deferred();
  const d = createHarness(t, { delivery() { return delivery.promise; } });
  await d.emit(permission("root", "asked"), permission("root", "asked", "queued"));
  d.cleanup();
  assert.equal(d.calls[0].kills, 1);
  delivery.resolve(0);
  await flush();
  assert.equal(d.calls.length, 1);
});

test("stream failure/end cancels eligibility, is advisory, and fresh reload does not replay turns", async (t) => {
  for (const error of [undefined, new Error("private stream failure")]) {
    const h = createHarness(t);
    await h.emit(execution("root", "started"));
    await h.settle("root");
    h.stream.end(error);
    await flush();
    await h.scheduler.advanceBy(50);
    assert.deepEqual(h.kinds, ["began:root"]);
    assert.equal(h.stream.signal.aborted, true);
    const fresh = createHarness(t);
    await fresh.emit(execution("root", "succeeded"), status("root", "idle"));
    await fresh.scheduler.advanceBy(50);
    assert.deepEqual(fresh.events, []);
  }
});

test("normalization reaches real subprocess stdin without shell interpolation", async (t) => {
  const fixtureDirectory = await mkdtemp(join(tmpdir(), "agent-notify-stdin-"));
  t.after(() => rm(fixtureDirectory, { force: true, recursive: true }));
  const notifier = join(fixtureDirectory, "notifier.mjs");
  const received = join(fixtureDirectory, "received.json");
  await writeFile(notifier, `#!/usr/bin/env node
import { writeFile } from "node:fs/promises";
let input = "";
for await (const chunk of process.stdin) input += chunk;
await writeFile(process.env.NOTIFIER_OUTPUT, input);
`);
  await chmod(notifier, 0o700);
  const exited = deferred();
  const h = createHarness(t, { delivery(event, call) {
    const child = spawnChild(notifier, [], { env: { PATH: process.env.PATH, NOTIFIER_OUTPUT: received }, stdio: ["pipe", "ignore", "ignore"] });
    child.stdin.end(call.options.stdin);
    return once(child, "exit").then(() => exited.resolve());
  } });
  await h.emit(permission("root", "asked"));
  await exited.promise;
  assert.deepEqual(JSON.parse(await readFile(received, "utf8")), h.events[0]);
});

test("two consecutive child failures remain deliverable through the unchanged notifier core", async (t) => {
  const h = createHarness(t, { sessions: tree });
  await h.emit(execution("root", "started"));
  for (let index = 0; index < 2; index += 1) {
    await h.emit(execution("child", "started"), status("child", "busy"), failure("child"), status("child", "idle"));
  }
  const fixture = await mkdtemp(join(tmpdir(), "agent-notify-child-core-"));
  t.after(() => rm(fixture, { force: true, recursive: true }));
  const inputs = join(fixture, "events.jsonl");
  await writeFile(inputs, h.events.map((event) => JSON.stringify(event)).join("\n") + "\n");
  const script = join(fixture, "check.zsh");
  await writeFile(script, `emulate -R zsh
setopt errexit no_unset pipe_fail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME=$1/home AGENT_NOTIFY_STATE_DIR=$1/state AGENT_NOTIFY_DIAGNOSTIC_DIR=$1/diagnostics
export AGENT_NOTIFY_MIN_RUNTIME_SECONDS=30 AGENT_NOTIFY_ATTENTION_DEBOUNCE_SECONDS=60
source "$2/lib/agent-notify/config.zsh"
source "$2/lib/agent-notify/json.zsh"
source "$2/lib/agent-notify/state.zsh"
source "$2/lib/agent-notify/delivery.zsh"
source "$2/lib/agent-notify/event.zsh"
integer deliveries=0
agent_notify_diag() { :; }
agent_notify_deliver() { (( deliveries++ )); return 0; }
integer now=100
while IFS= read -r event; do
  AGENT_NOTIFY_NOW=$now agent_notify_event <<< "$event"
  (( now += 100 ))
done < "$1/events.jsonl"
[[ $deliveries == 2 ]]
`);
  const root = new URL("../../", import.meta.url).pathname;
  const child = spawnChild("/bin/zsh", [script, fixture, root], { stdio: "ignore" });
  const [code] = await once(child, "exit");
  assert.equal(code, 0, "child-only resets must clear terminal suppression without modifying notifier core");
});

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Execute the installed module, without test-only exports or a real notifier/Keychain call.
const [pluginPath, notifierPath] = process.argv.slice(2);
const submissions = [];
globalThis.Bun = {
  spawn(argv, options) {
    assert.deepEqual(argv, [notifierPath, "event"]);
    assert.equal(options.stdout, "ignore");
    assert.equal(options.stderr, "ignore");
    assert.ok(options.stdin instanceof Uint8Array);
    submissions.push(JSON.parse(new TextDecoder().decode(options.stdin)));
    return { exited: Promise.resolve(0), kill() {} };
  },
  which() { throw new Error("OpenCode must not discover tmux"); },
};

const pending = [];
let wake;
let stopped = false;
const stream = {
  [Symbol.asyncIterator]() { return this; },
  async next() {
    while (!stopped && pending.length === 0) await new Promise((resolve) => { wake = resolve; });
    return stopped ? { done: true } : { done: false, value: pending.shift() };
  },
  async return() { stopped = true; wake?.(); return { done: true }; },
};
let subscriptions = 0;
let contextCalls = 0;
const ctx = {
  location: { directory: "/tmp/not-the-event-project" },
  event: {
    subscribe() { subscriptions += 1; return stream; },
  },
  session: {
    async get(request) {
      assert.deepEqual(request, { sessionID: "generated-plugin" });
      return { id: request.sessionID, location: { directory: "/tmp/generated-plugin" } };
    },
    async context() { contextCalls += 1; throw new Error("excerpts are disabled"); },
  },
};
const source = readFileSync(pluginPath, "utf8");
const module = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
assert.deepEqual(Object.keys(module), ["default"]);
assert.equal(module.default.id, "agent-notify");
assert.equal(typeof module.default.setup, "function");

let setupTimer;
const cleanup = await Promise.race([
  module.default.setup(ctx),
  new Promise((_, reject) => { setupTimer = setTimeout(() => reject(new Error("setup awaited stream lifetime")), 1000); }),
]).finally(() => clearTimeout(setupTimer));
assert.equal(typeof cleanup, "function");
assert.equal(subscriptions, 1);

let eventID = 0;
function send(type, data) {
  pending.push({ id: `generated-event-${++eventID}`, type, data });
  wake?.();
}
async function waitFor(count) {
  const deadline = Date.now() + 1500;
  while (submissions.length < count && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(submissions.length, count);
}

try {
  send("session.execution.started", { sessionID: "generated-plugin" });
  send("permission.asked", { sessionID: "generated-plugin", id: "generated-request" });
  send("permission.replied", { sessionID: "generated-plugin", requestID: "generated-request" });
  send("form.created", { form: { sessionID: "generated-plugin", id: "generated-form", fields: [{ text: "private-field-sentinel" }] } });
  send("form.cancelled", { sessionID: "generated-plugin", id: "generated-form" });
  send("session.execution.succeeded", { sessionID: "generated-plugin" });
  send("session.status", { sessionID: "generated-plugin", status: { type: "idle" } });
  await waitFor(6);
  const base = { source: "opencode", session_id: "generated-plugin", session_dir: "/tmp/generated-plugin" };
  assert.deepEqual(submissions, [
    { ...base, event: "began", request_id: "" },
    { ...base, event: "attention", request_id: "generated-request" },
    { ...base, event: "attention-cleared", request_id: "generated-request" },
    { ...base, event: "attention", request_id: "generated-form" },
    { ...base, event: "attention-cleared", request_id: "generated-form" },
    { ...base, event: "completed", request_id: "" },
  ]);
  assert.equal(contextCalls, 0);
} finally {
  await cleanup();
  await stream.return();
}
console.log("generated native plugin contract passed");

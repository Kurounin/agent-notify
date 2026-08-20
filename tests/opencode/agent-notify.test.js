import assert from "node:assert/strict";
import { spawn as spawnChild } from "node:child_process";
import { once } from "node:events";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import agentNotifyPlugin, * as pluginModule from "../../integrations/opencode/agent-notify.js";

function createClient({ sessions = {}, getSession } = {}) {
  const requests = [];
  return {
    requests,
    client: {
      session: {
        async get(request) {
          requests.push(request);
          if (getSession) return getSession(request.path.id);
          // OpenCode omits parentID entirely for root sessions.
          return { data: sessions[request.path.id] ?? { directory: `/work/${request.path.id}` } };
        },
      },
    },
  };
}

function status(sessionID, type) {
  return { type: "session.status", properties: { sessionID, status: { type } } };
}

test("exports only a callable default plugin factory for the OpenCode loader", () => {
  assert.deepEqual(Object.keys(pluginModule), ["default"]);
  assert.ok(Object.values(pluginModule).every((value) => typeof value === "function"));
});

test("submits one busy-to-idle lifecycle and ignores deprecated session.idle", async () => {
  const { client, requests } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: { type: "session.idle", properties: { sessionID: "session-a" } } });
  await adapter.event({ event: status("session-a", "idle") });

  assert.deepEqual(submitted, [
    { source: "opencode", kind: "began", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
    { source: "opencode", kind: "completed", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
  ]);
  assert.equal(requests.length, 2);
});

test("does not complete an idle session without a prior busy status", async () => {
  const { client, requests } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session-a", "idle") });

  assert.deepEqual(submitted, []);
  assert.equal(requests.length, 1);
});

test("completes an idle root immediately when it has no known active descendants", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("defers root completion for busy and retry descendants until the final child settles", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "retry") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
  ]);

  await adapter.event({ event: status("child", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("does not restart the turn when a finished background task wakes its deferred root", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "idle") });
  await adapter.event({ event: status("root", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("begins a new turn once a deferred root completion has been released", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });
  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("never submits lifecycle events for a background task session", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("child", "idle") });

  assert.deepEqual(submitted, []);
});

test("retains a deferred root completion across duplicate idle statuses", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("retains a known active child when a metadata lookup fails", async () => {
  let childLookupFails = false;
  const sessions = {
    root: { directory: "/work/root" },
    child: { directory: "/work/child", parentID: "root" },
  };
  const { client } = createClient({
    getSession(sessionID) {
      if (sessionID === "child" && childLookupFails) throw new Error("unavailable");
      return { data: sessions[sessionID] };
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  childLookupFails = true;
  await adapter.event({ event: status("child", "busy") });
  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);

  childLookupFails = false;
  await adapter.event({ event: status("child", "idle") });
  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("falls back to immediate root completion when a lookup failure hides the session tree", async () => {
  let rootLookupFails = false;
  const sessions = {
    root: { directory: "/work/root" },
    child: { directory: "/work/child", parentID: "root" },
  };
  const { client } = createClient({
    getSession(sessionID) {
      if (sessionID === "root" && rootLookupFails) throw new Error("unavailable");
      return { data: sessions[sessionID] };
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  rootLookupFails = true;
  await adapter.event({ event: status("root", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("retains a deferred root when only a duplicate idle fails its lookup", async () => {
  let rootLookupFails = false;
  const sessions = {
    root: { directory: "/work/root" },
    child: { directory: "/work/child", parentID: "root" },
  };
  const { client } = createClient({
    getSession(sessionID) {
      if (sessionID === "root" && rootLookupFails) throw new Error("unavailable");
      return { data: sessions[sessionID] };
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  rootLookupFails = true;
  await adapter.event({ event: status("root", "idle") });
  rootLookupFails = false;
  await adapter.event({ event: status("child", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("settles a retry-only child and releases its pending root", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "retry") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("merges nested descendants observed before their parent and root", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
      grandchild: { directory: "/work/grandchild", parentID: "child" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("grandchild", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });
  await adapter.event({ event: status("grandchild", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("ignores settled duplicate idle events after terminal tree cleanup", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });
  await adapter.event({ event: status("child", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("prunes settled provisional child trees before their root is observed", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
      failedChild: { directory: "/work/failed-child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("child", "idle") });
  await adapter.event({ event: status("failedChild", "busy") });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "failedChild", error: { name: "UnknownError" } } } });
  await adapter.event({ event: status("child", "idle") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "failed", session_id: "failedChild" },
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("treats a session payload without a parentID key as a root", async () => {
  const { client } = createClient({
    sessions: { session: { directory: "/work/session" } },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session", "busy") });
  await adapter.event({ event: status("session", "idle") });

  assert.deepEqual(submitted.map((event) => event.kind), ["began", "completed"]);
});

test("falls back to per-session completion when session parent metadata is unusable", async () => {
  const { client } = createClient({
    sessions: { session: { directory: "/work/session", parentID: "session" } },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session", "busy") });
  await adapter.event({ event: status("session", "idle") });

  assert.deepEqual(submitted.map((event) => event.kind), ["began", "completed"]);
});

test("settles a deferred root after a child terminal error and cleans up duplicate lifecycle state", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "child", error: { name: "UnknownError" } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "child", error: { name: "UnknownError" } } } });
  await adapter.event({ event: status("child", "idle") });
  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "failed", session_id: "child" },
    { kind: "completed", session_id: "root" },
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("clears only matching legacy attention requests", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "permission-1" } } });
  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "permission-1" } } });
  await adapter.event({ event: { type: "permission.replied", properties: { sessionID: "session-a", requestID: "permission-2" } } });
  await adapter.event({ event: { type: "permission.replied", properties: { sessionID: "session-a", requestID: "permission-1" } } });
  await adapter.event({ event: { type: "question.asked", properties: { sessionID: "session-a", id: "question-1" } } });
  await adapter.event({ event: { type: "question.rejected", properties: { sessionID: "session-a", requestID: "question-1" } } });

  assert.deepEqual(submitted.map(({ kind, request_id }) => ({ kind, request_id })), [
    { kind: "attention", request_id: "permission-1" },
    { kind: "attention-cleared", request_id: "permission-1" },
    { kind: "attention", request_id: "question-1" },
    { kind: "attention-cleared", request_id: "question-1" },
  ]);
});

test("only terminal non-aborted session errors fail and prevent a later idle completion", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "MessageAbortedError" } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "APIError", data: { isRetryable: true } } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "UnknownError", data: { isRecoverable: true } } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "ToolError" } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "UserAbortError" } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "UnknownError" } } } });
  await adapter.event({ event: status("session-a", "idle") });
  await adapter.event({ event: { type: "session.error", properties: { error: { name: "UnknownError" } } } });

  assert.deepEqual(submitted.map((event) => event.kind), ["began", "failed"]);
});

test("fails a terminal session error without busy and clears its attention", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "request-a" } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "UnknownError" } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "UnknownError" } } } });
  await adapter.event({ event: status("session-a", "idle") });
  await adapter.event({ event: { type: "permission.replied", properties: { sessionID: "session-a", requestID: "request-a" } } });

  assert.deepEqual(submitted.map(({ kind, request_id }) => ({ kind, request_id })), [
    { kind: "attention", request_id: "request-a" },
    { kind: "failed", request_id: "" },
  ]);
});

test("fails active sessions for terminal AssistantError variants", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });
  const terminalErrors = ["StructuredOutputError", "ContextOverflowError", "ContentFilterError"];

  for (const [index, name] of terminalErrors.entries()) {
    const sessionID = `session-${index}`;
    await adapter.event({ event: status(sessionID, "busy") });
    await adapter.event({ event: { type: "session.error", properties: { sessionID, error: { name } } } });
  }
  await adapter.event({ event: { type: "session.error", properties: { error: { name: "ContextOverflowError" } } } });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "session-0" },
    { kind: "failed", session_id: "session-0" },
    { kind: "began", session_id: "session-1" },
    { kind: "failed", session_id: "session-1" },
    { kind: "began", session_id: "session-2" },
    { kind: "failed", session_id: "session-2" },
  ]);
});

test("uses the canonical notifier subprocess arguments and JSON payload", async (t) => {
  const calls = [];
  const bunDescriptor = Object.getOwnPropertyDescriptor(globalThis, "Bun");
  Object.defineProperty(globalThis, "Bun", {
    configurable: true,
    value: {
      spawn(command, options) {
      calls.push({ command, options });
      return { exited: Promise.resolve(), kill() {} };
    },
    },
  });
  t.after(() => {
    if (bunDescriptor) Object.defineProperty(globalThis, "Bun", bunDescriptor);
    else delete globalThis.Bun;
  });
  const { client } = createClient();
  const adapter = await agentNotifyPlugin({ client });

  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "request-a" } } });

  assert.deepEqual(calls, [{
    command: ["agent-notify", "event"],
    options: {
      stdin: new TextEncoder().encode("{\"source\":\"opencode\",\"event\":\"attention\",\"session_id\":\"session-a\",\"session_dir\":\"/work/session-a\",\"request_id\":\"request-a\"}"),
      stdout: "ignore",
      stderr: "ignore",
    },
  }]);
});

test("propagates canonical JSON to the notifier process stdin", async (t) => {
  const fixtureDirectory = await mkdtemp(join(tmpdir(), "agent-notify-opencode-"));
  const notifier = join(fixtureDirectory, "notifier.mjs");
  const received = join(fixtureDirectory, "received.json");
  await writeFile(notifier, `#!/usr/bin/env node
import { writeFile } from "node:fs/promises";
let input = "";
for await (const chunk of process.stdin) input += chunk;
await writeFile(process.env.NOTIFIER_OUTPUT, input);
`);
  await chmod(notifier, 0o700);
  t.after(() => rm(fixtureDirectory, { force: true, recursive: true }));

  const bunDescriptor = Object.getOwnPropertyDescriptor(globalThis, "Bun");
  Object.defineProperty(globalThis, "Bun", {
    configurable: true,
    value: {
      spawn(_command, options) {
      const child = spawnChild(notifier, [], {
        env: { ...process.env, NOTIFIER_OUTPUT: received },
        stdio: ["pipe", "ignore", "ignore"],
      });
      child.stdin.end(options.stdin);
      return { exited: once(child, "exit"), kill: () => child.kill() };
    },
    },
  });
  t.after(() => {
    if (bunDescriptor) Object.defineProperty(globalThis, "Bun", bunDescriptor);
    else delete globalThis.Bun;
  });
  const { client } = createClient();
  const adapter = await agentNotifyPlugin({ client });

  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "request-a" } } });

  assert.deepEqual(JSON.parse(await readFile(received, "utf8")), {
    source: "opencode",
    event: "attention",
    session_id: "session-a",
    session_dir: "/work/session-a",
    request_id: "request-a",
  });
});

test("deduplicates busy, terminal errors, and idle events for one active turn", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "UnknownError" } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "session-a", error: { name: "UnknownError" } } } });
  await adapter.event({ event: status("session-a", "idle") });
  await adapter.event({ event: status("session-a", "idle") });

  assert.deepEqual(submitted.map((event) => event.kind), ["began", "failed"]);
});

test("clears attention for only the exact session when a turn terminates", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "a", id: "request-a" } } });
  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "a:similar", id: "request-a" } } });
  await adapter.event({ event: status("a", "busy") });
  await adapter.event({ event: status("a", "idle") });
  await adapter.event({ event: { type: "permission.replied", properties: { sessionID: "a:similar", requestID: "request-a" } } });

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "attention", session_id: "a" },
    { kind: "attention", session_id: "a:similar" },
    { kind: "began", session_id: "a" },
    { kind: "completed", session_id: "a" },
    { kind: "attention-cleared", session_id: "a:similar" },
  ]);
});

test("runs adapter events through the canonical notifier subprocess contract", async (t) => {
  const calls = [];
  const bunDescriptor = Object.getOwnPropertyDescriptor(globalThis, "Bun");
  Object.defineProperty(globalThis, "Bun", {
    configurable: true,
    value: {
      spawn(command, options) {
      calls.push({ command, options });
      return { exited: Promise.resolve(), kill() {} };
    },
    },
  });
  t.after(() => {
    if (bunDescriptor) Object.defineProperty(globalThis, "Bun", bunDescriptor);
    else delete globalThis.Bun;
  });
  const { client } = createClient();
  const adapter = await agentNotifyPlugin({ client });

  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "request-a" } } });

  assert.deepEqual(calls.map(({ command, options }) => ({ command, stdin: JSON.parse(new TextDecoder().decode(options.stdin)) })), [
    {
      command: ["agent-notify", "event"],
      stdin: { source: "opencode", event: "began", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
    },
    {
      command: ["agent-notify", "event"],
      stdin: { source: "opencode", event: "attention", session_id: "session-a", session_dir: "/work/session-a", request_id: "request-a" },
    },
  ]);
});

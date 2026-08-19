import assert from "node:assert/strict";
import { spawn as spawnChild } from "node:child_process";
import { once } from "node:events";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  LEGACY_ATTENTION_EVENTS,
  createBinarySubmitter,
  createOpenCodeAdapter,
} from "../../integrations/opencode/agent-notify.js";

function createClient() {
  const requests = [];
  return {
    requests,
    client: {
      session: {
        async get(request) {
          requests.push(request);
          return { data: { directory: `/work/${request.path.id}` } };
        },
      },
    },
  };
}

function status(sessionID, type) {
  return { type: "session.status", properties: { sessionID, status: { type } } };
}

test("submits one busy-to-idle lifecycle and ignores deprecated session.idle", async () => {
  const { client, requests } = createClient();
  const submitted = [];
  const adapter = createOpenCodeAdapter({ client, submit: async (event) => submitted.push(event) });

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
  const adapter = createOpenCodeAdapter({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session-a", "idle") });

  assert.deepEqual(submitted, []);
  assert.equal(requests.length, 0);
});

test("uses the declared legacy attention family and clears only matching requests", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = createOpenCodeAdapter({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "permission-1" } } });
  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "permission-1" } } });
  await adapter.event({ event: { type: "permission.replied", properties: { sessionID: "session-a", requestID: "permission-2" } } });
  await adapter.event({ event: { type: "permission.replied", properties: { sessionID: "session-a", requestID: "permission-1" } } });
  await adapter.event({ event: { type: "question.asked", properties: { sessionID: "session-a", id: "question-1" } } });
  await adapter.event({ event: { type: "question.rejected", properties: { sessionID: "session-a", requestID: "question-1" } } });

  assert.deepEqual(LEGACY_ATTENTION_EVENTS, [
    "permission.asked", "permission.replied", "question.asked", "question.replied", "question.rejected",
  ]);
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
  const adapter = createOpenCodeAdapter({ client, submit: async (event) => submitted.push(event) });

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
  const adapter = createOpenCodeAdapter({ client, submit: async (event) => submitted.push(event) });

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
  const adapter = createOpenCodeAdapter({ client, submit: async (event) => submitted.push(event) });
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

test("uses the canonical notifier subprocess arguments and JSON payload", async () => {
  const calls = [];
  const submit = createBinarySubmitter({
    binary: "/usr/local/bin/agent-notify",
    spawn(command, options) {
      calls.push({ command, options });
      return { exited: Promise.resolve(), kill() {} };
    },
  });

  await submit({ source: "opencode", kind: "attention", session_id: "session-a", session_dir: "/work/a", request_id: "request-a" });

  assert.deepEqual(calls, [{
    command: ["/usr/local/bin/agent-notify", "event"],
    options: {
      stdin: new TextEncoder().encode("{\"source\":\"opencode\",\"event\":\"attention\",\"session_id\":\"session-a\",\"session_dir\":\"/work/a\",\"request_id\":\"request-a\"}"),
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

  const submit = createBinarySubmitter({
    binary: notifier,
    spawn(command, options) {
      const child = spawnChild(command[0], command.slice(1), {
        env: { ...process.env, NOTIFIER_OUTPUT: received },
        stdio: ["pipe", "ignore", "ignore"],
      });
      child.stdin.end(options.stdin);
      return { exited: once(child, "exit"), kill: () => child.kill() };
    },
  });

  await submit({ source: "opencode", kind: "attention", session_id: "session-a", session_dir: "/work/a", request_id: "request-a" });

  assert.deepEqual(JSON.parse(await readFile(received, "utf8")), {
    source: "opencode",
    event: "attention",
    session_id: "session-a",
    session_dir: "/work/a",
    request_id: "request-a",
  });
});

test("deduplicates busy, terminal errors, and idle events for one active turn", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = createOpenCodeAdapter({ client, submit: async (event) => submitted.push(event) });

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
  const adapter = createOpenCodeAdapter({ client, submit: async (event) => submitted.push(event) });

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

test("runs adapter events through the canonical notifier subprocess contract", async () => {
  const calls = [];
  const submit = createBinarySubmitter({
    binary: "/usr/local/bin/agent-notify",
    spawn(command, options) {
      calls.push({ command, options });
      return { exited: Promise.resolve(), kill() {} };
    },
  });
  const { client } = createClient();
  const adapter = createOpenCodeAdapter({ client, submit });

  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "request-a" } } });

  assert.deepEqual(calls.map(({ command, options }) => ({ command, stdin: JSON.parse(new TextDecoder().decode(options.stdin)) })), [
    {
      command: ["/usr/local/bin/agent-notify", "event"],
      stdin: { source: "opencode", event: "began", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
    },
    {
      command: ["/usr/local/bin/agent-notify", "event"],
      stdin: { source: "opencode", event: "attention", session_id: "session-a", session_dir: "/work/session-a", request_id: "request-a" },
    },
  ]);
});

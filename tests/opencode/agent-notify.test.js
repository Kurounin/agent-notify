import assert from "node:assert/strict";
import { spawn as spawnChild } from "node:child_process";
import { once } from "node:events";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import agentNotifyPluginFactory, * as pluginModule from "../../integrations/opencode/agent-notify.js";

// Excerpt settings are read from an injected path so the suite never touches the live home.
const settingsDirectory = await mkdtemp(join(tmpdir(), "agent-notify-settings-"));
const settingsFile = join(settingsDirectory, "settings.conf");
process.env.AGENT_NOTIFY_SETTINGS_FILE = settingsFile;
process.on("exit", () => rmSync(settingsDirectory, { force: true, recursive: true }));

const inheritedTmux = { TMUX: process.env.TMUX, TMUX_PANE: process.env.TMUX_PANE };
delete process.env.TMUX;
delete process.env.TMUX_PANE;
process.on("exit", () => {
  for (const [key, value] of Object.entries(inheritedTmux)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

const corpus = JSON.parse(readFileSync(new URL("../fixtures/excerpt-corpus.json", import.meta.url), "utf8"));

function createClient({ sessions = {}, getSession, messages, getMessages } = {}) {
  const requests = [];
  const messageRequests = [];
  return {
    requests,
    messageRequests,
    client: {
      session: {
        async get(request) {
          requests.push(request);
          if (getSession) return getSession(request.path.id);
          // OpenCode omits parentID entirely for root sessions.
          return { data: sessions[request.path.id] ?? { directory: `/work/${request.path.id}` } };
        },
        async messages(request) {
          messageRequests.push(request);
          if (getMessages) return getMessages(request.path.id);
          if (!messages) throw new Error("session messages unavailable");
          return { data: messages[request.path.id] ?? [] };
        },
      },
    },
  };
}

function status(sessionID, type) {
  return { type: "session.status", properties: { sessionID, status: { type } } };
}

function retryStatus(sessionID, attempt, action = undefined) {
  const status = { type: "retry", attempt };
  if (action !== undefined) status.action = action;
  return { type: "session.status", properties: { sessionID, status } };
}

function assistantMessage(...parts) {
  return { info: { role: "assistant" }, parts };
}

function textPart(text, extra = {}) {
  return { type: "text", text, ...extra };
}

class FakeScheduler {
  #time = 0;
  timers = [];

  schedule = (callback, delay) => {
    const timer = { callback, due: this.#time + delay, cancelled: false, fired: false };
    this.timers.push(timer);
    return timer;
  };

  clear = (timer) => {
    timer.cancelled = true;
  };

  async advanceBy(delay) {
    this.#time += delay;
    for (const timer of this.timers.filter((entry) => !entry.fired && entry.due <= this.#time)) {
      timer.fired = true;
      if (!timer.cancelled) await timer.callback();
    }
  }

  async fireStale(timer) {
    await timer.callback();
  }
}

async function createAdapter(options) {
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({ ...options, schedule: scheduler.schedule, clear: scheduler.clear });
  return {
    async event(input) {
      await adapter.event(input);
      await scheduler.advanceBy(50);
    },
  };
}

async function agentNotifyPlugin(options) {
  return createAdapter(options);
}

function tmuxChild({ chunks = [new TextEncoder().encode("session\n")], exit = 0 } = {}) {
  let killed = false;
  return {
    child: {
      stdout: (async function* () {
        for (const chunk of await chunks) yield chunk;
      })(),
      exited: Promise.resolve(exit),
      kill() { killed = true; },
    },
    get killed() { return killed; },
  };
}

function deferredTmuxChild() {
  let release;
  const chunks = new Promise((resolve) => { release = resolve; });
  const fixture = tmuxChild({ chunks });
  return {
    child: fixture.child,
    get killed() { return fixture.killed; },
    release(text) { release([new TextEncoder().encode(text)]); },
  };
}

function controlledTmuxChild({ chunks = [], stalled = false, exit = 0 } = {}) {
  let index = 0;
  let returnCalls = 0;
  let killed = false;
  const stdout = {
    [Symbol.asyncIterator]() { return this; },
    next() {
      if (stalled) return new Promise(() => {});
      if (index >= chunks.length) return Promise.resolve({ done: true });
      const value = chunks[index];
      index += 1;
      return Promise.resolve({ done: false, value });
    },
    return() {
      returnCalls += 1;
      return Promise.resolve({ done: true });
    },
  };
  return {
    child: {
      stdout,
      exited: Promise.resolve(exit),
      kill() { killed = true; },
    },
    get killed() { return killed; },
    get returnCalls() { return returnCalls; },
  };
}

test("exports only a callable default plugin factory for the OpenCode loader", () => {
  assert.deepEqual(Object.keys(pluginModule), ["default"]);
  assert.ok(Object.values(pluginModule).every((value) => typeof value === "function"));
});

test("submits one busy-to-idle lifecycle when deprecated session.idle and status idle both arrive", async () => {
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
  assert.equal(requests.length, 3);
});

test("deduplicates prompted and admitted busy signals with session.status busy", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: { type: "session.next.prompted", properties: { sessionID: "session-a", prompt: "private prompt text" } } });
  await adapter.event({ event: { type: "session.next.prompt.admitted", properties: { sessionID: "session-a", prompt: "more private prompt text" } } });
  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: status("session-a", "idle") });

  assert.deepEqual(submitted, [
    { source: "opencode", kind: "began", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
    { source: "opencode", kind: "completed", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
  ]);
});

test("does not complete an idle session without a prior busy status", async () => {
  const { client, requests } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session-a", "idle") });

  assert.deepEqual(submitted, []);
  assert.equal(requests.length, 1);
});

test("alerts once for a retry action while preserving deferred root completion", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });
  const action = {
    reason: "quota",
    provider: "openai",
    title: "Plan limit reached",
    message: "Upgrade your plan",
    label: "Manage plan",
    link: "https://example.test/billing",
  };

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: retryStatus("child", 2, action) });
  await adapter.event({ event: retryStatus("child", 2, action) });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });

  assert.deepEqual(submitted, [
    { source: "opencode", kind: "began", session_id: "root", session_dir: "/work/root", request_id: "" },
    { source: "opencode", kind: "attention", session_id: "child", session_dir: "/work/child", request_id: "retry:2" },
    { source: "opencode", kind: "completed", session_id: "root", session_dir: "/work/root", request_id: "" },
  ]);
});

test("keeps retry statuses without an action lifecycle-only", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: retryStatus("session-a", 1) });
  await adapter.event({ event: status("session-a", "idle") });

  assert.deepEqual(submitted, [
    { source: "opencode", kind: "began", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
    { source: "opencode", kind: "completed", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
  ]);
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

test("retains a tracked root when a lookup failure hides the session tree", async () => {
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

test("shares attention keys between legacy and V2 permission and question events", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "permission-1" } } });
  await adapter.event({ event: { type: "permission.v2.replied", properties: { sessionID: "session-a", requestID: "permission-1" } } });
  await adapter.event({ event: { type: "permission.v2.asked", properties: { sessionID: "session-a", id: "permission-2" } } });
  await adapter.event({ event: { type: "permission.replied", properties: { sessionID: "session-a", requestID: "permission-2" } } });
  await adapter.event({ event: { type: "question.v2.asked", properties: { sessionID: "session-a", id: "question-1" } } });
  await adapter.event({ event: { type: "question.replied", properties: { sessionID: "session-a", requestID: "question-1" } } });
  await adapter.event({ event: { type: "question.asked", properties: { sessionID: "session-a", id: "question-2" } } });
  await adapter.event({ event: { type: "question.v2.rejected", properties: { sessionID: "session-a", requestID: "question-2" } } });
  await adapter.event({ event: { type: "question.v2.asked", properties: { sessionID: "session-a", id: "question-3" } } });
  await adapter.event({ event: { type: "question.v2.replied", properties: { sessionID: "session-a", requestID: "question-3" } } });

  assert.deepEqual(submitted.map(({ kind, request_id }) => ({ kind, request_id })), [
    { kind: "attention", request_id: "permission-1" },
    { kind: "attention-cleared", request_id: "permission-1" },
    { kind: "attention", request_id: "permission-2" },
    { kind: "attention-cleared", request_id: "permission-2" },
    { kind: "attention", request_id: "question-1" },
    { kind: "attention-cleared", request_id: "question-1" },
    { kind: "attention", request_id: "question-2" },
    { kind: "attention-cleared", request_id: "question-2" },
    { kind: "attention", request_id: "question-3" },
    { kind: "attention-cleared", request_id: "question-3" },
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

test("uses and clears the 10-second outer subprocess deadline", async (t) => {
  const scheduled = [];
  const cleared = [];
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  const bunDescriptor = Object.getOwnPropertyDescriptor(globalThis, "Bun");
  globalThis.setTimeout = (_callback, delay) => {
    const timer = { delay };
    scheduled.push(timer);
    return timer;
  };
  globalThis.clearTimeout = (timer) => cleared.push(timer);
  Object.defineProperty(globalThis, "Bun", {
    configurable: true,
    value: {
      spawn() {
        return { exited: Promise.resolve(), kill() {} };
      },
    },
  });
  t.after(() => {
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
    if (bunDescriptor) Object.defineProperty(globalThis, "Bun", bunDescriptor);
    else delete globalThis.Bun;
  });
  const { client } = createClient();
  const adapter = await agentNotifyPlugin({ client });

  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "request-a" } } });

  assert.deepEqual(scheduled, [{ delay: 10_000 }]);
  assert.deepEqual(cleared, scheduled);
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

test("carries the tail of the root session's last assistant message on a completion", async () => {
  const { client, messageRequests } = createClient({
    messages: {
      "session-a": [
        { info: { role: "user" }, parts: [textPart("run the suite")] },
        assistantMessage(textPart("All 14 tests pass.")),
      ],
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: status("session-a", "idle") });

  assert.deepEqual(submitted, [
    { source: "opencode", kind: "began", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
    { source: "opencode", kind: "completed", session_id: "session-a", session_dir: "/work/session-a", request_id: "", excerpt: "All 14 tests pass." },
  ]);
  assert.deepEqual(messageRequests, [{ path: { id: "session-a" }, query: { limit: 12 } }]);
});

test("takes a deferred root completion's excerpt from the root, never from a descendant", async () => {
  const { client, messageRequests } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
    messages: {
      root: [assistantMessage(textPart("A focused lifecycle review is still running."))],
      child: [assistantMessage(textPart("Subagent internal report."))],
    },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });

  // The excerpt predates the background work it was waiting on; that staleness is accepted.
  assert.deepEqual(submitted.map(({ kind, session_id, excerpt }) => ({ kind, session_id, excerpt })), [
    { kind: "began", session_id: "root", excerpt: undefined },
    { kind: "completed", session_id: "root", excerpt: "A focused lifecycle review is still running." },
  ]);
  assert.deepEqual(messageRequests.map((request) => request.path.id), ["root"]);
});

test("selects only non-synthetic, non-ignored text parts of the most recent assistant message", async () => {
  const cases = [
    { parts: [textPart("hidden", { synthetic: true }), textPart("visible")], excerpt: "visible" },
    { parts: [textPart("hidden", { ignored: true }), textPart("visible")], excerpt: "visible" },
    { parts: [{ type: "reasoning", text: "thinking out loud" }], excerpt: undefined },
    { parts: [textPart("only synthetic", { synthetic: true })], excerpt: undefined },
    { parts: [textPart("   ")], excerpt: undefined },
  ];

  for (const [index, entry] of cases.entries()) {
    const sessionID = `session-${index}`;
    const { client } = createClient({
      messages: {
        [sessionID]: [
          assistantMessage(textPart("an older assistant message")),
          assistantMessage(...entry.parts),
        ],
      },
    });
    const submitted = [];
    const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

    await adapter.event({ event: status(sessionID, "busy") });
    await adapter.event({ event: status(sessionID, "idle") });

    assert.equal(submitted[1].excerpt, entry.excerpt, `case ${index}`);
  }
});

test("treats both message-fetch failure modes as no excerpt available", async () => {
  for (const getMessages of [() => { throw new Error("transport failure"); }, () => ({ data: undefined, error: {} })]) {
    const { client } = createClient({ getMessages });
    const submitted = [];
    const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

    await adapter.event({ event: status("session-a", "busy") });
    await adapter.event({ event: status("session-a", "idle") });

    assert.deepEqual(submitted.map(({ kind, excerpt }) => ({ kind, excerpt })), [
      { kind: "began", excerpt: undefined },
      { kind: "completed", excerpt: undefined },
    ]);
  }
});

test("times out a stalled message fetch and submits an excerpt-free completion", async (t) => {
  const scheduled = [];
  const cleared = [];
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  globalThis.setTimeout = (callback, delay) => {
    const timer = { callback, delay };
    scheduled.push(timer);
    return timer;
  };
  globalThis.clearTimeout = (timer) => cleared.push(timer);
  t.after(() => {
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  });
  let markMessagesRequested;
  const messagesRequested = new Promise((resolve) => {
    markMessagesRequested = resolve;
  });
  const { client } = createClient({
    getMessages: () => {
      markMessagesRequested();
      return new Promise(() => {});
    },
  });
  const submitted = [];
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: status("session-a", "idle") });
  const completion = scheduler.advanceBy(50);
  await messagesRequested;
  assert.deepEqual(scheduled.map(({ delay }) => delay), [1_000]);
  scheduled[0].callback();
  await completion;

  assert.deepEqual(submitted, [
    { source: "opencode", kind: "began", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
    { source: "opencode", kind: "completed", session_id: "session-a", session_dir: "/work/session-a", request_id: "" },
  ]);
  assert.deepEqual(cleared, scheduled);
});

test("carries the terminal error's message and falls back to its name", async () => {
  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  await adapter.event({ event: { type: "session.error", properties: { sessionID: "with-message", error: { name: "ProviderAuthError", data: { message: "invalid api key" } } } } });
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "without-message", error: { name: "MessageOutputLengthError" } } } });

  assert.deepEqual(submitted.map(({ kind, excerpt }) => ({ kind, excerpt })), [
    { kind: "failed", excerpt: "invalid api key" },
    { kind: "failed", excerpt: "MessageOutputLengthError" },
  ]);
});

test("drops only the excerpt when the encoded payload would exceed its transport bound", async (t) => {
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

  const wide = "実".repeat(256);
  const { client } = createClient({
    sessions: { [wide]: { directory: `/${"実".repeat(255)}` } },
    messages: { [wide]: [assistantMessage(textPart("完了".repeat(200)))] },
  });
  const adapter = await agentNotifyPlugin({ client });

  await adapter.event({ event: status(wide, "busy") });
  await adapter.event({ event: status(wide, "idle") });

  const payloads = calls.map(({ options }) => JSON.parse(new TextDecoder().decode(options.stdin)));
  assert.equal(payloads.length, 2);
  assert.equal(payloads[1].event, "completed");
  assert.equal(payloads[1].excerpt, undefined);
});

test("honours the excerpt setting per decision, including a change made mid-session", async (t) => {
  t.after(() => rmSync(settingsFile, { force: true }));
  const { client, messageRequests } = createClient({
    messages: { "session-a": [assistantMessage(textPart("All 14 tests pass."))] },
  });
  const submitted = [];
  const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

  const completeOnce = async (sessionID) => {
    await adapter.event({ event: status(sessionID, "busy") });
    await adapter.event({ event: status(sessionID, "idle") });
    return submitted.at(-1).excerpt;
  };

  rmSync(settingsFile, { force: true });
  assert.equal(await completeOnce("session-a"), "All 14 tests pass.");
  writeFileSync(settingsFile, "# agent-notify settings\nEXCERPT=1\n");
  assert.equal(await completeOnce("session-a"), "All 14 tests pass.");
  writeFileSync(settingsFile, "this file is not key=value at all\n");
  assert.equal(await completeOnce("session-a"), "All 14 tests pass.");

  const requestsBefore = messageRequests.length;
  writeFileSync(settingsFile, "# agent-notify settings\nEXCERPT=0\n");
  assert.equal(await completeOnce("session-a"), undefined);
  // Disabled means the messages are never requested, not merely never forwarded.
  assert.equal(messageRequests.length, requestsBefore);
});

test("produces the corpus excerpt for every sanitisation case", async () => {
  for (const [index, entry] of corpus.cases.entries()) {
    const sessionID = `corpus-${index}`;
    const { client } = createClient({
      messages: { [sessionID]: [assistantMessage(textPart(entry.input))] },
    });
    const submitted = [];
    const adapter = await agentNotifyPlugin({ client, submit: async (event) => submitted.push(event) });

    await adapter.event({ event: status(sessionID, "busy") });
    await adapter.event({ event: status(sessionID, "idle") });

    assert.equal(submitted[1].excerpt, entry.excerpt === "" ? undefined : entry.excerpt, entry.name);
  }
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

test("debounces a plain root completion and reuses its candidate for compatibility idle", async () => {
  const { client } = createClient();
  const submitted = [];
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: { type: "session.idle", properties: { sessionID: "root" } } });
  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);
  assert.equal(scheduler.timers.filter((timer) => !timer.cancelled).length, 1);

  await scheduler.advanceBy(49);
  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);
  await scheduler.advanceBy(1);
  assert.deepEqual(submitted.map((event) => event.kind), ["began", "completed"]);
});

test("cancels a stale descendant-settlement candidate when the root resumes", async () => {
  const { client } = createClient({
    sessions: {
      root: { directory: "/work/root" },
      child: { directory: "/work/child", parentID: "root" },
    },
  });
  const submitted = [];
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });
  const stale = scheduler.timers.at(-1);
  await adapter.event({ event: status("root", "busy") });
  await scheduler.fireStale(stale);
  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);

  await adapter.event({ event: status("root", "idle") });
  await scheduler.advanceBy(50);
  assert.deepEqual(submitted.map((event) => event.kind), ["began", "completed"]);
});

test("does not complete when the root becomes busy during deferred excerpt retrieval", async () => {
  let resolveMessages;
  const messagesRequested = new Promise((resolve) => {
    resolveMessages = resolve;
  });
  const { client } = createClient({
    getMessages() {
      return messagesRequested;
    },
  });
  const submitted = [];
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });
  const completion = scheduler.advanceBy(50);
  await Promise.resolve();
  await adapter.event({ event: status("root", "busy") });
  resolveMessages({ data: [] });
  await completion;

  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);
});

test("cancels a root completion candidate when the root terminates", async () => {
  const { client } = createClient();
  const submitted = [];
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });
  const stale = scheduler.timers.at(-1);
  await adapter.event({ event: { type: "session.error", properties: { sessionID: "root", error: { name: "UnknownError" } } } });
  await scheduler.fireStale(stale);

  assert.deepEqual(submitted.map((event) => event.kind), ["began", "failed"]);
});

test("uses tracked-tree fallback after lookup failure before releasing the root", async () => {
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
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  rootLookupFails = true;
  await adapter.event({ event: status("root", "idle") });
  rootLookupFails = false;
  await adapter.event({ event: status("child", "idle") });

  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);
  assert.equal(scheduler.timers.filter((timer) => !timer.cancelled && !timer.fired).length, 1);
  await scheduler.advanceBy(50);

  assert.deepEqual(submitted.map(({ kind, session_id }) => ({ kind, session_id })), [
    { kind: "began", session_id: "root" },
    { kind: "completed", session_id: "root" },
  ]);
});

test("cancels a known root candidate before a deferred busy lookup resolves", async () => {
  let deferLookup = false;
  let resolveLookup;
  const lookup = new Promise((resolve) => {
    resolveLookup = resolve;
  });
  const sessions = { root: { directory: "/work/root" } };
  const { client } = createClient({
    getSession(sessionID) {
      return deferLookup ? lookup : { data: sessions[sessionID] };
    },
  });
  const submitted = [];
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("root", "idle") });
  const stale = scheduler.timers.at(-1);
  deferLookup = true;
  const resumed = adapter.event({ event: status("root", "busy") });

  assert.equal(stale.cancelled, true);
  await scheduler.fireStale(stale);
  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);
  resolveLookup({ data: sessions.root });
  await resumed;
  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);

  deferLookup = false;
  await adapter.event({ event: status("root", "idle") });
  await scheduler.advanceBy(50);
  assert.deepEqual(submitted.map((event) => event.kind), ["began", "completed"]);
});

test("cancels a known descendant retry candidate before its deferred lookup resolves", async () => {
  let deferLookup = false;
  let resolveLookup;
  const lookup = new Promise((resolve) => {
    resolveLookup = resolve;
  });
  const sessions = {
    root: { directory: "/work/root" },
    child: { directory: "/work/child", parentID: "root" },
  };
  const { client } = createClient({
    getSession(sessionID) {
      return deferLookup ? lookup : { data: sessions[sessionID] };
    },
  });
  const submitted = [];
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });
  const stale = scheduler.timers.at(-1);
  deferLookup = true;
  const retried = adapter.event({ event: retryStatus("child", 1) });

  assert.equal(stale.cancelled, true);
  await scheduler.fireStale(stale);
  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);
  resolveLookup({ data: sessions.child });
  await retried;

  deferLookup = false;
  await adapter.event({ event: status("child", "idle") });
  await scheduler.advanceBy(50);
  assert.deepEqual(submitted.map((event) => event.kind), ["began", "completed"]);
});

test("cancels a known descendant candidate before its deferred terminal lookup resolves", async () => {
  let deferLookup = false;
  let resolveLookup;
  const lookup = new Promise((resolve) => {
    resolveLookup = resolve;
  });
  const sessions = {
    root: { directory: "/work/root" },
    child: { directory: "/work/child", parentID: "root" },
  };
  const { client } = createClient({
    getSession(sessionID) {
      return deferLookup ? lookup : { data: sessions[sessionID] };
    },
  });
  const submitted = [];
  const scheduler = new FakeScheduler();
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
  });

  await adapter.event({ event: status("root", "busy") });
  await adapter.event({ event: status("child", "busy") });
  await adapter.event({ event: status("root", "idle") });
  await adapter.event({ event: status("child", "idle") });
  const stale = scheduler.timers.at(-1);
  deferLookup = true;
  const failed = adapter.event({ event: { type: "session.error", properties: { sessionID: "child", error: { name: "UnknownError" } } } });

  assert.equal(stale.cancelled, true);
  await scheduler.fireStale(stale);
  assert.deepEqual(submitted.map((event) => event.kind), ["began"]);
  resolveLookup({ data: sessions.child });
  await failed;
  assert.deepEqual(submitted.map((event) => event.kind), ["began", "failed"]);

  await scheduler.advanceBy(50);
  assert.deepEqual(submitted.map((event) => event.kind), ["began", "failed", "completed"]);
});

test("discovers one absolute tmux executable and gates pane-targeted lookups to notification kinds", async () => {
  const { client } = createClient();
  const submitted = [];
  const environment = { TMUX: "tmux-environment-marker", TMUX_PANE: "%42" };
  const calls = [];
  let discoveries = 0;
  const child = tmuxChild({ chunks: [new TextEncoder().encode("team/api\n")] });
  const adapter = await agentNotifyPlugin({
    client,
    submit: async (event) => submitted.push(event),
    environment,
    which(command) {
      discoveries += 1;
      assert.equal(command, "tmux");
      return "/private path/tmux executable";
    },
    tmuxSpawn(command, options) {
      calls.push({ command, options });
      return child.child;
    },
  });

  assert.equal(discoveries, 1);
  await adapter.event({ event: status("session-a", "busy") });
  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session-a", id: "request-a" } } });
  await adapter.event({ event: { type: "permission.replied", properties: { sessionID: "session-a", requestID: "request-a" } } });
  environment.TMUX_PANE = "not-a-pane";
  await adapter.event({ event: { type: "question.asked", properties: { sessionID: "session-a", id: "request-b" } } });

  assert.deepEqual(calls, [{
    command: ["/private path/tmux executable", "display-message", "-p", "-t", "%42", "#S"],
    options: { stdout: "pipe", stderr: "ignore" },
  }]);
  assert.deepEqual(submitted.map(({ kind, tmux_session }) => ({ kind, tmux_session })), [
    { kind: "began", tmux_session: undefined },
    { kind: "attention", tmux_session: "team/api" },
    { kind: "attention-cleared", tmux_session: undefined },
    { kind: "attention", tmux_session: undefined },
  ]);

  const relativeSubmitted = [];
  const relativeAdapter = await agentNotifyPlugin({
    client: createClient().client,
    submit: async (event) => relativeSubmitted.push(event),
    environment: { TMUX: "present", TMUX_PANE: "%1" },
    which: () => "tmux",
    tmuxSpawn() { throw new Error("relative executable must not run"); },
  });
  await relativeAdapter.event({ event: { type: "permission.asked", properties: { sessionID: "relative", id: "request" } } });
  assert.equal(relativeSubmitted[0].tmux_session, undefined);
});

test("fails open without leaking rejected tmux inputs or process failures", async () => {
  const rejected = [
    { name: "nonzero", chunks: [new TextEncoder().encode("stdout-marker\n")], exit: 1 },
    { name: "malformed UTF-8", chunks: [new Uint8Array([0xc3, 0x28])] },
    { name: "multiline", chunks: [new TextEncoder().encode("stdout-marker\nnext")] },
    { name: "C0", chunks: [new TextEncoder().encode("stdout-marker\u0001")] },
    { name: "DEL", chunks: [new TextEncoder().encode("stdout-marker\u007f")] },
    { name: "empty", chunks: [] },
  ];

  for (const entry of rejected) {
    const { client } = createClient();
    const submitted = [];
    const adapter = await agentNotifyPlugin({
      client,
      submit: async (event) => submitted.push(event),
      environment: { TMUX: "tmux-environment-marker", TMUX_PANE: "%999" },
      which: () => "/private executable-marker/tmux path",
      tmuxSpawn: () => {
        const child = tmuxChild(entry).child;
        child.stderr = new TextEncoder().encode("stderr-marker");
        return child;
      },
    });
    await adapter.event({ event: { type: "permission.asked", properties: { sessionID: entry.name, id: "request" } } });

    assert.equal(submitted[0].tmux_session, undefined, entry.name);
    assert.doesNotMatch(JSON.stringify(submitted), /tmux-environment-marker|999|executable-marker|stdout-marker|stderr-marker/);
  }

  const { client } = createClient();
  const submitted = [];
  const adapter = await agentNotifyPlugin({
    client,
    submit: async (event) => submitted.push(event),
    environment: { TMUX: "tmux-environment-marker", TMUX_PANE: "%999" },
    which: () => "/private executable-marker/tmux path",
    tmuxSpawn() { throw new Error("command-error-marker"); },
  });
  await adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session", id: "request" } } });
  assert.equal(submitted[0].tmux_session, undefined);
  assert.doesNotMatch(JSON.stringify(submitted), /tmux-environment-marker|999|executable-marker|command-error-marker/);
});

test("suppresses pane lookup for an empty TMUX marker and a pane longer than 255 digits", async () => {
  const cases = [
    { name: "empty TMUX", environment: { TMUX: "", TMUX_PANE: "%1" }, expectedCalls: 0 },
    { name: "255 pane digits", environment: { TMUX: "present", TMUX_PANE: `%${"9".repeat(255)}` }, expectedCalls: 1 },
    { name: "256 pane digits", environment: { TMUX: "present", TMUX_PANE: `%${"9".repeat(256)}` }, expectedCalls: 0 },
  ];

  for (const entry of cases) {
    const { client } = createClient();
    const submitted = [];
    const calls = [];
    const adapter = await agentNotifyPlugin({
      client,
      submit: async (event) => submitted.push(event),
      environment: entry.environment,
      which: () => "/tmp/tmux",
      tmuxSpawn(command) {
        calls.push(command);
        return tmuxChild({ chunks: [new TextEncoder().encode("session-name\n")] }).child;
      },
    });

    await adapter.event({ event: { type: "permission.asked", properties: { sessionID: entry.name, id: "request" } } });

    assert.equal(calls.length, entry.expectedCalls, entry.name);
    assert.equal(submitted[0].tmux_session, entry.expectedCalls ? "session-name" : undefined, entry.name);
  }
});

test("omits whitespace-only and overlong tmux stdout without treating it as context", async () => {
  const cases = [
    { name: "whitespace", output: "  \n" },
    { name: "257 UTF-16 units", output: "a".repeat(257) },
  ];

  for (const entry of cases) {
    const submitted = [];
    const adapter = await agentNotifyPlugin({
      client: createClient().client,
      submit: async (event) => submitted.push(event),
      environment: { TMUX: "present", TMUX_PANE: "%1" },
      which: () => "/tmp/tmux",
      tmuxSpawn: () => tmuxChild({ chunks: [new TextEncoder().encode(entry.output)] }).child,
    });

    await adapter.event({ event: { type: "permission.asked", properties: { sessionID: entry.name, id: "request" } } });

    assert.equal(submitted[0].tmux_session, undefined, entry.name);
    assert.doesNotMatch(JSON.stringify(submitted), /session-name|a{257}/, entry.name);
  }
});

test("allows exactly 1,024 tmux stdout bytes to finish normally but rejects 1,025 bytes", async () => {
  const exact = controlledTmuxChild({ chunks: [new Uint8Array(1_024).fill(0x61)] });
  const overflow = controlledTmuxChild({
    chunks: [new Uint8Array(1_025).fill(0x61), new TextEncoder().encode("overflow-late-marker\n")],
  });
  const results = [];

  for (const [name, fixture] of [["exact", exact], ["overflow", overflow]]) {
    const submitted = [];
    const adapter = await agentNotifyPlugin({
      client: createClient().client,
      submit: async (event) => submitted.push(event),
      environment: { TMUX: "present", TMUX_PANE: "%1" },
      which: () => "/tmp/tmux",
      tmuxSpawn: () => fixture.child,
    });
    await adapter.event({ event: { type: "permission.asked", properties: { sessionID: name, id: "request" } } });
    results.push({ submitted, fixture });
  }

  assert.equal(results[0].fixture.killed, false);
  assert.equal(results[0].fixture.returnCalls, 0);
  assert.equal(results[0].submitted[0].tmux_session, undefined);
  assert.equal(results[1].fixture.killed, true);
  assert.equal(results[1].fixture.returnCalls, 1);
  assert.equal(results[1].submitted[0].tmux_session, undefined);
  assert.doesNotMatch(JSON.stringify(results[1].submitted), /overflow-late-marker/);
});

test("cannot accept or leak tmux output delivered after its deadline", async () => {
  const submitted = [];
  const late = deferredTmuxChild();
  let deadline;
  const adapter = await agentNotifyPlugin({
    client: createClient().client,
    submit: async (event) => submitted.push(event),
    environment: { TMUX: "present", TMUX_PANE: "%1" },
    which: () => "/tmp/tmux",
    tmuxSpawn: () => late.child,
    tmuxSetTimeout(callback, delay) {
      assert.equal(delay, 500);
      deadline = callback;
      return {};
    },
    tmuxClearTimeout() {},
  });

  const pending = adapter.event({ event: { type: "permission.asked", properties: { sessionID: "deadline", id: "request" } } });
  await Promise.resolve();
  await Promise.resolve();
  deadline();
  await pending;
  late.release("deadline-late-marker\n");
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(late.killed, true);
  assert.equal(submitted[0].tmux_session, undefined);
  assert.doesNotMatch(JSON.stringify(submitted), /deadline-late-marker/);
});

test("terminates tmux lookups on the 500 ms deadline and 1,024-byte overflow", async () => {
  const { client } = createClient();
  const submitted = [];
  const hanging = controlledTmuxChild({ stalled: true });
  let deadline;
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    environment: { TMUX: "present", TMUX_PANE: "%1" },
    which: () => "/tmp/tmux",
    tmuxSpawn: () => hanging.child,
    tmuxSetTimeout(callback, delay) {
      assert.equal(delay, 500);
      deadline = callback;
      return { delay };
    },
    tmuxClearTimeout() {},
  });
  const pending = adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session", id: "request" } } });
  await Promise.resolve();
  await Promise.resolve();
  deadline();
  await pending;

  assert.equal(hanging.killed, true);
  assert.equal(hanging.returnCalls, 1);
  assert.equal(submitted[0].tmux_session, undefined);

  const overflow = controlledTmuxChild({ chunks: [new Uint8Array(1_025)] });
  const overflowSubmitted = [];
  const overflowAdapter = await agentNotifyPlugin({
    client: createClient().client,
    submit: async (event) => overflowSubmitted.push(event),
    environment: { TMUX: "present", TMUX_PANE: "%1" },
    which: () => "/tmp/tmux",
    tmuxSpawn: () => overflow.child,
  });
  await overflowAdapter.event({ event: { type: "permission.asked", properties: { sessionID: "overflow", id: "request" } } });

  assert.equal(overflow.killed, true);
  assert.equal(overflow.returnCalls, 1);
  assert.equal(overflowSubmitted[0].tmux_session, undefined);
});

test("keeps same-session attention submissions FIFO while tmux lookup is pending", async () => {
  const { client } = createClient();
  const submitted = [];
  const tmux = deferredTmuxChild();
  let started;
  const lookupStarted = new Promise((resolve) => { started = resolve; });
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    environment: { TMUX: "present", TMUX_PANE: "%1" },
    which: () => "/tmp/tmux",
    tmuxSpawn() {
      started();
      return tmux.child;
    },
  });

  const asked = adapter.event({ event: { type: "permission.asked", properties: { sessionID: "session", id: "request" } } });
  await lookupStarted;
  const replied = adapter.event({ event: { type: "permission.replied", properties: { sessionID: "session", requestID: "request" } } });
  await Promise.resolve();
  await Promise.resolve();
  assert.deepEqual(submitted, []);

  tmux.release("ordered-name\n");
  await Promise.all([asked, replied]);
  assert.deepEqual(submitted.map(({ kind, tmux_session }) => ({ kind, tmux_session })), [
    { kind: "attention", tmux_session: "ordered-name" },
    { kind: "attention-cleared", tmux_session: undefined },
  ]);
});

test("finishes failed-tree bookkeeping before a pending tmux notification", async () => {
  const { client } = createClient();
  const submitted = [];
  const scheduler = new FakeScheduler();
  const tmux = deferredTmuxChild();
  let spawnCount = 0;
  let started;
  const lookupStarted = new Promise((resolve) => { started = resolve; });
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    schedule: scheduler.schedule,
    clear: scheduler.clear,
    environment: { TMUX: "present", TMUX_PANE: "%1" },
    which: () => "/tmp/tmux",
    tmuxSpawn() {
      spawnCount += 1;
      if (spawnCount === 1) {
        started();
        return tmux.child;
      }
      return tmuxChild().child;
    },
  });

  await adapter.event({ event: status("root", "busy") });
  const failed = adapter.event({ event: { type: "session.error", properties: { sessionID: "root", error: { name: "UnknownError" } } } });
  await lookupStarted;
  const restarted = adapter.event({ event: status("root", "busy") });
  await Promise.resolve();
  await Promise.resolve();
  const settled = adapter.event({ event: status("root", "idle") });
  await settled;

  tmux.release("failed-name\n");
  await Promise.all([failed, restarted]);
  await scheduler.advanceBy(50);
  assert.deepEqual(submitted.map((event) => event.kind), ["began", "failed", "began", "completed"]);
});

test("uses fresh emission-local tmux results for concurrent and renamed panes", async () => {
  const { client } = createClient();
  const submitted = [];
  const environment = { TMUX: "present", TMUX_PANE: "%1" };
  const first = deferredTmuxChild();
  const second = deferredTmuxChild();
  const calls = [];
  let announceFirst;
  let announceSecond;
  const firstStarted = new Promise((resolve) => { announceFirst = resolve; });
  const secondStarted = new Promise((resolve) => { announceSecond = resolve; });
  const adapter = await agentNotifyPluginFactory({
    client,
    submit: async (event) => submitted.push(event),
    environment,
    which: () => "/tmp/tmux",
    tmuxSpawn(command) {
      calls.push(command);
      if (calls.length === 1) {
        announceFirst();
        return first.child;
      }
      announceSecond();
      return second.child;
    },
  });

  const firstEvent = adapter.event({ event: { type: "permission.asked", properties: { sessionID: "first", id: "first" } } });
  await firstStarted;
  environment.TMUX_PANE = "%2";
  const secondEvent = adapter.event({ event: { type: "permission.asked", properties: { sessionID: "second", id: "second" } } });
  await secondStarted;
  second.release("second-name\n");
  await secondEvent;
  first.release("first-name\n");
  await firstEvent;

  assert.deepEqual(calls, [
    ["/tmp/tmux", "display-message", "-p", "-t", "%1", "#S"],
    ["/tmp/tmux", "display-message", "-p", "-t", "%2", "#S"],
  ]);
  assert.deepEqual(submitted.map(({ session_id, tmux_session }) => ({ session_id, tmux_session })), [
    { session_id: "second", tmux_session: "second-name" },
    { session_id: "first", tmux_session: "first-name" },
  ]);

  const renamed = [];
  const renameAdapter = await agentNotifyPlugin({
    client: createClient().client,
    submit: async (event) => renamed.push(event),
    environment: { TMUX: "present", TMUX_PANE: "%3" },
    which: () => "/tmp/tmux",
    tmuxSpawn: (() => {
      const names = ["before-rename\n", "after-rename\n"];
      return () => tmuxChild({ chunks: [new TextEncoder().encode(names.shift())] }).child;
    })(),
  });
  await renameAdapter.event({ event: { type: "permission.asked", properties: { sessionID: "rename", id: "one" } } });
  await renameAdapter.event({ event: { type: "question.asked", properties: { sessionID: "rename", id: "two" } } });
  assert.deepEqual(renamed.map((event) => event.tmux_session), ["before-rename", "after-rename"]);
});

test("drops tmux context before excerpts at the OpenCode payload bound", async (t) => {
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

  const wide = "実".repeat(256);
  const directory = `/${"実".repeat(255)}`;
  const tmuxSpawn = () => tmuxChild({ chunks: [new TextEncoder().encode("t".repeat(256))] }).child;
  const environment = { TMUX: "present", TMUX_PANE: "%1" };

  const excerptFits = createClient({
    sessions: { [wide]: { directory } },
    messages: { [wide]: [assistantMessage(textPart("x".repeat(199)))] },
  });
  const adapter = await agentNotifyPlugin({
    client: excerptFits.client,
    environment,
    which: () => "/tmp/tmux",
    tmuxSpawn,
  });
  await adapter.event({ event: status(wide, "busy") });
  await adapter.event({ event: status(wide, "idle") });
  const retainedExcerpt = JSON.parse(new TextDecoder().decode(calls.at(-1).options.stdin));
  assert.equal(retainedExcerpt.tmux_session, undefined);
  assert.equal(retainedExcerpt.excerpt, "x".repeat(199));

  calls.length = 0;
  const excerptTooLarge = createClient({
    sessions: { [wide]: { directory } },
    messages: { [wide]: [assistantMessage(textPart("😀".repeat(120)))] },
  });
  const oversizedExcerptAdapter = await agentNotifyPlugin({
    client: excerptTooLarge.client,
    environment,
    which: () => "/tmp/tmux",
    tmuxSpawn,
  });
  await oversizedExcerptAdapter.event({ event: status(wide, "busy") });
  await oversizedExcerptAdapter.event({ event: status(wide, "idle") });
  const baseOnly = JSON.parse(new TextDecoder().decode(calls.at(-1).options.stdin));
  assert.equal(baseOnly.tmux_session, undefined);
  assert.equal(baseOnly.excerpt, undefined);

  calls.length = 0;
  const baseOversized = createClient({ sessions: { [wide]: { directory } } });
  const baseOversizedAdapter = await agentNotifyPlugin({ client: baseOversized.client });
  await baseOversizedAdapter.event({
    event: { type: "permission.asked", properties: { sessionID: wide, id: wide } },
  });
  assert.deepEqual(calls, []);
});

import assert from "node:assert/strict";
import plugin from "../../integrations/opencode/agent-notify.js";

// Sanitized structural fixtures pinned to OpenCode v2.0.27 packages/schema/src/
// {event,session-event,session-status-event,session,permission,form,session-message,session-error,shell}.ts.
let nextEventID = 0;
export function native(type, sessionID, data = {}, extra = {}) {
  return { id: `evt_fixture_${++nextEventID}`, created: 0, type,
    data: { ...(sessionID === undefined ? {} : { sessionID }), ...data }, ...extra };
}
export const shellCreated = (id, sessionID, info = {}) => native("shell.created", undefined, { info: {
  id, status: "running", command: "private-command-sentinel", cwd: "/private/cwd-sentinel", shell: "/bin/zsh",
  file: "/private/capture-sentinel", pid: 123, metadata: { sessionID, secret: "private-metadata-sentinel" },
  time: { started: 0 }, ...info,
} });
export const shellExited = (id, status = "exited", exit = 0) => native("shell.exited", undefined, { id, status, exit });
export const shellDeleted = (id) => native("shell.deleted", undefined, { id });
export const execution = (id, outcome, data) => native(`session.execution.${outcome}`, id, data);
export const status = (id, type, extra = {}) => native("session.status", id, { status: { type, ...extra } });
export const inbox = (id, action, inboxID) => native(`session.inbox.${action}`, id, { inboxID,
  ...(action === "enqueued" ? { item: { type: "synthetic", text: "private-item-sentinel" } } : {}) });
export const session = (id, parentID, directory = `/work/${id}`) => ({ id, location: { directory },
  ...(parentID === undefined ? {} : { parentID }) });
export const text = (value, extra = {}) => ({ type: "text", text: value, ...extra });
export const assistant = (...content) => ({ type: "assistant", content });

export function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

export async function flush() {
  // Drain detached intake, bounded lookups and per-session FIFO promise continuations.
  for (let index = 0; index < 150; index += 1) await Promise.resolve();
}

export class FakeScheduler {
  time = 0;
  timers = [];
  schedule = (callback, delay) => {
    const timer = { callback, delay, due: this.time + delay, cancelled: false, fired: false };
    this.timers.push(timer);
    return timer;
  };
  clear = (timer) => { if (timer) timer.cancelled = true; };
  async advanceBy(delay) {
    this.time += delay;
    for (const timer of this.timers.filter((entry) => !entry.fired && entry.due <= this.time)) {
      timer.fired = true;
      if (!timer.cancelled) timer.callback();
    }
    await flush();
  }
  get pending() { return this.timers.filter((timer) => !timer.cancelled && !timer.fired); }
}

export class EventStream {
  values = [];
  waiters = [];
  stopped = false;
  error = undefined;
  subscribeCalls = 0;
  signal = undefined;
  push(value) {
    const waiter = this.waiters.shift();
    if (waiter) waiter.resolve({ value, done: false });
    else this.values.push(value);
  }
  end(error) {
    this.stopped = true;
    this.error = error;
    for (const waiter of this.waiters.splice(0)) {
      if (error) waiter.reject(error);
      else waiter.resolve({ done: true });
    }
  }
  subscribe = ({ signal }) => {
    this.subscribeCalls += 1;
    this.signal = signal;
    signal.addEventListener("abort", () => this.end(), { once: true });
    return {
      [Symbol.asyncIterator]: () => ({
        next: () => {
          if (this.stopped) return this.error ? Promise.reject(this.error) : Promise.resolve({ done: true });
          if (this.values.length) return Promise.resolve({ value: this.values.shift(), done: false });
          const waiter = deferred();
          this.waiters.push(waiter);
          return waiter.promise;
        },
        return: () => { this.end(); return Promise.resolve({ done: true }); },
      }),
    };
  };
}

// The pinned bus snapshots routes: a move reaches both owners, later events only
// the destination. The public envelope may still carry the old location.
export class LocationRouter {
  observers = [];
  owners = new Map();
  attach(location, stream) { this.observers.push({ location, stream }); }
  async emit(...events) {
    for (const event of events) {
      const id = event.data.sessionID;
      const owner = this.owners.get(id);
      let routes = [owner];
      if (event.type === "session.created") {
        this.owners.set(id, event.data.location);
        routes = [event.location ?? event.data.location];
      } else if (event.type === "session.moved") {
        this.owners.set(id, event.data.location);
        routes = [owner, event.data.location];
      } else if (event.type === "session.deleted") {
        this.owners.delete(id);
      } else if (event.location) routes = [event.location];
      for (const { location, stream } of this.observers) {
        if (routes.some((ref) => ref && ref.directory === location.directory && ref.workspaceID === location.workspaceID)) stream.push(event);
      }
      await flush();
    }
  }
}

export function createHarness(t, { sessions = {}, getSession, contexts = {}, getContext, delivery,
  definition = plugin, scheduler = new FakeScheduler(), stream = new EventStream(),
  location = { directory: "/wrong/plugin-instance" } } = {}) {
  const calls = [];
  const getRequests = [];
  const contextRequests = [];
  const actions = [];
  const originalBun = Object.getOwnPropertyDescriptor(globalThis, "Bun");
  const originalSchedule = globalThis.setTimeout;
  const originalClear = globalThis.clearTimeout;
  Object.defineProperty(globalThis, "Bun", { configurable: true, value: {
    which() { actions.push("which"); throw new Error("pane discovery forbidden"); },
    spawn(command, options) {
      const event = JSON.parse(new TextDecoder().decode(options.stdin));
      const call = { command, options, event, kills: 0 };
      calls.push(call);
      const child = { exited: delivery ? delivery(event, call) : Promise.resolve(0), kill() { call.kills += 1; } };
      return child;
    },
  } });
  globalThis.setTimeout = scheduler.schedule;
  globalThis.clearTimeout = scheduler.clear;
  const ctx = {
    app: { version: "2.0.27" }, location, options: {},
    event: { subscribe: stream.subscribe },
    session: {
      get(input) {
        assert.deepEqual(Object.keys(input), ["sessionID"]);
        getRequests.push(input);
        return getSession ? getSession(input.sessionID) : sessions[input.sessionID] ?? session(input.sessionID);
      },
      context(input) {
        assert.deepEqual(Object.keys(input), ["sessionID"]);
        contextRequests.push(input);
        return getContext ? getContext(input.sessionID) : contexts[input.sessionID] ?? [];
      },
    },
    permission: { reply() { actions.push("permission.reply"); } },
    form: { reply() { actions.push("form.reply"); }, cancel() { actions.push("form.cancel"); } },
    storage: { set() { actions.push("storage.set"); } },
  };
  let cleanup;
  try { cleanup = definition.setup(ctx); } finally {
    globalThis.setTimeout = originalSchedule;
    globalThis.clearTimeout = originalClear;
    if (originalBun) Object.defineProperty(globalThis, "Bun", originalBun);
    else delete globalThis.Bun;
  }
  assert.equal(typeof cleanup, "function", "setup must synchronously return cleanup, not the stream lifetime");
  t.after(() => { cleanup(); assert.deepEqual(actions, []); });
  return { calls, getRequests, contextRequests, actions, scheduler, stream, cleanup,
    get events() { return calls.map((call) => call.event); },
    get kinds() { return calls.map((call) => `${call.event.event}:${call.event.session_id}`); },
    async emit(...events) { for (const event of events) { stream.push(event); await flush(); } },
    async settle(id) { await this.emit(execution(id, "succeeded")); },
    async complete(id) { await this.emit(execution(id, "started")); await this.settle(id); await scheduler.advanceBy(50); },
  };
}

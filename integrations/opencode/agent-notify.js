import { readFileSync } from "node:fs";

const SOURCE = "opencode";
const MAX_IDENTIFIER_LENGTH = 256;
const MAX_EXCERPT_LENGTH = 240;
const MAX_EXCERPT_GRAPHEMES = 200;
const MAX_EXCERPT_BYTES = 700;
const MAX_PAYLOAD_BYTES = 2048;
const MESSAGE_FETCH_LIMIT = 12;
const MESSAGE_FETCH_TIMEOUT_MS = 1_000;
const SUBPROCESS_OUTER_TIMEOUT_MS = 10_000;
const ROOT_QUIESCENCE_MS = 50;
const EXCERPT_TRUNCATION_MARKER = "…";
const EXCERPT_CODE_MARKER = "[code]";
const SETTINGS_RELATIVE_PATH = "/Library/Application Support/agent-notify/settings.conf";
const EXCERPT_DISABLED = /^[ \t]*EXCERPT[ \t]*=[ \t]*0[ \t]*$/m;
// Remove escape payloads before ESC itself; replace line breaks before deleting controls.
const ANSI_ESCAPE = /\x1b\][\s\S]*?(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -\/]*[@-~]|\x1b[@-Z\\-_]/g;
const LINE_BREAK = new RegExp("[\\u000a\\u000b\\u000c\\u000d\\u0085\\u2028\\u2029]", "g");
const CONTROL = /[\x00-\x1f\x7f-\x9f]/g;
// Preserve ZWJ and VS16: removing them breaks emoji graphemes.
const INVISIBLE = new RegExp("[\\u061c\\u200b\\u200c\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069\\ufeff]", "g");
const CODE_FENCE = /```[\s\S]*?```/g;
const BACKTICKS = /`+/g;
const EXCERPT_REJECTED = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029]");
const NORMALIZED_EVENT_KINDS = new Set(["began", "attention", "attention-cleared", "completed", "failed", "reset"]);
const EXECUTION_EVENTS = new Map([
  ["session.execution.started", "started"],
  ["session.execution.succeeded", "succeeded"],
  ["session.execution.failed", "failed"],
  ["session.execution.interrupted", "interrupted"],
]);

function boundedIdentifier(value) {
  return typeof value === "string" && value.length > 0 && value.length <= MAX_IDENTIFIER_LENGTH &&
    !/[\u0000-\u001f\u007f]/.test(value) ? value : undefined;
}

function boundedDirectory(value) {
  return typeof value === "string" && value.startsWith("/") ? boundedIdentifier(value) : undefined;
}

function boundedLocation(value) {
  const directory = boundedDirectory(value?.directory);
  const workspaceID = boundedIdentifier(value?.workspaceID);
  return directory && (value.workspaceID === undefined || workspaceID)
    ? { directory, workspaceID } : undefined;
}

function sameLocation(left, right) {
  return Boolean(left && right && left.directory === right.directory && left.workspaceID === right.workspaceID);
}

function sessionMetadata(value, sessionID) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      (value.id !== undefined && value.id !== sessionID)) return undefined;
  const directory = boundedDirectory(value.location?.directory);
  if (!directory) return undefined;
  const parentID = boundedIdentifier(value.parentID);
  return { directory, parentID, location: boundedLocation(value.location),
    relationship: value.parentID === undefined || Boolean(parentID && parentID !== sessionID) };
}

function boundedExcerpt(value) {
  return typeof value === "string" && value.length > 0 && value.length <= MAX_EXCERPT_LENGTH &&
    !EXCERPT_REJECTED.test(value) ? value : undefined;
}

function settingsPath() {
  const environment = globalThis.process?.env ?? {};
  return environment.AGENT_NOTIFY_SETTINGS_FILE || `${environment.HOME ?? ""}${SETTINGS_RELATIVE_PATH}`;
}

// Read at each decision, so a running session honours a live opt-out.
function excerptsEnabled() {
  try {
    return !EXCERPT_DISABLED.test(readFileSync(settingsPath(), "utf8"));
  } catch {
    return true;
  }
}

function sanitizeExcerpt(text) {
  return text.normalize("NFC").replace(ANSI_ESCAPE, "").replace(LINE_BREAK, " ")
    .replace(CONTROL, "").replace(INVISIBLE, "").replace(CODE_FENCE, EXCERPT_CODE_MARKER)
    .replace(BACKTICKS, "").replace(/\s+/g, " ").trim();
}

function utf8ByteLength(text) {
  let bytes = 0;
  for (const character of text) {
    const point = character.codePointAt(0);
    bytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
  }
  return bytes;
}

function boundExcerpt(text) {
  if (text.length === 0) return "";
  const clusters = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)]
    .map((cluster) => cluster.segment);
  if (clusters.length <= MAX_EXCERPT_GRAPHEMES && text.length <= MAX_EXCERPT_LENGTH &&
      utf8ByteLength(text) <= MAX_EXCERPT_BYTES) return text;

  const maxUnits = MAX_EXCERPT_LENGTH - EXCERPT_TRUNCATION_MARKER.length;
  const maxBytes = MAX_EXCERPT_BYTES - utf8ByteLength(EXCERPT_TRUNCATION_MARKER);
  let graphemes = 0;
  let units = 0;
  let bytes = 0;
  let index = clusters.length;
  while (index > 0) {
    const cluster = clusters[index - 1];
    const clusterBytes = utf8ByteLength(cluster);
    if (graphemes + 1 >= MAX_EXCERPT_GRAPHEMES || units + cluster.length > maxUnits ||
        bytes + clusterBytes > maxBytes) break;
    graphemes += 1;
    units += cluster.length;
    bytes += clusterBytes;
    index -= 1;
  }
  return EXCERPT_TRUNCATION_MARKER + clusters.slice(index).join("");
}

function excerptFrom(text) {
  return typeof text === "string" && text.length > 0 ? boundExcerpt(sanitizeExcerpt(text)) || undefined : undefined;
}

function encodeEvent(event) {
  if (event?.source !== SOURCE || !NORMALIZED_EVENT_KINDS.has(event.kind)) return undefined;
  const sessionID = boundedIdentifier(event.session_id);
  const sessionDir = boundedDirectory(event.session_dir);
  const requestID = event.request_id === undefined || event.request_id === "" ? "" : boundedIdentifier(event.request_id);
  if (!sessionID || !sessionDir || requestID === undefined) return undefined;
  if ((event.kind === "attention" || event.kind === "attention-cleared") && !requestID) return undefined;
  const normalized = { source: SOURCE, event: event.kind, session_id: sessionID, session_dir: sessionDir, request_id: requestID };
  const excerpt = boundedExcerpt(event.excerpt);
  if (excerpt) normalized.excerpt = excerpt;
  let encoded = JSON.stringify(normalized);
  // Oversized payloads cost the excerpt, never an otherwise valid event.
  if (excerpt && utf8ByteLength(encoded) > MAX_PAYLOAD_BYTES) {
    delete normalized.excerpt;
    encoded = JSON.stringify(normalized);
  }
  return utf8ByteLength(encoded) <= MAX_PAYLOAD_BYTES ? encoded : undefined;
}

// Retain only the verified, bounded contract. Raw forms, inbox items, metadata and responses
// never enter observation state, notification queues, or diagnostics.
function normalizeEvent(event) {
  const data = event?.data;
  if (!data || typeof data !== "object" || Array.isArray(data)) return undefined;
  let kind = EXECUTION_EVENTS.get(event.type);
  let sessionID = boundedIdentifier(data.sessionID);
  let requestID;
  let family;
  let status;
  if (event.type === "session.status") {
    status = data.status?.type;
    if (!["busy", "idle", "retry"].includes(status)) return undefined;
    kind = "status";
    if (status === "retry" && data.status.action && typeof data.status.action === "object" &&
        !Array.isArray(data.status.action) && Object.keys(data.status.action).length > 0 &&
        (typeof data.status.attempt === "string" || Number.isFinite(data.status.attempt))) {
      requestID = boundedIdentifier(`retry:${data.status.attempt}`);
    }
  } else if (event.type === "permission.asked" || event.type === "permission.replied") {
    kind = event.type.endsWith(".asked") ? "attention" : "cleared";
    family = "permission";
    requestID = boundedIdentifier(kind === "attention" ? data.id : data.requestID);
  } else if (event.type === "form.created") {
    kind = "attention";
    family = "form";
    sessionID = boundedIdentifier(data.form?.sessionID);
    requestID = boundedIdentifier(data.form?.id);
  } else if (event.type === "form.replied" || event.type === "form.cancelled") {
    kind = "cleared";
    family = "form";
    requestID = boundedIdentifier(data.id);
  } else if (["session.created", "session.moved", "session.deleted"].includes(event.type)) {
    kind = event.type.slice("session.".length);
  } else if (["session.inbox.enqueued", "session.inbox.delivered", "session.inbox.cancelled"].includes(event.type)) {
    kind = event.type.slice("session.inbox.".length);
    requestID = boundedIdentifier(data.inboxID);
    if (!requestID) return undefined;
  }
  if (!kind || !sessionID || (family === "form" && sessionID === "global") || (family && !requestID)) return undefined;
  const directory = boundedDirectory(data.location?.directory) ?? boundedDirectory(event.location?.directory);
  const parentValue = data.parentID;
  const parentID = boundedIdentifier(parentValue);
  const relationship = kind === "created" && directory &&
    (parentValue === undefined || (parentID && parentID !== sessionID));
  const errorText = kind === "failed" && excerptsEnabled()
    ? excerptFrom(typeof data.error?.message === "string" && data.error.message.length > 0 ? data.error.message : data.error?.type)
    : undefined;
  const nativeLocation = kind === "created" || kind === "moved" ? boundedLocation(data.location) : undefined;
  return { kind, sessionID, requestID, family, status, directory, parentID, relationship, errorText, nativeLocation };
}

function setupAdapter(ctx) {
  const schedule = globalThis.setTimeout;
  const clear = globalThis.clearTimeout;
  const spawn = globalThis.Bun?.spawn;
  const controller = new AbortController();
  const sessions = new Map();
  const ownership = new Map();
  const deleted = new Set();
  const departed = new Set();
  // Instance location is routing identity only, never a display-directory fallback.
  const instanceLocation = boundedLocation(ctx.location);
  const candidates = new Map();
  const notificationTails = new Map();
  const queuedControls = new Set();
  const timers = new Map();
  const children = new Map();
  let stopped = false;
  const pendingIntake = new Set();

  function later(callback, delay, cancelled = () => {}) {
    const timer = schedule(() => {
      timers.delete(timer);
      callback();
    }, delay);
    timers.set(timer, cancelled);
    return timer;
  }

  function cancelTimer(timer) {
    if (timer === undefined) return;
    clear(timer);
    timers.delete(timer);
  }

  async function bounded(work, timeoutMs, onTimeout = () => {}) {
    let timer;
    try {
      return await Promise.race([
        Promise.resolve().then(() => stopped ? undefined : work()),
        new Promise((resolve) => {
          timer = later(() => { onTimeout(); resolve(undefined); }, timeoutMs, () => resolve(undefined));
        }),
      ]);
    } catch {
      return undefined;
    } finally {
      cancelTimer(timer);
    }
  }

  function rootFor(sessionID) {
    const visited = new Set();
    let id = sessionID;
    while (sessions.get(id)?.parentID) {
      if (visited.has(id)) return undefined;
      visited.add(id);
      id = sessions.get(id).parentID;
    }
    return id;
  }

  function cancelCandidate(rootID) {
    const candidate = candidates.get(rootID);
    if (!candidate) return;
    candidates.delete(rootID);
    cancelTimer(candidate.timer);
  }

  function invalidate(sessionID) {
    const rootID = rootFor(sessionID);
    if (sessions.has(sessionID)) cancelCandidate(rootID);
    else for (const id of candidates.keys()) cancelCandidate(id);
  }

  function validOwner(sessionID, token) {
    return !stopped && !deleted.has(sessionID) && !departed.has(sessionID) && ownership.get(sessionID) === token;
  }

  function validRelationship(id, metadata) {
    if (!metadata?.relationship) return false;
    let ancestor = metadata.parentID;
    const visited = new Set([id]);
    while (ancestor) {
      if (visited.has(ancestor)) return false;
      visited.add(ancestor);
      ancestor = sessions.get(ancestor)?.parentID;
    }
    return true;
  }

  function intakeScope(entry) {
    const id = entry.event.sessionID;
    const known = sessions.get(id);
    const scope = new Set();
    const include = (member) => {
      while (member && !scope.has(member)) {
        scope.add(member);
        member = sessions.get(member)?.parentID;
      }
    };
    if (known?.relationshipKnown || entry.ready) include(id);
    for (const metadata of [entry.event, entry.details]) {
      if (!validRelationship(id, metadata)) continue;
      include(id);
      include(metadata.parentID);
    }
    // Until lookup/fallback resolves an unknown relationship it may belong to any tree.
    return scope.size > 0 ? scope : undefined;
  }

  function drainIntake() {
    const blocked = [];
    for (const entry of pendingIntake) {
      if (!validOwner(entry.event.sessionID, entry.token)) {
        pendingIntake.delete(entry);
        continue;
      }
      const scope = intakeScope(entry);
      const waiting = blocked.some((earlier) => {
        const previousScope = intakeScope(earlier);
        return !scope || !previousScope || [...scope].some((id) => previousScope.has(id));
      });
      if (!entry.ready || waiting) {
        blocked.push(entry);
        continue;
      }
      pendingIntake.delete(entry);
      try { reduce(entry.event, entry.token, entry.details); } catch { /* Advisory. */ }
    }
    if (!stopped) considerCompletions();
  }

  function resolveEntry(entry) {
    const ticket = {};
    entry.lookupTicket = ticket;
    entry.ready = false;
    entry.details = undefined;
    void (async () => {
      const details = await bounded(() => ctx.session.get({ sessionID: entry.event.sessionID }), MESSAGE_FETCH_TIMEOUT_MS);
      if (stopped || !pendingIntake.has(entry) || entry.lookupTicket !== ticket) return;
      try { entry.details = sessionMetadata(details, entry.event.sessionID); } catch { /* Lookup unavailable. */ }
      entry.ready = true;
      drainIntake();
    })().catch(() => {});
  }

  function recordMetadata(event, details) {
    const id = event.sessionID;
    let session = sessions.get(id);
    const directory = details?.directory ?? event.directory ?? session?.directory;
    if (!directory) return undefined;
    // A usable lookup directory does not make its relationship trustworthy.
    const metadata = validRelationship(id, details) ? details : event;
    const parentID = metadata.parentID;
    const relationship = validRelationship(id, metadata);
    if (!session) {
      session = { directory, parentID: undefined, status: "unknown", executing: false, outcome: undefined,
        turnOpen: false, requests: new Set(), inbox: new Map(), awaitingOutcome: false, relationshipKnown: false };
      sessions.set(id, session);
    }
    if (relationship && session.parentID !== parentID) {
      // Dynamic parent traversal merges provisional trees without losing descendant state.
      cancelCandidate(rootFor(id));
      session.parentID = parentID;
      cancelCandidate(rootFor(id));
    }
    if (relationship) session.relationshipKnown = true;
    if (session.directory !== directory) invalidate(id);
    session.directory = directory;
    return session;
  }

  function eligible(rootID) {
    const root = sessions.get(rootID);
    if (stopped || !root || root.parentID || !root.turnOpen || root.executing ||
        root.outcome !== "succeeded" || root.status !== "idle") return false;
    for (const entry of pendingIntake) {
      if (!validOwner(entry.event.sessionID, entry.token)) continue;
      const scope = intakeScope(entry);
      if (!scope || scope.has(rootID)) return false;
    }
    for (const [id, session] of sessions) {
      if (rootFor(id) !== rootID) continue;
      if (session.awaitingOutcome || [...session.inbox.values()].includes("pending")) return false;
      if (id !== rootID && (session.executing ||
          (["busy", "retry"].includes(session.status) && !["failed", "interrupted"].includes(session.outcome)))) return false;
    }
    return true;
  }

  async function sessionExcerpt(rootID) {
    if (!excerptsEnabled()) return undefined;
    const messages = await bounded(() => ctx.session.context({ sessionID: rootID }), MESSAGE_FETCH_TIMEOUT_MS);
    if (stopped || !Array.isArray(messages)) return undefined;
    for (let index = messages.length - 1; index >= Math.max(0, messages.length - MESSAGE_FETCH_LIMIT); index -= 1) {
      const message = messages[index];
      if (message?.type !== "assistant") continue;
      const part = Array.isArray(message.content) ? message.content.find((item) =>
        item?.type === "text" && !item.synthetic && !item.ignored &&
        typeof item.text === "string" && item.text.trim().length > 0) : undefined;
      return part ? excerptFrom(part.text) : undefined;
    }
    return undefined;
  }

  function terminate(child) {
    try { child.kill(); } catch { /* Advisory, including during cleanup. */ }
  }

  async function submit(event, commit) {
    const input = encodeEvent(event);
    if (!input || stopped || typeof spawn !== "function") return;
    try {
      // No await between the queue's eligibility check and subprocess submission.
      commit?.();
      const child = spawn(["agent-notify", "event"], {
        stdin: new TextEncoder().encode(input), stdout: "ignore", stderr: "ignore",
      });
      let terminated = false;
      const kill = () => {
        if (!terminated) { terminated = true; terminate(child); }
      };
      children.set(child, kill);
      try {
        await bounded(() => child.exited, SUBPROCESS_OUTER_TIMEOUT_MS, kill);
      } finally {
        children.delete(child);
      }
    } catch {
      // No raw subprocess output or host-visible errors.
    }
  }

  function queueNotification(sessionID, operation) {
    const previous = notificationTails.get(sessionID) ?? Promise.resolve();
    const tail = previous.catch(() => {}).then(operation).catch(() => {});
    notificationTails.set(sessionID, tail);
    void tail.then(() => {
      if (notificationTails.get(sessionID) === tail) notificationTails.delete(sessionID);
    });
  }

  function notify(kind, sessionID, requestID = "", excerpt, guard = () => true, commit) {
    const directory = sessions.get(sessionID)?.directory;
    const event = { source: SOURCE, kind, session_id: sessionID, session_dir: directory, request_id: requestID };
    if (excerpt) event.excerpt = excerpt;
    const queued = { event, token: ownership.get(sessionID) };
    if (kind === "began" || kind === "reset") queuedControls.add(queued);
    queueNotification(sessionID, () => {
      queuedControls.delete(queued);
      if (validOwner(sessionID, queued.token) && guard()) return submit(event, commit);
    });
  }

  function considerCompletions() {
    for (const rootID of sessions.keys()) {
      if (!eligible(rootID) || candidates.has(rootID)) continue;
      const candidate = { timer: undefined };
      candidates.set(rootID, candidate);
      const valid = () => {
        if (candidates.get(rootID) !== candidate) return false;
        if (eligible(rootID)) return true;
        cancelCandidate(rootID);
        // Intake may still be resolving metadata. Its final reducer will reconsider eligibility.
        considerCompletions();
        return false;
      };
      candidate.timer = later(() => {
        void (async () => {
          if (!valid()) return;
          const excerpt = await sessionExcerpt(rootID);
          if (!valid()) return;
          notify("completed", rootID, "", excerpt, valid, () => {
            sessions.get(rootID).turnOpen = false;
            cancelCandidate(rootID);
          });
        })().catch(() => {});
      }, ROOT_QUIESCENCE_MS);
    }
  }

  function activate(id, session) {
    if (session.executing) return;
    session.executing = true;
    session.outcome = undefined;
    session.requests.clear();
    if (session.parentID) notify("reset", id);
    else if (!session.turnOpen) {
      session.turnOpen = true;
      notify("began", id);
    }
  }

  function reduce(event, token, details) {
    const id = event.sessionID;
    if (!validOwner(id, token)) return;
    if (event.kind === "moved" && !sameLocation(details?.location, event.nativeLocation)) details = undefined;
    const session = recordMetadata(event, details);
    if (!session) return;
    if (event.kind === "created" || event.kind === "moved") return;
    if (event.kind === "started") {
      activate(id, session);
      session.status = "busy";
    } else if (event.kind === "status") {
      if (event.status === "busy") activate(id, session);
      if (event.status === "retry" && !session.executing && (session.parentID || session.turnOpen)) activate(id, session);
      session.status = event.status;
      if (event.status === "retry" && event.requestID && !session.requests.has(`retry:${event.requestID}`)) {
        session.requests.add(`retry:${event.requestID}`);
        notify("attention", id, event.requestID);
      }
    } else if (["succeeded", "failed", "interrupted"].includes(event.kind)) {
      if (!session.executing && session.outcome === event.kind && !session.awaitingOutcome) return;
      if (!session.executing && session.outcome && !session.awaitingOutcome && event.kind === "succeeded") return;
      session.executing = false;
      session.outcome = event.kind;
      // Terminal outcomes settle adapter-local execution; only success is completion-eligible.
      // In particular, a subsequent busy-only activation must not inherit stale busy status.
      session.status = "idle";
      session.awaitingOutcome = false;
      session.requests.clear();
      if (event.kind !== "succeeded") {
        session.turnOpen = false;
        notify(event.kind === "failed" ? "failed" : "reset", id, "", event.errorText);
      }
    } else if (event.kind === "enqueued") {
      if (!session.inbox.has(event.requestID)) session.inbox.set(event.requestID, "pending");
    } else if (event.kind === "delivered" || event.kind === "cancelled") {
      if (session.inbox.get(event.requestID) !== "pending") return;
      session.inbox.set(event.requestID, event.kind);
      if (event.kind === "delivered") session.awaitingOutcome = true;
    } else if (event.kind === "attention" || event.kind === "cleared") {
      const key = `${event.family}:${event.requestID}`;
      if (event.kind === "attention" && !session.requests.has(key)) {
        session.requests.add(key);
        notify("attention", id, event.requestID);
      } else if (event.kind === "cleared" && session.requests.delete(key)) {
        notify("attention-cleared", id, event.requestID);
      }
    }
  }

  function ingest(event) {
    const normalized = normalizeEvent(event);
    if (stopped || !normalized) return;
    const id = normalized.sessionID;
    if (departed.has(id) && normalized.kind !== "moved") {
      if (normalized.kind !== "created" || !sameLocation(normalized.nativeLocation, instanceLocation)) return;
      departed.delete(id);
    }
    if (!ownership.has(id)) ownership.set(id, {});
    // Invalidation is synchronous at intake, not hidden behind metadata or delivery latency.
    const observedInbox = sessions.get(id)?.inbox;
    const invalidating = ["started", "failed", "interrupted", "deleted", "moved"].includes(normalized.kind) ||
      (normalized.kind === "status" && ["busy", "retry"].includes(normalized.status)) ||
      (normalized.kind === "enqueued" && !observedInbox?.has(normalized.requestID)) ||
      (["delivered", "cancelled"].includes(normalized.kind) && observedInbox?.get(normalized.requestID) === "pending");
    if (invalidating) invalidate(id);
    if (normalized.kind === "deleted") {
      const directory = sessions.get(id)?.directory ?? normalized.directory;
      ownership.set(id, {});
      sessions.delete(id);
      deleted.add(id);
      for (const queued of queuedControls) if (queued.event.session_id === id) queuedControls.delete(queued);
      // The reset is owned by deletion, not by the removed observation state.
      // Queue it on the fresh token while rejecting all prior lookup/queue results.
      if (directory) {
        const token = ownership.get(id);
        queueNotification(id, () => {
          if (!stopped && ownership.get(id) === token) return submit({ source: SOURCE, kind: "reset", session_id: id,
            session_dir: directory, request_id: "" });
        });
      }
      drainIntake();
      return;
    }
    if (normalized.kind === "moved") {
      const previousToken = ownership.get(id);
      ownership.set(id, {});
      if (!sameLocation(normalized.nativeLocation, instanceLocation)) {
        // The bus sends this move to both owners, but future events reach only the destination.
        // Drop outgoing observation, not just its candidate token: old success cannot be re-armed.
        departed.add(id);
        sessions.delete(id);
        for (const queued of queuedControls) if (queued.event.session_id === id) queuedControls.delete(queued);
        drainIntake();
        return;
      }
      departed.delete(id);
      const session = sessions.get(id);
      if (session) session.directory = normalized.nativeLocation.directory;
      // Unsubmitted begins/child resets remain necessary for the notifier's next execution.
      // Refresh them in place in FIFO; submitted controls have already left this set.
      for (const queued of queuedControls) {
        if (queued.event.session_id !== id || queued.token !== previousToken) continue;
        queued.token = ownership.get(id);
        queued.event.session_dir = normalized.nativeLocation.directory;
      }
      // Same-owner movement cancels old delivery attribution, not earlier lifecycle inputs.
      // Re-resolve those inputs against current ownership, keeping their ingress positions and
      // rejecting late results from the obsolete lookup tickets.
      for (const entry of pendingIntake) {
        if (entry.event.sessionID !== id) continue;
        entry.token = ownership.get(id);
        resolveEntry(entry);
      }
    }
    if (deleted.has(id)) {
      if (normalized.kind !== "created") return;
      deleted.delete(id);
      ownership.set(id, {});
    }
    const entry = { event: normalized, token: ownership.get(id), ready: false, details: undefined };
    pendingIntake.add(entry);
    // Lookup latency is independent across events; reduction remains ordered within affected trees.
    resolveEntry(entry);
  }

  function cleanup() {
    if (stopped) return;
    stopped = true;
    try { controller.abort(); } catch { /* Advisory. */ }
    for (const [timer, cancelled] of timers) {
      try { clear(timer); cancelled(); } catch { /* Advisory. */ }
    }
    timers.clear();
    for (const kill of children.values()) kill();
    children.clear();
    candidates.clear();
    sessions.clear();
    ownership.clear();
    deleted.clear();
    departed.clear();
    pendingIntake.clear();
    notificationTails.clear();
    queuedControls.clear();
  }

  void (async () => {
    try {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        try { ingest(event); } catch { /* Malformed events do not end observation. */ }
      }
    } catch {
      // A stream error is not execution success; never expose its raw error.
    } finally {
      cleanup();
    }
  })();
  return cleanup;
}

// Plugin.define is an identity helper in 2.0.27; the loader accepts this native definition.
// Keep one default export and one installed file, with no package installation requirement.
export default { id: "agent-notify", setup: setupAdapter };

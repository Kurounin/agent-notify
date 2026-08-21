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
const EXCERPT_TRUNCATION_MARKER = "…";
const EXCERPT_CODE_MARKER = "[code]";
const SETTINGS_RELATIVE_PATH = "/Library/Application Support/agent-notify/settings.conf";
const EXCERPT_DISABLED = /^[ \t]*EXCERPT[ \t]*=[ \t]*0[ \t]*$/m;
// Escape payloads go before ESC itself becomes a deletable control character, and line breaks
// become spaces before the remaining control characters are deleted, or their text runs together.
const ANSI_ESCAPE = /\x1b\][\s\S]*?(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -\/]*[@-~]|\x1b[@-Z\\-_]/g;
const LINE_BREAK = new RegExp("[\\u000a\\u000b\\u000c\\u000d\\u0085\\u2028\\u2029]", "g");
const CONTROL = /[\x00-\x1f\x7f-\x9f]/g;
// Bidirectional and zero-width formatting can rewrite how the notification renders. ZWJ and VS16
// stay because removing them breaks emoji.
const INVISIBLE = new RegExp("[\\u061c\\u200b\\u200c\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069\\ufeff]", "g");
const CODE_FENCE = /```[\s\S]*?```/g;
const BACKTICKS = /`+/g;
const EXCERPT_REJECTED = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029]");
const NORMALIZED_EVENT_KINDS = new Set([
  "began",
  "attention",
  "attention-cleared",
  "completed",
  "failed",
]);

const ATTENTION_EVENTS = Object.freeze([
  "permission.asked",
  "permission.replied",
  "question.asked",
  "question.replied",
  "question.rejected",
  "permission.v2.asked",
  "permission.v2.replied",
  "question.v2.asked",
  "question.v2.replied",
  "question.v2.rejected",
]);

function boundedIdentifier(value) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_IDENTIFIER_LENGTH ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    return undefined;
  }

  return value;
}

function boundedDirectory(value) {
  return boundedIdentifier(value);
}

function boundedRequestID(value) {
  return value === "" ? "" : boundedIdentifier(value);
}

function boundedExcerpt(value) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_EXCERPT_LENGTH ||
    EXCERPT_REJECTED.test(value)
  ) {
    return undefined;
  }

  return value;
}

function settingsPath() {
  const environment = globalThis.process?.env ?? {};
  return environment.AGENT_NOTIFY_SETTINGS_FILE || `${environment.HOME ?? ""}${SETTINGS_RELATIVE_PATH}`;
}

// Read per excerpt decision rather than cached at plugin load, so a session that is already running
// honours a change to the setting without being restarted.
function excerptsEnabled() {
  try {
    return !EXCERPT_DISABLED.test(readFileSync(settingsPath(), "utf8"));
  } catch {
    // An absent, unreadable, or malformed settings file leaves excerpts enabled.
    return true;
  }
}

function sanitizeExcerpt(text) {
  return text
    .normalize("NFC")
    .replace(ANSI_ESCAPE, "")
    .replace(LINE_BREAK, " ")
    .replace(CONTROL, "")
    .replace(INVISIBLE, "")
    .replace(CODE_FENCE, EXCERPT_CODE_MARKER)
    .replace(BACKTICKS, "")
    .replace(/\s+/g, " ")
    .trim();
}

function utf8ByteLength(text) {
  let bytes = 0;
  for (const character of text) {
    const codePoint = character.codePointAt(0);
    bytes += codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
  }
  return bytes;
}

function graphemeClusters(text) {
  const clusters = [];
  for (const cluster of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)) clusters.push(cluster.segment);
  return clusters;
}

function boundExcerpt(text) {
  if (text.length === 0) return "";
  const clusters = graphemeClusters(text);
  if (clusters.length <= MAX_EXCERPT_GRAPHEMES && text.length <= MAX_EXCERPT_LENGTH && utf8ByteLength(text) <= MAX_EXCERPT_BYTES) return text;

  const maxGraphemes = MAX_EXCERPT_GRAPHEMES - 1;
  const maxUnits = MAX_EXCERPT_LENGTH - EXCERPT_TRUNCATION_MARKER.length;
  const maxBytes = MAX_EXCERPT_BYTES - utf8ByteLength(EXCERPT_TRUNCATION_MARKER);
  let graphemes = 0;
  let units = 0;
  let bytes = 0;
  let index = clusters.length;
  while (index > 0) {
    const cluster = clusters[index - 1];
    const clusterBytes = utf8ByteLength(cluster);
    if (graphemes + 1 > maxGraphemes || units + cluster.length > maxUnits || bytes + clusterBytes > maxBytes) break;
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

function attentionKey(eventType, requestID) {
  return `${eventType.startsWith("permission.") ? "permission" : "question"}:${requestID}`;
}

function sessionIDFrom(event) {
  return boundedIdentifier(event?.properties?.sessionID);
}

function requestIDFrom(event) {
  const properties = event?.properties;
  return boundedIdentifier(event?.type?.endsWith(".asked") ? properties?.id : properties?.requestID);
}

function retryActionRequestID(event) {
  const status = event?.properties?.status;
  const action = status?.action;
  const attempt = status?.attempt;
  if (
    !action ||
    typeof action !== "object" ||
    Array.isArray(action) ||
    Object.keys(action).length === 0 ||
    (typeof attempt !== "string" && (typeof attempt !== "number" || !Number.isFinite(attempt))) ||
    String(attempt).length === 0
  ) return undefined;

  return boundedRequestID(`retry:${attempt}`);
}

function terminalError(event) {
  const error = event?.properties?.error;
  if (!error || typeof error !== "object") return false;

  if (
    error.name === "MessageAbortedError" ||
    error.name === "AbortError" ||
    error.name === "UserAbortError" ||
    error.name === "ToolError" ||
    error.isRetryable === true ||
    error.isRecoverable === true ||
    error.data?.isRetryable === true ||
    error.data?.isRecoverable === true
  ) return false;
  if (error.name === "APIError") return error.data?.isRetryable === false;

  return error.name === "ProviderAuthError" ||
    error.name === "UnknownError" ||
    error.name === "MessageOutputLengthError" ||
    error.name === "StructuredOutputError" ||
    error.name === "ContextOverflowError" ||
    error.name === "ContentFilterError";
}

function encodeEvent(event) {
  if (event?.source !== SOURCE || !NORMALIZED_EVENT_KINDS.has(event.kind)) return undefined;

  const sessionID = boundedIdentifier(event.session_id);
  const sessionDir = boundedDirectory(event.session_dir);
  const requestID = event.request_id === undefined ? "" : boundedRequestID(event.request_id);
  if (!sessionID || !sessionDir || requestID === undefined) return undefined;
  if ((event.kind === "attention" || event.kind === "attention-cleared") && !requestID) return undefined;

  const excerpt = boundedExcerpt(event.excerpt);
  const normalized = {
    source: SOURCE,
    event: event.kind,
    session_id: sessionID,
    session_dir: sessionDir,
    request_id: requestID,
  };
  if (excerpt) normalized.excerpt = excerpt;

  let encoded = JSON.stringify(normalized);
  // An oversized payload must cost the excerpt, never the event.
  if (excerpt && new TextEncoder().encode(encoded).byteLength > MAX_PAYLOAD_BYTES) {
    delete normalized.excerpt;
    encoded = JSON.stringify(normalized);
  }
  if (new TextEncoder().encode(encoded).byteLength > MAX_PAYLOAD_BYTES) return undefined;
  return encoded;
}

function createBinarySubmitter({
  spawn = globalThis.Bun?.spawn,
  binary = "agent-notify",
  timeoutMs = SUBPROCESS_OUTER_TIMEOUT_MS,
} = {}) {
  return async (event) => {
    const input = encodeEvent(event);
    if (!input || typeof spawn !== "function") return;

    try {
      const process = spawn([binary, "event"], {
        stdin: new TextEncoder().encode(input),
        stdout: "ignore",
        stderr: "ignore",
      });
      const timeout = setTimeout(() => process.kill(), timeoutMs);
      try {
        await process.exited;
      } finally {
        clearTimeout(timeout);
      }
    } catch {
      // Notifications are advisory and must not affect OpenCode execution.
    }
  };
}

function createOpenCodeAdapter({ client, submit = createBinarySubmitter() }) {
  const activeTurns = new Set();
  const terminatedTurns = new Set();
  const attention = new Map();
  const sessionTrees = new Map();
  const sessionRoots = new Map();

  async function lookup(sessionID) {
    try {
      const result = await client.session.get({ path: { id: sessionID } });
      const details = result?.data;
      const directory = boundedDirectory(details?.directory);
      const parentValue = details?.parentID;
      const parentID = parentValue === null || parentValue === undefined
        ? undefined
        : boundedIdentifier(parentValue);
      // OpenCode omits parentID entirely for root sessions, so an absent key means root.
      const treeMetadata = Boolean(
        directory &&
        (parentValue === null || parentValue === undefined || (parentID && parentID !== sessionID)),
      );
      return { directory, parentID, treeMetadata };
    } catch {
      return { directory: undefined, treeMetadata: false };
    }
  }

  // Always called with the root session id: in a deferred completion the event being processed
  // belongs to a descendant, whose messages are a subagent's internal report.
  async function sessionExcerpt(rootID) {
    if (!excerptsEnabled()) return undefined;

    let timeout;
    try {
      const result = await Promise.race([
        client.session.messages({ path: { id: rootID }, query: { limit: MESSAGE_FETCH_LIMIT } }),
        new Promise((resolve) => {
          timeout = setTimeout(resolve, MESSAGE_FETCH_TIMEOUT_MS);
        }),
      ]);
      if (timeout !== undefined) clearTimeout(timeout);
      const messages = result?.data;
      if (!Array.isArray(messages)) return undefined;

      for (let index = messages.length - 1; index >= 0; index -= 1) {
        const message = messages[index];
        if (message?.info?.role !== "assistant") continue;

        const parts = Array.isArray(message.parts) ? message.parts : [];
        // Reasoning parts outnumber text parts in real sessions, so select text by predicate.
        const part = parts.find((candidate) =>
          candidate?.type === "text" &&
          !candidate.synthetic &&
          !candidate.ignored &&
          typeof candidate.text === "string" &&
          candidate.text.trim().length > 0,
        );
        return part ? excerptFrom(part.text) : undefined;
      }
      return undefined;
    } catch {
      if (timeout !== undefined) clearTimeout(timeout);
      // The client resolves {data: undefined} on a 4xx but rejects on a transport failure.
      return undefined;
    }
  }

  function errorExcerpt(event) {
    if (!excerptsEnabled()) return undefined;

    const error = event?.properties?.error;
    const message = typeof error?.data?.message === "string" && error.data.message.length > 0
      ? error.data.message
      : error?.name;
    return excerptFrom(message);
  }

  function removeTree(rootID) {
    const tree = sessionTrees.get(rootID);
    if (!tree) return;

    for (const sessionID of tree.keys()) sessionRoots.delete(sessionID);
    sessionTrees.delete(rootID);
  }

  function mergeTree(fromRootID, toRootID) {
    if (fromRootID === toRootID) return;

    const fromTree = sessionTrees.get(fromRootID);
    if (!fromTree) return;

    const toTree = sessionTrees.get(toRootID) ?? new Map();
    for (const [sessionID, session] of fromTree) {
      if (!toTree.has(sessionID)) toTree.set(sessionID, session);
      sessionRoots.set(sessionID, toRootID);
    }
    sessionTrees.set(toRootID, toTree);
    sessionTrees.delete(fromRootID);
  }

  function recordSession(sessionID, details, status) {
    const rootID = details.parentID
      ? sessionRoots.get(details.parentID) ?? details.parentID
      : sessionID;
    const previousRootID = sessionRoots.get(sessionID);
    if (previousRootID && previousRootID !== rootID) {
      mergeTree(previousRootID, rootID);
    }
    if (sessionID !== rootID && sessionTrees.has(sessionID)) {
      mergeTree(sessionID, rootID);
    }

    const tree = sessionTrees.get(rootID) ?? new Map();
    const previous = tree.get(sessionID);
    tree.set(sessionID, {
      directory: details.directory,
      parentID: details.parentID,
      status,
      pending: status === "busy" || status === "retry" ? false : previous?.pending,
    });
    sessionTrees.set(rootID, tree);
    sessionRoots.set(sessionID, rootID);
    return rootID;
  }

  function hasPendingCompletion(sessionID) {
    return sessionTrees.get(sessionID)?.get(sessionID)?.pending === true;
  }

  async function completePendingRoot(rootID) {
    const tree = sessionTrees.get(rootID);
    const root = tree?.get(rootID);
    if (!root?.pending || root.status !== "idle") return;

    for (const [sessionID, session] of tree) {
      if (sessionID !== rootID && (session.status === "busy" || session.status === "retry")) return;
    }

    root.pending = false;
    removeTree(rootID);
    await notifyCompleted(rootID, root.directory);
  }

  function pruneSettledTree(rootID) {
    const tree = sessionTrees.get(rootID);
    if (!tree) return;

    const root = tree.get(rootID);
    const hasActiveSession = [...tree.values()].some(
      (session) => session.status === "busy" || session.status === "retry",
    );
    if (!root?.pending && !hasActiveSession) removeTree(rootID);
  }

  async function fallBackToSessionLifecycle(sessionID, details, status) {
    const rootID = sessionRoots.get(sessionID);
    const session = rootID ? sessionTrees.get(rootID)?.get(sessionID) : undefined;
    const directory = details.directory ?? session?.directory;

    if (session) {
      if (directory) session.directory = directory;

      if (status === "busy" || status === "retry") {
        session.status = status;
        if (status !== "busy" || activeTurns.has(sessionID)) return;

        terminatedTurns.delete(sessionID);
        activeTurns.add(sessionID);
        if (!directory) {
          activeTurns.delete(sessionID);
          return;
        }
        if (sessionID === rootID && !session.pending) await notify("began", sessionID, directory);
        return;
      }

      if (status === "idle") {
        session.status = "idle";
        const wasActive = activeTurns.delete(sessionID);
        if (wasActive) attention.delete(sessionID);
        if (sessionID === rootID) {
          if (!wasActive && session.pending) return;
          removeTree(rootID);
          if (wasActive && directory) await notifyCompleted(sessionID, directory);
          return;
        }
        await completePendingRoot(rootID);
        pruneSettledTree(rootID);
      }
      return;
    }

    if (status === "busy") {
      if (activeTurns.has(sessionID)) return;
      terminatedTurns.delete(sessionID);
      activeTurns.add(sessionID);
      if (!directory) {
        activeTurns.delete(sessionID);
        return;
      }
      await notify("began", sessionID, directory);
      return;
    }

    if (status === "idle" && activeTurns.has(sessionID)) {
      activeTurns.delete(sessionID);
      attention.delete(sessionID);
      if (directory) await notifyCompleted(sessionID, directory);
    }
  }

  async function notify(kind, sessionID, sessionDir, requestID = "", excerpt = undefined) {
    const event = {
      source: SOURCE,
      kind,
      session_id: sessionID,
      session_dir: sessionDir,
      request_id: requestID,
    };
    if (excerpt) event.excerpt = excerpt;
    await submit(event);
  }

  // The message fetch is issued only once every state mutation for the event has been applied, so
  // its await cannot interleave with another event's view of the tracked lifecycle state.
  async function notifyCompleted(rootID, sessionDir) {
    await notify("completed", rootID, sessionDir, "", await sessionExcerpt(rootID));
  }

  async function notifyRetryAction(sessionID, sessionDir, event) {
    const requestID = retryActionRequestID(event);
    if (!requestID || !sessionDir) return;

    const key = `retry:${requestID}`;
    const requests = attention.get(sessionID) ?? new Set();
    if (requests.has(key)) return;

    requests.add(key);
    attention.set(sessionID, requests);
    await notify("attention", sessionID, sessionDir, requestID);
  }

  return {
    async event({ event }) {
      const sessionID = sessionIDFrom(event);
      if (!sessionID) return;

      const isLifecycleEvent =
        event.type === "session.status" ||
        event.type === "session.next.prompted" ||
        event.type === "session.next.prompt.admitted" ||
        event.type === "session.idle";
      if (isLifecycleEvent) {
        const status = event.type === "session.status"
          ? event.properties?.status?.type
          : event.type === "session.idle" ? "idle" : "busy";
        const details = await lookup(sessionID);
        if (!details.treeMetadata) {
          await fallBackToSessionLifecycle(sessionID, details, status);
          if (status === "retry") await notifyRetryAction(sessionID, details.directory, event);
          return;
        }

        const isTracked = sessionRoots.has(sessionID);
        if (
          status !== "busy" &&
          status !== "retry" &&
          (status !== "idle" || (!isTracked && !activeTurns.has(sessionID)))
        ) return;

        // A background task waking its root resumes the turn the user is still waiting on, so the
        // turn must not restart: the notifier times a completion from the began it last recorded.
        const resumesPendingTurn = hasPendingCompletion(sessionID);
        const rootID = recordSession(sessionID, details, status);
        if (status === "busy") {
          if (activeTurns.has(sessionID)) return;
          terminatedTurns.delete(sessionID);
          activeTurns.add(sessionID);
          if (sessionID === rootID && !resumesPendingTurn) await notify("began", sessionID, details.directory);
          return;
        }

        if (status === "retry") {
          await notifyRetryAction(sessionID, details.directory, event);
          return;
        }

        if (status === "idle") {
          const wasActive = activeTurns.delete(sessionID);
          if (wasActive) attention.delete(sessionID);
          if (sessionID === rootID) {
            const session = sessionTrees.get(rootID)?.get(sessionID);
            if (wasActive) session.pending = true;
          }
          await completePendingRoot(rootID);
          pruneSettledTree(rootID);
        }
        return;
      }

      if (event.type === "session.error") {
        if (!terminalError(event) || terminatedTurns.has(sessionID)) return;

        terminatedTurns.add(sessionID);
        activeTurns.delete(sessionID);
        attention.delete(sessionID);
        const excerpt = errorExcerpt(event);
        const details = await lookup(sessionID);
        const rootID = sessionRoots.get(sessionID);
        const session = rootID ? sessionTrees.get(rootID)?.get(sessionID) : undefined;
        const directory = details.directory ?? session?.directory;
        if (details.treeMetadata) {
          const trackedRootID = recordSession(sessionID, details, "terminal");
          if (details.directory) await notify("failed", sessionID, details.directory, "", excerpt);
          if (sessionID === trackedRootID) removeTree(trackedRootID);
          else {
            await completePendingRoot(trackedRootID);
            pruneSettledTree(trackedRootID);
          }
          return;
        }

        if (session) {
          session.status = "terminal";
          if (directory) await notify("failed", sessionID, directory, "", excerpt);
          if (sessionID === rootID) removeTree(rootID);
          else {
            await completePendingRoot(rootID);
            pruneSettledTree(rootID);
          }
          return;
        }

        if (directory) await notify("failed", sessionID, directory, "", excerpt);
        return;
      }

      if (!ATTENTION_EVENTS.includes(event.type)) return;

      const requestID = requestIDFrom(event);
      if (!requestID) return;
      const { directory } = await lookup(sessionID);
      if (!directory) return;

      const key = attentionKey(event.type, requestID);
      if (event.type.endsWith(".asked")) {
        const requests = attention.get(sessionID) ?? new Set();
        if (requests.has(key)) return;
        requests.add(key);
        attention.set(sessionID, requests);
        await notify("attention", sessionID, directory, requestID);
        return;
      }

      const requests = attention.get(sessionID);
      if (requests?.delete(key)) {
        if (requests.size === 0) attention.delete(sessionID);
        await notify("attention-cleared", sessionID, directory, requestID);
      }
    },
  };
}

export default async function agentNotifyPlugin({ client, submit }) {
  return createOpenCodeAdapter({ client, submit });
}
